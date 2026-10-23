| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M9's MOVE16, on the core and on UAE040 (make cosim): the five
| forms (PRM 4), addresses that are not line-aligned (the line is moved, from
| the long word the address names), the postincrement by 16, and, with the
| data cache on, a source line dirty in the cache (read from it) and a
| destination line the cache holds (invalidated, UM 4.3.3).

        .equ    STACK_TOP, 0x0000F000
        .equ    SRC,       0x00004000
        .equ    DST,       0x00005000

        .section .vectors, "a"
        .long   STACK_TOP
        .long   _start

        .text
        .globl  _start
_start:
        | A recognisable source: 64 bytes.
        lea     SRC, %a0
        move.l  #0x01020304, %d0
        moveq   #15, %d1
1:      move.l  %d0, (%a0)+
        add.l   #0x04040404, %d0
        dbf     %d1, 1b

        | --- the caches off ---------------------------------------------------
        lea     SRC, %a0
        lea     DST, %a1
        move16  (%a0)+, (%a1)+                   | line 0 -> line 0
        lea     SRC + 0x14, %a2                  | not aligned: line 1, from its long word 1
        move16  (%a2)+, DST + 0x20
        move16  SRC + 0x28, (%a1)+               | line 2 -> DST + $10
        lea     SRC + 0x30, %a3
        move16  (%a3), DST + 0x30
        lea     DST + 0x48, %a4
        move16  SRC + 0x3c, (%a4)                | line 3 -> DST + $40
        bsr     sum

        | --- the caches on, copyback over the low 16 MB -----------------------
        cinva   %bc
        move.l  #0x0000E020, %d0
        movec   %d0, %dtt0
        move.l  #0x80008000, %d0
        movec   %d0, %cacr
        lea     SRC, %a0
        move.l  #0xdeadbeef, 8(%a0)              | the source line, dirty in the cache
        move.l  DST + 0x80, %d7                  | the destination line, in the cache
        lea     DST + 0x80, %a1
        move16  (%a0)+, (%a1)+                   | from the cache, invalidating the destination
        move.l  DST + 0x88, %d6                  | $DEADBEEF: the new line, from memory
        bsr     sum
        cpusha  %dc
        moveq   #0, %d0
        movec   %d0, %cacr
        movec   %d0, %dtt0

        move.l  %sp, %d1
        illegal

| The destination's first $90 bytes, summed with rotation into D5.
sum:    lea     DST, %a5
        moveq   #0, %d5
        moveq   #35, %d2
2:      rol.l   #3, %d5
        add.l   (%a5)+, %d5
        dbf     %d2, 2b
        rts
