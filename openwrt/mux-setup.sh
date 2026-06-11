#!/bin/sh
# mux-setup.sh (OpenWrt/busybox-sh variant) - build the data plane for the 4x
# IDEC PLC selector on an EdgeRouter X running OpenWrt. POSIX sh (no bash
# arrays); requires ip-full + iptables. Idempotent; safe to re-run.
#
# Port map (edit PLC_IFS to match your cabling):
#   eth0 -> HMI / SCADA + UDP control
#   eth1 -> PLC #1   eth2 -> PLC #2   eth3 -> PLC #3   eth4 -> PLC #4
set -u

PLC_IP=192.168.1.160          # the shared address every PLC answers on
SNAT_IP=192.168.1.1           # source the PLCs see; must be in their /24
HMI_IF=eth0                   # port the HMI plugs into
HMI_ADDR=192.168.1.254/24     # router's presence on the HMI segment
PLC_IFS="eth1 eth2 eth3 eth4" # first == PLC #1
BASE_TABLE=100                # PLC #1 = table 100, #2 = 101, ...

ipf() { echo "$1" > "/proc/sys/net/ipv4/conf/$2/$3" 2>/dev/null; }

# Promiscuous mode (OpenWrt-only): the ER-X's DSA switch drops frames whose
# destination MAC isn't the port's own. A device can still hold a stale ARP for
# .160 (the real PLC's MAC from before the mux was inserted) and send to that MAC;
# promisc lets the router receive and forward those frames instead of the switch
# silently dropping them. Harmless on a dedicated appliance.
promisc() { ip link set "$1" promisc on 2>/dev/null; }

# ---- HMI side ------------------------------------------------------------
ip addr add "$HMI_ADDR" dev "$HMI_IF" 2>/dev/null
ip link set "$HMI_IF" up
promisc "$HMI_IF"
# Answer ARP for .160 on the HMI segment so the HMI believes the router IS the
# PLC. The router never owns .160 itself, so traffic is forwarded, not delivered.
ipf 1 "$HMI_IF" proxy_arp
ip neigh replace proxy "$PLC_IP" dev "$HMI_IF"
ipf 2 "$HMI_IF" rp_filter          # loose

# ---- PLC side ------------------------------------------------------------
i=0
for IF in $PLC_IFS; do
    table=$((BASE_TABLE + i))
    # /32 so no competing 192.168.1.0/24 connected route lands in the main table.
    ip addr add "${SNAT_IP}/32" dev "$IF" 2>/dev/null
    ip link set "$IF" up
    promisc "$IF"
    ipf 0 "$IF" rp_filter            # off: forward path is asymmetric by design
    ipf 1 "$IF" forwarding
    # The only route to the shared .160 in this table is out this one port.
    ip route replace "$PLC_IP/32" dev "$IF" scope link table "$table"
    # Make the PLC think the client lives at SNAT_IP (in its subnet) so it can reply.
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
