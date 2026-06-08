# CLAUDE.md

Context for working on this repo with Claude Code.

## What this is

A UDP-controlled multiplexer on an EdgeRouter X that presents four identical IDEC
PLCs (all hard-set to `192.168.1.160`) to a single HMI, one at a time. A UDP
datagram to port 5150 (payload 1-4) selects which PLC is live. See README.md for
the user-facing design.

## Target platform

- Ubiquiti EdgeRouter X, EdgeOS (Debian-based, MIPS / mipsel, MT7621).
- Code runs on the router. Perl is stock; `conntrack` is normally present.
- Keep dependencies to what ships on EdgeOS: bash, busybox, iproute2, iptables,
  perl core (no CPAN). Do not introduce Python or compiled binaries — cross-compiling
  for mipsel is not worth it for this tool.

## Files

- `src/mux-setup.sh` — builds the data plane (idempotent). Owns `eth1`-`eth4`
  addressing; assigns `eth0` `.254/24`; sets proxy ARP; creates per-port routing
  tables 100-103; installs per-port SNAT; sets the default selection (PLC #1).
- `src/plc-mux.pl` — UDP daemon. Binds `0.0.0.0:5150` (unicast + broadcast),
  rewrites the single `ip rule to 192.168.1.160 lookup 10N` on each selector,
  flushes conntrack, ACKs `ok N`. Has a no-op guard for repeats of the active PLC,
  and syncs `$active` from the live rule on startup.
- `post-config.d/90-plc-mux.sh` — boot launcher. Runs `mux-setup.sh`, then starts
  the daemon detached. Goes in `/config/scripts/post-config.d/`.
- `install.sh` / `uninstall.sh` — deploy/remove. Run as root on the router.

## Hard invariants (do not break)

1. The router must **never own `192.168.1.160`**. If `.160` is assigned to any
   interface, the kernel `local` table delivers it locally and forwarding breaks.
   Proxy ARP (`ip neigh ... proxy`) is how the router answers for `.160`.
2. `eth0` carries exactly one address: `192.168.1.254/24`.
3. PLC ports use `192.168.1.1/32` (host route), never a `/24`, to avoid a four-way
   connected-route conflict in the main table.
4. The selection mechanism is **one** `ip rule` at pref 100. Don't add more rules
   for this; rewrite the one.
5. `eth1`-`eth4` must not be in a hardware switch/bridge (`master`).

## Config knobs

Both scripts hardcode the addressing at the top. If these change, change them in
*both* `mux-setup.sh` and `plc-mux.pl`: `PLC_IP` (192.168.1.160), `SNAT_IP`
(192.168.1.1), HMI address (192.168.1.254), `BASE_TBL`/`BASE_TABLE` (100), port
`PORT` (5150), PLC count (4). A future improvement would be a single sourced config
file; not done yet.

## Testing

No CI; tested live on hardware. Quick checks that work in any Linux shell:

```sh
perl -c src/plc-mux.pl
bash -n src/mux-setup.sh post-config.d/90-plc-mux.sh
```

On the router, functional loopback test:

```sh
perl -MIO::Socket::INET -e '$s=IO::Socket::INET->new(PeerAddr=>"127.0.0.1:5150",Proto=>"udp");$s->send("2");$s->recv($r,16);print "$r\n"'
ip rule show | grep 192.168.1.160   # expect lookup 101
```

## Known gotchas (already hit during commissioning)

- An earlier design assigned `.160` to `eth0` — broke forwarding (see invariant 1).
- The HMI sends by **broadcast** (`192.168.1.255:5150`), which is why the daemon
  binds `0.0.0.0` with `Broadcast => 1` rather than the specific `.254`.
- Binding `0.0.0.0` can source the ACK from the "wrong" interface on a multi-homed
  box; the current HMI doesn't check the ACK so it hasn't mattered. If a future HMI
  needs a correctly-sourced reply, set the reply source explicitly.
- EdgeOS won't accept the same `.1` on four interfaces via the CLI — that's why the
  PLC-port addressing is done in the script, not the structured config.

## Style

- POSIX-ish bash, idempotent (re-running install or setup is safe).
- Perl: `use strict; use warnings;`, core modules only.
- Comments explain *why* (the routing trick), not *what*.
