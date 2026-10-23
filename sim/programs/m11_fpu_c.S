| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M11's FPU state frames, for sim/tb/core_fpu_tb.sv: what the
| manual and the FPSP say and UAE040 does otherwise or not at all
| (doc/oracles.md), so that only the bench can check it:
|
|   (a) FSAVE after reset: the null frame (UM 9.8);
|   (b) FSAVE after an FP instruction: the idle frame;
|   (c) FRESTORE of a null frame: FP0-FP7 NaN, FPCR zero (UM 9.2.1, 9.2.2);
|   (d) an unimplemented instruction (FSIN): vector 11, format $2, its
|       unimplemented frame with E1 and U set (UM 9.6.1, Table 9-16);
|   (e) an unsupported data type in opclass 010 (an extended denormal): vector
|       55, format $0, the PC the next instruction's (UM 9.6.2), its busy
|       frame -- E1, CMDREG1B, ETEMP as stored, STAG, NMCEXC's bit;
|   (f) DZ enabled: posted, taken by the next FP instruction, format $0 (UM
|       9.7.6), the frame the unimplemented one's size with E1 and not U;
|   (g) (e)'s busy frame FRESTOREd and FSAVEd again, unchanged;
|   (h) FRESTORE of a busy frame with CU_SAVEPC $FE and E1, E3 clear: its
|       CMDREG1B (FADD) run on ETEMP and FPTEMP, the result in FP3, the FPU
|       idle after (the FPSP's res_func.S).
|
| Each exception's handler FSAVEs the frame to the next FRM slot first, then
| stores the frame's format and vector word, PC and address long word, and
| FPIAR, in the next REC slot, and returns.

        .equ    STACK_TOP, 0x0000F000
        .equ    FRM,       0x0000E000            | 0x70 a frame
        .equ    REC,       0x0000E800            | 16 bytes an exception
        .equ    BUF2,      0x0000EC00            | (g)
        .equ    OUT,       0x0000FD00
        .equ    DONE,      0x0000FDFC

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
        lea     REC, %a5
        lea     FRM, %a4
        lea     OUT, %a3
        moveq   #0, %d6
        | The addresses the bench compares the frames with.
        move.l  #i_fsin, 48(%a3)
        move.l  #i_fsin_n, 52(%a3)
        move.l  #i_fadd, 56(%a3)
        move.l  #i_after, 60(%a3)
        move.l  #i_fdiv, 64(%a3)
        move.l  #i_fnop, 68(%a3)

        | (a) null, (b) idle
        fsave   (%a3)
        fmove.l #1, %fp0
        fsave   4(%a3)
        | (c) FRESTORE of a null frame
        fmove.l #0x00003010, %fpcr
        clr.l   -(%sp)
        frestore (%sp)+
        fmove.l %fpcr, 8(%a3)
        fmove.x %fp0, 12(%a3)

        | (d) unimplemented: FSIN
        fmove.l #1, %fp0
i_fsin: fsin.x  %fp0, %fp1
        | (e) unsupported data type: an extended denormal
i_fsin_n:
        fmove.l #1, %fp2
        lea     denorm, %a0
i_fadd: fadd.x  (%a0), %fp2
i_after:
        | (f) DZ, enabled, posted
        fmove.l #0x00000400, %fpcr
        fmove.l #1, %fp3
i_fdiv: fdiv.l  #0, %fp3
i_fnop: fnop
        fmove.l #0, %fpcr

        | (g) (e)'s frame, restored and saved again
        frestore FRM + 0x70
        fsave   BUF2
        | (h) a busy frame that resumes its operation
        lea     busy, %a0
        frestore (%a0)
        fmove.x %fp3, 24(%a3)
        fsave   36(%a3)

        move.l  #0xC0DE0000, DONE
1:      bra.s   1b

h_fp:
        fsave   (%a4)
        move.w  6(%sp), (%a5)
        move.l  2(%sp), 2(%a5)
        move.l  8(%sp), 6(%a5)
        fmove.l %fpiar, 10(%a5)
        lea     0x70(%a4), %a4
        lea     16(%a5), %a5
        rte
h_bad:
        move.l  #0x0bad, %d6
        move.l  #0xC0DE0000, DONE
2:      bra.s   2b

        .balign 4
denorm: .long   0x00000000, 0x40000000, 0x00000000   | an extended denormal
| (h): CU_SAVEPC $FE; CMDREG1B FADD.X FP0,FP3 (opclass 000); FPTEMP 2.0,
| ETEMP 1.0, both normal (STAG, DTAG 000; ETE15, FPTE15 clear); E1, E3 clear.
busy:   .long   0x41600000                       | 0: the format long word
        .long   0x00000000                       | 1
        .long   0xFE000000                       | 2: CU_SAVEPC
        .long   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 | 3-14
        .long   0x00000000                       | 15: STAG, ETE15
        .long   0x01A20000                       | 16: CMDREG1B
        .long   0x00000000                       | 17: DTAG, FPTE15
        .long   0x00000000                       | 18: E1, E3, T_BYTE
        .long   0x40000000, 0x80000000, 0x00000000 | 19-21: FPTEMP
        .long   0x3FFF0000, 0x80000000, 0x00000000 | 22-24: ETEMP
