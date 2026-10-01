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

# The middle-end address pair. Behind any NAT the public half has to be the
# address Telegram sees this host arrive from, or MTProxy's middle-end keys are
# derived from the wrong value and every connection is dropped after the
# handshake.
public_ip=${TPROXY_PUBLIC_IP:-}
if [ -z "$public_ip" ] && command -v curl >/dev/null 2>&1; then
	public_ip=$(curl --fail --silent --show-error --max-time 10 \
		https://api.ipify.org 2>/dev/null || true)
fi
if [ -n "$public_ip" ]; then
	local_ip=$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || true)
	if [ -n "$local_ip" ]; then
		sed -i.bak -e "s|^TPROXY_NAT_INFO=.*|TPROXY_NAT_INFO=$local_ip:$public_ip|" .env
		rm -f .env.bak
		echo "TPROXY_NAT_INFO=$local_ip:$public_ip"
	fi
fi

cat <<EOF
.env written.

  secret  $secret

Next:
  1. set TPROXY_HOSTNAME in .env
  2. docker compose up -d --build
  3. check http://127.0.0.1:\${LOCAL_HTTP_PORT:-8080}/
EOF
