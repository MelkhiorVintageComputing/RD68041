| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- what the bare-metal rd-virt programs (sim/programs/virt_*.S) share
| (RD68031's).
|
| The board is sim/virt/machine.h's: RAM from 0, the devices at $FF000000.
| A program links at 0 with its own vectors (virt.ld), prints through the
| goldfish-tty's PUT_CHAR, and ends by writing virt-ctrl's command register:
| 2 (halt, which rd-virt takes as a power-off and a pass when the console
| says PASS) or 3 (panic: a failure whatever the console says).
|
|   $00000  vectors      $01000  code and data      $0F000  supervisor stack
|   $10000- the programs' own tables and pages (each says where)

        .equ    PIC1,    0xFF000000     | goldfish-pic, level 1 ... (+$1000 each)
        .equ    PIC6,    0xFF005000     | ... level 6: the RTCs' IRQs 168, 169
        .equ    PIC_PENDING, 0x04
        .equ    PIC_DISABLE_ALL, 0x08
        .equ    PIC_ENABLE, 0x10
        .equ    RTC0,    0xFF006000     | the scheduler's goldfish-rtc
        .equ    RTC_TIME_LOW, 0x00
        .equ    RTC_TIME_HIGH, 0x04
        .equ    RTC_ALARM_LOW, 0x08
        .equ    RTC_ALARM_HIGH, 0x0C
        .equ    RTC_IRQ_ENABLED, 0x10
        .equ    RTC_CLEAR_INTERRUPT, 0x1C
        .equ    TTY,     0xFF008000
        .equ    CTRL,    0xFF009000
        .equ    STACK,   0x0000F000

| Print the NUL-terminated string at \lab.
        .macro  PUTS lab
        lea     \lab, %a0
        bsr     puts
        .endm

| Halt the machine: 2 = done, 3 = failed.
        .macro  POWEROFF code
        move.l  #\code, CTRL+4
1:      bra.s   1b
        .endm

| The vector table: the reset vectors, and every other vector to `unexp`
| unless the program has defined a handler for it by name (vec_<n>) -- so it
| goes at the END of a program, after the handlers.
        .macro  VECTORS
        .section .vectors, "ax"
        .long   STACK, _start
        .irp    n, 2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63
        .ifdef  vec_\n
        .long   vec_\n
        .else
        .long   unexp
        .endif
        .endr
        .endm

| What every program has: puts, a hex printer, and the handler of every
| exception the program did not expect, which prints its format/vector word
| and stacked PC and fails.
        .macro  COMMON
puts:   move.b  (%a0)+, %d0
        beq.s   9f
        and.l   #0xFF, %d0
        move.l  %d0, TTY
        bra.s   puts
9:      rts
| d1 as eight hex digits
puthex: movem.l %d0-%d2, -(%sp)
        moveq   #7, %d2
1:      rol.l   #4, %d1
        move.l  %d1, %d0
        and.l   #15, %d0
        cmp.b   #10, %d0
        blt.s   2f
        add.b   #'A'-'0'-10, %d0
2:      add.b   #'0', %d0
        move.l  %d0, TTY
        dbra    %d2, 1b
        movem.l (%sp)+, %d0-%d2
        rts
unexp:  lea     m_unexp, %a0
        bsr     puts
        moveq   #0, %d1
        move.w  6(%sp), %d1
        bsr     puthex
        move.l  #' ', TTY
        move.l  2(%sp), %d1
        bsr     puthex
        move.l  #10, TTY
        POWEROFF 3
m_unexp: .asciz "FAIL: unexpected exception, format/vector and PC "
        .even
        .endm
