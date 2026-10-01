#!/bin/sh
# Container entrypoint: render the relay config, generate the token key, and
# supervise MTProxy + the relay + Caddy.
#
# The reference deployment runs three processes on one host. In a container the
# relay, MTProxy and Caddy are the same image, so this supervises them together
# and shuts the container down if any of them exits.
set -eu

hostname="${TPROXY_HOSTNAME:?TPROXY_HOSTNAME is required}"
config_dir=/etc/tproxy-server
config_file="$config_dir/config.json"
profiles_file="$config_dir/profiles.json"

log() { echo "[entrypoint] $*"; }

# --------------------------------------------------------------- profiles --
# The client-facing secret is the plain hex MTProxy secret unless a base path is
# configured, in which case the client expects the marked 0x70 form. See
# README.md "Configure a Telegram client".
secret="${TPROXY_SECRET:?TPROXY_SECRET is required}"
if [ -n "${TPROXY_BASE_PATH:-}" ]; then
	marked=$(
		{ printf '\x70'; printf '%s' "$secret" | sed 's/../\\x&/g'; } |
			base64 | tr '+/' '-_' | tr -d '=\n'
	)
	client_secret="$marked"
else
	client_secret="$secret"
fi

# Both generated files are installed atomically via a temp file. Writing them
# in place would fail on every restart after the first: the file is created
# 0400, and a plain ">" redirect cannot reopen a file it does not have write
# permission on. That failure needs DAC_OVERRIDE to work around, and holding
# DAC_OVERRIDE makes official MTProxy abort at startup.
profiles_tmp=$(mktemp "$config_dir/.profiles.XXXXXX")
cat >"$profiles_tmp" <<EOF
{
  "profiles": [
    {
      "name": "default",
      "secret": "$client_secret",
      "backend": "127.0.0.1:2398",
      "carrier_mode": "${TPROXY_CARRIER_MODE:-https}"
    }
  ]
}
EOF
chmod 0400 "$profiles_tmp"
mv -f "$profiles_tmp" "$profiles_file"
chown root:mtproxy "$profiles_file"
log "profiles written (carrier_mode=${TPROXY_CARRIER_MODE:-https})"

# ------------------------------------------------------------------ site --
# The relay needs exactly one of public_dir (it serves the site itself, from
# memory) or public_upstream (it delegates to a loopback application). Exactly
# one of the two must be configured or the relay refuses to start.
#
# public_dir is the default here because it needs no second process. The
# repository deliberately ships no real site: many operators deploying the same
# starter page would give active probers a fingerprint. Mount your own over
# /srv/tproxy-site, or set TPROXY_PUBLIC_UPSTREAM to a loopback address to
# delegate instead.
site_dir=/srv/tproxy-site
if [ -n "${TPROXY_PUBLIC_UPSTREAM:-}" ]; then
	public_setting="\"public_upstream\": \"$TPROXY_PUBLIC_UPSTREAM\","
	log "serving the site from $TPROXY_PUBLIC_UPSTREAM"
else
	if [ ! -f "$site_dir/index.html" ]; then
		log "no index.html in $site_dir; the relay will answer 503 for site paths"
	fi
	public_setting="\"public_dir\": \"$site_dir\","
	log "serving the site from $site_dir"
fi

# ----------------------------------------------------------------- config --
# Every listener is loopback. Caddy is the only process that binds an
# externally reachable port, and it is the only thing the compose file
# publishes.
config_tmp=$(mktemp "$config_dir/.config.XXXXXX")
cat >"$config_tmp" <<EOF
{
  "public_hostname": "$hostname",
  "base_path": "${TPROXY_BASE_PATH:-}",
  "listen": "127.0.0.1:8080",
  "admin_listen": "127.0.0.1:8081",
  $public_setting
  "token_key_file": "$config_dir/token.key",
  "static_routes": "exact",
  "profiles_file": "$profiles_file",
  "enable_pprof": false,
  "timeouts": {
    "backend_dial": "5s",
    "long_poll": "25s",
    "reconnect_grace": "2m",
    "bootstrap_lifetime": "2m",
    "read_header": "10s",
    "idle": "75s",
    "shutdown": "15s"
  }
}
EOF
chmod 0600 "$config_tmp"
mv -f "$config_tmp" "$config_file"

# ------------------------------------------------------------------ token --
# A missing or permissive key fails startup; no ephemeral key is generated,
# because rotating it on every restart would invalidate live sessions. The relay
# wants exactly 32 raw bytes, so no trailing newline.
if [ ! -s "$config_dir/token.key" ]; then
	log "provisioning token.key"
	head -c 32 /dev/urandom >"$config_dir/token.key"
