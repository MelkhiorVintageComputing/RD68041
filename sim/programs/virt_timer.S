| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- rd-virt bare metal: timer interrupts.
|
| The scheduler's goldfish-rtc, through goldfish-pic 6, at level 6,
| autovectored (vector 30). Ten alarms 50 us apart: the first five taken out
| of STOP (the machine skips its idle time to the alarm), the next five
| taken while the program spins with the mask at 0, and then two with the
| mask at 6, which must not be taken until the mask comes down. Each tick
| reads the time, which must have reached the alarm. Untranslated, caches
| off.

#include "virt.inc"

        .equ    PERIOD, 50000           | ns

        .text
        .globl  _start
_start:
        PUTS    m_start
        clr.l   %d6                     | ticks taken
        move.l  #1, PIC6+PIC_ENABLE     | IRQ 168: RTC0
        move.l  #1, RTC0+RTC_IRQ_ENABLED
        bsr     arm
        | five ticks out of STOP
1:      stop    #0x2000
        cmp.l   #5, %d6
        blt.s   1b
        | five more while spinning, the mask at 0
        clr.l   %d5
2:      addq.l  #1, %d5
        cmp.l   #10, %d6
        blt.s   2b
        tst.l   %d5
        beq     fail
        | the mask at 6: the alarm fires and stays pending
        move.w  #0x2600, %sr
        bsr     arm
        move.l  #4000, %d0              | 80 us at 20 ns a step
3:      dbra    %d0, 3b
        cmp.l   #10, %d6
        bne     fail
        tst.l   PIC6+PIC_PENDING        | pending at the PIC, masked at the CPU
        beq     fail
        move.w  #0x2000, %sr            | ... and taken now -- at the
        moveq   #3, %d0                 | first boundary that is not a
4:      dbra    %d0, 4b                 | serialising instruction's on the
        cmp.l   #11, %d6                | core (doc/timing-divergences.md)
        bne     fail
        tst.l   PIC6+PIC_PENDING
        bne     fail
        PUTS    m_pass
        POWEROFF 2
fail:   PUTS    m_fail
        move.l  %d6, %d1
        bsr     puthex
        move.l  #10, TTY
        POWEROFF 3

| Arm the alarm PERIOD from now. TIME_LOW latches TIME_HIGH (goldfish-rtc).
arm:    move.l  RTC0+RTC_TIME_LOW, %d1
        move.l  RTC0+RTC_TIME_HIGH, %d0
        add.l   #PERIOD, %d1
        moveq   #0, %d2
        addx.l  %d2, %d0
        move.l  %d1, alarm_lo
        move.l  %d0, RTC0+RTC_ALARM_HIGH
        move.l  %d1, RTC0+RTC_ALARM_LOW
        rts

| Level 6 autovector: acknowledge the RTC, check the time reached the alarm,
| count, and re-arm until ten.
vec_30: movem.l %d0-%d2, -(%sp)
        move.l  #1, RTC0+RTC_CLEAR_INTERRUPT
        move.l  RTC0+RTC_TIME_LOW, %d1
        sub.l   alarm_lo, %d1           | now - alarm: positive, and not huge
        cmp.l   #4*PERIOD, %d1
        bhs     fail
        addq.l  #1, %d6
        cmp.l   #10, %d6
        bge.s   1f
        bsr     arm
1:      movem.l (%sp)+, %d0-%d2
        rte

        COMMON
alarm_lo: .long 0
m_start: .asciz "virt_timer: ten alarms, five from STOP\n"
m_pass:  .asciz "PASS: virt_timer\n"
m_fail:  .asciz "FAIL: virt_timer, ticks "
        .even
        VECTORS
