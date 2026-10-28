#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041
"""RD68041 -- integer instruction timings against UM section 10 (make cycles).

  cycles.py gen OUT.S        the program sim/tb/core_cycles_tb.sv runs
  cycles.py report LOG       the table doc/timing-divergences.md carries

Each case is one instruction (or a pair that must go together, JSR and RTS)
repeated N times in a straight line, run three times so that both caches are
warm on the last pass -- UM 10.1's assumption 2, "all memory accesses hit in
the caches". The bench counts the clocks (BCLK) between the retirement of the
first copy and of the last on that pass: divided by N - 1, the clocks each
copy takes in a run of them.

UM 10 gives two numbers per instruction: the clocks it spends in <ea>
calculate, and in execute, the latter as a lead time and a base time ("2L +
1"), the lead time being clocks it can wait to enter execute without delaying
it. In a run of copies of one instruction the two stages overlap, and the
lead time with the calculate time of the copy before, so the part's rate is
the larger of the calculate time and the base time: that is the "UM, a run"
column, with which the measurement is compared.
"""

import re
import sys

N = 16                 # copies per case
DATA = 0xC000          # data the cases address (a0 points here)
ISP = 0xF000

# The registers every pass starts with. D7 is the pass counter.
COMMON = [
    "lea     0x%x, %%a0" % DATA,
    "lea     0x%x, %%a1" % (DATA + 0x100),
    "lea     0x%x, %%a2" % (DATA + 0x600),
    "lea     0x%x, %%a3" % (DATA + 0x200),
    "lea     0x%x, %%a4" % (DATA + 0x300),
    "lea     0x%x, %%a5" % (DATA + 0x900),
    "lea     0x%x, %%sp" % ISP,
    "moveq   #3, %d1",
    "moveq   #2, %d2",
    "move.l  #0x2700, %d3",
    "moveq   #4, %d4",
    "moveq   #1, %d5",
    "move.l  #1000, %d6",
    "moveq   #0, %d0",
]

# (table, instruction, <ea> calculate, execute, assembly, setup)
# The UM columns are as printed (BCLK); where a cell gives T1/T2 the one that
# applies to the form measured is taken.
C = []


def case(group, name, calc, exe, asm, setup=()):
    C.append((group, name, calc, exe, asm, list(setup)))


