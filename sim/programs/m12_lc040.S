| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M12's MC68LC040, on the core built with FPU = 0 and on UAE040 -L
| (make cosim-lc): every FP instruction is vector 11 with an eight-word format
| $4 frame (UM A.5.1, A.5.2) -- the SR, the next instruction's PC, the format
| and vector word, the calculated <ea>, the FP instruction's own PC -- and
| leaves every register as it was, An of (An)+ and -(An) included.
|
|   every class: the general operations, register to register and from
|     memory, implemented on the MC68040 or not (FSIN), FMOVECR, packed;
|     FMOVE out; FMOVE(M) of the control registers; FMOVEM of FP0-FP7, static
|     and dynamic; FScc, FTRAPcc, FBcc (FNOP); FSAVE, FRESTORE;
|   every addressing mode that reaches the address: (An), (An)+ and -(An) at
|     each operand size (a byte through A7 steps two), (d16,An), (d8,An,Xn),
|     the absolutes, (d16,PC), memory indirect, immediate (0), Dn (0);
|   from user mode, onto the supervisor stack, and back by RTE of the $4
|     frame; FSAVE from user mode: a privilege violation, not format $4;
|   a traced FP instruction.
|
| The vector 11 handler keeps the frame in registers -- D0 the format and
| vector word, D1 the PC, D2 the address, D3 the FP instruction's PC, D4 the
| SR -- so the comparison at every boundary covers it; D7 counts them. The
| encodings PRM 5 has no instruction for, and FDBcc, are core_lc040_tb's:
| UAE040 -L gives them format $4 frames, the manual does not (doc/oracles.md).

        .equ    ISP_TOP, 0x0000F000
        .equ    USP_TOP, 0x0000D000
        .equ    DATA,    0x00004000

        .section .vectors, "a"
        .long   ISP_TOP                          | 0
        .long   _start                           | 1
        .rept   6                                | 2-7
        .long   h_bad
        .endr
        .long   h_priv                           | 8 privilege violation
        .long   h_trace                          | 9 trace
        .long   h_bad                            | 10
        .long   h_f4                             | 11 F-line: format $4
        .rept   244                              | 12-255
        .long   h_bad
        .endr

        .text
        .globl  _start
