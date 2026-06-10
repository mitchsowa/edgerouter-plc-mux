# edgerouter-plc-mux

A UDP-controlled selector that lets a single HMI talk to one of four **identical**
IDEC PLCs — all hard-set to the same IP address `192.168.1.160` — through an
EdgeRouter X, one PLC at a time. A UDP message picks which PLC is "live."

```
                        EdgeRouter X
                   +---------------------+
   HMI / SCADA --- | eth0  192.168.1.254 |
   192.168.1.25    |  (answers .160 via  |
                   |   proxy ARP)        |
                   |                     |--- eth1 --- PLC #1  192.168.1.160
                   |   policy routing    |--- eth2 --- PLC #2  192.168.1.160
                   |   picks one port    |--- eth3 --- PLC #3  192.168.1.160
                   |                     |--- eth4 --- PLC #4  192.168.1.160
                   +---------------------+

   HMI -> UDP :5150 payload "1".."4"  =>  router repoints .160 at that PLC
```

The HMI is configured once to talk to `192.168.1.160`. To switch units it sends a
single UDP datagram to port `5150` containing the PLC number (ASCII digit `1`-`4`
or a raw byte `0x01`-`0x04`), by unicast to the router or by subnet broadcast.

## Why it's built this way

Four devices sharing one IP can't coexist on a single L2/L3 segment — the address
is ambiguous, so the *only* thing that disambiguates a PLC is the physical port it's
on. The router therefore:

- **Never owns `.160`.** `eth0` carries `192.168.1.254/24` and answers ARP for `.160`
  on the HMI segment via proxy ARP, so the HMI thinks it's talking straight to the
  PLC while every frame is actually forwarded.
