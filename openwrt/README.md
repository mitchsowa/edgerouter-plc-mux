# OpenWrt variant

Runs the same PLC multiplexer on an **EdgeRouter X flashed with OpenWrt** instead of
stock EdgeOS. The selector mechanism is identical (one `ip rule` at pref 100, per-port
routing tables 100-103, per-port SNAT to `192.168.1.1`, proxy-ARP for `192.168.1.160`
on `eth0`); only the OS plumbing differs. The UDP daemon (`../src/plc-mux.pl`) is shared
**unchanged** — it's pure-core Perl and OS-agnostic.

Tested on OpenWrt 21.02.3 (`ramips/mt7621`, `ubnt,edgerouter-x`).

## Why this exists

Reverting an ER-X from OpenWrt back to stock EdgeOS reliably needs a **serial console**
(button-only TFTP recovery is unreliable on the ER-X; an SSH-only in-place flash can't
reformat the UBI volume the running rootfs lives on). If the box already runs OpenWrt and
you have no serial adapter, porting the mux is the zero-risk path to a working unit.

## What differs from the EdgeOS build

- **Ports:** OpenWrt's DSA presents `eth0`-`eth4` as independent netdevs already — no
  switch/VLAN surgery. The default config bridges `eth1`-`eth4` into `br-lan`; the port
  roles get flipped to `eth0`=HMI, `eth1`-`eth4`=PLC (see `install.sh`).
- **Runtime deps (not in OpenWrt base), installed via opkg:**
  - `perlbase-essential perlbase-io perlbase-socket perlbase-posix` — the daemon.
  - `conntrack` — the switch-time flush (`conntrack -D -d .160`).
  - `ip-full` — busybox `ip` can't do `ip neigh ... proxy` (and policy routing is
    flaky); full iproute2 is required.
- **Data-plane script:** `mux-setup.sh` here is busybox-`sh` (no bash arrays).
- **Boot:** a procd init service (`plc-mux.init` -> `/etc/init.d/plc-mux`, `START=99`)
  runs `mux-setup.sh` then supervises the daemon with `respawn`. Replaces the EdgeOS
  `post-config.d` launcher.
- **Logs:** daemon output goes to the system log — `logread -e plc-mux` (not a file).
- **Firewall/DHCP:** OpenWrt's `firewall`, `dnsmasq`, `odhcpd` are disabled — this is a
  dedicated L3 appliance; fw3's zones would block forwarding and the unzoned mgmt port.

## Files

- `mux-setup.sh` — busybox-sh data plane (mirrors `../src/mux-setup.sh`).
- `plc-mux.init` — procd init service.
- `install.sh` — installs deps + files, enables the service, prints the one-time `uci`
  network config.
- daemon: `../src/plc-mux.pl` (shared, unchanged).

## Install

```sh
git clone <this-repo> && cd edgerouter-plc-mux
sh openwrt/install.sh          # on the router, as root
```
Then apply the one-time `uci` network config it prints.

## Gotchas hit during commissioning

- **Don't share a switch between `eth0` and `eth1`-`eth4` once the mux runs.** With
  proxy-ARP on `eth0` and `192.168.1.1/32` on the PLC ports, putting two of them on one
  unmanaged switch makes the box answer ARP for the same addresses on multiple ports →
  MAC flapping → intermittent connectivity. Each PLC needs its own port/segment (which is
  the whole point of the mux). A switch on `eth0` for HMI + management is fine.
- **Apply the network flip from an `eth0`/`.254` session,** not via `br-lan`/`.1` — removing
  `br-lan` drops the `.1` path. Leaving both `br-lan` and `eth0` with a `.../24` creates two
  competing connected routes; remove `br-lan`.
- **Stale SSH host key:** if this box reuses an IP that previously hosted a different unit
  (e.g. the EdgeOS box at `.254`), clear it: `ssh-keygen -R 192.168.1.254`.
- **`opkg` over HTTPS** needs `libustream-ssl`/ca-certs the base image lacks; switching the
  feeds in `/etc/opkg/distfeeds.conf` to `http://` lets `opkg update` work offline-ish.
- **No `timeout`/serial recovery net:** verify changes are reachable before relying on them;
  the procd service auto-respawns the daemon but a bad network commit needs failsafe to undo.
