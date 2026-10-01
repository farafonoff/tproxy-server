#!/bin/sh
# Reports whether this host can actually carry Telegram traffic through the
# official MTProxy backend, before you spend time debugging a deployment that
# looks healthy but moves no data.
#
#   scripts/preflight.sh
set -eu

public_ip=""
for url in https://ifconfig.co/ip https://api.ipify.org https://ifconfig.me/ip; do
	public_ip=$(curl --fail --silent --show-error --max-time 10 \
		--proto '=https' --tlsv1.2 "$url" 2>/dev/null | tr ',[:space:]' '\n' |
		grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | head -1) || true
	[ -n "$public_ip" ] && break
done

# Every address on this host's interfaces, excluding loopback.
local_ips=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
if [ -z "$local_ips" ]; then
	local_ips=$(ifconfig 2>/dev/null | awk '/inet /{print $2}' |
		grep -v '^127\.' || true)
fi

# A local address inside 100.64.0.0/10 is the carrier-grade NAT giveaway: an
# ISP hands the customer a CGNAT address, and the public address is a shared
# translation that also rewrites the source port.
cgnat_local=no
for ip in $local_ips; do
	case "$ip" in
		100.*) cgnat_local=yes ;;
	esac
done

echo "public address : ${public_ip:-unknown}"
echo "local addresses: $(echo "$local_ips" | tr '\n' ' ')"
echo "CGNAT egress   : $cgnat_local"

verdict=0
note=""

# The address is not on any interface, so something is translating it.
if [ -n "$public_ip" ]; then
	on_interface=no
	for ip in $local_ips; do
		[ "$ip" = "$public_ip" ] && on_interface=yes
	done
	if [ "$on_interface" = no ]; then
		note="${note}  - the public address is not on any local interface, so it is translated.\n"
	fi
fi

# Either signal is enough: a CGNAT address on the egress, or the public address
# itself falling in the CGNAT range.
if [ "$cgnat_local" = yes ]; then
	note="${note}  - a local address is inside 100.64.0.0/10, which is CGNAT.\n"
	verdict=1
fi
case "$public_ip" in
	100.*)
		note="${note}  - the public address is inside 100.64.0.0/10, which is CGNAT.\n"
		verdict=1
		;;
esac

echo
if [ "$verdict" -eq 0 ]; then
	echo "Result: no obvious port-rewriting NAT detected."
	echo
	echo "That is necessary but not sufficient: a 1:1 NAT preserves the source port"
	echo "and works, while CGNAT does not. If traffic still does not flow, run the"
	echo "backend at -v -v -v -v and look for 'Disconnected from RPC Middle-End'."
else
	echo "Result: this host CANNOT work with the official MTProxy backend."
	echo
	printf "%b" "$note"
	echo "  MTProxy mixes the source PORT into its middle-end key and can translate"
	echo "  addresses only - never ports. Behind port-rewriting NAT the port it"
	echo "  hashes is not the port Telegram sees, so every middle-end connection is"
	echo "  dropped right after the handshake, with no error on any layer."
	echo
	echo "The relay, the site and the tunnel will all run. No Telegram data will"
	echo "ever flow. Use a host with a public IPv4 on the interface - a small VPS is"
	echo "enough. See docker/README.md."
fi
