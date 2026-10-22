# The checkpoint: what an exception leaves, and what RTE takes back

M5. Everything software can see of the processor's state when an exception is taken —
the stack frames, the special status word, the FSAVE state frames, the vectors — frozen
before the core that produces it is built (M6–M11), so the core is built to it and not the
other way round. The layouts are generated: `tools/ucode/frames.py` writes
`rtl/gen/rd68041_frame_pkg.sv` and the tables at the end of this file from one list, and
`make ucode-check` (in `make check`) fails if either has drifted.

## The model: restart, not continuation

The MC68030 suspended a faulted instruction mid-flight and continued it after RTE from an
internal state in the frame. **The MC68040 restarts** (UM 8.3: "due to the restart
exception model ... the remaining exceptions are regenerated when the current
instruction restarts"). Its access error frame (format $7) holds no internal state — only
what software needs to finish the work the pipeline had committed to and could not do:

- the faulted access (FA, SSW);
- the **pending write-backs** of instructions that had already completed (WB1–WB3);
- for a push fault, the line being pushed (PD0–PD3);
- four continuation bits, for an exception that was to follow (CP, CU, CT) or for MOVEM (CM).

RTE of a format $7 frame with no continuation bit set simply resumes at the stacked PC
(UM 8.4.6.7). This design follows the same model — it is what a pipeline that commits only
at W gives naturally: an instruction that faulted before W changed nothing, and runs again.

### Which instruction the PC names

The instruction executing when the fault was detected (UM 8.2.1;
`doc/manual-contradictions.md` 3). Here that is the oldest instruction that has not
reached W:

- a fault on an **operand read**, or on a store's translation in OF: the instruction that
  made it. It has not completed; RTE runs it again.
- a fault on a **write-back** (a store already past W, waiting in WB2 or WB1, or being
  written): a later instruction. The store's instruction completed at W, and its write is
  in the frame for the handler to finish.
- a fault on a **push**: the instruction whose miss caused it, which has not completed.

### The three write-back slots

UM 2.1 and Figure 2-2 name three holding registers, and the frame's three write-backs are
them:

| Frame | Part (UM 2.1) | Here |
|---|---|---|
| WB3 | the integer unit's, "a temporary holding register (WB3)" | the store a completed instruction left at W, not yet taken by the data memory unit; logical address, register-aligned data |
| WB2 | the data memory unit's, "prior to address translation" | the store the data memory unit has taken and is translating or looking up; logical address, register-aligned data |
| WB1 | the bus controller's, "multiplexes the data to the correct data byte lanes" | the store at the bus unit (a write-through or cache-inhibited write, or the write miss's transfer); physical address, memory-aligned data (Table 8-5) |

On a fault, each slot that holds a write is stacked with its status byte's V set; one that
does not has V clear. The order the handler completes them in is WB1, WB2, WB3 — the order
they were issued. A push fault stacks the line in PD0–PD3 and WB1S clear (UM 8.4.6.3);
WB1A is then the push's physical address, as FA is (UM 8.4.6.4).

### MOVEM: CM

UM 8.4.6.2: when a data access of MOVEM faults, "a stack frame is created with CM set, and
the effective address field contains the calculated effective address", and RTE restarts
MOVEM "using the effective address on the stack (instead of repeating the effective
address calculate operation) if the address mode is PC relative (mode = 111, register =
010 or 011) or indirect with index (mode = 110)" — the modes whose registers MOVEM may
have overwritten. **This design does exactly that**: CM set on any MOVEM data fault, EA
stacked, RTE using it for those modes and recalculating for the rest; "all operand
accesses for the MOVEM that occurred before the faulted access are repeated"
(UM 8.4.6.7). The registers MOVEM loads before the fault are written at W only if the
whole instruction completes, so a restart starts from the architectural values.

### A misaligned access: MA

MA is set when the ATC fault is on the second page of an access that spans two (UM
8.4.6.2); FA is the first byte's address whichever part faulted (UM 8.4.6.4). The access
restarts whole, so "the partial access to the first page always happens twice" (UM 4.1) —
here too.

### The continuation bits

CT, CU and CP mark an exception that was to be taken after the instruction an access error
interrupted (UM 8.3): RTE converts the frame and takes it. CT: "move the words on the
stack an offset of $00–$0B ... to offset $30–$3B, adjusting the stack pointer by +$30 ...
change the stack frame format to $2" and take the trace vector; CU and CP the same with
the F-line and the FP post-instruction vectors (UM 8.4.6.2). Built at M8 (CT) and M11 (CU,
CP).

### Which frame for which exception

