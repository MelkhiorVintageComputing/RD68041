# The oracles, and what each is trusted for

RD68031 checked itself against UAE030 (WinUAE's MC68030 core), WinUAE's cputest corpus,
and, for the bus, AP68030. RD68041 follows the same process with the MC68040's
counterparts, chosen in `doc/plan.md` §3:

| Layer | Oracle | Trusted for | State |
|---|---|---|---|
| 1 | **UAE040**, the WinUAE MC68040 core (Hatari's copy) | instructions, the programmer's model at every boundary, the MMU's table searches and faults, the data cache's copyback behaviour, the FPU's results and its unimplemented-instruction traps | M0 spike 1: **go, with caveats** (below) |
| 1b | **cputest**, WinUAE's tester, `cpu=68040`, integer and `fpu=68040` | bulk single-instruction vectors, integer and FPU, checked against real processors by its author | M0 spike 2: **go, with caveats** (below) |
| 1c | QEMU `-cpu m68040` | a third opinion on integer instructions; weak on frames, no caches, MMU and FPU only roughly | M0 spike 3: **go, with caveats** (below) |
| 1d | Berkeley TestFloat/SoftFloat | the FPU datapath's rounding | from M11 |
| 3 | Linux 7.2.9 (`CONFIG_M68040`) on QEMU's `virt` | validates the guest kernels rd-virt will run | M0 spike 5: **go** (below) |
| 3 | **rd-virt**: Linux and bare programs, the RTL in lockstep with UAE040 (`doc/virt.md`) | the whole processor over a real kernel's boot and user space: the MMU's faults, the caches, interrupts, STOP, the FPSP | M13: **pass**, 0 divergences (below; `doc/m13-mismatches.md`) |
| 4b | **rd-qvirt**: QEMU 11.1.2's `virt` with the core as its processor, against QEMU's own m68040 on the same machine (`doc/qvirt.md`) | Linux and NetBSD/virt68k, console byte for byte; QEMU's devices, DMA included, as a snooping bus master | M14: **pass** (below) |
| 4 | MAME's m68040 in a Macintosh Quadra | whole-system behaviour | M0 spike 4: **go, with caveats**; M14: the core boots System 7.6.1 from the user's disk to the Finder, pixel for pixel MAME's own m68040's screen, as the MC68040 and the MC68LC040 (below) |

This file records:
- what each oracle is and how it is configured;
- what M0's spikes found when it was first run here;
- what each is *not* authoritative for, and every place it was seen to disagree with the
  manual, with the evidence.

When an oracle and the core disagree, the manual decides and the case goes into
`doc/divergences.md` (CLAUDE.md).

Rules that apply to every oracle:
- Every oracle sits under `Inputs/ref/` and is never modified.
- Each is copied into `build/` to be built, and patched only in the copy.
- None is ever read to write `rtl/`. The harnesses (`tools/cosim/`, `tools/cputest/`) are
  written against each oracle's interface, and are GPL-2.0-or-later where they link it.

One more document is read as an interface, not as an oracle: the M68040FPSP
(`arch/m68k/fpsp040/` in Linux, its NetBSD counterpart), for the contents of the FSAVE
frames it consumes (CLAUDE.md).

---

## UAE040: the WinUAE MC68040 core (instructions, MMU, caches, FPU) -- M0 spike

**What.** Toni Wilen's MC68040 core: the 68040 MMU (`cpummu.c`), the 68040 data and
instruction caches with copyback, and the FPU (`fpp.c` over softfloat). It is taken from
Hatari's copy, `Inputs/ref/hatari/src/cpu` (Hatari b166d8c), which builds on Linux with far
less of an emulator around it than WinUAE's own tree (WinUAE 858c5f3). It is GPL code, so
everything that links it is GPL-2.0-or-later; whatever only reads its output (the checker,
the testbenches to come) stays CERN-OHL-S-2.0.

**Hatari's copy against WinUAE's.** At these two commits `cpummu.c`, `cpummu.h`,
`fpp.c`, `newcpu_common.c` and the 68040 parts of `newcpu.c` and `gencpu.c` differ only in
build glue (include files, logging, savestates; one array initialised in `fpp.c`). Nothing
WinUAE has for the 68040 is missing from Hatari's copy. Hatari's own debugger does not
translate addresses for an 040 (a TODO in its `newcpu.c`); the harness does not use it.

### The harness (`tools/cosim/uae040/`)

| File | What |
|---|---|
| `build.sh` | copies the core into `build/uae040/`, patches the copy, generates the opcode tables and archives core and glue as `libuae040.a`. Incremental. About 40 s at `-j4` from clean; the generated `cpuemu_*.c` at `-O0`, `cpuemu_31.c` (the 68040 MMU core actually used) at `-O1` |
| `uae040.h` | the library's interface |
| `uae040_glue.c` | stands in for Hatari's memory, chipset and event code; the hooks; state get/set; the image loaders |
| `uae040_trace.c` | the tracer: a `.trc` of every boundary, and optionally the bus (`-B`) and operand (`-O`) streams |
| `tests/smoke040.S`, `tests/smoke040_check.py` | the M0 smoke program and its checker (`make uae040-smoke`) |

`make uae040` builds the library and `uae040_trace`; `make uae040-smoke` runs the smoke
program as an MC68040 and as an MC68LC040 and checks both.

**Configured as** (`uae040_init`): `cpu_model` 68040, `mmu_model` 68040 (not `mmu_ec`),
`fpu_model` 68040, or 0 for the MC68LC040 (`-L`); `cpu_compatible` (that selects the
68040 MMU core, `op_smalltbl_31`, with the instruction cache and the prefetch buffer);
`cpu_data_cache`, the 68040 data cache with copyback (off with `-D`); not cycle exact;
32-bit addressing; `fpu_no_unimplemented`, so that the instructions and data types the
MC68040 does not implement trap as on the part (vector 11 format $2, vector 55) instead of
being emulated; `fpu_mode` 1 (softfloat, 80-bit extended).

**Patches to the build copy** (in `build.sh`, each checked after it is applied). None
changes what the core computes:
- `MMU_IPAGECACHE` and `MMU_DPAGECACHE` are off: they are host-side shortcuts in front of
  the emulated ATC, so with them on the ATC's behaviour could not be trusted. (`MMU_ICACHE`,
  the third, is off already.)
- Bookkeeping that labels each physical access -- its function code, and whether it is a
  table search access (and for which kind of access, and whether PTEST started it), a
  data-cache push, a line fill, a MOVE16 transfer, MOVES, or inside a locked
  read-modify-write -- and that brackets each operand access with calls into the glue, with
  its logical address.
- The per-instruction hook, at the top of the 68040 MMU run loop.
- As in RD68031: the run loop's saved flags made `volatile` (a non-volatile local assigned
  after a `setjmp` is indeterminate after the `longjmp`, C11 7.13.2.1).
- Not a patch, a link option: the core's routines that move an operand in pieces (it
  crosses a page; MOVES; the locked read-modify-write) are wrapped (`-Wl,--wrap`, `O40WRAP`
  in the Makefile) so that the glue reports each as the one operand it is.

**Interface** (`uae040.h`), RD68031's `uae030.h` with the 040's state:
- `uae040_init(ram, dcache, fpu)`, `uae040_set_alias`, `uae040_add_region` (more memories
  or a bus-error window in front of the RAM), `uae040_load` (raw binary),
  `uae040_load_srec` (Motorola S-records).
- The instruction hook gets the whole state at every boundary: PC, D0-D7, A0-A7, USP, ISP,
  MSP, SR, VBR, SFC, DFC, CACR, TC, URP, SRP, ITT0, ITT1, DTT0, DTT1, MMUSR, FP0-FP7 (80
  bits: the sign/exponent word and the 64-bit mantissa), FPCR, FPSR, FPIAR, and the cache
  hit counts.
