# Two MC68040s on one bus: the board, the arbiter, and the bench

A board with two RD68041s sharing one MC68040 bus, behind the fairness arbiter of UM
7.8.2.1 as `doc/um-7-8-2-1-fairness-arbitration.md` corrects it. It validates the core's
multiprocessor behaviour:
- arbitration, including implicit ownership and the indeterminate handover;
- snooping between two caching masters, with sourcing and invalidation;
- locked sequences under contention;
- interprocessor interrupts;
- instruction-cache and ATC maintenance driven by the other processor.

Nothing here is an oracle. The checks are the manual's rules, the program's own
consistency checks, and memory at the end.

| File | What |
|---|---|
| `sim/models/rd68041_fairarb.sv` | the corrected Figure 7-35 arbiter; `use_locke` and `gapless` (the printed outputs, for the negative test) |
| `sim/models/rd68041_smpdev.sv` | the board's devices: WHOAMI, interprocessor interrupts, CPU 1's release from reset |
| `sim/models/rd68041_slave.sv` | memory; gains `set_external` (a window left to another responder) and `add_retries` |
| `sim/tb/rd68041_smp_harness.svh` | the board: two `rd68041_top`, the bus resolved, the arbiter, memory, the devices, the board's two gates (below), the bus checks |
| `sim/tb/core_smp_tb.sv` | the run, the memory checks, the verdict; `+progress`, `+watchline` for debugging |
| `sim/programs/m14_smp.S` | the program both processors run |

`make sim` runs `core_smp_tb` with 6 iterations; `make smp` runs its variants (below).

## The board, and whether the proposed wiring works

The wiring asked about:
- **per processor:** /MI, /BR, /BG, /IPL2-0, /RSTI, /RSTO, /IPEND;
- **bussed:** /BB, /TS, /TIP, /TA, /TEA, /TBI, /TCI, /LOCK, /LOCKE, /CIOUT, R/W, SIZ1-0,
  TLN1-0, TM2-0, TT1-0, A31-0, SC1-0, and the data bus;
- **snoop control:** UPA0→SC0 and UPA1→SC1;
- /AVEC grounded on both processors.

**It works with two gates, a few pull-ups, and the software rules below.** Straight as
listed, it fails in two ways that the bench reproduces.

1. **SC needs a gate with SIZ** (`+rawsc` takes it away).
   - A shared copyback page needs U = 10, mark invalid: only one cache may hold a
     shared copyback line, and the reader takes it over (UM 4.5). Wired straight, every
     transfer to the page then asks for mark invalid, including long-word and byte
     ones: locked reads and writes, which are never cached, or a cache-inhibited alias.
   - UM 4.4.3: mark invalid "causes the line to be invalidated after the access, even
     if it is dirty. Alternate bus masters should indicate mark invalid only for line
     reads". A CAS from one processor to a line the other holds dirty sources one long
     word, then drops the whole line. The bench lost a lock's counter this way.
   - The gate turns 10 into 01 (supply or sink, leave dirty) for anything that is not
     a line: SC1 = UPA1 ∧ (SIZ = line), SC0 = UPA0 ∨ (UPA1 ∧ SIZ ≠ line). For writes
     this is UM 4.4.4's "sink data for copyback pages".
2. **MI needs a gate from reset to the processor's first bus cycle** (`+nomigate`
   takes it away).
   - Memory must wait for both MIs negated, and MI is asserted during reset (UM 5.5.2).
     So a processor held in reset stops the other's memory accesses.
   - Ignoring MI while RSTI is asserted is not enough. MI stays asserted after reset
     until the processor's first cycle, and between bus cycles (UM 5.5.2, 7.9.1).
   - A processor let out of reset in the middle of the other's transfer never saw that
     transfer's TS, so it never negates MI for it, and memory waits for ever. The bench
     hit exactly this when CPU 1 was released.
   - The board ignores a processor's MI from its reset until it first drives TS. Until
     then its caches are invalid (reset leaves them so), so there is nothing to
     protect.
3. **The memory controller must update memory from the data a snooper sources** (UM
   4.5; `+nosnarf` takes it away). With mark invalid, the reader's copy is clean, so
   dirty data that is not written to memory is lost when that copy is replaced.
