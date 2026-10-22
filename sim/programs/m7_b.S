| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M7's second batch, run on the core and on UAE040 by make cosim:
| the full extension-word format (base and index suppressed, memory
| indirection pre- and post-indexed, the PC as base, MOVE with it on both
| sides), ABCD, SBCD, NBCD, PACK, UNPK in both forms, CAS and CAS2 both ways,
| TAS, CMP2 and CHK2 (not trapping), and MOVES. Nothing takes an exception.

        .equ    STACK_TOP, 0x0000F000

        .section .vectors, "a"
        .long   STACK_TOP
        .long   _start

        .text
        .globl  _start
_start:
        andi.b  #0x00, %ccr
        lea     buf, %a2
        lea     data, %a1
        lea     ptrs, %a3

        | --- the full format --------------------------------------------------
        moveq   #2, %d1
        move.l  (0x10,%a1,%d1.l*4), %d0         | bd.W, scaled index
        move.l  (0x12345678-0x12345678+4,%a1), %d2  | base displacement
        move.l  ([%a3]), %d3                   | memory indirect, no od
        move.l  ([%a3],4), %d4                 | ... with od
        moveq   #1, %d1
        move.l  ([%a3,%d1.l*4],8), %d5         | pre-indexed
        move.l  ([%a3],%d1.l*4,8), %d6         | post-indexed
        move.l  ([4,%a3],%d1.w*2,0x10), %d7    | post-indexed, word index, od.W
        move.l  (data).l, %a4                  | bd only: base suppressed
        move.l  ([ptrs+4]), %d0                | ([bd]): base and index suppressed
        move.l  ([ptrs,%pc]), %d2              | PC base, memory indirect
        move.l  (data+8,%pc,%d1.w*4), %d3      | PC base, no indirection
        lea     ([%a3],8), %a5                 | LEA through a pointer
        pea     ([4,%a3])
        move.l  (%sp)+, %d4
        move.l  ([%a3]), ([4,%a3],12)          | MOVE: indirect on both sides
        move.l  #0x0badf00d, ([%a3],%d1.l*4,0)
        add.l   ([%a3]), %d4                   | an ALU operand through a pointer
        addq.l  #1, ([4,%a3])                  | read-modify-write through one
        move.l  ([4,%a3]), %d5
        jsr     ([jtab])                        | a call through one
        bra     after_call
call_tgt:
        moveq   #77, %d6
        rts
after_call:

        | --- BCD, PACK, UNPK -------------------------------------------------
        move.b  #0x45, %d0
        move.b  #0x38, %d1
        andi.b  #0x00, %ccr
        abcd    %d1, %d0                        | 83
        move.b  #0x99, %d2
        abcd    %d2, %d0                        | carry
        move.b  #0x12, %d3
        sbcd    %d1, %d3                        | borrow
        nbcd    %d3
        move.b  #0x19, (%a2)
        move.b  #0x27, 1(%a2)
        lea     1(%a2), %a4
        lea     2(%a2), %a5
        abcd    -(%a4), -(%a5)
        move.w  #0x0304, %d0
        pack    %d0, %d1, #0
        pack    %d0, %d2, #0x0101
        unpk    %d1, %d3, #0x3030
        move.w  #0x0506, 8(%a2)
        lea     10(%a2), %a4
        lea     12(%a2), %a5
        pack    -(%a4), -(%a5), #0
        move.b  #0x79, 16(%a2)
        lea     17(%a2), %a4
        lea     20(%a2), %a5
        unpk    -(%a4), -(%a5), #0x3030

        | --- CAS, CAS2, TAS ---------------------------------------------------
        move.l  #100, 24(%a2)
        moveq   #100, %d0
        move.l  #200, %d1
        cas.l   %d0, %d1, 24(%a2)              | equal: 200 written
        cas.l   %d0, %d1, 24(%a2)              | not: D0 loaded with 200
        move.w  #0x1234, 28(%a2)
        move.w  #0x1234, %d2
        move.w  #0x5678, %d3
        cas.w   %d2, %d3, 28(%a2)
        lea     24(%a2), %a4
        lea     28(%a2), %a5
        move.l  (%a4), %d4
        move.w  (%a5), %d5
        move.l  #0x11111111, %d6
        move.l  #0x2222, %d7
        cas2.l  %d4:%d5, %d6:%d7, (%a4):(%a5)  | first equal, second not (word vs long)
        move.l  (%a4), %d4
        move.l  (%a5), %d5
        cas2.l  %d4:%d5, %d6:%d7, (%a4):(%a5)  | both equal
        clr.b   32(%a2)
        tas     32(%a2)
        tas     32(%a2)
        moveq   #0, %d0
        tas     %d0

        | --- CMP2, CHK2 -------------------------------------------------------
        move.l  #10, 36(%a2)
        move.l  #20, 40(%a2)
        moveq   #15, %d0
        cmp2.l  36(%a2), %d0                   | inside
        moveq   #20, %d0
        cmp2.l  36(%a2), %d0                   | on the upper bound
        moveq   #25, %d0
        cmp2.l  36(%a2), %d0                   | outside
        move.w  #-5, 44(%a2)
        move.w  #5, 46(%a2)
        move.l  #-3, %a0
        cmp2.w  44(%a2), %a0                   | An, word bounds sign-extended
        move.b  #0xf0, 48(%a2)
        move.b  #0x10, 49(%a2)
        move.b  #0x05, %d1
        cmp2.b  48(%a2), %d1                   | signed bounds, Dn byte
        moveq   #12, %d0
        chk2.l  36(%a2), %d0                   | not taken

        | --- MOVES --------------------------------------------------------------
        moveq   #5, %d0
        movec   %d0, %sfc
        movec   %d0, %dfc
        move.l  #0xcafe0001, %d1
        moves.l %d1, 52(%a2)
        moves.l 52(%a2), %d2
        moves.w 52(%a2), %a6
        moves.b 53(%a2), %d3

        move.l  %sp, %d7
        illegal

        .align  4
data:   .long   0x01020304, 0x05060708, 0x090a0b0c, 0x0d0e0f10
        .long   0x11121314, 0x15161718, 0x191a1b1c, 0x1d1e1f20
        .long   0x21222324, 0x25262728, 0x292a2b2c, 0x2d2e2f30
jtab:   .long   call_tgt

        .data
        .align  4
ptrs:   .long   tgt0, tgt1, tgt2, tgt3
tgt0:   .long   0x10000001, 0x10000002, 0x10000003, 0x10000004, 0x10000005
tgt1:   .long   0x20000001, 0x20000002, 0x20000003, 0x20000004, 0x20000005
tgt2:   .long   0x30000001, 0x30000002, 0x30000003, 0x30000004, 0x30000005
tgt3:   .long   0x40000001, 0x40000002, 0x40000003, 0x40000004, 0x40000005
        .long   0x50000001, 0x50000002, 0x50000003, 0x50000004, 0x50000005
buf:    .space  64
