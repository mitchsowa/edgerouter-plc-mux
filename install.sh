#!/bin/bash
# install.sh - deploy the PLC multiplexer onto an EdgeRouter X.
# Run as root ON THE ROUTER, from the cloned repo:  sudo ./install.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
DEST=/config/user-data/plc-mux
PCD=/config/scripts/post-config.d

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo ./install.sh"; exit 1; }

mkdir -p "$DEST" "$PCD"
install -m 0755 "$REPO/src/mux-setup.sh"            "$DEST/mux-setup.sh"
install -m 0755 "$REPO/src/plc-mux.pl"              "$DEST/plc-mux.pl"
install -m 0755 "$REPO/post-config.d/90-plc-mux.sh" "$PCD/90-plc-mux.sh"

# Guard against CRLF if the repo was ever touched on Windows.
sed -i 's/\r$//' "$DEST/mux-setup.sh" "$DEST/plc-mux.pl" "$PCD/90-plc-mux.sh"

cat <<'EOM'

Files installed.

One-time EdgeOS config for the HMI-side port (do NOT address eth1-eth4):

    configure
    set interfaces ethernet eth0 address 192.168.1.254/24
    set interfaces ethernet eth0 ip enable-proxy-arp
    commit ; save ; exit

Bring it up now (no reboot needed):

    sudo /config/scripts/post-config.d/90-plc-mux.sh

Verify:

    ip rule show | grep 192.168.1.160
    pgrep -af plc-mux.pl
    tail -n3 /var/log/plc-mux.log
EOM
