| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M9's instruction cache, on the core and on UAE040 (make cosim):
| the cache invalidated and enabled (UM 4.2), loops that run from it, code
| that crosses lines and half-lines, and code that is changed and made
| coherent again by CINV by line, by page and whole and by CPUSHA (UM 4.5:
| the instruction cache does not watch data writes) -- the only
| self-modifying code whose outcome the manual defines. Not CPUSHL or CPUSHP
| of the instruction cache: UAE040 does not invalidate it for them
| (doc/oracles.md); core_cache_tb checks those.

        .equ    STACK_TOP, 0x0000F000

        .section .vectors, "a"
        .long   STACK_TOP
        .long   _start

        .text
        .globl  _start
_start:
        cinva   %ic
        move.l  #0x00008000, %d0                 | IE
        movec   %d0, %cacr
        movec   %cacr, %d1

        | --- a loop that runs from the cache -----------------------------------
        moveq   #0, %d2
        moveq   #40, %d3
1:      add.l   %d3, %d2
        addq.l  #3, %d2
        rol.l   #1, %d2
        subq.l  #1, %d3
        bne.s   1b

        | --- a nest, across lines --------------------------------------------
        moveq   #5, %d4
        moveq   #0, %d5
2:      moveq   #7, %d6
3:      add.l   %d6, %d5
        eor.l   %d4, %d5
        nop
        nop
        nop
        nop
        dbf     %d6, 3b
        dbf     %d4, 2b

        | --- code that changes: patch, make coherent, run ------------------------
        lea     patch, %a0
        jsr     (%a0)                            | moveq #1, d0, as built
        move.l  %d0, %d7
        move.w  #0x7002, (%a0)                   | moveq #2, d0
        cinva   %ic                              | everything
        jsr     (%a0)
        add.l   %d0, %d7
        move.w  #0x7003, (%a0)                   | moveq #3, d0
        cinvl   %ic, (%a0)
        jsr     (%a0)
        add.l   %d0, %d7
        move.w  #0x7004, (%a0)                   | moveq #4, d0
        cinvp   %ic, (%a0)                       | the page
        jsr     (%a0)
        add.l   %d0, %d7
        move.w  #0x7005, (%a0)                   | moveq #5, d0
        cpusha  %bc                              | everything
        jsr     (%a0)
        add.l   %d0, %d7

        | --- the cache off again ---------------------------------------------
        moveq   #0, %d0
        movec   %d0, %cacr
        moveq   #3, %d3
4:      addq.l  #1, %d2
        dbf     %d3, 4b

        move.l  %sp, %d3
        illegal

        .data
        .align  16
patch:  moveq   #1, %d0
        rts
