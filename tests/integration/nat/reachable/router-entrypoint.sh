#!/usr/bin/env bash

source "$(dirname "$0")/router-common.sh"

# Forward the node's TCP listen port (what AutoNAT dials back) and UDP disc port
# in order to simulate the port mapping.
forward_port 8070 "$NODE_IP" 8070 tcp
forward_port 8090 "$NODE_IP" 8090 udp

echo "router ready (forwarding tcp/8070 + udp/8090 to $NODE_IP, wan iface $wanif)"

hold_until_stopped
