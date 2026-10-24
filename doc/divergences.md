# Where this design does not behave as the part does

Every standing difference between RD68041 and a real MC68040 or MC68LC040, why it is
there, and how it is checked. Cycle-count differences live in
`doc/timing-divergences.md`; this file is for behaviour.

*Started fresh at M0.*

---

## The data bus is not driven in park or implicit ownership

**UM 7.8.1.** In implicit ownership "the processor drives its output pins with
undetermined values and three-states BB"; in park it "keeps BB asserted and drives the
bus with undefined values".

**What this design does.** In both states it drives the address bus and the transfer
attributes, with TS and TIP negated, and leaves the data bus released. Which pins "the
bus" covers is not spelled out, and a data bus driven outside a transfer is the one
choice that can fight a slave late in releasing it (specification 17 gives a slave up to
49 ns at 25 MHz to release the data bus after a read). Nothing that follows the protocol
can tell: the values are undefined either way, and no transfer is in progress.

**Checked by:** `bus_arb_tb` (park and implicit ownership).

## Only the normal bus and data-latch modes are built

**UM 7.11.** CDIS low at reset selects the multiplexed bus mode, MDIS low the DLE mode,
and the IPL levels at reset the output buffer strengths. This design builds the normal
modes only: `rd68041_rstctl` records what was asked for (`mode_mux`, `mode_dle`,
`mode_ipl`) and nothing reads it. The MC68LC040 has none of the three modes (Appendix A),
so for `FPU = 0` this is exact. Buffer strength has no meaning inside an FPGA.

## The mode selects are recorded, not met

**Specifications 53 and 54.** CDIS, MDIS and IPL2–IPL0 are valid from 20 ns before RSTI
negates to 2 ns after, and the part latches them there (UM 7.10).

**What this design does.** `rd68041_rstctl` captures them on the rising edge on which its
first synchroniser rank sees RSTI negated, which can be up to a clock after RSTI negates
(39.5 ns at 25 MHz, measured by `make timing` at M3). A synchronous design cannot do
better: the window is timed from RSTI's own, asynchronous edge and is narrower than a
clock, and a register clocked by RSTI would be a second clock domain. Nothing depends on
the result -- the modes are not built (above) and the captured levels are only reported --
so `tools/timing/anchors.py` lists 53 and 54 as not about this design, with this entry as
the reason. A board that relies on a mode select must hold it for a clock after RSTI.

## The writes before an exception are made before it is taken

**UM 8.2.1, 8.4.6.3.** A data access fault "freezes the pipeline", and the writes that
are pending are stacked in the access error frame's write-back slots, for the handler to
complete; other exceptions stack nothing of them.

**What this design does.** An exception, or a serialising instruction, waits in
write-back until the data memory unit's write queue is empty, so every write before it
reaches memory first; an interrupt or a trace, taken at a boundary, waits in `XS_SR`
for the writes of the instruction before it. A format $7 frame therefore has write-backs
pending only when one of those writes is itself what faulted (below, "A write's bus
error"). The handler that completes write-backs finds none otherwise, which the frame
allows; what differs is when the writes reach the bus. It also keeps the writes'
function codes those of the mode they were made in, since the SR changes only after them.

**Checked by:** `core_fault_tb` (the WB status words of the read and fetch faults).

## A write's access fault is taken before the write

**UM 8.2.1, 8.4.6.3, 8.4.6.7.** The part makes a write after the instruction has executed;
when its translation fails, the write is one of the frame's pending write-backs, for the
handler to complete once it has mapped the page. UAE040 stacks such a write in WB3
(`doc/oracles.md`).

**What this design does.** With translation or a data TTR on, every write is translated
in \<ea\> fetch first, by a probe (`doc/microarch.md`, "The MMU"), and a fault there is
taken as a read's is: the frame's PC is the instruction's, RW is clear, FA, SIZE, TT and
TM are the write's, no write-back is pending, and RTE restarts the instruction, its
registers put back as for any access fault (the undo log). A handler that maps the page
and returns sees the write made by the instruction's second run. What differs:

- an instruction that wrote memory before the write that faulted (MOVEM to memory, a
  write to a second operand) makes those writes again;
- the search the probe makes sets the page's M before the write is made, so an
  exception that comes between them -- a later access of the same instruction that
  faults -- leaves M set on a page the instruction did not write.

A write that faults after its probe passed -- only if the tables changed under it -- is
dropped. **Checked by:** `core_mmu_tb` (the write to a write-protected page), `make
cosim` (`m10_mmu`).

## Reset clears the ATCs

**UM 3.7.4:** "The assertion of RSTI disables translation by clearing the E-bits ... but it
does not flush the ATCs."

**What this design does.** Reset clears every entry's valid bit (ASIC: nothing has a
value it was not given at reset). Software must flush after a reset anyway, as the
manual says; what it cannot do is rely on an entry surviving one.

