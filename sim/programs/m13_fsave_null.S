| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- M13: the FPU's null state (UM 9.8): FSAVE after FRESTORE of a
| null frame, as Linux's setup_arch and its first context switch have them,
| and after each nonconditional FP instruction that is not an operation --
| FMOVEM out (BusyBox's setjmp), FMOVE out, a control register read -- which
| leave the null state as FMOVE in does; and FNOP, which does not
| (doc/bugs-found.md M13). Run by make cosim.

        .equ    STACK_TOP, 0x0000F000

        .section .vectors, "a"
        .long   STACK_TOP
        .long   _start

        .text
        .globl  _start
_start:
        fmove.l #1, %fp0                | the FPU leaves the null state
        clr.l   -(%sp)
        frestore (%sp)+                 | ... and goes back to it (UM 9.7)
        lea     buf, %a0
        fsave   (%a0)
        move.l  (%a0), %d0              | a null frame: zero
        fmove.l #2, %fp1
        fsave   (%a0)
        move.l  (%a0), %d1              | an idle one: $41000000
        lea     regs, %a1
        bsr.s   null
        fmovem.x %fp0-%fp7, (%a1)
        bsr.s   save
        move.l  %d0, %d2
        bsr.s   null
        fmove.x %fp0, (%a1)
        bsr.s   save
        move.l  %d0, %d3
        bsr.s   null
        fmove.l %fpcr, %d4
        bsr.s   save
        move.l  %d0, %d4
        bsr.s   null
        fmovem.l %fpcr/%fpsr, (%a1)
        bsr.s   save
        move.l  %d0, %d5
        bsr.s   null
        fnop
        bsr.s   save
        move.l  %d0, %d6                | still null
        illegal
null:   clr.l   -(%sp)
        frestore (%sp)+
        rts
save:   fsave   (%a0)
        move.l  (%a0), %d0
        rts

        .data
        .even
buf:    .space  256
regs:   .space  96
