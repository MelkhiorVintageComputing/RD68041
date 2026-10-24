# rd-virt: the deterministic `virt` machine, and the lockstep

M13's platform (doc/plan.md, Layer 3), RD68031's rd-virt for the MC68040 and the
MC68LC040. A C++ machine that mirrors the Linux and QEMU m68k `virt` board, with a CPU
socket that takes either the RTL (under Verilator) or the UAE040 oracle, and a lockstep
driver that runs both, each on its own copy of the machine, and compares them at every
instruction boundary. Nothing here is an oracle; it is the bench the RTL and the oracle
run Linux on.

| File | What |
|---|---|
| `sim/virt/machine.{h,cpp}` | RAM, the devices, the bootinfo, the ELF loader, the clock, the bus record (RD68031's; the bootinfo says 68040) |
| `sim/virt/cpu_if.h` | the socket: `reset`, `run_until_retire`, `set_ipl`, `regs()`, `retired()`, `last_iack`, `last_vector`, `inject_interrupt`, and the step's operand writes |
| `sim/virt/cpu_rtl.{h,cpp}` | `rd68041_top` under Verilator and the pin-level bus agent |
| `sim/virt/public.vlt` | the `public_flat_rd` signals the RTL socket reads: the registers, where a boundary is, the data unit's write port |
| `sim/virt/cpu_uae.{h,cpp}` | the UAE040 core (`tools/cosim/uae040`) as a coroutine behind the socket |
| `sim/virt/rdvirt.cpp` | the solo runs, the lockstep, the console script, the options |
| `sim/virt/build.sh` | `uae`: the oracle-only machine; `rtl`: the Verilator build with both (`FPU=0`: the MC68LC040) |
| `sim/virt/linux/` | the guests: `rd-virt.config` (the MC68040: the M68040FPSP), `rd-virt-lc.config` (the MC68LC040: the FPU emulation), `init`, `cpio.list`, `build.sh`, and the command sets `commands.script`, `commands-lc.script`, `commands-fpsp.script` |
| `sim/programs/virt_*.S`, `virt.inc`, `virt.ld` | the bare-metal programs |

The parts linked with UAE040 (`cpu_uae.*`, `rdvirt.cpp`) are GPL-2.0-or-later, like
everything else that links it (doc/oracles.md); the machine and the RTL socket are
CERN-OHL-S-2.0.

## The machine

RD68031's, unchanged but for the bootinfo. The map is the one doc/oracles.md recorded
at M0, from `arch/m68k/virt/` and QEMU's `hw/m68k/virt.c`:

| Address | Device | Linux IRQ (PIC, input) |
|---|---|---|
| `$00000000` | RAM, 64 MB by default (`--ram`) | |
| `$FF000000` + i·`$1000` | goldfish-pic i+1 of 6, driving level i+1, autovectored | |
| `$FF006000` | goldfish-rtc, the scheduler's timer | 168 (6, 0) |
| `$FF007000` | goldfish-rtc, the wall clock | 169 (6, 1) |
| `$FF008000` | goldfish-tty, version 1 (physical DMA pointers) | 39 (1, 31) |
| `$FF009000` | virt-ctrl: CMD 1 reset, 2 halt (power off), 3 panic | 8 (1, 0) |
| `$FF010000` + n·`$200` | 128 virtio-mmio transports, legacy, every one empty (device ID 0) | 40 + n |

Everything else is a hole and answers with a bus error. The MC68040 has no CIIN: what
must not be cached says so through the MMU, and Linux's head.S maps the devices with a
transparent translation register, noncachable serialised (`$FF00A040` in ITT1 and
DTT1).

**Loading.** The kernel's ELF goes in physical = virtual; the reset vectors at 0 give
the entry and a harmless SSP; the bootinfo goes at `(_end + 1) & ~1` with `MACHTYPE` 14,
`CPUTYPE` and `MMUTYPE` 68040 (4), **`FPUTYPE` 68040 (4), or 0 with `--no-fpu`** (the
MC68LC040; RD68031 found that the record must be there either way), `MEMCHUNK`, the
`VIRT_*` records, the command line, a fixed `RNG_SEED`, and `RAMDISK` with the initrd
page-aligned at the top of RAM.

**Time.** The machine is told the time at every boundary: steps × `--ns` (20 ns, so
50 M steps per virtual second) plus whatever was skipped while STOP held the processor,
when the clock jumps to the next armed alarm. Nothing reads the host's clock, so a run
is the same from one execution to the next, and the two sides of a lockstep see the same
time at the same instruction.

## The RTL socket

`rd68041_top` (`FPU=1`, or `FPU=0` for the MC68LC040: its own build directory,
`build/virt/lc`) under Verilator, single-threaded. A **boundary** is the cosim bench's:
`retire`, true in the clock before the edge that writes the instruction's results, with
its next PC `retire_npc`; the registers are read after that edge. The core folds two
boundaries into the next one, which the processor's model and the oracle have, so the
socket makes them itself:

- the end of an instruction an interrupt is then taken after (`w_end && w_int`): the
  core counts the interrupt's processing as that instruction's boundary;
- STOP's: the core has none until the interrupt that ends it.

The reset exception's end -- the clock the core has its PC and starts fetching -- is
step 0.

**The bus agent** is `sim/models/rd68041_slave.sv` in C++ (UM 7.4-7.6): TS seen on a
rising edge, TA (or TEA, TBI) driven from just after one edge to just after the next,
`--ram-waits` (0) or `--io-waits` (1) clocks after TS at the earliest; a line is four
long words in A3-A2 order from the one addressed, wrapping (UM 7.4.2), or with `--tbi`
the first answered with TBI and the processor goes on with three long-word transfers.
A device line (which only a cachable mapping of them would ask for) is answered with TBI
and TCI; a device register is read once per transfer. An interrupt acknowledge (TT 11,
A = `$FFFFFFFF`, the level in TM) is answered with AVEC; a breakpoint acknowledge and
every hole with TEA. `--tci` answers every line read with TCI, so that no line is ever
allocated (UM 7.4.2) and both caches stay empty: the caches off, as far as a bus can turn
them off -- CDIS does not on this core (`doc/divergences.md`). Every transfer goes into
the bus record (the last 4,096).

**The writes** the lockstep compares are taken where write-back hands them to the data
unit (`rd68041_dmu`'s `st_ready`): the logical address, the size and the data -- for
MOVE16, the line from its buffer. A store the queue takes belongs to the step it is
taken in: the instruction that made it completes in that same step.

## The UAE040 socket

The core of `tools/cosim/uae040`, configured as the part (MMU, both caches with
copyback, the FPU or `-L`'s none; `--no-dcache` turns its data cache off), as RD68031's
UAE030 socket: the library enters the core once and only comes back through the
instruction hook, so the core runs on its own stack as a coroutine. The library gained,
for M13 (`tools/cosim/uae040/uae040.h`): devices behind the RAM (`uae040_set_ext_bus`),
taking an interrupt at the hook's boundary (`uae040_interrupt`), STOP's state, the last
operation word, a write through the core's own path (`uae040_poke`), and the integer
registers set without touching the caches (`uae040_set_regs`; `uae040_set_state`
invalidates them, which would lose a copyback line). The writes are its operand hook's:
every operand write an instruction or exception processing makes, cache hit or not.

STOP: the oracle keeps its program counter on the STOP and executes it again at every
boundary until an interrupt moves it on; the socket reports the processor's boundary
(after the STOP) once and hides the repeats.

## The lockstep

The RTL leads. After each of its steps:

1. if the RTL acknowledged an interrupt (level L) during the step, the oracle is told to
   take it at the boundary it is at;
2. the oracle takes the same step;
3. the frame alignments below, when both took an access error;
4. every register is compared: D0-D7, A0-A7, USP, ISP, MSP, SR, PC, VBR, SFC, DFC, CACR,
   TC, URP, SRP, ITT0/1, DTT0/1 (under the bits UM 3.1 gives each), MMUSR, and with the
   FPU FP0-FP7, FPCR, FPSR, FPIAR;
5. the two steps' operand writes are cut into bytes, each byte's last value taken, and
   the two maps compared: every byte either wrote must have been written by the other,
   with the same value -- but for the internal part of a frame the step stacked: an
   access error frame (`$7`, UM 8.4.6) beyond its format and vector word (and its
   effective address too, unless a continuation bit says it holds one, UM 8.4.6.1), and
   an FSAVE frame beyond its first long word (UM 9.8). Whatever a handler then reads
   from them is compared in what it does;
6. both machines are told the new time; the console script may type.

This is not RD68031's comparison of the bus's writes: with copyback caches the bus says
when a line was pushed, which is each implementation's replacement's business (UM
4.4.4), not what the program wrote. What a copyback cache does wrong shows as a read that
returns the wrong value, which the registers catch.

At the first boundary the oracle takes the RTL's values of what a reset leaves
undefined (USP, MSP, SFC, DFC, the MMU's registers but TC, and FP0-FP7: NaN on the core,
UM 9.2.1, zero in the oracle).

**On a divergence** the run stops (`--maxdiv N` goes on after N-1), and the dump
(`--dump`; `make virt-linux` writes `lockstep-on.div`, or `-off` with
`VIRT_CACHES=off`: `--tci --no-dcache`) holds both states,
both steps' writes and the last 4,096 transfers of each bus. `--dump-at N` writes the
same at step N and stops; `--trace-from N` prints every boundary from step N;
`RDVIRT_WATCH=<hex address>` prints every bus write either side makes to that byte, and
`RDVIRT_FTRACE=1` every F-line operation word the oracle runs. A model built with
`TRACE=1 sim/virt/build.sh rtl DIR` takes `--vcd F --vcd-from N`.

**Accepted differences** (doc/m13-mismatches.md has each, with its decision):

| | Default | What |
|---|---|---|
| m13-c1: a write's access fault | on (`--strict-wfault`) | the core takes it before the write and restarts the instruction; the oracle, as the part, completes the instruction and leaves the write in WB3 for the handler (`doc/divergences.md`). When both take the fault, the oracle's frame on the stack is replaced by the core's through the oracle's own write path, and its address registers (those within 16 of the core's) and condition codes by the core's; the oracle's RTE then runs the instruction again as the core's does |
| m13-c2: an instruction fetch fault's SIZE and FA | on (`--strict-fsize`) | the oracle stacks SIZE word and the instruction word's address; the core long and the long word's, the access the MC68040 makes (`doc/oracles.md`, M10). When the two frames differ in those alone, the oracle's gets the core's |
| m13-c6: the FPSR at an unimplemented FP instruction's trap | on (`--strict-fpsr`) | the core leaves the condition codes and EXC as the instruction before left them, the oracle clears them; the FPSP clears both first thing. When both take vector 11 with a format $2 frame and the FPSRs differ there alone, the oracle gets the core's |

## Options

`rdvirt --help` lists them. The ones a run usually wants:

| | |
|---|---|
| `--cpu uae\|rtl\|lockstep` | which processor, or both |
| `--kernel F --initrd F --cmdline S` / `--bare ELF` | what to run |
| `--no-fpu` | the MC68LC040: the bootinfo says no FPU, the oracle is `-L`'s (the RTL must be an `FPU=0` build) |
| `--script F`, `--expect S` | the console script (`expect <text>` / `send <text>`), and what the console must show for a pass |
| `--ram-waits N`, `--io-waits N`, `--tbi`, `--tci` | the RTL's bus and caches |
| `--no-dcache` | the oracle without its data cache |
| `--max-steps N`, `--progress N` | limits and reporting |

A run passes when the machine powered off through virt-ctrl (not a panic), the console
showed every `--expect` string and the script finished -- and, in lockstep, there was no
divergence and the two consoles are the same.

## The guests

`sim/virt/linux/build.sh` fetches the sources `Inputs/sw/MANIFEST` pins, checks their
sha256, builds the kernel with `rd-virt.config` (or, with `CONFIG=rd-virt-lc.config`,
the MC68LC040's) over `allnoconfig`, a static BusyBox for the 68040, and the initramfs
with every timestamp at 0. `/init` prints the machine's view of itself; with
`rdvirt.shell` on the command line it then starts a shell on the console, which a
command set drives:

- `commands.script` (the MC68040): arithmetic, `uname`, `/proc/cpuinfo`, floating point
  in awk -- sin, exp, log, which the MC68040 leaves to the M68040FPSP the kernel links
  in --, an `md5sum` of `seq 1 200`, a file written and read back, the RTC, a pipeline,
  `poweroff -f`;
- `commands-lc.script` (the MC68LC040): the same with the transcendental functions left
  out -- the kernel's FPU emulation has none, as RD68031 found -- and a line of the
  arithmetic it does have;
- `commands-fpsp.script` (`make fpsp`): sin, cos, atan2, exp, log, int, a remainder and
  sqrt, printed to ten decimals against the host's libm.

The kernel is booted with `lpj=250000` (50 BogoMIPS at 20 ns a step), so that it does
not calibrate its delay loop.

## The bare-metal programs

`virt.inc`'s macros and `virt.ld`'s map are RD68031's: vectors at 0, code from `$1000`,
the supervisor stack at `$F000`, the programs' tables from `$10000`; a program prints
through the tty and ends by writing virt-ctrl (2: done, 3: failed).

| Program | What |
|---|---|
| `virt_hello` | the tty, virt-ctrl's features, a byte read of a long-word register, the PIC, a bus error from the hole (an access error frame, `$7`), the clock moving |
| `virt_timer` | ten alarms of the scheduler's RTC at level 6: five out of STOP, five while spinning, then one held pending by the mask until it comes down |
| `virt_mmu` | three-level tables, 4 KB pages, copyback caches, the devices through DTT0; a checksum over 64 KB, a write through an alias read back through the identity mapping, PTEST, a read and a write to invalid pages and a write to a write-protected one, each repaired and resumed (a write-back the part leaves is completed by the handler), CPUSHA and the data read uncached through DTT1 |

`make virt-bare` runs each in lockstep three times: with the default bus, with
`--tbi --ram-waits 1`, and with the caches off (`--tci --no-dcache`).
