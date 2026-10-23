| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M10's MMU, for sim/tb/core_mmu_tb.sv: translation tables built
| here (UM 3.2), translation turned on, and then:
|
|   - reads and a write through page $10 (logical $10000), mapped to the
|     physical page $C000; a read through page $14, whose descriptor is
|     indirect (UM 3.2.4.1) to one for $C000 too;
|   - access faults (UM 8.4.6), each frame copied to RES as m8_fault.S does:
|     (a) a write to a write-protected page, (b) a read of an invalid one,
|     (c) a long word read across from a valid page into that invalid one
|     (MA), (d) a user read of a supervisor page, (e) an instruction fetched
|     from an invalid page;
|   - code run from page $15, mapped to the page this program's xroutine is
|     in (the instruction ATC);
|   - PTEST (UM 3.7.3), its MMUSR stored to OUT: of the page written, of the
|     invalid page, PTESTW of the write-protected page, of an address DTT0
|     matches, and of page $15 in the supervisor program space;
|   - PFLUSH (UM 3.7.2): page $10's descriptor changed to $D000, a read
|     through it before (the ATC's old entry) and after PFLUSH (An).
|
| The bench checks the descriptors' U and M bits (UM 3.2.5, Table 3-1) in
| memory afterwards. It may set CFG: a CACR, and CM bits for pages 0-15 (the
| tables, the program and its stacks), so that the table searches read
| through the data cache (make cache). Run under make cosim too (PROGS=m10_mmu): the handler
| loads each frame's SSW and FA into D7 and D4, so the trace compares them --
| but for two things this design and UAE040 do differently (doc/oracles.md,
| doc/divergences.md): the SIZE of an instruction fetch's fault, and the
| write-back slots, which here are always empty (a write's fault is taken
| before it is made), so the handler copies neither.

        .equ    ISP_TOP, 0x0000F000
        .equ    USP_TOP, 0x0000B000
        .equ    RES,     0x0000FE00
        .equ    OUT,     0x0000FD00
        .equ    RESUME,  0x0000FDF0
        .equ    DONE,    0x0000FDFC
        .equ    CFG,     0x0000FDE8              | the bench's: CACR, the pages' CM
        .equ    ROOT,    0x0000A000
        .equ    PTR,     0x0000A200
        .equ    PT,      0x0000A400
        .equ    IND,     0x0000A5F0

        .section .vectors, "a"
        .long   ISP_TOP                          | 0
        .long   _start                           | 1
        .long   h_fault                          | 2  access fault
        .long   h_bad                            | 3
        .long   h_end                            | 4  ILLEGAL: the end
        .rept   27                               | 5-31
        .long   h_bad
        .endr
        .long   h_bad                            | 32
        .long   h_super                          | 33 TRAP #1: back to supervisor
        .rept   222
        .long   h_bad
        .endr

        .text
        .globl  _start
_start:
        lea     RES, %a5
        lea     USP_TOP, %a0
        move.l  %a0, %usp

        | The tables: the root's entry 0 to the pointer table, its entry 0 to
        | the page table; pages 0-15 identity, U clear.
        move.l  #PTR + 2, ROOT
        move.l  #PT + 2, PTR
        lea     PT, %a0
        moveq   #0, %d0
        move.l  CFG + 4, %d2
1:      move.l  %d0, %d1
        ori.l   #1, %d1
        or.l    %d2, %d1
        move.l  %d1, (%a0)+
        addi.l  #0x1000, %d0
        cmpi.l  #0x10000, %d0
        bne.s   1b
        move.l  #0x0000C001, PT + 4*0x10         | $10: $C000
        move.l  #0x0000D005, PT + 4*0x11         | $11: $D000, write protected
        move.l  #0x0000E081, PT + 4*0x13         | $13: $E000, supervisor only
        move.l  #IND + 2, PT + 4*0x14            | $14: indirect
        move.l  #0x0000C001, IND                 | ... to $C000
        lea     xroutine, %a0                    | $15: xroutine's page
        move.l  %a0, %d0
        andi.l  #0xFFFFF000, %d0
        ori.l   #1, %d0
        move.l  %d0, PT + 4*0x15
        move.l  %d0, OUT + 0x30                  | (PTEST's expected PA and R)

        move.l  #0x11223344, 0xC004
        move.l  #0x99AABBCC, 0xD004

        move.l  #ROOT, %d0
        movec   %d0, %urp
        movec   %d0, %srp
        pflusha
        move.l  #0x8000, %d0                     | E, 4 KB pages
        movec   %d0, %tc
        move.l  CFG, %d0
        movec   %d0, %cacr

        | Reads and a write, translated.
        move.l  0x10004, OUT + 0x00
        move.l  #0x55667788, 0x10008
        move.l  0x14004, OUT + 0x04

        | (a) a write to a write-protected page. (UAE040 completes the MOVE and
        | stacks its write; the core faults before it: D0 positive, so that the
        | condition codes are the same either way.)
        move.l  #0x12345678, %d0
        move.l  #fa_ret, RESUME
fa1:    move.l  %d0, 0x11000
fa_ret:
        | (b) a read of an invalid page
        move.l  #fb_ret, RESUME
fb1:    move.l  0x12000, %d0
fb_ret:
        | (c) across into it: the fault on the second page
        move.l  #fc_ret, RESUME
fc1:    move.l  0x11FFE, %d0
fc_ret:
        | (d) a user read of a supervisor page
        move.l  #fd_ret, RESUME
        andi.w  #0xdfff, %sr
fd1:    move.w  0x13000, %d1
fd_ret: trap    #1
        | (e) an instruction fetched from an invalid page
        move.l  #fe_ret, RESUME
        jmp     0x16000
fe_ret:
        | Code from page $15.
        lea     0x15000, %a1
        lea     xroutine, %a0
        move.l  %a0, %d1
        andi.l  #0xFFF, %d1
        adda.l  %d1, %a1
        moveq   #0, %d5
        jsr     (%a1)
        move.l  %d5, OUT + 0x08

        | PTEST.
        moveq   #5, %d0
        movec   %d0, %dfc
        lea     0x10000, %a0
        ptestr  (%a0)
        movec   %mmusr, %d0
        move.l  %d0, OUT + 0x10
        lea     0x12000, %a0
        ptestr  (%a0)
        movec   %mmusr, %d0
        move.l  %d0, OUT + 0x14
        lea     0x11000, %a0
        ptestw  (%a0)
        movec   %mmusr, %d0
        move.l  %d0, OUT + 0x18
        move.l  #0xFF00C000, %d0                 | DTT0: $FFxxxxxx, either mode
        movec   %d0, %dtt0
        lea     0xFF000000, %a0
        ptestr  (%a0)
        movec   %mmusr, %d0
        move.l  %d0, OUT + 0x1C
        moveq   #0, %d0
        movec   %d0, %dtt0
        moveq   #6, %d0                          | supervisor program
        movec   %d0, %dfc
        lea     0x15000, %a0
        ptestr  (%a0)
        movec   %mmusr, %d0
        move.l  %d0, OUT + 0x20

        | PFLUSH: the descriptor changed, the old entry used until flushed.
        move.l  PT + 4*0x10, OUT + 0x24          | (as the searches left it)
        move.l  #0x0000D009, PT + 4*0x10
        move.l  0x10004, OUT + 0x28
        moveq   #5, %d0
        movec   %d0, %dfc
        lea     0x10000, %a0
        pflush  (%a0)
        move.l  0x10004, OUT + 0x2C

        cpusha  %dc                              | (for the bench, with copyback:
        move.l  #0xC0DE0000, DONE                | everything in memory, then DONE)
        cpusha  %dc
        illegal                                  | (where make cosim stops)

h_fault:
        move.w  #0xFF9F, %d7                     | (the SSW less SIZE, and FA, for
        and.w   12(%sp), %d7                     | the trace: doc/oracles.md)
        move.l  20(%sp), %d4
        move.w  (%sp), (%a5)+
        move.l  2(%sp), (%a5)+
        move.w  6(%sp), (%a5)+
        move.w  12(%sp), (%a5)+
        move.l  20(%sp), (%a5)+
        addq.l  #6, %a5                          | (not the write-backs: below)
        move.l  RESUME, 2(%sp)
        rte
h_super:
        ori.w   #0x2000, (%sp)
        rte
h_bad:
        move.l  #0x0bad, %d6
h_end:  bra.s   h_end

        .balign 4096
xroutine:
        moveq   #42, %d5
        rts