- The bus hook gets every physical access: address, size, R/W, data, its kind (operand,
  table search, instruction fetch, push, line fill, MOVE16), the function code, TT1-TT0 and
  TM2-TM0 as UM tables 5-2 to 5-4 give them for that kind, LOCK, and a bus error. TT and TM
  are derived by the harness from the kind and the function code: the oracle has no such
  notion. Cache hits do not appear.
- The operand hook gets every operand access, *whether or not it reached the bus*: logical
  and physical address, size, value, function code, bus error. A data-cache hit is still an
  operand; with copyback it is the only record of the access. Exception frames, the vector
  fetch and RTE's reads are operands.
- The exception hook gets the vector number when exception processing starts.
- `uae040_set_state`, `uae040_set_mmu` (installs the MMU registers as MOVEC would and
  flushes the ATCs), `uae040_set_fpu`, `uae040_run_each` (one instruction per test, as
  RD68031's vector generator uses), `uae040_run`.

**The trace format** (`uae040_trace`, the comment at the top of `uae040_trace.c` is the
reference): RD68031's positional hex `.trc` -- a header `nstep nfield`, then per
instruction the PC and `nfield` values -- with `nfield` = 58: D0-D7, A0-A6, USP, ISP, MSP,
SR, VBR, CACR, SFC, DFC, TC, URP, SRP, ITT0, ITT1, DTT0, DTT1, MMUSR, FPCR, FPSR, FPIAR,
then FP0-FP7 as three values each (the sign/exponent word, the high and the low mantissa
long word: FMOVEM.X's memory image without its zero word). It is RD68031's list without
the registers an MC68040 does not have (CAAR, the 64-bit CRP; TT0/TT1 become the four
TTRs), with the 040's MMU and FPU registers after the integer ones. Registers are only
ever appended, and a reader takes `nfield` from the header.

The bus stream (`-B`) is RD68031's, with the 040's kinds: D (an operand that reached the
bus), T (a table search access for data or PTEST), F (one for an instruction fetch), P (a
push), C (one long word of a line fill), M (one long word of a MOVE16), each with TT, TM,
CACR.DE, LOCK and bus error. Instruction fetches are left out, as in RD68031. The operand
stream (`-O`) is new: `O R|W la pa size data fc [B]`. Both carry `I n pc` at each boundary
and `E vector` at each exception.

### The M0 spike

`make uae040-smoke`: `tools/cosim/uae040/tests/smoke040.S` (`-mcpu=68040`, linked at 0)
run from reset, 130 instructions as an MC68040 and 213 as an MC68LC040, checked by
`smoke040_check.py` at each `L_*` landmark against the value or the access the manual
fixes (59 checks and 48, all passing). It found, against the UM:

- **Integer and MOVEC.** CACR written with $FFFFFFFF reads back $80008000 (DE, IE: UM
  4.2); a TTR $FFFFE364 (bits 12-10, 7, 4, 3, 1, 0 read as zero, UM 3.1.3); TC $4000 for
  $7FFF (bits 13-0 read as zero, UM 3.1.2); MSP, ISP, SFC, DFC, VBR, URP and SRP as
  written.
- **The MMU on, 4K pages, a three-level table** (UM 3.2.1): LA $20000 translates through
  the root, pointer and page descriptors (reads at URP+0, the pointer table + 0, the page
  table + $80) to PA $30000; U is written into each descriptor on first use; a second
  access hits the ATC and makes no search.
- **A page fault** (an invalid page descriptor, LA $21000): vector 2, a 30-word format $7
  frame; SSW $0505 (ATC, RW, size long, TT 0, TM 5: UM 8.4.6.2); FA = $21000, the logical
  address (8.4.6.4); EA 0 (no continuation bit, 8.4.6.1); the stacked PC is the faulted
  instruction's (UM 8.2.1). The handler maps the page, PFLUSHes it and RTEs; the read is
  restarted and returns the new page's data (8.4.6.7). The table search for the
  supervisor stack page sets M when the frame is written.
- **PTEST** (UM 3.1.4): MMUSR $00030001 for the mapped page, 0 for an invalid one,
  $00030011 after PTESTW (M set, and written back to the descriptor); $00000003 (T, R) for
  an address under a DTTR. The entry PTESTW leaves is used by the next access (no search);
  after PFLUSH (An) the page is searched again.
- **A DTTR** over $00xxxxxx: accesses are not translated (LA $20000 reads PA $20000).
- **The data cache, copyback** (a page with CM = 01, CACR = DE|IE): a write miss allocates
  the line (four line-fill reads) and makes no bus write; the read after it hits; CPUSHA
  writes the dirty data back (TT 0, TM 0) and invalidates; CINVA drops a dirty line without
  a push, so the data written is lost and the next read returns memory's; on a
  write-through page (CM = 00) the write reaches the bus and allocates nothing (UM 4.3, 4.5).
- **MOVE16** (Ax)+,(Ay)+: four long words read and four written, TT 1, TM 5 (UM tables
  5-2, 5-3); Ax and Ay advance by 16.
- **FPU**: FADD/FMUL/FDIV/FSQRT in double give 3.75, 7.5, 2.5, 2.5 exactly; FPIAR is the
  last FP instruction's address; FMOVEM.X out and back is exact (12 long words written);
  FSAVE after them is an idle frame, $41000000 (version $41, size $00: UM 9.7).
- **An unimplemented FP instruction** (FSIN, UM table 9-10): vector 11, format $2, the
  stacked PC is the next instruction's, the address field 0 for a register source (UM
  9.6.1); FSAVE in the handler gives the 52-byte unimplemented-instruction frame, $4130xxxx.
- **The MC68LC040** (`-L`): every FP instruction -- the arithmetic, FMOVE, FMOVEM, FSAVE,
  FRESTORE, FSIN; 16 in the program -- takes vector 11 with an eight-word format $4 frame:
  the next instruction's PC at +$02, the effective address at +$08 (0 for an immediate
  source), the faulted instruction's PC at +$0C (UM A.5.1). FPCR, FPSR, FPIAR and FP0-FP7
  read as zero in the trace.

**Quirks: where UAE040 and the manual disagree.** Each is confirmed on every
`make uae040-smoke` (its `quirk:` lines), so a change in the oracle is noticed.

| Quirk | Manual | Evidence |
|---|---|---|
| A root or pointer descriptor's U write comes immediately after its read, before the next level's read | UM figure 3-10, note: "a pointer descriptor write access to update the U-bit occurs after the read of the next level descriptor" | `make uae040-smoke`, `build/uae040/smoke/040.bus`, boundary 40: `R 10000`, `W 10000`, `R 10200`, ... |
| Descriptor U/M updates are a plain read and a plain write, not a locked read-modify-write cycle | UM figure 3-10: "execute locked RMW access" for a page descriptor whose U (or M) is to be set | the same accesses carry no LOCK (the harness reports LOCK only inside TAS, CAS, CAS2) |
| The exception vector is read before the frame is written | UM 8.1: the third step builds the frame, the last fetches the vector | `040.ops`, boundary 42: `O R 8` then the frame's writes; likewise for vector 11 (`R 2c`) and in the LC040 run. RD68031 found the same in UAE030 |
| A data-cache push writes only the dirty long words of the line, as long-word writes | UM 4.5, 7.4.1: a push is a line write (the four long words, SIZ = line) | `040.bus`, boundary 79: a single `W 22000 4 cafef00d .. P` |
| A line fill is four long-word reads | UM 7.4.1: one line read (burst) | `C` accesses come in fours; granularity, not behaviour -- a bus stream compare has to rejoin them |
| FRESTORE of a 52-byte (unimplemented instruction) frame reads only its first long word | UM 9.7: FRESTORE reads the frame it restores | `040.ops`, boundary 124: one `O R 7fc0`; SP still advances by 52 |
| FSAVE's idle frame writes its undefined low word as $0000 | UM 9.7, figure 9-10: bits 15-0 of an idle frame are undefined | `040.bus`: `W 7ffc 4 41000000` -- a mask, not a disagreement |

