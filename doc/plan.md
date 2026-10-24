# RD68041 plan: an MC68040 / MC68LC040, and its cosimulation

## Context

RD68021 (MC68020) and RD68031 (MC68030) are from-scratch SystemVerilog replicas, with RD68884 (MC68881/2) beside them. RD68041 does the same for the **MC68040**, plus the **MC68LC040** (no FPU) as a build parameter. It keeps the same goals, hard rules, layout, tools and milestone process as RD68031, which is the template (`../RD68031/CLAUDE.md`, `doc/plan.md`). The sibling repos are read and copied from, never modified.

Requirements:
- bus and software compatible with the 040 and the LC040;
- instruction cycle counts broadly similar, every divergence measured in `doc/timing-divergences.md`;
- at least 20 MHz on Artix-7, preferably 25 MHz or more (xc7a100t, `make impl`).

At the start, the repo holds only `Inputs/doc/MC68030_Doc_More_Readable` (with `MC68040UM_split/`, its AC/pin CSVs and figure pages) and `Inputs/QuadraFPGA`.

**Decisions taken with the user:**
- A **new pipelined integer core**, not a fork of RD68031's microcoded sequencer. Tools, testbenches, process and the microcode assembler framework are reused.
- A **new 040 FPU** aimed at 040-like throughput. RD68884 is a test reference only.
- **Layer 4 machine: a Mac Quadra in MAME** (macquadra800/650, plus the LC040 machines such as macquadra605). The user supplies the ROMs. rd-virt (Linux) carries over as well.
- **Snooping (SC1-0, MI) is implemented.** JTAG, the multiplexed bus/DLE modes and PST3-0 are stubbed, with defined outputs.
- **The FPSP source** (`arch/m68k/fpsp040`, Linux and NetBSD) may be read as *interface documentation* for the FSAVE frame contents. It is cited in comments and listed in `doc/oracles.md`.
- **QuadraFPGA is a "bus witness".** Anyone may read it, RTL authors included, as evidence of how a real 040 behaves on the bus. No code from it goes into `rtl/`. It is the basis for a slave model in `sim/models/`. The manual stays the arbiter.

**Defaults assumed (not asked):**
- The core runs on BCLK, a single clock domain. PCLK is an input that is ignored. Every AC spec is referenced to the BCLK rising edge, and 2×BCLK internally (50 MHz) is out of reach. Per bus clock the core does about half of a real 040's work; that is the main entry in `timing-divergences.md`.
- Prefix `rd68041_`. Licence CERN-OHL-S-2.0, author and commit style as in RD68031. Source location `github.com/MelkhiorVintageComputing/RD68041`.
- The MC68EC040 and 040V (LPSTOP) are out of scope.

## 1. Repository and rules (M0)

**Copy from `../RD68031` and adapt:**
- `CLAUDE.md`, `README.md`, `LICENSE`, `.gitignore`, `Makefile` (lint/audit/sim/check/impl/paths/quartus/questa kept).
- `doc/coding-standard.md`, and empty templates for `bugs-found`, `divergences`, `timing-divergences`, `manual-contradictions`, `size-and-speed`, `implementation`, `critical-path` and `oracles`.
- `tools/{reset_audit,src_lint,paths_report,cycles}.py`.
- `tools/timing/`, retargeted to `MC68040UM_split/ac-electrical-specifications.csv`.
- `tools/ucode/`: `assemble.py` as is; `isa.py`, `program.py` and `frames.py` rewritten for the uop format and the 040 frames.
- `tools/vectors/gen.c`, `tools/cputest/`, `tools/bus_diff.py` (040 pin stream), `tools/cache_diff.py` (copyback-aware).
- `sim/tb` harness/cosim/vec/ea/cputest benches; `sim/programs` (`crt0.S`, `flat.ld`, `arith.c`, `corners.S`, `cache.S`, `cow.S`, `virt_*`).
- The `sim/virt` and `sim/mame` patterns; `scripts/`, with a single-clock xdc/sdc.

**RTL reused:** `rd68031_shifter.sv`, `rd68031_bitfield.sv`, `rd68031_divider.sv` and `rd68031_sync.sv`, renamed.

**Dropped:**
- AP68030, sun3x, NetBSD/sun3x and SunOS.
- The coprocessor interface and the `Inputs/ip/RD68884` socket.
- The 030 MMU programs and PMMU group, CAAR, the 030 SSW documents.
- `dedge_ff` and the 030 biu/seq/ifu/caches/mmu.