# --- UM 10.4: MOVE --------------------------------------------------------------
case("MOVE", "MOVE.L Dn,Dn", 1, "1", "move.l %d1, %d0")
case("MOVE", "MOVE.L (An),Dn", 1, "1", "move.l (%a0), %d0")
case("MOVE", "MOVE.L (An)+,Dn", 1, "1", "move.l (%a1)+, %d0")
case("MOVE", "MOVE.L -(An),Dn", 1, "1", "move.l -(%a2), %d0")
case("MOVE", "MOVE.L (d16,An),Dn", 1, "1", "move.l (8,%a0), %d0")
case("MOVE", "MOVE.L (d16,PC),Dn", 3, "2L+1", "move.l (pcdat,%pc), %d0")
case("MOVE", "MOVE.L (xxx).L,Dn", 1, "1", "move.l (0x%x).l, %%d0" % DATA)
case("MOVE", "MOVE.L #<xxx>,Dn", 1, "1", "move.l #0x12345678, %d0")
case("MOVE", "MOVE.L (d8,An,Xn),Dn", 3, "3", "move.l (8,%a0,%d4.l), %d0")
case("MOVE", "MOVE.L (d8,PC,Xn),Dn", 5, "1L+4", "move.l (pcdat,%pc,%d4.l), %d0")
case("MOVE", "MOVE.L (bd,An,Xn),Dn", 7, "1L+6", "move.l (0x100,%a0,%d4.l), %d0")
case("MOVE", "MOVE.L ([bd,An,Xn]),Dn", 10, "1L+9", "move.l ([0x10,%a0,%d4.l]), %d0")
case("MOVE", "MOVE.L ([bd,An,Xn],od),Dn", 11, "1L+10", "move.l ([0x10,%a0,%d4.l],4), %d0")
case("MOVE", "MOVE.L ([bd,An],Xn),Dn", 11, "3L+8", "move.l ([0x10,%a0],%d4.l), %d0")
case("MOVE", "MOVE.L ([bd,An],Xn,od),Dn", 12, "3L+9", "move.l ([0x10,%a0],%d4.l,4), %d0")
case("MOVE", "MOVE.L Dn,(An)", 1, "1", "move.l %d1, (%a0)")
case("MOVE", "MOVE.L Dn,(An)+", 1, "1", "move.l %d1, (%a1)+")
case("MOVE", "MOVE.L Dn,-(An)", 1, "1", "move.l %d1, -(%a2)")
case("MOVE", "MOVE.L Dn,(d16,An)", 1, "1", "move.l %d1, (8,%a0)")
case("MOVE", "MOVE.L Dn,(xxx).L", 1, "1", "move.l %%d1, (0x%x).l" % DATA)
case("MOVE", "MOVE.L Dn,(d8,An,Xn)", 3, "3", "move.l %d1, (8,%a0,%d4.l)")
case("MOVE", "MOVE.L #<xxx>,(An)", 1, "1", "move.l #0x12345678, (%a0)")
case("MOVE", "MOVE.L (An),(An)", 1, "1", "move.l (%a0), (%a3)")
case("MOVE", "MOVE.L (An)+,(An)+", 2, "1L+1", "move.l (%a1)+, (%a3)+")
case("MOVE", "MOVE.L (An),(d16,An)", 2, "1L+1", "move.l (%a0), (8,%a3)")
case("MOVE", "MOVE.L (d8,An,Xn),(d8,An,Xn)", 8, "8", "move.l (8,%a0,%d4.l), (8,%a3,%d4.l)")
case("MOVE", "MOVEA.L (An),An", 1, "1", "movea.l (%a0), %a4")
case("MOVE", "MOVEQ", 1, "1", "moveq #5, %d0")

