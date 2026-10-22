#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041
"""Check UAE040's run of smoke040.S against the MC68040 user's manual.

    smoke040_check.py [--lc] ELF TRC BUS OPS

ELF is the linked smoke program (its L_* labels are the landmarks), TRC the
uae040_trace output, BUS and OPS its -B and -O streams. Each check is a value
or an access the manual fixes; the UM section is given with each. With --lc
the run was an MC68LC040 (uae040_trace -L), and the FP part is checked for
UM appendix A's format $4 frames instead.

Prints one line per check, then PASS or FAIL. Lines starting "quirk:" are the
oracle's known disagreements with the manual (doc/oracles.md, UAE040): they
are confirmed, not failed, so that a change in the oracle is noticed.
"""
import argparse
import subprocess
import sys

NAMES = (["d%d" % i for i in range(8)] + ["a%d" % i for i in range(7)] +
         ["usp", "isp", "msp", "sr", "vbr", "cacr", "sfc", "dfc", "tc", "urp", "srp",
          "itt0", "itt1", "dtt0", "dtt1", "mmusr", "fpcr", "fpsr", "fpiar"] +
         ["fp%d%s" % (i, p) for i in range(8) for p in ("e", "h", "l")])


def symbols(elf):
    out = subprocess.run(["m68k-linux-gnu-nm", elf], check=True, capture_output=True,
                         text=True).stdout
    sym = {}
    for line in out.splitlines():
        f = line.split()
        if len(f) == 3:
            sym[f[2]] = int(f[0], 16)
    return sym


def read_trc(path):
    with open(path) as f:
        tok = f.read().split()
    n, nf = int(tok[0], 16), int(tok[1], 16)
    recs, p = [], 2
    for _ in range(n):
        r = {"pc": int(tok[p], 16)}
        for i in range(nf):
            if i < len(NAMES):
                r[NAMES[i]] = int(tok[p + 1 + i], 16)
        recs.append(r)
        p += 1 + nf
    return recs


def read_stream(path):
    """Events grouped by the boundary they follow: ev[n] = the accesses and
    exceptions between boundary n and boundary n+1."""
    ev = {-1: []}
    cur = -1
    with open(path) as f:
        for line in f:
            t = line.split()
            if not t:
                continue
            if t[0] == "I":
                cur = int(t[1])
                ev[cur] = []
            else:
                ev[cur].append(t)
    return ev