**Not authoritative for, or not modelled:**
- **Bus cycles.** The bus stream is a stream of accesses, not cycles: no bursts (lines are
  four long words), no retry, no snooping, no TLN, no UPA, no CIOUT; TT and TM are the
  harness's derivation, LOCK is only what TAS/CAS/CAS2 bracket, and LOCKE is not there.
  Layer 2 (the slave models and the QuadraFPGA witness) is for cycles.
- **The order of a table search's accesses** and the locking of descriptor updates (above).
- **The order of exception processing's accesses** (above), and the order of a frame's
  writes, which the manual does not fix.
- **Pushes and fills as the bus sees them** (above): what is pushed, and that a push
  happens, can be trusted; its granularity cannot.
- **Write-backs in the format $7 frame.** The spike's fault was a read, where the two
  agree. On a write's ATC fault the oracle stacks the write in WB3 (M10, below), where the
  core takes the fault before the write; faults on a push and on MOVE16 are M10's second
  part.
- **FSAVE frames' contents** beyond the format word, and FRESTORE of anything but an idle
  or null frame (above). The FPSP is the reference for those fields (CLAUDE.md).
- **The effective address field** of the format $4 frame for `-(An)`: for FMOVEM.X and
  FSAVE to `-(SP)` the oracle stacks An before the decrement ($8000); UM A.5.1 says "the
  calculated effective address" without saying which for a predecrement. An open question
  for M12.
- **Clock counts** (`cpu_cycle_exact` is not used).
- **Interrupts** were not wired until M13: rd-virt takes them through
  `uae040_interrupt`, at the boundary the RTL took them at (below).
- **The data cache when the MMU is off.** UM 3.1.2 gives such accesses the default
  attributes cachable, write-through; the spike did not test copyback through a TTR with
  TC.E clear.

**Found on the way:**
- UM 8.4.6's frame table says the format $7 frame's stacked PC points to the "next
  instruction"; UM 8.2.1 says it is "the logical address of the instruction executing at the
  time the fault was detected". The oracle stacks the faulted instruction's (the restart
  model); the text is followed here. A candidate for `doc/manual-contradictions.md`.

---

### Where UAE040 disagrees with the manual (M7)

Found by `make vectors-all`. The manual is the arbiter; the bench accepts the core's
behaviour and counts each case.

- **A CAS or CAS2 whose compare fails makes no write.** UM 7.7.3: "If an operand
  does not match ... the M68040 still executes a single write transfer to terminate
  the locked sequence with LOCKE asserted. For the CAS instruction, the value read
  from memory is written back; for the CAS2 instruction, the second operand read is
  written back." The core makes that write; `core_vec_tb` accepts one write, to the
  address last read, where UAE040 has none, and prints how many it accepted.
- **A byte or word write carries the register's upper bits.** UAE040 reports the
  value written as the whole register (`ffffffad` for a byte `ad`). That is the
  harness's view, not a disagreement; the bench compares only the bytes written.
- **How PACK and UNPK's two bytes at -(An) are accessed.** UAE040 makes them one
  word access at an odd address; the core makes two byte accesses, as PRM 4 describes
  the operation. The split is a bus detail the manual leaves to the part (UM 7.3), so
  for `packunpk_mem` and `bitfield_mem` the bench falls back to comparing bytes: the
  same bytes read, and the same written with the same values. It prints how many
  vectors needed that (96, all PACK and UNPK: the bit fields match access for access).

### Where the oracles disagree with the manual, or with each other (M8)

- **The format $2 frame's address.** UM 8.4.3: for CHK, CHK2, TRAPcc, TRAPV, trace and
  the zero divide, +$08 holds "the address of the instruction that caused the
  exception". UAE040 stacks the next instruction's address there, the same as the PC.
  The cputest corpus -- WinUAE's copy of the core, whose tester its author checks
  against real processors -- stacks the instruction's, as the manual says, and RD68031
  found the same split for the MC68030 (UAE030 against the corpus). `tools/vectors/gen.c`
  (`normalise`) puts the instruction's address in UAE040's frame; `m8_exc` does not read
  that word in its handlers.
