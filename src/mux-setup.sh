#!/bin/bash
# mux-setup.sh - build the data plane for the 4x IDEC PLC selector on an
# EdgeRouter X. Idempotent; safe to re-run. Owns eth1-eth4 addressing itself
# (do NOT give those ports an address in the EdgeOS GUI/CLI).
#
# Port map (edit PLC_IFS to match your cabling):
#   eth0 -> HMI / SCADA + UDP control
#   eth1 -> PLC #1    eth2 -> PLC #2    eth3 -> PLC #3    eth4 -> PLC #4
set -u

PLC_IP=192.168.1.160          # the shared address every PLC answers on
SNAT_IP=192.168.1.1           # source the PLCs see; must be in their /24
HMI_IF=eth0                   # port the HMI plugs into
HMI_ADDR=192.168.1.254/24     # router's presence on the HMI segment
PLC_IFS=(eth1 eth2 eth3 eth4) # index 0 == PLC #1
BASE_TABLE=100                # PLC #1 = table 100, #2 = 101, ...

ipf() { echo "$1" > "/proc/sys/net/ipv4/conf/$2/$3" 2>/dev/null; }

# ---- HMI side ------------------------------------------------------------
ip addr add "$HMI_ADDR" dev "$HMI_IF" 2>/dev/null
ip link set "$HMI_IF" up
# Answer ARP for .160 on the HMI segment so the HMI believes the router IS
# the PLC. The router never owns .160 itself, so traffic gets forwarded, not
# delivered locally.
ipf 1 "$HMI_IF" proxy_arp
ip neigh replace proxy "$PLC_IP" dev "$HMI_IF"
ipf 2 "$HMI_IF" rp_filter          # loose

# ---- PLC side ------------------------------------------------------------
i=0
for IF in "${PLC_IFS[@]}"; do
    table=$((BASE_TABLE + i))
    # /32 so no competing 192.168.1.0/24 connected route lands in the main
    # table (that would be a four-way conflict).
    ip addr add "${SNAT_IP}/32" dev "$IF" 2>/dev/null
    ip link set "$IF" up
    ipf 0 "$IF" rp_filter            # off: forward path is asymmetric by design
    ipf 1 "$IF" forwarding
    # The only route to the shared .160 in this table is out this one port.
    ip route replace "$PLC_IP/32" dev "$IF" scope link table "$table"
    # Make the PLC think the client lives at SNAT_IP, which is in its subnet,
    # so it can reply directly to us.
    iptables -t nat -C POSTROUTING -o "$IF" -d "$PLC_IP" -j SNAT --to-source "$SNAT_IP" 2>/dev/null \
      || iptables -t nat -A POSTROUTING -o "$IF" -d "$PLC_IP" -j SNAT --to-source "$SNAT_IP"
    i=$((i + 1))
done

echo 1 > /proc/sys/net/ipv4/ip_forward

# ---- default selection: PLC #1 ------------------------------------------
# The daemon rewrites this single rule on each UDP selector.
ip rule del to "$PLC_IP" 2>/dev/null
ip rule add to "$PLC_IP" lookup "$BASE_TABLE" pref 100

logger -t plc-mux "data plane up; default -> PLC #1 (table $BASE_TABLE)"
