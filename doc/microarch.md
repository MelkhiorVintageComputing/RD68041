# Microarchitecture

The working design of RD68041's core, refined milestone by milestone; `doc/plan.md`,
section 2, is the summary it started from. Every number here is from the manual unless it
says it is a choice.

## Clocking

One clock, BCLK, rising edge (`doc/coding-standard.md`). At 25–30 MHz that is 33–40 ns a
stage, about twice what a 7-series LUT-and-route stage needs for a 32-bit add, which is
what lets each stage below do a lookup *and* a compare *and* a select in one clock.

## The integer pipeline (UM 2.1)

Six stages, single issue, in order, as the part has. The part's own names are used:

| Stage | Here |
|---|---|
| Instruction fetch | **IF1** computes the fetch address (sequential, or a branch target) and presents it to the instruction cache's RAM and registers it. **IF2** reads the tags and the instruction ATC on that registered address, selects the way, and puts 64 bits (a half-line, UM 4.4.3) into the instruction queue. |
| Decode | **DE** takes the operation word and up to two extension words from the queue head, looks the operation word up in the decoder ROM (generated, `tools/ucode/`), and issues either one simple operation or the first of a micro-sequence. Longer instructions take the rest of their extension words on later clocks. |
| \<ea\> calculate | **EA**: a three-input adder (base + scaled index + displacement). Postincrement and predecrement update an address-register *future file* here, as the part does ("updates that occur in the \<ea\> calculate stage", UM 2.1); it is restored from the architectural file when the pipeline is flushed. |
| \<ea\> fetch | **OF**: the data ATC and the data cache, looked up in parallel on the address EA registered (below), the way selected, the operand aligned and extended. |
| Execute | **EX**: ALU, shifter, bit-field unit, a 32 × 32 multiplier on DSP slices, the iterative divider; condition codes; branches resolved. |
| Write-back | **W**: the architectural register file is written and stores enter the write buffer. Exceptions are taken here, so every instruction before the faulting one has completed and none after it has changed anything architectural. |

## The memory units

### Why the caches and the ATCs run in parallel

The caches are 4 KB, four-way, 64 sets of 16-byte lines (UM 4.1): the set is chosen by
physical address bits 9–4, which lie inside the page offset for both page sizes, so the set
is the logical address's. The tag is physical bits 31–10. The ATC is 64 entries, four-way,
16 sets, indexed by LA15–LA12 for 4 KB pages and LA16–LA13 for 8 KB (UM 3.3). So one
registered logical address can drive, in the same clock:

- the cache's data RAM (registered inside the block RAM: the address is presented on the
  clock before, which is the EA stage's adder output, or IF1's);
- the cache's tags (LUT RAM, read combinationally from the registered address);
- the ATC's tags and entries (LUT RAM, the same).

and the clock ends with the ATC's physical page compared against the four cache tags.

### Storage

| | Where | Why |
|---|---|---|
| Cache data, each way 128 × 64 (a half-line per word) | block RAM, true dual port, byte write enables | port A for the core's reads, port B for fills, pushes, snoops and stores |
| Cache tags, 4 × 64 × 22 | LUT RAM | read combinationally by the core, the snooper and the push logic at three addresses at once |
| Data cache dirty bits, 4 × 64 × 4 | LUT RAM | read with the tags |
| Valid bits, 256 per cache | flip-flops | reset (below), and CINVA clears them in one clock |
| ATC tags and entries, 4 × 16 | LUT RAM | read combinationally |
| ATC valid and global bits, 64 each | flip-flops | PFLUSHA and PFLUSHAN clear them in one clock |

