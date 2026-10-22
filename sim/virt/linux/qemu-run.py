#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041
"""Boot the guest on QEMU's m68k virt board and run a scripted command set
(M0 spike 5, `make virt-qemu`; doc/oracles.md, "Linux on QEMU's virt").

    qemu-run.py --qemu QEMU --log FILE [--script FILE] [--timeout S]
                [--expect TEXT] -- QEMU-ARGS...

QEMU's console (the goldfish tty, -serial stdio) is read and logged to FILE.
The script's lines are `expect <text>` (wait until the text has appeared
since the last match) and `send <text>` (type it; \\n is a newline); # starts
a comment. After the script, the run waits for QEMU to exit by itself (the
guest powers off through virt-ctrl). Exit status 0 when every expect matched,
the --expect texts (if any) are in the log, and QEMU exited by itself before
TIMEOUT wall seconds.
"""
import argparse
import os
import select
import subprocess
import sys
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qemu", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--script")
    ap.add_argument("--timeout", type=float, default=300)
    ap.add_argument("--expect", action="append", default=[])
    ap.add_argument("args", nargs=argparse.REMAINDER)
    o = ap.parse_args()
    args = o.args[1:] if o.args and o.args[0] == "--" else o.args
    steps = []
    if o.script:
        for line in open(o.script):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            verb, _, text = line.partition(" ")
            if verb not in ("expect", "send"):
                sys.exit(f"qemu-run.py: bad script line: {line}")
            steps.append((verb, text.replace("\\n", "\n")))

    t0 = time.time()
    p = subprocess.Popen([o.qemu] + args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT)
    log = open(o.log, "wb")
    out = b""
    mark = 0            # the output before mark has been matched already
    k = 0
    ok = True
    while True:
        while k < len(steps) and steps[k][0] == "send":
            time.sleep(0.05)
            p.stdin.write(steps[k][1].encode())
            p.stdin.flush()
            k += 1
        left = o.timeout - (time.time() - t0)
        if left <= 0:
            print(f"qemu-run.py: timeout after {o.timeout:.0f} s"
                  + (f", waiting for '{steps[k][1]}'" if k < len(steps) else ""))
            ok = False
            p.kill()
            break
        r, _, _ = select.select([p.stdout], [], [], min(left, 1.0))
        if r:
            b = os.read(p.stdout.fileno(), 65536)
            if not b:
                break
            log.write(b)
            log.flush()
            out += b
        if k < len(steps) and steps[k][0] == "expect":
            i = out.find(steps[k][1].encode(), mark)
            if i >= 0:
                mark = i + len(steps[k][1])
                k += 1
    rc = p.wait()
    log.close()
    wall = time.time() - t0
    if k < len(steps):
        print(f"qemu-run.py: the script stopped at step {k + 1}: {steps[k][0]} '{steps[k][1]}'")
        ok = False
    for e in o.expect:
        if e.encode() not in out:
            print(f"qemu-run.py: '{e}' is not in the console")
            ok = False
    print(f"qemu-run.py: QEMU exited with {rc} after {wall:.1f} s wall")
    return 0 if ok and rc == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
