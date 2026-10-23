| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M8's interrupts, STOP, RESET and BKPT, for sim/tb/core_exc_tb.sv
| (no oracle runs interrupts: the bench drives IPL and checks what is here
| against UM 8.2.9 and 7.5).
|
| The program asks for each interrupt by writing a long word to DOOR: the
| level in bits 2-0, how the acknowledge is to end in bits 9-8 (0 a vector,
| 1 AVEC, 2 TEA), and a delay in clocks in bits 31-16; the handler writes zero
| there, and the bench lets IPL go. Each interrupt leaves, at A5, the format
| and vector word of its frame and the system byte of the SR its handler runs
| with; the bench compares the list.

        .equ    ISP_TOP, 0x0000F000
        .equ    MSP_TOP, 0x0000E000
        .equ    DOOR,    0x0000FF00
        .equ    res,     0x0000FE00              | the results, for the bench
        .equ    lastpc,  0x0000FDF0

        .section .vectors, "a"
        .long   ISP_TOP                          | 0
        .long   _start                           | 1
        .rept   2                                | 2, 3
        .long   h_bad
        .endr
        .long   h_bkpt                           | 4  illegal: BKPT's
        .rept   19                               | 5-23
        .long   h_bad
        .endr
        .rept   8                                | 24-31: spurious, autovectors
        .long   h_int
        .endr
        .rept   32                               | 32-63
        .long   h_bad
        .endr
        .rept   192                              | 64-255: vectored interrupts
        .long   h_int
        .endr

        .text
        .globl  _start
_start:
        lea     res, %a5
        moveq   #0, %d7
        moveq   #0, %d5
        move.l  #MSP_TOP, %d0
        movec   %d0, %msp

        | (a) level 3, autovectored, the mask at 0
        move.w  #0x2000, %sr
        move.l  #0x00000103, DOOR
1:      cmp.l   #1, %d7
        bne.s   1b
        | (b) level 5, vectored: the bench's device answers vector $45
        move.l  #0x00000005, DOOR
1:      cmp.l   #2, %d7
        bne.s   1b
        | (c) level 2, TEA: the spurious interrupt
        move.l  #0x00000202, DOOR
1:      cmp.l   #3, %d7
        bne.s   1b
        | (d) level 3 under a mask of 4: not taken, until the mask comes down
        move.w  #0x2400, %sr
        move.l  #0x00000103, DOOR
        move.l  #200, %d1
1:      subq.l  #1, %d1
        bne.s   1b
        move.l  %d7, (%a5)+                      | still 3
        move.w  #0x2200, %sr
1:      cmp.l   #4, %d7
        bne.s   1b
        | (e) level 7 under a mask of 7: a transition is always taken
        move.w  #0x2700, %sr
        move.l  #0x00000107, DOOR
1:      cmp.l   #5, %d7
        bne.s   1b
        | (f) STOP, woken by level 4 a hundred clocks later; the frame's PC is
        | the instruction after it
        move.l  #0x00640104, DOOR
        stop    #0x2000
after_stop:
        move.l  lastpc, (%a5)+
        lea     after_stop, %a0
        move.l  %a0, (%a5)+
        move.w  #0x2700, %sr

        | RESET: RSTO for 512 clocks
        reset
        | BKPT: the acknowledge cycle, then the illegal instruction exception
        bkpt    #5

        | (g) level 6 with M set: a $0 frame on the MSP, M cleared, the
        | throwaway $1 on the ISP; RTE of it goes back to the MSP's. Last, so
        | that both frames are still there for the bench to read.
        move.w  #0x3000, %sr
        move.l  #0x00000106, DOOR
1:      cmp.l   #7, %d7
        bne.s   1b
        move.w  #0x2700, %sr
        movec   %msp, %d0
        move.l  %d0, (%a5)+                      | MSP_TOP again
        move.l  %sp, (%a5)+                      | ISP_TOP again
        illegal

h_int:
        clr.l   DOOR
        move.w  6(%sp), (%a5)+
        move.w  %sr, %d2
        andi.w  #0xff00, %d2
        move.w  %d2, (%a5)+
        move.l  2(%sp), lastpc
        addq.l  #1, %d7
        rte
h_bkpt:
        addq.l  #1, %d5
        addq.l  #2, 2(%sp)
        rte
h_bad:
        move.l  #0x0bad, %d6
        illegal
