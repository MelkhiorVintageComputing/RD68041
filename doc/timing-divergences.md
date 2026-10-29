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
MC68040. UM section 10 counts in BCLK all the same, and `make cycles` measures the
integer instructions against it (below).

## The integer instructions (M15)

**Not identical.** UM section 10 counts in BCLK ("All timings are related to BCLK cycles",
UM 10.1), so the comparison is direct. `make cycles` measures 142 instruction and
addressing-mode cases from UM 10.4-10.6. 31 take what the part takes, 72 are faster and
39 slower. The MC68LC040 build (`make cycles FPU=0`) gives the same table, clock for clock.

**How it is measured** (`tools/cycles/cycles.py`, `sim/tb/core_cycles_tb.sv`):
- Each case is 16 copies of the instruction in a straight line, or of a pair that must go
  together (BSR and RTS, LINK and UNLK).
- Each case runs three times, under UM 10.1's assumptions:
  - every access hits the caches: DTT0 and ITT0 make everything cachable, the data
    copyback, and the last pass is the one counted;
  - accesses are aligned;
  - the bus is granted, and memory has no wait states.
- "Here" is the clocks from the first copy's retirement to the last's, divided by 15. It is
  the rate in a run of copies, each copy using the registers the one before it left.
- "UM, a run" is what the part would take in the same run. In such a run \<ea\> calculate
  and execute overlap, and an instruction's lead time overlaps its calculate time (UM
  10.1, Figure 10-2). So the part's rate is the larger of the calculate time and the
  execute stage's base time; for a pair, the sum over its two instructions.
- Copies that address memory use the same location every time, except the
  postincrement and predecrement forms.

**Why they differ**, by cause:
- **Faster:**
  - **EX does in one clock what the part does in several**: a 32 × 32 multiplier on DSP
    slices (MULS/MULU, 1 against 14 to 20), a barrel shifter (ASL/ASR/LSL/LSR/ROL/ROR/
    ROXL, 1 against 2 to 5), and the BCD, bit and bit-field operations on a register (1
    or 2 against 2 to 6).
  - **\<ea\> calculate's three-input adder** takes the indexed and the base-displacement
    modes in one clock, and memory indirection adds one prelude micro-operation. A run of
    loads by (d8,An,Xn) takes 1 clock (UM: 3), by (d8,PC,Xn) or (bd,An,Xn) 1.4, the rate
    the instruction fetch gives them (UM: 5 and 7); one through a memory-indirect mode, 4
    (UM: 10 to 12).
  - **Several instructions don't serialise here**:
    - CHK, CHK2 and CMP2 in bounds;
    - TRAPcc and TRAPV not taken;
    - MOVE USP, both ways;
    - MOVEC reading a control register.

    Each takes 1 to 4 clocks, where the part interlocks its stages (5 to 13).
  - **CAS and TAS (An)** take 17 against 36 and 26: a locked read and write to memory
    with no wait states, and no table search.
  - **A conditional branch not taken** costs 1 clock: the fetch went on in sequence
    anyway (UM: 3).
