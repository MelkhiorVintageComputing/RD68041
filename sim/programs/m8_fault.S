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
| frames should hold are at RES + $80. From (h) on the records go to RESB,
| and every frame's WB3A, WB3D, WB2A, WB2D, WB1A, WB1D/PD0, PD1-PD3 go to
| RES2, 36 bytes each:
|
|   (h) a long word write that ends in a bus error, a NOP after it, which
|       waits for it: the fault is taken there (UM 8.2.1), the write in WB1;
|   (i) a misaligned long word write to $8102, where the bench makes the
|       bus error come 40 clocks late, so that two writes behind it are queued
|       by then: WB1 memory aligned, WB2 and WB3 register aligned (UM
|       8.4.6.5), and neither of those made;
|   (j) MOVE16 whose line write faults: the line in PD0-PD3, WB1S clear
|       (UM 8.4.6.3), the instruction itself done;
|   (k) a traced write that faults: the access fault in place of the trace.

        .equ    ISP_TOP, 0x0000F000
        .equ    USP_TOP, 0x0000D000
        .equ    BERR,    0x00008000
        .equ    RES,     0x0000FE00
        .equ    RESUME,  0x0000FDF0
        .equ    SCRATCH, 0x0000FDE0
        .equ    RES2,    0x0000FA00
        .equ    RESB,    0x0000FB80

        .section .vectors, "a"
        .long   ISP_TOP                          | 0
        .long   _start                           | 1
        .long   h_fault                          | 2  access fault
        .rept   6                                | 3-8
        .long   h_bad
        .endr
        .long   h_trace                          | 9  trace
        .rept   22                               | 10-31
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
        lea     RES2, %a4
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

        lea     RESB, %a5
        | (h) a write's bus error, taken at the NOP that waits for it
        move.l  #fh_ret, RESUME
        lea     fh1, %a0
        move.l  %a0, RES + 0xA4
        move.l  #0x11223344, BERR + 0x50
fh1:    nop
fh_ret:
        | (i) a misaligned long word write whose bus error is late, two writes
        | queued behind it
        move.l  #fi_ret, RESUME
        lea     fi1, %a0
        move.l  %a0, RES + 0xA8
        lea     0x5200, %a1
        move.l  #0xAABBCCDD, BERR + 0x102
        move.w  #0xBBB2, (%a1)
        move.b  #0xC3, 3(%a1)
fi1:    nop
fi_ret:
        | (j) MOVE16 to a line that faults
        move.l  #0x01020304, 0x5100
        move.l  #0x05060708, 0x5104
        move.l  #0x090A0B0C, 0x5108
        move.l  #0x0D0E0F10, 0x510C
        move.l  #fj_ret, RESUME
        lea     fj1, %a0
        move.l  %a0, RES + 0xAC
        lea     0x5100, %a0
        lea     BERR + 0x80, %a1
        move16  (%a0)+, (%a1)+
fj1:    nop
fj_ret: move.l  %a0, RES + 0xB4
        move.l  %a1, RES + 0xB8
        | (k) a traced write that faults
        move.l  #fk_ret, RESUME
        lea     fk1, %a0
        move.l  %a0, RES + 0xBC
        move.l  #0x0000ABCD, %d0
        ori.w   #0x8000, %sr
        move.l  %d0, BERR + 0x90
fk1:    nop
fk_ret: andi.w  #0x3FFF, %sr

        | (e) the vector read faults while TRAP #0's frame is being built: a
        | double bus fault, and the processor halts
        move.l  #BERR, %d0
        movec   %d0, %vbr
        trap    #0
        move.l  #0x0bad, %d6                     | never

h_fault:
        move.l  0x18(%sp), (%a4)+
        move.l  0x1C(%sp), (%a4)+
        move.l  0x20(%sp), (%a4)+
        move.l  0x24(%sp), (%a4)+
        move.l  0x28(%sp), (%a4)+
        move.l  0x2C(%sp), (%a4)+
        move.l  0x30(%sp), (%a4)+
        move.l  0x34(%sp), (%a4)+
        move.l  0x38(%sp), (%a4)+
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
h_trace:
        addq.l  #1, RES + 0xB0                   | (k): traces taken
        andi.w  #0x3FFF, (%sp)
        rte
h_bad:
        move.l  #0x0bad, %d6
        illegal
