| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M6's walking-skeleton program.
|
| Every instruction and addressing mode the M6 decoder builds
| (rtl/rd68041_decode.sv), in byte, word and long forms, including misaligned
| operands, a loop, subroutine calls and a computed jump. It ends on ILLEGAL,
| which stops the M6 core and on which the trace generator's run is cut.
| make cosim runs it on the core and on UAE040 and compares every register at
| every instruction boundary.

        .equ    STACK_TOP, 0x0000F000

        .section .vectors, "a"
        .long   STACK_TOP
        .long   _start

        .text
        .globl  _start
_start:
        | Reset leaves the condition codes undefined (UM 8.2.10); set them, so
        | both sides start from the same state.
        andi.b  #0x00, %ccr

        | --- MOVEQ, MOVE between registers, the immediates ---------------------
        moveq   #-1, %d0
        moveq   #5, %d1
        move.l  %d0, %d2
        move.w  %d1, %d2
        move.b  #0x7f, %d2
        move.l  #0x12345678, %d3
        move.w  #0x8000, %d4
        movea.w %d4, %a0                | sign-extended
        movea.l #data, %a1
        lea     buf, %a2

        | --- arithmetic and logic, register and immediate ----------------------
        add.l   %d1, %d3
        sub.w   #3, %d3
        add.b   #0x90, %d3              | carry and overflow at byte size
        addq.l  #8, %d1
        subq.w  #1, %d1
        and.l   #0x0f0f0f0f, %d3
        or.w    %d1, %d3
        eor.l   %d3, %d0
        cmp.l   %d0, %d3
        cmpi.w  #0x0f, %d1
        andi.b  #0xf0, %d0
        ori.l   #0x80000000, %d0
        eori.w  #0xffff, %d0
        adda.w  #-2, %a0
        suba.l  %a0, %a0
        addq.l  #4, %a2
        subq.l  #4, %a2
        cmpa.l  %a1, %a2
        ext.w   %d0
        ext.l   %d0
        extb.l  %d4
        swap    %d3
        tst.l   %d3
        tst.b   %d4

        | --- addressing modes ---------------------------------------------------
        move.l  (%a1), %d5              | (An)
        move.w  4(%a1), %d6             | (d16,An)
        move.l  (%a1)+, %d7             | (An)+
        move.b  (%a1)+, %d7
        move.b  (%a1)+, %d7
        move.w  -(%a1), %d7             | -(An), word
        moveq   #2, %d1
        move.l  8(%a1,%d1.w*2), %d5     | (d8,An,Xn)
        move.l  data+4, %d6             | (xxx).L
        move.w  (data+8).w, %d6         | (xxx).W
        move.l  data(%pc), %d7          | (d16,PC)
        move.w  4(%pc,%d1.l*2), %d5     | (d8,PC,Xn): the brief format, so near

        | --- stores, and memory to memory ----------------------------------------
        move.l  %d5, (%a2)
        move.w  %d6, 4(%a2)
        move.b  %d7, 6(%a2)
        move.l  #0xdeadbeef, 8(%a2)
        move.l  (%a2), 12(%a2)          | memory to memory
        move.w  4(%a2), (%a2)+
        move.l  -(%a2), 16(%a2)
        lea     buf, %a2                | (A2 is now two below buf: back to it)
        clr.w   20(%a2)
        clr.l   %d2
        addq.w  #1, 20(%a2)             | read-modify-write
        add.l   %d3, (%a2)
        or.b    %d0, 1(%a2)
        eor.w   %d1, 2(%a2)

        | --- misaligned operands -------------------------------------------------
        move.l  #0x11223344, 25(%a2)    | a long word at offset 1: byte, word, byte
        move.w  #0x5566, 31(%a2)        | a word at offset 3
        move.l  25(%a2), %d5
        move.w  31(%a2), %d6
        move.l  26(%a2), %d7            | offset 2: two words

        | --- a loop: sum 1..10 -------------------------------------------------
        moveq   #0, %d0
        moveq   #10, %d1
1:      add.l   %d1, %d0
        subq.l  #1, %d1
        bne     1b
        cmpi.l  #55, %d0
        beq     2f
        illegal                          | not reached
2:
        | --- every condition --------------------------------------------------
        moveq   #0, %d6
        moveq   #-1, %d1
        cmpi.l  #1, %d1                  | -1 vs 1: LT, MI, CC...
        blt     3f
        addq.l  #1, %d6
3:      bhi     4f
        addq.l  #2, %d6
4:      bmi     5f
        addq.l  #4, %d6
5:      bvs     6f
        addq.l  #8, %d6
6:      bge     7f
        addi.l  #16, %d6
7:      bls     8f
        addi.l  #32, %d6
8:
        | --- subroutines --------------------------------------------------------
        moveq   #3, %d0
        bsr     sub1
        jsr     sub2
        lea     sub1, %a3
        jsr     (%a3)
        pea     buf
        move.l  (%sp)+, %a4
        lea     tbl, %a5
        moveq   #4, %d1
        move.l  0(%a5,%d1.w), %a3
        jmp     (%a3)
        illegal                          | not reached

back:   move.l  %sp, %d7
        moveq   #42, %d0
        illegal                          | the end

sub1:   addq.l  #1, %d0
        rts
sub2:   move.l  %d0, -(%sp)
        add.l   (%sp)+, %d0
        rts

        .align  4
data:   .long   0x01020304, 0x05060708, 0x090a0b0c, 0x0d0e0f10
        .long   0x11121314, 0x15161718, 0x191a1b1c, 0x1d1e1f20
tbl:    .long   0, back

        .data
        .align  4
buf:    .space  64
