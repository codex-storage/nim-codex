#!/usr/bin/env bash

source "$(dirname "$0")/router-common.sh"

# Forward the node's TCP listen port (what AutoNAT dials back) and UDP disc port
# in order to simulate the port mapping.
iptables -t nat -A PREROUTING -i "$wanif" -p tcp --dport 8070 -j DNAT --to-destination "$NODE_IP:8070"
iptables -t nat -A PREROUTING -i "$wanif" -p udp --dport 8090 -j DNAT --to-destination "$NODE_IP:8090"

echo "router ready (forwarding tcp/8070 + udp/8090 to $NODE_IP, wan iface $wanif)"

hold_until_stopped
