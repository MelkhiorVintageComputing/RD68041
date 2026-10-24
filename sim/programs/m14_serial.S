| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M14, for sim/tb/core_ser_tb.sv: UM 4.3.2's serialised page, its
| reads made once each. DTT0 makes $40xxxxxx (the slave's memory again) noncachable
| serialised, then for the second half noncachable and not serialised (which
| this core reads once too); the bench counts the reads that reach $40008000 and drives
| interrupts at level 2 all the while. Each of the LOOPS passes makes four
| reads of it -- after a forward BEQ, statically predicted not taken but
| taken, past a read of it the pipeline must not make -- so the count is
| 4 x LOOPS whatever the interrupts and the branches did (doc/bugs-found.md M14:
| the Quadra's SCSI pseudo-DMA read twice).

        .equ    STACK_TOP, 0x0000F000
        .equ    LOOPS, 200
        .equ    OUT, 0x0000FD00
        .equ    DONE, 0x0000FDFC

        .section .vectors, "a"
        .long   STACK_TOP
        .long   _start
        .rept   24
        .long   h_bad
        .endr
        .long   h_int                   | 26: level 2, autovectored
        .rept   229
        .long   h_bad
        .endr

        .text
        .globl  _start
_start:
        move.l  #0x4000C040, %d0        | $40/$00, E, either mode, CM 10
        movec   %d0, %dtt0
        lea     0x40008000, %a1
        moveq   #0, %d7                 | interrupts taken
        moveq   #0, %d6                 | bad exceptions
        move.w  #LOOPS - 1, %d5
        move.w  #0x2000, %sr
1:      moveq   #0, %d0
        tst.l   %d0
        beq.s   2f                      | taken; predicted not taken
        move.l  (%a1), %d1              | never executed
2:      move.l  (%a1), %d2              | four reads a pass, back to back,
        move.l  (%a1), %d2              | as the Quadra ROM's SCSI loop has
        move.l  (%a1), %d2              | them: each issued while the one
        move.l  (%a1), %d2              | before is still in EX or W
        addq.l  #4, %d3
        cmp.w   #LOOPS / 2, %d5         | half way: the page noncachable but
        bne.s   5f                      | not serialised (CM 11), as Mac OS
        move.l  #0x4000C060, %d0        | maps the Quadra's SCSI pseudo-DMA
        movec   %d0, %dtt0              | register (doc/divergences.md)
5:      dbra    %d5, 1b
        move.w  #0x2700, %sr
        move.l  %d7, OUT
        move.l  %d6, OUT + 4
        move.l  #0xC0DE0000, DONE
3:      bra.s   3b
h_int:  addq.l  #1, %d7
        rte
h_bad:  addq.l  #1, %d6
        move.l  #0xC0DE0000, DONE
4:      bra.s   4b