| Exception | Frame | PC |
|---|---|---|
| TRAP #n; an interrupt, spurious or uninitialised interrupt | $0 | the next instruction (UM 8.4.1) |
| illegal instruction, A-line, F-line, privilege violation | $0 | the instruction (UM 8.4.1) |
| format error | $0 | the RTE whose frame was refused |
| interrupt, entering the interrupt stack from the master stack | $1 on the interrupt stack, $0 on the master | next instruction (UM 8.4.2) |
| CHK, CHK2, TRAPcc, FTRAPcc, TRAPV, trace, divide by zero | $2, ADDR the instruction's address | next instruction (UM 8.4.3) |
| address error | $2, ADDR the faulted address | the instruction (UM 8.4.3) |
| unimplemented FP instruction (MC68040) | $2, ADDR the calculated \<ea\> | next instruction |
| FP post-instruction (FMOVE to memory) | $3, EA the \<ea\> | next instruction (UM 8.4.4) |
| unsupported FP data type | $0 before the instruction, $3 after it (UM 9.6.2; `doc/oracles.md` has UAE040 making $3 where 9.6.2 says $0 — settled at M11) | |
| any FP instruction on the MC68LC040 | $4, EA and the instruction's PC | next instruction (UM A.5.1) |
| access error | $7 | above |
| reset | none | |

## The FSAVE state frames

UM 9.8: null after reset or an FRESTORE of a null frame until the first non-conditional FP
instruction; idle when nothing is pending; unimplemented (26 words) after an unimplemented
instruction; busy (50 words) after an unsupported data type or an arithmetic exception.
Version $41 throughout. The fields' offsets are below; the bit positions inside their long
words are the M68040FPSP's interface, read from the FPSP source at M11 as `CLAUDE.md`
allows.

## Reset

The part leaves the caches' and ATCs' contents alone at reset (UM 4.1, 3.6.1) and software
must invalidate them; this design clears their valid bits (`doc/microarch.md`, "Storage";
`doc/divergences.md` from M9). Nothing else here depends on reset.

## The tables

<!-- BEGIN GENERATED by tools/ucode/frames.py: edit there, not here -->

### Format $0: four-word, 8 bytes (UM 8.4.1)

| Offset | Bytes | Field | |
|---|--:|---|---|
| +$00 | 2 | SR | the status register, as it was before the exception |
| +$02 | 4 | PC | the program counter (which instruction: UM 8.4, per format) |
| +$06 | 2 | FV | format (15-12) and vector offset (11-0) |

### Format $1: four-word throwaway, 8 bytes (UM 8.4.2)

| Offset | Bytes | Field | |
|---|--:|---|---|
| +$00 | 2 | SR | the status register, as it was before the exception |
| +$02 | 4 | PC | the program counter (which instruction: UM 8.4, per format) |
| +$06 | 2 | FV | format (15-12) and vector offset (11-0) |

### Format $2: six-word, 12 bytes (UM 8.4.3)

| Offset | Bytes | Field | |
|---|--:|---|---|
| +$00 | 2 | SR | the status register, as it was before the exception |
| +$02 | 4 | PC | the program counter (which instruction: UM 8.4, per format) |
| +$06 | 2 | FV | format (15-12) and vector offset (11-0) |
| +$08 | 4 | ADDR | the instruction address (CHK, CHK2, TRAPcc, FTRAPcc, TRAPV, trace, divide by zero), the calculated <ea> (unimplemented FP instruction), or the faulted address (address error) |

### Format $3: floating-point post-instruction, 12 bytes (UM 8.4.4)

| Offset | Bytes | Field | |
|---|--:|---|---|
| +$00 | 2 | SR | the status register, as it was before the exception |
| +$02 | 4 | PC | the program counter (which instruction: UM 8.4, per format) |
| +$06 | 2 | FV | format (15-12) and vector offset (11-0) |
| +$08 | 4 | EA | the calculated <ea> of the FP instruction |

### Format $4: eight-word (MC68LC040 only), 16 bytes (UM A.5.1, A.5.2)

| Offset | Bytes | Field | |
|---|--:|---|---|
| +$00 | 2 | SR | the status register, as it was before the exception |
| +$02 | 4 | PC | the program counter (which instruction: UM 8.4, per format) |
| +$06 | 2 | FV | format (15-12) and vector offset (11-0) |
| +$08 | 4 | EA | the calculated <ea> of the FP instruction, $0 for immediate and register direct |
| +$0C | 4 | PCF | the PC of the faulted FP instruction |

### Format $7: access error, 60 bytes (UM 8.4.6)

