#!/bin/sh
# Creates .env from .env.example with a fresh client-facing secret.
set -eu

cd "$(dirname "$0")/.."

if [ -e .env ]; then
	echo ".env already exists, refusing to overwrite it" >&2
	exit 1
fi

if command -v openssl >/dev/null 2>&1; then
	secret=$(openssl rand -hex 16)
else
	secret=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
fi

sed -e "s|^TPROXY_SECRET=.*|TPROXY_SECRET=$secret|" .env.example >.env
chmod 600 .env

# Report whether this host can actually carry Telegram traffic, and leave
# TPROXY_PUBLIC_IP empty so the entrypoint detects it at startup. Detecting it
# here and pinning it would be wrong: on CGNAT the address can be reassigned
# without notice, and the whole point of the lookup at startup is to notice.
#
# The pairing with the local address is the entrypoint's job, not ours: inside a
# container MTProxy sees the container address, never the host's, so a rule
# keyed on a host address can never match.
public_ip=""
if command -v curl >/dev/null 2>&1; then
	public_ip=$(curl --fail --silent --show-error --max-time 10 \
		https://ifconfig.co/ip 2>/dev/null | tr ',' '\n' |
		grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | head -1 || true)
fi

local_ip=""
if command -v ipconfig >/dev/null 2>&1; then
	for dev in en0 en1 en2; do
		candidate=$(ipconfig getifaddr "$dev" 2>/dev/null || true)
		[ -n "$candidate" ] && local_ip="$candidate" && break
	done
elif command -v hostname >/dev/null 2>&1; then
	local_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
fi

warning=""
if [ -n "$public_ip" ] && [ "$public_ip" != "$local_ip" ]; then
	warning=yes
fi

cat <<EOF
.env written.

  secret  $secret

Next:
  1. set TPROXY_HOSTNAME in .env
  2. docker compose up -d --build
  3. check http://127.0.0.1:\${LOCAL_HTTP_PORT:-8080}/
EOF

if [ -n "$warning" ]; then
	cat <<EOF

NOTE: this host's public address ($public_ip) is not on any of its interfaces
      (local is $local_ip).

      That matters for the backend. MTProxy's middle-end key includes the source
      PORT, and it can only translate addresses - never ports. So this works
      behind 1:1 NAT, which preserves the port, but it CANNOT work behind CGNAT
      or other port-rewriting NAT, where the carrier also rewrites the port.

      If your egress is a 100.64.0.0/10 address, or the public address above is
      not yours alone, the relay and the site will run but no Telegram traffic
      will ever flow. See "Port-rewriting NAT" in docker/README.md.
EOF
fi

