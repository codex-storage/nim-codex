#!/bin/bash
set -euo pipefail

RUNDIR=/tmp/miniupnpd
mkdir -p "$RUNDIR"

LAN_IF=$(ip route show default | awk '/default/{print $5; exit}')
LAN_IP=$(ip -4 addr show "$LAN_IF" | awk '/inet /{print $2; exit}' | cut -d/ -f1)

ip link add plum-wan type dummy
ip addr add 1.2.3.4/24 dev plum-wan
ip link set plum-wan up

start_miniupnpd() {
  local enable_pcp_pmp=$1
  cat > "$RUNDIR/miniupnpd.conf" << EOF
ext_ifname=plum-wan
listening_ip=$LAN_IF
enable_pcp_pmp=$enable_pcp_pmp
port=0
allow 1024-65535 0.0.0.0/0 1024-65535
EOF
  miniupnpd -d -f "$RUNDIR/miniupnpd.conf" > "$RUNDIR/miniupnpd.log" 2>&1 &
  sleep 1
}

if [[ "${TEST_PCP:-0}" == "1" ]]; then
  # PCP requires the UDP source IP to match the client_address in the MAP request.
  # Point the default route at LAN_IP so libplum uses it as both gateway and PCP target.
  ip route replace default via "$LAN_IP" dev "$LAN_IF"
  start_miniupnpd yes
  failed=0
  DEBUG=${DEBUG:-0} /app/build/testIntegrationNatPcp || failed=1
else
  start_miniupnpd no
  failed=0
  DEBUG=${DEBUG:-0} /app/build/testIntegrationNat || failed=1
fi

if [[ "${DEBUG:-0}" == "1" ]]; then
  echo "--- miniupnpd log ---"
  cat "$RUNDIR/miniupnpd.log" 2>/dev/null || true
fi

[ $failed -eq 0 ] || exit 1
