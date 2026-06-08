#!/bin/bash
# /config/scripts/post-config.d/90-plc-mux.sh
# Runs after EdgeOS applies its config on every boot. Brings up the data
# plane and (re)launches the UDP selector daemon detached.
DIR=/config/user-data/plc-mux

/bin/bash "$DIR/mux-setup.sh"

if ! pgrep -f plc-mux.pl >/dev/null 2>&1; then
    setsid /usr/bin/perl "$DIR/plc-mux.pl" >> /var/log/plc-mux.log 2>&1 &
    logger -t plc-mux "daemon started"
fi
