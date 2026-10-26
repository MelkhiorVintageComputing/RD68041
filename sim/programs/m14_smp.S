| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- two processors on one bus, for sim/tb/core_smp_tb.sv (doc/smp.md).
| Both run this image; each learns its number from the board's WHOAMI
| register. CPU 1 is held in reset until CPU 0 has built the page tables and
| lets it go (the board's RELEASE register).
|
| The MMU maps the 64 KB of memory one to one in 4 KB pages, each with the
| cache mode and the U1-U0 bits the board's snooping needs: the board wires
| UPA1-UPA0 to SC1-SC0, so a page's U bits are the snoop operation the other
| processor performs on this one's transfers (UM 5.3.4, Table 4-1).
|
|   page  0-2   vectors, code                write-through, U 00
|   page  3     the barrier's code           cache-inhibited: its fetches are
|                                            uncached, and a branch withdraws
|                                            a prefetch's bus request
|   page  4     code rewritten by CPU 0      write-through, U 01 (snoop)
|   page  5     the page tables              write-through, U 01 (table
|                                            searches are never snooped, UPA
|                                            00: the tables must be written
|                                            through, doc/smp.md)
|   page  6     shared, copyback             copyback, U 10 (mark invalid: one
|                                            cache at a time holds a line, UM
|                                            4.5)
|   page  7     shared, write-through        write-through, U 01
|   page  8     flags, results, locks        cache-inhibited, serialised
|   page  9     mapped to page 10, then 11   write-through (the TLB shootdown)
|   page 12-13  CPU 0's and CPU 1's stacks   copyback, U 00 (private)
|
| The bench pokes ITERS, WTSHARED (non-zero: page 6 is write-through with U 01
| like every other shared page -- the board without the SC gate, doc/smp.md),
| and UMASK, ANDed into every page descriptor, to
| show that the U bits matter) before reset. Phases, each ended by a barrier:
|
|   1  boot: CPU 0 builds the tables, turns on its MMU and caches, idles,
|      then lets CPU 1 go; CPU 1 does the same
|   2  interprocessor interrupts: each sends ITERS to the other (level 5,
|      autovectored: vector 29)
|   3  locks: a CAS spinlock and a TAS spinlock around a shared counter, in
|      a cache-inhibited and in a write-through page, then around counters in
|      a copyback page (the locks themselves write-through and
|      cache-inhibited: a lock word must not be copyback, doc/smp.md);
|      lock-free CAS increments, cache-inhibited and copyback (a line of its
|      own, never written through the cache); every counter must reach
|      2 x ITERS
|   4  coherence: two counters in one copyback line (false sharing); a
|      producer and a consumer in write-through memory; a CAS word in a
|      copyback line beside each one's ordinary counter; a misaligned long
|      word across two lines, read racing its writer (torn reads counted)
|      and under a lock (never torn); MOVE16 of a line the other processor
|      holds dirty
|   5  the instruction cache: CPU 1 runs a routine, CPU 0 rewrites it, CPU 1
|      runs the new one -- its line invalidated by snooping CPU 0's write
|   6  TLB shootdown: CPU 0 remaps a page and interrupts CPU 1, whose handler
|      flushes its ATC (PFLUSHA)
|   7  CPUSHA, and DONE
|
| The barriers' numbers only grow (a barrier waits until the other processor
| has reached a number at least as large). Every check that fails counts in ERR and leaves its code (phase x $100 +
| check) in FIRST, for the bench.

        .equ    DEV,       0xFFFF0000            | the board's devices
        .equ    WHOAMI,    DEV + 0x0
        .equ    IPI_SET,   DEV + 0x4
        .equ    IPI_ACK,   DEV + 0x8
        .equ    RELEASE,   DEV + 0xC

        .equ    TABLES,    0x5000                | root, pointer and page tables
        .equ    PTR,       0x5200
        .equ    PAGES,     0x5400
        .equ    ROUTINE,   0x4000

        .equ    CB,        0x6000                | copyback, U 10
        .equ    CBCNT,     CB + 0x04
        .equ    CBTCNT,    CB + 0x14
        .equ    CBFREE,    CB + 0x20
        .equ    FS,        CB + 0x100            | FS + 4 x cpu: false sharing
        .equ    M16SRC,    CB + 0x200
        .equ    M16DST,    CB + 0x280
        .equ    MIX,       CB + 0x300            | a CAS word, then each one's own

        .equ    WT,        0x7000                | write-through, U 01
        .equ    WTLOCK,    WT + 0x00
        .equ    WTCNT,     WT + 0x04
        .equ    WTTAS,     WT + 0x10
        .equ    WTTCNT,    WT + 0x14
        .equ    WTLOCK2,   WT + 0x20             | guards CBCNT
        .equ    MISLOCK,   WT + 0x30             | guards MIS
        .equ    MIS,       WT + 0x1FE            | a long word across two lines
        .equ    SEQ,       WT + 0x100
        .equ    DATA,      WT + 0x120

        .equ    CI,        0x8000                | cache-inhibited, serialised
        .equ    ITERS,     CI + 0x00
        .equ    UMASK,     CI + 0x04
        .equ    WTSHARED,  CI + 0x08
        .equ    ARR,       CI + 0x10             | ARR + 4 x cpu: the barrier
        .equ    ERR,       CI + 0x20
        .equ    FIRST,     CI + 0x28
        .equ    DONE,      CI + 0x30
        .equ    IPICNT,    CI + 0x40
        .equ    SHOOT1,    CI + 0x48
        .equ    SHOOTDONE1, CI + 0x4C
        .equ    CILOCK,    CI + 0x50
        .equ    CICNT,     CI + 0x54
        .equ    CITAS,     CI + 0x58
        .equ    CITCNT,    CI + 0x5C
        .equ    CIFREE,    CI + 0x60
        .equ    CITAS2,    CI + 0x64             | guards CBTCNT
        .equ    MISDONE,   CI + 0x70
        .equ    TEARS,     CI + 0x74             | torn racing reads (counted)

        .equ    REMAP,     0x9000                | page 9: page 10, then page 11
        .equ    PAGE_A,    0xA000
        .equ    PAGE_B,    0xB000

        | Page descriptors' low bits (UM 3.2.3): resident, U and M set (no
        | table-search writes), and the cache mode and U1-U0.
        .equ    D_WT,      0x019
        .equ    D_WT_U01,  0x119
        .equ    D_CB_U10,  0x239
        .equ    D_CB,      0x039
        .equ    D_CI_SER,  0x059
        .equ    D_CI,      0x079

        .section .vectors, "a"
        .long   0x0000D000                       | 0: CPU 0's stack (CPU 1 moves)
        .long   _start                           | 1
        .rept   27                               | 2-28
        .long   h_bad
        .endr
        .long   h_ipi                            | 29: level 5 autovector
        .rept   226                              | 30-255
        .long   h_bad
        .endr

        .text
        .globl  _start