**Hard rules, word for word from RD68031.** Inputs are immutable, no initialisation outside reset (`make audit`), split `_i/_o/_oe` pins, portable SV for all six tools, and the host's memory limits. The oracle ban now covers WinUAE/Hatari, MAME, QEMU, and the Linux/NetBSD trees except the FPSP interface exception above. CLAUDE.md gets a documentation map for `MC68040UM_split/` (§2 IU, §3 MMU, §4 caches, §5 signals, §7 bus, §8 exceptions, §9 FPU, §10 timings, App. A LC040), and PRM with the MC68040 column of `instructions-by-cpu.csv`.

**Submodules under `Inputs/ref/`, pinned:** winuae, hatari, mame, qemu (source, built into `build/`). Under `Inputs/third_party/`: berkeley softfloat-3 and testfloat-3, as in RD68884. Software goes in `Inputs/sw/MANIFEST*`: the Linux tarball, busybox, NetBSD/mac68k sets. The Quadra ROMs are git-ignored and hash-checked, as `PROMS.sha256` is.

**M0 spikes:**
1. A UAE040 harness (`tools/cosim/uae040/`, from `uae030_glue.c` with `cpu_model`/`mmu_model`/`fpu_model` = 68040). New hooks on `cpummu.c`, the 040 data cache and `fpp.c`. The trace carries TC, URP, SRP, ITT0/1, DTT0/1, MMUSR, CACR and the FP registers.
2. A cputest corpus for `cpu=68040 fpu=68040`.
3. QEMU (`-cpu m68040`): `.trc` traces from a TCG plugin, or by stepping the gdbstub.
4. MAME macquadra800/650/605 booting the user's ROM on MAME's m68040.
5. A Linux `CONFIG_M68040` virt kernel booting under QEMU `-M virt`.

## 2. Microarchitecture

**Integer pipeline.** Six stages, single issue, in order. Every architectural write happens in W, so exceptions are precise.
- **IF:** I-ATC and I-cache read in parallel, a 6-word instruction queue, static prediction (backward taken), BRA/BSR folded.
- **DE:** the decoder ROM gives a simple control vector or a micro-sequencer entry. The micro-sequencer issues uops, each making at most one memory access. It is used for MOVEM, CAS/CAS2 under LOCK, exception entry, RTE, MOVE16, CINV/CPUSH, PTEST/PFLUSH and FMOVEM.
- **EA:** a 3-input address adder; speculative An for (An)+ and -(An); forwarding from W only (an E→EA dependency costs one bubble).
- **OF:** D-ATC and D-cache read in parallel, alignment.
- **EX:** ALU, shifter, bitfield, a 32×32 DSP48 multiplier, the iterative divider; Bcc resolved here.
- **W:** register write, commit to the store buffer, exception and interrupt check.

**Caches:**
- 4 KB I and D, each 4-way × 64 sets × 16 B, virtually indexed and physically tagged. The index is bits 9:4, which lie inside the page offset, so there is no aliasing and the ATC lookup runs in parallel with the cache read.
- Data in BRAM, 128 bits wide (4 ways). Port A serves the core; port B serves fills, pushes and snoops.
- Tags in LUTRAM with an extra read port for the snooper.
- Pseudo-random replacement; one valid bit and four dirty bits per line.
- Copyback or writethrough per page or TTR, with a one-line push buffer and a 3-entry posted store buffer. Those three entries map onto WB1–WB3 of the format $7 frame.

**MMU:**
- Two 64-entry 4-way ATCs in LUTRAM, tagged with S and G (needed by PFLUSHN), and ITT0/1 and DTT0/1 compared in parallel.
- A 3-level hardware walker with indirect descriptors and U/M updates under LOCK. It reads cached descriptors from the D-cache without allocating them (UM §3).
- PTEST and PFLUSH; no PMOVE or PLOAD.

**Bus unit:**
- `rd68041_biu`: one FSM on the BCLK rising edge, behind a clean requester interface. The requesters are I-fill, D-fill, push, store drain, walker, uncached/MOVE16 and IACK.
- It handles TS/TIP/TA/TEA/TCI/TBI, retry (TA together with TEA), line bursts with the TBI fallback, TT/TM/TLN/UPA/SIZ, LOCK/LOCKE, CIOUT, BR/BG/BB, IPL/IPEND/AVEC, and RSTI/RSTO.
- `rd68041_snoop` is a separate module: SC1-0 and MI, sourcing or sinking data through port B, and checking the push buffer.
- The caches, MMU and BIU talk only through defined ports. This avoids RD68031's BIU/dcache/ATC tangle, which is what limited its clock.

