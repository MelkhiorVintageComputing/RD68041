| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M13: memory indirection on instructions whose own access is not a
| plain one -- MOVES (its operand in SFC's or DFC's space), TAS and CAS
| (locked), a bit field -- the pointer read from the program's data space
| as an ordinary long word (doc/bugs-found.md M13: Linux's FPU emulation on the
| MC68LC040 reads a user instruction's word with MOVES.W ([$32,SP],0),A1, and
| the pointer came out sign-extended from a word as the operand going to An
| is: virt_mmu has that case, where an address can miss the RAM).
| Run by make cosim. SFC and DFC are user data (1), which the flat memory
| answers as it does supervisor data; the pointers are where only an
| ordinary read finds them -- no MMU here, so it is the attributes the
| oracle and the core must agree on, and the values.

        .equ    STACK_TOP, 0x0000F000

        .section .vectors, "a"
        .long   STACK_TOP
        .long   _start

        .text
        .globl  _start
_start:
        moveq   #1, %d0
        movec   %d0, %sfc
        movec   %d0, %dfc
        lea     ptrs, %a2
        moves.w ([0,%a2],0), %a1        | the word at w1, sign-extended
        moves.l ([4,%a2],2), %d1        | the long at w2+2
        move.l  #0x13572468, %d2
        moves.l %d2, ([8,%a2],0)        | into out
        move.l  out, %d3
        tas     ([12,%a2],1)            | the byte at tb+1
        move.l  tb, %d4
        moveq   #0, %d5
        move.l  #0x0BADCAFE, %d6
        cas.l   %d5, %d6, ([16,%a2])    | cv is 0: swapped
        move.l  cv, %d7
        bfextu  ([20,%a2]){4:12}, %d0
        bfins   %d2, ([20,%a2],2){8:8}
        move.l  bf, %d1
        illegal

        .data
        .even
ptrs:   .long   w1, w2, out, tb, cv, bf
w1:     .word   0x8001
w2:     .word   0x1111, 0x2222, 0x3333, 0x4444
out:    .long   0
tb:     .long   0x00400000
cv:     .long   0
bf:     .long   0xA5C3F00F
