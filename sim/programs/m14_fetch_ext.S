| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- an instruction whose extension words are on a page not resident,
| its operation word on one that is, for sim/tb/core_fetchext_tb.sv. Found
| running NetBSD (litex-68k, and rd-qvirt): gzcat's zlib, a MOVE.L #imm,
| (d16,An) at the last word of a page, the page after it not yet mapped.
|
| Pages $16 and $18 are resident, both mapped to pg1; $17 and $19 are
| invalid. The code at the end of pg1 is a MOVE.L #imm,(d16,A3) whose
| operation word is at $xxFFE and whose three extension words are on the next
| page: its fetch faults there (UM 8.4.6: ATC, the program space, FA $17000),
| with one of the three in the queue. The handler makes the faulting page
| resident, mapped to the page after pg1, flushes its ATC entry and returns;
| the instruction runs. Once through $16 with the caches off, once through
| $18 with the instruction cache on (its fetch a line). Every fault's FA goes
| to OUT + $20 on, their count to OUT; the two stores to OUT + $30 and $34,
| the code's result (D5) to OUT + 4.

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
        | The tables, as m10_mmu.S's: pages 0-15 identity; $16 and $18 pg1,
        | $17 and $19 invalid, and what the handler will make them.
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
        lea     pg1, %a0
        move.l  %a0, %d0
        ori.l   #1, %d0
        move.l  %d0, PT + 4*0x16
        move.l  %d0, PT + 4*0x18
        clr.l   PT + 4*0x17
        clr.l   PT + 4*0x19
        addi.l  #0x1000, %d0
        move.l  %d0, OUT + 0x10                  | what $17 and $19 are to be
        clr.l   OUT                              | the faults
        clr.l   OUT + 0x30
        clr.l   OUT + 0x34
        moveq   #0, %d5

        move.l  #ROOT, %d0
        movec   %d0, %urp
        movec   %d0, %srp
        pflusha
        move.l  #0x8000, %d0                     | E, 4 KB pages
        movec   %d0, %tc

        lea     OUT, %a3                         | caches off
        jsr     0x16FFC
        cinva   %ic
        move.l  #0x00008000, %d0                 | IE
        movec   %d0, %cacr
        lea     OUT + 4, %a3                     | the instruction cache on
        jsr     0x18FFC
        moveq   #0, %d0
        movec   %d0, %cacr
        move.l  %d5, OUT + 4
        move.l  #0xC0DE0000, DONE
        illegal

| An access fault: count it, keep its FA, make the faulting page resident,
| flush its ATC entry (the supervisor program space: DFC 6), and return. A
| third is the end.
h_fault:
        addq.l  #1, OUT
        move.l  OUT, %d0
        lsl.l   #2, %d0
        lea     OUT + 0x1C, %a0
        move.l  20(%sp), (%a0, %d0.l)
        cmpi.l  #3, OUT
        bge.s   h_end
        move.l  20(%sp), %d0
        moveq   #12, %d1
        lsr.l   %d1, %d0
        lsl.l   #2, %d0
        lea     PT, %a0
        move.l  OUT + 0x10, (%a0, %d0.l)
        moveq   #6, %d0
        movec   %d0, %dfc
        movea.l 20(%sp), %a0
        pflush  (%a0)
        rte
h_bad:
        move.l  #0x0bad, OUT + 8
h_end:  bra.s   h_end

| Two pages: pg1, which $16 and $18 map, and the one after it, which the
| handler maps $17 and $19 to.
        .balign 4096
pg1:
        .fill   0xFFC, 1, 0
        addq.l  #1, %d5                          | $xxFFC
        move.l  #0x2A2A2A2A, 0x30(%a3)           | $xxFFE: its extension words on the next page
        addq.l  #1, %d5                          | $x+1006
        rts
