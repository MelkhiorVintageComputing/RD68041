#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041

"""What each MC68040 / MC68LC040 specification measures, and between which events.

    python3 tools/timing/anchors.py              # the table
    python3 tools/timing/anchors.py --unanchored # what is not measured, and why
    python3 tools/timing/anchors.py --pending    # what is not measured YET

Retargeted from RD68031's tools/timing/anchors.py. UM section 11's Figures 11-3
to 11-7 (redrawn in MC68040UM_split/figure-11-0*.svg) draw each limit as a
callout between a BCLK rising edge and a pin, or between RSTI and a mode
select. This module is that reading, written down. Every specification is one
of these:

PAD     a budget on one pad delay: "BCLK to Address Valid", 9..21 ns.
SEP     a required separation between two events, each a pin of the core (with
        its pad delay), an input as a device moves it, or an edge inside the
        core (neither of which has one).
INPUT   an input's setup or hold window, which the edge the core samples that
        input on must lie inside -- found by the probes of rd68041_timing_tb.
DIRECT  the clock, checked against the run's own period and high time.

and then three lists that are not measurements, each entry with its reason:

UNANCHORED  a real specification that is not a question about this core: PCLK
            (not used), the clock's own edges, the multiplexed and DLE modes
            (not built).
PENDING     a question about this core that cannot be asked yet, because the
            logic it is about does not exist -- IPL's synchroniser, CDIS and
            MDIS during normal operation, IPEND and RSTO. Each names the
            milestone that brings it and the probe or event that will anchor
            it; the analysis prints every pending specification on every run,
            never counts one as measured, and FAILS if the log already holds
            the evidence a pending entry is waiting for (so that a pending
            entry cannot outlive its reason).
PARTIAL     a specification that names a pin this analysis cannot see, and
            what covers that pin.

`check_complete` fails if a specification of either device is in none of them.

THE MC68040 IS SYNCHRONOUS. Almost every limit in UM 11 is "BCLK to <pin>"
or "<input> to BCLK": a pad budget or a sampling window around a rising edge.
The handful of separations are the ones where something other than one rising
edge is involved: the late release of BB, TA and TIP half a clock after the
edge that negates them (39, from the edge to the falling-edge release); the
processor's side of a device's limit (17, 49); and the mode selects around
RSTI (53, 54), which are measured from RSTI, not from the clock (Figure 11-2,
note 3).

EVENTS. `<pin>.<what>` is a pin of the core, with a pad delay. `in.<pin>.<what>`
is an input as the testbench drives it, and `smp.<what>` and `clk.<what>` are
clock edges inside the core -- no pad delay. The vocabulary is fixed here and in
sim/tb/rd68041_timing_tb.sv, and nothing else may invent one:

    addr.{drive,valid,invalid,hiz}   A31-A0 and every transfer attribute UM 11
                                     names with them (TT, TM, TLN, UPA, R/W, SIZ,
                                     LOCK, LOCKE, CIOUT), which move together
    ts, tip, bb, ta .{drive,assert,negate,hiz}
    dout.{drive,valid,invalid,hiz}   D31-D0 as the core drives them
    br, mi .{assert,negate}          always driven
    smp.rdend    the edge a read's last TA is sampled on
    smp.bbfree   the edge the core sampled BB negated, with BG, and took the bus
    smp.mode     the edge rd68041_rstctl captured the mode selects on
    clk.{bb,tip,ta}_rel   the rising edge whose late-release register drops:
                          the pin is negated there and released half a clock on
    in.rsti.negate        RSTI negated by the testbench
"""

import argparse
import os
import sys

R = 'R'   # the transition happens on a rising clock edge
F = 'F'   # ... or a falling one

# Each scenario is one stretch of the log, recorded separately, so that the
# pairing rule never reaches from one kind of cycle into another.
MASTER = ['read', 'write', 'mixed', 'line', 'error', 'arb']
SCENARIOS = MASTER + ['snoop', 'reset']
ALL = SCENARIOS
WRITES = ['write', 'mixed', 'line', 'error']


def scenarios_for(tag):
    if isinstance(tag, (list, tuple)):
        return list(tag)
    return [tag]


