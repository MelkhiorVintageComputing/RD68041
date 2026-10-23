| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M8's exception processing, on the core and on UAE040 (make cosim):
| the traps (TRAP #n, TRAPV, TRAPcc), the illegal,
| A-line and F-line instructions and BKPT, privilege violations from user mode,
| the master stack, MOVEC of the stack pointers and VBR, trace on every
| instruction and on a change of flow, RTE of $0, $2 and a throwaway $1 frame,
| a format error, NOP, RESET, and the SR's writers.
|
| The handlers keep what the frame says in registers -- D6 the format and
| vector word, D4 the stacked PC -- so the comparison at every boundary covers
| the frame as well; D7 counts exceptions, D5 traces. The format $2 frame's
| address (+$08) is not read: UAE040 stacks the next instruction's there, the
| manual the instruction's (doc/oracles.md).

        .equ    ISP_TOP, 0x0000F000
        .equ    MSP_TOP, 0x0000E000
        .equ    USP_TOP, 0x0000D000

        .section .vectors, "a"
        .long   ISP_TOP                          | 0  the reset ISP
        .long   _start                           | 1  the reset PC
        .long   h_count                          | 2  access fault
        .long   h_count                          | 3  address error
        .long   h_skip                           | 4  illegal instruction
        .long   h_count                          | 5  zero divide
        .long   h_count                          | 6  CHK, CHK2
        .long   h_count                          | 7  TRAPcc, TRAPV
        .long   h_skip                           | 8  privilege violation
        .long   h_trace                          | 9  trace
        .long   h_skip                           | 10 A-line
        .long   h_skip                           | 11 F-line
        .long   h_count, h_count                 | 12, 13
        .long   h_fmterr                         | 14 format error
        .rept   18                               | 15-32 (32: TRAP #0)
        .long   h_count
        .endr
        .long   h_super                          | 33 TRAP #1: back to supervisor
        .rept   222                              | 34-255
        .long   h_count
        .endr

        .text
        .globl  _start
_start:
        moveq   #0, %d7
        moveq   #0, %d5
        lea     USP_TOP, %a0
        move.l  %a0, %usp
        move.l  #MSP_TOP, %d0
        movec   %d0, %msp

        | --- the traps -------------------------------------------------------
        trap    #0
        trap    #15
        move.w  #0x2702, %sr                     | V set
        trapv
        move.w  #0x2700, %sr                     | V clear: no trap
        trapv
        trapt
        trapf
        move.w  #0x2704, %sr                     | Z set
        trapeq.w #0x1234
        trapne.l #0x12345678
        | CHK, CHK2 and the zero divide leave condition codes undefined (PRM
        | 4), which the handler's first boundary would compare; the sweeps
        | (make vectors-all: chk, cmp2, traps) cover them under the masks.

        | --- the illegal and unimplemented instructions -----------------------
        .word   0x4afb                           | TAS (d8,PC,Xn): illegal
        .word   0xa123                           | A-line
        .word   0xfe00                           | F-line, coprocessor 7
        bkpt    #3                               | acknowledge, then illegal

        | --- serialising ----------------------------------------------------
        nop
        reset
        move.w  #0x2500, %sr
        ori.w   #0x0200, %sr
        andi.w  #0xfaff, %sr
        eori.w  #0x0001, %sr
        move.w  %sr, %d3
        move.w  #0x2700, %sr

        | --- the master stack -------------------------------------------------
        ori.w   #0x1000, %sr                     | M: A7 is the MSP now
        move.l  %sp, %d3
        trap    #0                               | its frame on the MSP
        movec   %msp, %d3
        movec   %isp, %d4
        andi.w  #0xefff, %sr                     | back to the ISP
        movec   %msp, %d3
        movec   %isp, %d4
        move.l  #0x0000E800, %d0
        movec   %d0, %msp                        | the inactive one: held aside
        movec   %d0, %isp                        | the active one: A7
        move.l  #ISP_TOP, %d0
        movec   %d0, %isp
        move.l  #MSP_TOP, %d0
        movec   %d0, %msp

        | --- user mode -------------------------------------------------------
        andi.w  #0xdfff, %sr                     | S clear: A7 is the USP
        move.l  %sp, %d3
        move.w  %sr, %d0                         | privileged on the MC68040
        move.l  %usp, %a1                        | privileged
        trap    #0                               | the frame on the ISP
        movea.l %sp, %a3
        trap    #1                               | the handler returns to supervisor
        move.l  %sp, %d3

        | --- trace -----------------------------------------------------------
        ori.w   #0x8000, %sr                     | T1: every instruction
        moveq   #1, %d0
        addq.l  #1, %d0
        bra.s   1f
        moveq   #9, %d0                          | skipped
1:      andi.w  #0x3fff, %sr                     | traced: T1 was set when it began
        ori.w   #0x4000, %sr                     | T0: the changes of flow
        moveq   #2, %d0
        bra.s   2f
        moveq   #9, %d0                          | skipped
2:      nop
        bne.s   3f                               | not taken
        moveq   #3, %d0
3:      beq.s   4f                               | taken
        moveq   #9, %d0                          | skipped
4:      trap    #0                               | a trap is not also traced
        andi.w  #0x3fff, %sr

        | --- RTE --------------------------------------------------------------
        clr.l   -(%sp)                           | a $2 frame: ADDR
        move.w  #0x2018, -(%sp)                  | format and vector offset
        pea     r1
        move.w  #0x2704, -(%sp)                  | SR
        rte
r1:
        | A throwaway frame on the ISP over a $0 frame on the MSP (UM 8.4.2).
        movec   %msp, %a3
        subq.l  #8, %a3
        move.w  #0x2701, (%a3)
        move.l  #r2, 2(%a3)
        move.w  #0x0064, 6(%a3)
        movec   %a3, %msp
        subq.l  #8, %sp
        move.w  #0x3700, (%sp)                   | S and M: the MSP's frame next
        move.l  #0x12345678, 2(%sp)
        move.w  #0x1064, 6(%sp)
        rte
r2:
        movec   %msp, %d3
        | A format error: the frame is left where it was, below the handler's.
        subq.l  #8, %sp
        move.w  #0x2700, (%sp)
        move.l  #0x12345678, 2(%sp)
        move.w  #0xa000, 6(%sp)                  | $A: not an MC68040 frame
        rte
fe_cont:
        addq.l  #8, %sp

        | --- a vector table elsewhere ------------------------------------------
        lea     table2, %a0
        movec   %a0, %vbr
        trap    #2
        moveq   #0, %d0
        movec   %d0, %vbr
        trap    #2

        move.l  %sp, %d3
        illegal

| --- the handlers ---------------------------------------------------------
h_count:
        addq.l  #1, %d7
        move.w  6(%sp), %d6
        move.l  2(%sp), %d4
        rte
| The ones whose frame holds the instruction: past it (two bytes, all of them).
h_skip:
        addq.l  #1, %d7
        move.w  6(%sp), %d6
        addq.l  #2, 2(%sp)
        rte
h_trace:
        addq.l  #1, %d5
        move.w  6(%sp), %d6
        move.l  2(%sp), %d4
        rte
h_super:
        ori.w   #0x2000, (%sp)
        rte
h_fmterr:
        move.w  6(%sp), %d6
        move.l  #fe_cont, 2(%sp)
        rte
h_other:
        addi.l  #0x100, %d7
        move.w  6(%sp), %d6
        rte

        .data
        .align  4
table2: .rept   35
        .long   h_other
        .endr