- **The stack frame's accesses.** UAE040 writes a frame a word at a time where it can;
  the core writes long words (UM 8.4: "it uses long-word operand transfers wherever
  possible"), and UM 8.4 leaves the order to the part. For a test that takes an exception
  the vector bench compares the bytes written, under the masks of the stacked SR's
  undefined condition codes.
- **Reserved bits of extension words.** The corpus runs BFCHG, BFCLR, BFSET and BFTST
  with bit 15 of the extension word set, and MOVES with bits 10-0 set -- fields PRM 4 and
  6 show as zero -- and expects them to execute normally: the part ignores those bits.
  The decoder did not, until M8 made its "illegal" an exception instead of a halt that
  the corpus counted as not built; it ignores them now.
- **The undefined condition codes of CHK, CHK2 and the zero divide** follow no rule in
  UAE040 that the vectors show. PRM 4 leaves them undefined, and the benches that can
  compare under a mask do; the program comparisons (`make cosim`), which cannot, keep
  out of them (`m8_exc` has no CHK).
- **CPUSHL and CPUSHP do not invalidate UAE040's instruction cache** (M9), whether
  the instruction is CPUSH IC or CPUSH BC; CPUSHA does, and so do CINVL, CINVP and
  CINVA. UM 4.2: CPUSH's second operation is that "all selected cache lines are
  invalidated", and the instruction cache is selected. Found by `m9_icache`, which now
  makes changed code coherent with CINV and CPUSHA only; `core_cache_tb` checks CPUSHL
  and CPUSHP of the instruction cache against the manual.
- **MOVE16 (An)+,(An)+ with the same register twice** increments it once, by 16, in the
  cputest corpus (four tests); PRM 4 says nothing of the case. The core follows the
  corpus, whose tester its author checks against real processors.
- **UAE040's copyback data cache agrees with the core** on everything `m9_dcache` and
  `m9_move16` can see from the program: write-through and copyback writes, replacements
  and pushes, CPUSHL and CPUSHA, CINV dropping dirty data, TAS, CAS and MOVES on dirty
  lines, a cache-inhibited access to a line the cache holds, and MOVE16 reading a dirty
  source line from the cache and invalidating its destination. What is on the bus is
  checked against the manual instead (`core_cache_tb`).
- **The caches against the oracles** (`make cache`): `m9_icache`, `m9_dcache` and
  `m9_move16` against UAE040 with the caches on, and the vector sweep and the cputest
  corpus run with the caches forced on, write-through (`CACHE=1`) and copyback through
  DTT0 (`CACHE=2`); a MOVEC that reads CACR is set aside then, since the bench put its
  value there. MOVE16 has no vector group: the vector bench compares operand accesses,
  and a line is not one; the corpus's 652 MOVE16 tests and `m9_move16` cover it. The
  `cinv_cpush` group sweeps CINV and CPUSH's encodings in both modes.
- **No oracle runs interrupts** (UAE040's harness and the corpus have no interrupt
  source), and the access error frame is UAE040's to judge only from M10. `core_exc_tb`
  and `core_fault_tb` check interrupts, STOP, RESET, BKPT, the format $7 frames of read
  faults and the double bus fault against the manual instead.

### The MMU against UAE040 (M10)

`m10_mmu` (264 instructions) and the `pmmu040` vector group (332 vectors) -- `make
cosim-mmu` runs both -- agree with UAE040 on: translation through three-level tables and an
indirect descriptor, translated code, the MMUSR of PTEST for a resident page written to
(M), an invalid one, PTESTW of a write-protected one, a TTR in a data and in a program
space; PFLUSH's effect on a stale entry; MOVEC to and from every MMU register, with the
bits that read as zero; and the access fault frames of a write to a write-protected
page, a read of an invalid page, a long word across into it (MA, FA its first byte), a
user read of a supervisor page and an instruction fetch from an invalid page -- format,
vector, SSW and FA. Where they differ:

- **The SIZE of an instruction fetch's fault.** UAE040 stacks a word ($0546 for a
  supervisor fetch's ATC fault); UM 8.4.6.2 says SIZE is "the original access size", and
  the MC68040 fetches long words (UM 7.3, 4.4.3), which the core reports ($0506), as it
  does for a fetch's bus error (`core_fault_tb`). `m10_mmu` keeps SIZE out of the
  register it compares.
- **A write's ATC fault.** UAE040 completes the instruction -- its condition codes set
  -- and stacks the write in WB3, V set, as the part does (UM 8.4.6.3); the core takes
  the fault before the write (`doc/divergences.md`), the instruction not done, its
  write-back status words clear. `m10_mmu` does not read them, and writes a value whose
  condition codes are those already set.
- **PTESTW of an address a write-protected TTR matches.** UAE040 answers MMUSR $0800 (B,
  a bus error); UM 3.1.4: a TTR match is "the R-bit is set, and all other bits are
  zero" with T -- **UAE040 wrong**. The `pmmu040` group keeps W out of PTESTW's TTRs.
- **URP and SRP keep bits 8-0** as written in UAE040. UM 3.1.1 says only that they
  "must be zero"; the core keeps them too, a search using bits 31-9.
- **The order of a search's accesses and its locking** are not compared: the oracle's
  operand hook does not report a search (above). `core_mmu_tb` checks the descriptors'
  U and M bits in memory against Table 3-1 instead.

### The FPU against UAE040 (M11)

`make cosim` runs `m11_fpu_a` (159 instructions: every format in and out but packed,
the arithmetic in the four rounding modes and three precisions, the conditionals,
FMOVEM, FSAVE and FRESTORE of the idle frame) and `m11_fpu_b` (214: an unimplemented
instruction, DZ, OPERR, INEX2, SNAN, overflow, underflow, BSUN, an FMOVE to an integer
that does not fit) register for register, FP0-FP7, FPCR, FPSR and FPIAR included.
`make cputest` runs the FPU corpus with the integer one: 11,136 FPU tests sampled
(`CPUTEST_MAX=40` an instruction file) from 2,705,164, every one passing, 732 of them an
unsupported data type compared with format $0. Where the two differ from the manual, or say what it does not:

- **UAE040 runs encodings PRM 5 has no instruction for** -- An as an FP operand, Dn as
  an extended, packed or double one, an FMOVEM of FP0-FP7 whose mode field does not say
  what its \<ea\> is -- as instructions, or as unimplemented ones (format $2). UM 9.6.1
  makes them F-line illegal (vector 11, format $0), which the core takes; `convert.py`
  leaves them out and counts them (773,840 tests).
- **An unsupported data type in opclass 000/010** is format $3 in UAE040, $0 on the part
  (above, the M0 spike); compared as $0.
- **FPCR's bits 3-0** are kept by UAE040; UM Figure 9-2 has them as zeros, which the core
  reads -- **UAE040 wrong**; compared as zeros.
- **A NaN's or an infinity's integer bit** differs at times (UAE040 converts a single NaN
  to an extended one with it clear); UM Table 9-5 makes it a don't care, and
  `core_cputest_tb` ignores it.
- **The unimplemented-instruction frame** has E1 and U clear in UAE040; Table 9-16 has
  both set, as the FPSP's `x_unimp` expects. UAE040's FSAVE frames are its own
  throughout: `core_fpu_tb` checks the core's against Table 9-16 and `fpsp.h`
  (`m11_fpu_c`), and the cosim programs discard theirs.
- **FP0-FP7 after reset** are zeros in UAE040; UM 9.2.1 says NaNs, which the core has.
  The cosim allows a reset NaN against UAE040's zero.
- **Where the manual leaves a choice the core follows UAE040** (`doc/divergences.md`,
  "Where the manual leaves the FPU a choice"): PREC = 11 as double; overflow and
  underflow to a register taken at once, format $3; the condition codes and the INEX2
  of a trapped underflow from the denormalised result; Table 9-12's value stored by an
  overflowing FMOVE out, an integer saturated; a packed FMOVE out's (An)+ and -(An)
  stepped before it traps.
- **PRM 5 contradicts itself** on FSGLDIV's operands and on FMOVEM's control-register
  modes (`doc/manual-contradictions.md` 7 and 8): the corpus decided both.

**Not authoritative for:** the FSAVE frames' contents (above), FRESTORE (cputest has
neither), the E1/E3 split, packed decimal (always vector 55 on the part, the FPSP's), or
the transcendental instructions' results (the FPSP's, `make fpsp`).

### The MC68LC040 against UAE040 -L (M12)

`make cosim-lc` builds the core with `FPU = 0` and runs the integer programs and
`m12_lc040` (535 instructions: every FP class through every addressing mode that reaches
the address calculation, from user mode onto the supervisor stack, a privileged FSAVE in
user mode, a traced FP instruction) against UAE040 `-L`, register for register, the
handlers keeping the format $4 frame in registers. `make vectors OP=lc040 FPU=0` sweeps
the same with random states: 1,610 vectors, the frame's writes compared, all passing;
`make vectors-all FPU=0` runs every group that way, with an RTE of a format $4 frame in
`traps`. The two agree that every FP instruction takes vector 11 with the eight-word frame
(UM A.5.2), the PC the next instruction's, changing no register -- An of (An)+ and -(An)
included -- and that a privilege violation comes first. The address field, which UM
A.5.1 says only is "the calculated effective address of the operand ... using the
addressing mode in which the effective address is calculated", is in UAE040:

- **0** for a register or an immediate (as UM A.5.1 says), and for FBcc, FTRAPcc,
  FMOVECR and a register-to-register operation, which have no \<ea\>;
- **the operand's address** for the general operations, FMOVE out and FScc: An for
  (An)+, An less the operand's size for -(An) (12 for an extended or packed one; 2 for a
  byte through A7);
- **An itself** for -(An) of FMOVEM (FP0-FP7 or the control registers, one of them
  included), FSAVE and FRESTORE: where the first register would go, not the operand's
  lowest byte.

The core does as UAE040 there; the last is the manual's silence decided by the oracle
(`doc/divergences.md`). Where they differ, `core_lc040_tb` (`m12_lc040_b`) checks the
core against the manual:

- **The encodings PRM 5 has no FP instruction for** -- An as an operand, Dn as an
  extended one, an FMOVEM whose mode field does not match its \<ea\>, an opmode PRM 5
  does not have -- are format $4 in UAE040 `-L`. UM A.5.1 gives format $4 to "all legal
  MC68040 and MC68881/MC68882 floating-point instructions" and distinguishes them "from
  other unimplemented F-line instructions": the core takes them as the MC68040 does, an
  F-line illegal instruction, format $0 -- **UAE040 wrong**.
- **FDBcc**'s address field is a number UAE040 makes up ($0001FFFC for `FDBNE D5`); its
  mode is a register direct one, 0 by UM A.5.1 -- **UAE040 wrong**.
- **FMOVE.P FPn,-(An){Dn}**, a dynamic k factor, has An in UAE040, where the static
  k factor's has An - 12 -- the size of opclass 010's format 7, FMOVECR, which has none;
  the operand is twelve bytes either way, An - 12 in the core -- **UAE040 wrong**.
- **RTE of a format $4 frame** is taken by UAE040 as an MC68040 too. UM A.5.2: "The
  MC68040 cannot accept the eight-word unimplemented stack frame", and UM 8.4's list
  for the MC68040 has no $4: a format error, vector 14, in the core -- **UAE040 wrong**.
  The vector group has that RTE only with `-L`.

**Not authoritative for:** anything the MC68040 and the MC68LC040 share (the sections
above), or where the format $4 exception falls among the access errors of the writes
before it (UM A.5.1, step 2): UAE040 has no store buffer, and neither program faults.

### UAE040 in rd-virt (M13)

