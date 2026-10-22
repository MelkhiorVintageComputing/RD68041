# RD68041

A from-scratch SystemVerilog implementation of the Motorola **MC68040**, and of the
**MC68LC040** (the same part without its floating-point unit), for FPGA and ASIC.

It follows [RD68021](https://github.com/MelkhiorVintageComputing/RD68021) (an MC68020)
and [RD68031](https://github.com/MelkhiorVintageComputing/RD68031) (an MC68030), and
keeps their rules, tools and process. The integer core is new rather than a fork: the
MC68040 is a pipelined, Harvard design, and this one is too.

- a six-stage integer pipeline;
- 4 KB instruction and 4 KB data caches, four-way, with copyback, and bus snooping;
- separate instruction and data MMUs, each with a 64-entry ATC and two transparent
  translation registers;
- the on-chip FPU of the MC68040 (`FPU = 1`), or none for the MC68LC040 (`FPU = 0`);
- the MC68040's synchronous bus: line bursts, TBI, retry, snooping, no dynamic sizing.

The target is at least 20 MHz, preferably 25 MHz or more, on a Xilinx Artix-7.

## Status

**M0: scaffolding.** No processor yet. The milestones are listed in `doc/plan.md`, and
the state of each oracle is in `doc/oracles.md`.

## Goals

1. **Software compatibility.** Everything a real MC68040 or MC68LC040 runs, this runs,
   including Motorola's M68040FPSP for the instructions the part leaves to software.
   Where the reference emulators disagree with the core, the Motorola manuals in
   `Inputs/doc/` decide.
2. **Bus compatibility.** The pins follow the MC68040's bus protocol, so the core can
   sit on a real 68040 board's bus.
3. **Cycle counts are allowed to differ, but never silently.** Every divergence from
   the manual's instruction timings is measured and explained in
   `doc/timing-divergences.md`.

## Verification

1. **The WinUAE MC68040 core** (`tools/cosim/uae040/`), with its MMU, copyback data
   cache and FPU, as the instruction, MMU and FPU oracle; its `cputest` adds vectors
   from a generator checked against real hardware.
2. **QEMU's m68040**, a third opinion on instruction traces, and **Berkeley
   TestFloat** for the FPU's arithmetic.
3. **rd-virt** (`sim/virt/`), a deterministic machine shaped like Linux's m68k `virt`
   board, where the core and the WinUAE core run Linux in lockstep.
4. **A Macintosh Quadra in MAME** (`sim/mame/`), the core as a MAME CPU against MAME's
   own m68040.

## Rules the RTL follows

These are hard rules; breaking one is a bug. `CLAUDE.md` has the full text.

- **Nothing under `Inputs/` is modified.**
- **The reference implementations are oracles, never sources.**
- **No initialisation outside reset.** `make audit` proves it.
- **Portable SystemVerilog.** The RTL elaborates under iverilog, Verilator,
  yosys, Vivado, Quartus and Questa (`doc/coding-standard.md`).

## Getting started

```sh
git clone --recursive <this repository>
cd RD68041
make check
```

`make help` lists every target.

## Licence

Copyright 2026 Romain Dolbeau.

RD68041 is licensed under the **CERN Open Hardware Licence Version 2 – Strongly
Reciprocal** (SPDX: `CERN-OHL-S-2.0`); the full text is in `LICENSE`. Harness code
that links against a GPL oracle (`tools/cosim/uae040/`, `sim/mame/`) is under the
GPL-2.0-or-later, as its header says; none of it is part of the hardware.

The submodules under `Inputs/` are separate works under their own terms, as are
the Motorola manuals they contain.
