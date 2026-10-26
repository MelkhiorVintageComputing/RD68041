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

**It works, with one gate on MI and a few pull-ups.** Between UPA and SC it can be built
two ways (below), and each asks something different of the software. As listed, with
nothing added, it hangs as soon as the second processor leaves reset (1).

### What every setup needs

1. **MI needs a gate from reset to the processor's first bus cycle** (`+nomigate`
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
2. **The bussed three-state lines need pull-ups:** /BB, /TS, /TIP, /TA, /TEA, /TBI,
   /TCI, /LOCK, /LOCKE, /CIOUT. SC needs pull-downs to 00, no snoop. The arbiter reads
   /BB, /LOCK and /LOCKE, so their pulls are part of its logic. The manual says nothing
   of pull-ups.
3. **"DQ[0..13]" must be D31-D0.** The 32-bit data bus is bussed: a snooper drives it to
   source and samples it to sink.
4. **/TA is bussed correctly.** A processor that intervenes as a slave drives TA, and
   memory must not answer while MI is asserted.
5. **/AVEC grounded is fine.** UM 7.5.1: "AVEC is only sampled with TA asserted. AVEC
   can be grounded if all interrupt requests are autovectored". Every acknowledge is
   then autovectored (vector 24 + level), and still ends with TA, TEA (spurious) or TA
   with TEA (retry). In RD68041 AVEC reaches only the acknowledge's vector selection.
6. **Pins the list leaves out:** CDIS and MDIS negated, DLE low on both (normal mode at
   reset), one BCLK; PCLK, PST3-0 and JTAG unused.
7. **The board must also provide two things:**
   - **A way for each processor to learn its number:** both fetch the same reset
     vectors. The bench's WHOAMI answers with the processor the arbiter granted, which
     the bench checks against the processor that drove TS.
   - **Interprocessor interrupts:** a register raises the other processor's IPL.
8. **The arbiter must be the corrected one** (`doc/manual-contradictions.md` entry 12).
   `+gapless` gives B and D the printed grants. The bench then sees the address group
   handed from one processor to the other with no clock between, when the losing
   processor was in implicit ownership. It also sees both processors driving TIP at
   once, the old owner's release (specification 39) overlapping the new owner's TS.

### What the snoop control does to a line

The U bits of the master's page, through UPA and SC, decide what the other processor's
data cache does (UM Table 4-4):

| | Clean line | Dirty line |
|---|---|---|
| Read, SC 01 (leave dirty) | V9: kept | D9: sourced, kept dirty |
| Read, SC 10 (mark invalid) | V10: invalidated | D10: sourced, then invalidated |
| Write, SC 10 (invalidate) | V11: invalidated | D11: invalidated, its dirty data dropped |
| Write, SC 01, not a line (sink) | V12: invalidated | D12: sunk into the line, kept dirty |
| Write, SC 01, a line | V13: invalidated | D13: invalidated |

The instruction cache only sees writes: a snooped write hit invalidates its line (UM
Table 4-3, V6). Snooped reads leave it alone (V4).

So:
- With U = 01, a shared line can sit clean in both caches. A copyback write is then a
  cache hit with nothing on the bus, so the other copy goes stale. **U = 01 must never
  be used on a shared copyback page.**
- With U = 10, a read takes the line away from the other cache, clean or dirty, so at
  most one data cache holds it. That is UM 4.5's "only one processor at a time can cache
  the data". The cost: no read sharing, and the line moves on every miss.

### Setup A: UPA straight to SC, every shared page write-through

The wiring as listed, with the MI gate.

**Board:** nothing between UPA and SC. Memory need not take the data a snooper sources:
a snooped line is never dirty, so nothing is ever sourced.

