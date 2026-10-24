/* SPDX-License-Identifier: CERN-OHL-S-2.0
 * Copyright 2026 Romain Dolbeau
 * Source location: https://github.com/MelkhiorVintageComputing/RD68041
 */

/* RD68041 -- the link map of the bare-metal rd-virt programs
 * (sim/programs/virt_*.S): vectors at 0, code from $1000, physical = linked
 * (sim/virt/machine.cpp loads each PT_LOAD at its physical address). */

ENTRY(_start)

SECTIONS
{
  .vectors 0x00000000 : { KEEP(*(.vectors)) }
  .text 0x00001000 : { *(.text*) *(.rodata*) }
  .data : { *(.data*) }
  .bss  : { *(.bss*) *(COMMON) }
  ASSERT(. <= 0xE000, "a virt program runs into its stack")
  .tables 0x00010000 : { KEEP(*(.tables)) }
  _end = .;
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
