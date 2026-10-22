#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041

"""The MC68040's and MC68LC040's AC electrical specifications, as data.

    python3 tools/timing/specs.py                       # a summary
    python3 tools/timing/specs.py --dump                # every row, every column
    python3 tools/timing/specs.py --dump --column 040-40L

Carried over from RD68031's tools/timing/specs.py and retargeted. The source is
`Inputs/doc/MC68030_Doc_More_Readable/MC68040UM_split/ac-electrical-specifications.csv`:
UM section 11 (the MC68040) and Appendix A (the MC68LC040), parsed from the
manual's text layer and checked against a second reading (that directory's
README says how; read it before "correcting" a value). The CSV is long, not
wide: one row per device, specification, grade and buffer. This module adds
the judgements the CSV cannot carry: which columns this design is judged
against, which unit a row is in, and what an em dash means.

THE COLUMNS. The MC68040 prints three speed grades (25, 33, 40 MHz) and, for its
output table only, two buffer columns each: large buffers (50-ohm terminated
line, output note 1) and small (an unterminated 30-ohm line, note 2). The
buffers are chosen at reset by IPL2-IPL0 (UM 7.11.1). The MC68LC040 prints four
grades (20, 25, 33, 40 MHz) and has small buffers only (UM 11.8's note, and
Appendix A). An FPGA's pads are neither, so this design is judged against
every column there is -- ten -- and a grade is conformant only if it is
conformant in the column its board uses. For the same grade the large-buffer
column is never looser than the small one (every output maximum is smaller or
equal, every minimum equal), so a large-buffer pass implies a small-buffer
pass; both are still run, because that implication is a property of this
table and not something the analysis should assume.

The limits live here and not in SystemVerilog. The testbench emits times and
nothing else -- no testbench knows what a specification is.
"""

import argparse
import csv
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CSV = os.path.join(ROOT, 'Inputs', 'doc', 'MC68030_Doc_More_Readable',
                   'MC68040UM_split', 'ac-electrical-specifications.csv')

DEVICES = ['MC68040', 'MC68LC040']

# Each grade's minimum BCLK cycle time -- specification 5, checked against the
# CSV on load so that the two cannot drift apart. One simulation per grade
# (two, for the duty cycle: tools/timing/README.md), shared by every column of
# that grade.
GRADE_PERIOD_NS = {'20': 50.0, '25': 40.0, '33': 30.0, '40': 25.0}
GRADE_MHZ = {'20': 20.0, '25': 25.0, '33': 33.33, '40': 40.0}


class Column(object):
    """One column of the tables: a device at a grade, with a buffer choice."""

    def __init__(self, device, grade, buffer):
        self.device = device
        self.grade = grade
        self.buffer = buffer          # 'large', 'small'

    @property
    def name(self):
        if self.device == 'MC68040':
            return '040-%s%s' % (self.grade, self.buffer[0].upper())
        return 'LC040-%s' % self.grade

    @property
    def title(self):
        if self.device == 'MC68040':
            return 'MC68040 %s MHz, %s buffers' % (self.grade, self.buffer)
        return 'MC68LC040 %s MHz' % self.grade

    @property
    def period(self):
        return GRADE_PERIOD_NS[self.grade]


COLUMNS = [
    Column('MC68040', '25', 'large'), Column('MC68040', '25', 'small'),
    Column('MC68040', '33', 'large'), Column('MC68040', '33', 'small'),
    Column('MC68040', '40', 'large'), Column('MC68040', '40', 'small'),
    Column('MC68LC040', '20', 'small'), Column('MC68LC040', '25', 'small'),
    Column('MC68LC040', '33', 'small'), Column('MC68LC040', '40', 'small'),
]
BY_NAME = dict((c.name, c) for c in COLUMNS)


def columns_of_grade(grade):
    return [c for c in COLUMNS if c.grade == grade]


