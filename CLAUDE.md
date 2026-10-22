# RD68041 — SystemVerilog MC68040 / MC68LC040

A from-scratch SystemVerilog implementation of the Motorola MC68040, and of the
MC68LC040 (no FPU, `FPU = 0`), targeting FPGA (short-term priority) and ASIC. It
follows RD68021 (`../RD68021`, an MC68020) and RD68031 (`../RD68031`, an MC68030) and
keeps their goals, rules, tools and process. Unlike RD68031, the processor is **not a
fork**: the integer pipeline, caches, MMU, bus unit and FPU are new. Tools, testbench
infrastructure and a few leaf units are carried over (`doc/plan.md`, section 1).

The sibling repositories (`../RD68021`, `../RD68031`, `../RD68884`) may be read and
copied from. **They are never modified.**

## Goals

1. **100 % software compatibility** with a real MC68040 and MC68LC040, including the
   M68040FPSP's view of the FPU (unimplemented instructions and data types trap as
   they do on the part).
2. **Bus compatibility** — the MC68040's synchronous bus: TS/TIP/TA/TEA/TCI/TBI, line
   transfers, retry, arbitration, snooping (SC1-SC0, MI), no dynamic bus sizing.
3. Instruction *cycle* timings need not match — broadly similar, faster where cheap,
   slower where unavoidable — but **every divergence must be measured, reported and
   justified** in `doc/timing-divergences.md`.
4. **At least 20 MHz, preferably 25 MHz or more, on a Xilinx Artix-7** (`make impl`).

## Hard rules

These are not style preferences. Breaking one is a bug.

### `Inputs/` is immutable

Nothing under `Inputs/` may be modified, ever. New inputs may be *added* (as submodules or
new directories), but once added they are frozen too. Anything that builds into its own
tree (WinUAE, Hatari, MAME, QEMU) is copied into `build/` first and built there.

### A reference implementation is never a source for RTL

Everything under `Inputs/ref/` exists **only** to be run and compared against:

- `winuae/` and `hatari/` — the WinUAE MC68040 core (MMU, caches, FPU) and its `cputest`;
- `mame/` — MAME's m68040 and its Macintosh Quadra machines;
- `qemu/` — QEMU's m68040;
- the Linux and NetBSD trees fetched into `build/` by `Inputs/sw/MANIFEST*`.

You may **not** read them to work out how to write our RTL. Anyone (human or agent)
writing code in `rtl/` must not open a file in those directories. Harness code in
`tools/cosim/`, `sim/virt/` and `sim/mame/` is written against the oracles' *interfaces*
(a CPU core's API, an emulator's device interface), which is what running them needs.

Two exceptions, decided with the user:

- **The M68040FPSP** (`arch/m68k/fpsp040/` in Linux, its counterpart in NetBSD) may be
  read as *interface documentation*: it is the consumer of the FPU's FSAVE frames and
  the only definition of their internal fields. Read it for that contract only, cite
  it in comments (`FPSP <file>`), and nothing else in those trees.
- **`Inputs/QuadraFPGA/`** is a *bus witness*: a slave design known to work against a
  real MC68040, not an implementation of the chip. Anyone may read it, RTL authors
  included, as evidence of what the part does on the bus. No code from it goes into
  `rtl/`; it is the basis for a slave model in `sim/models/`.

The golden reference is the documentation in `Inputs/doc/`. When an oracle disagrees with
this core, the manual is the arbiter and the disagreement is an investigation, not a bug
report against the RTL. `doc/oracles.md` records what each oracle is trusted for.

### No initialisation outside reset

ASIC is a target, so there is no power-on register state. No `initial` blocks in `rtl/`,
no declaration-site initialisers on anything that infers a register, no relying on `'x`
resolving to a useful value. Every register gets its value from the reset branch of its
`always_ff`. `make audit` proves it, in the source *and* in the yosys netlist.

### Split I/O pins

The original's bidirectional and three-state pins become separate `_i` / `_o` / `_oe`
signals, `_oe` active high meaning the core is driving. An external wrapper converts to
real three-state pins where a design needs them. See `doc/pinout.md`.

### One clock

The core runs on BCLK, rising edge only. PCLK is a port and is not used
(`doc/timing-divergences.md`). No `negedge` in `rtl/` (`doc/coding-standard.md`).

### Portable SystemVerilog only

The RTL must elaborate under **iverilog, Verilator, yosys, Vivado, Quartus and Questa**.
See `doc/coding-standard.md` for the permitted subset — yosys is the strictest and
therefore defines it. `make lint` is the gate for the three that need no vendor
installation; `make synth`, `make lint-quartus` and `make lint-questa` are the other
three, and they are not in `make check` for that reason.

### Mind the host's memory

The build machine has 15 GB and no swap, and has crashed out of memory. Heavy jobs —
MAME, QEMU, the Linux kernel, Verilator builds, the UAE040 core build — are run one at a
time, never alongside each other or alongside anything else, with bounded parallelism
(`-j4` at most; `-j2` for MAME). Simulations that take little memory (the iverilog
testbenches, the oracle runs) may run up to **4 at a time** in parallel, using at most
4 cores.

## Scope

| | |
|---|---|
| In | the full MC68040 integer ISA; the 4 KB instruction and data caches with copyback, the push and store buffers, CINV/CPUSH, MOVE16, and snooping; both MMUs (TC, URP, SRP, ITT0/1, DTT0/1, MMUSR, two 64-entry ATCs, the table search, PTEST/PFLUSH); the MC68040 FPU with its unimplemented-instruction and unsupported-data-type traps, FSAVE/FRESTORE; the MC68LC040 (`FPU = 0`); the MC68040 bus |
| Stubbed (defined outputs, documented) | JTAG (UM 6), the multiplexed bus and DLE modes selected at reset, PST3-PST0 |
| Out | the MC68EC040 and the 040V parts (LPSTOP); PCLK |

