#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041
"""Compare a guest's console on QEMU's m68040 (the reference) with the same
guest's on the core (rd-qvirt; doc/qvirt.md).

    console-diff.py REFERENCE CORE [--mask FILE] [--until TEXT]

Both are taken as bytes, carriage returns dropped. Before the comparison:
  - a kernel log line's time stamp ("[    1.0400030] ", NetBSD's and
    Linux's printk times) is removed: it is the virtual time, which the two
    processors reach at different instructions;
  - each line matching a regular expression of the mask file (one a line,
    # comments) is left out: a line printed by work that runs beside the
    boot's (Linux's initramfs unpacking) lands where the timing puts it.
With --until, the comparison ends with the first line holding TEXT on each
side: what follows (a shutdown's, several writers sharing the console) is
ordered by the timing. Exit status 0 when the two are then the same; otherwise the first difference
is shown, with the lines around it.
"""
import re
import sys

STAMP = re.compile(rb"^\[ *[0-9]+\.[0-9]+\] ")


def lines(path, masks, until):
    b = open(path, "rb").read().replace(b"\r", b"")
    out = []
    for l in b.split(b"\n"):
        l = STAMP.sub(b"", l)
        if any(m.search(l) for m in masks):
            continue
        out.append(l)
        if until and until in l:
            break
    else:
        if until:
            sys.exit(f"  {path} never shows '{until.decode()}'")
    return out


def main():
    a = sys.argv[1:]
    masks = []
    if "--mask" in a:
        i = a.index("--mask")
        for l in open(a[i + 1], "rb"):
            l = l.rstrip(b"\n")
            if l and not l.startswith(b"#"):
                masks.append(re.compile(l))
        del a[i:i + 2]
    until = None
    if "--until" in a:
        i = a.index("--until")
        until = a[i + 1].encode()
        del a[i:i + 2]
    if len(a) != 2:
        sys.exit(__doc__)
    ref, core = lines(a[0], masks, until), lines(a[1], masks, until)
    for i in range(max(len(ref), len(core))):
        x = ref[i] if i < len(ref) else None
        y = core[i] if i < len(core) else None
        if x != y:
            print(f"  consoles differ at line {i + 1}:")
            for j in range(max(0, i - 3), min(i + 4, max(len(ref), len(core)))):
                rx = ref[j] if j < len(ref) else b"<end>"
                cy = core[j] if j < len(core) else b"<end>"
                mark = "!" if rx != cy else " "
                print(f"  {mark} ref  {j + 1:5}: {rx.decode('latin-1')}")
                if rx != cy:
                    print(f"  {mark} core {j + 1:5}: {cy.decode('latin-1')}")
            sys.exit(1)
    print(f"  consoles identical: {len(ref)} lines")


if __name__ == "__main__":
    main()