# --- UM 10.5: miscellaneous ----------------------------------------------------------
case("misc", "ABCD Dy,Dx", 1, "3", "abcd %d1, %d0")
case("misc", "ABCD -(Ay),-(Ax)", 3, "1L+3", "abcd -(%a2), -(%a5)")
case("misc", "ADDX.L Dy,Dx", 1, "1", "addx.l %d1, %d0")
case("misc", "ADDX.L -(Ay),-(Ax)", 3, "1L+2", "addx.l -(%a2), -(%a5)")
case("misc", "ANDI #<xxx>,CCR", 1, "4", "andi.b #0x1f, %ccr")
case("misc", "ANDI #<xxx>,SR", 9, "1L+8", "andi.w #0x271f, %sr")
case("misc", "Bcc.W, taken (BRA)", 2, "2", "bra.w .+4")
case("misc", "Bcc.W, not taken", 3, "3", "beq.w .+4", ["moveq #1, %d0"])
case("misc", "BSR.W + RTS", "2+5", "1L+1 + 5", "bsr.w sub_rts")
case("misc", "CMPM.L", 3, "1L+2", "cmpm.l (%a1)+, (%a3)+")
case("misc", "DBcc, false, count > -1", 3, "3", "dbf %d6, .+4")
case("misc", "EXG Dy,Dx", 1, "1", "exg %d1, %d2")
case("misc", "EXG Ay,Ax", 2, "1L+1", "exg %a3, %a4")
case("misc", "EXT.W", 1, "2", "ext.w %d0")
case("misc", "EXT.L", 1, "1", "ext.l %d0")
case("misc", "EXTB.L", 1, "1", "extb.l %d0")
case("misc", "LINK + UNLK", "3+2", "2L+1 + 1L+1", "link %a6, #-8\n        unlk %a6")
case("misc", "MOVE USP,An", 3, "2L+1", "move.l %usp, %a4")
case("misc", "MOVE An,USP", 7, "1L+6", "move.l %a4, %usp")
case("misc", "MOVE16 (Ax)+,(Ay)+", 6, "1L+7", "move16 (%a1)+, (%a3)+")
case("misc", "MOVEC Rc,Rn (VBR)", 11, "1L+10", "movec %vbr, %d0")
case("misc", "MOVEC Rn,Rc (VBR)", 7, "1L+6", "movec %d0, %vbr", ["moveq #0, %d0"])
case("misc", "MOVEP.W Dn,(d16,An)", 11, "2L+9", "movep.w %d0, (0,%a0)")
case("misc", "MOVEP.L Dn,(d16,An)", 13, "2L+11", "movep.l %d0, (0,%a0)")
case("misc", "MOVEP.W (d16,An),Dn", 4, "2L+5", "movep.w (0,%a0), %d0")
case("misc", "MOVEP.L (d16,An),Dn", 8, "2L+8", "movep.l (0,%a0), %d0")
case("misc", "NOP", 8, "1L+7", "nop")
case("misc", "ORI #<xxx>,CCR", 1, "4", "ori.b #0, %ccr")
case("misc", "PACK Dx,Dy,#", 1, "3", "pack %d1, %d0, #0")
case("misc", "PACK -(Ax),-(Ay),#", 3, "2L+3", "pack -(%a2), -(%a5), #0")
case("misc", "SBCD Dy,Dx", 1, "3", "sbcd %d1, %d0")
case("misc", "SUBX.L Dy,Dx", 1, "1", "subx.l %d1, %d0")
case("misc", "SWAP", 1, "2", "swap %d0")
case("misc", "TRAPcc, not taken (TRAPF)", 5, "5", "trapf")
case("misc", "TRAPV, not taken", 5, "5", "trapv", ["moveq #0, %d0"])
case("misc", "UNPK Dx,Dy,#", 1, "4", "unpk %d1, %d0, #0")
case("misc", "UNPK -(Ax),-(Ay),#", 3, "2L+4", "unpk -(%a2), -(%a5), #0")

