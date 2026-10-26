#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041

"""Figures and checks for doc/um-7-8-2-1-fairness-arbitration.md.

    python3 tools/um_figures/um_7_8_2_1.py           # write the SVGs into doc/
    python3 tools/um_figures/um_7_8_2_1.py --check   # print the arc analysis only
    python3 tools/um_figures/um_7_8_2_1.py --bars PDF PAGE Y0 Y1
                                                     # measure a page's overbars

UM 7.8.2.1, "Dual M68040 Fairness Arbitration", is one state diagram (Figure
7-35, UM p. 7-53) and the text around it. Motorola's addendum tells the reader
to ignore UM 7.8.2 if it confuses them; this redraws the figure as printed,
checks every arc, and draws a corrected one.

Two kinds of output:

  state diagrams   Figure 7-35 as printed, and corrected. Drawn here: nothing in
                   Inputs/ draws state diagrams.

  timing diagrams  three illustrations that are *not* in the manual: a bus
                   handover through the printed arbiter and through the
                   corrected one, and a locked sequence ended with LOCKE. They
                   use the engine of the redrawn section 11 figures,
                   Inputs/doc/MC68030_Doc_More_Readable/MC68040UM_split/
                   timingsvg.py, imported read-only, and its conventions: the
                   unit of time is half a BCLK period, BCLK rises at 0, 2, 4...
                   Every signal drawn is active low: the lower rail is asserted.

Notation. The conditions are kept as strings in the figure's own terms, so
that the same text labels the drawing and is evaluated by --check: a literal
is a signal name, "/" in front of it where the figure draws an overbar
(ASCII for one; the RTL uses an _n suffix instead), "*" after it where the
figure prints one, "&" for the figure's "Λ" and "|" for its "V". In the SVGs a "/" becomes a
bar drawn over the name, and the asterisk stays outside the bar, as printed.

Overbars. In Figure 7-35 the bars are separate stroked lines, so they can be
measured: --bars runs poppler's pdftocairo (for the strokes) and pdftotext
-bbox (for the words) and says, for every word, which bar lies over it and
how much of it the bar covers. Every signal name in Figure 7-35 carries a
bar over the whole name and none over its asterisk; the transcription below
records that, literal by literal.

Readings. Because the bars do not vary, a reading of the figure has to say
what the asterisk does to a barred name. --check evaluates the printed figure
under each reading in READINGS, and reports, state by state, input
combinations matched by no arc (a gap) or by more than one (an overlap),
combinations whose arc disagrees with the text, and whether the state's
outputs agree with the text.
"""

import itertools
import math
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
UMDIR = os.path.join(ROOT, 'Inputs', 'doc', 'MC68030_Doc_More_Readable', 'MC68040UM_split')
DOC = os.path.join(ROOT, 'doc')

# Inputs/ is immutable: importing from it must not leave a __pycache__ there.
sys.dont_write_bytecode = True
sys.path.insert(0, UMDIR)
from timingsvg import Fig, esc   # noqa: E402  (read-only use of the section 11 engine)


# ===================================================== the two arbiters ====
# Each state: its outputs as printed inside the circle, the inputs its arcs
# look at, and its arcs as (destination, condition). A self-loop has
# destination == the state. "/" is a printed overbar (all of them measured
# over the whole name, none over the asterisk -- see --bars).

PRINTED = {
    'A': {'out': '/BG1*, /BG2', 'inputs': ('BR2', 'LOCK', 'LOCKE'),
          'arcs': [('A', '/BR2* | /BR2 & /LOCK & /LOCKE'),
                   ('B', '/BR2 & /LOCK & /LOCKE | /BR2 & /LOCK*')]},
    'B': {'out': '/BG1, /BG2*', 'inputs': ('BB', 'LOCK', 'LOCKE'),
          'arcs': [('B', '/BB & /LOCK* | /BB & /LOCK & /LOCKE'),
                   ('C', '/BB*'),
                   ('A', '/BB & /LOCK & /LOCKE*')]},
    'C': {'out': '/BG1, /BG2*', 'inputs': ('BR1', 'LOCK', 'LOCKE'),
          'arcs': [('C', '/BR1* | /BR1 & /LOCK & /LOCKE*'),
                   ('D', '/BR1 & /LOCK & /LOCKE | /BR1 & /LOCK*')]},
    'D': {'out': '/BG1*, /BG2', 'inputs': ('BB', 'LOCK', 'LOCKE'),
          'arcs': [('D', '/BB & /LOCK* | /BB & /LOCK & /LOCKE'),
                   ('A', '/BB*'),
                   ('C', '/BB & /LOCK & /LOCKE*')]},
}