def _num(text):
    """One printed cell. Returns a float, or None where the source prints an
    em dash, "n/a" (specification 10 at 33 and 40 MHz) or nothing."""
    t = (text or '').strip()
    if not t or t in ('—', '-', '--') or t.lower() == 'n/a':
        return None
    return float(t.replace('–', '-'))


class Spec(object):
    """One numbered specification of one device, at every grade and buffer."""

    def __init__(self, row):
        self.num = row['num'].strip()
        self.characteristic = ' '.join(row['characteristic'].split())
        # Appendix A prints "nS"; the unit is the same.
        u = row['unit'].strip()
        self.unit = 'ns' if u.lower() == 'ns' else u
        self.footnotes = [f.strip() for f in row['footnotes'].split(',') if f.strip()]
        self.table = row['table'].strip()
        self.device = row['device'].strip()
        self.limits = {}              # (grade, buffer) -> (min, max)

    def add(self, row):
        key = (row['grade'].strip(), row['buffer'].strip())
        if key in self.limits:
            raise SystemExit('specs: %s %s has two rows for %r -- the CSV has '
                             'changed and this module has not'
                             % (self.device, self.num, key))
        self.limits[key] = (_num(row['min']), _num(row['max']))

    @property
    def key(self):
        return self.num

    @property
    def name(self):
        return self.num

    def raw(self, col):
        """(min, max) as printed, in the row's own unit, for a column. An
        input or clock row has no buffer split and serves both columns."""
        for k in ((col.grade, col.buffer), (col.grade, '')):
            if k in self.limits:
                return self.limits[k]
        return (None, None)

    def ns(self, col):
        """The limits in nanoseconds; (None, None) for a row in %, MHz or ppm."""
        if self.unit != 'ns':
            return (None, None)
        return self.raw(col)

    def lo(self, col):
        return self.ns(col)[0]

    def hi(self, col):
        return self.ns(col)[1]


def load(device, path=CSV):
    """Every numbered specification of one device, keyed by its number."""
    out = {}
    with open(path) as fh:
        for row in csv.DictReader(fh):
            if row['device'].strip() != device:
                continue
            num = row['num'].strip()
            if not num:
                continue              # the unnumbered "Frequency of Operation" row
            if num not in out:
                out[num] = Spec(row)
            out[num].add(row)
    five = out.get('5')
    if five is None:
        raise SystemExit('specs: no specification 5 (BCLK cycle time) for %s' % device)
    for g, p in GRADE_PERIOD_NS.items():
        lo = five.limits.get((g, ''), (None, None))[0]
        if lo is None:
            continue                  # the MC68040 has no 20 MHz grade
        if lo != p:
            raise SystemExit('specs: %s specification 5 at %s MHz is %s ns, but '
                             'GRADE_PERIOD_NS says %s' % (device, g, lo, p))
    return out


def load_all():
    return dict((d, load(d)) for d in DEVICES)


def for_column(col, cache={}):
    if col.device not in cache:
        cache[col.device] = load(col.device)
    return cache[col.device]


def _order(num):
    n = num.split(',')[0]
    digits = ''.join(c for c in n if c.isdigit())
    return (int(digits) if digits else 0, n)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dump', action='store_true')
    ap.add_argument('--column', default=None, choices=sorted(BY_NAME))
    args = ap.parse_args()

    allspecs = load_all()
    if not args.dump:
        for d in DEVICES:
            print('%-10s %d specifications' % (d, len(allspecs[d])))
        print('columns: %s' % ', '.join(c.name for c in COLUMNS))
        return 0

    cols = [BY_NAME[args.column]] if args.column else COLUMNS
    for col in cols:
        S = allspecs[col.device]
        print('# %s (%s)' % (col.title, col.name))
        for num in sorted(S, key=_order):
            s = S[num]
            lo, hi = s.raw(col)
            if lo is None and hi is None:
                continue
            print('  %-6s %-62s %7s %7s %s'
                  % (num, s.characteristic[:62],
                     '-' if lo is None else '%g' % lo,
                     '-' if hi is None else '%g' % hi, s.unit))
    return 0


if __name__ == '__main__':
    sys.exit(main())
