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

cat >"$profiles_file" <<EOF
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
chmod 0400 "$profiles_file"
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
cat >"$config_file" <<EOF
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
# Behind a container bridge the host is 1:1 NATed, so MTProxy would announce an
# address Telegram cannot reach and every middle-end connection would die right
# after the handshake - silently, on every layer. TPROXY_NAT_INFO must carry
# <local>:<public> for that case; see README.md.

log "starting MTProxy"
# `su` needs a single shell-quoted command string. sh has no %q, so quote the
# known-safe arguments explicitly: the secret is hex and the NAT pair is
# <address>:<address>.
nat_args=""
if [ -n "${TPROXY_NAT_INFO:-}" ]; then
	nat_args="--nat-info ${TPROXY_NAT_INFO}"
	log "MTProxy NAT mode: $nat_args"
fi

mtproxy_command="/usr/local/bin/mtproto-proxy -u mtproxy -p 8888 -H 2398"
mtproxy_command="$mtproxy_command -S $secret"
mtproxy_command="$mtproxy_command --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf"
mtproxy_command="$mtproxy_command -M ${MTPROXY_WORKERS:-1} -C ${MTPROXY_MAX_CONNECTIONS:-4096}"
if [ -n "$nat_args" ]; then
	mtproxy_command="$mtproxy_command $nat_args"
fi

# shellcheck disable=SC2086
su -s /bin/sh mtproxy -c "$mtproxy_command" &
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
