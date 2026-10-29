| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M15: reads released from <ea> fetch to execute before their
| answer (rd68041_core of_rel, rd68041_dmu ld_take), for make cosim: runs of
| reads of each size and offset, a read used by the next instruction, reads
| among writes and read-modify-writes, and the operations that use a read in
| execute -- a division, CHK, RTS, MOVEM. With the data cache write-through
| (the first pass after CINVA misses: the slow path, EX waiting), copyback,
| then cache-inhibited, serialised and not (DTT0, CM 10 and 11: the slot,
| which waits for the read to be the oldest), at eight alignments each.

        .equ    STACK_TOP, 0x0000F000
        .equ    BUF,       0x00008000

        .section .vectors, "a"
        .long   STACK_TOP
        .long   _start

        .text
        .globl  _start
_start:
        cinva   %bc
        move.l  #0x80008000, %d0                 | DE and IE
        movec   %d0, %cacr
        bsr     fill
        move.l  #0x13572468, %d1
        bsr     pass                             | write-through, missing
        move.l  #0x2468ACE0, %d1
        bsr     pass                             | write-through, hitting
        move.l  #0x0000E020, %d0                 | DTT0: base 0, mask 0, E, S either, CM 01
        movec   %d0, %dtt0
        move.l  #0x8899AABB, %d1
        bsr     pass                             | copyback
        cpusha  %dc
        move.l  #0x0000E040, %d0                 | CM 10: inhibited, serialised
        movec   %d0, %dtt0
        move.l  #0x0F1E2D3C, %d1
        bsr     pass
        move.l  #0x0000E060, %d0                 | CM 11: inhibited, not serialised
        movec   %d0, %dtt0
        move.l  #0x55AA33CC, %d1
        bsr     pass
        illegal

| BUF's 64 bytes, each its own.
fill:   lea     BUF, %a0
        moveq   #63, %d0
        move.l  #0x01234567, %d2
1:      move.b  %d2, (%a0)+
        rol.l   #5, %d2
        addq.l  #7, %d2
        dbra    %d0, 1b
        rts

| One pass: the patterns at BUF + 0 .. BUF + 7. D1 the value written, turned
| each time.
pass:   lea     BUF, %a0
        moveq   #7, %d7
1:
        | A run of reads, each size, each offset in a long word and across one.
        move.l  (%a0), %d2
        move.l  4(%a0), %d3
        move.l  8(%a0), %d4
        move.w  (%a0), %d5
        move.w  1(%a0), %d6
        move.w  2(%a0), %d2
        move.w  3(%a0), %d3
        move.b  (%a0), %d4
        move.b  1(%a0), %d5
        move.b  2(%a0), %d6
        move.b  3(%a0), %d2
        move.l  1(%a0), %d3
        move.l  6(%a0), %d4
        movea.l 12(%a0), %a1
        movea.w 14(%a0), %a2

        | A read used at once, as data and as an address.
        move.l  16(%a0), %d2
        add.l   %d2, %d3
        lea     BUF+32, %a3
        move.l  %a3, 20(%a0)
        movea.l 20(%a0), %a4
        move.l  (%a4), %d4
        add.l   (%a0), %d4
        sub.w   2(%a0), %d4
        and.l   4(%a0), %d4
        cmp.l   8(%a0), %d4
        seq     %d5

        | Among writes and read-modify-writes.
        move.l  %d1, 24(%a0)
        move.l  28(%a0), %d2
        move.w  %d2, 30(%a0)
        move.l  24(%a0), %d3
        addq.l  #1, 28(%a0)
        move.l  32(%a0), %d4
        add.l   %d4, 32(%a0)
        move.l  32(%a0), %d5
        not.b   33(%a0)
        move.b  33(%a0), %d6

        | What uses a read in execute.
        move.l  #0x00012345, 36(%a0)
        move.l  %d1, %d2
        andi.l  #0x007FFFFF, %d2
        move.w  #0x0123, %d3
        divu.w  38(%a0), %d2
        move.l  %d1, %d4
        andi.l  #0x00FFFFFF, %d4
        divu.l  36(%a0), %d4
        move.w  #100, 40(%a0)
        moveq   #50, %d5
        chk.w   40(%a0), %d5
        movem.l (%a0), %d2-%d6
        movem.w 2(%a0), %d2-%d4/%a5
        bsr     2f
        move.l  (%sp), %d6
        bra     3f
2:      move.l  (%a0), %d2
        rts
3:
        rol.l   #7, %d1
        addi.l  #0x01030507, %d1
        addq.l  #1, %a0
        dbra    %d7, 1b
        rts
