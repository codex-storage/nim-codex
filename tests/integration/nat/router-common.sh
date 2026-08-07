#!/usr/bin/env bash

# Shared router base, sourced by each scenario's router-entrypoint.sh

set -euo pipefail

# iptables needs the wan interface's name (eth0/eth1), but podman assigns those
# names arbitrarily — so look for the name using the wan IP,
# defined in the compose file.
wanif=$(ip -o -4 addr show | awk -v ip="$ROUTER_WAN_IP" '$0 ~ ip {print $2; exit}')

if ! iptables -t nat -A POSTROUTING -s "$LAN_SUBNET" -o "$wanif" -j MASQUERADE; then
  echo "ERROR: iptables NAT failed. Load netfilter modules on the host:" >&2
  echo "       sudo modprobe iptable_nat nf_conntrack" >&2
  exit 1
fi
iptables -P FORWARD ACCEPT

# By default, drop all incoming traffic on the WAN interface - if we don't do this,
# the router will issue an RST when external peers try to connect and things like hole
# punching will fail.
iptables -A INPUT -i "$wanif" -j DROP

# Block until `compose down`. sleep runs in the background so the SIGTERM trap
# fires immediately instead of waiting for sleep to return.
hold_until_stopped() {
  trap 'exit 0' TERM INT
  sleep infinity &
  wait
}
