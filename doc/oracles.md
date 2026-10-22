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
| 4 | MAME's m68040 in a Macintosh Quadra | whole-system behaviour | M0 spike 4: **go, with caveats** (below; one more ROM needed) |

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
- **Write-backs in the format $7 frame.** The oracle restarts a faulted instruction rather
  than leaving pending write-backs for the handler (UM 8.4.6.3); the spike's fault was a
  read, where the two agree. Faults on writes, on a push, on MOVE16 and on misaligned
  accesses across a page (MA) are M10's investigation.
- **FSAVE frames' contents** beyond the format word, and FRESTORE of anything but an idle
  or null frame (above). The FPSP is the reference for those fields (CLAUDE.md).
- **The effective address field** of the format $4 frame for `-(An)`: for FMOVEM.X and
  FSAVE to `-(SP)` the oracle stacks An before the decrement ($8000); UM A.5.1 says "the
  calculated effective address" without saying which for a predecrement. An open question
  for M12.
- **Clock counts** (`cpu_cycle_exact` is not used).
- **Interrupts** are not wired (M13).
- **The data cache when the MMU is off.** UM 3.1.2 gives such accesses the default
  attributes cachable, write-through; the spike did not test copyback through a TTR with
  TC.E clear.

**Found on the way:**
- UM 8.4.6's frame table says the format $7 frame's stacked PC points to the "next
  instruction"; UM 8.2.1 says it is "the logical address of the instruction executing at the
  time the fault was detected". The oracle stacks the faulted instruction's (the restart
  model); the text is followed here. A candidate for `doc/manual-contradictions.md`.

---

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
- A `summary` command; `bench` refuses an FPU set until RD68041's bench defines its stream.

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
  exception)", format $3 only for opclass 011. To settle at M11, against the FPSP's
  handler (which reads the frame) before following either.
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
  for format $4.

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
