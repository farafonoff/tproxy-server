#!/bin/sh
# Refreshes official MTProxy's AES secret and routing table, and restarts
# MTProxy only when the routing data actually changed.
#
# The same contract as deploy/refresh-mtproxy-config.sh: existing backend
# streams reconnect through the still-live relay session, and the public site
# stays available while either backend process is down.
set -eu

secret_file=/etc/mtproxy/proxy-secret
config_file=/etc/mtproxy/proxy-multi.conf

tmp_secret=$(mktemp /tmp/proxy-secret.XXXXXX)
tmp_config=$(mktemp /tmp/proxy-multi.conf.XXXXXX)
trap 'rm -f "$tmp_secret" "$tmp_config"' EXIT

for url in https://core.telegram.org/getProxySecret https://core.telegram.org/getProxyConfig; do
	curl --fail --silent --show-error --location \
		--proto '=https' --proto-redir '=https' --tlsv1.2 \
		--retry 3 --retry-delay 5 \
		--output "$([ "$url" = "https://core.telegram.org/getProxySecret" ] && echo "$tmp_secret" || echo "$tmp_config")" \
		"$url"
done

# Validate before replacing anything: a truncated download must not be installed.
test "$(wc -c <"$tmp_secret")" -eq 128
test "$(wc -c <"$tmp_config")" -ge 100
grep -q '^default ' "$tmp_config"
grep -q '^proxy_for ' "$tmp_config"

changed=0
cmp -s "$secret_file" "$tmp_secret" || changed=1
cmp -s "$config_file" "$tmp_config" || changed=1

if [ "$changed" -eq 0 ]; then
	echo "[refresh] routing data unchanged"
	exit 0
fi

echo "[refresh] routing data changed; installing"
install -m 0640 -o root -g mtproxy "$tmp_secret" "$secret_file"
install -m 0640 -o root -g mtproxy "$tmp_config" "$config_file"

if [ -f /run/tproxy-mtproxy.pid ]; then
	kill -HUP "$(cat /run/tproxy-mtproxy.pid)" 2>/dev/null ||
		echo "[refresh] could not signal MTProxy; it will pick the data up on restart"
fi