**Stubs:**
- JTAG: TDO `_oe`=0.
- CDIS/MDIS: sampled at reset; only normal mode is built, and a non-normal selection is a recorded divergence.
- PST3-0: a documented constant, with a ~20-LUT minimal encoding noted as an option.

**FPU (`FPU=1`; `FPU=0` is the LC040):**
- 8×80-bit register file, FPCR, FPSR and FPIAR.
- Stages: FC (unpack S/D/X/B/W/L; denormals, unnormals and packed trap to vector 55), FE and FW (rounding to the FPCR or FSxxx/FDxxx precision).
- FE: a 2-stage adder, a 3-stage 64×64 DSP48 multiplier, and a shared radix-4 SRT unit for divide and square root.
- Integer instructions may overlap FP ones. Arithmetic exceptions are deferred the 040 way (format $0/$3).
- Unimplemented opcodes (transcendentals, FINT/FINTRZ, FMOD, FREM, FSCALE, FGETEXP/MAN, FMOVECR) take vector 11 with format $2.
- FSAVE/FRESTORE: null, idle, unimplemented (26 words) and busy (50 words) frames, version $41, with the field contents the FPSP expects.
- With `FPU=0`, every FP opcode, FSAVE/FRESTORE included, takes vector 11 with format $4.

**Budget:** roughly 26k LUTs, ~8 RAMB36 and ~20 DSP in total; the xc7a100t has 63k LUTs.

## 3. Cosimulation layers

| Layer | Oracle | Use |
|---|---|---|
| 1 | **UAE040** (WinUAE/Hatari 040: MMU `cpummu.c`, copyback data cache, `fpp.c`) | `make ea vectors(-all) cosim cosim-mmu cache`; new vector groups `move16`, `cinv_cpush`, `pmmu040`, `fpu` |
| 1b | **cputest** 68040 + FPU | `make cputest` (no MMU coverage) |
| 1c | **QEMU** `-cpu m68040` traces | `make cosim-qemu`, a third opinion on instructions; weak on frames |
| 1d | **TestFloat/SoftFloat** | `make testfloat` on a standalone `fpu_tb` (extF80 with rounding precision) |
| 2 | slave models from UM §7 + the QuadraFPGA witness; random alternate-master snoop bench with an architectural memory checker | `bus_*_tb`, `snoop_tb` (replaces AP68030, as no second 040 RTL exists) |
| 3 | **rd-virt**: bootinfo CPU/MMU/FPU_68040 (FPU 0 for the LC040), new pin agent, lockstep against UAE040 | `make virt-bare virt-linux(-solo)`; QEMU `virt` validates kernels |
| 4 | **MAME Quadra**: `rd68041_device` against MAME's m68040 | serial console byte for byte (NetBSD/mac68k, Linux/mac); framebuffer hashes for Mac OS; `quadra` and `quadra-lc` |

The FPSP (`make fpsp`) runs on the core in rd-virt as Linux's own FPSP, and on bare metal.

## 4. Milestones