The harness gained devices behind the RAM, interrupts taken at a hook boundary, STOP's
state, writes through the core's own path and an integer-register setter that leaves the
caches alone (`doc/virt.md`). Linux 7.2.9 boots on it alone in rd-virt to the shell, runs
`commands.script` and powers off -- 88.4 M steps in 86 s, the M68040FPSP emulating awk's
transcendental functions to the host's digits (`make virt-uae`, `make fpsp`'s script).
In lockstep with the core, 0 divergences but the decided ones, and six RTL bugs found
(`doc/m13-mismatches.md`). Against the manual, what the lockstep met in the oracle:

- **A write's ATC fault** (M10, above): completed, and the write left in WB3, on every
  page fault of a user write -- 399 in the boot. The lockstep gives the oracle the
  core's frame (m13-c1).
- **An instruction fetch fault's SIZE and FA** (M10, above): word, and the instruction
  word's address -- 436 in the boot (m13-c2).
- **The EA field of an access error frame** is filled in with no continuation bit set,
  where UM 8.4.6.1 makes it meaningful only with one (m13-c3).
- **The unimplemented-instruction frame's E1** is clear for a register source -- as the
  FPSP needs, and against UM Table 9-16 (`doc/manual-contradictions.md` 9). **UAE040
  right**; the core followed the table until M13.
- **The FPSR at an unimplemented FP instruction's trap**: condition codes and EXC
  cleared, where the core leaves them, as the FPSP's "D25B fix" says the part did
  (m13-c6).
- **FMOVE to an integer of a NaN**, which takes the nonmaskable operand error: the
  oracle leaves the NaN's top bits in the destination before the handler runs, the core
  zero (m13-c5); the manual leaves it open.

## cputest: WinUAE's instruction tester, for the MC68040 -- M0 spike

**What.** The vector generator that comes with WinUAE (`Inputs/ref/winuae/cputest/`),
written to be run against real CPUs; its readme calls its 68040 integer support "almost
complete" and its FPU support incomplete ("not all tests work correctly yet"; no
FSAVE/FRESTORE). It has no MMU and no cache-instruction tests. It is built on Linux, out of
tree, by `tools/cputest/build.sh` with the shims in `tools/cputest/compat/` -- both
RD68031's, unchanged but for their headers -- in about 10 s.

**The flow** (`make cputest-gen`):

1. `build/cputest/gen/cputestgen`, built once.
2. Two corpora, each generated once per ini by `tools/cputest/generate.sh`, **one
   instruction per generator run** with a time limit (`CPUTEST_TIMEOUT`, 120 s), a stalled
   instruction retried once with the next seed into a set of its own (RD68031's scheme):
   - integer, from `tools/cputest/cputestgen.ini` (`cpu=68040`, no FPU), into
     `build/cputest/run/data/4_RD040/`: RD68031's list of integer mnemonics with MOVE16
     added;
   - FPU, from `tools/cputest/cputestgen-fpu.ini` (`cpu=68040`, `fpu=68040`), into
     `build/cputest/fpu/data/4_RD040F/`: every FPU instruction cputest knows, in the order
     of its own `fall` -- FMOVECR, every arithmetic opmode including those the 68040 does
     not implement, one undefined opmode (FPP3F), FDBcc, FScc, FTRAPcc, FBcc, FMOVEM.
   cputest generates FPU tests only in a set whose `fpu=` is set, hence two inis.
3. `tools/cputest/convert.py summary` decodes every test of both and counts them per
   instruction (`build/cputest/summary.txt`).

**The memory map** is RD68031's (low memory $0000-$7FFF, test memory $8000-$FFFF, the
64 KB 32-bit port its bench used). RD68041 has no bench yet; the map is to be revisited
when `core_cputest_tb` is written (M7).

**convert.py.** The corpus is DATA_VERSION 24, as RD68031's. What the 68040 needed:
- The FPU's state: FP0-FP7 (an extended value, partly replaced from both ends: the
  generator's `restore_fpvalue`), FPCR, FPSR and FPIAR in both the set-up and the result
  streams; the FPU test loops (all off / all on, or FPSR's condition codes, or FPCR's
  rounding precision and mode, in place of the CCR loop); FPIAR set to $FFFFFFFF before
  each test; and the FPU register overrides.
- Frames: nothing new. The corpus generates no bus or address errors, so no format $7;
  the FP frames -- $0 (F-line, pre-instruction), $2 (unimplemented instruction, with the
  generator's "EA valid" flag), $3 (post-instruction) -- were already decoded. Format $4
  (an MC68LC040's) does not occur: there is no LC040 corpus.
- A `summary` command. Since M11 `bench` writes the FPU's registers into every test of
  an FPU set, and `core_cputest_tb` deposits and compares them (below, "The FPU against
  UAE040").

### The M0 spike

`make cputest-gen`: 4 min 18 s on this machine (generator built in 10 s), nothing left
out, one instruction reseeded (CHK, as in RD68031). `convert.py summary` decodes the whole
corpus without an error:

| | Instruction files | Tests | Mnemonics |
|---|---|---|---|
| integer (`4_RD040`, `4_RD040S3`) | 177 | 1,574,646 | 99 |
| FPU (`4_RD040F`) | 391 (61 mnemonics x their sizes) | 2,705,164 | 61 |
| total | 568 | 4,279,814 (4,133,537 run, 146,277 skipped by the generator) | 160 |

The 61 FPU mnemonics: every arithmetic opmode cputest names (the MC68040's own, its
FSxxx/FDxxx forms, and the 22 of UM table 9-10 it does not implement), FMOVECR, FPP3F,
FBcc, FDBcc, FScc, FTRAPcc, FMOVEM (which includes FMOVE to and from FPCR/FPSR/FPIAR).
Frames in the corpus: $0 (vectors 4, 8, 10, 11, 14, 32-47), $2 (5, 6, 7, 9, and 11 for
1,090,032 unimplemented-instruction tests), $3 (51 UNFL, 52 OPERR, 53 OVFL, 55
unsupported data type). Per instruction: `build/cputest/summary.txt`.

What the corpus says, checked against UM §9 on samples:
- Every instruction of table 9-10, and FMOVECR, takes vector 11 with a format $2 frame
  (FSIN.x: 6,000 tests each), as UM 9.6.1 says; their illegal effective-address forms take
  vector 11 format $0 (F-line), as it also says.
- Overflow and underflow trap (vectors 53, 51, format $3) with the user's enables clear:
  UM 9.7.4.2 and 9.7.5.2, "nonmaskable" on the 68040. Correct.
- **Disagreement:** an unsupported data type in a memory-to-register operation (FADD.P,
  FADD.S of a denormal: opclass 010) is recorded as vector 55 with a **format $3**
  (post-instruction) frame -- 118,096 tests, none with format $0. UM 9.6.2: opclass 000
  and 010 "cause a pre-instruction exception ... a format $0 (for the pre-instruction
  exception)", format $3 only for opclass 011. Settled at M11 for the manual: the FPSP's
  `x_unsupp` returns through either, and the core stacks format $0; `convert.py`
  compares such a test with a format $0 frame, and counts them.
- The FPU loops set FPCR's rounding precision to 11 in their all-ones pass, a value UM 9
  leaves undefined: those tests are the oracle's convention, not the manual's.

Stalls and gaps: CHK stalls under seed 2 and is generated under seed 3 (its own set,
`4_RD040S3`); MOVE2C (MOVEC to a control register) yields no tests at all (the generator
writes no file for it); CAS2 yields 20 tests and MOVE16 652 in this 32 KB test memory --
a larger map is the first thing to try at M7.

**Not authoritative for:**
- the MMU, the caches, CINV/CPUSH, PTEST/PFLUSH (none generated), bus and address errors
  (disabled), interrupts, FSAVE/FRESTORE (not supported by the generator);
- the FPU where WinUAE's author says it is incomplete; every FPU test the core fails is an
  investigation against UM §9 before it is a bug;
- the MC68LC040: there is no LC040 corpus, and the integer corpus's ILLEGAL set (a 68040
  with no FPU) gives FP opcodes plain F-line format $0 frames, not UM A.5's format $4 --
  that is cputest's model of an FPU-less part, not an LC040's. UAE040 `-L` is the oracle
  for format $4 (above, "The MC68LC040 against UAE040 -L").

---

## QEMU: the m68040 of QEMU 11.1.2 (a third instruction trace) -- M0 spike

**What.** QEMU's `qemu-system-m68k -cpu m68040` (`Inputs/ref/qemu`, v11.1.2), run on its
`virt` board, traced by a TCG plugin. It has no MC68LC040 model (`-cpu help`: m68000 to
m68060 and ColdFires), no caches, and executes the whole 68881 instruction set itself.
The plugin links nothing of QEMU's but its plugin API, and is GPL-2.0-or-later like the
other harnesses; the comparison script only reads traces.

### The harness (`tools/cosim/qemu040/`)

| File | What |
|---|---|
| `build.sh` | exports the tree (`git archive`) into `build/qemu/src`, configures out of tree in `build/qemu/obj` (`m68k-softmmu`, `--enable-plugins`, no UI, no tools, no docs), installs into `build/qemu/inst`. About 2 minutes at `-j4` from clean |
| `qemu040.c` | the plugin, `build/qemu040/libqemu040.so`: the `.trc`, an operand stream, or an instruction count |
| `compare.py` | compares two `.trc`s record by record, resynchronising on the PC; `--expect` a list of known differences |
| `smoke040.quirks` | the differences expected on `smoke040.S` |

`make qemu040` builds both; `make cosim-qemu-smoke` runs `tools/cosim/uae040/tests/smoke040.S`
on QEMU and on UAE040 (`make uae040-smoke` first) and compares the traces.

**Build quirks.** QEMU's configure refuses an exported tree without the `keycodemapdb`
subproject that a release tarball carries: `build.sh` copies the release's subprojects from
RD68031's unpacked `qemu-11.1.2` tarball, and keeps downloads enabled because configure's
Python venv wants the `wheel` package, which this host lacks (fetched from PyPI into
`build/qemu/obj/pyvenv`). ninja is not installed: RD68031's copy is used.

**Running a bare-metal image.** `-M virt -cpu m68040 -m 1M -kernel prog.elf`: the board
loads the ELF and starts at its entry point in the reset state, with no SSP. The plugin
(`reset=on`, the default) then performs the reset exception's loads itself before the first
instruction -- SSP from physical 0 and PC from physical 4 (UM 8.2.10) -- so the program runs
as it does under `uae040_trace`. The board writes its bootinfo after the ELF's `_end`; a
program must not expect zeroes there. The run ends, as `uae040_trace`'s does, at the first
BRA to itself.

**The trace** is `uae040_trace`'s `.trc`, nfield 58, same order, so every reader of UAE040's
traces reads it. QEMU's plugin interface exposes its gdbstub's registers only: D0-D7, A0-A6,
the active A7, SR, PC, FP0-FP7, FPCR, FPSR. Every other field is written **`x`** -- an
unknown digit to `$fscanf("%h")`, skipped by `compare.py`:
- USP, ISP, MSP: the active A7 goes into the one SR.S/SR.M select, the other two are `x`;
- VBR, CACR, SFC, DFC, TC, URP, SRP, ITT0/1, DTT0/1, MMUSR: `x`;
- FPIAR: `x` (the gdbstub always reads it as 0).
The PC is the instruction's own address (QEMU's PC register is brought up to date only at
block boundaries). The operand stream (`ops=`) is `uae040_trace -O`'s format with `x` for
the function code and `E x` at each exception (a plugin is not told the vector). It carries
only the accesses instructions make: exception frames, the vector fetch, RTE's frame
reads and table searches are absent. `count=FILE` counts instructions, at full speed.