class Checker:
    def __init__(self, a):
        self.sym = symbols(a.elf)
        self.trc = read_trc(a.trc)
        self.bus = read_stream(a.bus)
        self.ops = read_stream(a.ops)
        self.fails = 0
        self.n = 0

    def at(self, label, nth=0):
        """The index of the boundary where label's instruction is about to run."""
        pc = self.sym[label]
        hits = [i for i, r in enumerate(self.trc) if r["pc"] == pc]
        return hits[nth] if len(hits) > nth else None

    def ok(self, cond, what, ref):
        self.n += 1
        if not cond:
            self.fails += 1
        print("  %s %s  (%s)" % ("ok  " if cond else "FAIL", what, ref))

    def reg(self, label, name, want, ref, mask=0xFFFFFFFF):
        i = self.at(label)
        if i is None:
            self.ok(False, "%s: never reached" % label, ref)
            return
        got = self.trc[i][name] & mask
        self.ok(got == want, "%s %s = %x (want %x)" % (label, name, got, want), ref)

    def between(self, stream, a, b):
        """The events between boundaries a and b (labels or indices)."""
        ia = self.at(a) if isinstance(a, str) else a
        ib = self.at(b) if isinstance(b, str) else b
        if ia is None or ib is None:
            return []
        out = []
        for n in range(ia, ib):
            out.extend(stream.get(n, []))
        return out

    def acc(self, evs, rw=None, pa=None, kind=None, data=None):
        r = []
        for t in evs:
            if t[0] not in ("R", "W"):
                continue
            if rw and t[0] != rw:
                continue
            if pa is not None and int(t[1], 16) != pa:
                continue
            if kind and t[6] != kind:
                continue
            if data is not None and int(t[3], 16) != data:
                continue
            r.append(t)
        return r

    def quirk(self, cond, what):
        print("  %s %s" % ("quirk:" if cond else "quirk GONE (update doc/oracles.md):", what))

    # ------------------------------------------------------------------
    def common(self):
        print("integer:")
        self.reg("L_int", "d1", 0x00010005, "PRM 4 DIVU")
        self.reg("L_int", "d2", 0x56781234, "PRM 4 SWAP")
        self.reg("L_int", "d3", 0x67, "PRM 4 BFEXTU")
        print("MOVEC:")
        self.reg("L_movec", "d4", 0x80008000, "UM 4.2: CACR has DE (31) and IE (15) only")
        self.reg("L_movec", "d5", 0xFFFFE364, "UM 3.1.3: TTR bits 12-10, 7, 4, 3, 1, 0 read as 0")
        self.reg("L_movec", "d6", 0x4000, "UM 3.1.2: TC bits 13-0 read as 0")
        self.reg("L_movec", "a1", 0x7000, "UM 2: MSP")
        self.reg("L_movec", "a2", 0x8000, "UM 2: ISP, the active stack with M clear")
        self.reg("L_movec", "sfc", 5, "PRM 6 MOVEC")
        print("MMU:")
        self.reg("L_remap", "d0", 0x13579BDF, "UM 3.2.1: LA $20000 through the page descriptor to PA $30000")
        ev = self.between(self.bus, "L_mmu_on", "L_remap")
        t = [int(x[1], 16) for x in self.acc(ev, "R", kind="T")]
        self.ok(t[:3] == [0x10000, 0x10200, 0x10480],
                "the search reads the root, pointer and page descriptors: %s" % " ".join("%x" % x for x in t),
                "UM 3.2.1, figure 3-8")
        self.ok(bool(self.acc(ev, "W", 0x10480, "T", 0x00030009)),
                "a read sets U in the page descriptor", "UM figure 3-10")
        self.ok(bool(self.acc(ev, "R", 0x30000, "D")), "the operand read at PA $30000", "UM 3.2.1")
        w = [x for x in ev if x[0] in "RW" and x[6] in "TF"]
        rd = [i for i, x in enumerate(w) if x[0] == "R" and x[1] == "10200"]
        wr = [i for i, x in enumerate(w) if x[0] == "W" and x[1] == "10000"]
        self.quirk(bool(rd and wr and wr[0] < rd[0]),
                   "a root/pointer descriptor's U write comes before the next level's read "
                   "(UM figure 3-10 note: after it)")
        self.quirk(not any(len(x) > 8 and x[8] == "L" for x in w),
                   "descriptor U/M updates are not locked read-modify-write cycles (UM figure 3-10)")
        ev = self.between(self.bus, "L_remap", "L_atc")
        self.ok(not self.acc(ev, kind="T"), "an ATC hit makes no table search", "UM 3.3")
        print("access error:")
        self.reg("L_fault", "d1", 0x2468ACE0, "UM 8.4.6.7: RTE restarts the faulted read")
        self.reg("L_fault", "d5", 0x7008, "UM 8.4.6: format $7, vector offset $008", 0xFFFF)
        self.reg("L_fault", "d6", 0x0505, "UM 8.4.6.2: SSW ATC, RW, SIZE long, TT 0, TM 5", 0xFFFF)
        self.reg("L_fault", "a4", 0x21000, "UM 8.4.6.4: FA, the logical address")
        self.reg("L_fault", "d7", 1, "one fault")
        h = self.at("aerr")
        if h is not None:
            self.ok(self.trc[h]["isp"] == 0x8000 - 60, "the frame is 30 words (ISP %x)" % self.trc[h]["isp"],
                    "UM 8.4.6")
            evo = self.ops.get(h - 1, [])
            pcw = [x for x in evo if x[0] == "O" and x[1] == "W" and int(x[3], 16) == 0x8000 - 60 + 2]
            self.ok(bool(pcw) and int(pcw[0][5], 16) == self.sym["L_atc"],
                    "the stacked PC is the faulted instruction's", "UM 8.2.1")
            pos = [i for i, x in enumerate(evo) if x[0] == "O"]
            vec = [i for i, x in enumerate(evo) if x[0] == "O" and x[1] == "R" and x[2] == "8"]
            frm = [i for i, x in enumerate(evo) if x[0] == "O" and x[1] == "W"]
            self.quirk(bool(vec and frm and vec[0] < frm[0]),
                       "the vector is read before the frame is written (UM 8.1: frame, then vector)")
        print("PTEST, PFLUSH, TTR:")
        self.reg("L_ptest", "d2", 0x00030001, "UM 3.1.4: MMUSR PA $30000, R")
        self.reg("L_ptest", "d3", 0, "UM 3.1.4: an invalid page, R clear")
        self.reg("L_ptest", "d4", 0x00030011, "UM 3.1.4, figure 3-10: PTESTW sets M")
        i = self.at("L_ptest")
        if i is not None:
            self.ok(not self.acc(self.bus.get(i, []), kind="T"), "PTESTW's entry is used: no search", "UM 3.3")
            self.ok(bool(self.acc(self.between(self.bus, i + 2, "L_pflush"), "R", 0x10480, "T")),
                    "after PFLUSH (An) the page is searched again", "UM 3.4.1")
        self.reg("L_ttr", "d4", 0xA5A5A5A5, "UM 3.1.3: a DTTR hit is not translated")
        self.reg("L_ttr", "d5", 3, "UM 3.1.4: PTEST of a TTR hit: T and R")
        print("data cache:")
        self.reg("L_cb1", "d1", 0xCAFEF00D, "UM 4: a copyback hit")
        ev = self.between(self.bus, "L_ttr", "L_cb1")
        self.ok(not self.acc(ev, "W", 0x22000, "D"), "a copyback write does not reach the bus", "UM 4.3")
        self.ok(len(self.acc(ev, "R", kind="C")) == 4, "a copyback write miss allocates a line", "UM 4.3")
        ev = self.between(self.bus, "L_cb1", "L_cb2")
        p = self.acc(ev, "W", kind="P")
        self.ok(bool(self.acc(ev, "W", 0x22000, "P", 0xCAFEF00D)), "CPUSHA pushes the dirty line", "UM 4.5")
        self.ok(all(x[4] == "0" and x[5] == "0" for x in p), "a push is TT 0, TM 0", "UM table 5-3")
        self.quirk(len(p) == 1, "a push writes the dirty long words only, not the line (UM 4.5, 7.4.1: a line write)")
        self.reg("L_cb3", "d2", 0xCAFEF00D, "UM 4.5: CINV invalidates without a push")
        self.ok(not self.acc(self.between(self.bus, "L_cb2", "L_end"), "W", data=0x11112222),
                "the invalidated write never reaches memory", "UM 4.5")
        self.ok(bool(self.acc(self.between(self.bus, "L_cb3", "L_wt"), "W", 0x23000, "D", 0x33334444)),
                "a write-through write reaches the bus", "UM 4.3")
        print("MOVE16:")
        self.reg("L_move16", "a0", 0x24010, "PRM 4 MOVE16: Ax += 16")
        self.reg("L_move16", "a1", 0x24110, "PRM 4 MOVE16: Ay += 16")
        self.reg("L_move16", "d3", 0x01234567, "PRM 4 MOVE16")
        self.reg("L_move16", "d4", 0x76543210, "PRM 4 MOVE16")
        ev = self.between(self.bus, "L_cb3", "L_move16")
        m = self.acc(ev, kind="M")
        self.ok(len(m) == 8 and all(x[4] == "1" and x[5] == "5" for x in m),
                "a line read and a line write, TT 1, TM 5", "UM table 5-2, 5-3")

    def fpu(self):
        print("FPU:")
        for r, (e, h) in (("fp0", (0x4000, 0xF0000000)), ("fp1", (0x4001, 0xF0000000)),
                          ("fp2", (0x4000, 0xA0000000)), ("fp3", (0x4000, 0xA0000000))):
            for lab in ("L_fp", "L_fpm"):
                i = self.at(lab)
                got = (self.trc[i][r + "e"], self.trc[i][r + "h"], self.trc[i][r + "l"]) if i is not None else None
                self.ok(got == (e, h, 0), "%s %s = %s (want %x:%08x00000000)" % (
                    lab, r, got and "%x:%08x%08x" % got, e, h), "IEEE 754, UM 9.1")
        self.reg("L_fp", "fpiar", self.sym["L_fsqrt_insn"], "UM 9.2: FPIAR, the last FP instruction")
        ev = self.between(self.ops, "L_fp", "L_fpm")
        self.ok(len([x for x in ev if x[0] == "O" and x[1] == "W"]) == 12, "FMOVEM.X writes 4 x 12 bytes",
                "PRM 5 FMOVEM")
        self.reg("L_fsave", "d5", 0x41000000, "UM 9.7: an idle frame, version $41, size $00", 0xFFFF0000)
        i = self.at("L_fsave")
        ev = self.between(self.ops, i + 1, "L_fsin") if i is not None else []
        self.ok(any(x[0] == "E" and x[1] == "11" for x in ev), "FSIN takes vector 11", "UM 9.6.1, table 9-10")
        self.reg("L_fsin", "d6", 0x202C, "UM 9.6.1: format $2, vector offset $02C", 0xFFFF)
        self.reg("L_fsin", "a2", self.sym["L_fsin"], "UM 9.6.1: the stacked PC is the next instruction's")
        self.reg("L_fsin", "d4", 0x41300000, "UM 9.7: FSAVE in the handler: the unimplemented "
                 "instruction frame, version $41, size $30", 0xFFFF0000)
        self.reg("L_fsin", "fp4e", 0, "FSIN not executed")
        fr = [x for x in ev if x[0] == "O" and x[1] == "R" and 0x7FC4 <= int(x[2], 16) < 0x7FF4]
        self.quirk(not fr, "FRESTORE of the 52-byte frame reads only its first long word (UM 9.7)")

    def lc(self):
        print("MC68LC040, FP instructions:")
        fp = [x for x in self.ops_all() if x[0] == "O" and x[1] == "W" and x[4] == "2" and x[5] == "402c"]
        e11 = [x for x in self.ops_all() if x[0] == "E" and x[1] == "11"]
        self.ok(len(e11) == 16, "every FP instruction (16) takes vector 11: %d" % len(e11), "UM A.5")
        self.ok(len(fp) == 16, "each with a format $4 frame: %d" % len(fp), "UM A.5.1, table 12-1")
        self.reg("L_end", "a6", 16, "the handler saw 16 format $4 frames")
        self.reg("L_end", "fpcr", 0, "no FPU")
        i = self.at("L_move16")
        h = self.at("fline")
        if i is not None and h is not None and h > i:
            evo = self.ops.get(h - 1, [])
            w = {int(x[3], 16) - 0x7FF0: int(x[5], 16) for x in evo if x[0] == "O" and x[1] == "W"}
            self.ok(w.get(2) == self.sym["L_move16"] + 12 and w.get(12) == self.sym["L_move16"] and w.get(8) == 0,
                    "frame: PC next, +$0C the FP instruction's PC, +$08 EA 0 for #imm "
                    "(%s)" % " ".join("+%x=%x" % kv for kv in sorted(w.items())), "UM A.5.1")

    def ops_all(self):
        for n in sorted(self.ops):
            for t in self.ops[n]:
                yield t

    def run(self, lc):
        self.common()
        if lc:
            self.lc()
        else:
            self.fpu()
        end = self.at("L_end")
        self.ok(end is not None, "the program reaches L_end", "")
        self.ok(self.at("other_end") is None, "no unexpected exception", "")
        print("%s: uae040-smoke%s, %d checks, %d failed" % (
            "PASS" if not self.fails else "FAIL", " (MC68LC040)" if lc else "", self.n, self.fails))
        return self.fails == 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--lc", action="store_true", help="the run was an MC68LC040")
    ap.add_argument("elf")
    ap.add_argument("trc")
    ap.add_argument("bus")
    ap.add_argument("ops")
    a = ap.parse_args()
    sys.exit(0 if Checker(a).run(a.lc) else 1)


if __name__ == "__main__":
    main()
