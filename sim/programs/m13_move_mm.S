| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M13: two memory-to-memory moves with an indexed destination, as
| Linux's setup_arch has them, which rd-virt found the core running the first
| of only: its second micro-operation took the next instruction's words for
| its destination's (doc/bugs-found.md M13). Run by make cosim.

        .equ    STACK_TOP, 0x0000F000

        .section .vectors, "a"
        .long   STACK_TOP
        .long   _start

        .text
        .globl  _start
_start:
        lea     src, %a3
        moveq   #0, %d2
        move.l  cnt, %d0
        moveq   #3, %d1
        cmp.l   %d0, %d1
        blt.s   9f
        lea     dst, %a0
        move.l  4(%a3), 0(%a0,%d0.l*8)
        move.l  8(%a3), 4(%a0,%d0.l*8)
        addq.l  #1, %d0
        move.l  %d0, cnt
        andi.l  #0xffff, %d2
        adda.l  %d2, %a3
        | the same with the loop around it, twice
        moveq   #1, %d7
1:      move.l  cnt, %d0
        lea     dst, %a0
        move.l  4(%a3), 0(%a0,%d0.l*8)
        move.l  8(%a3), 4(%a0,%d0.l*8)
        addq.l  #1, %d0
        move.l  %d0, cnt
        dbra    %d7, 1b
        movem.l dst, %d0-%d7
9:      illegal

        .data
        .even
cnt:    .long   0
src:    .long   0x11111111, 0x22222222, 0x33333333, 0x44444444
dst:    .long   0, 0, 0, 0, 0, 0, 0, 0
