| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M7's first batch of the integer instruction set, run on the core
| and on UAE040 by make cosim: shifts and rotates, Scc, DBcc, TRAPcc and TRAPV
| and CHK (none taken), NEG, NEGX, NOT, ADDX, SUBX, CMPM, EXG, MULU, MULS,
| DIVU, DIVS (an overflow included, no division by zero), the bit operations,
| MOVEP, LINK, UNLK, MOVE USP, MOVEC, RTR, RTD, MOVE to and from CCR, MOVE from
| SR, and MOVEM in every mode. Nothing takes an exception: those are M8's.

        .equ    STACK_TOP, 0x0000F000

        .section .vectors, "a"
        .long   STACK_TOP
        .long   _start

        .text
        .globl  _start
_start:
        andi.b  #0x00, %ccr
        lea     buf, %a2
        lea     data, %a1

        | --- shifts and rotates ------------------------------------------------
        move.l  #0x81234567, %d0
        move.l  %d0, %d1
        asl.l   #3, %d1
        move.l  %d0, %d1
        asr.w   #1, %d1
        lsl.b   #8, %d1
        lsr.l   #4, %d1
        rol.w   #5, %d1
        ror.l   #7, %d1
        roxl.l  #2, %d1
        roxr.b  #3, %d1
        moveq   #35, %d2
        move.l  %d0, %d1
        lsl.l   %d2, %d1                | count 35: zero
        moveq   #0, %d2
        asr.l   %d2, %d1                | count 0: C cleared, X kept
        moveq   #9, %d2
        roxl.w  %d2, %d1
        move.w  #0xc001, (%a2)
        asl.w   (%a2)
        lsr.w   (%a2)
        roxr.w  (%a2)
        rol.w   (%a2)

        | --- Scc, DBcc, TRAPcc ----------------------------------------------------
        moveq   #3, %d3
        cmp.l   %d3, %d0
        slt     %d4
        sgt     %d4
        seq     2(%a2)
        st      3(%a2)
        moveq   #4, %d5
        moveq   #0, %d6
1:      addq.l  #1, %d6
        dbf     %d5, 1b                 | five times round
        moveq   #2, %d5