**The condition codes.** Read in the middle of a translation block, SR's condition codes
are stale (a MOVEQ #0 seen with Z clear). QEMU is therefore always run with
`-accel tcg,one-insn-per-tb=on`; with it, SR agrees with UAE040 at every boundary of the
smoke program.

### The M0 spike

`make cosim-qemu-smoke`: 117 instructions on QEMU, 130 on UAE040 (the 13 of the FSIN
handler, below), compared after resynchronisation. D0-D7, A0-A6, the active stack pointer,
SR, FPCR, FPSR and FP0-FP7 agree at every common boundary except in the cases below, each
listed in `smoke040.quirks` and confirmed on every run. The access error's format $7 frame
gives the same format word ($7008) and SSW ($0505) in both; MOVEC to CACR, the MSP/ISP/VBR
reads, the three-level table search with its remap, the page fault, its RTE restart, PFLUSH,
MOVE16 and the FP arithmetic and FMOVEM all agree.

| Where (`smoke040.S`) | UAE040 | QEMU | The manual |
|---|---|---|---|
| reset | FP0-FP7 = 0 | FP0-FP7 = NaN ($7FFF FFFFFFFF FFFFFFFF) | UM 8.2.10 does not say: both are allowed |
| MOVEC $FFFFFFFF to ITT0, back | $FFFFE364 | $FFFFFFFF | UM 3.1.3: the reserved bits read as zero -- **QEMU wrong** |
| MOVEC $7FFF to TC, back | $4000 | $7FFF | UM 3.1.2: bits 13-0 read as zero -- **QEMU wrong** |
| format $7 frame, the EA field (+$08) | 0 | the fault address | UM 8.4.6.1; to settle at M10 |
| PTESTW of a resident page, MMUSR | $00030011 (M) | $00030001 | UM 3.1.4: a write search sets M -- **QEMU wrong** |
| DTT0 $0000C040 (base 0, mask 0, S ignored) | not translated: PA $20000 | translated through the tables: PA $30000 | UM 3.1.3 -- **QEMU wrong** for this TTR |
| CINVA of a dirty copyback line | the write is lost | kept (no data cache) | UM 4.5 -- QEMU has no caches |
| FSIN | vector 11, format $2, handled | executed: a result in FP4, no exception | UM table 9-10: unimplemented on the 040 -- **QEMU wrong** |

**Trusted for:** integer instructions and their condition codes in supervisor and user
mode, outside the MMU and the caches; MOVEM, bit fields, MUL/DIV, the 040's MOVE16; the
results of the FP instructions the MC68040 implements (no FPSP is needed on QEMU).

**Not authoritative for:** anything the trace writes as `x`; the control registers'
reserved bits; transparent translation and PTEST's status; caches and
CINV/CPUSH (none); exception frames beyond the format word and SSW, and their bus accesses
(not visible); the FPU's unimplemented instructions and data types (QEMU implements them,
so it can never stand in for the FPSP traps: UAE040 is the reference there); the
MC68LC040 (no model). A third opinion at M7, not an arbiter.

**Verdict: go, with caveats** -- the trace works and lines up with UAE040's; its value is
the integer ISA.

---

## MAME's Quadra: the user's Quadra 650 ROM on MAME's m68040 -- M0 spike

**Which machine.** The ROM the user supplied (`Inputs/ref/ROMs/Quadra-650.ROM`, sha256 in
`Inputs/sw/ROMS.sha256`) is, by CRC and SHA-1, MAME's `f1acad13.rom` (CRC 4e70e3c0,
SHA-1 f2a9ce38..., "Version 23F2"), the default BIOS of the `macqd800` set in
`src/mame/apple/macquadra800.cpp`. Its clones share it: `macqd650` (Quadra 650: an
MC68040 at 33 MHz), `macqd610`, and `macct650`/`macct610` (Centris 650/610: an
**MC68LC040**). One ROM so gives both RD68041 configurations, `quadra` and `quadra-lc`.

**MAME also needs `342s0440-b.bin`** (1 KB, CRC cffb33eb, SHA-1 4a35a446...), the firmware
of the ADB modem's PIC microcontroller, which MAME runs at low level. It is Apple
firmware too and was not supplied. Without it MAME refuses to start; with a **zero-filled
stand-in** (made by the Makefile in `build/` when `Inputs/ref/ROMs/342s0440-b.bin` is
absent) MAME warns about the checksum and runs.