# Corrected: note 2's convention throughout ("/X*" asserted, "/X" negated),
# the A self-loop's LOCKE inverted to match C's, and no grant asserted in B
# and D (UM p. 7-48: one rising edge with every grant negated between
# tenures).
CORRECTED = {
    'A': {'out': '/BG1*, /BG2', 'inputs': ('BR2', 'LOCK', 'LOCKE'),
          'arcs': [('A', '/BR2 | /BR2* & /LOCK* & /LOCKE'),
                   ('B', '/BR2* & /LOCK* & /LOCKE* | /BR2* & /LOCK')]},
    'B': {'out': '/BG1, /BG2', 'inputs': ('BB', 'LOCK', 'LOCKE'),
          'arcs': [('B', '/BB* & /LOCK | /BB* & /LOCK* & /LOCKE*'),
                   ('C', '/BB'),
                   ('A', '/BB* & /LOCK* & /LOCKE')]},
    'C': {'out': '/BG1, /BG2*', 'inputs': ('BR1', 'LOCK', 'LOCKE'),
          'arcs': [('C', '/BR1 | /BR1* & /LOCK* & /LOCKE'),
                   ('D', '/BR1* & /LOCK* & /LOCKE* | /BR1* & /LOCK')]},
    'D': {'out': '/BG1, /BG2', 'inputs': ('BB', 'LOCK', 'LOCKE'),
          'arcs': [('D', '/BB* & /LOCK | /BB* & /LOCK* & /LOCKE*'),
                   ('A', '/BB'),
                   ('C', '/BB* & /LOCK* & /LOCKE')]},
}

# The grants each state must drive, True = asserted. Printed: from the text
# (A: processor 1 owns the bus; B: "BG1 is negated and BG2 is asserted"; C:
# processor 2 granted; D, the mirror image of B). Corrected: the corrected
# text.
OUT_TEXT_PRINTED = {'A': (True, False), 'B': (False, True),
                    'C': (False, True), 'D': (True, False)}
OUT_TEXT_CORRECTED = {'A': (True, False), 'B': (False, False),
                      'C': (False, True), 'D': (False, False)}


# How a literal is read: (barred, starred) -> True if the literal holds when
# the signal is asserted, False if it holds when the signal is negated. None
# means the reading gives that combination no meaning (it never occurs in
# Figure 7-35, where every name is barred).
READINGS = [
    ('a', 'the bar is part of the name; "*" = asserted, no "*" = negated (note 2)',
     lambda bar, star: star),
    ('b', 'a barred name is the line\'s electrical level, true when high; "*" marks '
          'assertion (low)',
     lambda bar, star: True if star else (False if bar else None)),
    ('c', 'a barred name is the signal, true when asserted; an unbarred name its '
          'complement; "*" only repeats "asserted"',
     lambda bar, star: True if (bar or star) else False),
    ('d', 'a barred name is the signal, true when asserted; "*" complements it '
          '(the ASCII "X*" = active low habit)',
     lambda bar, star: not star),
]


# What UM 7.8.2.1's text says each state does, as functions of the inputs
# *asserted* (True = asserted). From the three numbered cases on UM p. 7-53
# and the paragraph after them; C and D are the mirror image.
def _intent(state, v):
    if state in ('A', 'C'):
        req = v['BR2'] if state == 'A' else v['BR1']
        leave = req and (not v['LOCK'] or v['LOCKE'])   # cases 1 and 2
        return {'A': 'B', 'C': 'D'}[state] if leave else state
    # B and D: wait for BB negated (cases 1-3); a newly started locked
    # access (LOCK without LOCKE, BB asserted) gives the bus back (case 3).
    if not v['BB']:
        return {'B': 'C', 'D': 'A'}[state]
    if v['LOCK'] and not v['LOCKE']:
        return {'B': 'A', 'D': 'C'}[state]
    return state


def literal(tok):
    """'/LOCKE*' -> ('LOCKE', barred, starred)."""
    tok = tok.strip()
    bar = tok.startswith('/')
    star = tok.endswith('*')
    return tok.strip('/*'), bar, star


def evaluate(expr, v, read):
    """Evaluate a condition string under `read`. `v` maps a signal to True
    when asserted."""
    def lit(tok):
        name, bar, star = literal(tok)
        want = read(bar, star)
        if want is None:
            raise ValueError('reading undefined for %r' % tok)
        return v[name] == want
    return any(all(lit(t) for t in term.split('&')) for term in expr.split('|'))


def outputs(out, read):
    """'/BG1*, /BG2' -> (BG1 asserted, BG2 asserted) under `read`."""
    toks = dict((literal(t)[0], read(*literal(t)[1:])) for t in out.split(','))
    return toks['BG1'], toks['BG2']