# --------------------------------------------------------------------------
# Pad-delay budgets: "BCLK to <pin> <transition>", all from the rising edge.
# A design that moves the pin on the other edge is not merely slow, it is
# judged against the wrong edge -- and the analyser says so.
# --------------------------------------------------------------------------
PAD = [
    # key,  events,                                                   edge, scenarios
    ('11',  ['addr.valid'],                                            R, ALL),
    # Output hold: the old level stays at least this long after the edge, on
    # every output Figures 11-3 to 11-7 mark 12 on.
    ('12',  ['addr.invalid', 'ts.assert', 'ts.negate', 'tip.assert',
             'tip.negate', 'bb.assert', 'bb.negate', 'br.assert', 'br.negate',
             'mi.assert', 'mi.negate', 'ta.assert', 'ta.negate'],      R, ALL),
    ('13',  ['ts.assert', 'ts.negate'],                                R, ALL),
    ('14',  ['tip.assert', 'tip.negate'],                              R, ALL),
    ('18',  ['dout.valid'],                                            R, ALL),
    ('19',  ['dout.invalid'],                                          R, ALL),
    # Output low impedance (notes 3 and 4: the address and data bus); the
    # other three-state outputs going driven are held to it too.
    ('20',  ['addr.drive', 'ts.drive', 'tip.drive', 'bb.drive', 'ta.drive',
             'dout.drive'],                                            R, ALL),
    ('21',  ['dout.hiz'],                                              R, ALL),
    ('38',  ['addr.hiz', 'ts.hiz'],                                    R, ALL),
    ('40',  ['br.assert', 'br.negate', 'bb.assert', 'bb.negate'],      R, ALL),
    ('43',  ['mi.assert', 'mi.negate'],                                R, ALL),
    ('48',  ['ta.assert', 'ta.negate'],                                R, ['snoop']),
]


# --------------------------------------------------------------------------
# Bounds that are not the specification's own (lo, hi): the processor's side
# of a requirement on a device, and the mode selects. Each takes the table and
# a column and returns (lo, hi) in nanoseconds.
# --------------------------------------------------------------------------
def _dev(key):
    """The device may take up to spec `key`'s maximum, so the core must wait
    at least that long."""
    def f(S, col):
        return (S[key].ns(col)[1], None)
    f.__doc__ = 'max(%s)' % key
    return f


def _setup_before(key):
    """The core's instant may be no earlier than min(key) before the event."""
    def f(S, col):
        return (-S[key].ns(col)[0], None)
    f.__doc__ = '>= -min(%s)' % key
    return f


def _hold_after(key):
    """... and no later than min(key) after it."""
    def f(S, col):
        return (None, S[key].ns(col)[0])
    f.__doc__ = '<= min(%s)' % key
    return f


# --------------------------------------------------------------------------
# Separations. Each pairs an occurrence of a with the next occurrence of b
# after it in the log.
# --------------------------------------------------------------------------
REL = ['arb', 'error', 'reset']
SEP = [
    # key,  a,                b,             scenarios,  bound
    #
    # 39: "BCLK to BB, TA, TIP High Impedance". The three pins are negated at a
    # rising edge and released half a clock later (UM 7.1: they "transition
    # from a driven state to a high-impedance state during T1"); the limit is
    # measured from the rising edge, so it is a separation from that edge --
    # an event inside the core -- to the release at the pin.
    ('39',  'clk.bb_rel',     'bb.hiz',      REL,        None),
    ('39',  'clk.tip_rel',    'tip.hiz',     REL,        None),
    ('39',  'clk.ta_rel',     'ta.hiz',      ['snoop'],  None),
    #
    # 17: a device may hold the data bus up to max(17) after the edge that
    # terminates a read (49 ns at 25 MHz: one clock and min(20), the earliest
    # the core itself would drive it), so the core must not drive it for a
    # write before then.
    ('17',  'smp.rdend',      'dout.drive',  ['mixed'],  _dev('17')),
    #
    # 49: an alternate master may take up to max(49) after the edge at which
    # the core sees its BB negated to stop driving BB; the core must not drive
    # BB before then.
    ('49',  'smp.bbfree',     'bb.drive',    ['arb'],    _dev('49')),
]

# --------------------------------------------------------------------------
# Where the core samples its inputs. Each row names the probes (the P lines)
# whose sampling instant must lie inside the specification's window around a
# rising edge: 'setup' checks the instant is no earlier than min(spec) before
# the edge, 'hold' no later than min(spec) after it, 'split' only that the
# probe split -- that the core samples there at all.
# --------------------------------------------------------------------------
TERM = ['ta', 'ta_snoop', 'tea', 'tci', 'tbi']
SNOOP_ATTR = ['snoop_a', 'snoop_siz', 'snoop_tt', 'snoop_rw', 'snoop_sc']
MODES = ['mode_cdis', 'mode_mdis', 'mode_ipl']

