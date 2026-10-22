#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041

"""Read an event log and pair its events the way the anchors ask.

    python3 tools/timing/events.py build/timing-25-40.log

Carried over from RD68031. The log is what sim/tb/rd68041_timing_tb.sv emits:
the clock (period and high time), a few facts about the run, then scenarios --
a marker, then one line per transition giving the time, the clock edge it
happened on, and the event's name -- and the input probes. Nothing in it knows
what a specification is.

THE PAIRING RULE, stated once because every separation depends on it: an
occurrence of `a` is paired with the **first occurrence of `b` strictly later in
the log**. That one rule covers every shape a separation comes in -- from an
edge inside the core to a pin (clk.bb_rel to bb.hiz), from a sample to a pin
(smp.rdend to dout.drive), from a stimulus to a sample (in.rsti.negate to
smp.mode) -- and it is why each scenario is a separate stretch of the log: a
read's end must never pair with a snooped transfer's data. "Strictly later in
the log", not in time: the testbench writes a clock edge's internal events
(smp.*, clk.*) before the pins that move on it, so a sample pairs with a pin on
its own edge, and it may write an event after another whose time is later --
smp.mode is written once the reset is over, with the time of the edge that
captured the modes -- so a separation can be negative.
"""

import sys


class Event(object):
    __slots__ = ('t', 'edge', 'name', 'idx')

    def __init__(self, t, edge, name, idx):
        self.t = t
        self.edge = edge
        self.name = name
        self.idx = idx

    def __repr__(self):
        return '%s@%.1f%s' % (self.name, self.t, self.edge)


class Probe(object):
    """One input probe: the same input changed off_b and off_a ns from an edge
    of kind `edge`, and what the core did each time."""
    __slots__ = ('name', 'edge', 'off_b', 'off_a', 'out_b', 'out_a')

    def __init__(self, f):
        self.name = f[1]
        self.edge = f[2]
        self.off_b, self.off_a, self.out_b, self.out_a = [float(x) for x in f[3:7]]

    @property
    def split(self):
        """The two runs differed: the core sampled inside (off_b, off_a]."""
        return abs(self.out_b - self.out_a) > 1e-6


class Log(object):
    def __init__(self):
        self.period = None
        self.high = None      # BCLK high time, the C line's second field
        self.path = None
        self.facts = {}
        self.scen = {}
        self.probes = {}

    def get(self, scen, default=None):
        return self.scen.get(scen, [] if default is None else default)


def read(path):
    out = Log()
    out.path = path
    cur = None
    with open(path) as fh:
        for line in fh:
            f = line.split()
            if not f:
                continue
            if f[0] == 'C':
                out.period = float(f[1])
                out.high = float(f[2]) if len(f) > 2 else out.period / 2.0
            elif f[0] == 'H':
                out.facts[f[1]] = f[2]
            elif f[0] == 'S':
                cur = f[1]
                out.scen.setdefault(cur, [])
            elif f[0] == 'T':
                if cur is None:
                    raise SystemExit('events: a transition before any scenario')
                lst = out.scen[cur]
                lst.append(Event(float(f[1]), f[2], f[3], len(lst)))
            elif f[0] == 'P':
                p = Probe(f)
                out.probes[p.name] = p
    return out


def occurrences(events, name):
    return [e for e in events if e.name == name]


def pairs(events, a, b):
    """Every (a, b) the pairing rule gives, in order."""
    out = []
    bs = occurrences(events, b)
    for ea in occurrences(events, a):
        # the first b strictly after this a in the log
        k = 0
        while k < len(bs) and bs[k].idx <= ea.idx:
            k += 1
        if k < len(bs):
            out.append((ea, bs[k]))
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    log = read(sys.argv[1])
    print('clock %.3f ns, %.3f ns high; %s' % (log.period or 0.0, log.high or 0.0,
                                 ', '.join('%s=%s' % kv for kv in sorted(log.facts.items()))))
    for scen in sorted(log.scen):
        evs = log.scen[scen]
        print('%s: %d events, %.1f ns to %.1f ns'
              % (scen, len(evs), evs[0].t if evs else 0, evs[-1].t if evs else 0))
        names = {}
        for e in evs:
            names[e.name] = names.get(e.name, 0) + 1
        for n in sorted(names):
            print('    %-16s %d' % (n, names[n]))
    for name in sorted(log.probes):
        p = log.probes[name]
        print('probe %-18s CLK%s  %+.1f -> %g   %+.1f -> %g   %s'
              % (name, p.edge, p.off_b, p.out_b, p.off_a, p.out_a,
                 'sampled in between' if p.split else 'NOT SAMPLED THERE'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