def analyse(fsm, read_arc, read_out, out_text):
    """Per state: gaps, overlaps, disagreements with the text, and whether
    the outputs agree with the text."""
    report = {}
    for s, d in fsm.items():
        gaps, overlaps, wrong = [], [], []
        for bits in itertools.product((False, True), repeat=len(d['inputs'])):
            v = dict(zip(d['inputs'], bits))
            hit = [dst for dst, c in d['arcs'] if evaluate(c, v, read_arc)]
            if not hit:
                gaps.append(v)
            elif len(hit) > 1:
                overlaps.append((v, hit))
            elif hit[0] != _intent(s, v):
                wrong.append((v, hit[0], _intent(s, v)))
        got = outputs(d['out'], read_out)
        report[s] = (gaps, overlaps, wrong, got, out_text[s])
    return report


def show(v):
    return ' '.join('%s%s' % (k, '*' if b else '') for k, b in v.items())


def grants(g):
    return 'BG1 %s, BG2 %s' % tuple('asserted' if x else 'negated' for x in g)


def check_text(verbose=True):
    out = ['(inputs listed with "*" meaning asserted, whatever the reading)', '']
    rd = dict((k, f) for k, _, f in READINGS)
    cases = []
    for k, desc, f in READINGS:
        cases.append(('Figure 7-35 as printed, reading (%s): %s' % (k, desc), PRINTED, f, f,
                      OUT_TEXT_PRINTED))
    cases.append(('Figure 7-35 as printed, arcs read as (d), outputs as (a)', PRINTED,
                  rd['d'], rd['a'], OUT_TEXT_PRINTED))
    cases.append(('Corrected, reading (a) throughout', CORRECTED, rd['a'], rd['a'],
                  OUT_TEXT_CORRECTED))
    for title, fsm, ra, ro, ot in cases:
        out.append(title)
        rep = analyse(fsm, ra, ro, ot)
        total = 0
        for s in sorted(rep):
            gaps, overlaps, wrong, got, want = rep[s]
            total += len(gaps) + len(overlaps) + len(wrong) + (got != want)
            arcs_ok = not (gaps or overlaps or wrong)
            line = '  state %s: arcs %s; outputs %s' % (
                s,
                'complete, exclusive, agree with the text' if arcs_ok else
                '%d gap(s), %d overlap(s), %d against the text'
                % (len(gaps), len(overlaps), len(wrong)),
                'agree (%s)' % grants(got) if got == want else
                'say %s, text %s' % (grants(got), grants(want)))
            out.append(line)
            if verbose:
                for v in gaps:
                    out.append('      no arc for      %s' % show(v))
                for v, hit in overlaps:
                    out.append('      arcs to %s all match %s' % ('+'.join(hit), show(v)))
        out.append('  total problems: %d' % total)
        out.append('')
    return '\n'.join(out)


# ============================================================ overbars ====
def measure_bars(pdf, page, y0, y1):
    """Every word between y0 and y1 (PDF points from the top) on `page`, and
    the stroked horizontal line over it, if any. Needs poppler's pdftocairo
    and pdftotext."""
    svg = subprocess.run(['pdftocairo', '-svg', '-f', str(page), '-l', str(page), pdf, '-'],
                         check=True, capture_output=True, text=True).stdout
    bbox = subprocess.run(['pdftotext', '-bbox', '-f', str(page), '-l', str(page), pdf, '-'],
                          check=True, capture_output=True, text=True).stdout
    body = svg.split('</defs>', 1)[-1]
    bars = []
    for m in re.finditer(r'<path ([^>]*)/>', body):
        a = m.group(1)
        d = re.search(r' d="([^"]*)"', a)
        mm = re.fullmatch(r'M ([\d.]+) ([\d.]+) L ([\d.]+) ([\d.]+) ', d.group(1)) if d else None
        if not mm:
            continue
        xa, ya, xb, yb = map(float, mm.groups())
        if abs(ya - yb) > 0.01:
            continue
        t = re.search(r'transform="matrix\(([^)]*)\)"', a)
        if t:
            A, B, C, D, E, F = map(float, t.group(1).split(','))
            xa, xb, ya = A * xa + C * ya + E, A * xb + C * yb + E, B * xa + D * ya + F
        if xa > xb:
            xa, xb = xb, xa
        if y0 - 5 <= ya <= y1 and xb - xa < 60:
            bars.append((ya, xa, xb))
    rows = []
    for m in re.finditer(r'<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" '
                         r'yMax="([\d.]+)">([^<]*)</word>', bbox):
        xa, ya, xb, _ = map(float, m.groups()[:4])
        w = m.group(5)
        if not (y0 <= ya <= y1) or w in ('\u039b', 'V'):
            continue
        over = [(a, b) for (y, a, b) in bars if ya - 3.5 <= y <= ya + 0.3 and a < xb and b > xa]
        if over:
            a, b = min(o[0] for o in over), max(o[1] for o in over)
            rows.append('%6.1f %6.1f  %-8s bar %6.1f-%6.1f, word %6.1f-%6.1f, '
                        'unbarred tail %.1f pt' % (ya, xa, w, a, b, xa, xb, max(0.0, xb - b)))
        else:
            rows.append('%6.1f %6.1f  %-8s no bar' % (ya, xa, w))
    return '\n'.join(rows)