2:      addq.l  #1, %d6
        cmpi.l  #7, %d6
        dbeq    %d5, 2b                 | stops on the condition
        trapne                           | not taken: Z is set
        trapvs.w #0x1234
        trapf.l  #0x12345678
        trapv                            | V clear
        moveq   #10, %d7
        moveq   #5, %d3
        chk.w   %d7, %d3                 | 0 <= 5 <= 10
        chk.l   #100, %d3

        | --- NEG, NEGX, NOT, ADDX, SUBX, CMPM, EXG -----------------------------
        move.l  #0x00000001, %d0
        neg.l   %d0
        negx.l  %d0
        not.w   %d0
        move.b  #0x80, (%a2)
        neg.b   (%a2)
        moveq   #-1, %d1
        moveq   #1, %d2
        add.l   %d1, %d2                | X set
        addx.l  %d1, %d2
        subx.w  %d1, %d2
        lea     4(%a2), %a3
        lea     8(%a2), %a4
        move.l  #0x11111111, (%a3)
        move.l  #0x22222222, (%a4)
        addq.l  #4, %a3
        addq.l  #4, %a4
        addx.l  -(%a3), -(%a4)
        subx.b  -(%a3), -(%a4)
        lea     data, %a3
        lea     data, %a4
        cmpm.l  (%a3)+, (%a4)+
        cmpm.b  (%a3)+, (%a4)+
        exg     %d0, %d1
        exg     %a3, %a4
        exg     %d2, %a3

        | --- multiply and divide --------------------------------------------------
        move.l  #0x00012345, %d0
        move.w  #-3, %d1
        mulu.w  %d1, %d0
        move.l  #-7, %d2
        muls.w  #9, %d2
        move.l  #0x12345678, %d3
        mulu.l  #0x9abcdef0, %d3
        move.l  #-5, %d4
        muls.l  #0x7fffffff, %d5:%d4
        move.l  #0xfedcba98, %d6
        mulu.l  %d6, %d7:%d6
        move.l  #100000, %d0
        divu.w  #7, %d0
        move.l  #-100000, %d1
        divs.w  #7, %d1
        move.l  #0x7fffffff, %d2
        divu.w  #1, %d2                 | overflow: V set, D2 unchanged
        move.l  #1000000007, %d3
        divu.l  #12345, %d3
        move.l  #-1000000007, %d4
        divsl.l #12345, %d5:%d4
        moveq   #1, %d6
        move.l  #0x00000000, %d7
        divu.l  #3, %d6:%d7             | 64-bit dividend: $1_00000000 / 3
        move.l  #-1, %d6
        divs.l  #-1, %d6

        | --- bit operations, MOVEP ----------------------------------------------
        move.l  #0x0000ffff, %d0
        moveq   #3, %d1
        btst    %d1, %d0
        bchg    %d1, %d0
        bclr    #15, %d0
        bset    #31, %d0
        btst    #33, %d0                | modulo 32
        move.b  #0x5a, (%a2)
        btst    %d1, (%a2)
        bchg    #9, (%a2)               | modulo 8
        bset    #0, (%a2)
        bclr    %d1, (%a2)
        btst    #2, data(%pc)
        move.l  #0x11223344, %d2
        movep.l %d2, 16(%a2)
        movep.w %d2, 25(%a2)
        movep.l 16(%a2), %d3
        movep.w 25(%a2), %d4

        | --- LINK, UNLK, MOVE USP, MOVEC, MOVE to and from CCR and SR ---------
        link.w  %a6, #-16
        move.l  #0xa5a5a5a5, -4(%a6)
        unlk    %a6
        link.l  %a5, #-0x100
        unlk    %a5
        move.l  #0x3000, %a0
        move.l  %a0, %usp
        move.l  %usp, %a3
        moveq   #5, %d0
        movec   %d0, %sfc
        moveq   #2, %d0
        movec   %d0, %dfc
        movec   %sfc, %d1
        movec   %dfc, %d2
        move.l  #0x400, %d0
        movec   %d0, %vbr
        movec   %vbr, %d3
        move.l  #0x5000, %d0
        movec   %d0, %msp
        movec   %msp, %d4
        movec   %usp, %d5
        movec   %isp, %d6
        move.w  #0x0015, %d0
        move.w  %d0, %ccr
        move.w  %ccr, %d7
        move.w  %sr, %d6
        move.w  %sr, 30(%a2)
        move.w  #0, %ccr

        | --- MOVEM ------------------------------------------------------------------
        moveq   #1, %d0
        moveq   #2, %d1
        moveq   #3, %d2
        lea     0x100, %a0
        lea     0x200, %a1
        movem.l %d0-%d2/%a0-%a1, -(%sp)     | -(An)
        movem.l (%sp)+, %d3-%d5/%a3-%a4     | (An)+
        movem.w %d0-%d1, 32(%a2)            | control mode
        movem.w 32(%a2), %a5-%a6            | words, sign-extended
        lea     40(%a2), %a0
        movem.l %d0/%a0, -(%a0)             | the base in the list
        lea     40(%a2), %a0
        movem.l (%a0)+, %d6/%a0             | ... and loaded: not
        movem.l data(%pc), %d0-%d3          | PC-relative
        movem.l %d0-%d1, (%a2)              | (An)

        | --- RTR, RTD -----------------------------------------------------------
        pea     after_rtr
        move.w  #0x0011, -(%sp)
        rtr
        illegal
after_rtr:
        pea     after_rtd
        rtd     #0
        illegal
after_rtd:
        move.l  %sp, %d0
        moveq   #42, %d7
        illegal

        .align  4
data:   .long   0x01020304, 0x05060708, 0x090a0b0c, 0x0d0e0f10

        .data
        .align  4
buf:    .space  64
