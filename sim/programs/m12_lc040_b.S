| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M12, for sim/tb/core_lc040_tb.sv, on either build: where UAE040
| -L stacks what the manual does not, and what UAE040 as an MC68040 takes
| that the manual says it cannot (doc/oracles.md), so that only the bench can
| check it.
|
|   (a) the encodings PRM 5 has no instruction for -- An as an operand, Dn as
|       an extended one, an FMOVEM whose mode field does not match its <ea>,
|       an opmode PRM 5 does not have -- and a coprocessor ID other than 1:
|       F-line illegal instructions, vector 11, format $0, the PC the
|       instruction's (UM 8.4.1), on the MC68LC040 too: only "legal" FP
|       instructions take format $4 (UM A.5.1);
|   (b) on the MC68LC040, FDBcc: format $4, its address field 0, a register
|       direct mode's (UM A.5.1);
|   (c) on the MC68LC040, FMOVE.P FPn,-(An){Dn}: the address An - 12, the
|       operand's, An left alone;
|   (d) RTE of a format $4 frame: the MC68LC040 returns through it (UM A.5.2),
|       the MC68040 takes a format error, vector 14 (UM 8.4, A.5.2).
|
| The first FNOP tells the two apart: format $4 on the MC68LC040 (D4 = 1),
| nothing on the MC68040. Each exception's handler stores the frame's format
| and vector word, PC, and long words +$08 and +$0C in the next REC slot; a
| format $0 one goes on past the instruction, D5 bytes long.

        .equ    STACK_TOP, 0x0000F000
        .equ    REC,       0x0000E800            | 16 bytes an exception
        .equ    OUT,       0x0000FD00
        .equ    DONE,      0x0000FDFC
        .equ    DATA,      0x00004000

        .section .vectors, "a"
        .long   STACK_TOP                        | 0
        .long   _start                           | 1
        .rept   9                                | 2-10
        .long   h_bad
        .endr
        .long   h_f                              | 11
        .long   h_bad, h_bad                     | 12, 13
        .long   h_fmt                            | 14 format error
        .rept   241
        .long   h_bad
        .endr

        .text
        .globl  _start
_start:
        lea     REC, %a5
        lea     OUT, %a3
        moveq   #0, %d6
        moveq   #0, %d4
        lea     DATA, %a0
        lea     DATA + 0x100, %a1
        move.l  #i_ill0, 0(%a3)
        move.l  #i_fdb, 4(%a3)
        move.l  #i_fdb_n, 8(%a3)
        move.l  #i_pk, 12(%a3)
        move.l  #i_pk_n, 16(%a3)
        move.l  #i_rte, 20(%a3)
        move.l  #i_ill5, 24(%a3)

        moveq   #0, %d5
        fnop                                     | the MC68LC040: format $4, D4 = 1

        | (a) six F-line illegal instructions, each four bytes
        moveq   #4, %d5
i_ill0: .word   0xf208, 0x4000                   | FMOVE.L A0,FP0
        .word   0xf200, 0x4800                   | FMOVE.X D0,FP0
        .word   0xf210, 0xe0ff                   | FMOVEM.X FP0-FP7,(A0), mode -(An)
        .word   0xf220, 0xf0ff                   | FMOVEM.X FP0-FP7,-(A0), mode (An)+
        .word   0xf200, 0x007f                   | opmode $7F
i_ill5: .word   0xf000, 0x0000                   | coprocessor ID 0
        moveq   #0, %d5

        tst.l   %d4
        beq.s   2f
        | (b) FDBcc, (c) FMOVE.P with a dynamic k factor
        moveq   #5, %d1
i_fdb:  fdbne   %d1, 1f
i_fdb_n:
1:      moveq   #3, %d5
i_pk:   fmove.p %fp0, -(%a1){%d5}
i_pk_n:
        moveq   #0, %d5
        move.l  %a1, 28(%a3)                     | A1 after it

        | (d) RTE of a format $4 frame, built by hand
2:      lea     3f, %a6                          | where the format error's handler goes on
        move.l  #0x11112222, -(%sp)              | the PC of the faulted instruction
        move.l  #0x33334444, -(%sp)              | the address
        move.w  #0x402c, -(%sp)                  | format $4, vector 11
        pea     3f                               | the PC
        move.w  #0x2700, -(%sp)                  | the SR
i_rte:  rte
3:      move.l  %sp, 32(%a3)                     | SP after it: the frame gone either way

        move.l  #0xC0DE0000, DONE
4:      bra.s   4b

| Vector 11: the frame recorded; a format $0 one (pre-instruction) goes on
| past the instruction, D5 bytes long.
h_f:
        bsr.s   record
        move.w  6(%sp), %d0
        and.w   #0xf000, %d0
        cmp.w   #0x4000, %d0
        bne.s   1f
        moveq   #1, %d4                          | format $4: the MC68LC040
        rte
1:      tst.w   %d0
        bne.s   h_bad
        add.l   %d5, 2(%sp)
        rte
| Vector 14, the RTE's: its frame and the refused one dropped, and on.
h_fmt:
        bsr.s   record
        lea     8 + 16(%sp), %sp
        jmp     (%a6)
| The frame above the return address: format and vector word, PC, +$08, +$0C.
record:
        move.w  4 + 6(%sp), (%a5)
        move.l  4 + 2(%sp), 2(%a5)
        move.l  4 + 8(%sp), 6(%a5)
        move.l  4 + 12(%sp), 10(%a5)
        lea     16(%a5), %a5
        rts
h_bad:
        move.l  #0x0bad, %d6
        move.l  #0xC0DE0000, DONE
5:      bra.s   5b
