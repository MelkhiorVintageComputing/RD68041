| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M9's caches, for sim/tb/core_cache_tb.sv: phases the bench
| watches on the bus, each begun by writing its number to MARK. The bench
| counts and checks the transfers in each (UM 4, 7.4) and, at the end, the
| registers the program leaves.
|
|   1  a loop run from the instruction cache: once its lines are in, no
|      fetches at all
|   2  CPUSHL and CPUSHP of the instruction cache make code that was changed
|      visible (UM 4.2: CPUSH invalidates the lines it selects) -- D7
|   3  ITT0 makes the code cache-inhibited: long-word fetches, CIOUT asserted
|   4  a routine the bench's slave answers with TCI (UM 4.6.1): its line is
|      read every time it is called, never cached
|   0  the end

        .equ    STACK_TOP, 0x0000F000
        .equ    MARK,      0x0000FF00

        .section .vectors, "a"
        .long   STACK_TOP
        .long   _start

        .text
        .globl  _start
_start:
        cinva   %ic
        move.l  #0x00008000, %d0                 | IE
        movec   %d0, %cacr

        | --- 1: a loop from the cache ------------------------------------------
        moveq   #20, %d3
        bsr.s   loop                             | the loop's lines are filled
        move.l  #1, MARK
        moveq   #20, %d3
        bsr.s   loop                             | now it hits
        bra.s   p2
        .align  16
loop:   addq.l  #1, %d2
        rol.l   #1, %d2
        subq.l  #1, %d3
        bne.s   loop
        rts

        | --- 2: CPUSH of the instruction cache ---------------------------------
p2:     move.l  #2, MARK
        lea     patch, %a0
        jsr     (%a0)                            | moveq #1, d0
        move.l  %d0, %d7
        move.w  #0x7002, (%a0)
        cpushl  %ic, (%a0)
        jsr     (%a0)                            | moveq #2, d0
        lsl.l   #4, %d7
        or.l    %d0, %d7
        move.w  #0x7003, (%a0)
        cpushp  %ic, (%a0)
        jsr     (%a0)                            | moveq #3, d0
        lsl.l   #4, %d7
        or.l    %d0, %d7                         | $123

        | --- 3: cache-inhibited code (ITT0 over everything, CM = 11) ------------
        move.l  #0x00FFE060, %d0                 | base 0, mask $FF, E, S either, CM 11
        movec   %d0, %itt0
        move.l  #3, MARK
        moveq   #3, %d3
        bsr.s   loop
        moveq   #0, %d0
        movec   %d0, %itt0

        | --- 4: a routine whose line comes with TCI ----------------------------
        move.l  #0x70094E75, 0x3000              | moveq #9, d0; rts
        move.l  #4, MARK
        lea     0x3000, %a1
        jsr     (%a1)
        jsr     (%a1)
        jsr     (%a1)
        move.l  %d0, %d6

        move.l  #0, MARK
        illegal

        .data
        .align  16
patch:  moveq   #1, %d0
        rts