_start:
        move.l  WHOAMI, %d7                      | 0 or 1, for good
        lea     0xD000, %sp
        tst.l   %d7
        beq.s   1f
        lea     0xE000, %sp
1:      lea     ARR, %a5                         | a5: my barrier word
        lea     ARR + 4, %a6                     | a6: the other's
        tst.l   %d7
        beq.s   2f
        exg     %a5, %a6
2:      move.l  ITERS, %d5
        bne.s   3f
        moveq   #8, %d5
3:      tst.l   %d7
        bne.w   mmu_on

| --- CPU 0 alone: the tables and the data, with the MMU and caches off -----
        move.l  UMASK, %d6
        bne.s   4f
        moveq   #-1, %d6
4:      lea     TABLES, %a0                      | root and pointer tables clear
        move.w  #255, %d0
5:      clr.l   (%a0)+
        dbf     %d0, 5b
        move.l  #PTR + 0x0A, TABLES              | root[0]: resident, U set
        move.l  #PAGES + 0x0A, PTR               | pointer[0]
        lea     PAGES, %a0
        lea     page_bits, %a1
        moveq   #0, %d1                          | the page's address
        moveq   #15, %d0
6:      move.l  (%a1)+, %d2
        and.l   %d6, %d2
        or.l    %d1, %d2
        move.l  %d2, (%a0)+
        add.l   #0x1000, %d1
        dbf     %d0, 6b
        moveq   #47, %d0                         | pages 16-63: invalid
