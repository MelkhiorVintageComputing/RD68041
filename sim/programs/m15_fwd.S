| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M15: reads answered from the write queue (rd68041_dmu, fwd), for
| make cosim: a write and then, while it is still queued, reads of the bytes
| it holds -- the same size, a smaller one at each offset, a partial overlap
| (which must wait for the write instead), two writes to one long word (the
| younger answers), accesses across a long word (which are not forwarded),
| read-modify-writes of memory (their read now fast too), and the stack's
| pushes and pops. Every value read lands in a register, which the cosim
| compares at each boundary. With the data cache write-through, then
| copyback (DTT0, CM 01), at eight alignments of the base each.

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
        move.l  #0x11223344, %d1
        bsr     pass                             | write-through
        move.l  #0x0000E020, %d0                 | DTT0: base 0, mask 0, E, S either, CM 01
        movec   %d0, %dtt0
        move.l  #0x8899AABB, %d1
        bsr     pass                             | copyback
        cpusha  %dc
        illegal

| One pass: the patterns at BUF + 0 .. BUF + 7. D1 the value written, turned
| each time so that no two writes are alike.
pass:   lea     BUF, %a0
        moveq   #7, %d7
1:      move.l  %d1, %d6
        swap    %d6
        not.l   %d6

        | The same size, and smaller reads of a long word's bytes.
        move.l  %d1, (%a0)
        move.l  (%a0), %d2
        move.w  (%a0), %d3
        move.w  2(%a0), %d4
        move.b  (%a0), %d5
        move.b  3(%a0), %d2
        move.b  1(%a0), %d3

        | A word, a byte: read back, and read wider (a partial overlap).
        move.w  %d6, 2(%a0)
        move.w  2(%a0), %d4
        move.l  (%a0), %d5
        move.b  %d1, 1(%a0)
        move.b  1(%a0), %d2
        move.w  (%a0), %d3

        | Two writes to one long word: the younger covers the word read, not
        | the long word.
        move.l  %d6, 4(%a0)
        move.w  %d1, 6(%a0)
        move.w  6(%a0), %d4
        move.l  4(%a0), %d5
        move.w  4(%a0), %d2

        | Across a long word: not forwarded.
        move.l  %d1, 9(%a0)
        move.l  9(%a0), %d3
        move.b  10(%a0), %d4
        move.w  %d6, 15(%a0)
        move.w  15(%a0), %d5
        move.b  16(%a0), %d2

        | Read-modify-writes of memory, then read.
        move.l  %d1, 20(%a0)
        addq.l  #1, 20(%a0)
        addq.l  #3, 20(%a0)
        add.l   %d6, 20(%a0)
        move.l  20(%a0), %d3
        bset    #5, 23(%a0)
        bchg    #0, 22(%a0)
        not.w   20(%a0)
        lsl.w   20(%a0)
        move.l  20(%a0), %d4
        neg.b   21(%a0)
        move.w  20(%a0), %d5

        | The stack.
        move.l  %d1, -(%sp)
        move.l  (%sp)+, %d2
        move.w  %d6, -(%sp)
        move.w  (%sp)+, %d3
        pea     3(%a0)
        movea.l (%sp)+, %a1
        movem.l %d1-%d3, -(%sp)
        movem.l (%sp)+, %d4-%d6
        link    %a6, #-8
        move.l  %d1, -4(%a6)
        move.l  -4(%a6), %d5
        unlk    %a6

        rol.l   #7, %d1
        addi.l  #0x01030507, %d1
        addq.l  #1, %a0
        dbra    %d7, 1b
        rts
