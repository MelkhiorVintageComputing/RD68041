| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M14: the Quadra ROM's SCSI pseudo-DMA set-up (its $408D22C6), a
| byte count turned into an entry point into an unrolled block of 32
| MOVE.L (A1),(A2)+ by JMP (d8,PC,D3.W*2) and the long words a DBF repeats it
| for, the last odd word flagged in D3's bit 31 by ROR.L. A suspect of the
| SCSI stall of doc/bugs-found.md M14, cleared; kept as a test of the
| computed jump into cached code. Run by make cosim, for 510, 512, 2, 4 and
| 130 bytes.

        .equ    STACK_TOP, 0x0000F000

        .section .vectors, "a"
        .long   STACK_TOP
        .long   _start

        .text
        .globl  _start
_start:
        move.l  #0x8000, %d0            | the instruction cache on, as the ROM has it
        movec   %d0, %cacr
        lea     counts, %a5
        moveq   #4, %d7
1:      move.l  (%a5)+, %d2
        lea     src, %a1
        lea     dst, %a2
        bsr.s   dma
        move.l  %a2, %d0
        sub.l   #dst, %d0               | bytes moved as long words
        dbra    %d7, 1b
        illegal

dma:    move.l  %d2, %d4
        lsr.l   #7, %d4
        andi.l  #127, %d2
        ror.l   #1, %d2
        move.l  %d2, %d3
        ror.l   #1, %d3
        neg.w   %d3
        nop
        jmp     2f(%pc,%d3.w*2)
        .rept   32
        move.l  (%a1), (%a2)+
        .endr
2:      dbf     %d4, 2b - 64
        nop
        btst    #31, %d3
        beq.s   3f
        move.w  (%a1), (%a2)+
3:      rts

        .data
        .even
counts: .long   510, 512, 2, 4, 130
src:    .long   0x12345678
dst:    .space  1024