7:      clr.l   (%a0)+
        dbf     %d0, 7b
        move.l  #PAGE_A + D_WT, PAGES + 4 * 9    | page 9 is page 10 for now
        tst.l   WTSHARED
        beq.s   1f
        move.l  #0x6000 + D_WT_U01, %d2          | page 6 write-through, U 01
        and.l   %d6, %d2
        move.l  %d2, PAGES + 4 * 6
1:
        move.l  #0xAAAA0000, PAGE_A
        move.l  #0xBBBB0000, PAGE_B
        move.l  #0x70014E75, ROUTINE             | moveq #1,d0; rts

mmu_on:
        move.l  #TABLES, %d0
        movec   %d0, %srp
        movec   %d0, %urp
        move.l  #0xFF00E040, %d0                 | DTT1: $FFxxxxxx serialised
        movec   %d0, %dtt1
        pflusha
        move.l  #0x00008000, %d0                 | TC: enabled, 4 KB pages
        movec   %d0, %tc
        cinva   %bc
        move.l  #0x80008000, %d0                 | data and instruction caches
        movec   %d0, %cacr
        tst.l   %d7
        bne.s   8f
        | CPU 0 idles from its instruction cache for a while (no bus
        | request: it parks), then lets CPU 1 out of reset.
        move.w  #400, %d0
9:      dbf     %d0, 9b
        move.l  #1, RELEASE
8:      moveq   #1, %d0
        bsr     barrier

| --- 2: interprocessor interrupts ------------------------------------------
        move.w  #0x2000, %sr
        moveq   #1, %d3                          | k
        moveq   #1, %d2
        sub.l   %d7, %d2                         | the other's number
        lea     IPICNT, %a1
10:     move.l  %d2, IPI_SET
11:     cmp.l   (%a1, %d2.l*4), %d3              | until the other has taken it
        bgt.s   11b
        addq.l  #1, %d3
        cmp.l   %d5, %d3
        ble.s   10b
12:     cmp.l   (%a1, %d7.l*4), %d5              | and I have taken all of mine
        bgt.s   12b
        move.w  #0x2700, %sr
        moveq   #2, %d0
        bsr     barrier

| --- 3: locks ---------------------------------------------------------------
        lea     CILOCK, %a0
        lea     CICNT, %a1
        move.l  #0x301, %d4
        bsr     cas_lock_run
        lea     CITAS, %a0
        lea     CITCNT, %a1
        move.l  #0x302, %d4
        bsr     tas_lock_run
        lea     WTLOCK, %a0
        lea     WTCNT, %a1
        move.l  #0x303, %d4
        bsr     cas_lock_run
        lea     WTTAS, %a0
        lea     WTTCNT, %a1
        move.l  #0x304, %d4
        bsr     tas_lock_run
        | Copyback data guarded by locks that are not: a lock word must not
        | be in a copyback page the other processor may hold dirty (doc/smp.md:
        | its locked read can then be neither atomic nor lossless).
        lea     WTLOCK2, %a0
        lea     CBCNT, %a1
        move.l  #0x305, %d4
        bsr     cas_lock_run
        lea     CITAS2, %a0
        lea     CBTCNT, %a1
        move.l  #0x306, %d4
        bsr     tas_lock_run
        lea     CIFREE, %a1
        move.l  #0x307, %d4
        bsr     cas_free_run
        lea     CBFREE, %a1
        move.l  #0x308, %d4
        bsr     cas_free_run

| --- 4: coherence -----------------------------------------------------------
        | False sharing: my counter and the other's in one copyback line.
        lea     FS, %a2
        lea     (%a2, %d7.l*4), %a3              | mine
        moveq   #1, %d0
        sub.l   %d7, %d0
        lea     (%a2, %d0.l*4), %a4              | the other's
        moveq   #0, %d3                          | the other's, last seen
        moveq   #1, %d2                          | i