# ===================================================== barred text ====
# A name written "/NAME" is drawn with a bar over it. The bar needs the name's
# width; rather than trust a font metric, every piece of text is given an
# explicit width (SVG textLength) estimated from DejaVu Sans advance widths,
# so the bar fits whichever font the viewer substitutes.
_ADV = dict(zip('ABCDEFGHIJKLMNOPQRSTUVWXYZ',
                (1401, 1405, 1430, 1577, 1294, 1178, 1587, 1540, 604, 604, 1343, 1141, 1767,
                 1532, 1612, 1235, 1612, 1423, 1300, 1251, 1499, 1401, 2025, 1403, 1251, 1403)))
_ADV.update(dict(zip('abcdefghijklmnopqrstuvwxyz',
                     (1255, 1300, 1126, 1300, 1260, 721, 1300, 1298, 569, 569, 1186, 569, 1995,
                      1298, 1253, 1300, 1300, 842, 1067, 803, 1298, 1212, 1675, 1212, 1212, 1075))))
_ADV.update({c: 1303 for c in '0123456789'})
_ADV.update({' ': 651, '*': 1024, ',': 651, '.': 651, '-': 739, '(': 799, ')': 799,
             ':': 690, '>': 1716, '\u2227': 1290, '\u2228': 1290, '"': 942, "'": 563,
             '=': 1716, '+': 1716, '&': 1595})


def text_width(t, size, bold=False):
    w = sum(_ADV.get(c, 1250) for c in t) / 2048.0 * size
    return w * (1.08 if bold else 1.0)


def rich(x, y, s, size, cls, anchor='middle', bold=False, barcls='ob'):
    """SVG for the string `s` at baseline y, "/NAME" drawn with an overbar.
    `anchor` is start, middle or end, applied to the whole string."""
    pieces = [p for p in re.split(r'(/[A-Z][A-Z0-9_]*)', s) if p]
    widths = [text_width(p.lstrip('/'), size, bold) for p in pieces]
    total = sum(widths)
    x0 = x - {'start': 0.0, 'middle': total / 2, 'end': total}[anchor]
    out = []
    for p, w in zip(pieces, widths):
        t = p.lstrip('/')
        out.append('<text class="%s" style="text-anchor:start" x="%.1f" y="%.1f" '
                   'textLength="%.1f" lengthAdjust="spacingAndGlyphs">%s</text>'
                   % (cls, x0, y, w, esc(t)))
        if p.startswith('/'):
            yb = y - size * 0.86
            out.append('<line class="%s" x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f"/>'
                       % (barcls, x0 + 0.4, yb, x0 + w - 0.4, yb))
        x0 += w
    return out


# ======================================================== state diagrams ====
SD_CSS = """  <style>
    .c    { stroke:#111; stroke-width:2.2; fill:none; }
    .e    { stroke:#111; stroke-width:1.4; fill:none; }
    .eh   { stroke:#b8321f; stroke-width:2.0; fill:none; }
    .ah   { fill:#111; }
    .ahh  { fill:#b8321f; }
    .t    { fill:#111; font-size:12.5px; text-anchor:middle; }
    .th   { fill:#b8321f; font-size:12.5px; text-anchor:middle; font-weight:700; }
    .o    { fill:#111; font-size:13px; font-weight:700; text-anchor:middle; }
    .nth  { fill:#b8321f; font-size:11.5px; }
    .oh   { fill:#b8321f; font-size:13px; font-weight:700; text-anchor:middle; }
    .sn   { fill:#111; font-size:12.5px; font-weight:700; }
    .nt   { fill:#111; font-size:11.5px; }
    .ob   { stroke:#111; stroke-width:1.0; }
    .obh  { stroke:#b8321f; stroke-width:1.0; }
    @media (prefers-color-scheme: dark) {
      .c,.e,.ob { stroke:#e8e8e8; }
      .obh { stroke:#ff8a73; }
      .ah,.t,.o,.sn,.nt { fill:#e8e8e8; }
      .ahh,.th,.oh { fill:#ff8a73; }
      .eh { stroke:#ff8a73; }
    }
  </style>"""

R_ST = 58.0
CENTRE = {'D': (250.0, 215.0), 'C': (690.0, 215.0),
          'A': (250.0, 475.0), 'B': (690.0, 475.0)}


