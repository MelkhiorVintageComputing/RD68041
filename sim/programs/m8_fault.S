| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M8's access faults, for sim/tb/core_fault_tb.sv: the bench makes
| every transfer to $8000-$80FF end in a bus error (TEA), and the program
| faults on it four ways -- a long-word read in supervisor mode, a word read
| in user mode, an instruction fetch, the read of TAS's locked
| read-modify-write -- each time copying what the format $7 frame says (UM
| 8.4.6) to RES and returning past the fault by RTE; then a vector fetched
| from there, during exception processing: a double bus fault (UM 8.2.1).
|
| Each record at RES, twenty bytes: the stacked SR (2), PC (4), format and
| vector word (2), SSW (2), FA (4), WB3S, WB2S, WB1S (2 each). The PCs the
| frames should hold are at RES + $80.

        .equ    ISP_TOP, 0x0000F000
        .equ    USP_TOP, 0x0000D000
        .equ    BERR,    0x00008000
        .equ    RES,     0x0000FE00
        .equ    RESUME,  0x0000FDF0
        .equ    SCRATCH, 0x0000FDE0

        .section .vectors, "a"
        .long   ISP_TOP                          | 0
        .long   _start                           | 1
        .long   h_fault                          | 2  access fault
        .rept   29                               | 3-31
        .long   h_bad
        .endr
        .long   h_bad                            | 32 TRAP #0: (e) never gets here
        .long   h_super                          | 33 TRAP #1: back to supervisor
        .rept   222
        .long   h_bad
        .endr

        .text
        .globl  _start
_start:
        lea     RES, %a5
        lea     USP_TOP, %a0
        move.l  %a0, %usp
        lea     fa1, %a0
        move.l  %a0, RES + 0x80
        lea     fb1, %a0
        move.l  %a0, RES + 0x84
        lea     fd1, %a0
        move.l  %a0, RES + 0x88

        | (a) a long-word read, supervisor data
        move.l  #fa_ret, RESUME
fa1:    move.l  BERR, %d0
fa_ret:
        | (b) a word read in user mode, user data
        move.l  #fb_ret, RESUME
        lea     BERR + 0x10, %a0
        andi.w  #0xdfff, %sr
fb1:    move.w  (%a0), %d1
fb_ret: trap    #1
        | (c) an instruction fetch: the fault is the instruction's at the target
        move.l  #fc_ret, RESUME
        jmp     BERR + 0x40
fc_ret:
        | (d) TAS: a locked read-modify-write, whose read counts as a write;
        | the locked sequence ends, and the bus goes on working
        move.l  #fd_ret, RESUME
fd1:    tas     BERR + 0x20
fd_ret:
        move.l  #0x1234, %d2
        move.l  %d2, SCRATCH
        move.l  SCRATCH, %d3

        | (f) CMPM, its second read faulting after the first moved A0: the
        | instruction restarts from where it began, A0 put back
        move.l  #ff_ret, RESUME
        lea     0x5000, %a0
        lea     BERR + 0x30, %a1
        cmpm.l  (%a0)+, (%a1)+
ff_ret: move.l  %a0, RES + 0x90
        move.l  %a1, RES + 0x94
        | (g) MOVEM, its third long word faulting after two registers were
        | loaded and A2 moved twice: all three put back
        move.l  #fg_ret, RESUME
        lea     BERR - 8, %a2
        moveq   #-1, %d0
        moveq   #-1, %d1
        movem.l (%a2)+, %d0-%d3
fg_ret: move.l  %a2, RES + 0x98
        move.l  %d0, RES + 0x9C
        move.l  %d1, RES + 0xA0

        | (e) the vector read faults while TRAP #0's frame is being built: a
        | double bus fault, and the processor halts
        move.l  #BERR, %d0
        movec   %d0, %vbr
        trap    #0
        move.l  #0x0bad, %d6                     | never

h_fault:
        move.w  (%sp), (%a5)+
        move.l  2(%sp), (%a5)+
        move.w  6(%sp), (%a5)+
        move.w  12(%sp), (%a5)+
        move.l  20(%sp), (%a5)+
        move.w  14(%sp), (%a5)+
        move.w  16(%sp), (%a5)+
        move.w  18(%sp), (%a5)+
        move.l  RESUME, 2(%sp)
        rte
h_super:
        ori.w   #0x2000, (%sp)
        rte
h_bad:
        move.l  #0x0bad, %d6
        illegal
