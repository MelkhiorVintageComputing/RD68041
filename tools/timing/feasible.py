#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041

"""The difference-constraint system, and Bellman-Ford.

Carried over unchanged in substance from RD68031's tools/timing/feasible.py:
nothing in it knows which processor it is judging.

An RTL model has no pad delays, so the manual's AC limits cannot be measured from
it. They can still be answered, because every one of them is a statement about
the same unknowns: the delay from a clock edge to the pin moving.

    a budget on a pad delay             lo <= d[e] <= hi
    a required separation between pins  (t_b + d_b) - (t_a + d_a) >= m

The times t come from the simulation and are constants. Rearranged, every
constraint is `d_x - d_y <= c`, which is a weighted edge y -> x in a graph whose
shortest-path problem is feasible exactly when the graph has no negative cycle.
Bellman-Ford answers that, and its potentials are a pad-delay assignment that
meets every limit at once.

INFEASIBLE IS A PROOF. FEASIBLE IS CONDITIONAL. Each transition has its own
variable, so unless they are tied the solver may give one pin a large delay when
it asserts and a small one when it negates. Real pads do not work that way, and
it is not a hypothetical: a short bus cycle can pass a minimum-width limit only by
exploiting exactly that. `pad_skew` ties the transitions of one pin to within a
given number of nanoseconds, and the analysis defaults to 0 -- one delay per pin.
"""

INF = float('inf')


class System(object):
    def __init__(self):
        self.vars = set()
        # (y, x, c, why, kind) meaning d[x] - d[y] <= c.
        #
        # kind separates the two things a margin can mean. A BOUND's margin is
        # just how wide the manual printed the budget -- 0 to 30 ns of pad delay
        # is 30 ns of room whatever the design does -- so it says nothing about
        # this design. A SEPARATION's margin does: it is how much closer together
        # two pins could be asked to move before no pad assignment could do it.
        # Only the second is a binding constraint in any useful sense.
        self.edges = []

    def var(self, name):
        self.vars.add(name)
        return name

    def le(self, x, y, c, why, kind='sep'):
        """d[x] - d[y] <= c"""
        self.var(x)
        self.var(y)
        self.edges.append((y, x, c, why, kind))

    def bound(self, x, lo, hi, why, kind='bound'):
        """lo <= d[x] <= hi, either end optional."""
        self.var(x)
        if hi is not None:
            self.le(x, '#0', hi, why, kind)
        if lo is not None:
            self.le('#0', x, -lo, why, kind)

    def floor(self, x):
        """d[x] >= 0. A pad delay is a delay: a pin cannot move before the
        clock edge that moves it. Without this, a pin whose specifications give
        it only a maximum could be given
        a negative delay, and a separation measured from it would be met by a
        pin moving before its own clock edge. Its own kind, so that it is never
        reported as a budget the manual printed."""
        self.bound(x, 0.0, None, 'a pad delay is not negative (%s)' % x, 'floor')

    def sep(self, xa, ta, xb, tb, lo, hi, why):
        """lo <= (tb + d[xb]) - (ta + d[xa]) <= hi"""
        gap = tb - ta
        if lo is not None:
            # d[xa] - d[xb] <= gap - lo
            self.le(xa, xb, gap - lo, why)
        if hi is not None:
            # d[xb] - d[xa] <= hi - gap
            self.le(xb, xa, hi - gap, why)

    def solve(self):
        """(feasible, potentials, negative_cycle_edges)."""
        self.var('#0')
        nodes = sorted(self.vars)
        edges = list(self.edges)

        # A virtual source with a zero-weight edge to every node, implemented by
        # starting every distance at zero rather than by adding the edges. Adding
        # them for real would assert d[n] - d[source] <= 0, which is a constraint
        # of its own -- and a wrong one: it says every pad delay is at most zero,
        # which any specification with a non-zero minimum contradicts.
        dist = dict((n, 0.0) for n in nodes)
        pred = dict((n, None) for n in nodes)

        for _ in range(len(nodes)):
            changed = False
            for y, x, c, why, kind in edges:
                if dist[y] != INF and dist[y] + c < dist[x] - 1e-9:
                    dist[x] = dist[y] + c
                    pred[x] = (y, x, c, why)
                    changed = True
            if not changed:
                break
        else:
            # One more relaxation still improves something: a negative cycle.
            culprit = None
            for y, x, c, why, kind in edges:
                if dist[y] != INF and dist[y] + c < dist[x] - 1e-9:
                    culprit = x
                    break
            return (False, dist, self._cycle(pred, culprit))
        return (True, dist, [])

    def _cycle(self, pred, node):
        """The negative cycle itself, as a list of edges.

        Walking the predecessor chain |V| times first is what guarantees landing
        *inside* the cycle rather than on the tail that leads to it.
        """
        if node is None:
            return []
        cur = node
        for _ in range(len(self.vars) + 1):
            e = pred.get(cur)
            if e is None:
                return []
            cur = e[0]
        start = cur
        out = []
        while True:
            e = pred.get(cur)
            if e is None:
                break
            out.append(e)
            cur = e[0]
            if cur == start or len(out) > len(self.vars) + 2:
                break
        out.reverse()
        return out

    def margins(self):
        """How far each constraint could be tightened before the system breaks.

        The slack of one constraint in one solution is not a margin: Bellman-Ford
        returns the assignment that sits hard against some corner, so whichever
        bound it landed on reports zero room whatever the design does.

        The real question is per constraint and independent of any solution: by
        how much could this limit be made stricter before some cycle goes
        negative? For an edge y -> x of weight c that is exactly

            c + (shortest path from x back to y)

        because tightening c by more than that closes a negative cycle. The
        minimum over every constraint is the design's margin, and the constraint
        that attains it is the binding one.
        """
        nodes = sorted(self.vars)
        idx = dict((n, i) for i, n in enumerate(nodes))
        n = len(nodes)
        d = [[INF] * n for _ in range(n)]
        for i in range(n):
            d[i][i] = 0.0
        for y, x, c, _, _k in self.edges:
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

        out = []
        for y, x, c, why, kind in self.edges:
            if why is None:
                continue
            back = d[idx[x]][idx[y]]
            if back == INF:
                continue          # nothing constrains it from the other side
            out.append((c + back, why, kind))
        out.sort(key=lambda p: p[0])
        return out


