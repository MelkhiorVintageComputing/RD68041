| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M13: an instruction whose source is (An)+ or -(An) and whose
| destination is the same An, with and without a write to An just before it,
| as Linux's RESTORE_ALL has it (ADDQ #4,SP; ADDA.L (SP)+,SP): the
| destination's An is the one the source's update left (doc/bugs-found.md
| M13). Run by make cosim.

        .equ    STACK_TOP, 0x0000F000

        .section .vectors, "a"
        .long   STACK_TOP
        .long   _start

        .text
        .globl  _start
_start:
        lea     tab, %a0
        adda.l  (%a0)+, %a0             | no write just before
        lea     tab, %a0
        addq.l  #4, %a0
        adda.l  (%a0)+, %a0             | An written by the instruction before
        lea     tab, %a0
        addq.l  #4, %a0
        nop
        adda.l  (%a0)+, %a0             | ... two before
        lea     tab+8, %a1
        subq.l  #2, %a1
        adda.w  -(%a1), %a1
        lea     tab, %a2
        addq.l  #8, %a2
        cmpa.l  (%a2)+, %a2
        lea     tab, %a3
        addq.l  #4, %a3
        suba.l  (%a3)+, %a3
        lea     tab, %a4
        addq.l  #4, %a4
        movea.l (%a4)+, %a4             | the load wins over the update
        | the stack, as Linux has it
        move.l  #0, -(%sp)
        move.l  #0x12345678, -(%sp)
        addq.l  #4, %sp
        adda.l  (%sp)+, %sp
        move.l  %sp, %d0
        lea     tab, %a5
        addq.l  #4, %a5
        add.l   (%a5)+, %d1
        move.l  %a5, %d1
        illegal

        .data
        .even
tab:    .long   0x10, 0x20, 0x00300004, 0x40
