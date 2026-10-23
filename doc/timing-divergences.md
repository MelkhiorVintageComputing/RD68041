# Where this core takes a different number of clocks

`CLAUDE.md`: instruction cycle timings need not match a real MC68040, but **every
divergence must be measured, reported and justified**. Bus *timing* is a different
matter and is not negotiable -- that is `doc/bus-timing-compliance.md` and
`doc/ac-timing.md`.

*Started fresh at M0.*

---

## The core runs at BCLK, not PCLK

**UM 5.** The MC68040's integer unit, FPU and caches are clocked by PCLK, "exactly
twice the frequency of BCLK"; the bus is referenced to BCLK's rising edge. This
design has a single clock domain, BCLK, and ignores the PCLK input: the FPGA target
cannot close the core at 50 MHz, and every AC specification is referenced to BCLK.
Per bus clock the core can therefore do at most half the internal work of a real
MC68040. `make cycles` (from M15) measures what that costs, instruction by
instruction, against UM section 10.

## Exception processing and the serialising instructions (M8)

Not yet measured against UM section 10 (M15's `make cycles`); what the design adds, so
that the measurement has something to explain:

- **An exception waits for every queued write** before the SR changes (`XS_SR`,
  `doc/microarch.md`), then issues its frame as two, three or fifteen long-word writes
  and the vector read through the ordinary pipeline, one micro-operation a clock; an
  interrupt adds its acknowledge cycle first. The part overlaps these (UM 8.1: the
  stacking cycles "are not guaranteed to occur in the order in which they are
  described").
- **The SR's writers, NOP and RESET serialise**: nothing after one issues until it has
  left write-back and the SR has changed, and fetching starts again behind it. UM 8.2.6
  says the part refetches after an SR write too ("the processor must prefetch
  instruction words again to fill the pipeline any time an instruction that modifies the
  SR is executed"); the drain of the pipeline in front of it is this design's.
- **An interrupt is taken at the boundary after the one where it became pending** when
  an SR write is what lowered the mask, since the SR changes only after the serialising
  instruction has left write-back (UM 7.5.1: "within one instruction boundary").
