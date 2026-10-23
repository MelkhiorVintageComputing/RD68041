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

## Every write finishes before an exception is taken

**UM 8.2.1, 8.4.6.3.** A data access fault "freezes the pipeline", and the writes that
are pending are stacked in the access error frame's write-back slots, for the handler to
complete; other exceptions stack nothing of them.

**What this design does.** Exception processing waits until the data memory unit's write
queue is empty, so every write before the exception reaches memory first, and a format $7
frame's WB3S, WB2S and WB1S always have V clear. The handler that completes the pending
write-backs finds none, which the frame allows; what differs is when the writes reach the
bus. It also keeps the writes' function codes those of the mode they were made in, since
the SR changes only after them. At M10, when a write can itself fault, the write-back
slots get their contents (`doc/checkpoint.md`).

**Checked by:** `core_fault_tb` (the WB status words of four frames).

## Not yet: a write that ends in a bus error, and the format $7 continuations

**UM 8.2.1:** "a bus error on a data write access always results in an access fault
exception". **UM 8.4.6.2, 8.4.6.7:** MOVEM's continuation (CM) and the trace
continuation (CT).

**What this design does until M10.** A write answered with TEA is dropped, with no
exception; a MOVEM whose read faults is restarted from its first transfer, so a MOVEM
whose addressing mode uses a register the list loaded can restart from the wrong address
(the case CM exists for); CT is never set, and RTE of a format $7 frame resumes at its PC
whatever the continuation bits say. These are M10's (`doc/plan.md`).

## An address error during exception processing is a double bus fault

**UM 8.2.2:** "If an address error occurs during the exception processing for a bus
error, address error, or reset, a double bus fault occurs" -- for the other exceptions,
an odd handler address is an address error exception.

**What this design does.** Any fault on the micro-operations of exception processing,
an odd vector included, halts the processor as a double bus fault. Only a vector table
holding an odd handler address for a non-fault exception can tell.

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

## A write's line fill that faults, and pushes that fault, are not reported

**UM 4.6.2:** "if a bus error terminates a push transfer, the processor immediately
takes an exception." **UM 8.2.1:** a write's bus error always does.

**What this design does until M10.** A push answered with TEA is dropped. A copyback
write whose allocating line read faults on its first long word is written through to
memory instead; one whose own bus write faults is dropped (above, "a write that ends in
a bus error"). M10 brings the access error frame's write-back slots, and these with them.
