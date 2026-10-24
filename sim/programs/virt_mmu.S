| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- rd-virt bare metal: the MC68040's MMU on, with both caches in
| copyback mode (RD68031's virt_mmu, for the 040's tables).
|
| Three-level tables, 4 KB pages (TC $8000; UM 3.2), as Linux builds them:
|   ROOT[0]    a pointer table whose first sixteen entries each point to a
|              page table of 64 pages: 0-4 MB identity, copyback (CM 01)
|   ROOT[32]   for $40000000: a page table with page 0 -> $300000, page 1
|              invalid, page 2 -> $302000 write-protected, page 3 invalid
| DTT0 maps the devices at $FFxxxxxx untranslated, noncachable serialised
| (CM 10), as Linux's head.S does with a TTR. CACR enables both caches.
|
| Then: a checksum over 64 KB written and read twice through the data cache;
| a write through the alias read back through the identity mapping (one
| physical line: the caches are physically tagged, UM 4.1); MOVES with a
| memory indirect operand, its pointer on a supervisor-only page; PTEST's verdicts
| on a valid, an invalid and a write-protected page (UM 3.1.4); a read and a
| write that fault on invalid pages and a write that faults on a
| write-protected one, each repaired by the access error handler and resumed
| by RTE (UM 8.4.6.7); CPUSHA at the end, and the copyback data checked
| uncached: DTT1 over the low gigabyte, CM 10, which the TTR's match makes
| win over the tables (UM 3.2.2).

#include "virt.inc"

        .equ    ROOT,   0x00010000      | 128 entries (UM 3.5.1)
        .equ    PTR0,   0x00010200      | ROOT[0]'s pointer table, 128 entries
        .equ    PTR1,   0x00010400      | ROOT[32]'s
        .equ    PT0,    0x00011000      | sixteen page tables of 64, $100 apart
        .equ    PTA,    0x00012000      | the alias's page table
        .equ    BUF,    0x00100000
        .equ    SPAGE,  0x00200000      | made supervisor only (S)
        .equ    ALIAS,  0x40000000
        .equ    APHYS,  0x00300000

        .equ    PG_CB,  0x21            | resident (PDT 01), copyback (CM 01)
        .equ    PG_W,   0x04            | write-protected
        .equ    TB_OK,  0x03            | a resident table descriptor (UDT 11)

        .text
        .globl  _start
_start:
        PUTS    m_start
        clr.l   %d7                     | access errors taken
        | the tables: everything invalid, then filled in
        lea     ROOT, %a0
        move.w  #(0x13000 - ROOT) / 4 - 1, %d0
1:      clr.l   (%a0)+
        dbra    %d0, 1b
        move.l  #PTR0 + TB_OK, ROOT
        move.l  #PTR1 + TB_OK, ROOT + 32*4
        lea     PTR0, %a0
        move.l  #PT0 + TB_OK, %d1
        moveq   #15, %d0
2:      move.l  %d1, (%a0)+
        add.l   #0x100, %d1
        dbra    %d0, 2b
        lea     PT0, %a0
        move.l  #PG_CB, %d1
        move.w  #16*64 - 1, %d0
3:      move.l  %d1, (%a0)+
        add.l   #0x1000, %d1
        dbra    %d0, 3b
        move.l  #PTA + TB_OK, PTR1
        move.l  #APHYS + PG_CB, PTA
        move.l  #APHYS + 0x2000 + PG_W + PG_CB, PTA + 8
        | data the faulting read will find once its page is mapped
        move.l  #0x0BADF00D, APHYS + 0x1000 + 0x20
        | the MMU and the caches on
        move.l  #ROOT, %d0
        movec   %d0, %urp
        movec   %d0, %srp
        move.l  #0xFF00C040, %d0        | $FF/$00, E, either mode, CM 10
        movec   %d0, %dtt0
        moveq   #0, %d0
        movec   %d0, %dtt1
        movec   %d0, %itt0
        movec   %d0, %itt1
        moveq   #5, %d0
        movec   %d0, %dfc               | PFLUSH's space: supervisor data
        pflusha
        move.l  #0x8000, %d0
        movec   %d0, %tc
        cinva   %bc
        move.l  #0x80008000, %d0
        movec   %d0, %cacr

        | a checksum over 64 KB, through the copyback cache, twice
        lea     BUF, %a0
        move.l  #0x12345678, %d1
        move.w  #16383, %d0
4:      move.l  %d1, (%a0)+
        rol.l   #5, %d1
        add.l   #0x9E3779B9, %d1
        dbra    %d0, 4b
        moveq   #1, %d3
5:      lea     BUF, %a0
        clr.l   %d2
        move.w  #16383, %d0
6:      add.l   (%a0)+, %d2
        dbra    %d0, 6b
        tst.l   %d3
        beq.s   7f
        move.l  %d2, %d4
