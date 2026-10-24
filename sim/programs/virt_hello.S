| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041

| RD68041 -- rd-virt bare metal: the console, and the machine's own registers.
|
| The tty's PUT_CHAR and its version register, virt-ctrl's FEATURES, a
| byte-wide read of a device register, the PIC's registers, the hole above the
| devices (a bus error, caught), and a power-off. Untranslated, caches off.

#include "virt.inc"

        .text
        .globl  _start
_start:
        PUTS    m_hello
        | goldfish-tty version 1, virt-ctrl power control
        cmp.l   #1, TTY+0x20
        bne     fail
        cmp.l   #1, CTRL+0
        bne     fail
        | a byte-wide read of a long-word register: its low-order byte
        cmp.b   #1, CTRL+3
        bne     fail
        | a PIC with nothing enabled has nothing pending
        tst.l   PIC6+PIC_PENDING
        bne     fail
        | the hole above the devices answers with a bus error
        clr.l   %d7
        lea     1f, %a6
        move.l  0xFF800000, %d0
        bra     fail
1:      cmp.l   #1, %d7
        bne     fail
        | the time moves forward between two reads
        move.l  RTC0+RTC_TIME_LOW, %d1
        nop
        nop
        move.l  RTC0+RTC_TIME_LOW, %d2
        cmp.l   %d1, %d2
        beq     fail
        PUTS    m_pass
        POWEROFF 2
fail:   PUTS    m_fail
        POWEROFF 3

| The bus error from the hole: count it, drop its frame -- the access error
| frame ($7, 60 bytes, UM 8.4.6) -- and go on at the continuation in A6
| rather than return into the faulted read.
vec_2:  addq.l  #1, %d7
        move.w  6(%sp), %d0
        and.w   #0xF000, %d0
        cmp.w   #0x7000, %d0
        bne     fail
        lea     60(%sp), %sp
        jmp     (%a6)

        COMMON
m_hello: .asciz "hello from rd-virt bare metal\n"
m_pass:  .asciz "PASS: virt_hello\n"
m_fail:  .asciz "FAIL: virt_hello\n"
        .even
        VECTORS