| Offset | Bytes | Field | |
|---|--:|---|---|
| +$00 | 2 | SR | the status register, as it was before the exception |
| +$02 | 4 | PC | the program counter (which instruction: UM 8.4, per format) |
| +$06 | 2 | FV | format (15-12) and vector offset (11-0) |
| +$08 | 4 | EA | the calculated <ea> when CM, CT, CU or CP is set |
| +$0C | 2 | SSW | the special status word (below) |
| +$0E | 2 | WB3S | write-back 3 status (low byte; below) |
| +$10 | 2 | WB2S | write-back 2 status |
| +$12 | 2 | WB1S | write-back 1 status |
| +$14 | 4 | FA | the fault address: logical, physical for a push |
| +$18 | 4 | WB3A | write-back 3 address (the integer unit's, WB3) |
| +$1C | 4 | WB3D | write-back 3 data, register aligned |
| +$20 | 4 | WB2A | write-back 2 address (the data memory unit's, WB2) |
| +$24 | 4 | WB2D | write-back 2 data, register aligned |
| +$28 | 4 | WB1A | write-back 1 address (the bus controller's, WB1) |
| +$2C | 4 | WB1D | write-back 1 data, memory aligned; push data LW0 |
| +$30 | 4 | PD1 | push data LW1 |
| +$34 | 4 | PD2 | push data LW2 |
| +$38 | 4 | PD3 | push data LW3 |

RTE accepts, on the MC68040: $0, $1, $2, $3, $7; on the MC68LC040: $0, $1, $2, $3, $4, $7. Any other format is a format error, vector 14.

### The special status word (UM 8.4.6.2)

| Bits | Field | |
|---|---|---|
| 15 | CP | continuation: FP post-instruction exception pending |
| 14 | CU | continuation: unimplemented FP instruction exception pending |
| 13 | CT | continuation: trace exception pending |
| 12 | CM | continuation: MOVEM pending; EA holds its calculated <ea> |
| 11 | MA | misaligned: the ATC fault is on the second page of an access that spans two |
| 10 | ATC | an ATC fault (nonresident, write protected, supervisor only), not a bus error |
| 9 | LK | the faulted transfer was locked |
| 8 | RW | the faulted transfer was a read |
| 7 | X | undefined (written as zero here) |
| 6–5 | SIZE | the original access's size: 00 long, 01 byte, 10 word, 11 line |
| 4–3 | TT | TT1-TT0 of the faulted transfer |
| 2–0 | TM | TM2-TM0 of the faulted transfer |

### A write-back status byte (UM 8.4.6.3)

| Bits | Field | |
|---|---|---|
| 7 | V | a write-back is pending |
| 6–5 | SIZE | its size |
| 4–3 | TT | its TT1-TT0 |
| 2–0 | TM | its TM2-TM0 |

### FSAVE state frames (UM 9.8, Figure 9-10)

| Frame | First long word | Bytes | Fields (offset: what) |
|---|---|--:|---|
| null | $00 $00 | 4 | — |
| idle | $41 $00 | 4 | — |
| unimplemented instruction | $41 $30 | 52 | +$04: CMDREG3B; +$0C: STAG, WBTM66, WBTM1, WBTM0, SBIT; +$10: CMDREG1B; +$14: DTAG, WBTE15; +$18: E1, E3, T; +$1C: FPTS, FPTE; +$20: FPTM 63-32; +$24: FPTM 31-0; +$28: ETS, ETE; +$2C: ETM 63-32; +$30: ETM 31-0 |
| busy | $41 $60 | 100 | +$08: CU_SAVEPC; +$18: WBTS, WBTE 14-0; +$1C: WBTM 65-34; +$20: WBTM 33-2; +$28: FPIARCU; +$34: CMDREG3B; +$3C: STAG, WBTM66, WBTM1, WBTM0, SBIT; +$40: CMDREG1B; +$44: DTAG, WBTE15; +$48: E1, E3, T; +$4C: FPTS, FPTE; +$50: FPTM 63-32; +$54: FPTM 31-0; +$58: ETS, ETE; +$5C: ETM 63-32; +$60: ETM 31-0 |

### Vectors

| Vector | |
|--:|---|
| 0 | reset: initial interrupt stack pointer |
| 1 | reset: initial PC |
| 2 | access error |
| 3 | address error |
| 4 | illegal instruction |
| 5 | integer divide by zero |
| 6 | CHK, CHK2 |
| 7 | FTRAPcc, TRAPcc, TRAPV |
| 8 | privilege violation |
| 9 | trace |
| 10 | A-line |
| 11 | F-line; unimplemented FP instruction; every FP instruction on the MC68LC040 |
| 14 | format error |
| 15 | uninitialised interrupt |
| 24 | spurious interrupt |
| 25 | level 1-7 autovectors (25-31) |
| 32 | TRAP #0-15 (32-47) |
| 48 | FP branch or set on unordered (BSUN) |
| 49 | FP inexact result |
| 50 | FP divide by zero |
| 51 | FP underflow |
| 52 | FP operand error |
| 53 | FP overflow |
| 54 | FP signaling NAN |
| 55 | FP unimplemented data type |

<!-- END GENERATED -->