## A table search finds a cached descriptor with the cache disabled

**UM 3.2.1:** "If table descriptors are allocated in the data cache and the cache is
disabled, the processor locks up trying to access a cached descriptor during a table
search."

**What this design does.** With DE clear the search's accesses go to memory, as every
other access does, and see what memory holds (not a dirty line's newer data); nothing
locks up. With DE set they read a line the cache has, never allocating one, and write
through a line they hit.

## A write's bus error is taken on what is in write-back

**UM 8.2.1:** "a bus error on a data write access always results in an access fault
exception, causing the processor to begin exception processing immediately"; the saved
PC is "the instruction executing at the time the fault was detected".

**What this design does.** A write is made from the write queue after its instruction
has completed. When it ends in a bus error -- its transfer, the line read a copyback
write miss allocates (on the long word wanted), MOVE16's line write -- the queue
freezes, and the access fault is taken on the next micro-operation to reach write-back,
which does not complete: its instruction is the frame's PC, its registers are put back
by the undo log, and RTE runs it again. The faulted write is WB1 (memory aligned, its
physical address; for MOVE16 WB1S is clear and the line is in PD0-PD3), the two queued
behind it are WB2 and WB3 (register aligned, logical addresses) and are not made: the
handler completes them, in that order (`doc/checkpoint.md`). Which instruction the PC
names depends on how far the pipeline had got, as on the part. Differences:

- the reads made while the fault is pending -- for instructions that will not complete
  -- are made, their data discarded, and made again when the instruction runs again;
- an interrupt or a trace waiting for the writes of the instruction before it is
  replaced by the access fault, at the same PC: the interrupt is taken after the
  handler returns, as it is still pending; the trace of that instruction is lost (the
  part sets CT and takes it after the RTE, UM 8.4.6.2).

**Checked by:** `core_fault_tb` (h)-(k).

## The format $7 continuation bits are never set

**UM 8.4.6.2, 8.4.6.7:** MOVEM's continuation (CM), the trace continuation (CT), and the
floating-point ones (CP, CU).

**What this design does.** None is ever set, and RTE of a format $7 frame resumes at its
PC whatever they say. A MOVEM that faults restarts from its first transfer with every
register it loaded put back (the undo log), so its effective address is calculated from
what it was -- the case CM exists for cannot arise. CT: above. CP and CU are M11's.

## An address error during exception processing is a double bus fault

**UM 8.2.2:** "If an address error occurs during the exception processing for a bus
error, address error, or reset, a double bus fault occurs" -- for the other exceptions,
an odd handler address is an address error exception.

**What this design does.** Any fault on the micro-operations of exception processing,
an odd vector included, halts the processor as a double bus fault -- a bus error on one
of the frame's writes too, whenever it comes back. Only a vector table holding an odd
handler address, or a stack that faults, for a non-fault exception can tell.

## Format error and odd PC on RTE

**UM 8.4:** "If during restoration, a stack frame has an odd address PC and an SR that
indicates user trace mode enabled, then an address error is taken. The SR stacked for
the address error has the SR S-bit set."

**What this design does.** RTE to an odd PC completes (the SR and the stack pointer are
restored) and the fetch from the odd address is the address error, with the odd address
as the frame's PC and its address less bit 0 as ADDR (UM 8.4.6.7), whatever the trace
bits.

## CDIS does not disable the caches

**UM 4.2:** "System hardware can assert the cache disable (CDIS) signal to dynamically
disable both caches, regardless of the state of the enable bits in the CACR. ... CDIS is
intended primarily for use by in-circuit emulators."

**What this design does.** CDIS is sampled at reset, for the multiplexed-bus mode select
(`rd68041_rstctl`), and otherwise ignored: only CACR's IE and DE enable the caches.

## A dirty line is pushed before the fill that replaces it

**UM 4.3.1.2, 4.6.2:** "the dirty line being replaced is temporarily placed in a push
buffer while the new line is fetched from memory. ... After the bus transfer for the new
line successfully completes, the dirty cache line is copied back to memory." A fill that
is cache-inhibited or faults puts the dirty line back.

**What this design does.** The push is written first, then the line is filled: the bus
sees the push before the line read, and the latency of the miss includes the push. With
the push done, a fill that fails has nothing to restore; the line is left invalid, which
memory, now holding its data, agrees with. While the push waits for the bus the line
stays in the cache, valid and dirty, and is snooped there (`doc/microarch.md`).

## MOVES bypasses the data cache

**UM 4.3:** an access's caching mode comes from its page or TTR, whatever its function
code.

**What this design does.** A MOVES read or write is treated as a cache-inhibited access:
a line the cache holds is pushed if dirty and invalidated, and the transfer goes to the
bus. The data it reads and leaves is the same; what differs is that MOVES never hits the
cache and never allocates.

## A push that faults is not reported

**UM 4.6.2:** "if a bus error terminates a push transfer, the processor immediately
takes an exception", the line in PD0-PD3 (UM 8.4.6.6).

**What this design does.** A push answered with TEA is dropped: the line is invalidated
as if it had been written, and its dirty data is lost. A push is a copyback line leaving
the cache for memory that took it before, so a bus error there is a failure of the
memory system, which software does not recover from; the frame for it, its write-backs
and the order against the queued writes are not built. A copyback write whose allocating
line read faults is reported (above, "A write's bus error").

## Where the manual leaves the FPU a choice

The MC68040's FPU (UM 9) leaves several behaviours open. In each the core does what
UAE040 does (it is the only oracle that runs FP code), so that a program behaves the same
under both. A real part may do otherwise in any of them; none is a case the FPSP or
IEEE-conforming code depends on.

| UM | Left open | The core |
|---|---|---|
| Table 9-1 | PREC = 11, "Undefined" | rounds to double |
| 9.7.4.2, 9.7.5.2 | overflow and underflow to a register: "either a pre-instruction or a post-instruction exception" | post-instruction, at once, format $3, T clear (E3, or E1 for FMOVE, FABS, FNEG) |
| 9.7.4.2, 9.7.5.2 | the condition codes after a trapped overflow or underflow | those of the result the FPSP stores: Table 9-12's; the denormalised result |
| 9.7.5 | INEX2 with an underflow | the denormalised result's inexactness |
| 9.7.3.2, 9.7.4.2 | "an undefined result is stored" by FMOVE out on an operand error or an overflow | an integer saturated; a single or double gets Table 9-12's value |
| 9.6.2 | (An)+ and -(An) of an FMOVE.P out, which always traps | stepped over the twelve bytes, the frame's EA the destination |

**Checked by:** the cputest FPU corpus and `m11_fpu_b` (`make cputest`, `make cosim`).

## Where the manual leaves the MC68LC040 a choice

UM A.5.1 says what the format $4 frame holds, not how every mode's address is formed,
and it says nothing of when a part ends a "legal" FP instruction's decode. The core does
what UAE040 `-L` does where the manual is silent, and what the manual says where UAE040
does otherwise (`doc/oracles.md`, "The MC68LC040 against UAE040 -L"):

| UM A.5.1 | Left open | The core |
|---|---|---|
| "the calculated effective address of the operand" | -(An) | the operand's address, An less its size; for FMOVEM, the control registers' FMOVE(M), FSAVE and FRESTORE, An itself |
| | (An)+ and -(An) | An not stepped |
| | no \<ea\> (FBcc, FTRAPcc, FMOVECR, register to register, FDBcc) | 0, as for a register or an immediate |
| "all legal ... floating-point instructions" | the encodings PRM 5 has no instruction for | F-line illegal, format $0, as on the MC68040 (UM 9.6.1) |
| | a privileged one (FSAVE, FRESTORE) in user mode | a privilege violation, vector 8, first |

**Checked by:** `make cosim-lc`, `make vectors OP=lc040 FPU=0` and `core_lc040_tb`.

## A nonserialised cache-inhibited read is made once, as a serialised one is

**UM 4.3.2:** "If the CM field indicates serialized, then the sequence of read and write
accesses to the page is guaranteed to match the sequence of the instruction order ...
Serialization forces operand read accesses for an instruction to occur only once by
preventing the instruction from being interrupted after the operand fetch stage.
Otherwise, the instruction is aborted, and the operand is accessed when the instruction
is restarted."

**What this design does.** A read of a cache-inhibited page -- serialised (CM 10) or
not (CM 11) -- or a locked one does not start until the instructions before it have
completed, so no interrupt and no mispredicted branch can discard its instruction after
the read; it is made once. The manual promises that for CM 10 only. Mac OS 7.6.1 on the
Quadra maps its SCSI pseudo-DMA register (`$50F50000`) CM 11 and reads it, a FIFO,
four or thirty-two long words at a time with interrupts enabled: a read made twice loses
a word of the disk and the boot stops (M14, `doc/bugs-found.md`). What it costs is a
cache-inhibited read's overlap with the instructions before it -- I/O reads only.
Reads may still pass queued writes on a CM 11 page, as UM 7.7 allows. **Checked by:**
`core_ser_tb`, `make quadra`.