def pretty(expr):
    """The condition as drawn: one disjunct per line, the "V" leading."""
    terms = [t.strip().replace(' & ', ' ∧ ') for t in expr.split('|')]
    return [terms[0]] + ['∨ ' + t for t in terms[1:]]


def on_circle(s, deg):
    cx, cy = CENTRE[s]
    a = math.radians(deg)
    return cx + R_ST * math.cos(a), cy + R_ST * math.sin(a)


class StateFig:
    def __init__(self, title, w=1010, h=740):
        self.title, self.w, self.h = title, w, h
        self.parts = []

    SIZES = {'t': 12.5, 'o': 13.0, 'nt': 11.5}

    def text(self, x, y, lines, cls='t', hl=False, step=15.0, anchor='middle'):
        c = cls + ('h' if hl else '')
        y0 = y - (len(lines) - 1) * step / 2 + 4.5
        for i, ln in enumerate(lines):
            self.parts += rich(x, y0 + i * step, ln, self.SIZES[cls], c, anchor,
                               bold=(cls == 'o'), barcls='obh' if hl else 'ob')

    def head(self, x, y, fx, fy, hl=False):
        # arrowhead at (x, y) pointing away from (fx, fy)
        a = math.atan2(y - fy, x - fx)
        L, W = 11.0, 5.0
        bx, by = x - L * math.cos(a), y - L * math.sin(a)
        px, py = -math.sin(a) * W, math.cos(a) * W
        self.parts.append('<path class="ah%s" d="M %.1f,%.1f L %.1f,%.1f L %.1f,%.1f Z"/>'
                          % ('h' if hl else '', x, y, bx + px, by + py, bx - px, by - py))

    def state(self, s, out, name_xy, hl=False):
        cx, cy = CENTRE[s]
        self.parts.append('<circle class="c" cx="%.1f" cy="%.1f" r="%.1f"/>' % (cx, cy, R_ST))
        self.text(cx, cy, [out], cls='o', hl=hl)
        x, y, anchor = name_xy
        self.parts.append('<text class="sn" x="%.1f" y="%.1f" text-anchor="%s">STATE %s</text>'
                          % (x, y, anchor, s))

    def line(self, a, b, hl=False):
        (x0, y0), (x1, y1) = a, b
        self.parts.append('<path class="e%s" d="M %.1f,%.1f L %.1f,%.1f"/>'
                          % ('h' if hl else '', x0, y0, x1, y1))
        self.head(x1, y1, x0, y0, hl)

    def curve(self, a, ctl, b, hl=False):
        (x0, y0), (qx, qy), (x1, y1) = a, ctl, b
        self.parts.append('<path class="e%s" d="M %.1f,%.1f Q %.1f,%.1f %.1f,%.1f"/>'
                          % ('h' if hl else '', x0, y0, qx, qy, x1, y1))
        self.head(x1, y1, qx, qy, hl)

    def loop(self, s, deg, hl=False):
        a0, a1 = deg - 24, deg + 24
        p0, p1 = on_circle(s, a0), on_circle(s, a1)
        cx, cy = CENTRE[s]
        k = R_ST * 2.5
        c0 = (cx + k * math.cos(math.radians(a0 - 12)), cy + k * math.sin(math.radians(a0 - 12)))
        c1 = (cx + k * math.cos(math.radians(a1 + 12)), cy + k * math.sin(math.radians(a1 + 12)))
        self.parts.append('<path class="e%s" d="M %.1f,%.1f C %.1f,%.1f %.1f,%.1f %.1f,%.1f"/>'
                          % ('h' if hl else '', p0[0], p0[1], c0[0], c0[1], c1[0], c1[1],
                             p1[0], p1[1]))
        self.head(p1[0], p1[1], c1[0], c1[1], hl)

    def svg(self):
        out = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" '
               'font-family="\'DejaVu Sans\',Verdana,Arial,sans-serif" role="img" aria-label="%s">'
               % (self.w, self.h, self.w, self.h, esc(self.title)),
               '  <title>%s</title>' % esc(self.title), SD_CSS]
        out.append('  <g transform="translate(50,0)">')
        out += ['    ' + p for p in self.parts]
        out.append('  </g>')
        out.append('</svg>')
        return '\n'.join(out) + '\n'

    def write(self, path):
        with open(path, 'w') as f:
            f.write(self.svg())
        return path


