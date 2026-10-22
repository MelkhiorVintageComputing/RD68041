/* SPDX-License-Identifier: CERN-OHL-S-2.0
 * Copyright 2026 Romain Dolbeau
 * Source location: https://github.com/MelkhiorVintageComputing/RD68041
 */

/* RD68041 -- the link map for a program that runs on the bare core.
 *
 * The core-level harness (sim/tb/rd68041_core_harness.svh) puts the RAM
 * at $0000_0000 with sixteen address bits, so everything lives in the first
 * 64 KB: the exception vectors at zero, the program at $1000 where the reset
 * vector points, and the stack at the top.
 *
 * There is no operating system and no loader. The image IS the memory. */

ENTRY(_start)

MEMORY
{
  ram (rwx) : ORIGIN = 0x00000000, LENGTH = 0x00010000
}

SECTIONS
{
  /* The two long words the processor reads before it fetches anything:
     the interrupt stack pointer and the PC (UM 8.2.10). */
  .vectors 0x00000000 : { KEEP(*(.vectors)) } > ram

  .text 0x00001000 :
  {
    *(.text.startup)
    *(.text*)
    *(.rodata*)
  } > ram

  .data : { *(.data*) } > ram
  .bss  : { __bss_start = .; *(.bss*) *(COMMON) __bss_end = .; } > ram

  _end = .;

  /* Nothing from the C runtime: there is no runtime. Anything that turns up
     here is a mistake worth seeing rather than silently dropping. */
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