_start:
        moveq   #0, %d7
        moveq   #0, %d6
        moveq   #0, %d5
        lea     USP_TOP, %a0
        move.l  %a0, %usp
        lea     DATA, %a0
        lea     DATA + 0x100, %a1
        lea     DATA + 0x200, %a2
        moveq   #8, %d5

        | --- the general operations --------------------------------------
        fadd.x  %fp1, %fp2                       | register to register: 0
        fsin.x  %fp0                             | unimplemented on the 040 too
        fmovecr #0x32, %fp3                      | FMOVECR: 0
        fmove.l #5, %fp0                         | immediate: 0
        fmove.x #0x3fff00008000000000000000, %fp1
        fmove.l %d5, %fp0                        | Dn: 0
        fmove.s %d5, %fp0
        fadd.x  (%a0), %fp0                      | (An)
        fmove.x (%a0)+, %fp0                     | (An)+: An, An left alone
        fmove.x -(%a1), %fp1                     | -(An): An - 12
        fmove.d -(%a1), %fp1                     | - 8
        fmove.s -(%a1), %fp1                     | - 4
        fmove.l -(%a1), %fp1
        fmove.w -(%a1), %fp1                     | - 2
        fmove.b -(%a1), %fp1                     | - 1
        fmove.b -(%sp), %fp1                     | A7: - 2
        fmove.b (%sp)+, %fp1
        fmove.p -(%a1), %fp1                     | packed: - 12
        fsub.d  16(%a0), %fp2                    | (d16,An)
        fmul.l  4(%a0, %d5.l*2), %fp2            | (d8,An,Xn)
        fdiv.w  DATA + 0x10, %fp2                | (xxx).W
        fdiv.l  DATA + 0x20.l, %fp2              | (xxx).L
        fcmp.x  pc_data(%pc), %fp2               | (d16,PC)
        ftst.l  ([DATA + 0x40])                  | memory indirect: the pointer read
        fsqrt.x ([DATA + 0x40], 8), %fp4
        fsglmul.s (%a0), %fp5
        fetox.x (%a0)+, %fp6                     | unimplemented, from memory

        | --- FMOVE out ----------------------------------------------------
        fmove.x %fp0, -(%a1)
        fmove.d %fp0, (%a1)+
        fmove.l %fp0, %d1                        | Dn: 0
        fmove.p %fp0, (%a0){#3}
        fmove.p %fp0, -(%a1){#-2}                | - 12 (dynamic k: core_lc040_tb)
        fmove.b %fp0, -(%sp)

        | --- the control registers -----------------------------------------
        fmove.l %fpcr, %d1                       | Dn: 0
        fmove.l %a0, %fpiar                      | An: 0
        fmove.l #0, %fpcr                        | immediate: 0
        fmove.l %fpsr, -(%a1)                    | -(An): An itself
        fmovem.l %fpcr/%fpsr/%fpiar, -(%a1)
        fmovem.l (%a0)+, %fpcr/%fpsr
        .word   0xf23c, 0x9800, 0, 1, 0, 2       | FMOVEM.L #1,#2,FPCR/FPSR

        | --- FMOVEM of FP0-FP7 ---------------------------------------------
        fmovem.x %fp0-%fp3, -(%a1)               | An itself
        fmovem.x (%a0)+, %fp0-%fp7
        fmovem.x %fp2/%fp4, 0x30(%a0)
        moveq   #0x0f, %d1
        fmovem.x %d1, -(%a1)                     | dynamic
        fmovem.x (%a0), %d1

        | --- the conditionals ----------------------------------------------
        fseq    %d1                              | Dn: 0
        fsne    (%a0)+
        fsgt    -(%a1)                           | a byte: - 1
        fsle    -(%sp)                           | A7: - 2
        fsf     8(%a2)
        ftrapeq                                  | no operand: 0
        ftrapne.w #0x1234                        | 0
        ftrapgt.l #0x12345678
        fbeq    1f                               | FBcc: 0, not taken
1:      fbf.l   2f
2:      fnop                                     | FBF: 0

        | --- the state frames ----------------------------------------------
        fsave   -(%a1)                           | An itself
        fsave   (%a0)
        frestore (%a0)+
        frestore 0x10(%a2)

        | --- from user mode ------------------------------------------------
        move.w  #0x0000, %sr
        fadd.l  #3, %fp0                         | onto the supervisor stack
        fmove.x (%a0)+, %fp1
        fsave   (%a0)                            | privileged: vector 8, not 11
        illegal                                  | (not reached: h_priv goes on)

| Vector 11: the eight-word frame into registers (UM A.5.2), and back past
| the FP instruction -- the frame's PC is the next instruction's.
h_f4:
        move.w  6(%sp), %d0
        move.l  2(%sp), %d1
        move.l  8(%sp), %d2
        move.l  12(%sp), %d3
        move.w  (%sp), %d4
        addq.l  #1, %d7
        rte
| Vector 8, FSAVE from user mode: the frame's PC is the FSAVE's; go on past
| it, and trace one FP instruction from the supervisor level.
h_priv:
        move.w  6(%sp), %d0
        move.l  2(%sp), %d1
        addq.l  #1, %d6
        addq.l  #8, %sp                          | the four-word frame dropped
        ori.w   #0x8000, %sr                     | T1: trace every instruction
        fabs.x  %fp1                             | traced: format $4 first
        nop
        andi.w  #0x7fff, %sr
        fnop
        illegal
h_trace:
        addq.l  #1, %d5
        rte
h_bad:
        move.l  #0x0bad, %d6
        illegal

        .balign 4
pc_data:
        .long   0x3fff0000, 0x80000000, 0x00000000