- **Slower:**
  - **A run of writes goes at the data memory unit's rate: 2 clocks a write.** Writes
    drain from the write queue through the unit's state machine: the translation and
    half-line read, then the tag compare and the write. While one write compares its tag,
    the next in the queue starts its translation, and a write's probe in \<ea\> fetch runs
    beside the writes draining (`doc/microarch.md`, the data cache). A run of stores takes
    2 clocks a store, where the part takes 1 (3 for the indexed mode, so faster there).
    - MOVEM.L of four registers to memory takes 12 (UM: 6).
    - MOVE16 takes 24. The UM gives 7, plus 8 for each successive one (its note d), so 15
      in a run.
  - **A read-modify-write of memory takes 4**, the part 1 to 3: ADD, ADDI, ADDQ, NOT, BSET
    or LSL to (An). The read is answered from the write queue: the write the copy before
    made to the same long word is still queued, and holds every byte the read wants (UM
    7.7 lets a read be answered from data waiting to be written). What remains is the
    \<ea\> fetch stage waiting for the write in execute and write-back to reach the
    queue. A read the queued write covers only in part still waits for it to drain.
    Instructions that read and write memory through two micro-operations take 4.4 to 7.8
    a copy (UM: 2 to 4):
    - MOVE (An),(An);
    - the -(Ay),-(Ax) forms of ABCD, SBCD, ADDX, SUBX, PACK and UNPK.
  - **A taken branch costs 8 clocks** (UM: 2). It is resolved in EX, which empties decode,
    \<ea\> calculate and \<ea\> fetch and restarts fetching at the target, through IF1,
    IF2 and the instruction queue. The part fetches the target earlier. The same cost
    applies to:
    - BRA, DBcc and JMP: 8 (UM: 2 to 3);
    - BSR or JSR with RTS: 16 and 17.5 (UM: 7 and 8);
    - LINK with UNLK: 8 (UM: 5). Each also writes or reads the stack.
  - **The divider is a bit a clock.** DIVS.L and DIVU.L take 35 against 44, but DIVU.W
    takes 35 against 27.
  - **Instruction fetch gives about two words a clock** (the caches, below). A run of
    six-byte instructions, a long immediate, takes 1.4 clocks (UM: 1).
- **The serialising instructions take about what the part takes.** ANDI and ORI to the
  SR, MOVE to the SR, MOVEC to a control register and NOP take 8.4 to 8.9 (UM: 7 to 9).
  They wait for the pipeline and the write queue to empty and refetch behind themselves
  (below).

The measurements, BCLK. Where UM 10 gives T1/T2 (an immediate or a register count or
bit number, a word or a long word), the form measured is the one shown. A pair's columns
give each instruction's figures, separated by ";":