**Software:**
- **Every page that two processors use is write-through, with U = 01.** Both caches can
  hold its lines for reading (V9), and every write goes to the bus and invalidates the
  other's copy (V12, V13). This is UM 4.5's recommendation ("shared data should be
  stored in write-through pages").
- **Copyback only for pages private to one processor, with U = 00** (not snooped).
  "Private" must hold for good. Before a page passes to the other processor (a thread
  that migrates, a page freed and reused, a buffer handed over), its owner pushes it
  (CPUSH), or the other reads stale memory.
- **Never a shared copyback page.** With U = 01 it is incoherent (above). With U = 10, a
  long-word or byte access, such as a locked CAS or TAS or an access through a
  cache-inhibited alias, asks for mark invalid. That drops the other processor's dirty
  line after one long word: UM 4.4.3 says alternate masters "should indicate mark
  invalid only for line reads". The bench's `rawsc` run shows the loss.
- And the rules common to both setups (below).

The bench runs this setup as `straight`: `+wtshared` (page 6 write-through, U = 01, like
every other shared page), `+rawsc`, `+nosnarf`. It passes, and no transfer is ever
answered by the snooping processor.

### Setup B: an SC gate with SIZ, and memory updated from sourced data

**Board:**
- **A gate:** SC1 = UPA1 ∧ (SIZ = line), SC0 = UPA0 ∨ (UPA1 ∧ SIZ ≠ line). Mark invalid
  (10) passes for line transfers only, and becomes supply or sink, leave dirty (01), for
  anything smaller. That is UM 4.4.3's rule for reads, and UM 4.4.4's "sink data for
  copyback pages" for writes.
- **The memory controller writes the data a snooper sources into memory too** (UM 4.5).
  With mark invalid the reader's new copy is clean, so if memory missed the dirty data,
  it would be lost when that copy is replaced (`+nosnarf`).

**Software:** everything setup A allows, and also **shared copyback pages with U = 10.**
Each line has one owner at a time, and moves between the caches on every miss. They
come with their own rule:
- **A word that locked transfers update must not also take ordinary stores in a
  copyback page.** A spinlock released by `clr.l` is the usual case.
  - The locked read is sourced from the other processor's dirty line and leaves it
    dirty (the gate makes it SC 01). That processor can then store to the word in its
    cache between the locked read and the locked write.
  - The bench saw a release lost exactly so: CPU 1's `clr.l` landed between CPU 0's
    failing CAS read and its write-back of the old value.
  - So spinlocks live in write-through or cache-inhibited memory; the data they guard
    can be copyback.
  - A word changed only by locked transfers (lock-free CAS) can be copyback, even in a
    line whose other words each processor writes through its cache. Its locked reads
    and writes are sourced from and sunk into the other's dirty line, and the gate keeps
    that line's other words. The bench checks exactly this, and `+rawsc` loses them.

Setup B is what the bench runs by default. It buys copyback for shared data at the cost
of the gate, the memory update, the lock rule, and lines that never stay put. Setup A
is simpler, and is the setup UM 4.5 recommends.

### Rules for the software, in both setups

The board can't enforce these.

- **No snooping before the MMU or a TTR is set:** UPA is 00 until then (UM 5.3.4). Run
  with the data cache off until then, or set a TTR's U bits first.
- **Table searches and line pushes are never snooped** (UPA 00). Page tables must be
  write-through or cache-inhibited, or pushed before they change.
- **ATCs are per processor.** A page-table change needs the other processor to PFLUSH
  (a TLB shootdown, by interprocessor interrupt).
- **The instruction cache:** another processor's write is snooped into it (V6). Its own
  writes still need CPUSHA (UM 4.5).
- **Lock words in write-through or cache-inhibited memory, naturally aligned.** The
  addendum also advises cache-inhibited memory for semaphores: a locked access that
  hits a dirty line asserts LOCK during the push (General Operation item 7). A
  write-through line is never dirty, so that does not happen there.
- **Anything accessed concurrently without a lock must be naturally aligned:** lock
  words, lock-free counters and flags, the data a seqlock-style reader reads. The
  addendum's "misaligned reads of shared memory and snoop invalidation" (General
  Operation item 9):
  - A misaligned read that spans two lines takes its first part from the first line.
  - A snooped write from the other processor invalidates the second line, and the
    second part then comes from memory, new. The operand is half old, half new.
  - Every setup has this exposure. A snooped write invalidates a clean line under SC 01
    as well as SC 10 (V11 to V13), and a write-through line is always clean.
  - The cache doesn't cause it either. A noncachable misaligned operand is "a sequence
    of aligned accesses" (UM 7.3), not locked, and the other processor can have the bus
    between them.
  - On a two-processor MC68040 board, a misaligned operand that spans two lines is
    never atomic against the other processor's writes.
  - The addendum's workarounds are aligned shared accesses, or shared data accessed by
    one master at a time under aligned semaphores.
  - Code that synchronises is therefore unaffected, misaligned or not. Only an
    unsynchronised misaligned read racing a write tears: a data race, as C and POSIX
    call it.
  - The kernel can keep its own shared data aligned. User code gets the usual
    multiprocessor rule.
  - The bench shows both sides. A long word across two write-through lines, read while
    the other processor rewrites it, is sometimes torn: 37 of the `long` run's reads,
    counted but not an error. Under a lock it never is, which is checked.

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
   - a misaligned long word across two write-through lines, read while the other
     processor rewrites it (torn reads counted, not an error) and under a lock (never
     torn: checked);
   - MOVE16 of a line the other processor holds dirty.

