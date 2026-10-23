| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M9's data cache, on the core and on UAE040 (make cosim), whose
| copyback data cache is the oracle's own (doc/oracles.md):
|
|   write-through (the mode with translation off and no TTR, UM 3.1.2): reads
|     and writes of every size, misaligned across half-lines and lines, and a
|     sweep of more lines than a set has ways, so that lines are replaced;
|   copyback (DTT0 over the low 16 MB, CM 01): writes that stay in the cache,
|     replaced dirty lines pushed, CPUSHL and CPUSHA, and CINV, which drops
|     dirty data -- the one way a program can see a copyback cache (UM 4.2);
|   cache-inhibited (DTT0, CM 11): a line the cache holds, pushed and
|     invalidated by an inhibited access to it (UM 4.3.2);
|   TAS, CAS and MOVES on cached data (UM 7.4.5: treated as noncachable).

        .equ    STACK_TOP, 0x0000F000
        .equ    BUF,       0x00004000             | 4 KB from here
        .equ    FAR,       0x00008000             | another 1 KB, the same sets

        .section .vectors, "a"
        .long   STACK_TOP
        .long   _start

        .text
        .globl  _start
_start:
        cinva   %bc
        move.l  #0x80008000, %d0                 | DE and IE
        movec   %d0, %cacr

        | --- write-through -------------------------------------------------------
        lea     BUF, %a0
        moveq   #63, %d1
1:      move.l  %d1, (%a0)+                      | 256 bytes of pattern
        dbf     %d1, 1b
        lea     BUF, %a0
        moveq   #0, %d2
        moveq   #63, %d1
2:      add.l   (%a0)+, %d2                      | read back, through the cache
        dbf     %d1, 2b
        lea     BUF + 6, %a0
        move.l  (%a0), %d3                       | across a half-line
        move.l  BUF + 14, %d4                    | across a line
        move.l  #0x11223344, BUF + 30            | a misaligned write across a line
        move.l  BUF + 28, %d5
        move.l  BUF + 32, %d6
        move.w  BUF + 31, %d7                    | an odd word
        move.b  #0x5a, BUF + 33
        move.l  BUF + 32, %d1
        add.l   %d1, %d7
        | Five lines in one set (each 1 KB apart): replacements.
        lea     BUF + 0x40, %a1
        moveq   #4, %d1
3:      move.l  (%a1), %d0
        add.l   %d0, %d2
        move.l  %d2, (%a1)
        adda.l  #0x400, %a1
        dbf     %d1, 3b
        lea     BUF + 0x40, %a1
        moveq   #4, %d1
4:      add.l   (%a1), %d3
        adda.l  #0x400, %a1
        dbf     %d1, 4b

        | --- copyback: DTT0 over $00xxxxxx, CM 01 -----------------------------------
        move.l  #0x0000E020, %d0                 | base 0, mask 0, E, S either, CM 01
        movec   %d0, %dtt0
        lea     BUF + 0x100, %a0
        moveq   #31, %d1
5:      move.l  %d1, (%a0)+                      | dirty lines
        dbf     %d1, 5b
        lea     BUF + 0x100, %a0
        moveq   #0, %d4
        moveq   #31, %d1
6:      add.l   (%a0)+, %d4
        dbf     %d1, 6b
        | Fill one set past its ways with dirty lines: pushes.
        lea     BUF + 0x200, %a1
        moveq   #5, %d1
7:      move.l  %d1, (%a1)
        move.w  %d1, 6(%a1)
        adda.l  #0x400, %a1
        dbf     %d1, 7b
        lea     BUF + 0x200, %a1
        moveq   #5, %d1
8:      add.l   (%a1), %d4
        add.w   6(%a1), %d4
        adda.l  #0x400, %a1
        dbf     %d1, 8b
        | CPUSHL, then the cache off for a read: memory has the data.
        lea     BUF + 0x300, %a2
        move.l  #0xCAFEF00D, (%a2)
        cpushl  %dc, (%a2)
        moveq   #0, %d0
        movec   %d0, %dtt0
        move.l  #0x00008000, %d0                 | IE only
        movec   %d0, %cacr
        move.l  (%a2), %d5                       | $CAFEF00D, from memory
        move.l  #0x80008000, %d0
        movec   %d0, %cacr
        move.l  #0x0000E020, %d0
        movec   %d0, %dtt0
        | CINV drops a dirty line: memory keeps what it had.
        move.l  #0x12345678, (%a2)               | the line, dirty
        move.l  (%a2), %d6                       | $12345678, from the cache
        cinvl   %dc, (%a2)
        move.l  (%a2), %d7                       | $CAFEF00D again, from memory
        | Locked and alternate accesses on a dirty line.
        lea     BUF + 0x380, %a3
        move.l  #0x00000080, (%a3)               | dirty
        tas     3(%a3)                           | pushed, then locked: N set
        move.l  (%a3), %d0
        add.l   %d0, %d6
        move.l  #0x11111111, 4(%a3)
        move.l  #0x11111111, %d0
        move.l  #0x22222222, %d1
        cas.l   %d0, %d1, 4(%a3)                 | equal: written
        add.l   4(%a3), %d6
        moveq   #5, %d0
        movec   %d0, %dfc                        | supervisor data
        movec   %d0, %sfc
        move.l  #0x33333333, 8(%a3)
        moves.l 8(%a3), %d1
        add.l   %d1, %d6
        moves.l %d6, 12(%a3)
        add.l   12(%a3), %d7
        | Everything pushed.
        cpusha  %dc

        | --- cache-inhibited: DTT0 CM 11 over the same block ----------------------
        lea     FAR, %a4
        move.l  #0x0BADBEEF, (%a4)               | copyback: in the cache, dirty
        move.l  #0x0000E060, %d0                 | CM 11
        movec   %d0, %dtt0
        move.l  (%a4), %d3                       | pushed, invalidated, read from memory
        move.l  #0x00C0FFEE, 4(%a4)
        add.l   4(%a4), %d3
        moveq   #0, %d0
        movec   %d0, %dtt0

        move.l  %sp, %d1
        illegal