# --- UM 10.6: the integer unit ---------------------------------------------------------
case("integer", "ADD.L Dn,Dn", 1, "1", "add.l %d1, %d0")
case("integer", "ADD.L (An),Dn", 1, "1", "add.l (%a0), %d0")
case("integer", "ADD.L (An)+,Dn", 1, "1", "add.l (%a1)+, %d0")
case("integer", "ADD.L -(An),Dn", 1, "1", "add.l -(%a2), %d0")
case("integer", "ADD.L (d16,An),Dn", 1, "1", "add.l (8,%a0), %d0")
case("integer", "ADD.L (d16,PC),Dn", 3, "2L+1", "add.l (pcdat,%pc), %d0")
case("integer", "ADD.L #<xxx>,Dn", 1, "1", "add.l #0x11, %d0")
case("integer", "ADD.L (d8,An,Xn),Dn", 3, "3", "add.l (8,%a0,%d4.l), %d0")
case("integer", "ADD.L (bd,An,Xn),Dn", 7, "1L+6", "add.l (0x100,%a0,%d4.l), %d0")
case("integer", "ADD.L ([bd,An,Xn]),Dn", 10, "1L+9", "add.l ([0x10,%a0,%d4.l]), %d0")
case("integer", "ADD.L Dn,(An)", 1, "1", "add.l %d1, (%a0)")
case("integer", "ADD.L Dn,(d16,An)", 1, "1", "add.l %d1, (8,%a0)")
case("integer", "ADDA.L Dn,An", 1, "2", "adda.l %d1, %a4")
case("integer", "ADDA.L (An),An", 1, "2", "adda.l (%a0), %a4")
case("integer", "ADDI.L #<xxx>,Dn", 1, "1", "addi.l #0x11, %d0")
case("integer", "ADDI.L #<xxx>,(An)", 1, "1", "addi.l #0x11, (%a0)")
case("integer", "ADDQ.L #,Dn", 1, "1", "addq.l #1, %d0")
case("integer", "ADDQ.L #,An", 1, "1", "addq.l #1, %a4")
case("integer", "ADDQ.L #,(An)", 1, "1", "addq.l #1, (%a0)")
case("integer", "ASL.L #,Dn", 1, "3", "asl.l #1, %d0")
case("integer", "ASL.L Dn,Dn", 1, "4", "asl.l %d5, %d0")
case("integer", "ASR.L #,Dn", 1, "2", "asr.l #1, %d0")
case("integer", "LSR.L Dn,Dn", 1, "3", "lsr.l %d5, %d0")
case("integer", "LSL.W (An)", 1, "2", "lsl.w (%a0)")
case("integer", "ROL.L #,Dn", 1, "3", "rol.l #1, %d0")
case("integer", "ROXL.L #,Dn", 1, "5", "roxl.l #1, %d0")
case("integer", "BCHG #,Dn", 1, "3", "bchg #1, %d0")
case("integer", "BCHG Dn,Dn", 1, "4", "bchg %d5, %d0")
case("integer", "BSET #,(An)", 1, "3", "bset #1, (%a0)")
case("integer", "BTST #,Dn", 1, "1", "btst #1, %d0")
case("integer", "BTST Dn,(An)", 1, "2", "btst %d5, (%a0)")
case("integer", "BFCHG Dn{#:#}", 3, "6", "bfchg %d0{#4:#8}")
case("integer", "BFCHG (An){#:#}", 9, "2L+8", "bfchg (%a0){#4:#8}")
case("integer", "BFEXTU Dn{#:#},Dn", 1, "4", "bfextu %d0{#4:#8}, %d1")
case("integer", "BFEXTU (An){#:#},Dn", 9, "2L+7", "bfextu (%a0){#4:#8}, %d1")
case("integer", "BFFFO Dn{#:#},Dn", 3, "6", "bfffo %d0{#4:#8}, %d1")
case("integer", "BFINS Dn,Dn{#:#}", 2, "5", "bfins %d1, %d0{#4:#8}")
case("integer", "BFTST Dn{#:#}", 1, "3", "bftst %d0{#4:#8}")
case("integer", "CAS.L Dc,Du,(An)", 36, "6L+31", "cas.l %d1, %d2, (%a0)")
case("integer", "CHK.L Dn,Dn (in bounds)", 8, "1L+7", "chk.l %d1, %d0")
case("integer", "CHK2.L (An),Dn (in bounds)", 11, "2L+9", "chk2.l (%a0), %d0",
     ["clr.l (%a0)", "move.l #0x7fffffff, (4,%a0)", "moveq #5, %d0"])
case("integer", "CLR.L Dn", 1, "1", "clr.l %d0")
case("integer", "CLR.L (An)", 1, "1", "clr.l (%a0)")
case("integer", "CMP.L Dn,Dn", 1, "1", "cmp.l %d1, %d0")
case("integer", "CMP.L (An),Dn", 1, "1", "cmp.l (%a0), %d0")
case("integer", "CMPA.L Dn,An", 1, "1", "cmpa.l %d1, %a4")
case("integer", "CMPI.L #<xxx>,Dn", 1, "1", "cmpi.l #0x11, %d0")
case("integer", "CMP2.L (An),Dn (in bounds)", 13, "2L+11", "cmp2.l (%a0), %d0",
     ["clr.l (%a0)", "move.l #0x7fffffff, (4,%a0)", "moveq #5, %d0"])
case("integer", "DIVU.W Dn,Dn", 8, "27", "divu.w %d1, %d0",
     ["move.w #0x7fff, %d1", "move.l #0x12345, %d0"])
