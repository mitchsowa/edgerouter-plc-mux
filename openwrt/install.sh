#!/bin/sh
# install.sh (OpenWrt variant) - deploy the PLC multiplexer onto an EdgeRouter X
# running OpenWrt. Run as root ON THE ROUTER, from the cloned repo:
#     sh openwrt/install.sh
#
# Installs runtime deps, the daemon (shared with the EdgeOS build), an OpenWrt
# busybox-sh data-plane script, and a procd init service. It does NOT touch the
# network config automatically (that's lockout-prone) - it prints the one-time
# uci steps for you to apply. See openwrt/README.md.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST=/root/plc-mux

[ "$(id -u)" -eq 0 ] || { echo "run as root on the router"; exit 1; }

echo ">> Installing runtime dependencies (needs opkg feeds / internet)..."
opkg update
# perl (daemon) + conntrack (switch-time flush) + ip-full (policy routing,
# proxy-neigh; busybox 'ip' can't do these).
opkg install perlbase-essential perlbase-io perlbase-socket perlbase-posix conntrack ip-full

echo ">> Installing files..."
mkdir -p "$DEST"
cp "$REPO/src/plc-mux.pl"       "$DEST/plc-mux.pl"
cp "$REPO/openwrt/mux-setup.sh" "$DEST/mux-setup.sh"
cp "$REPO/openwrt/plc-mux.init" /etc/init.d/plc-mux
chmod +x "$DEST/plc-mux.pl" "$DEST/mux-setup.sh" /etc/init.d/plc-mux
# Guard against CRLF if the repo was ever touched on Windows.
sed -i 's/\r$//' "$DEST/plc-mux.pl" "$DEST/mux-setup.sh" /etc/init.d/plc-mux

/etc/init.d/plc-mux enable

cat <<'EOM'

Files installed; service enabled on boot.

ONE-TIME network config. This turns eth0 into the HMI/control port and frees
eth1-4 as independent routed PLC ports; it REMOVES the default br-lan/LAN, wan,
and firewall. After this you manage the box at eth0 = 192.168.1.254.

WARNING: apply this while connected via eth0 (so removing br-lan won't drop you),
and do NOT leave eth1-4 cabled to the same switch as eth0 once the mux is running
(proxy-ARP + the shared .1 will flap an unmanaged switch).

    uci -q delete network.wan; uci -q delete network.wan6
    uci -q delete network.lan
    uci -q delete network.@device[0]              # the br-lan bridge
    uci set network.mgmt=interface
    uci set network.mgmt.device=eth0
    uci set network.mgmt.proto=static
    uci set network.mgmt.ipaddr=192.168.1.254
    uci set network.mgmt.netmask=255.255.255.0
    for i in 1 2 3 4; do
      uci set network.plc$i=interface
      uci set network.plc$i.device=eth$i
      uci set network.plc$i.proto=none
    done
    uci commit network
    for s in firewall dnsmasq odhcpd; do /etc/init.d/$s stop; /etc/init.d/$s disable; done
    /etc/init.d/network reload
    /etc/init.d/plc-mux start

Verify:
    logread -e plc-mux
    ip rule show | grep 192.168.1.160
    ip route show table 100        # 192.168.1.160 dev eth1
EOM
