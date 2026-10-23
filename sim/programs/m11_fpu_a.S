| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M11's FPU, the instructions in hardware, on the core and on UAE040
| (make cosim), which compares FP0-FP7, FPCR, FPSR and FPIAR at every boundary
| as well as the integer registers:
|
|   FMOVE in from every format but packed: immediates, Dn, memory, (An)+ and
|     -(An) across the long words of a double and an extended;
|   the arithmetic (FADD, FSUB, FMUL, FDIV, FSQRT, FABS, FNEG, FSGLMUL,
|     FSGLDIV) and the FS/FD forms, in the four rounding modes and the three
|     rounding precisions (UM 9.2.2, 9.4);
|   FCMP and FTST, read by FBcc, FScc, FDBcc;
|   FMOVE out to every format but packed, rounding included, read back into
|     the integer registers;
|   FMOVEM of FP registers (static and dynamic lists, -(An), (An)+, control)
|     and of FPCR, FPSR, FPIAR;
|   FSAVE and FRESTORE of the idle frame, and FNOP.

        .equ    STACK_TOP, 0x0000F000
        .equ    BUF,       0x00004000

        .section .vectors, "a"
        .long   STACK_TOP
        .long   _start

        .text
        .globl  _start
_start:
        lea     consts, %a0
        lea     BUF, %a1

        | --- FMOVE in ------------------------------------------------------------
        fmove.l #3, %fp0
        fmove.w #-7, %fp1
        fmove.b #100, %fp2
        fmove.s #0x40490fdb, %fp3                | pi, single
        fmove.d (%a0), %fp4                      | e, double
        fmove.x 8(%a0), %fp5                     | 1/3, extended
        moveq   #-42, %d0
        fmove.l %d0, %fp6
        move.l  #0x3f800000, %d1
        fmove.s %d1, %fp7                        | 1.0
        lea     8(%a0), %a2
        fmove.x (%a2)+, %fp0                     | (An)+ over twelve bytes
        lea     20(%a0), %a2
        fmove.x -(%a2), %fp1                     | -(An)
        lea     8(%a0), %a2
        fmove.d -(%a2), %fp2

        | --- the arithmetic -------------------------------------------------------
        fmove.l #3, %fp0
        fadd.x  %fp3, %fp0                       | 3 + pi
        fsub.x  %fp4, %fp0                       | - e
        fmul.x  %fp5, %fp0                       | * 1/3
        fdiv.x  %fp3, %fp0                       | / pi
        fsqrt.x %fp0, %fp1
        fabs.x  %fp6, %fp2                       | 42
        fneg.x  %fp2, %fp6                       | -42
        fsadd.x %fp3, %fp4                       | single precision
        fdmul.x %fp5, %fp5                       | double
        fsglmul.x %fp3, %fp3
        fsgldiv.x %fp4, %fp3
        fadd.d  (%a0), %fp7
        fsub.s  #0x3f000000, %fp7                | - 0.5
        fmul.l  #-3, %fp7
        fdiv.w  #7, %fp7
        fssqrt.x %fp4, %fp2
        fdsqrt.x %fp4, %fp2
        fsabs.x %fp6, %fp1
        fdneg.x %fp1, %fp1
        fsmove.x %fp5, %fp0
        fdmove.x %fp5, %fp0

        | --- rounding modes and precisions -----------------------------------------
        moveq   #3, %d7
1:      move.l  %d7, %d0
        lsl.l   #4, %d0                          | RND in 5-4
        fmove.l %d0, %fpcr
        fmove.x %fp5, %fp0
        fadd.x  %fp3, %fp0
        fmove.l %fp0, %d1                        | to an integer in that mode
        fmove.x %fp5, %fp2
        fmul.x  %fp2, %fp2
        fmove.s %fp2, %d2
        fmove.d %fp2, (%a1)
        move.l  (%a1), %d3
        move.l  4(%a1), %d4
        dbra    %d7, 1b
        fmove.l #0x40, %fpcr                     | PREC single
        fmove.x %fp5, %fp0
        fdiv.x  %fp3, %fp0
        fmove.l #0x80, %fpcr                     | PREC double
        fmove.x %fp5, %fp1
        fdiv.x  %fp3, %fp1
        fmove.l #0, %fpcr

        | --- FCMP, FTST and the conditionals ----------------------------------------
        moveq   #0, %d5
        fcmp.x  %fp3, %fp4
        fbgt    2f
        addq.l  #1, %d5
2:      fble    3f
        addq.l  #2, %d5
3:      fseq    %d6
        fsne    %d0
        fsolt   %d1
        fsoge   %d2
        ftst.x  %fp6
        fbge    4f
        addq.l  #4, %d5
4:      fslt    %d3
        moveq   #2, %d4
5:      fdbeq   %d4, 5b
        fnop

        | --- FMOVE out --------------------------------------------------------------
        fmove.l #100, %fp0
        fmove.b %fp0, %d0
        fmove.w %fp0, %d1
        fmove.l %fp3, %d2                        | pi, rounded to 3
        fmove.s %fp3, %d3
        fmove.x %fp3, (%a1)
        move.l  (%a1), %d4
        move.l  4(%a1), %d5
        move.l  8(%a1), %d6
        fmove.d %fp5, (%a1)+
        fmove.s %fp5, (%a1)+
        fmove.x %fp5, -(%a1)
        move.l  (%a1), %d4
        move.l  4(%a1), %d5
        move.l  8(%a1), %d6
        lea     BUF, %a1

        | --- FMOVEM -----------------------------------------------------------------
        fmovem.x %fp0-%fp3, -(%sp)
        fmove.l  #0, %fp0
        fmove.l  #0, %fp1
        fmovem.x (%sp)+, %fp0-%fp3
        fmovem.x %fp2/%fp4/%fp6, (%a1)
        fmovem.x (%a1), %fp1/%fp3/%fp5
        moveq    #0x15, %d0                      | FP3, FP5, FP7 for the control modes
        fmovem.x %d0, 36(%a1)
        fmovem.x 36(%a1), %d0
        fmove.l  %fpsr, %d1
        fmove.l  %fpiar, %d2
        fmovem.l %fpcr/%fpsr/%fpiar, -(%sp)
        fmovem.l (%sp)+, %fpcr/%fpsr/%fpiar
        fmovem.l %fpcr/%fpiar, (%a1)
        move.l   (%a1), %d3
        move.l   4(%a1), %d4
        fmove.l  #0x00003400, %fpcr              | enables, no exception from here
        fmove.l  %fpcr, %d5
        fmove.l  #0, %fpcr

        | --- FSAVE, FRESTORE ----------------------------------------------------------
        fsave    -(%sp)
        move.l   (%sp), %d6
        frestore (%sp)+
        fsave    (%a1)
        move.l   (%a1), %d7
        frestore (%a1)

        illegal

        .balign 4
consts:
        .long   0x4005bf0a, 0x8b145769           | e, double
        .long   0x3ffd0000, 0xaaaaaaaa, 0xaaaaaaab | 1/3, extended
