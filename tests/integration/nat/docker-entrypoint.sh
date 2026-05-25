#!/bin/bash
set -euo pipefail

RUNDIR=/tmp/miniupnpd
mkdir -p "$RUNDIR"

# miniupnpd must listen on the same interface as the test node.
# We get the default route interface (e.g. eth0) and its IP.
LAN_IF=$(ip route show default | awk '/default/{print $5; exit}')
LAN_IP=$(ip -4 addr show "$LAN_IF" | awk '/inet /{print $2; exit}' | cut -d/ -f1)

if [[ -z "$LAN_IF" ]]; then
  echo "ERROR: could not determine LAN interface" >&2
  exit 1
fi

if [[ -z "$LAN_IP" ]]; then
  echo "ERROR: could not determine LAN IP on $LAN_IF" >&2
  exit 1
fi

# We use a public WAN IP (1.2.3.4) on a dummy interface because miniupnpd
# disables port forwarding when the external interface has a private/RFC1918
# address (treats it as double-NAT).
ip link add plum-wan type dummy
ip addr add 1.2.3.4/24 dev plum-wan
ip link set plum-wan up

start_miniupnpd() {
  local enable_pcp_pmp=$1
  cat > "$RUNDIR/miniupnpd.conf" << EOF
ext_ifname=plum-wan
listening_ip=$LAN_IF
enable_pcp_pmp=$enable_pcp_pmp
# port=0: pick a random HTTP port to avoid conflicts with host services.
port=0
# Without an allow rule miniupnpd denies all mapping requests by default.
allow 1024-65535 0.0.0.0/0 1024-65535
EOF
  miniupnpd -d -f "$RUNDIR/miniupnpd.conf" > "$RUNDIR/miniupnpd.log" 2>&1 &
  MINIUPNPD_PID=$!
  sleep 1
  kill -0 "$MINIUPNPD_PID" 2>/dev/null \
    || { echo "ERROR: miniupnpd failed to start" >&2; cat "$RUNDIR/miniupnpd.log" >&2; exit 1; }
  echo "miniupnpd started (pid $MINIUPNPD_PID)"
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
