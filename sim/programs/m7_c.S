| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M7's bit fields, on the core and on UAE040 (make cosim): the eight
| BFxxx in register and memory forms, offset and width from the extension word
| and from data registers, a negative offset, width 0 (32), a field wrapping
| round a register, and one across five bytes.

        .equ    STACK_TOP, 0x0000F000

        .section .vectors, "a"
        .long   STACK_TOP
        .long   _start

        .text
        .globl  _start
_start:
        andi.b  #0x00, %ccr
        lea     buf, %a2
        move.l  #0x12345678, %d0
        bftst   %d0{4:8}
        bfextu  %d0{4:8}, %d1
        bfexts  %d0{0:4}, %d2
        bfextu  %d0{28:8}, %d3                   | wraps round the register
        moveq   #12, %d4
        moveq   #0, %d5                          | width 0: 32
        bfextu  %d0{%d4:%d5}, %d6
        bfffo   %d0{8:16}, %d7
        bfchg   %d0{0:4}
        bfclr   %d0{4:4}
        bfset   %d0{24:8}
        move.l  #0xa5, %d1
        bfins   %d1, %d0{12:8}

        move.l  #0x0f0f0f0f, (%a2)
        move.l  #0xf0f0f0f0, 4(%a2)
        move.l  #0x55aa55aa, 8(%a2)
        bftst   (%a2){3:10}
        bfextu  (%a2){3:10}, %d1
        bfexts  4(%a2){6:30}, %d2                | five bytes
        moveq   #-5, %d4
        bfextu  8(%a2){%d4:12}, %d3               | negative offset
        moveq   #37, %d4
        bfffo   (%a2){%d4:8}, %d5
        bfchg   (%a2){2:6}
        bfclr   4(%a2){7:31}
        bfset   8(%a2){0:1}
        move.l  #0x123, %d6
        bfins   %d6, 1(%a2){5:12}
        move.l  (%a2), %d0
        move.l  4(%a2), %d1
        move.l  8(%a2), %d2

        move.l  %sp, %d7
        illegal

        .data
        .align  4
buf:    .space  32
