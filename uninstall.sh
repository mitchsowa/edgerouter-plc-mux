#!/bin/bash
# uninstall.sh - stop the daemon and remove installed files. Run as root.
set -u

pkill -f plc-mux.pl 2>/dev/null || true
rm -f  /config/scripts/post-config.d/90-plc-mux.sh
rm -rf /config/user-data/plc-mux

# Tear down the live policy rule. Per-interface addresses, routing tables and
# SNAT rules are runtime-only and clear on the next reboot.
ip rule del to 192.168.1.160 2>/dev/null || true

cat <<'EOM'
Removed. Remaining runtime state (addresses, tables, NAT) clears on reboot.

The eth0 address and proxy-arp are still in the saved EdgeOS config; remove by hand if unwanted:

    configure
    delete interfaces ethernet eth0 ip enable-proxy-arp
    delete interfaces ethernet eth0 address 192.168.1.254/24
    commit ; save ; exit
EOM
