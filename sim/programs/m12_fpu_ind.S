| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- FP instructions with a memory indirect operand, on the core and on
| UAE040 (make cosim): the indirection's prelude reads the pointer into T3, and
| only the instruction's own micro-operations are the FPU's (bugs-found, M12).
| In and out, a single and an extended, FMOVEM of FP0-FP7 and of FPCR, FScc.

        .section .vectors, "a"
        .long   0xF000, _start
        .text
        .globl  _start
_start:
        lea     ptrs, %a0
        move.l  %a0, 0x4000
        lea     vals, %a1
        move.l  %a1, 0x4004
        fmove.l #2, %fp0
        fmove.l ([0x4004]), %fp1
        fadd.l  ([0x4004], 4), %fp1
        fmove.x ([0x4004], 8), %fp2
        fmul.x  ([0x4004], 8), %fp1
        fmove.l %fp1, ([0x4004], 32)
        fmove.l ([0x4004], 32), %fp3
        fmovem.x %fp1-%fp2, ([0x4004], 40)
        fmovem.x ([0x4004], 40), %fp4-%fp5
        fmove.l %fpcr, ([0x4004], 64)
        fseq    ([0x4004], 68)
        move.l  68(%a1), %d0
        illegal
        .balign 4
ptrs:     .long 0
vals:     .long 7, 5, 0x40000000, 0xc0000000, 0, 0, 0, 0
        .space 128