**Reset invalidates the caches and the ATCs here, and the part does not** (UM 4.1: "reset
does not invalidate the cache lines"; UM 4.2: "the CINV instruction must clear the caches
before enabling them"). A valid bit with no reset value is a register initialised outside
reset (`CLAUDE.md`), so these are cleared by reset; software that follows the manual cannot
tell, and software that does not would find stale lines on the part.
`doc/divergences.md`.

### Writes

UM 2.1 and Figure 2-2: a write leaves the integer unit in WB3, is translated by the data
memory unit in WB2 and goes to the bus in WB1 — the three write-back slots of the access
error frame (UM 8). Here the same three: the W stage's store slot (WB3), the data memory
unit's (WB2, translated and looked up), and the bus unit's request (WB1). Reads that come
later may pass a write waiting in WB3 or WB2 except to the same address (UM 7.7: "the
processor detects a read access that references earlier data waiting to be written").

## Micro-operations (M6)

Decode issues one micro-operation a clock (`rd68041_pkg::uop_t`); an instruction is one or
more, the last marked `last`, every one carrying the instruction's address and length. A
micro-operation has at most one effective address and so at most one memory operand:

| | |
|---|---|
| \<ea\> | base (none, An, the PC, or a register), an index (Dn/An, word or long, scaled), a displacement, and an update (`(An)+`, `-(An)`, by 1, 2 or 4 — 2 for a byte on A7) |
| \<ea\> fetch | `ld`: read the operand; `st`: write the result there at write-back; both: a read-modify-write |
| execute | operands A and B, each a register, the immediate, the operand read, or the address itself, a word optionally sign-extended (`a_sxw`, `b_sxw`); an operation; how the condition codes are set; a control transfer (to a target decode computed, to B, or to the operand read) |
| write-back | a register result of a byte, a word or a long word |

Two micro-operations where an instruction has a second address or a push beside its own:
`MOVE <mem>,<mem>` (the source into T0, then T0 to the destination), `PEA` (the address
into T0, then T0 pushed), `JSR` (the target into T0, then the return address pushed and a
jump to T0). The register file holds four temporaries, T0–T3, beside D0–D7 and A0–A7.

Memory indirection (PRM 2.2.8–2.2.10) is a prelude micro-operation that reads the
pointer into T3. A bit field in memory is a sequence: the parameters into T3 and the
field's first byte address into T0; the bytes it covers, one to five, read into T1 and
T2; the operation; and, if it modifies the field, the bytes written back. Its accesses
are sized in \<ea\> calculate from T3, which it reads on the index port (`bfa`,
`bf_bytes`): a byte, a word, a word and a byte, a long word, or a long word and a byte,
never a byte outside the field.

Hazards (`rtl/rd68041_core.sv`):

- **\<ea\> calculate** takes an address register's update from the OF, EX or W stage
  of an older micro-operation that made it, newest first. It waits for a result an older
  micro-operation computes in EX until that one is in W, and takes it from there.
- **execute** reads its operands from the register file and from W. Only W can hold an
  older micro-operation then.
- **\<ea\> fetch** waits for an older write it overlaps that is still in EX or W; the
  data memory unit waits for the ones in its queue (UM 7.7).
- **a taken branch**, resolved in EX, empties decode, \<ea\> calculate and \<ea\>
  fetch, cancelling any read of theirs already on the bus, and restarts fetching.
- **the condition codes** exist twice: EX's, for the next branch, and those write-back
  committed.

## Exceptions (M8)

UM 8.1's model, a restart one: an exception is taken at an instruction boundary, and
everything after it is thrown away and fetched again. Here every exception is taken at
**write-back**, where nothing younger has changed anything architectural
(`rtl/rd68041_core.sv`, `rtl/rd68041_exc.sv`).

**Where each is found.** A micro-operation carries the vector of the exception it takes
(`xvec`) and whether the frame's PC is its own instruction or the next (`xnext`):

| Found in | Exceptions |
|---|---|
| decode | illegal (4), privilege violation (8), A-line (10), F-line (11), TRAP #n (32 + n, after); an instruction a word of which came from a fetch that faulted (2, format $7); a fetch redirected to an odd address (3) |
| \<ea\> fetch | an operand read that ended in a bus error (2, format $7: FA and the SSW ride in the micro-operation's `imm` and `tgt`) |
| execute | divide by zero (5), CHK and CHK2 (6), TRAPcc and TRAPV (7), all after the instruction; RTE's format error (14); a branch to an odd address, or a conditional one with an odd displacement even when not taken (3, UM 8.2.2) |
| write-back | trace (9) after an instruction traced as T1 and T0 were when it began; an interrupt at a boundary, after a trace |

A micro-operation that takes an exception before completing changes nothing; one that
takes it after (the traps) completes first. Write-back then empties the pipeline behind
it and hands over to the exception state machine:

| State | |
|---|---|
| `XS_SR` | waits until every queued write has gone (so the frame never holds a pending write-back, and the function codes of the writes are the old mode's), then, in one clock: the SR changes (S set, T1 T0 cleared, an interrupt's level the mask), A7 is saved to the stack pointer it was and loaded with the frame's address on the one it becomes, and the frame's address is worked out |
| `XS_SEQ` | the sequencer issues, in decode's place, an interrupt's acknowledge (the vector offset into T0), the frame's long words at their absolute addresses, a throwaway frame for an interrupt taken with M set, and the vector fetch, which jumps to the handler. Its end is an instruction boundary: a pending interrupt is taken there (UM 8.3), except after an interrupt's own |
| `XS_STOP` | STOP, until an interrupt |
| `XS_RST` | RESET: RSTO for 512 clocks |

A fault on any of the sequencer's micro-operations is a double bus fault: the core halts.

**The status register's writers are serialising** (`ser`): MOVE, ANDI, ORI and EORI to
SR, RTE, STOP, and also NOP (UM 2.1: it waits for the writes) and RESET. Decode issues
nothing after one until it has left write-back and `XS_SR` has applied it, then fetching
starts again from the next instruction, in the new mode's space. So the SR's system byte
and the stack pointers change only in `XS_SR`, decode reads S and M as they are (for the
privileged instructions and for which supervisor stack pointer MOVEC means), and nothing
needs to be undone.

**The stack pointers.** A7 is the active one; the core holds the other two (USP, ISP,
MSP). Whatever changes S or M swaps them in `XS_SR`. MOVEC of the active one is a plain
register move of A7; of an inactive one, a control register.

**RTE** is four micro-operations: the SR into T0, the PC into T1, the format word, which
checks the format (vector 14) and moves A7 past the frame, and the last, serialising,
which writes the SR and goes to the PC -- or, for a throwaway frame, to the RTE itself,
which runs again on the stack the loaded SR names (UM 8.4.2).

**Interrupts.** IPL2-IPL0 are synchronised and a level is taken once two consecutive
samples agree (UM 7.5.1); it is pending above the mask, or on a transition to 7 until that
is taken. IPEND is that. The acknowledge is a byte read at $FFFFFFFF, TT 11, TM the level:
a vector on D7-D0, AVEC (24 + level) or TEA (24, spurious).

Not yet (M10): a write that ends in a bus error is not reported (the data memory unit
drops it); MOVEM's continuation (CM) and the trace continuation (CT) of a format $7 frame
are neither set nor honoured by RTE -- a faulted MOVEM restarts from its first transfer.
`doc/divergences.md` has these.

## Caches (M9)

**Attributes.** Each memory unit has an `rd68041_attr`: its two transparent
translation registers, matched on A31-A24 and the mode, give an access its cache mode,
UPA and write protection; no match, with translation off, is cachable write-through
(UM 3.1.2, 3.1.3). The ATC's page descriptors join them at M10.

**The instruction cache** (`rtl/rd68041_ifu.sv`). A fetch from a cachable address with
IE set reads the half-line it is in on one clock and compares the four tags on the next;
a hit puts the half-line's words from the fetch address on into the queue (up to four, so
about two words a clock from the cache). A miss reads the line: a burst, the long word
wanted first (UM 4.6.1), into the first invalid way or the one the replacement counter
names (UM 4.1), the way made invalid before the first long word is written to it. The
words in order from the fetch address are queued as they arrive, as far as there is
room; the line is made valid after its fourth long word unless the slave said TCI with
the first or a transfer faulted. A bus error on the first long word puts its words in
the queue marked, as an uncached fetch does (M8); on a later one the fill is abandoned
and done again when the line is next wanted. CINV and CPUSH of the cache (UM 4.2) run
in the exception state machine's `XS_CMO`: all at once, a line by its set, a page by
walking the 256 lines; the snooper invalidates a line a snooped transfer hits
(Table 4-3).

**The data cache** (`rtl/rd68041_dmu.sv`). The cache's port A is addressed with the
address \<ea\> fetch will hold next (the one \<ea\> calculate hands on, or the one it
holds), so a read that fits in a half-line has its data out of the RAM on the clock it is
in \<ea\> fetch; its tags are compared then, and a hit is answered on the next clock --
two clocks of \<ea\> fetch where the part takes one (`doc/timing-divergences.md`).
Everything else goes a piece at a time (each aligned in a long word, as UM 7.3 splits
an operand) through a state machine: a cachable piece's half-line read on port B and
its tags compared; a hit read from or written into the cache (a copyback write setting
the long word's D bit, a write-through one also going to the bus); a miss that allocates
-- a read, a copyback write, neither from exception processing or MOVE16 -- taking the
invalid way or the counter's, pushing it first if it is dirty, then filling it by a
line read; a cache-inhibited, locked, alternate-space or acknowledge piece going to the
bus, after a line the cache holds has been pushed if dirty and invalidated. A push
copies the line into the push buffer and writes it with TM 000, a long word if one long
word is dirty, the line otherwise, and invalidates it; it is done before the fill that
needs the way, where the part does it after (`doc/divergences.md`). The writes queued
from write-back drain through the same machine, a read going first unless it touches
one of them or its page is serialised.

**The snooper** has the data cache's port B, its tags and its dirty bits first in the
clocks it uses them; the state machine waits, and a write that hits waits out any clock
the snooper touches the cache at all, since it decides and writes in one. While a push waits for the bus its line
stays valid and dirty, where the snooper finds it: a sink into it is copied into the push
buffer too, and a snoop that invalidates it cancels the push.

**MOVE16** is a line read of the source into the data memory unit's MOVE16 buffer -- from
the cache if the line is there, else a TT 01 burst from the long word the address names,
not allocated -- and a line write of the destination from it, queued at write-back like
any write, which invalidates a line the cache holds first (UM 4.3.3); then the address
registers that postincrement, by 16, after both transfers so that a fault leaves them
alone. The read waits for every queued write, so the buffer is free when it fills it.

**MOVEC to a control register is serialising**, like the SR's writers: what follows it
sees the caches' enables, the TTRs' modes and VBR as written.

## Status

**M4: measured.** The storage above (`rtl/rd68041_bram.sv`, `rd68041_atc.sv`,
`rd68041_cache_arr.sv`), the register file (`rd68041_regfile.sv`) and the address adder
(`rd68041_agu.sv`) exist, and `make spike` places and routes them, with the shifter and
the bus unit, in the pipeline's arrangement through a harness that is not part of the
design (`sim/spike/`). Every stage's path fits in one clock at 30 MHz with at least 12 ns
to spare (`doc/size-and-speed.md`): OF 21.2 ns, EX into IF1 19.5, IF2 18.9, EX 14.6, EA
13.6. The spike's control is a stand-in, so the margin is what the real control, stalls
and forwarding have to fit in; no stage needs splitting, and the plan's fallback (two OF
stages) is not taken. 30 MHz stays the constraint.

**M6: the walking skeleton runs.** All six stages, uncached and untranslated, for the
instructions `rtl/rd68041_decode.sv` lists: `make cosim` runs `sim/programs/m6_basic.S`
on the core and on UAE040 and compares every register and the SR at every one of its 131
instruction boundaries. About 6.5 clocks an instruction, every fetch and operand a bus
transfer: the caches (M9) are where the pipeline starts to pay.

**M7: the integer instruction set.** Every MC68040 integer instruction that does not
take an exception, in every addressing mode, the full extension-word format and memory
indirection included; locked transfers (CAS, CAS2, TAS) and MOVES. Against UAE040,
`make vectors-all` passes 12,307 vectors with none failing (382 wait for M8, 18 trace
or trap tests for M8 are not built), `make cputest` passes 5,811 of WinUAE's corpus with
none failing (768 wait for M8; MOVE16 is M9's), and `make cosim` runs four programs
register for register (`m6_basic`, `m7_a`, `m7_b`, `m7_c`). `doc/bugs-found.md` has
the defects those found, `doc/oracles.md` the three places UAE040 disagrees with the
manual.

**M8: exceptions.** Every exception of the integer unit but the access faults on a write
(M10): the traps, the illegal, privileged and unimplemented instructions, trace, the
interrupts (vectored, autovectored, spurious, level 7), STOP, RESET, BKPT, RTE of every
MC68040 format and the format error, access faults on instruction fetches and operand
reads (format $7), and the double bus fault. `make vectors-all` runs all 12,707 vectors,
none pending and none failing; `make cputest` runs the corpus in each test's own mode,
exceptions and frames included: 6,649 of the 6,688 sampled pass, none fails, and the 39
not built are MOVE16 (M9); `make cosim` adds `m8_exc` (traps, privilege, trace, the
master stack, throwaway and format-error RTEs); `core_exc_tb` (interrupts, STOP, RESET,
BKPT) and `core_fault_tb` (access faults, the double bus fault) check against the manual
what no oracle runs.

**M9: the caches.** Both caches, write-through and copyback, write-allocate in copyback
mode, the push buffer, CINV and CPUSH by line, page and whole, MOVE16, the TTRs' cache
modes with translation off, CIOUT, TLN and UPA, and snooping into both caches. Against
UAE040, `make cosim` runs `m9_icache`, `m9_dcache` and `m9_move16` with the caches on,
and `make cache` runs the vector sweep and the cputest corpus with them forced on,
write-through and copyback, as well. What is on the bus is checked against the manual by
`core_cache_tb` (fills, write-through, pushes by size, CIOUT, TCI, TAS on a dirty line)
and `core_snoop_tb`: a random alternate master reads and writes memory the program
shares with it, its every transfer snooped -- dirty data sourced, sunk and invalidated --
and both sides' views stay coherent.