4. **The bussed three-state lines need pull-ups:** /BB, /TS, /TIP, /TA, /TEA, /TBI,
   /TCI, /LOCK, /LOCKE, /CIOUT. SC needs pull-downs to 00, no snoop. The arbiter reads
   /BB, /LOCK and /LOCKE, so their pulls are part of its logic. The manual says nothing
   of pull-ups.
5. **"DQ[0..13]" must be D31-D0.** The 32-bit data bus is bussed: a snooper drives it to
   source and samples it to sink.
6. **/TA is bussed correctly.** A processor that intervenes as a slave drives TA, and
   memory must not answer while MI is asserted.
7. **/AVEC grounded is fine.** UM 7.5.1: "AVEC is only sampled with TA asserted. AVEC
   can be grounded if all interrupt requests are autovectored". Every acknowledge is
   then autovectored (vector 24 + level), and still ends with TA, TEA (spurious) or TA
   with TEA (retry). In RD68041 AVEC reaches only the acknowledge's vector selection.
8. **Pins the list leaves out:** CDIS and MDIS negated, DLE low on both (normal mode at
   reset), one BCLK; PCLK, PST3-0 and JTAG unused.
9. **The board must also provide two things:**
   - **A way for each processor to learn its number:** both fetch the same reset
     vectors. The bench's WHOAMI answers with the processor the arbiter granted, which
     the bench checks against the processor that drove TS.
   - **Interprocessor interrupts:** a register raises the other processor's IPL.
10. **The arbiter must be the corrected one** (`doc/manual-contradictions.md` entry 12).
    `+gapless` gives B and D the printed grants. The bench then sees the address group
    handed from one processor to the other with no clock between, when the losing
    processor was in implicit ownership. It also sees both processors driving TIP at
    once, the old owner's release (specification 39) overlapping the new owner's TS.

### Rules for the software

The board can't enforce these. The bench's program follows them, and they belong in
any operating system for the board.

- **Shared copyback pages: U = 10. Shared write-through pages: U = 01 or 10.** Private
  pages (stacks) can use 00.
- **No snooping before the MMU or a TTR is set:** UPA is 00 until then (UM 5.3.4). Run
  with the data cache off until then, or set a TTR's U bits first.
- **Table searches and line pushes are never snooped** (UPA 00). Page tables must be
  write-through or cache-inhibited, or pushed before they change. A push needs nothing,
  under U = 10's one owner per line.
- **A word that locked transfers update must not also take ordinary stores in a
  copyback page.** A spinlock released by `clr.l` is the usual case.
  - With SC = 01, a locked read is sourced from the other processor's dirty line and
    leaves it dirty. That processor can then store to the word in its cache between the
    locked read and the locked write.
  - The bench saw a release lost exactly so: CPU 1's `clr.l` landed between CPU 0's
    failing CAS read and its write-back of the old value.
  - With SC = 10, the rest of the line is lost instead (rule 1 above).
  - So spinlocks live in write-through or cache-inhibited memory, and the data they
    guard can be copyback.
  - A word changed only by locked transfers (lock-free CAS) can be copyback, even in a
    line whose other words each processor writes through its cache. Its locked reads
    and writes are sourced from and sunk into the other's dirty line, and only the gate
    of rule 1 keeps that line's other words. The bench's phase 4 checks exactly this
    (`+rawsc` must then fail).
  - This is UM 4.5's advice ("shared data should be stored in write-through pages")
    made precise for locked transfers.
- **The instruction cache needs no software:** another processor's write is snooped
  into it (UM Table 4-3, V6). Its own writes still need CPUSHA (UM 4.5).
- **ATCs are per processor.** A page table change needs the other processor to PFLUSH
  (a TLB shootdown by interprocessor interrupt).

## The arbiter

