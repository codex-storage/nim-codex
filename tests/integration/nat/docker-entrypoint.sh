#!/bin/bash
set -euo pipefail

RUNDIR=/tmp/miniupnpd
mkdir -p "$RUNDIR"

LAN_IF=$(ip route show default | awk '/default/{print $5; exit}')

ip link add plum-wan type dummy
ip addr add 1.2.3.4/24 dev plum-wan
ip link set plum-wan up

cat > "$RUNDIR/miniupnpd.conf" << EOF
ext_ifname=plum-wan
listening_ip=$LAN_IF
enable_pcp_pmp=no
port=0
allow 1024-65535 0.0.0.0/0 1024-65535
EOF

if [[ "${DEBUG:-0}" == "1" ]]; then
  miniupnpd -d -f "$RUNDIR/miniupnpd.conf" &
else
  miniupnpd -d -f "$RUNDIR/miniupnpd.conf" > /dev/null 2>&1 &
fi
sleep 1

/app/build/testIntegrationNat