# --------------------------------------------------------------------------
# Known-answer tests for the solver itself.
#
# The design is judged by this code, so the code is judged by cases whose answer
# is arithmetic rather than engineering. `python3 tools/timing/feasible.py`.
# --------------------------------------------------------------------------
def _self_test():
    fails = 0

    def case(name, build, want_feasible):
        nonlocal fails
        s = System()
        build(s)
        ok, _, cycle = s.solve()
        if ok != want_feasible:
            fails += 1
            print('  FAIL: %s -- expected %s, got %s'
                  % (name, 'feasible' if want_feasible else 'infeasible',
                     'feasible' if ok else 'infeasible'))
            if cycle:
                for y, x, c, why in cycle:
                    print('        d[%s] - d[%s] <= %.1f  %s' % (x, y, c, why))
        return s

    # A bound alone is satisfiable, including one with a non-zero minimum --
    # which an earlier version of this module got wrong by wiring the virtual
    # source in as a real constraint saying every delay is at most zero.
    case('a single bound 3..30',
         lambda s: s.bound('a', 3.0, 30.0, 'b'), True)

    # A bound that contradicts itself.
    case('an impossible bound 30..3',
         lambda s: s.bound('a', 30.0, 3.0, 'b'), False)

    # Two pins 30 ns apart in the simulation, asked to be 15 ns apart at the
    # pins: easily met by delays inside 0..30.
    def two_ok(s):
        s.bound('a', 0.0, 30.0, 'a')
        s.bound('b', 0.0, 30.0, 'b')
        s.sep('a', 0.0, 'b', 30.0, 15.0, None, 'a->b >= 15')
    case('a separation with room', two_ok, True)

    # The same pins asked to be 100 ns apart when they are 30 ns apart and
    # neither delay may exceed 30: impossible by 40 ns.
    def two_bad(s):
        s.bound('a', 0.0, 30.0, 'a')
        s.bound('b', 0.0, 30.0, 'b')
        s.sep('a', 0.0, 'b', 30.0, 100.0, None, 'a->b >= 100')
    case('a separation that cannot be met', two_bad, False)

    # A width shorter than its minimum is a self-loop of negative weight: one
    # variable, and no assignment of it can help.
    def width_bad(s):
        s.sep('w', 0.0, 'w', 10.0, 20.0, None, 'width >= 20 over a 10 ns gap')
    case('a width shorter than its minimum', width_bad, False)

    # Margins: a 30 ns gap asked to be 15 has 15 ns to give.
    s = System()
    two_ok(s)
    m = s.margins()
    # The separation asks two pins 30 ns apart to stay 15 ns apart. Each delay
    # may be anywhere in 0..30, so d[a] - d[b] can be pushed as low as -30: the
    # limit could be tightened by 45 ns before nothing could meet it.
    sep = [v for v, why, kind in m if kind == 'sep']
    if not sep or abs(min(sep) - 45.0) > 1e-6:
        fails += 1
        print('  FAIL: the separation\'s own margin: expected 45.0, got %s'
              % (('%.1f' % min(sep)) if sep else 'none'))
    # The bound's margin is the width the manual printed, and nothing else.
    bnd = [v for v, why, kind in m if kind == 'bound']
    if not bnd or abs(min(bnd) - 30.0) > 1e-6:
        fails += 1
        print('  FAIL: the bound\'s margin: expected 30.0, got %s'
              % (('%.1f' % min(bnd)) if bnd else 'none'))

    # The floor: a separation that can only be met by a pin moving before its
    # own clock edge is not met. Two pins 10 ns apart in the simulation asked to
    # be 20 ns apart, where only b's delay has a budget (0..30): with the floor
    # a's delay cannot go negative, and b's 30 ns makes it -- feasible. Ask for
    # 50 and it is not, though a delay of -10 on a would have done it.
    def floor_ok(s):
        s.floor('a')
        s.bound('b', 0.0, 30.0, 'b')
        s.sep('a', 0.0, 'b', 10.0, 20.0, None, 'a->b >= 20')
    case('a separation met above the floor', floor_ok, True)

    def floor_bad(s):
        s.floor('a')
        s.bound('b', 0.0, 30.0, 'b')
        s.sep('a', 0.0, 'b', 10.0, 50.0, None, 'a->b >= 50')
    case('a separation that needs a negative delay', floor_bad, False)

    # A separation between two edges inside the core, neither with a pad delay:
    # both ends are the fixed node, so it is a constant, checked as a loop.
    case('an internal separation that holds',
         lambda s: s.sep('#0', 0.0, '#0', 20.0, 15.0, None, 'int >= 15'), True)
    case('an internal separation that does not',
         lambda s: s.sep('#0', 0.0, '#0', 20.0, 25.0, None, 'int >= 25'), False)

    if fails:
        print('FAIL: feasible.py self-test, %d failures' % fails)
        return 1
    print('PASS: feasible.py self-test')
    return 0


if __name__ == '__main__':
    import sys as _sys
    _sys.exit(_self_test())