`rd68041_fairarb` is the table in section 6.1 of
`doc/um-7-8-2-1-fairness-arbitration.md`:
- it runs synchronously on BCLK, with the grants registered;
- processor 1 is the bench's CPU 0;
- `use_locke = 0` (`+nolocke`) treats /LOCKE as always negated. The bench uses that
  with retries: a retried last write of a locked sequence would otherwise let the other
  processor in (the corrected text's last paragraph).

## The program

Both processors run `sim/programs/m14_smp.S`. CPU 0 builds the page tables, while CPU 1
is still in reset. The memory map's pages carry the cache modes and U bits above, and
the barrier's own code is in a cache-inhibited page. The phases:

1. **Boot:** the MMU, the caches, CPU 1's release.
2. **Interprocessor interrupts:** ITERS each way, level 5, autovectored (vector 29).
3. **Locks:**
   - CAS and TAS spinlocks around counters in cache-inhibited and in write-through
     memory;
   - around counters in copyback memory, the locks themselves write-through and
     cache-inhibited;
   - lock-free CAS in cache-inhibited and copyback memory.
4. **Coherence:**
   - two counters in one copyback line (false sharing);
   - a producer and a consumer in write-through memory;
   - a CAS word in a copyback line beside each processor's ordinary counter;
   - MOVE16 of a line the other processor holds dirty.
5. **The instruction cache:** CPU 1 runs a routine, CPU 0 rewrites it, and CPU 1 must
   run the new version.
6. **TLB shootdown:** CPU 0 remaps a page and interrupts CPU 1, whose handler runs
   PFLUSHA.
7. **CPUSHA**, then each processor reports it is done.

Each processor counts its own failed checks. The bench then checks memory: every
counter at 2 × ITERS, the interrupt counts, the false-sharing words, the MOVE16 copy,
and the rewritten routine.

## The bus checks

Each is counted, and any count fails the run:
- **contention:** two drivers on a bussed line;
- **turnaround:** the address group handed over with no clock between;
- **gap:** a grant asserted the edge after the other was;
- **owner:** a TS from a processor the arbiter did not grant;
- **atomicity:** the other processor's TS inside a locked sequence;
- **fairness:** a bus request ungranted for 4,000 clocks;
- **busmon:** each processor's own protocol, the existing `rd68041_busmon`.

## Results

`make smp` (FPU=1 and FPU=0) runs these variants, light jobs four at a time:

| Variant | What | Must |
|---|---|---|
| `long` | 32 iterations | pass |
| `retry` | wait states, a retry about every 40 clocks, the arbiter without LOCKE | pass |
| `late` | CPU 1 let out of reset at clock 30,000 or later | pass |
| `gapless` | the printed arbiter's grants | the turnaround caught |
| `nomigate` | memory obeys MI as it is | fail (memory waits for ever) |
| `nosnarf` | memory not updated from sourced data | fail (counts lost) |
| `nosnoop` | every page's U bits cleared | fail (stale reads, a hang) |
| `rawsc` | UPA wired straight to SC | fail (a counter beside a CAS word lost) |

Every variant does what it must, with FPU=1 and FPU=0 (M14, branch `smp_validation`):
- **The runs that must pass** have every bus check at zero.
  - `long`, 32 iterations: 4,536 transfers by CPU 0 and 2,893 by CPU 1; 4,032 grants;
    1,245 locked sequences; 505 transfers answered by the snooping processor, 441 long
    words sourced and the rest sunk.
  - `make sim`'s 6 iterations: 3,190 transfers, 231 locked sequences, 115 snooped
    answers. About 7 s.
- **The runs that must fail** each fail where the missing piece predicts:
  - `nomigate` hangs, memory waiting for CPU 1's MI;
  - `nosnarf` loses false-sharing counts (code $401);
  - `nosnoop` hangs in the locks, after stale reads ($303, $304);
  - `rawsc` loses the counter beside the CAS word ($409).
- **`gapless`:** the address group handed over with no clock between, from implicit
  ownership, and TIP driven by both processors at once.

The FPU change was checked as RTL changes are: `make check` with FPU=1 and FPU=0; cosim;
vectors-all, 13,325; cputest, 17,824; rd-virt's fpsp and virt-linux at M13's step counts
and the same clock counts as before, 0 divergences.

## What it found

- **The wiring needs the SC and MI gates** (above). Both failures are the board's, and
  the core does what the manual says in each.
- **A software rule the manual leaves implicit:** a lock word must not be in a copyback
  page another processor may hold dirty (above).
- **No RTL bug.** One RTL edit, for the simulator only. Two processors in one iverilog 12
  simulation hung at the second instruction. `rd68041_fpu`'s source unpacking called
  the FPU package's functions from an `always_comb`, and the package is shared by both
  instances, so iverilog woke each instance's block from the other's forever. It is the
  known iverilog 12 defect (`doc/coding-standard.md`). The calls are now continuous
  assignments, the same logic.
- **UM 7.8.2.1's F3 shown on the bus:** with the printed grants, the address group and
  TIP change hands with no clock between (`+gapless`).