fi
chown root:mtproxy "$config_dir/token.key"
chmod 0400 "$config_dir/token.key"

# ----------------------------------------------------------------- mtproxy --
# The backend's middle-end needs --nat-info <local>:<public>.
#
# Telegram mixes the endpoints' addresses into the AES key that protects the
# middle-end handshake (net/net-crypto-aes.c: aes_create_keys), so both ends
# must independently hash the same address pair. The transport is plain TCP and
# the connection really does establish; it is dropped immediately afterwards,
# because Telegram sees the public source address while MTProxy only knows the
# container's. The failure is silent on every layer: clients connect, streams
# open, and no data ever comes back.
#
# Two things make the rule easy to get wrong, and both are handled here:
#
#   - The first half must be the address MTProxy sees on its own socket, which
#     inside a container is the container address, not the host's LAN address.
#     nat_translate_ip() only substitutes on an exact match
#     (net/net-connections.c:2173), so a host address never matches and the
#     rule is silently inert. It is derived from the running container instead
#     of being configured, so it cannot go stale across restarts.
#   - On CGNAT the public address is not on any interface and is not stable.
#     It is detected at startup rather than pinned in configuration.

log "starting MTProxy"

# Only the first IPv4 is usable: MTProxy's translation table is 32-bit.
detect_public_ip() {
	ip=""
	for url in https://ifconfig.co/ip https://api.ipify.org https://ifconfig.me/ip; do
		ip=$(curl --fail --silent --show-error --max-time 10 \
			--proto '=https' --tlsv1.2 "$url" 2>/dev/null | tr ',[:space:]' '\n' |
			grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | head -1)
		[ -n "$ip" ] && break
	done
	printf '%s' "$ip"
}

public_ip="${TPROXY_PUBLIC_IP:-}"
if [ -z "$public_ip" ]; then
	public_ip=$(detect_public_ip)
fi

local_ip=$(hostname -i 2>/dev/null | awk '{print $1}')

nat_args=""
if [ -n "$public_ip" ] && [ -n "$local_ip" ]; then
	nat_args="--nat-info=$local_ip:$public_ip"
	log "MTProxy NAT mode: --nat-info $local_ip:$public_ip"
	if [ "$local_ip" = "$public_ip" ]; then
		log "note: local and public addresses are identical, so no translation is in effect"
	fi
else
	log "WARNING: could not determine the public IPv4 address (set TPROXY_PUBLIC_IP)."
	log "WARNING: the middle-end will very likely fail silently - every Telegram"
	log "WARNING: connection will be dropped right after the handshake because the"
	log "WARNING: AES key is derived from an address the DC does not see. Set"
	log "WARNING: TPROXY_PUBLIC_IP, or egress to an address-lookup service."
fi


# The secret is hex and the remaining values are paths and integers, so the
# unquoted expansions below are safe; set -- keeps each one a single argv entry.
# shellcheck disable=SC2086
set -- /usr/local/bin/mtproto-proxy \
	-u mtproxy \
	-p 8888 \
	-H 2398 \
	-S "$secret" \
	--aes-pwd /etc/mtproxy/proxy-secret \
	/etc/mtproxy/proxy-multi.conf \
	-M "${MTPROXY_WORKERS:-1}" \
	-C "${MTPROXY_MAX_CONNECTIONS:-4096}"
if [ -n "$nat_args" ]; then
	set -- "$@" "$nat_args"
fi

"$@" &
mtproxy_pid=$!

log "starting relay"
/usr/local/bin/tproxy-server -config "$config_file" -profiles-file "$profiles_file" &
relay_pid=$!

# Caddy serves the whole hostname. When it runs behind a Cloudflare Tunnel it
# must not also try to obtain a public certificate, so TPROXY_TLS=off is the
# supported tunnel mode and Caddy terminates plain HTTP for the tunnel to
# forward.
log "starting caddy (site=${TPROXY_SITE_ADDRESS:-http://:80})"
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
caddy_pid=$!

shutdown() {
	log "shutting down"
	kill "$mtproxy_pid" "$relay_pid" "$caddy_pid" 2>/dev/null || true
	wait 2>/dev/null || true
}
trap shutdown INT TERM

# Exit as soon as any supervised process does, so an orchestrator restarts the
# container instead of leaving a half-working relay serving 503s.
while :; do
	for pid in "$mtproxy_pid" "$relay_pid" "$caddy_pid"; do
		if ! kill -0 "$pid" 2>/dev/null; then
			log "process $pid exited; stopping the container"
			shutdown
			exit 1
		fi
	done
	sleep 2
done