- **Gives each PLC port its own routing table** (100-103), each holding exactly one
  route: `192.168.1.160 dev ethN`. The PLC-facing ports carry `192.168.1.1/32`
  (host address, so four ports don't fight over one connected `/24`).
- **Selects with a single policy rule**: `ip rule ... to 192.168.1.160 lookup 10N`.
  That one rule is the entire switch; the daemon rewrites it on each UDP selector.
- **SNATs** the HMI's source to `192.168.1.1` on the way out so the PLC can reply
  into its own subnet, and **flushes conntrack** to `.160` on each switch so the
  HMI's session re-establishes against the newly selected unit.

> Running OpenWrt on the ER-X instead of stock EdgeOS? See [`openwrt/`](openwrt/) for a
> port that runs the same mux on OpenWrt (procd service, busybox-sh setup, opkg deps).

## Requirements

- Ubiquiti EdgeRouter X on EdgeOS (v1.10+ or v2.x; `post-config.d` support).
- `eth1`-`eth4` must be **independent routed ports**, not members of a hardware
  switch/bridge. Check with `ip -br link show | grep -i master` — it must return
  nothing.
- Perl (stock on EdgeOS) and `conntrack` (used by the firewall; usually present).

## Wiring / port map

| Port | Role                         |
|------|------------------------------|
| eth0 | HMI / SCADA + UDP control    |
| eth1 | PLC #1                       |
| eth2 | PLC #2                       |
| eth3 | PLC #3                       |
| eth4 | PLC #4                       |

To change the mapping, edit `PLC_IFS` in `src/mux-setup.sh` (index 0 = PLC #1).
Selector `N` always maps to PLC #N regardless of which port you assign it.

> Note: on the EdgeRouter X, `eth0` is the PoE-input port. Fine for data; just be
> aware of what you plug in there.

## Install

```sh
git clone <this-repo> edgerouter-plc-mux
cd edgerouter-plc-mux
sudo ./install.sh
```

Then apply the one-time EdgeOS config and bring it up with the launcher. `eth0` gets
`.254/24` + proxy ARP; `eth1`-`eth4` must carry **no** EdgeOS address (the script owns
their addressing). On a factory EdgeRouter X, `eth1` ships as the WAN port — it has
`address dhcp` plus the `WAN_IN`/`WAN_LOCAL` firewall. That **must** be cleared, or the
EdgeOS DHCP client keeps wiping the host address the script puts on `eth1`, leaving
table 100 empty so PLC #1 (the default) silently black-holes. `eth2`-`eth4` are bare by
default and need nothing.

```sh
configure
set interfaces ethernet eth0 address 192.168.1.254/24
set interfaces ethernet eth0 ip enable-proxy-arp
delete interfaces ethernet eth1 address          # drop the factory WAN dhcp
delete interfaces ethernet eth1 firewall         # drop WAN_IN / WAN_LOCAL
commit ; save ; exit
sudo /config/scripts/post-config.d/90-plc-mux.sh
```

Everything lives under `/config`, which survives reboots and firmware upgrades;
`post-config.d/90-plc-mux.sh` re-runs the data plane and relaunches the daemon on
every boot.

## Verify

```sh
ip addr show eth0                      # ONLY 192.168.1.254/24
ip neigh show proxy                    # 192.168.1.160 dev eth0 proxy
ip rule show | grep 192.168.1.160      # to 192.168.1.160 lookup 100
ip route show table 100                # 192.168.1.160 dev eth1 scope link
sudo iptables -t nat -S POSTROUTING | grep SNAT   # four eth1..eth4 rules
pgrep -af plc-mux.pl                    # running
tail -n3 /var/log/plc-mux.log          # listening on 0.0.0.0:5150
```

Self-contained functional test (runs on the router, needs only Perl):

```sh
perl -MIO::Socket::INET -e '$s=IO::Socket::INET->new(PeerAddr=>"127.0.0.1:5150",Proto=>"udp");$s->send("2");$s->recv($r,16);print "$r\n"'
# expect: ok 2   then ip rule show -> lookup 101
```

## HMI side

Point the HMI at `192.168.1.160` for normal traffic. To switch, send one UDP
datagram to port `5150` with payload `1`-`4`:

- Unicast to the router (`192.168.1.254:5150`), or
- Subnet broadcast (`192.168.1.255:5150`) — the daemon binds `0.0.0.0` and listens
  for both.

The daemon replies `ok N` (or `err`). Resending the current selection is a no-op:
no rule change, no session drop — safe to use as a heartbeat.

A selector of `0` (ASCII `'0'` or raw `0x00`) maps to **PLC #1**. This is for HMIs
(the commissioned IDEC unit among them) that emit `0` as a power-on default while
bringing up their TCP link to `.160`, before the operator picks a unit: rather than
reject it and leave the HMI unable to connect, the daemon brings up PLC #1 so the link
establishes and the operator can then select `1`-`4`. This is safe only because the HMI
heartbeats its *selected* unit (`1`-`4`) once chosen, never `0`.

## Troubleshooting

- **`eth0` shows `192.168.1.160` as a secondary** — fatal. The kernel `local` table
  delivers `.160` to the router instead of forwarding it. `eth0` must carry `.254`
  *only*. Remove any other addresses.
- **`eth1`-`eth4` in a switch/bridge** — all four PLCs share one wire and the
  duplicate IPs collide. Pull them out into independent routed ports.
- **One PLC dead, its table empty / port missing `192.168.1.1/32`** — that port still
  has an EdgeOS-assigned address. Most often it's `eth1`, which ships as the factory
  WAN (`address dhcp`): EdgeOS's DHCP client owns the interface and flushes the host
  address the script adds, taking the table's route with it. `delete interfaces
  ethernet ethN address` (and any `firewall`) in `configure`, commit, then re-run
  `mux-setup.sh`. Confirm with `ip -br addr show ethN` and `ip route show table 10N`.
- **Selector ignored, nothing in the log** — packets aren't reaching the daemon.
  `sudo tcpdump -ni eth0 udp port 5150` and check the destination. If a firewall
  `LOCAL` policy is dropping them, allow `udp/5150`. (On EdgeOS, `sudo timeout` is
  unavailable — bound a capture with tcpdump's `-c N`, not `timeout`.)
- **Log says `ignored bad selector`** — the datagram arrives but the payload is out of
  range. The daemon accepts ASCII `0`-`4` or raw `0x00`-`0x04` (`0` → PLC #1); anything
  else (e.g. `5`-`9`, or a non-digit) is rejected. Point the HMI at a valid selector.
- **Switch works but HMI clings to the old PLC** — `conntrack` userspace tool
  missing, so old flows aren't torn down. `which conntrack`.
- **Everything gone after reboot** — a file landed outside `/config`. All three
  files must be under the paths `install.sh` uses.
- **Log timestamps wrong (year 2014, etc.)** — NTP hasn't synced. Cosmetic.

## Limitations

- The PLC sees the client as `192.168.1.1`, not the HMI's real address (SNAT is
  unavoidable here). Fine for Modbus/IDEC; if you need the real source, put the HMI
  in a different subnet.
- Switching tears down the live session by design; the HMI reconnects to the new PLC.

## License

MIT — see [LICENSE](LICENSE).