def state_diagram(fsm, title, notes, hl=()):
    """Figure 7-35's layout: D and C on top, A and B below. `hl` names the
    elements to draw in the highlight colour: 'out:X' for a state's outputs,
    'X>Y' for an arc and its label."""
    f = StateFig(title)
    arc = {(s, dst): c for s, d in fsm.items() for dst, c in d['arcs']}
    H = lambda k: k in hl

    f.state('D', fsm['D']['out'], (150, 190, 'end'), H('out:D'))
    f.state('C', fsm['C']['out'], (770, 160, 'start'), H('out:C'))
    f.state('A', fsm['A']['out'], (200, 560, 'end'), H('out:A'))
    f.state('B', fsm['B']['out'], (770, 420, 'start'), H('out:B'))

    # C -> D, straight, across the top; D -> C, the arc above it.
    f.line(on_circle('C', 180), on_circle('D', 0), H('C>D'))
    f.text(470, 185, pretty(arc[('C', 'D')]), hl=H('C>D'))
    f.curve(on_circle('D', -62), (470, 30), on_circle('C', -118), H('D>C'))
    f.text(470, 70, pretty(arc[('D', 'C')]), hl=H('D>C'))
    # A -> B, straight, across the bottom; B -> A, the arc below it.
    f.line(on_circle('A', 0), on_circle('B', 180), H('A>B'))
    f.text(470, 507, pretty(arc[('A', 'B')]), hl=H('A>B'))
    f.curve(on_circle('B', 118), (470, 660), on_circle('A', 62), H('B>A'))
    f.text(470, 625, pretty(arc[('B', 'A')]), hl=H('B>A'))
    # D -> A down the left, B -> C up the right.
    f.line(on_circle('D', 90), on_circle('A', -90), H('D>A'))
    f.text(285, 345, pretty(arc[('D', 'A')]), hl=H('D>A'))
    f.line(on_circle('B', -90), on_circle('C', 90), H('B>C'))
    f.text(655, 345, pretty(arc[('B', 'C')]), hl=H('B>C'))
    # Self-loops: D upper left, A left, C right, B lower right.
    f.loop('D', 215, H('D>D'))
    f.text(95, 105, pretty(arc[('D', 'D')]), hl=H('D>D'))
    f.loop('A', 180, H('A>A'))
    f.text(80, 425, pretty(arc[('A', 'A')]), hl=H('A>A'))
    f.loop('C', 10, H('C>C'))
    f.text(845, 295, pretty(arc[('C', 'C')]), hl=H('C>C'))
    f.loop('B', 35, H('B>B'))
    f.text(835, 565, pretty(arc[('B', 'B')]), hl=H('B>B'))

    y = 690
    for i, n in enumerate(notes):
        f.text(-10, y + i * 16 - 4.5, [n], cls='nt', anchor='start')
    return f


# ======================================================= timing diagrams ====
EXTRA_CSS = """    .shade { fill:#d9534f; opacity:.25; }
    .ok    { fill:#3c8d40; opacity:.18; }
    .an    { fill:#111; font-size:11.5px; text-anchor:middle; }
    .anl   { fill:#111; font-size:11.5px; text-anchor:start; }
    .sname { fill:#111; font-size:12px; font-weight:700; text-anchor:middle; }
    .rl    { fill:#111; font-size:12.5px; font-weight:700; }
    .ob    { stroke:#111; stroke-width:1.0; }
    @media (prefers-color-scheme: dark) {
      .an,.anl,.sname,.rl { fill:#e8e8e8; }
      .ob { stroke:#e8e8e8; }
      .shade { fill:#ff6b5b; opacity:.30; }
      .ok    { fill:#7ccf80; opacity:.22; }
    }
"""

OUT = 0.66        # an output changes this long after its edge (as Figure 11-4)
REL_MAX = 0.90    # spec 38, 18 ns max at 25 MHz: address group released by
ON_MIN = 0.45     # spec 20, 9 ns min at 25 MHz: address group driven from
BB_Z = 1.26       # BB and TIP negated, then released half a clock later (39)


