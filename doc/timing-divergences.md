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
  instruction has left write-back (UM 7.5.1: "within one instruction boundary"). It is
  never taken at the end of a serialising instruction, so an SR write followed by a NOP
  -- RD68031's `virt_timer` had one -- takes it at the end of the instruction after the
  NOP, two boundaries late (M13; the program waits in a DBRA loop now).

## The caches (M9)

To be measured at M15; what the design does:

- **A read that hits takes two clocks of \<ea\> fetch**, where the part's data cache
  answers in one: the tags are compared on the clock the read is in \<ea\> fetch and the
  answer registered. Misaligned reads, writes and misses go a piece at a time, a clock or
  two each before any bus transfer.
- **The instruction cache gives a half-line every second clock** -- about two words a
  clock -- where the part's gives one a clock.
- **A miss with a dirty victim pays for the push first** (`doc/divergences.md`).
- **MOVEC to a control register serialises** the pipeline, and so refetches behind it.

## The MMU (M10)

To be measured at M15; what the design does:

- **A write's micro-operation spends a clock more in \<ea\> fetch** when translation or
  a data TTR is on: it waits for its probe, which an ATC hit answers on the next clock,
  as a read's cache hit is answered (`doc/microarch.md`, "The MMU"). With both off a
  write is not probed and costs what it did.
- **A table search is a sequence of the data memory unit's own operations**, each a
  long-word access through its state machine (a clock or two before each bus transfer),
  with the U and M updates as separate writes or a locked read-modify-write after the
  read that found them clear. The part pipelines a pointer descriptor's U write behind
  the next read (UM Figure 3-10's note); this design makes it after that read too, but
  does not overlap the two.
- **PTEST and PFLUSH serialise**, and wait for the write queue to empty first.

## The FPU (M11)

The data path's clocks (BCLK) from start to its answer, measured on
`rd68041_fpu_dp` alone with normal extended operands -- the first of them the clock its
inputs are registered on, which keeps the operand selection out of the operation's
first step (M11's critical path, `doc/size-and-speed.md`) -- against the sum of UM
10.7.3's conversion, execution and normalisation stages (PCLK, an idle FPU, register
operands):

| Operation | Here | UM 10.7.3 |
|---|---|---|
| FMOVE, FABS, FNEG (to a register) | 4 | 2 |
| FADD, FSUB | 6 | 2 + 3 + 2 |
| FMUL, FSGLMUL | 8 | 2 + 5 + 2 |
| FDIV, FSGLDIV | 72 | 2 + 37.5 + 2 |
| FSQRT | 71 | 2 + 103 + 2 |
| FCMP | 2 | 2 + 3 + 1 |
| FMOVE to an integer (the conversion) | 3 | 3 |

Around it, what the design adds and the part does not:

- **No overlap.** An FP instruction holds the integer pipeline at execute until the data
  path answers, and the next FP instruction waits until the previous one has committed at
  write-back (`doc/fpu.md`). The part overlaps integer instructions with an FP one and
  has three FP stages in flight, so FDIV and FSQRT followed by integer code cost their
  full latency here and almost nothing on the part.
- **Divide and square root are a bit a clock** (restoring). With PCLK twice BCLK the
  part's FDIV is about 21 bus clocks and its FSQRT about 54: here FDIV takes about 3.4
  times as long, FSQRT 1.3 times, FADD (3.5 bus clocks on the part) 1.7 times.
- **A memory operand is a load a long word**, each a micro-operation through \<ea\>
  fetch, and an FMOVE to memory a store a long word after the conversion; FMOVEM moves a
  long word a clock, three per data register.
- **FSAVE and FRESTORE move one long word a micro-operation**: a busy frame is 25.

To be measured instruction by instruction against UM section 10 at M15 (`make cycles`).