**The build** (`make mame-quadra`, `sim/mame/build.sh`): RD68031's recipe -- a copy of
`Inputs/ref/mame` in `build/mame/src`, `SUBTARGET=quadra SOURCES=src/mame/apple/macquadra800.cpp`,
SDL headers from RD68031's unprivileged prefix, `-j2`, a guard that stops the build under
3 GB available. 22 minutes; about 1,400 compile units (the driver pulls in the NuBus card
library and the SCSI devices). MAME is not patched.

**The run** (`make quadra-m68040`, `sim/mame/quadra.sh`, `sim/mame/quadra.lua`): headless,
`-video none -sound none -nothrottle`, a fresh PRAM each time, the screen saved as a PNG
every emulated second and the PC and SR logged. `-wavwrite` keeps the sound.

### The M0 spike

| | Quadra 650 (`macqd650`, m68040) | Centris 650 (`macct650`, 68LC040) |
|---|---|---|
| 0-2 s | sound in the first two seconds of the recording, then silence but for a short blip at 4 s: taken to be the startup chime (not listened to) | |
| 1-5 s | black screen, the ROM's tests and set-up (PC in the ROM, $408xxxxx) | the same |
| from 6 s | the grey desktop pattern; the ROM waits in a loop at $4080A870 with interrupts enabled, testing a flag an interrupt is to clear -- by its place in the boot, most likely ADB initialisation | the same, from 7 s |
| speed | 15 emulated seconds in 4.7 s wall (350 %); 120 s in 38 s | |

The run is deterministic: two runs give the same PCs and the same PNGs, so a screen hash
is a valid check (`sim/mame/quadra-m68040.expect`). With the stand-in firmware the ADB
modem never answers, which is the likely reason the boot stops before the "?" disk:
the ROM got through its POST, the chime, the video and the desktop pattern on MAME's
m68040 (and its 68LC040), **with no fix needed** to MAME's CPU so far.

**What is needed next** (no OS media was fetched):
- `342s0440-b.bin`, the ADB modem firmware, from the user, to reach the "?" disk;
- a serial console: the SCC's `modem` and `printer` ports take MAME's `null_modem`
  (`-modem null_modem -bitb socket.127.0.0.1:PORT`), RD68031's `drive.py` scheme;
- for NetBSD/mac68k or Linux/m68k: both start from a Mac OS application (the NetBSD
  Booter, Penguin), so a SCSI disk image (`-hard1`, `.chd`/`.hd`) with System 7.1-7.6 or
  8.1, the booter and a kernel and root (a NetBSD/mac68k install set or a Debian m68k
  image), and the booter set to a serial console. Mac OS itself would be checked by screen
  hashes.

**Not authoritative for:** anything beyond MAME's own model of the machine; the bus
(MAME has no 040 bus cycles); cycle timing.

**Verdict: go, with caveats** -- the machine boots MAME's m68040 and 68LC040 from the
user's ROM to the desktop pattern; reaching the "?" disk and a console needs the ADB
firmware and OS media above.

---

### The core in MAME's Quadra (M14, phase A)