20:     addq.l  #1, (%a3)
        cmp.l   (%a3), %d2
        beq.s   21f
        move.l  #0x401, %d0                      | my own count lost
        bsr     err
21:     move.l  (%a4), %d0
        cmp.l   %d3, %d0
        bcc.s   22f
        move.l  #0x402, %d0                      | the other's went down
        bsr     err
22:     move.l  %d0, %d3
        addq.l  #1, %d2
        cmp.l   %d5, %d2
        ble.s   20b
        move.l  #0x411, %d0
        bsr     barrier
        cmp.l   (%a3), %d5
        beq.s   23f
        move.l  #0x403, %d0
        bsr     err
23:     cmp.l   (%a4), %d5
        beq.s   24f
        move.l  #0x404, %d0
        bsr     err
24:
        | A producer (CPU 0) and a consumer (CPU 1), write-through.
        tst.l   %d7
        bne.s   27f
        moveq   #1, %d2
25:     lea     DATA, %a0
        move.l  %d2, (%a0)+
        move.l  %d2, (%a0)+
        move.l  %d2, (%a0)+
        move.l  %d2, (%a0)+
        move.l  %d2, SEQ
        addq.l  #1, %d2
        cmp.l   %d5, %d2
        ble.s   25b
        bra.s   30f
27:     moveq   #0, %d3                          | SEQ, last seen
28:     move.l  SEQ, %d2
        cmp.l   %d3, %d2
        bcc.s   29f
        move.l  #0x405, %d0                      | SEQ went down
        bsr     err
29:     move.l  %d2, %d3
        lea     DATA, %a0
        moveq   #3, %d1
26:     cmp.l   (%a0)+, %d2                      | the data written before SEQ
        bls.s   31f
        move.l  #0x406, %d0                      | stale data after a new SEQ
        bsr     err
31:     dbf     %d1, 26b
        cmp.l   %d5, %d2
        bne.s   28b
30:     move.l  #0x421, %d0
        bsr     barrier
        | One copyback line: a word both change only by CAS, and beside it
        | each processor's own counter, changed by ordinary (cached) adds. A
        | CAS finds the line dirty in the other's cache: its locked read and
        | write are sourced and sunk there (SC 01), and the other's counter
        | survives only because the board does not pass mark invalid for a
        | long word (doc/smp.md; +rawsc loses it).
        lea     MIX, %a1
        lea     4(%a1, %d7.l*4), %a3
        move.l  %d5, %d3
70:     move.l  (%a1), %d0
71:     move.l  %d0, %d1
        addq.l  #1, %d1
        cas.l   %d0, %d1, (%a1)
        bne.s   71b
        addq.l  #1, (%a3)
        subq.l  #1, %d3
        bne.s   70b
        move.l  #0x425, %d0
        bsr     barrier
        move.l  %d5, %d0
        add.l   %d0, %d0
        cmp.l   (%a1), %d0
        beq.s   72f
        move.l  #0x408, %d0
        bsr     err
72:     cmp.l   4(%a1), %d5
        bne.s   73f
        cmp.l   8(%a1), %d5
        beq.s   74f
73:     move.l  #0x409, %d0
        bsr     err
