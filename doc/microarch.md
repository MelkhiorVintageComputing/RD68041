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
