#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041
"""Compare two .trc traces (uae040_trace's format) record by record.

    compare.py [--elf ELF] [--max N] [--expect FILE] A.trc B.trc

A field written "x" in either trace (a register QEMU's interface does not
give, tools/cosim/qemu040/qemu040.c) is not compared. While the PCs agree the
records are compared field by field; when they part, the next PC common to
both within 64 records resynchronises them (an exception handler that took a
different path, say), and the skipped records are reported.

Every difference is printed as one line,
    step <n> pc <pc> [<label>] <field> A=<a> B=<b>
with the nearest symbol from ELF (nm) when given -- once, where it appears:
a register that keeps the same two values in the following records is not
reported again until they change or agree. With --expect FILE (one
"<label> <field>" per line, either a shell-style pattern; # comments), the run passes when every
difference is one listed there and every listed one occurred: the known
quirks are then confirmed on every run, as smoke040_check.py does for UAE040.
Without --expect, it passes when the traces agree.
"""
import argparse
import bisect
import fnmatch
import subprocess
import sys

NAMES = ([f"d{i}" for i in range(8)] + [f"a{i}" for i in range(7)] +
         ["usp", "isp", "msp", "sr", "vbr", "cacr", "sfc", "dfc", "tc", "urp",
          "srp", "itt0", "itt1", "dtt0", "dtt1", "mmusr", "fpcr", "fpsr", "fpiar"] +
         [f"fp{i}{p}" for i in range(8) for p in ("e", "h", "l")])


def load(path):
    with open(path) as f:
        head = f.readline().split()
        nstep, nfield = int(head[0], 16), int(head[1], 16)
        recs = []
        for line in f:
            v = line.split()
            if len(v) != nfield + 1:
                sys.exit(f"{path}: a record of {len(v)} values, not {nfield + 1}")
            recs.append(v)
    if len(recs) != nstep:
        sys.exit(f"{path}: {len(recs)} records, the header says {nstep}")
    return nfield, recs


def symbols(elf):
    out = subprocess.run(["m68k-linux-gnu-nm", "-n", elf], capture_output=True,
                         text=True, check=True).stdout
    syms = []
    for line in out.splitlines():
        p = line.split()
        if len(p) == 3 and p[1] in "tT":
            syms.append((int(p[0], 16), p[2]))
    return syms


def label(syms, pc):
    """The last symbol at or before pc (a landmark: L_*, or a handler)."""
    if not syms:
        return "-"
    i = bisect.bisect_right([s[0] for s in syms], pc) - 1
    if i < 0:
        return "-"
    a, n = syms[i]
    return n if a == pc else f"{n}+{pc - a:x}"


def same(a, b):
    return a == "x" or b == "x" or int(a, 16) == int(b, 16)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--elf")
    ap.add_argument("--max", type=int, default=200)
    ap.add_argument("--expect")
    o = ap.parse_args()
    na, A = load(o.a)
    nb, B = load(o.b)
    n = min(na, nb)
    syms = symbols(o.elf) if o.elf else []
    diffs = []          # (step, pc, label, field, a, b)
    carried = {}        # field -> (a, b) while a difference persists unchanged
    i = j = 0
    while i < len(A) and j < len(B):
        ra, rb = A[i], B[j]
        if int(ra[0], 16) != int(rb[0], 16):
            # resynchronise on the next common PC
            best = None
            for di in range(64):
                for dj in range(64):
                    if (i + di < len(A) and j + dj < len(B)
                            and int(A[i + di][0], 16) == int(B[j + dj][0], 16)):
                        if best is None or di + dj < sum(best):
                            best = (di, dj)
            pa = int(ra[0], 16)
            diffs.append((i, pa, label(syms, pa), "pc", ra[0], rb[0]))
            if best is None:
                break
            i += best[0]
            j += best[1]
            continue
        pc = int(ra[0], 16)
        for k in range(n):
            f = NAMES[k] if k < len(NAMES) else str(k)
            if same(ra[k + 1], rb[k + 1]):
                carried.pop(f, None)
                continue
            pair = (int(ra[k + 1], 16), int(rb[k + 1], 16))
            if carried.get(f) == pair:
                continue        # the same difference, carried from the last record
            carried[f] = pair
            diffs.append((i, pc, label(syms, pc), f, ra[k + 1], rb[k + 1]))
        i += 1
        j += 1
    if i < len(A) or j < len(B):
        diffs.append((i, 0, "end", "length", str(len(A)), str(len(B))))

    known = []          # (label, field) patterns, fnmatch-style
    if o.expect:
        with open(o.expect) as f:
            for line in f:
                line = line.split("#")[0].split()
                if line:
                    known.append((line[0], line[1]))
    seen = set()
    unexpected = 0
    for k, (s, pc, lab, fld, a, b) in enumerate(diffs):
        hit = [q for q in known if fnmatch.fnmatchcase(lab, q[0]) and fnmatch.fnmatchcase(fld, q[1])]
        seen.update(hit)
        if not hit:
            unexpected += 1
        if k < o.max:
            print(f"  {'quirk' if hit else 'DIFF'} step {s} pc {pc:x} {lab} {fld} A={a} B={b}")
    missing = [q for q in known if q not in seen]
    for lab, fld in missing:
        print(f"  MISSING expected difference {lab} {fld}")
    print(f"compared {min(len(A), len(B))} records ({len(A)} and {len(B)}), "
          f"{len(diffs)} differences, {unexpected} unexpected")
    ok = unexpected == 0 and not missing
    print("PASS: the traces agree" + (" but for the known quirks" if diffs else "")
          if ok else "FAIL: the traces disagree")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