| M | Content | Gate |
|---|---|---|
| M0 | Scaffolding, CLAUDE.md, `doc/pinout.md` from `pin-assignments.csv`, submodules, the five spikes | `make check` on the scaffold; spikes in `doc/oracles.md` |
| M1 | BIU and requester interface, `rd68041_slave.sv` (waits, TBI, TCI, TEA, retry, bursts), bus monitor | `bus_*_tb` |
| M2 | Arbitration, RSTI/RSTO, CDIS/MDIS sampling, IPL/AVEC; the snoop protocol against stub tags (Figs 11-5, 11-6) | `bus_arb_tb`, `bus_snoop_tb` |
| M3 | AC feasibility at 25/33/40 MHz (LC040: 20–40) | `make timing` |
| **M4** | **Frequency spike:** register file, EA adder, BRAM caches, ATC, BIU and a dummy EX, placed and routed | `make impl` ≥ 28 MHz with margin; else split OF and re-plan |
| M5 | Checkpoint freeze: frames $0/$1/$2/$3/$4/$7, the SSW, FSAVE layouts, the uop format, the CM/MA restart policy | `doc/checkpoint.md`, `doc/ssw.md`, `make ucode-check` |
| M6 | Walking skeleton: six stages, uncached, MOVE/ADD/Bcc | it runs; small cosim |
| M7 | Full integer ISA (the 040 column) | `make ea vectors-all cputest cosim`, `cosim-qemu` |
| M8 | Exceptions, interrupts, trace, STOP, double fault, RTE format checks | `core_exc_tb`, `core_fault_tb` |
| M9 | Caches: copyback, store and push buffers, CINV/CPUSH/MOVE16, snoop integrated | `core_cache_tb`, `make cache`, `snoop_tb` |
| M10 | MMU: ATCs, walker, PTEST/PFLUSH, $7 faults with write-backs | `core_mmu_tb`, `make cosim-mmu` |
| M11 | FPU datapath standalone, then integrated: frames, deferred exceptions, FSAVE/FRESTORE | `make testfloat`, cputest with FPU, `core_fpu_tb`, FP cosim programs (see the note below) |
| M12 | The LC040 build | `make check FPU=0`, format $4 vectors (`make vectors OP=lc040 FPU=0`), `make cosim-lc`, `core_lc040_tb` |
| M13 | rd-virt lockstep: bare metal, then Linux (FPU=1, and FPU=0 with emulation) | `make virt-bare virt-linux`, `make fpsp`; each also with `FPU=0` (but `fpsp`) and with `VIRT_CACHES=off` |
| M14 | MAME Quadra: PROM/ROM to the Finder or console; then NetBSD/mac68k and Linux | `make quadra`, `quadra-lc` (phase A, the ROM to the desktop with the stand-in ADB firmware: done; phase B waits for the user's ADB firmware and OS media) |
| M15 | Performance and FPGA (Vivado and Quartus), `make cycles` against UM §10 | `doc/implementation.md` |

**M11's gate, as changed at M11.** `vectors OP=fpu` is replaced by the cputest FPU corpus:
both are generated by the same WinUAE FPU code, and the corpus covers every FP instruction
in every mode with millions of operands, which a vector group would only repeat; what
neither oracle can judge (the FSAVE frames, FRESTORE) is `core_fpu_tb`'s. `make fpsp`
moves to M13: running the FPSP bare means building it with glue of our own, which would
mean reading its kernel interface (`skeleton.S`), and the FPSP may be read for the frame
contract only (`CLAUDE.md`). Linux builds it into the kernel itself, so rd-virt runs it
on the core with nothing read.

Each milestone gets an `Mn:` commit in RD68031's style. Every defect goes into `doc/bugs-found.md`, and every oracle disagreement into `doc/divergences.md`.

## 5. Risks

1. **Frequency.** The likely limiting paths are decoder → EA adder → BRAM address, and ATC → tag compare → way mux → aligner. M4 measures them before any ISA work.
2. **Copyback, snoop, walker and store-buffer interactions:**
   - a snoop hitting the push buffer;
   - a snoop at the same moment as a port A store;
   - the walker reading through the D-cache;
   - a store-buffer entry matching a line being filled;
   - CPUSH against a snoop.

   The random alternate-master bench runs from M2 (stubbed) onward.
3. The FSAVE internals, and the $7 frame's CM/MA cases and misaligned accesses across a page.
4. Oracle fidelity: UAE's 040 MMU and cache are unproven, cputest has no MMU coverage, QEMU has no frame fidelity. All of this is recorded in `doc/oracles.md`.
5. Mac ROM sensitivities: the FSAVE version and size, MOVE16, CPUSHA, LC040 detection.
6. Host memory: the Verilator builds are larger; heavy jobs run one at a time, at most -j4.

## 6. Verification

- `make check` = `ucode-check`, `lint`, `audit`, `sim`, `timing`, with `FPU=1` and `FPU=0`.
- Oracle targets (minutes each, not in check): `ea vectors-all cputest cosim cosim-mmu cosim-qemu cache testfloat fpsp snoop virt-* quadra*`.
- Acceptance:
  - Linux in rd-virt lockstep with zero divergence (caches on and off, FPU=1 and 0);
  - the Quadra console identical to MAME's m68040;
  - `make impl` ≥ 25 MHz.

## Critical files to read and reuse (copied, never modified)
- `../RD68031/{CLAUDE.md,Makefile,doc/plan.md,doc/coding-standard.md,doc/oracles.md}`
- `../RD68031/tools/ucode/{assemble,isa,program,frames}.py`, `tools/timing/`, `tools/cosim/uae030/{uae030_glue.c,build.sh}`, `tools/vectors/gen.c`, `tools/cputest/`
- `../RD68031/sim/{tb,models,programs,virt,mame}/`, `rtl/rd68031_{shifter,bitfield,divider,sync}.sv`
- `../RD68884/` TestFloat flows (`third_party/`, `tools/model/`, `check_testfloat.py`)
- `Inputs/QuadraFPGA/quadra-to-ztex-gateware/mc68040_fsm.py` (bus witness)
- `MC68040UM_split/` §5, §7, §8, §9, App. A, `ac-electrical-specifications.csv`, `pin-assignments.csv`
