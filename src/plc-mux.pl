#!/usr/bin/perl
# plc-mux.pl - UDP-driven selector for the EdgeRouter X IDEC PLC multiplexer.
#
# Listens for a selector (1-4) and repoints the virtual 192.168.1.160 at the
# matching PLC port by rewriting a single policy-routing rule. A selector of 0
# (the IDEC HMI's power-on default) maps to PLC #1 so the HMI's initial TCP link
# comes up instead of being rejected. A repeat of the already-active selection is
# a true no-op (no rule churn, no session drop), so an HMI that resends the
# current selection as a heartbeat won't glitch the link.
#
# Pure-core Perl, no CPAN. See README.md for the full design.
use strict;
use warnings;
use Socket;
use IO::Socket::INET;
use POSIX qw(strftime);

my $PORT     = 5150;
my $BIND     = '0.0.0.0';   # all interfaces: accepts unicast AND broadcast HMIs
my $PLC_IP   = '192.168.1.160';
my $BASE_TBL = 100;         # PLC #N -> table BASE_TBL + N - 1
my $NUM_PLC  = 4;
my $ACK      = 1;           # send a one-line UDP reply confirming the switch

$| = 1;

my $sock = IO::Socket::INET->new(
    LocalAddr => $BIND,
    LocalPort => $PORT,
    Proto     => 'udp',
    Broadcast => 1,
) or die "plc-mux: bind $BIND:$PORT failed: $!\n";

# Sync with whatever PLC is already selected so the no-op guard holds even
# across a daemon restart.
my $active = current_selection();
logmsg("listening on $BIND:$PORT; active PLC #" . ($active || '?'));

while (1) {
    my $data;
    my $paddr = $sock->recv($data, 64);
    next unless defined $paddr;
    my ($pport, $pip) = sockaddr_in($paddr);
    my $from = inet_ntoa($pip);

    # Accept an ASCII digit ("2", "2\n", ...) or a raw byte (0x02). $sel is the
    # value as received; $n is what we act on.
    my $sel;
    if    ($data =~ /([0-9])/)  { $sel = $1 + 0; }
    elsif (length $data)        { $sel = ord substr($data, 0, 1); }

    # The IDEC HMI emits 0 (ASCII '0') as its power-on default while it brings up
    # the TCP link to .160, before the operator picks a unit. Map 0 -> PLC #1 so
    # that link comes up (and stale .160 flows get flushed) instead of being
    # rejected, which left the HMI giving up before a unit could be selected.
    # Safe only because the HMI heartbeats its *selected* unit (1-4), not 0, once
    # the operator has chosen one; if it ever re-sent 0 mid-session it would snap
    # the selection back to PLC #1.
    my $n = (defined $sel && $sel == 0) ? 1 : $sel;

    unless (defined $n && $n >= 1 && $n <= $NUM_PLC) {
        logmsg("ignored bad selector from $from");
        $sock->send("err", 0, $paddr) if $ACK;
        next;
    }

    # Log the raw selector so a wire-0 default is distinguishable from a real 1.
    my $how = ($sel == $n) ? "selector $n" : "selector $sel (default -> PLC #$n)";

    if (defined $active && $n == $active) {
        logmsg("$how from $from (already active, no-op)");
        $sock->send("ok $n", 0, $paddr) if $ACK;
        next;
    }

    select_plc($n);
    $active = $n;
    logmsg("$how from $from -> table " . ($BASE_TBL + $n - 1) . " (PLC #$n)");
    $sock->send("ok $n", 0, $paddr) if $ACK;
}

# Repoint the virtual PLC_IP at PLC #n and tear down stale flows so the HMI
# re-establishes against the newly selected unit.
sub select_plc {
    my $n = shift;
    my $table = $BASE_TBL + $n - 1;
    system("ip rule del to $PLC_IP 2>/dev/null");
    system("ip rule add to $PLC_IP lookup $table pref 100");
    system("conntrack -D -d $PLC_IP >/dev/null 2>&1");
}

# Derive the currently selected PLC number from the live policy rule, or 0 if
# none/unknown.
sub current_selection {
    for (`ip rule show 2>/dev/null`) {
        next unless /to \Q$PLC_IP\E\b.*lookup (\d+)/;
        my $t = $1;
        return $t - $BASE_TBL + 1 if $t >= $BASE_TBL && $t < $BASE_TBL + $NUM_PLC;
    }
    return 0;
}

sub logmsg {
    print STDERR strftime("%Y-%m-%d %H:%M:%S", localtime), " plc-mux: $_[0]\n";
}