class TFig(Fig):
    """timingsvg.Fig with BCLK numbering, text inside a bus row, shading
    across rows and free annotations."""

    def __init__(self, title, clocks, **kw):
        n = 2 * clocks
        Fig.__init__(self, title, states=n, labels=[''] * n, **kw)
        self.clocks = clocks
        self.under = []
        self.rich_labels = {}

    def _row(self, name, label, lanes):
        # the engine draws plain labels; keep ours, barred, and give it a blank
        self.rich_labels[name] = label or name
        return Fig._row(self, name, ' ', lanes)

    def numbers(self, first=1):
        for k in range(self.clocks):
            self.parts.append('<text class="st" x="%.1f" y="30">C%d</text>'
                              % (self.x(2 * k + 1), k + first))

    def names(self, sig, segs):
        """Text centred in each (t0, t1, text) of a bus row."""
        r = self.rows[sig]
        y = r['top'] + 26.0 / 2 + 4.5
        for t0, t1, txt in segs:
            self.parts.append('<text class="sname" x="%.1f" y="%.1f">%s</text>'
                              % ((self.x(t0) + self.x(t1)) / 2, y, esc(txt)))

    def shade(self, t0, t1, sig0, sig1, cls='shade'):
        y0 = self.rows[sig0]['top'] - 6
        y1 = self.rows[sig1]['top'] + 26.0 + 6
        self.under.append('<rect class="%s" x="%.1f" y="%.1f" width="%.1f" height="%.1f"/>'
                          % (cls, self.x(t0), y0, self.x(t1) - self.x(t0), y1 - y0))

    def note(self, sig, lane, t, text, anchor='an'):
        y = self._lane_y(sig, lane) + 4
        self.parts += rich(self.x(t), y, text, 11.5, 'an',
                           'middle' if anchor == 'an' else 'start')

    def svg(self):
        for name, label in self.rich_labels.items():
            r = self.rows[name]
            lines = label.split('|')
            y0 = r['top'] + 26.0 / 2 + 4.5 - (len(lines) - 1) * 6.5
            for i, ln in enumerate(lines):
                self.parts += rich(158.0 - 14, y0 + i * 13, ln, 12.5, 'rl', 'end', bold=True)
        self.rich_labels = {}
        s = Fig.svg(self)
        s = s.replace('  </style>', EXTRA_CSS + '  </style>', 1)
        # shading goes under everything else: just after the style block
        i = s.index('</style>') + len('</style>\n')
        return s[:i] + ''.join('  %s\n' % u for u in self.under) + s[i:]


def handover(corrected):
    """Processor 1 implicitly owns the bus (state A, nothing to do); processor
    2 asks for it. Printed: B asserts BG2 as it negates BG1. Corrected: B
    negates both, C asserts BG2."""
    title = ('Handover from implicit ownership, %s arbiter'
             % ('corrected' if corrected else 'printed'))
    f = TFig(title, clocks=6, trail=0.5)
    f.clock('BCLK', label='BCLK', lanes=0)
    f.bus('ARB', [(0, 'v'), (2 + OUT, 'v'), (4 + OUT, 'v')], label='ARBITER|STATE', lanes=0)
    f.level('BR2', [(OUT, 0), (6 + OUT, 1)] if corrected else [(OUT, 0), (4 + OUT, 1)],
            label='/BR2', lanes=0)
    f.level('BG1', [(2 + OUT, 1)], start=0, label='/BG1', lanes=1)
    f.level('BG2', [(4 + OUT, 0)] if corrected else [(2 + OUT, 0)], label='/BG2', lanes=1)
    take = 6 if corrected else 4          # the edge processor 2 takes the bus on
    f.level('BB', [(take + OUT, 0)], label='/BB (line)', lanes=1)
    f.bus('A1', [(0, 'v'), (4 + REL_MAX, 'z')], label='PROCESSOR 1|A31-A0, ATTR', lanes=1)
    f.bus('A2', [(0, 'z'), (take + ON_MIN, 'v')], label='PROCESSOR 2|A31-A0, ATTR', lanes=1)
    f.level('TS2', [(take + OUT, 0), (take + 2 + OUT, 1)], label='/TS (PROC. 2)', lanes=1)
    f.numbers()

    if corrected:
        f.names('ARB', [(0, 2 + OUT, 'A'), (2 + OUT, 4 + OUT, 'B'), (4 + OUT, 12.5, 'C')])
        f.shade(3.6, 4.4, 'BG1', 'BG2', 'ok')
        f.note('BG2', 0, 4, 'end of C2: a rising edge with /BG1 and /BG2 both high, i.e. negated (UM p. 7-48)')
        f.note('A1', 0, 4 + REL_MAX + 0.1, 'released by 18 ns after the end of C2 (spec 38)', 'anl')
        f.note('A2', 0, take + ON_MIN + 0.1, 'driven from 9 ns after the end of C3 (spec 20)', 'anl')
        f.note('TS2', 0, 0.2, 'nobody drives the address group from (end of C2 + 18 ns) to (end of C3 + 9 ns)', 'anl')
    else:
        f.names('ARB', [(0, 2 + OUT, 'A'), (2 + OUT, 4 + OUT, 'B'), (4 + OUT, 12.5, 'C')])
        f.shade(4 + ON_MIN, 4 + REL_MAX, 'A1', 'A2')
        f.note('BG2', 0, 3.0, '/BG2 falls (asserted) in the clock /BG1 rises (negated): no edge with both high',
               'anl')
        f.note('A1', 0, 4 + REL_MAX + 0.1, 'released up to 18 ns after the end of C2 (spec 38)', 'anl')
        f.note('A2', 0, 4 + ON_MIN + 0.5, 'driven from 9 ns after the same edge (spec 20)', 'anl')
        f.note('TS2', 0, 7.2, 'shaded: both processors drive the address group', 'anl')
    return f