case("integer", "DIVS.L Dn,Dn", 9, "44", "divs.l %d1, %d0", ["move.l #0x7fffffff, %d0"])
case("integer", "DIVU.L Dn,Dn", 9, "44", "divu.l %d1, %d0", ["move.l #0x7fffffff, %d0"])
case("integer", "JMP (d16,PC)", 3, "2L+1", ".word 0x4efa, 0x0002")
case("integer", "JSR (An) + RTS", "3+5", "2L+1 + 5", "jsr (%a4)", ["lea sub_rts, %a4"])
case("integer", "LEA (An),An", 1, "1", "lea (%a0), %a4")
case("integer", "LEA (d16,PC),An", 4, "3L+1", "lea (pcdat,%pc), %a4")
case("integer", "LEA (d8,PC,Xn),An", 5, "1L+4", "lea (pcdat,%pc,%d4.l), %a4")
case("integer", "MOVE CCR,Dn", 1, "2", "move.w %ccr, %d0")
case("integer", "MOVE Dn,CCR", 1, "2", "move.w %d0, %ccr")
case("integer", "MOVE SR,Dn", 2, "1L+2", "move.w %sr, %d0")
case("integer", "MOVE Dn,SR", 9, "1L+8", "move.w %d3, %sr")
case("integer", "MOVEM.L 4 Dn,(An)", "2+4", "1L+1+4", "movem.l %d0-%d3, (%a3)")
case("integer", "MOVEM.L (An),4 Dn", "3+4", "1L+2+4", "movem.l (%a0), %d0-%d3")
case("integer", "MULS.W Dn,Dn", 1, "16", "muls.w %d1, %d0")
case("integer", "MULU.W Dn,Dn", 1, "14", "mulu.w %d1, %d0")
case("integer", "MULS.L Dn,Dn", 1, "20", "muls.l %d1, %d0")
case("integer", "MULU.L Dn,Dn", 1, "20", "mulu.l %d1, %d0")
case("integer", "NBCD Dn", 1, "3", "nbcd %d0")
case("integer", "NEG.L Dn", 1, "1", "neg.l %d0")
case("integer", "NOT.L (An)", 1, "1", "not.l (%a0)")
case("integer", "PEA (An)", 2, "1L+1", "pea (%a0)")
case("integer", "Scc Dn (ST)", 1, "2", "st %d0")
case("integer", "Scc (An) (SEQ)", 1, "2", "seq (%a0)")
case("integer", "SUBA.L Dn,An", 1, "1", "suba.l %d1, %a4")
case("integer", "TAS Dn", 1, "2", "tas %d0")
case("integer", "TAS (An)", 26, "2L+24", "tas (%a0)")
case("integer", "TST.L Dn", 1, "1", "tst.l %d0")
case("integer", "TST.L (An)", 1, "1", "tst.l (%a0)")


def um_parts(s):
    """'2L+1' -> (lead, base); '1L+1 + 5' (a pair) -> summed; '3+5' too."""
    lead = base = 0
    for part in str(s).split("+"):
        part = part.strip()
        if not part:
            continue
        m = re.fullmatch(r"(\d+)L", part)
        if m:
            lead += int(m.group(1))
        else:
            base += int(part)
    return lead, base


def um_run(calc, exe):
    """The part's clocks per copy in a run of them: max(calculate, base),
    per instruction of a pair, summed."""
    if " + " in str(exe):
        # a pair: calculate "a+b", execute "x + y"
        ca = [int(x) for x in str(calc).split("+")]
        ex = [um_parts(e)[1] for e in str(exe).split(" + ")]
        return sum(max(c, e) for c, e in zip(ca, ex))
    c = sum(int(x) for x in str(calc).split("+"))
    return max(c, um_parts(exe)[1])