7:      dbra    %d3, 5b
        cmp.l   %d2, %d4
        bne     fail

        | the alias: written at $40000010, read at $300010
        move.l  #0xA11A5ED0, ALIAS + 0x10
        cmp.l   #0xA11A5ED0, APHYS + 0x10
        bne     fail

        | PTEST (UM 3.1.4): resident, invalid, write-protected
        lea     ALIAS, %a0
        ptestr  (%a0)
        movec   %mmusr, %d0
        btst    #0, %d0                 | R
        beq     fail
        and.l   #0xFFFFF000, %d0
        cmp.l   #APHYS, %d0
        bne     fail
        lea     ALIAS + 0x1000, %a0
        ptestr  (%a0)
        movec   %mmusr, %d0
        btst    #0, %d0
        bne     fail
        lea     ALIAS + 0x2000, %a0
        ptestr  (%a0)
        movec   %mmusr, %d0
        btst    #2, %d0                 | W
        beq     fail
        pflusha

        | MOVES with memory indirection: the pointer is read from the
        | program's data space, the operand from SFC's -- user data here, and
        | the pointer's page supervisor only (S), so a pointer read in SFC's
        | space would be an access error (doc/bugs-found.md M13)
        or.l    #0x80, PT0 + (SPAGE >> 12) * 4
        pflusha
        move.l  #BUF + 0x40, SPAGE
        move.l  #0xFEEDFACE, BUF + 0x40
        moveq   #1, %d0
        movec   %d0, %sfc
        lea     SPAGE, %a2
        moves.l ([0,%a2]), %d1
        | ... and a word to An, Linux's form (MOVES.W ([$32,SP],0),A1 in the
        | FPU emulation): the pointer a long word, though the operand is
        | sign-extended -- a pointer whose bit 15 is set, sign-extended,
        | would be in the hole above the devices
        move.l  #BUF + 0x8040, SPAGE + 0x32
        move.w  #0x8123, BUF + 0x8040
        moves.w ([0x32,%a2],0), %a3
        moveq   #5, %d0
        movec   %d0, %sfc
        cmp.l   #0xFEEDFACE, %d1
        bne     fail
        cmp.l   #0xFFFF8123, %a3
        bne     fail

        | three access errors, each repaired and resumed
        lea     ALIAS + 0x1020, %a1
        move.l  (%a1), %d5              | a read of invalid page 1
        cmp.l   #0x0BADF00D, %d5
        bne     fail
        move.l  #0x55AA55AA, ALIAS + 0x3008   | a write to invalid page 3
        cmp.l   #0x55AA55AA, APHYS + 0x3008
        bne     fail
        move.w  #0x1234, ALIAS + 0x2004       | write-protected page 2
        cmp.w   #0x1234, APHYS + 0x2004
        bne     fail
        cmp.l   #3, %d7
        bne     fail

        | CPUSHA: the copyback data reaches memory; read it uncached
        cpusha  %dc
        move.l  #0x003FC040, %d0        | $00-$3F, E, either mode, CM 10
        movec   %d0, %dtt1
        move.l  BUF, %d0
        cmp.l   #0x12345678, %d0
        bne     fail
        cmp.l   #0x55AA55AA, APHYS + 0x3008
        bne     fail
        PUTS    m_pass
        POWEROFF 2
fail:   PUTS    m_fail
        move.l  %d7, %d1
        bsr     puthex
        move.l  #10, TTY
        POWEROFF 3

| The access error handler (UM 8.4.6): FA at +$14. Page 1 or 3 of the alias
| is made resident, page 2 writable; the ATC flushed, and the instruction
| run again by RTE. A pending write-back -- what the part leaves for a write
| that faulted after it was made (UM 8.4.6.3; this core restarts the
| instruction instead, doc/divergences.md) -- is completed first, WB3 the
| only one these writes could leave.
vec_2:  movem.l %d0-%d1/%a0, -(%sp)
        move.l  12 + 0x14(%sp), %d0     | FA
        and.l   #0xFFFFF000, %d0
        cmp.l   #ALIAS + 0x1000, %d0
        beq.s   1f
        cmp.l   #ALIAS + 0x3000, %d0
        beq.s   2f
        cmp.l   #ALIAS + 0x2000, %d0
        bne     fail
        and.l   #~PG_W, PTA + 8
        bra.s   3f
1:      move.l  #APHYS + 0x1000 + PG_CB, PTA + 4
        bra.s   3f
2:      move.l  #APHYS + 0x3000 + PG_CB, PTA + 12
3:      pflusha
        addq.l  #1, %d7
        move.w  12 + 0x0E(%sp), %d0     | WB3S
        btst    #7, %d0
        beq.s   6f
        move.l  12 + 0x18(%sp), %a0     | WB3A
        move.l  12 + 0x1C(%sp), %d1     | WB3D, register aligned
        and.w   #0x60, %d0
        beq.s   4f                      | SIZE 00: long
        cmp.w   #0x20, %d0
        beq.s   5f                      | 01: byte
        move.w  %d1, (%a0)              | 10: word
        bra.s   6f
4:      move.l  %d1, (%a0)
        bra.s   6f
5:      move.b  %d1, (%a0)
6:      movem.l (%sp)+, %d0-%d1/%a0
        rte

        COMMON
m_start: .asciz "virt_mmu: three-level tables, copyback caches, three access errors\n"
m_pass:  .asciz "PASS: virt_mmu\n"
m_fail:  .asciz "FAIL: virt_mmu, access errors "
        .even
        VECTORS