INPUT = [
    # key,   probes,                         edge, side
    ('15',   ['data_read', 'data_sink'],      R,   'setup'),
    ('16',   ['data_read', 'data_sink'],      R,   'hold'),
    ('22a',  ['ta', 'ta_snoop'],              R,   'setup'),
    ('22b',  ['tea'],                         R,   'setup'),
    ('22c',  ['tci'],                         R,   'setup'),
    ('22d',  ['tbi'],                         R,   'setup'),
    ('23',   TERM,                            R,   'hold'),
    ('24',   ['avec'],                        R,   'setup'),
    ('25',   ['avec'],                        R,   'hold'),
    ('41a',  ['bb'],                          R,   'setup'),
    ('41b',  ['bg'],                          R,   'setup'),
    ('42',   ['bb', 'bg'],                    R,   'hold'),
    ('44a',  ['snoop_a'],                     R,   'setup'),
    ('44b',  ['snoop_siz'],                   R,   'setup'),
    ('44c',  ['snoop_tt'],                    R,   'setup'),
    ('44d',  ['snoop_rw'],                    R,   'setup'),
    ('44e',  ['snoop_sc'],                    R,   'setup'),
    ('45',   SNOOP_ATTR,                      R,   'hold'),
    ('46',   ['snoop_ts'],                    R,   'setup'),
    ('47',   ['snoop_ts'],                    R,   'hold'),
    ('51',   ['rsti'],                        R,   'setup'),
    ('52',   ['rsti'],                        R,   'hold'),
]

# The clock: the run's own period, duty cycle and pulse widths (the C line).
DIRECT = {
    '5':  'period',
    '8':  'duty',
    '8a': 'high',
    '8b': 'low',
}

# --------------------------------------------------------------------------
# What this analysis is not about, and why. Every one of these is a real
# specification; none of them is a question about this design.
# --------------------------------------------------------------------------
_PCLK = ('PCLK, which this design does not use: the core runs on BCLK alone '
         '(CLAUDE.md, doc/timing-divergences.md), and the pin is sunk')
_MUX = ('the multiplexed bus mode (UM 7.11.2), which this design does not build: '
        'doc/divergences.md, "Only the normal bus and data-latch modes are built"')
_DLE = ('the data latch enable mode (UM 7.11.3), which this design does not build '
        '(doc/divergences.md); DLE is sunk')
_MODES = ('the mode selects sampled at reset (UM 7.10, 7.11): the modes are not '
          'built, and rd68041_rstctl records their levels a clock late at worst, '
          'for a report only -- doc/divergences.md, "The mode selects are '
          'recorded, not met"')
UNANCHORED = {
    '1':   _PCLK,
    '2':   _PCLK,
    '3':   _PCLK,
    '4':   _PCLK,
    '4a':  _PCLK,
    '4b':  _PCLK,
    '10':  _PCLK,
    '6,7': ('BCLK rise and fall times: a property of the system\'s clock; an '
            'RTL model has no edge ramps'),
    '9':   ('frequency stability: a property of the system\'s oscillator, and '
            'what the MC68040 needs it for is its PLL, which this design does not '
            'have'),
    '26':  _MUX, '27': _MUX, '28': _MUX, '29': _MUX, '30': _MUX,
    '31':  _DLE, '32': _DLE, '33': _DLE, '34': _DLE, '35': _DLE, '36': _DLE,
    '37':  _DLE,
    # Measured at M3 and found unmeetable by any rising-edge capture: the
    # window is timed from RSTI's own edge, which is asynchronous to BCLK, and
    # is 22 ns wide, less than a clock at every grade. The modes it selects are
    # not built, so what is captured is only reported (doc/divergences.md).
    '53':  _MODES,
    '54':  _MODES,
}

# --------------------------------------------------------------------------
# Not anchored YET. (milestone, reason, evidence): the evidence is the probe
# or event names that will anchor the specification, and the analysis fails if
# any of them is already in the log.
# --------------------------------------------------------------------------
PENDING = {
    '41c': ('M9 (CDIS) and M10 (MDIS)',
            'CDIS and MDIS are sampled during normal operation by the caches and '
            'the MMU, which do not exist yet; nothing samples them outside reset, '
            'where they are mode selects and are measured by 53 and 54',
            ['cdis', 'mdis']),
    '41d': ('M8',
            'IPL2-IPL0 go through a synchroniser to the interrupt logic, and '
            'neither exists yet; rd68041_rstctl reads IPL only as a mode select '
            'at reset (53, 54)',
            ['ipl']),
    '42':  ('M8 (IPL), M9 (CDIS), M10 (MDIS)',
            'the hold of BB and BG is measured; that of CDIS, MDIS and IPL2-IPL0 '
            'waits for the logic that samples them, as 41c and 41d do',
            ['cdis', 'mdis', 'ipl']),
    '50':  ('M7 (RSTO, the RESET instruction) and M8 (IPEND)',
            'IPEND and RSTO are constants in rd68041_top until the core drives '
            'them; PST3-PST0 is stubbed (a constant, doc/pinout.md), and a pin '
            'that never moves cannot violate 50',
            ['ipend.assert', 'ipend.negate', 'rsto.assert', 'rsto.negate']),
    '12':  ('M7 and M8',
            'the output hold of every bus pin is measured; that of IPEND and RSTO, '
            'which Figure 11-7 also marks 12 on, waits for them to move, as 50 does',
            ['ipend.assert', 'ipend.negate', 'rsto.assert', 'rsto.negate']),
}

