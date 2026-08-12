#!/usr/bin/env bash

source "$(dirname "$0")/router-common.sh"

# miniupnpd listens for UPnP (SSDP) on the lan face, so find it by its IP like
# router-common.sh finds the wan one.
lanif=$(ip -o -4 addr show | awk -v ip="$ROUTER_LAN_IP" '$0 ~ ip {print $2; exit}')

# Reuse miniupnpd's chains (as nft_init.sh sets them up) without its forward drop
# policy.
nft -f - <<'EOF'
table inet filter {
  chain prerouting_miniupnpd {}
  chain postrouting_miniupnpd {}
  chain miniupnpd {}
  chain prerouting {
    type nat hook prerouting priority -100; policy accept;
    jump prerouting_miniupnpd
  }
  chain postrouting {
    type nat hook postrouting priority 100; policy accept;
    jump postrouting_miniupnpd
  }
}
EOF

# The prerouting_miniupnpd chain above is where miniupnp puts its DNAT rules.
# The FORWARD rules, however, are added to the miniupnpd chain which is not
# jumped from anywhere. Yet, even if we were to jump from FORWARD to miniupnpd,
# the rules there would still be useless because the iptables FORWARD chain is
# set to DROP in `router-common.sh`. We therefore need to add a general "allow
# DNATed packets" to the forward chain or mapped ports won't work.
iptables -A FORWARD -m conntrack --ctstate DNAT -j ACCEPT

# FIXME this is a bit of a mess. :-) Ideally there should be a way to just let
#   miniupnpd manage everything, we'll need to revisit router-common.sh to make
#   that happen.

conf=/tmp/miniupnpd.conf
cat > "$conf" <<EOF
ext_ifname=$wanif
listening_ip=$lanif
# Disable PCP/NAT-PMP so libplum can't pick them and falls back to UPnP, which
# is what this scenario exercises.
enable_pcp_pmp=no
# port=0: pick a random HTTP port, no conflict with the storage API.
port=0
# Without an allow rule miniupnpd denies every mapping request by default.
allow 1024-65535 0.0.0.0/0 1024-65535
EOF

# -d: stay in the foreground; background it so the SIGTERM trap below still fires.
miniupnpd-nft -d -f "$conf" &
upnpd_pid=$!
sleep 1
kill -0 "$upnpd_pid" 2>/dev/null \
  || { echo "ERROR: miniupnpd failed to start" >&2; exit 1; }

echo "router ready (wan iface $wanif, miniupnpd on $lanif)"

hold_until_stopped