def gen(out):
    L = []
    w = L.append
    w("| Generated by tools/cycles/cycles.py: integer timings, for core_cycles_tb.")
    w("        .equ    DATA, 0x%x" % DATA)
    w("        .section .vectors, \"a\"")
    w("        .long   0x%x" % ISP)
    w("        .long   _start")
    w("        .rept   254")
    w("        .long   h_bad")
    w("        .endr")
    w("        .text")
    w("        .globl  _start")
    w("_start: bra.w   main")
    w("        .long   table                    | at $1004, for the bench")
    w("pcdat:  .long   0x11111111, 0x22222222, 0x33333333, 0x44444444")
    w("sub_rts: rts")
    w("h_bad:  bra.s   h_bad")
    w("main:")
    # Everything cachable: the data copyback, instructions too (UM 4: TTRs).
    w("        move.l  #0x00FFC020, %d0          | DTT0: all, copyback")
    w("        movec   %d0, %dtt0")
    w("        move.l  #0x00FFC000, %d0          | ITT0: all, cachable")
    w("        movec   %d0, %itt0")
    w("        cinva   %bc")
    w("        move.l  #0x80008000, %d0          | DE, IE")
    w("        movec   %d0, %cacr")
    w("        lea     DATA, %a0")
    w("        move.l  %a0, (0x10,%a0)           | the memory-indirect pointers")
    w("        move.l  %a0, (0x14,%a0)")
    for i, (_, name, calc, exe, asm, setup) in enumerate(C):
        w("| %d: %s" % (i, name))
        w("c%d:     moveq   #2, %%d7" % i)
        w("c%d_p:" % i)
        for s in COMMON + setup:
            w("        " + s)
        w("        .balignw 4, 0x51fc               | TRAPF: a word of padding that does nothing")
        lines = asm.split("\n")
        for k in range(N):
            for j, ln in enumerate(lines):
                lab = ("c%d_f: " % i if k == 0 and j == 0 else
                       "c%d_l: " % i if k == N - 1 and j == 0 else "       ")
                w(lab + " " + ln.strip())
        w("        dbra    %%d7, c%d_p" % i)
    w("        moveq   #0, %d0")
    w("        movec   %d0, %cacr")
    w("end:    bra.s   end")
    w("        .balign 4")
    w("table:  .long   %d" % len(C))
    for i in range(len(C)):
        w("        .long   c%d_f, c%d_l" % (i, i))
    open(out, "w").write("\n".join(L) + "\n")


def report(log):
    got = {}
    for ln in open(log):
        m = re.match(r"CYC (\d+) (\d+)$", ln.strip())
        if m:
            got[int(m.group(1))] = int(m.group(2))
    if len(got) != len(C):
        print("cycles: %d of %d cases measured" % (len(got), len(C)), file=sys.stderr)
        return 1
    same = slower = faster = 0
    cur = None
    print("| Instruction | UM \\<ea\\> calc. | UM execute | UM, a run | Here | Here − UM |")
    print("|---|---|---|---|---|---|")
    for i, (group, name, calc, exe, _, _) in enumerate(C):
        here = got[i] / (N - 1)
        um = um_run(calc, exe)
        d = here - um
        if abs(d) < 0.05:
            same += 1
        elif d > 0:
            slower += 1
        else:
            faster += 1
        hs = ("%d" % round(here)) if abs(here - round(here)) < 0.05 else "%.2f" % here
        ds = "=" if abs(d) < 0.05 else (("+%s" if d > 0 else "%s") %
                                         (("%d" % round(d)) if abs(d - round(d)) < 0.05 else "%.2f" % d))
        print("| %s | %s | %s | %d | %s | %s |" % (name, calc, exe.replace(" + ", " ; "), um, hs, ds))
    print()
    print("%d cases: %d the same, %d slower, %d faster" % (len(C), same, slower, faster))
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "gen":
        gen(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == "report":
        sys.exit(report(sys.argv[2]))
    else:
        print(__doc__)
        sys.exit(2)
