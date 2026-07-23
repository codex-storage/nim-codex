#!/usr/bin/env bash

source "$(dirname "$0")/router-common.sh"

# Drop early punch SYN so TCP retransmits until the
# pinhole is open and the SYN gets forwarded.
iptables -A INPUT -i "$wanif" -p tcp --dport 8070 -j DROP

echo "router ready (wan iface $wanif)"

hold_until_stopped
