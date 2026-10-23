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
|   5  the data cache, write-through: a read miss is a line read, a write
|      goes to the bus hit or not, a hit is no transfer at all
|   6  copyback (DTT0 over $01xxxxxx, the same memory: the slave repeats it):
|      writes stay in the cache, a dirty line replaced is pushed (TM 000; a
|      long word for one dirty long word, a line for more, UM 4.6.2), and
|      CPUSHA pushes the rest
|   7  cache-inhibited (DTT1 over $02xxxxxx): every read on the bus, CIOUT
|   8  TAS on a dirty line: the push, then the locked read (UM 7.4.5)
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
        nop                                      | (later reads must not pass it)
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
        nop                                      | (later reads must not pass it)
        moveq   #3, %d3
        bsr.s   loop
        moveq   #0, %d0
        movec   %d0, %itt0

        | --- 4: a routine whose line comes with TCI ----------------------------
        move.l  #0x70094E75, 0x3000              | moveq #9, d0; rts
        move.l  #4, MARK
        nop                                      | (later reads must not pass it)
        lea     0x3000, %a1
        jsr     (%a1)
        jsr     (%a1)
        jsr     (%a1)
        move.l  %d0, %d6

        | --- 5: the data cache, write-through ---------------------------------
        move.l  #0x80008000, %d0                 | DE and IE
        movec   %d0, %cacr
        cinva   %dc
        move.l  #5, MARK
        nop                                      | (later reads must not pass it)
        lea     0x5000, %a0
        move.l  (%a0), %d0                       | a miss: one line read
        move.l  4(%a0), %d1                      | a hit
        move.l  %d0, 8(%a0)                      | written through, hit or not
        move.l  8(%a0), %d2                      | a hit
        add.l   %d1, %d2

        | --- 6: copyback, DTT0 over $01xxxxxx ------------------------------------
        move.l  #0x0100E020, %d0                 | base $01, mask 0, E, S either, CM 01
        movec   %d0, %dtt0
        move.l  #6, MARK
        nop                                      | (later reads must not pass it)
        lea     0x01006000, %a1
        moveq   #4, %d1
1:      move.l  %d1, (%a1)                       | five lines of one set, one dirty long each
        adda.l  #0x400, %a1
        dbf     %d1, 1b
        move.l  #7, 0x01006004                   | the fifth line's, now two dirty long words
        cpusha  %dc                              | the four left pushed

        | --- 7: cache-inhibited, DTT1 over $02xxxxxx, CM 11 -----------------------
        move.l  #0x0200E060, %d0
        movec   %d0, %dtt1
        move.l  #7, MARK
        nop                                      | (later reads must not pass it)
        move.l  0x02007000, %d3                  | on the bus, CIOUT
        move.l  0x02007000, %d4                  | again
        moveq   #0, %d0
        movec   %d0, %dtt1

        | --- 8: TAS on a dirty copyback line --------------------------------------
        move.l  #8, MARK
        nop                                      | (later reads must not pass it)
        move.l  #0x00000080, 0x01006800          | dirty
        tas     0x01006803                       | the push, then the locked read
        moveq   #0, %d0
        movec   %d0, %dtt0
        cpusha  %dc

        move.l  #0, MARK
        nop                                      | (later reads must not pass it)
        illegal

        .data
        .align  16
patch:  moveq   #1, %d0
        rts
