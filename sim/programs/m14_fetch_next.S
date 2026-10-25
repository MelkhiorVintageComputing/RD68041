| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- an instruction fetch's ATC fault, and the page after it, for
| sim/tb/core_fetchnext_tb.sv. Found running Linux (litex-68k): busybox's
| first call of fopen64 in glibc, whose code ran from the end of one page not
| yet resident into the next one, not resident either.
|
| Pages $16 and $17 are invalid. A JSR to $16FF8 faults (UM 8.4.6: ATC, the
| program space, FA $16FF8). The handler makes both pages resident, mapped to
| two consecutive pages of this program, as Linux's handler does when it maps
| the faulting page and, by fault-around, its neighbours; and, as Linux's
| does, it flushes the ATC entry of the faulting page only (PFLUSH, UM 3.7.2;
| Linux by PTEST), then returns. The code from $16FF8 runs into page $17 with
| an instruction across the two (a MOVE.L #imm at $16FFE): page $17 was never
| fetched before the handler made it resident, so its first fetch searches
| the tables and finds it so -- one fault, not two. Every fault's FA goes to
| OUT + $20 on, their count to OUT; the code's result (D5) to OUT + 4.

        .equ    ISP_TOP, 0x0000F000
        .equ    OUT,     0x0000FD00
        .equ    DONE,    0x0000FDFC
        .equ    ROOT,    0x0000A000
        .equ    PTR,     0x0000A200
        .equ    PT,      0x0000A400

        .section .vectors, "a"
        .long   ISP_TOP                          | 0
        .long   _start                           | 1
        .long   h_fault                          | 2  access fault
        .long   h_bad                            | 3
        .long   h_end                            | 4  ILLEGAL: the end
        .rept   251                              | 5-255
        .long   h_bad
        .endr

        .text
        .globl  _start
_start:
        | The tables, as m10_mmu.S's: pages 0-15 identity; $16 and $17
        | invalid, and what the handler will make them.
        move.l  #PTR + 2, ROOT
        move.l  #PT + 2, PTR
        lea     PT, %a0
        moveq   #0, %d0
1:      move.l  %d0, %d1
        ori.l   #1, %d1
        move.l  %d1, (%a0)+
        addi.l  #0x1000, %d0
        cmpi.l  #0x10000, %d0
        bne.s   1b
        clr.l   PT + 4*0x16
        clr.l   PT + 4*0x17
        lea     pg1, %a0
        move.l  %a0, %d0
        ori.l   #1, %d0
        move.l  %d0, OUT + 0x10                  | page $16's descriptor to be
        addi.l  #0x1000, %d0
        move.l  %d0, OUT + 0x14                  | page $17's
        clr.l   OUT                              | the faults
        moveq   #0, %d5

        move.l  #ROOT, %d0
        movec   %d0, %urp
        movec   %d0, %srp
        pflusha
        move.l  #0x8000, %d0                     | E, 4 KB pages
        movec   %d0, %tc

        jsr     0x16FF8
        move.l  %d5, OUT + 4
        move.l  #0xC0DE0000, DONE
        illegal

| An access fault: count it, keep its FA, make pages $16 and $17 resident,
| flush the ATC entry of the faulting page (the supervisor program space:
| DFC 6), and return. A third is the end.
h_fault:
        addq.l  #1, OUT
        move.l  OUT, %d0
        lsl.l   #2, %d0
        lea     OUT + 0x1C, %a0
        move.l  20(%sp), (%a0, %d0.l)
        cmpi.l  #3, OUT
        bge.s   h_end
        move.l  OUT + 0x10, PT + 4*0x16
        move.l  OUT + 0x14, PT + 4*0x17
        moveq   #6, %d0
        movec   %d0, %dfc
        movea.l 20(%sp), %a0
        pflush  (%a0)
        rte
h_bad:
        move.l  #0x0bad, OUT + 8
h_end:  bra.s   h_end

| Two pages: page $16 is mapped to pg1, page $17 to the one after it.
        .balign 4096
pg1:
        .fill   0xFF8, 1, 0
        moveq   #1, %d5                          | $16FF8
        addq.l  #1, %d5                          | $16FFA
        nop                                      | $16FFC
        move.l  #0x2A2A2A2A, %d5                 | $16FFE: across into page $17
        addq.l  #1, %d5                          | $17004
        rts