**How it plugs in** (`sim/mame/`, RD68031's scheme): `rd68041_device`, a `cpu_device`
compiled into MAME beside the driver, loads the core from a shared object
(`$RD68041_VLT`: `build/mame/vlt/rd68041_vlt.so`, or `vlt-lc/` for the MC68LC040) --
`rd68041_top` under Verilator behind a pin-level agent that turns its transfers into
accesses of the machine's physical address space (`rd68041_vlt.cpp`). The core
translates and caches inside, as the part does. `sim/mame/quadra.patch` adds the
machines `macqd650rd` (the Quadra 650, 33 MHz) and `macct650rd` (the Centris 650,
25 MHz, the MC68LC040 build) and lets the IOSB take a CPU that is not MAME's 68000
family: it asked for Musashi's external-MMU mode, and its SCSI pseudo-DMA has an access
made again with `retry_access()` when the device is not ready, which the agent answers
with a bus retry (TA with TEA, UM 7.4.6) so that the core runs the transfer again. The
Quadra raises no bus errors. Harness choices, not the core's: a write is made one clock
after its data is on the bus (the machine is asked before the transfer is answered),
so writes take a wait state; interrupts are autovectored (the CPU space map).

**Compared on:** the screen. With the stand-in ADB firmware MAME's m68040 and 68LC040
run the user's ROM through its POST to the grey desktop and wait in ADB initialisation
(the M0 spike); the core does the same and must end on the same pixels
(`sim/mame/quadra-m68040.expect`; the hash is of the decoded pixels now, the PNG files
carrying the machine's name):

| | Machine | Instructions in 12 s | Screens (pixels) | Wall |
|---|---|---|---|---|
| `make quadra` | `macqd650rd`, the core as the MC68040 | 66.6 M (393 M clocks) | black from 1 s, the desktop from 7 s (MAME's m68040: 6 s); the ROM's ADB wait loop at $4080A870 | 788 s, 0.015× real time, 500 k clocks/s |
| `make quadra-lc` | `macct650rd`, the MC68LC040 | 47.0 M (297 M clocks) | the same, the desktop from 8 s (MAME's 68LC040: 7 s) | 474 s |

The core reaches each screen later than MAME's CPUs in emulated time: it takes more
clocks per instruction than MAME counts (`doc/timing-divergences.md`). No bus retry was
asked for (no SCSI device here). **Next (phase B):** the ADB modem's firmware, then a
disk with Mac OS and a booter, from the user (`doc/plan.md`, M14).

### The core in MAME's Quadra (M14, phase B): System 7.6.1 to the Finder

**The media**, the user's, git-ignored and checked against `Inputs/sw/ROMS-m14.sha256`:
`342s0440-b.bin`, the ADB modem's firmware (CRC cffb33eb, MAME's), and `mac761.chd`, a
SCSI disk with System 7.6.1. The disk is copied read-only into `build/mame/disks/`, and
MAME writes a diff file into each run's directory, so every run boots the same disk.

**The check.** The screen is hashed every 10 emulated seconds (`QUADRA_STEP`), in
`quadra.lua` now: an FNV-1a of the pixels, the menu bar's clock masked (x >= 448, y < 20)
because MAME's RTC starts from the host's time. MAME is otherwise deterministic. A run
stops once the screen has been one of the reference machine's screens in
`sim/mame/quadra-m68040.expect` for three samples (`QUADRA_UNTIL`), and passes when that
screen is the reference's last. The Finder -- the disk's window, the menu bar, the
Control Strip -- is `2078a196` on both machines.

| | Machine | Screens (every 10 s) | Finder from | Instructions, clocks | Retries | Wall |
|---|---|---|---|---|---|---|
| `make quadra-m68040` | `macqd650`, MAME's m68040 | the happy Mac (30 s), the extensions (40-60 s), the Finder | 70 s | | | 75 s for 200 s |
| `make quadra-m68040 QUADRA_MACHINE=macct650` | `macct650`, MAME's 68LC040 | the same, the extensions to 70 s | 80 s | | | |
| `make quadra` | `macqd650rd`, the core as the MC68040 | the same screens: 30 s `d5613dc5` and 40 s `3ad8a1c1` as MAME's; 50 s MAME's 60 s screen | **60 s** | 443.2 M boundaries, 2,601 M clocks to 78.8 s | 1,787 | 5,545 s (92 min), 469 k clocks/s |
| `make quadra-lc` | `macct650rd`, the core as the MC68LC040 | the desktop (10 s), `3d31be56` (20 s), the happy Mac and `3ad8a1c1` (40 s) as MAME's, the extensions | **70 s** | 375.7 M boundaries, 2,222 M clocks to 88.9 s | 3 | 3,698 s (62 min), 601 k clocks/s |

**PASS on both**: the core ends on the very pixels MAME's CPU ends on. It gets there
sooner in emulated time (60 s against 70 s, 70 s against 80 s), although it takes more
clocks an instruction (5.9 on average here). Most of the boot is spent waiting on the disk
and the timers, and the two CPUs meet the SCSI device differently: MAME's m68040 has an
access made again inside MAME, the core runs a bus retry. Where the 10 s go was not
investigated; the emulated time to a screen is not a performance measure.

**What it found** (`doc/bugs-found.md`, M14): a read of a serialised page could be made
twice when an interrupt or a mispredicted branch discarded the instruction after its
read (UM 4.3.2); the ROM's SCSI FIFO reads lost a word and the boot from the disk stopped
for good. Mac OS then maps the same register noncachable but not serialised (CM 11), and
the core now holds every cache-inhibited read until the instructions before it are done
(`doc/divergences.md`). `core_ser_tb` keeps both cases.

**Debugging aids** (`rd68041_vlt.cpp`): `RD68041_TRACE=lo-hi` prints every transfer in
that address range with its answer, then the pipeline's state for 6 boundaries and 60
clocks (retire, the stages' valid bits and PCs, the interrupt, the DMU's read state). The
PC the device reports is the core's retired one.

**NetBSD and Linux** were to follow on the Quadra, from a Mac OS booter (the NetBSD
Booter, Penguin) with their own media. They run on QEMU's `virt` instead, where both
boot from `-kernel` ("rd-qvirt", below).

## rd-qvirt: the core in QEMU's virt, against QEMU's m68040 (M14)

**What.** The rest of M14 after Mac OS. NetBSD and Linux could have run on MAME's
Quadra, but only from Mac OS booters and their media; they run instead on QEMU 11.1.2's
`virt` board, where both boot from `-kernel`. NetBSD has a port for it, virt68k, from
11.0. QEMU runs unmodified under qtest, and the core drives its devices from a harness
(`doc/qvirt.md`). The reference is the same guest on the same board, with QEMU's own
m68040, the same RTC, disk and command set. The gate is the console, compared line for
line by `sim/qvirt/console-diff.py`. Each guest's mask file leaves out only the lines
that depend on elapsed virtual time.

| | Guest | Result | Instructions (core) | Clocks | Wall | Notes |
|---|---|---|---|---|---|---|
| `make qvirt-bare` | `virt_hello`, `virt_timer`, `virt_mmu` | PASS | 274, 17,068, 140,919 | | seconds | `--step-ns 20`; with a one-step quantum `virt_timer` takes rd-virt's 17,023 steps exactly |
| `make qvirt-linux` | rd-virt's Linux 7.2.9 and command set | **PASS, consoles identical** (111 lines) | 95.9 M | 324.8 M | 685 s | 479 DMA commands, 604 snooped transfers (the tty's buffers) |
| `make qvirt-linux FPU=0` | the same, for the MC68LC040 (`commands-lc.script`) | **PASS, consoles identical** (110 lines, `linux-lc.mask`) | 96.6 M | 329.8 M | 532 s | 473 DMA commands, 601 snooped transfers |
| `make netbsd-qvirt` | NetBSD/virt68k 11.0 GENERIC, multi-user from `ld0`, root logged in, the command set, `shutdown -p` | **PASS, consoles identical** (120 lines) | 1,762 M | 7,296 M | 4.4 h | 1,912 DMA commands, 1.97 M snooped transfers, 1,422 virtio settles; `FPU=1` only (below) |

**What it found:**
- **No RTL bug.** The core's behaviour that NetBSD tripped on is the MC68040's (below).
- **A guest that needs coherent DMA.** QEMU's devices write guest memory behind any
  processor, and QEMU's m68040 has no caches. A copyback-cached MC68040 needs the board
  to make DMA coherent, which a real board does with snooping (UM 4.4, 7.9). So
  rd-qvirt's devices are an alternate bus master: the DMA command is held off with a
  retry, the bus is taken, and snooped transfers carry what the device reads and writes
  (`doc/qvirt.md`). It exercises the core's snooper, retry and arbitration with real
  traffic.
- **A guest that relies on QEMU's synchronous MMIO.** NetBSD's polled console input,
  `gftty_cngetc`, reads its DMA buffer two instructions after the write that starts the
  DMA. On an MC68040 that write may still be pending (UM 7.7: *"write cycles can be
  deferred indefinitely"*). The core read the stale byte, so every key at the
  root-device prompt was answered with a bell. The harness's copy of the kernel gets
  the NOP the manual prescribes in place of a redundant `clrl` (`sim/qvirt/nbpatch.py`),
  and both processors run it. This is class (b): a harness issue, not an RTL one.
- **The MC68LC040** runs Linux (FPU=0, the kernel's FPU emulation), not NetBSD:
  virt68k's GENERIC has the FPSP but not `FPU_EMULATE`.
- **QEMU's m68040 is no MC68LC040.** With the bootinfo's FPU record cleared, Linux
  takes it to have no FPU, but QEMU still executes FP instructions. So `/init`'s
  `awk float:` (FATAN) is right on the reference, while on the core it goes through the
  kernel's emulation, which has no FATAN and prints a warning and its own value.
  `linux-lc.mask` leaves those lines out. They are the same as M13's, where the
  no-FPU UAE040 traps as the core does. Apart from the RAM size and the echoes, the
  core's LC console equals that M13 lockstep console. This is class (c), the
  reference's.
- **No line was ever sourced.** Both kernels push a buffer from the data cache before
  a device reads it, so the snooper's intervention is left to the benches.

**Not authoritative for:** anything QEMU's m68040 does not model (caches, bus timing,
the access error frames' internals, the MC68LC040's F-line trap). Console identity says the two systems computed the
same things, not that they did so the same way.

## Linux on QEMU's virt (the guest kernel for rd-virt) -- M0 spike

**What.** RD68031's rd-virt guest rebuilt for the MC68040: Linux 7.2.9 and BusyBox
1.38.0, pinned by sha256 in `Inputs/sw/MANIFEST` (the same files and hashes as RD68031's;
the tarballs were copied from RD68031's download directory and verified). In
`sim/virt/linux/`, from RD68031's:
- `rd-virt.config`, over `allnoconfig`: `VIRT`, `M68040` alone (no `M68030`, so the kernel's
  C is built for the 040), and **`M68KFPU_EMU` off**. With `M68040` the kernel always links
  the M68040FPSP (`arch/m68k/fpsp040`);
- `build.sh` (BusyBox static with `-mcpu=68040`; a check that the config took);
- `init`, `cpio.list`, `commands.script` (expecting `68040` and `-rd040`, and floating
  point in awk: `atan2`, `sin`, `exp`, `log`);
- `qemu-run.py`: boots QEMU with the console on stdio, types the script, waits for the
  power-off.

`make virt-qemu` builds the guest once (`-j4`, alone: 76 s for the kernel and BusyBox) and
boots it on `build/qemu` (`-M virt -cpu m68040 -m 128M`, `lpj=250000 rdvirt.shell`).

### The M0 spike

The kernel boots to the shell (`CPU: 68040`, `MMU: 68040`, `FPU: 68040` in
`/proc/cpuinfo`), every command of the script answers as expected -- awk's `3.141593`
and `fp 3.55975 2.30259`, the md5 of `seq`, the goldfish tty's input -- and it powers off
through virt-ctrl: **about 90.9 M instructions** (the plugin's count; 144 M without
`lpj=`), 1.1 s wall. The count varies by a few tens of thousands from run to run, with or
without `-icount shift=0,sleep=off`: the console input arrives at host-dependent times.

**Caveats:**
- On QEMU the FPSP is linked but **never runs**: QEMU executes FSIN, FETOX, FLOGN and
  FATAN itself. The same kernel on UAE040 or the core will trap them to the FPSP, which is
  the point of running it there (M11, M13).
- **The MC68LC040** needs `CONFIG_M68KFPU_EMU=y` as well: the kernel's FP emulation takes
  the F-line traps when the bootinfo reports no FPU (rd-virt leaves `BI_FPUTYPE` at 0, as
  RD68031 found an 030 kernel needs). QEMU cannot run that case (no LC040 model); its first
  run will be on rd-virt with UAE040 `-L`. RD68031's cautions about the emulator's
  transcendental placeholders apply.

**Verdict: go.**