74:
        | A long word across two write-through lines ($71FE-$7201), its halves
        | written as words by CPU 0 with the same value, read whole by CPU 1.
        | Racing, a read can be torn -- half old, half new: the two halves are
        | two transfers, cached or not (UM 7.3; the addendum's "misaligned
        | reads of shared memory and snoop invalidation"). Counted, not an
        | error. Under a lock it never is: that is checked.
        lea     MIS, %a2
        move.l  %d5, %d3
        lsl.l   #2, %d3                          | 4 x ITERS
        tst.l   %d7
        bne.s   76f
        moveq   #1, %d2
75:     move.w  %d2, 2(%a2)                      | the second line's half
        move.w  %d2, (%a2)                       | the first line's
        addq.l  #1, %d2
        cmp.l   %d3, %d2
        ble.s   75b
        move.l  #1, MISDONE
        bra.s   78f
76:     move.l  (%a2), %d0                       | misaligned: two lines
        move.l  %d0, %d1
        swap    %d1
        cmp.w   %d0, %d1
        beq.s   77f
        addq.l  #1, TEARS
77:     tst.l   MISDONE
        beq.s   76b
78:     move.l  #0x426, %d0
        bsr     barrier
        lea     MISLOCK, %a0
        tst.l   %d7
        bne.s   81f
        move.l  %d3, %d2
        add.l   %d3, %d2                         | carry on from 4 x ITERS + 1
79:     moveq   #0, %d0
        moveq   #1, %d1
        cas.l   %d0, %d1, (%a0)
        bne.s   79b
        move.w  %d2, 2(%a2)
        move.w  %d2, (%a2)
        clr.l   (%a0)
        subq.l  #1, %d2
        cmp.l   %d3, %d2
        bgt.s   79b
        bra.s   84f
81:     moveq   #0, %d0
        moveq   #1, %d1
        cas.l   %d0, %d1, (%a0)
        bne.s   81b
        move.l  (%a2), %d4
        clr.l   (%a0)
        move.l  %d4, %d1
        swap    %d1
        cmp.w   %d4, %d1
        beq.s   82f
        move.l  #0x40A, %d0                      | torn under the lock
        bsr     err
82:     subq.l  #1, %d3
        bne.s   81b
84:     move.l  #0x427, %d0
        bsr     barrier
        | MOVE16 of a line CPU 0 holds dirty, copyback U 10.
        tst.l   %d7
        bne.s   32f
        lea     M16SRC, %a0
        move.l  #0x16160000, (%a0)+
        move.l  #0x16160001, (%a0)+
        move.l  #0x16160002, (%a0)+
        move.l  #0x16160003, (%a0)+
32:     move.l  #0x431, %d0
        bsr     barrier
        tst.l   %d7
        beq.s   33f
        lea     M16SRC, %a0
        lea     M16DST, %a1
        move16  (%a0)+, (%a1)+
33:     move.l  #0x441, %d0
        bsr     barrier
        lea     M16DST, %a0
        move.l  #0x16160000, %d2
        moveq   #3, %d1
34:     cmp.l   (%a0)+, %d2
        beq.s   35f
        move.l  #0x407, %d0
        bsr     err
35:     addq.l  #1, %d2
        dbf     %d1, 34b
        move.l  #0x451, %d0
        bsr     barrier

| --- 5: the instruction cache -----------------------------------------------
        tst.l   %d7
        beq.s   40f
        jsr     ROUTINE
        jsr     ROUTINE                          | now it is in CPU 1's cache
        cmp.l   #1, %d0
        beq.s   40f
        move.l  #0x501, %d0
        bsr     err
40:     move.l  #0x511, %d0
        bsr     barrier
        tst.l   %d7
        bne.s   41f
        move.w  #0x7002, ROUTINE                 | moveq #2,d0: snooped by CPU 1
41:     move.l  #0x521, %d0
        bsr     barrier
        tst.l   %d7
        beq.s   42f
        jsr     ROUTINE
        cmp.l   #2, %d0
        beq.s   42f
        move.l  #0x502, %d0                      | ran the stale routine
        bsr     err
42:     move.l  #0x531, %d0
        bsr     barrier

| --- 6: TLB shootdown -------------------------------------------------------
        tst.l   %d7
        beq.s   50f
        cmp.l   #0xAAAA0000, REMAP               | CPU 1's ATC has page 9 now
        beq.s   50f
        move.l  #0x601, %d0
        bsr     err
50:     move.l  #0x611, %d0
        bsr     barrier
        tst.l   %d7
        bne.s   52f
        move.l  #PAGE_B + D_WT, PAGES + 4 * 9    | page 9 is page 11
        pflusha
        move.l  #1, SHOOT1
        move.l  #1, IPI_SET
51:     tst.l   SHOOTDONE1
        beq.s   51b
        bra.s   54f
52:     move.w  #0x2000, %sr
53:     tst.l   SHOOTDONE1
        beq.s   53b
        move.w  #0x2700, %sr
54:     cmp.l   #0xBBBB0000, REMAP
        beq.s   55f
        move.l  #0x602, %d0                      | the old mapping
        bsr     err
55:     move.l  #0x621, %d0
        bsr     barrier

| --- 7: the end -------------------------------------------------------------
        cpusha  %dc
        move.l  #0x711, %d0
        bsr     barrier
        lea     DONE, %a0
        move.l  #0xC0DE0000, (%a0, %d7.l*4)
60:     bra.s   60b

| --- subroutines --------------------------------------------------------------
| A spinlock (a0) around a counter (a1), ITERS times; then the counter must be
| 2 x ITERS. d4: the error code.
cas_lock_run:
        move.l  %d5, %d3
1:      moveq   #0, %d0
        moveq   #1, %d1
        cas.l   %d0, %d1, (%a0)
        bne.s   1b
        addq.l  #1, (%a1)
        clr.l   (%a0)
        subq.l  #1, %d3
        bne.s   1b
        bra.s   lock_check

tas_lock_run:
        move.l  %d5, %d3
1:      tas     (%a0)
        bmi.s   1b
        addq.l  #1, (%a1)
        clr.b   (%a0)
        subq.l  #1, %d3
        bne.s   1b
        bra.s   lock_check

| Lock-free: CAS increments of (a1).
cas_free_run:
        move.l  %d5, %d3
1:      move.l  (%a1), %d0
2:      move.l  %d0, %d1
        addq.l  #1, %d1
        cas.l   %d0, %d1, (%a1)
        bne.s   2b
        subq.l  #1, %d3
        bne.s   1b

lock_check:
        move.l  %d4, %d0
        bsr     barrier
        move.l  %d5, %d0
        add.l   %d0, %d0
        cmp.l   (%a1), %d0
        beq.s   1f
        move.l  %d4, %d0
        bsr     err
1:      rts

| Count an error, code d0; the first one's code is kept.
err:
        move.l  %a0, -(%sp)
        lea     ERR, %a0
        addq.l  #1, (%a0, %d7.l*4)
        lea     FIRST, %a0
        tst.l   (%a0, %d7.l*4)
        bne.s   1f
        move.l  %d0, (%a0, %d7.l*4)
1:      move.l  (%sp)+, %a0
        rts

| The interprocessor interrupt (level 5, vector 29): acknowledged first, so
| that the next one is not lost; counted; and on CPU 1, a shootdown asked
| for is done (UM 3.7: PFLUSHA).
h_ipi:
        movem.l %d0-%d1/%a0, -(%sp)
        move.w  18(%sp), %d0                     | the frame's format/vector word
        and.w   #0x0FFF, %d0
        cmp.w   #0x74, %d0
        beq.s   1f
        move.l  #0x201, %d0
        bsr     err
1:      move.l  #1, IPI_ACK
        nop                                      | the acknowledge reaches the board
        lea     IPICNT, %a0
        addq.l  #1, (%a0, %d7.l*4)
        tst.l   %d7
        beq.s   2f
        tst.l   SHOOT1
        beq.s   2f
        clr.l   SHOOT1
        pflusha
        addq.l  #1, SHOOTDONE1
2:      movem.l (%sp)+, %d0-%d1/%a0
        rte

h_bad:
        move.w  6(%sp), %d0
        and.l   #0x0FFF, %d0
        or.l    #0xF000, %d0
        bsr     err
1:      bra.s   1b

page_bits:
        .long   D_WT, D_WT, D_WT, D_CI           | 0-3
        .long   D_WT_U01, D_WT_U01, D_CB_U10, D_WT_U01   | 4-7
        .long   D_CI_SER, D_WT, D_WT, D_WT       | 8-11 (9 is set apart)
        .long   D_CB, D_CB, D_CB, D_CB           | 12-15

| --- page 3, cache-inhibited: the barrier ------------------------------------
| Wait until the other processor has reached barrier d0 too. Its fetches are
| uncached long words, and the loop's branch withdraws the prefetch's bus
| request -- so a processor is often granted the bus without wanting it, in
| implicit ownership, when the other asks for it (UM 7.8.1).
        .org    0x2000
barrier:
        move.l  %d0, (%a5)
1:      cmp.l   (%a6), %d0
        bgt.s   1b
        rts