## Layout

| Path | What |
|---|---|
| `rtl/` | the processor, one module per file, prefix `rd68041_` |
| `rtl/gen/` | generated from `tools/ucode/` — decoder, micro-sequencer store, frame package |
| `tools/` | microcode assembler, test runners, timing solver, doc generators (Python) |
| `tools/cosim/uae040/` | the harness around the WinUAE MC68040 core: traces, vectors |
| `sim/tb/` | testbenches |
| `sim/models/` | bus-slave models, the alternate bus master, the bus monitor |
| `sim/programs/` | real code, built by the cross-compiler and run on the core |
| `sim/virt/` | rd-virt, the deterministic lockstep platform (from M13) |
| `sim/mame/` | the core as a MAME CPU device in a Macintosh Quadra (from M14) |
| `scripts/` | Vivado and Quartus synthesis, implementation and timing scripts |
| `doc/` | plan, pinout, coding standard, oracles, checkpoint, divergence and implementation reports |
| `Inputs/doc/` | Motorola manuals, split by section, with machine-readable AC specs |
| `Inputs/ref/` | reference implementations used as oracles (not as RTL sources) |
| `Inputs/third_party/` | Berkeley SoftFloat and TestFloat, for the FPU |
| `Inputs/QuadraFPGA/` | the bus witness (above) |

## Documentation map

Everything authoritative lives in `Inputs/doc/MC68030_Doc_More_Readable/`. **Ignore
`MC68000UM_split`** — a different processor. `MC68030UM_split` and `MC68881UM_split` are
read only to understand modules reused from RD68031 and to compare.

| Need | Read (`MC68040UM_split/` unless named) |
|---|---|
| Architecture overview, pipeline | `04-section-01-introduction.pdf` |
| Integer unit, registers, SR, the stacks | `05-section-02-integer-unit.pdf` |
| MMU, ATCs, table search, PTEST/PFLUSH | `06-section-03-memory-management-unit.pdf` |
| Caches, copyback, snooping, CINV/CPUSH | `07-section-04-instruction-and-data-caches.pdf` |
| Pin behaviour | `08-section-05-signal-description.pdf` |
| JTAG (stubbed) | `09-section-06-jtag-test-access-port.pdf` |
| Bus protocol | `10-section-07-bus-operation.pdf` |
| Exceptions, stack frames, the access error frame | `11-section-08-exception-processing.pdf` |
| FPU, unimplemented instructions and data types, FSAVE frames | `12-section-09-floating-point-unit.pdf` |
| MC68040 cycle counts | `13-section-10-instruction-timings.pdf` |
| Bus timing figures and AC limits | `14-section-11-...pdf`, `figure-11-*.md`, `ac-electrical-specifications.csv` |
| The MC68LC040 | `16-appendix-a-mc68lc040.pdf` |
| FP emulation (FPSP) | `20-appendix-e-floating-point-emulation.pdf` |
| Pin list | `pin-assignments.csv`, `pin-assignments.md` |
| Addressing modes and extension words | `M68000PRM_split/05-section-02-addressing-capabilities.pdf` |
| Instruction semantics | `M68000PRM_split/07-section-04-integer-instructions.pdf`, `08-section-05-floating-point-instructions.pdf`, `09-section-06-supervisor-instructions.pdf` |
| Opcode encodings | `M68000PRM_split/11-section-08-instruction-format-summary.pdf` |
| Which instructions exist | `M68000PRM_split/instructions-by-cpu.csv`, the MC68040 column |
| Condition codes | `M68000PRM_split/CONDITION-CODES.md` |
| Vectors and frame formats | `M68000PRM_split/13-appendix-b-exception-processing-reference.pdf` |

`MC68040UM_split/README.md` explains how the AC table was transcribed and lists
Motorola's errata per section, and `doc/manual-contradictions.md` records the places
found here where the manuals contradict themselves — read both before "correcting" a
spec that looks wrong.

The PDFs have reconstructed outlines and are best read with
`pdftotext -layout <file> -` for a specific section.

In a comment, `UM` is `MC68040UM_split` and `PRM` is `M68000PRM_split`; specification
numbers refer to `MC68040UM_split/ac-electrical-specifications.csv`. Comments in modules
reused from RD68031 that cite the MC68030 manual say `UM30`.

## Building and checking

```sh
make lint     # elaborate every rtl module under the three always-available tools
make audit    # prove no register initialises outside reset
make sim      # directed testbenches (iverilog)
make check    # the gate: lint, audit, sim (and, as they arrive, ucode-check and timing)
```

`make help` lists every target. The oracle flows arrive with the milestones in
`doc/plan.md`; `doc/oracles.md` has the state of each.

## Tooling notes

- iverilog 12.0, Verilator 5.032, yosys 0.52, Vivado 2025.2 in `/opt/Xilinx`, and
  Quartus Prime Lite in `/opt/Altera` with Questa Altera Starter Edition. Questa's
  `vlog`/`vopt` need no licence; `vsim` does, and this machine has none, so nothing
  simulates under Questa.
- `m68k-linux-gnu-gcc` / `-as` / `-objcopy` build test programs; pass `-mcpu=68040`.
- QEMU is not installed system-wide; it is built from `Inputs/ref/qemu` into `build/`.
- No gtkwave — dump VCD and inspect with a text tool or an external viewer.
- Commits follow RD68031's style: an `Mn:` prefix, a prose subject, a body explaining
  the reasoning and the coverage.