| Instruction | UM \<ea\> calc. | UM execute | UM, a run | Here | Here − UM |
|---|---|---|---|---|---|
| MOVE.L Dn,Dn | 1 | 1 | 1 | 1 | = |
| MOVE.L (An),Dn | 1 | 1 | 1 | 1 | = |
| MOVE.L (An)+,Dn | 1 | 1 | 1 | 1 | = |
| MOVE.L -(An),Dn | 1 | 1 | 1 | 1 | = |
| MOVE.L (d16,An),Dn | 1 | 1 | 1 | 1 | = |
| MOVE.L (d16,PC),Dn | 3 | 2L+1 | 3 | 1 | -2 |
| MOVE.L (xxx).L,Dn | 1 | 1 | 1 | 1.40 | +0.40 |
| MOVE.L #<xxx>,Dn | 1 | 1 | 1 | 1.40 | +0.40 |
| MOVE.L (d8,An,Xn),Dn | 3 | 3 | 3 | 1 | -2 |
| MOVE.L (d8,PC,Xn),Dn | 5 | 1L+4 | 5 | 1.40 | -3.60 |
| MOVE.L (bd,An,Xn),Dn | 7 | 1L+6 | 7 | 1.40 | -5.60 |
| MOVE.L ([bd,An,Xn]),Dn | 10 | 1L+9 | 10 | 4 | -6 |
| MOVE.L ([bd,An,Xn],od),Dn | 11 | 1L+10 | 11 | 4 | -7 |
| MOVE.L ([bd,An],Xn),Dn | 11 | 3L+8 | 11 | 4 | -7 |
| MOVE.L ([bd,An],Xn,od),Dn | 12 | 3L+9 | 12 | 4 | -8 |
| MOVE.L Dn,(An) | 1 | 1 | 1 | 2 | +1 |
| MOVE.L Dn,(An)+ | 1 | 1 | 1 | 2 | +1 |
| MOVE.L Dn,-(An) | 1 | 1 | 1 | 2 | +1 |
| MOVE.L Dn,(d16,An) | 1 | 1 | 1 | 2 | +1 |
| MOVE.L Dn,(xxx).L | 1 | 1 | 1 | 2 | +1 |
| MOVE.L Dn,(d8,An,Xn) | 3 | 3 | 3 | 2 | -1 |
| MOVE.L #<xxx>,(An) | 1 | 1 | 1 | 2 | +1 |
| MOVE.L (An),(An) | 1 | 1 | 1 | 4.40 | +3.40 |
| MOVE.L (An)+,(An)+ | 2 | 1L+1 | 2 | 4.40 | +2.40 |
| MOVE.L (An),(d16,An) | 2 | 1L+1 | 2 | 4.40 | +2.40 |
| MOVE.L (d8,An,Xn),(d8,An,Xn) | 8 | 8 | 8 | 4.40 | -3.60 |
| MOVEA.L (An),An | 1 | 1 | 1 | 1 | = |
| MOVEQ | 1 | 1 | 1 | 1 | = |
| ABCD Dy,Dx | 1 | 3 | 3 | 1 | -2 |
| ABCD -(Ay),-(Ax) | 3 | 1L+3 | 3 | 7.80 | +4.80 |
| ADDX.L Dy,Dx | 1 | 1 | 1 | 1 | = |
| ADDX.L -(Ay),-(Ax) | 3 | 1L+2 | 3 | 4.60 | +1.60 |
| ANDI #<xxx>,CCR | 1 | 4 | 4 | 1 | -3 |
| ANDI #<xxx>,SR | 9 | 1L+8 | 9 | 8.93 | -0.07 |
| Bcc.W, taken (BRA) | 2 | 2 | 2 | 7.87 | +5.87 |
| Bcc.W, not taken | 3 | 3 | 3 | 1 | -2 |
| BSR.W + RTS | 2+5 | 1L+1 ; 5 | 7 | 16.07 | +9.07 |
| CMPM.L | 3 | 1L+2 | 3 | 2 | -1 |
| DBcc, false, count > -1 | 3 | 3 | 3 | 7.87 | +4.87 |
| EXG Dy,Dx | 1 | 1 | 1 | 1 | = |
| EXG Ay,Ax | 2 | 1L+1 | 2 | 1 | -1 |
| EXT.W | 1 | 2 | 2 | 1 | -1 |
| EXT.L | 1 | 1 | 1 | 1 | = |
| EXTB.L | 1 | 1 | 1 | 1 | = |
| LINK + UNLK | 3+2 | 2L+1 ; 1L+1 | 5 | 8 | +3 |
| MOVE USP,An | 3 | 2L+1 | 3 | 1 | -2 |
| MOVE An,USP | 7 | 1L+6 | 7 | 1 | -6 |
| MOVE16 (Ax)+,(Ay)+ | 6 | 1L+7 | 7 | 24 | +17 |
| MOVEC Rc,Rn (VBR) | 11 | 1L+10 | 11 | 1 | -10 |
| MOVEC Rn,Rc (VBR) | 7 | 1L+6 | 7 | 8.93 | +1.93 |
| MOVEP.W Dn,(d16,An) | 11 | 2L+9 | 11 | 4 | -7 |
| MOVEP.L Dn,(d16,An) | 13 | 2L+11 | 13 | 8 | -5 |
| MOVEP.W (d16,An),Dn | 4 | 2L+5 | 5 | 2 | -3 |
| MOVEP.L (d16,An),Dn | 8 | 2L+8 | 8 | 4 | -4 |
| NOP | 8 | 1L+7 | 8 | 8.53 | +0.53 |
| ORI #<xxx>,CCR | 1 | 4 | 4 | 1 | -3 |
| PACK Dx,Dy,# | 1 | 3 | 3 | 1 | -2 |
| PACK -(Ax),-(Ay),# | 3 | 2L+3 | 3 | 4.93 | +1.93 |
| SBCD Dy,Dx | 1 | 3 | 3 | 1 | -2 |
| SUBX.L Dy,Dx | 1 | 1 | 1 | 1 | = |
| SWAP | 1 | 2 | 2 | 1 | -1 |
| TRAPcc, not taken (TRAPF) | 5 | 5 | 5 | 1 | -4 |
| TRAPV, not taken | 5 | 5 | 5 | 1 | -4 |
| UNPK Dx,Dy,# | 1 | 4 | 4 | 1 | -3 |
| UNPK -(Ax),-(Ay),# | 3 | 2L+4 | 4 | 6 | +2 |
| ADD.L Dn,Dn | 1 | 1 | 1 | 1 | = |
| ADD.L (An),Dn | 1 | 1 | 1 | 1 | = |
| ADD.L (An)+,Dn | 1 | 1 | 1 | 1 | = |
| ADD.L -(An),Dn | 1 | 1 | 1 | 1 | = |
| ADD.L (d16,An),Dn | 1 | 1 | 1 | 1 | = |
| ADD.L (d16,PC),Dn | 3 | 2L+1 | 3 | 1 | -2 |
| ADD.L #<xxx>,Dn | 1 | 1 | 1 | 1.40 | +0.40 |
| ADD.L (d8,An,Xn),Dn | 3 | 3 | 3 | 1 | -2 |
| ADD.L (bd,An,Xn),Dn | 7 | 1L+6 | 7 | 1.40 | -5.60 |
| ADD.L ([bd,An,Xn]),Dn | 10 | 1L+9 | 10 | 4 | -6 |
| ADD.L Dn,(An) | 1 | 1 | 1 | 4 | +3 |
| ADD.L Dn,(d16,An) | 1 | 1 | 1 | 4 | +3 |
| ADDA.L Dn,An | 1 | 2 | 2 | 1 | -1 |
| ADDA.L (An),An | 1 | 2 | 2 | 1 | -1 |
| ADDI.L #<xxx>,Dn | 1 | 1 | 1 | 1.40 | +0.40 |
| ADDI.L #<xxx>,(An) | 1 | 1 | 1 | 4 | +3 |
| ADDQ.L #,Dn | 1 | 1 | 1 | 1 | = |
| ADDQ.L #,An | 1 | 1 | 1 | 1 | = |
| ADDQ.L #,(An) | 1 | 1 | 1 | 4 | +3 |
| ASL.L #,Dn | 1 | 3 | 3 | 1 | -2 |
| ASL.L Dn,Dn | 1 | 4 | 4 | 1 | -3 |
| ASR.L #,Dn | 1 | 2 | 2 | 1 | -1 |
| LSR.L Dn,Dn | 1 | 3 | 3 | 1 | -2 |
| LSL.W (An) | 1 | 2 | 2 | 4 | +2 |
| ROL.L #,Dn | 1 | 3 | 3 | 1 | -2 |
| ROXL.L #,Dn | 1 | 5 | 5 | 1 | -4 |
| BCHG #,Dn | 1 | 3 | 3 | 1 | -2 |
| BCHG Dn,Dn | 1 | 4 | 4 | 1 | -3 |
| BSET #,(An) | 1 | 3 | 3 | 4 | +1 |
| BTST #,Dn | 1 | 1 | 1 | 1 | = |
| BTST Dn,(An) | 1 | 2 | 2 | 1 | -1 |
| BFCHG Dn{#:#} | 3 | 6 | 6 | 2 | -4 |
| BFCHG (An){#:#} | 9 | 2L+8 | 9 | 10 | +1 |
| BFEXTU Dn{#:#},Dn | 1 | 4 | 4 | 2 | -2 |
| BFEXTU (An){#:#},Dn | 9 | 2L+7 | 9 | 6 | -3 |
| BFFFO Dn{#:#},Dn | 3 | 6 | 6 | 2 | -4 |
| BFINS Dn,Dn{#:#} | 2 | 5 | 5 | 2 | -3 |
| BFTST Dn{#:#} | 1 | 3 | 3 | 2 | -1 |
| CAS.L Dc,Du,(An) | 36 | 6L+31 | 36 | 17 | -19 |
| CHK.L Dn,Dn (in bounds) | 8 | 1L+7 | 8 | 1 | -7 |
| CHK2.L (An),Dn (in bounds) | 11 | 2L+9 | 11 | 2 | -9 |
| CLR.L Dn | 1 | 1 | 1 | 1 | = |
| CLR.L (An) | 1 | 1 | 1 | 2 | +1 |
| CMP.L Dn,Dn | 1 | 1 | 1 | 1 | = |
| CMP.L (An),Dn | 1 | 1 | 1 | 1 | = |
| CMPA.L Dn,An | 1 | 1 | 1 | 1 | = |
| CMPI.L #<xxx>,Dn | 1 | 1 | 1 | 1.40 | +0.40 |
| CMP2.L (An),Dn (in bounds) | 13 | 2L+11 | 13 | 2 | -11 |
| DIVU.W Dn,Dn | 8 | 27 | 27 | 35 | +8 |
| DIVS.L Dn,Dn | 9 | 44 | 44 | 35 | -9 |
| DIVU.L Dn,Dn | 9 | 44 | 44 | 35 | -9 |
| JMP (d16,PC) | 3 | 2L+1 | 3 | 7.87 | +4.87 |
| JSR (An) + RTS | 3+5 | 2L+1 ; 5 | 8 | 17.47 | +9.47 |
| LEA (An),An | 1 | 1 | 1 | 1 | = |
| LEA (d16,PC),An | 4 | 3L+1 | 4 | 1 | -3 |
| LEA (d8,PC,Xn),An | 5 | 1L+4 | 5 | 1.40 | -3.60 |
| MOVE CCR,Dn | 1 | 2 | 2 | 1 | -1 |
| MOVE Dn,CCR | 1 | 2 | 2 | 1 | -1 |
| MOVE SR,Dn | 2 | 1L+2 | 2 | 1 | -1 |
| MOVE Dn,SR | 9 | 1L+8 | 9 | 8.40 | -0.60 |
| MOVEM.L 4 Dn,(An) | 2+4 | 1L+1+4 | 6 | 12 | +6 |
| MOVEM.L (An),4 Dn | 3+4 | 1L+2+4 | 7 | 7 | = |
| MULS.W Dn,Dn | 1 | 16 | 16 | 1 | -15 |
| MULU.W Dn,Dn | 1 | 14 | 14 | 1 | -13 |
| MULS.L Dn,Dn | 1 | 20 | 20 | 1 | -19 |
| MULU.L Dn,Dn | 1 | 20 | 20 | 1 | -19 |
| NBCD Dn | 1 | 3 | 3 | 1 | -2 |
| NEG.L Dn | 1 | 1 | 1 | 1 | = |
| NOT.L (An) | 1 | 1 | 1 | 4 | +3 |
| PEA (An) | 2 | 1L+1 | 2 | 3 | +1 |
| Scc Dn (ST) | 1 | 2 | 2 | 1 | -1 |
| Scc (An) (SEQ) | 1 | 2 | 2 | 2 | = |
| SUBA.L Dn,An | 1 | 1 | 1 | 1 | = |
| TAS Dn | 1 | 2 | 2 | 1 | -1 |
| TAS (An) | 26 | 2L+24 | 26 | 17 | -9 |
| TST.L Dn | 1 | 1 | 1 | 1 | = |
| TST.L (An) | 1 | 1 | 1 | 2 | +1 |

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

What the design does; the hits' cost is in the integer instructions' table (above),
misses are still to be measured:

- **A read that hits takes one clock of \<ea\> fetch**, as on the part, when it can be
  released to execute before its answer (M15; `doc/microarch.md`, the data cache): the
  tags are compared on the clock the read is in \<ea\> fetch, and execute has the answer
  on the next. A read that cannot be released -- with a write in its way in the queue,
  or while the data unit is busy, or locked, alternate-space or MOVE16 -- takes two.
  Misaligned reads, writes and misses go a piece at a time, a clock or two each before
  any bus transfer.
- **A read of bytes a queued write holds is answered from the write queue** (M15), at
  a hit's cost, without waiting for the write to drain.
- **The instruction cache gives a half-line every second clock** -- about two words a
  clock -- where the part's gives one a clock.
- **A miss with a dirty victim pays for the push first** (`doc/divergences.md`).
- **MOVEC to a control register serialises** the pipeline, and so refetches behind it.

## The MMU (M10)

What the design does; the integer instructions' table (above) is measured with a TTR on,
so its writes include their probes, and table searches are still to be measured:

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
