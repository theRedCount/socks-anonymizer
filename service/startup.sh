#!/bin/bash
set -euo pipefail

# Save original gateway before VPN
ORIG_GW=$(ip route show default | awk '/^default/ {print $3}')

# Required environment variables
: "${OPENVPN_USERNAME:?environment variable OPENVPN_USERNAME is required}"
: "${OPENVPN_PASSWORD:?environment variable OPENVPN_PASSWORD is required}"
: "${NORDVPN_CONFIG:?environment variable NORDVPN_CONFIG is required (e.g. us6914.nordvpn.com.tcp.ovpn)}"

# Write OpenVPN credentials
cat > /etc/openvpn/credentials.txt <<EOF
${OPENVPN_USERNAME}
${OPENVPN_PASSWORD}
EOF
chmod 600 /etc/openvpn/credentials.txt

# Start OpenVPN in background on tun0
openvpn \
  --config "/etc/openvpn/${NORDVPN_CONFIG}" \
  --auth-user-pass /etc/openvpn/credentials.txt \
  --dev tun0 \
  --verb 3 \
  --log /dev/stdout &

# Wait up to 60s for tun0 to appear
echo "Waiting for tun0 (max 60s)…"
for _ in $(seq 1 60); do
  [ -d /sys/class/net/tun0 ] && { echo "tun0 is up"; break; }
  sleep 1
done
[ -d /sys/class/net/tun0 ] || { echo "ERROR: tun0 did not appear" >&2; exit 1; }

# Set up a new routing table "100 ethroute"
mkdir -p /etc/iproute2
if [ ! -f /etc/iproute2/rt_tables ]; then
    # Create default rt_tables file if missing
    cat > /etc/iproute2/rt_tables <<'EOFTABLES'
#
# reserved values
#
255	local
254	main
253	default
0	unspec
#
# local
#
EOFTABLES
fi

# Add ethroute table if not already present
grep -q "ethroute" /etc/iproute2/rt_tables || echo "100 ethroute" >> /etc/iproute2/rt_tables
ip route add default via "${ORIG_GW}" dev eth0 table ethroute 2>/dev/null || true

# Mark incoming connections on eth0
iptables -t mangle -A PREROUTING -i eth0 -p tcp --dport 1080 -j CONNMARK --set-mark 0x1

# Mark responses based on connection mark
iptables -t mangle -A OUTPUT -m connmark --mark 0x1 -j MARK --set-mark 0x1

# Policy routing: use ethroute table for marked packets
ip rule add fwmark 0x1 table ethroute priority 1000

# Launch Dante SOCKS server (drops privileges per /etc/sockd.conf)
exec /usr/local/sbin/sockd -f /etc/sockd.conf