With `+wtshared` the copyback shared page (page 6) is write-through with U = 01, like
every other shared page: setup A's policy. The same tests then run on write-through
lines.
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
| `straight` | setup A: UPA wired straight, no memory update, every shared page write-through | pass |
| `gapless` | the printed arbiter's grants | the turnaround caught |
| `nomigate` | memory obeys MI as it is | fail (memory waits for ever) |
| `nosnarf` | memory not updated from sourced data | fail (counts lost) |
| `nosnoop` | every page's U bits cleared | fail (stale reads, a hang) |
| `rawsc` | setup B's program, UPA wired straight to SC | fail (a counter beside a CAS word lost) |

Every variant does what it must, with FPU=1 and FPU=0 (M14, branch `smp_validation`):
- **The runs that must pass** have every bus check at zero.
  - `long`, 32 iterations: 6,250 transfers by CPU 0 and 4,067 by CPU 1; 5,504 grants;
    1,723 locked sequences; 507 transfers answered by the snooping processor, 444 long
    words sourced and the rest sunk; 37 torn racing reads.
  - `straight`: no transfer answered by the snooping processor; 14 torn racing reads.
  - `make sim`'s 6 iterations: 3,810 transfers, 319 locked sequences, 117 snooped
    answers, 7 torn racing reads. About 7 s.
  - No misaligned read under a lock was ever torn.
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

- **The wiring needs the MI gate** in every setup, and the SC gate (with the memory
  update) only if shared data is to be copyback (setups A and B, above). Each failure
  is the board's; the core does what the manual says in each.
- **A software rule the manual leaves implicit:** in setup B, a word that locked
  transfers update must not take ordinary stores in a copyback page (above).
- **The addendum's misaligned-read erratum applies to every setup**, and is not the
  cache's doing: two-line misaligned operands are never atomic between two processors.
  Data accessed without a lock must be aligned (above).
- **No RTL bug.** One RTL edit, for the simulator only. Two processors in one iverilog 12
  simulation hung at the second instruction. `rd68041_fpu`'s source unpacking called
  the FPU package's functions from an `always_comb`, and the package is shared by both
  instances, so iverilog woke each instance's block from the other's forever. It is the
  known iverilog 12 defect (`doc/coding-standard.md`). The calls are now continuous
  assignments, the same logic.
- **UM 7.8.2.1's F3 shown on the bus:** with the printed grants, the address group and
  TIP change hands with no clock between (`+gapless`).