def locke_handover():
    """Corrected arbiter: processor 1's TAS write is the last of its locked
    sequence; processor 2 is waiting. BG1 is negated before the edge of the
    write's TA, so processor 1 cannot start another cycle."""
    f = TFig('Locked sequence ended with LOCKE, corrected arbiter', clocks=6, trail=0.5)
    f.clock('BCLK', label='BCLK', lanes=0)
    f.bus('ARB', [(0, 'v'), (2 + OUT, 'v'), (6 + OUT, 'v')], label='ARBITER|STATE', lanes=0)
    f.level('TS1', [(OUT, 0), (2 + OUT, 1)], label='/TS (PROC. 1)', lanes=0)
    f.level('TA', [(2 + OUT, 0), (4 + OUT, 1)], label='/TA', lanes=1)
    f.level('LOCK', [(4 + OUT, 1)], start=0, label='/LOCK', lanes=0)
    f.level('LOCKE', [(OUT, 0), (4 + OUT, 1)], label='/LOCKE', lanes=0)
    f.level('BR2', [(8 + OUT, 1)], start=0, label='/BR2', lanes=0)
    f.level('BG1', [(2 + OUT, 1)], start=0, label='/BG1', lanes=1)
    f.level('BG2', [(6 + OUT, 0)], label='/BG2', lanes=0)
    f.level('BB', [(4 + OUT, 1), (8 + OUT, 0)], start=0, label='/BB (line)', lanes=1)
    f.level('TS2', [(8 + OUT, 0), (10 + OUT, 1)], label='/TS (PROC. 2)', lanes=1)
    f.numbers()
    f.names('ARB', [(0, 2 + OUT, 'A'), (2 + OUT, 6 + OUT, 'B'), (6 + OUT, 12.5, 'C')])
    f.note('TA', 0, 4.2, 'last /TA, sampled at the end of C2 with /BG1 already negated: '
           'processor 1 gives the bus up (UM p. 7-45)', 'anl')
    f.note('BG1', 0, 2.8, 'A -> B at the end of C1: /BR2, /LOCK and /LOCKE asserted', 'anl')
    f.note('BB', 0, 6.2, 'B -> C at the end of C3; the ends of C2 and C3 see no grant', 'anl')
    f.note('TS2', 0, 0.2, 'on /LOCK alone, A is left only at the end of C3, when processor 1 '
           'may already have started another cycle', 'anl')
    return f


# ================================================================= main ====
NOTES_PRINTED = [
    'Redrawn from UM p. 7-53. Arc labels as printed: every name barred over its whole length, '
    '"*" outside the bar; \u2227 and \u2228 for the figure\'s \u039b and V.',
    'Printed notes: 1. Because this example uses two MC68040s, 1 and 2 refer to the processor '
    'and its signals.',
    '2. *Indicates the signal is asserted for that device.',
]
NOTES_CORRECTED = [
    'Corrected. "*" = asserted, no "*" = negated, everywhere (printed note 2). /BB, /LOCK and '
    '/LOCKE are the shared lines (pulled up).',
    'Every arc literal\'s asterisk is flipped from the printed figure (F1). Highlighted: the A '
    'self-loop (F2) and the grants in B and D (F3).',
    'B and D are the hand-over states: no grant is asserted in them, so every hand-over has a '
    'rising edge with /BG1 and /BG2 both high.',
]


def main(argv):
    if argv[:1] == ['--bars']:
        pdf, page, y0, y1 = argv[1], int(argv[2]), float(argv[3]), float(argv[4])
        print(measure_bars(pdf, page, y0, y1))
        return
    print(check_text())
    if '--check' in argv:
        return
    figs = [
        ('um-7-8-2-1-fig-7-35-printed.svg',
         state_diagram(PRINTED, 'Figure 7-35. Dual M68040 Fairness Arbitration State Diagram '
                       '(as printed)', NOTES_PRINTED)),
        ('um-7-8-2-1-fig-7-35-corrected.svg',
         state_diagram(CORRECTED, 'Figure 7-35. Dual M68040 Fairness Arbitration State Diagram '
                       '(corrected)', NOTES_CORRECTED,
                       hl=('A>A', 'out:B', 'out:D'))),
        ('um-7-8-2-1-handover-printed.svg', handover(False)),
        ('um-7-8-2-1-handover-corrected.svg', handover(True)),
        ('um-7-8-2-1-locke-corrected.svg', locke_handover()),
    ]
    for name, fig in figs:
        path = os.path.join(DOC, name)
        fig.write(path)
        print('%-40s %d bytes' % (name + ':', os.path.getsize(path)))


if __name__ == '__main__':
    main(sys.argv[1:])
