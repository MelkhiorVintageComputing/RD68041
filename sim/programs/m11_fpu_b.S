| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M11's FP exceptions, on the core and on UAE040 (make cosim): each
| handler loads what the exception frame and the FSAVE frame say into the data
| registers, so that the trace compares them, discards the FSAVE frame (the
| FPU is idle after FSAVE, UM 9.8) and returns.
|
|   vector 11, format $2: an unimplemented instruction (FSIN, UM 9.6.1);
|   vectors 50, 52, 49, 54: DZ, OPERR, INEX2, SNAN enabled, taken by the FP
|     instruction after the one that caused them (UM 9.7);
|   vectors 53, 51: overflow and underflow, nonmaskable (UM 9.7.4.2, 9.7.5.2);
|   vector 48: BSUN, enabled, before the conditional (UM 9.7.1);
|   FMOVE to an integer that does not fit: OPERR after it, format $3.
|
| D0: the format/vector word; D1: the stacked PC; D2: the FSAVE frame's format
| long word; D3: the long word holding E1 and E3; D4: CMDREG1B's long word.

        .equ    STACK_TOP, 0x0000F000

        .section .vectors, "a"
        .long   STACK_TOP                        | 0
        .long   _start                           | 1
        .rept   9                                | 2-10
        .long   h_bad
        .endr
        .long   h_fp                             | 11
        .rept   36                               | 12-47
        .long   h_bad
        .endr
        .rept   8                                | 48-55
        .long   h_fp
        .endr
        .rept   200
        .long   h_bad
        .endr

        .text
        .globl  _start
_start:
        moveq   #0, %d7
        lea     consts, %a0

        | (a) unimplemented: FSIN
        fmove.l #1, %fp0
        fsin.x  %fp0, %fp1
        fnop
        | (b) an unsupported data type: core_fpu_tb's (UAE040 stacks format $3
        | where UM 9.6.2 and the FPSP have $0, doc/oracles.md)
        | (c) DZ, enabled: taken by the next FP instruction
        fmove.l #0x00000400, %fpcr
        fmove.l #1, %fp3
        fdiv.l  #0, %fp3
        fnop
        fmove.l #0, %fpcr
        | (d) OPERR, enabled: 0/0
        fmove.l #0x00002000, %fpcr
        fmove.l #0, %fp4
        fdiv.x  %fp4, %fp4
        fnop
        fmove.l #0, %fpcr
        | (e) INEX2, enabled: 1/3
        fmove.l #0x00000200, %fpcr
        fmove.l #1, %fp5
        fdiv.l  #3, %fp5
        fnop
        fmove.l #0, %fpcr
        | (f) SNAN, enabled
        fmove.l #0x00004000, %fpcr
        fmove.x (%a0), %fp6                      | a signalling NaN, FMOVEM-free
        fnop
        fmove.l #0, %fpcr
        | (g) overflow, nonmaskable
        fmove.x 12(%a0), %fp0                    | 2^16000
        fmul.x  %fp0, %fp0
        fnop
        | (h) underflow, nonmaskable
        fmove.x 24(%a0), %fp1                    | 2^-16000
        fmul.x  %fp1, %fp1
        fnop
        | (i) BSUN, enabled: FBGT on an unordered compare
        fmove.l #0x00008000, %fpcr
        fmove.x 36(%a0), %fp2                    | a quiet NaN
        fcmp.x  %fp2, %fp2
        fbgt    1f
1:      fmove.l #0, %fpcr
        | (j) FMOVE to an integer that does not fit: OPERR, after it
        fmove.l #100000, %fp3
        fmove.w %fp3, %d6
        fnop

        illegal

| Every FP exception: the frames into D0-D4, the FSAVE frame dropped. BSUN's
| handler also turns its enable off, or the FBGT would take it again.
h_fp:
        move.w  6(%sp), %d0
        move.l  2(%sp), %d1
        fsave   -(%sp)
        move.l  (%sp), %d2
        moveq   #0, %d3
        moveq   #0, %d4
        cmpi.b  #0x60, 1(%sp)                    | busy: E bits at +$48, CMDREG1B +$40
        bne.s   2f
        move.l  0x48(%sp), %d3
        move.l  0x40(%sp), %d4
        bra.s   3f
2:      cmpi.b  #0x30, 1(%sp)                    | unimplemented: +$18, +$10
        bne.s   3f
        move.l  #0xFBDFFFFF, %d3                 | E1, U: UAE040 sets neither (doc/oracles.md)
        and.l   0x18(%sp), %d3
        move.l  0x10(%sp), %d4
3:      moveq   #0, %d5
        move.b  1(%sp), %d5
        addq.l  #4, %d5
        adda.l  %d5, %sp                         | the FSAVE frame dropped
        addq.l  #1, %d7
        fmove.l #0, %fpcr
        rte
h_bad:
        move.l  #0x0bad, %d6
        illegal

        .balign 4
consts:
        .long   0x7fff0000, 0x00000000, 0x00000001   | SNAN
        .long   0x7e7f0000, 0x80000000, 0x00000000   | 2^16000
        .long   0x007f0000, 0x80000000, 0x00000000   | 2^-16000
        .long   0x7fff0000, 0xc0000000, 0x00000000   | a quiet NaN
