#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041

"""Group a Vivado `report_timing -unique_pins -nworst 1` file into families.

    python3 tools/paths_report.py build/paths_activatable.rpt [N]

A family is a start register and an end register with the bit indices taken
off, so a 32-bit bus through the same logic is one line and not thirty-two.
Each path is scaled to the PERIOD it needs, not its slack: this design works on
both clock edges, and a half-period path's slack is worth twice a full-period
one's (scripts/fmax.tcl).
"""

import re
import sys


def families(path):
    txt = open(path).read()
    period = float(re.search(r'period=([\d.]+)ns', txt).group(1))
    fam = {}
    for b in re.split(r'\nSlack \((?:MET|VIOLATED)\)', txt)[1:]:
        sl = float(re.search(r':\s+(-?[\d.]+)ns', b).group(1))
        req = float(re.search(r'Requirement:\s+([\d.]+)ns', b).group(1))
        src = re.search(r'Source:\s+(\S+)', b).group(1)
        dst = re.search(r'Destination:\s+(\S+)', b).group(1)
        lv = int(re.search(r'Logic Levels:\s+(\d+)', b).group(1))
        rt = re.search(r'route ([\d.]+)ns \(([\d.]+)%\)', b)
        need = (req - sl) * period / req
        key = (re.sub(r'\[\d+\]|_\d+$', '[*]', src.rsplit('/', 1)[0]),
               re.sub(r'\[\d+\]', '[*]', dst.rsplit('/', 1)[0]))
        if key not in fam or fam[key][0] < need:
            fam[key] = (need, req, lv, rt.group(2) if rt else '?')
    return period, sorted(fam.items(), key=lambda kv: -kv[1][0])


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 15
    period, fams = families(sys.argv[1])
    print('  %-8s %-8s %-4s %-6s %s' % ('period', 'MHz', 'lvls', 'route', 'family'))
    for (src, dst), (need, req, lv, rt) in fams[:n]:
        half = ' (half)' if req < period else ''
        print('  %6.2f   %6.2f   %-4d %5s%%  %s -> %s%s'
              % (need, 1000.0 / need, lv, rt, src, dst, half))


if __name__ == '__main__':
    sys.exit(main())
