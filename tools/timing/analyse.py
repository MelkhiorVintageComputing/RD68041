#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041

"""Is there any pad-delay assignment that meets the MC68040's AC tables?

    python3 tools/timing/analyse.py --grade 25 build/timing-25-40.log build/timing-25-60.log
    python3 tools/timing/analyse.py --grade 25 --column 040-25L --verbose LOGS...
    python3 tools/timing/analyse.py --grade 25 --pad-skew 2 LOGS...
    python3 tools/timing/analyse.py --grade 25 --tie-edges LOGS...

Retargeted from RD68031's tools/timing/analyse.py. Builds the difference-
constraint system that anchors.py describes out of the times the testbench
recorded at one grade, and solves it against each column of that grade -- the
MC68040's large and small buffers and the MC68LC040. The answer is exact:
either an assignment exists, in which case one can be printed, or a set of
limits contradict each other, in which case those limits are printed.

SEVERAL LOGS, ONE SYSTEM. A grade is recorded more than once -- with BCLK high
for 40 % and for 60 % of the period, the two ends of specification 8 -- and
every log's constraints go into the same system over the same delay variables,
because a board's pads do not change with the clock's duty cycle. That matters
for exactly one thing in this design, the release of BB, TA and TIP on BCLK's
falling edge (specification 39).

THE PAD MODEL. Every pin transition has a delay variable, and the variables of
one pin launched from the same clock edge are tied to within --pad-skew (0 by
default: one delay). A pin's falling-edge transitions -- only the late
release of BB, TA and TIP -- come from a different register (the falling-edge
half of rd68041_late_release, through an OR into the pad's enable) and get a
delay of their own; --tie-edges ties those too, the strictest model, which is
what doc/ac-timing.md reports alongside. Every delay is at least zero.

Then the checks that are not about pad delays: that every input is sampled
inside its setup and hold window, on the edge the manual names; the clock; that
no pin of the core moved anywhere but on a clock edge; and that no PENDING
specification already has its evidence in the log. Any of them failing fails
the column, as does a specification the log gave nothing to measure, and a
pin that moved on the other edge from the one its specification is measured
from. A pending specification never fails a column and is never counted as
measured: every run prints it.

INFEASIBLE is a proof. FEASIBLE is conditional on the pad model.
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import anchors                                                  # noqa: E402
import events as events_mod                                     # noqa: E402
import feasible                                                 # noqa: E402
import specs as specs_mod                                       # noqa: E402

INTERNAL = ('smp.', 'in.', 'clk.')
INF = feasible.INF


def var_of(event, edge):
    """The delay variable an event carries: its own, per launching edge, for a
    pin of the core; none -- the fixed node -- for an input as the device
    drives it or an edge inside the core."""
    if event.startswith(INTERNAL):
        return '#0'
    return '%s@%s' % (event, edge)


def group_of(var, tie_edges):
    """The pad a delay variable belongs to: the pin, and (unless tied) the
    edge that launches it."""
    ev, edge = var.split('@')
    pin = ev.split('.')[0]
    return pin if tie_edges else '%s@%s' % (pin, edge)


def label(log):
    if log.period:
        return '%.0f%% high' % (100.0 * log.high / log.period)
    return os.path.basename(log.path)


class Result(object):
    def __init__(self):
        self.measured = set()
        self.fails = []          # (spec name, why)
        self.notes = []          # (spec name, what), for --verbose
        self.inputs = []         # (room, spec name, probe, side, log label)


def build(logs, S, col, pad_skew, tie_edges):
    """The whole system, plus everything that is checked outside it."""
    sys_ = feasible.System()
    res = Result()
    bounded = set()

    for log in logs:
        lab = label(log)

        # Pad-delay budgets.
        for key, evs, edge, tag in anchors.PAD:
            if key not in S:
                continue
            spec = S[key]
            lo, hi = spec.ns(col)
            ok = True
            for ev in evs:
                seen = 0
                wrong = None
                for scen in anchors.scenarios_for(tag):
                    for occ in events_mod.occurrences(log.get(scen), ev):
                        seen += 1
                        if occ.edge != edge and wrong is None:
                            wrong = occ
                if seen == 0:
                    res.fails.append((spec.name, 'no %s in the %s log (%s)'
                                      % (ev, '/'.join(anchors.scenarios_for(tag)), lab)))
                    ok = False
                    continue
                if wrong is not None:
                    res.fails.append((spec.name,
                                      'measured from BCLK %s, but %s moved on a %s '
                                      'edge at %.1f ns (%s)'
                                      % ('rising' if edge == 'R' else 'falling', ev,
                                         'rising' if wrong.edge == 'R' else 'falling',
                                         wrong.t, lab)))
                    ok = False
                    continue
                v = var_of(ev, edge)
                if (key, v) not in bounded:
                    sys_.bound(v, lo, hi, '%s %s' % (spec.name, v))
                    bounded.add((key, v))
            if ok:
                res.measured.add(key)

        # Separations.
        seps = {}
        for key, a, b, tag, bound in anchors.SEP:
            if key not in S:
                continue
            spec = S[key]
            lo, hi = bound(S, col) if bound else spec.ns(col)
            n = 0
            for scen in anchors.scenarios_for(tag):
                for ea, eb in events_mod.pairs(log.get(scen), a, b):
                    va, vb = var_of(ea.name, ea.edge), var_of(eb.name, eb.edge)
                    gap = eb.t - ea.t
                    n += 1
                    if va == '#0' and vb == '#0':
                        # Two events with no pad delay: the separation is a
                        # constant, met or not whatever the pads do. Judged
                        # here, so that one broken constant does not hide the
                        # rest of the system behind it.
                        if (lo is not None and gap < lo - 1e-9) or \
                           (hi is not None and gap > hi + 1e-9):
                            res.fails.append((spec.name, '%s->%s is %.1f ns (%s, %s); '
                                              'it must be %s'
                                              % (a, b, gap, scen, lab,
                                                 ' and '.join(x for x in [
                                                     None if lo is None else
                                                     'at least %.1f' % lo,
                                                     None if hi is None else
                                                     'at most %.1f' % hi] if x))))
                        else:
                            res.notes.append((spec.name, '%s->%s is %.1f ns (%s, %s), '
                                              'inside %s..%s' % (a, b, gap, scen, lab,
                                                                 lo, hi)))
                        continue
                    sys_.sep(va, ea.t, vb, eb.t, lo, hi,
                             '%s %s->%s (%s, %s, %.1f ns apart)'
                             % (spec.name, a, b, scen, lab, gap))
            seps.setdefault(key, []).append(n)
        for key, ns in seps.items():
            if min(ns) == 0:
                res.fails.append((S[key].name, 'a pair it needs is missing from '
                                  'the log (%s)' % lab))
            else:
                res.measured.add(key)

        # Where the inputs are sampled.
        for key, probes, edge, side in anchors.INPUT:
            if key not in S:
                continue
            spec = S[key]
            v = spec.ns(col)[0]
            ok = True
            for name in probes:
                p = log.probes.get(name)
                if p is None:
                    res.fails.append((spec.name, 'no probe of %s in the log (%s)'
                                      % (name, lab)))
                    ok = False
                    continue
                if not p.split:
                    res.fails.append((spec.name,
                                      '%s: the same outcome %+.1f and %+.1f ns from '
                                      'the BCLK %s edge, so it is not sampled there '
                                      '(%s)' % (name, p.off_b, p.off_a,
                                                'rising' if edge == 'R' else 'falling',
                                                lab)))
                    ok = False
                    continue
                if p.edge != edge:
                    res.fails.append((spec.name,
                                      '%s is sampled on a %s edge; the manual '
                                      'measures it from the BCLK %s edge (%s)'
                                      % (name, {'R': 'rising', 'F': 'falling'}.get(
                                          p.edge, 'unknown'),
                                         'rising' if edge == 'R' else 'falling', lab)))
                    ok = False
                    continue
                if side == 'split':
                    res.notes.append((spec.name, '%s: captured between %+.1f and '
                                      '%+.1f ns of the edge smp.mode names (%s)'
                                      % (name, p.off_b, p.off_a, lab)))
                    continue
                # The instant lies in (off_b, off_a]; the window is [-setup, +hold].
                room = (v + p.off_b) if side == 'setup' else (v - p.off_a)
                if room < -1e-9:
                    res.fails.append((spec.name,
                                      '%s is sampled up to %.1f ns %s the edge, '
                                      'outside the %.1f ns window (%s)'
                                      % (name, abs(p.off_b if side == 'setup'
                                                   else p.off_a),
                                         'before' if side == 'setup' else 'after',
                                         v, lab)))
                    ok = False
                    continue
                res.inputs.append((room, spec.name, name, side, lab))
            if ok:
                res.measured.add(key)

        # The clock.
        for key, what in sorted(anchors.DIRECT.items()):
            if key not in S:
                continue
            spec = S[key]
            lo, hi = spec.raw(col)
            if log.period is None:
                res.fails.append((spec.name, 'the log does not say its clock'))
                continue
            val = {'period': log.period,
                   'duty': 100.0 * log.high / log.period,
                   'high': log.high,
                   'low': log.period - log.high}[what]
            if (lo is not None and val < lo - 1e-9) or \
               (hi is not None and val > hi + 1e-9):
                res.fails.append((spec.name, 'the clock\'s %s is %.2f %s, outside '
                                  '%s..%s (%s)' % (what, val, spec.unit, lo, hi, lab)))
            else:
                res.notes.append((spec.name, 'the clock\'s %s is %.2f %s, inside '
                                  '%s..%s (%s)' % (what, val, spec.unit, lo, hi, lab)))
                res.measured.add(key)

        # Nothing of the core's moves off a clock edge.
        off = int(log.facts.get('offedge_changes', '-1'))
        if off != 0:
            res.fails.append(('all', 'the testbench saw %s pin changes away from '
                              'every clock edge (%s)' % (off if off > 0 else 'no count of',
                                                         lab)))

        # A pending specification whose evidence is already here has outlived
        # its reason.
        present = set(log.probes)
        for evs in log.scen.values():
            present.update(e.name for e in evs)
        for key, (ms, why, evidence) in sorted(anchors.PENDING.items()):
            if key not in S:
                continue
            got = [e for e in evidence if e in present]
            if got:
                res.fails.append((key, 'pending (%s), but the log already holds %s: '
                                  'anchor it' % (ms, ', '.join(got))))

    # Pad delays are not negative, and one pad has one delay -- or several,
    # within pad_skew of each other.
    groups = {}
    for v in sorted(sys_.vars):
        if v.startswith('#'):
            continue
        sys_.floor(v)
        groups.setdefault(group_of(v, tie_edges), []).append(v)
    for g, vs in sorted(groups.items()):
        for i in range(len(vs) - 1):
            sys_.le(vs[i], vs[i + 1], pad_skew, None)
            sys_.le(vs[i + 1], vs[i], pad_skew, None)

    return sys_, res, groups


def windows(sys_, groups):
    """For each pad, the range of delays consistent with every constraint:
    [-dist(v -> #0), dist(#0 -> v)] over the shortest paths."""
    nodes = sorted(sys_.vars)
    idx = dict((n, i) for i, n in enumerate(nodes))
    n = len(nodes)
    d = [[INF] * n for _ in range(n)]
    for i in range(n):
        d[i][i] = 0.0
    for y, x, c, _, _k in sys_.edges:
        i, j = idx[y], idx[x]
        if c < d[i][j]:
            d[i][j] = c
    for k in range(n):
        dk = d[k]
        for i in range(n):
            dik = d[i][k]
            if dik == INF:
                continue
            di = d[i]
            for j in range(n):
                if dk[j] != INF and dik + dk[j] < di[j]:
                    di[j] = dik + dk[j]
    z = idx['#0']
    out = []
    for g, vs in sorted(groups.items()):
        lo = max(-d[idx[v]][z] for v in vs)
        hi = min(d[z][idx[v]] for v in vs)
        out.append((hi - lo, g, lo, hi))
    out.sort()
    return out


def run_column(logs, col, pad_skew, tie_edges, verbose):
    S = specs_mod.for_column(col)
    sys_, res, groups = build(logs, S, col, pad_skew, tie_edges)
    ok, dist, cycle = sys_.solve()
    n_all = len(S)
    anchored = anchors.anchored_keys()
    pend_full = sorted(k for k in S if k in anchors.PENDING and k not in anchored)
    pend_part = sorted(k for k in S if k in anchors.PENDING and k in anchored)
    expl = [k for k in S if k in anchors.UNANCHORED]
    measured = sorted(k for k in res.measured if k in S)
    bad = 0
    head = '%-31s' % col.title

    if not ok:
        bad = 1
        print('%s INFEASIBLE -- these limits contradict each other:' % head)
        total = 0.0
        for y, x, c, why in cycle:
            total += c
            print('           d[%s] - d[%s] <= %7.1f   %s'
                  % (x, y, c, why if why else '(one pad, one delay)'))
        print('           round trip: %.1f ns, which cannot be met' % total)
    else:
        margins = sys_.margins()
        seps = [(m, why) for m, why, kind in margins if kind == 'sep']
        tight = seps[0] if seps else (INF, 'nothing')
        win = windows(sys_, groups)
        print('%s pads feasible, %d of %d measured, %d pending, %d not about '
              'this design; %.1f ns of room on the binding constraint'
              % (head, len(measured), n_all, len(pend_full), len(expl), tight[0]))
        print('           %s' % tight[1])
        if win:
            w = win[0]
            print('           narrowest pad window: %s, %.1f to %.1f ns (%.1f ns wide)'
                  % (w[1], w[2], w[3], w[0]))
    if res.inputs:
        res.inputs.sort()
        r = res.inputs[0]
        print('           inputs: %d windows checked, each sampled on its own edge; '
              'tightest %.1f ns, %s %s (%s)' % (len(res.inputs), r[0], r[1], r[2], r[3]))
    print('           PENDING, not measured: %s'
          % ('; '.join('%s (%s)' % (k, anchors.PENDING[k][0]) for k in pend_full)
             + ('; partly: %s' % ', '.join(pend_part) if pend_part else '')))
    for name, why in res.fails:
        bad = 1
        print('           FAIL %-6s %s' % (name, why))
    unaccounted = [k for k in S if k not in res.measured and k not in anchors.UNANCHORED
                   and k not in pend_full]
    if unaccounted and not res.fails:
        bad = 1
        print('           FAIL %d specifications neither measured, pending nor '
              'explained: %s' % (len(unaccounted), ', '.join(sorted(unaccounted))))
    failed = sorted(set(n for n, _ in res.fails), key=specs_mod._order)
    if not ok:
        failed = ['the pad system'] + failed
    print('           => %s %s' % (col.name, 'PASS' if not bad else
                                   'FAIL: %s' % ', '.join(failed)))

    if verbose:
        print('           -- %s in detail --' % col.title)
        for log in logs:
            print('           %s: clock %.3f ns, %.3f ns high'
                  % (os.path.basename(log.path), log.period or 0.0, log.high or 0.0))
        if ok:
            print('           tightest separations, one per specification and pair:')
            seen = set()
            n = 0
            for m, why in seps:
                k = why.split(' (')[0]
                if k in seen:
                    continue
                seen.add(k)
                print('             %6.1f ns  %s' % (m, why))
                n += 1
                if n == 12:
                    break
            print('           pad windows (what every limit together leaves each pad):')
            for wd, g, lo, hi in win:
                print('             %-10s %6.1f .. %6.1f ns  (%.1f wide)' % (g, lo, hi, wd))
            print('           a pad assignment that meets every limit:')
            for v in sorted(dist):
                if not v.startswith('#'):
                    print('             %-18s %6.1f ns' % (v, dist[v] - dist['#0']))
        print('           input windows, tightest first:')
        for room, name, probe, side, lab in res.inputs[:16]:
            print('             %6.1f ns  %-5s %-12s %-5s (%s)' % (room, name, probe, side, lab))
        for name, what in res.notes:
            print('           %-6s %s' % (name, what))
        for key in sorted(k for k in anchors.UNANCHORED if k in S):
            print('           not measured %-5s %s' % (key, anchors.UNANCHORED[key]))
        for key in pend_full + pend_part:
            ms, why, _ = anchors.PENDING[key]
            print('           pending      %-5s %s%s: %s'
                  % (key, ms, ' (partly)' if key in pend_part else '', why))
        for key, why in sorted(anchors.PARTIAL.items()):
            if key in S:
                print('           partly       %-5s %s' % (key, why))
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('logs', nargs='+')
    ap.add_argument('--grade', required=True, choices=sorted(specs_mod.GRADE_PERIOD_NS))
    ap.add_argument('--column', action='append', default=None,
                    choices=sorted(specs_mod.BY_NAME),
                    help='only these columns (default: every column of the grade)')
    ap.add_argument('--pad-skew', type=float, default=0.0,
                    help='how far apart the delays of one pad may be (default 0)')
    ap.add_argument('--tie-edges', action='store_true',
                    help='one delay per pin, whichever clock edge launches it')
    ap.add_argument('--verbose', action='store_true')
    args = ap.parse_args()

    allspecs = specs_mod.load_all()
    missing, stale = anchors.check_complete(allspecs)
    if missing or stale:
        print('FAIL: the anchor table does not cover the manual: missing %s, stale %s'
              % (missing, stale))
        return 1

    logs = [events_mod.read(p) for p in args.logs]
    for log in logs:
        want = specs_mod.GRADE_PERIOD_NS[args.grade]
        if log.period is None or abs(log.period - want) > 1e-6:
            print('FAIL: %s was recorded at %s ns, and the %s MHz grade is %s ns'
                  % (log.path, log.period, args.grade, want))
            return 1
    cols = ([specs_mod.BY_NAME[c] for c in args.column] if args.column
            else specs_mod.columns_of_grade(args.grade))
    bad = 0
    for col in cols:
        if col.grade != args.grade:
            print('FAIL: column %s is not of the %s MHz grade' % (col.name, args.grade))
            bad = 1
            continue
        bad |= run_column(logs, col, args.pad_skew, args.tie_edges, args.verbose)
    return bad


if __name__ == '__main__':
    sys.exit(main())