# Specifications that cover a pin this analysis cannot see, and what covers it.
PARTIAL = {
    '11': ('the MC68LC040\'s 11 also names PSTx: stubbed, a constant '
           '(doc/pinout.md), so it never moves and cannot violate it'),
}


def _evs():
    out = set()
    for _, evs, _, _ in PAD:
        out.update(evs)
    for row in SEP:
        out.add(row[1])
        out.add(row[2])
    return sorted(out)


EVENTS = _evs()


def anchored_keys():
    keys = set(k for k, _, _, _ in PAD)
    keys |= set(row[0] for row in SEP)
    keys |= set(k for k, _, _, _ in INPUT)
    keys |= set(DIRECT)
    return keys


def check_complete(specs_by_device):
    """Every specification of every device is anchored, explained or pending,
    and nothing names a specification that no device has. A fully pending
    specification (pending and not anchored) is allowed; one both anchored and
    unanchored is not."""
    anchored = anchored_keys()
    every = set()
    for S in specs_by_device.values():
        every |= set(S)
    missing = []
    for dev, S in sorted(specs_by_device.items()):
        for k in S:
            if k not in anchored and k not in UNANCHORED and k not in PENDING:
                missing.append((dev, k))
    stale = [k for k in anchored | set(UNANCHORED) | set(PENDING) | set(PARTIAL)
             if k not in every]
    stale += [k for k in UNANCHORED if k in anchored or k in PENDING]
    return missing, sorted(set(stale))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--unanchored', action='store_true')
    ap.add_argument('--pending', action='store_true')
    args = ap.parse_args()

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import specs as specs_mod
    allspecs = specs_mod.load_all()
    S40 = allspecs['MC68040']

    def ch(key):
        for d in specs_mod.DEVICES:
            if key in allspecs[d]:
                return allspecs[d][key].characteristic
        return '?'

    if args.unanchored:
        for key, why in sorted(UNANCHORED.items()):
            print('%-6s %-48s %s' % (key, ch(key)[:48], why))
        for key, why in sorted(PARTIAL.items()):
            print('%-6s %-48s (partly) %s' % (key, ch(key)[:48], why))
    elif args.pending:
        for key, (ms, why, ev) in sorted(PENDING.items()):
            print('%-6s %-44s %s%s -- %s' % (key, ch(key)[:44], ms,
                                             ' (partly)' if key in anchored_keys()
                                             else '', why))
    else:
        print('# pad-delay budgets')
        for key, evs, edge, scen in PAD:
            print('  %-5s %-4s %-44s %s'
                  % (key, 'CLK' + edge, ','.join(evs)[:44], ch(key)[:40]))
        print('# separations')
        for key, a, b, scen, bound in SEP:
            print('  %-5s %-15s -> %-11s %s'
                  % (key, a, b, bound.__doc__ if bound else ch(key)[:44]))
        print('# input sampling windows')
        for key, probes, edge, side in INPUT:
            print('  %-5s CLK%s %-5s %s' % (key, edge, side, ', '.join(probes)))
        print('# the clock')
        for key, what in sorted(DIRECT.items()):
            print('  %-5s the clock\'s %s' % (key, what))

    missing, stale = check_complete(allspecs)
    if missing:
        print('\nFAIL: %d specifications are neither anchored, explained nor '
              'pending: %s' % (len(missing), ', '.join('%s %s' % m for m in missing)))
        return 1
    if stale:
        print('\nFAIL: anchors or exclusions that name no specification, or that '
              'both anchor and exclude one: %s' % ', '.join(stale))
        return 1
    for d in specs_mod.DEVICES:
        S = allspecs[d]
        a = len([k for k in S if k in anchored_keys()])
        p = len([k for k in S if k in PENDING and k not in anchored_keys()])
        u = len([k for k in S if k in UNANCHORED])
        print('%s: %d specifications: %d anchored (%d of them partly pending), '
              '%d pending, %d not about this design'
              % (d, len(S), a, len([k for k in S if k in PENDING and
                                     k in anchored_keys()]), p, u))
    return 0


if __name__ == '__main__':
    sys.exit(main())
