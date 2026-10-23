| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M9's snooping, for sim/tb/core_snoop_tb.sv: the program and an
| alternate master (the bench's) share memory, each side writing only its own
| words and always upwards, and the caches have to keep both sides' view
| coherent through snooping alone (UM 4.5).
|
|   A ($6000, 64 long words): the program adds 1 to every word, PASSES times,
|     copyback; the master reads them, snooped, and checks they never go down.
|   B ($6100, 64 long words): the master writes them, ever larger; the program
|     clears them first (so its lines start dirty, and the master's word writes
|     are sunk into them), then reads them each pass, copyback-cached, and
|     counts in D7 any that went down since it last looked (C, $6200).
|   Then the program says it is done (MARK), waits for the bench's FLAG -- the
|   master has stopped -- reads B once more into C, and pushes everything; the
|   bench checks A (all PASSES), C (the master's last writes) and D7 (zero).
|
| MARK and FLAG are in a cache-inhibited page (DTT1 over $02xxxxxx; the
| bench's memory repeats every 64 KB, so $0200FF00 is $FF00).

        .equ    STACK_TOP, 0x0000F000
        .equ    A,         0x00006000
        .equ    B,         0x00006100
        .equ    C,         0x00006200
        .equ    MARK,      0x0200FF00
        .equ    FLAG,      0x0200FF04
        .equ    PASSES,    24

        .section .vectors, "a"
        .long   STACK_TOP
        .long   _start

        .text
        .globl  _start
_start:
        cinva   %bc
        move.l  #0x0000E020, %d0                 | DTT0: $00xxxxxx copyback
        movec   %d0, %dtt0
        move.l  #0x0200E060, %d0                 | DTT1: $02xxxxxx cache-inhibited
        movec   %d0, %dtt1
        move.l  #0x80008000, %d0
        movec   %d0, %cacr
        moveq   #0, %d7
        | B's lines dirty in the cache, so that the master's word writes are
        | sunk into them (Table 4-4, D12).
        lea     B, %a1
        moveq   #63, %d5
0:      clr.l   (%a1)+
        dbf     %d5, 0b

        moveq   #PASSES - 1, %d6
1:      lea     A, %a0
        lea     B, %a1
        lea     C, %a2
        moveq   #63, %d5
2:      addq.l  #1, (%a0)+                       | A[i] += 1
        move.l  (%a1)+, %d0                      | B[i]
        cmp.l   (%a2), %d0
        bcc.s   3f
        addq.l  #1, %d7                          | went down: incoherent
3:      move.l  %d0, (%a2)+
        dbf     %d5, 2b
        dbf     %d6, 1b

        move.l  #1, MARK
4:      tst.l   FLAG
        beq.s   4b
        lea     B, %a1
        lea     C, %a2
        moveq   #63, %d5
5:      move.l  (%a1)+, (%a2)+
        dbf     %d5, 5b
        cpusha  %dc
        move.l  #2, MARK
        illegal
