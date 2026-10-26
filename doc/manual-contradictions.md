# Places the MC68040 manuals disagree with themselves

Each entry: what the two sources say, which one this design follows, and why. Read this
before "correcting" something in the RTL that looks wrong against one reading of the
manual.

Transcription defects -- ones in the *document*, found while splitting it -- are recorded
in the READMEs of `Inputs/doc/MC68030_Doc_More_Readable/`, and Motorola's own errata in
`MC68040UM_split/README.md`. This file is for places where the manual's own *content*
contradicts itself.

*Started fresh at M0.*

---

## 1. Table 7-6 has TIP asserted in park

**Followed: the text -- TIP is negated in park.**

UM 7.8.1: "When it completes the active bus cycle and the external arbiter has not
negated BG, the processor goes back into park, negating BR, TIP, and TS." Table 7-6's
park row: "M68040 asserts BB; arbiter asserts BG; bus is driven with undefined values;
TIP is asserted." The same table gives the active bus cycle row BG *negated*, and the
two rows read as if their BG and TIP columns were exchanged. TIP is "negated during idle
bus cycles if the bus is still granted to the processor" (UM 5.4.2), which is what park
is. `bus_arb_tb` checks TIP negated in park.

## 2. LOCK "drives high before three-stating", and specification 38

**Followed: specification 38 -- LOCK is released with the address group.**

UM 5.3.7: "LOCK drives high before three-stating", and 5.3.8 the same for LOCKE.
Specification 38 releases LOCK and LOCKE with the address, 9 to 18 ns after the rising
edge that gives the bus up (Figure 11-4), while the "negated, then released" pins BB,
TA and TIP have their own specification (39) for it. A LOCK that is asserted at that edge
cannot be both driven high first and released within 38. This design negates LOCK at the
end of a locked sequence, so the bus is normally given up with LOCK already high; when the
arbiter takes BG away in the middle of a sequence (which UM 7.8.1 allows: "the read and
write portions of a locked read-modify-write sequence are divisible"), LOCK is released
at the edge as 38 says.

## 3. The PC in the access error frame

**Followed: UM 8.2.1 -- the instruction executing when the fault was detected.**

UM 8.2.1: "The saved PC value is the logical address of the instruction executing at the
time the fault was detected. This instruction is not necessarily the one that initiated the
bus cycle since the processor overlaps execution of instructions." The table beside the
format $7 frame in UM 8.4.6 says the stacked PC "points to: Next Instruction". UM 8.4.6.7
settles which is meant: with no continuation bit set, RTE "resumes normal instruction
execution" at the stacked PC, so a faulted operand access is retried by running the
instruction again -- which it can be only if the PC is that instruction's. An instruction
whose fault is on a pending write-back has itself completed, and the PC is then whatever
instruction was executing when the write-back faulted, which is the "next instruction" of
the one that issued it; the table describes that case. UAE040 follows 8.2.1
(`doc/oracles.md`). Raised by the M0 UAE040 spike.

## 4. The MC68LC040's output timing is not the MC68040's small-buffer timing

**Followed: each table as printed -- Appendix A for the MC68LC040, section 11 for the
MC68040.**

UM 11.8: "All references to the MC68040 also include the MC68LC040 and MC68EC040. Note
that the MC68LC040 and MC68EC040 only implement the small buffer mode." Read with UM
11.6's two buffer columns, the MC68LC040's output limits should be the MC68040's
small-buffer column at each grade the two share. Appendix A's output table (page A-10;
Appendix B's, page B-14, prints the same for the MC68EC040) agrees with that column
everywhere but three cells:

| Spec | Grade | MC68040, small buffers (11.6) | MC68LC040 (A.6.7) |
|---|---|--:|--:|
| 39, BCLK to BB, TA, TIP High Impedance | 33 MHz | 14 / 23 | 14 / **25** |
| 40, BCLK to BR, BB Valid | 33 MHz | 6.50 / 25 | 6.5 / **23** |
| 40, BCLK to BR, BB Valid | 40 MHz | 5.25 / 24 | 5.25 / **14** |

The 14 is the only valid-time maximum below 16 anywhere in these tables -- the
MC68LC040's other valid times at 40 MHz (11, 13, 14, 43, 48, 50) are 24, and 18 is 26 --
and it is the number specification 38, a high-impedance time, prints at 40 MHz; the 23 at
33 MHz is the number 39 prints for the MC68040 there. They look like cells taken from a
neighbouring row, but the page is printed so (checked against the PDF's text, and the
CSV's own second reading agrees), and nothing says which is meant.

`make timing` judges the MC68LC040 in its own columns, as printed. The 14 ns is not
harmless: with specification 49 holding BB's delay to at least 9 ns, it leaves BB a
window of 9 to 14 ns at 40 MHz, the binding constraint of that column
(`doc/ac-timing.md`). A board built to the MC68040's small-buffer 24 ns would fail it.

## 5. The throwaway frame's SR: M clear, or M set

**Followed: UM 8.4.2 and the MC68030 -- the throwaway frame holds the SR as it was, with
S set (so M is still set).**

UM 8.2.9: "The copy of the SR saved on the throwaway frame has the S-bit set, the M-bit
clear, and the interrupt mask level set to the new interrupt level. It may or may not be
set in the copy saved on the master stack." UM 8.4.2, RTE of that frame: "In most cases,
the throwaway frame is on the interrupt stack, and when the SR value is read from the
stack, the S-bit and M-bit are set. In that case, there is a normal four-word frame on the
master stack." Both cannot hold: RTE loads the throwaway frame's SR and runs again on the
stack it names, and with M clear that is the interrupt stack again, above the throwaway
frame -- not the master stack's frame below the interrupted code. The MC68030's manual
says what the second sentence of 8.2.9 is left over from: "The copy of the status
register saved on the throwaway frame is exactly the same as that placed on the master
stack except that the S bit is set in the version placed on the interrupt stack. (It may
or may not be set in the copy saved on the master stack.)" -- "it" is the S bit. So the
throwaway frame's SR is the master frame's with S set, as on the MC68030, and RTE of it
returns through the master stack (`rd68041_core.sv`, the sequencer's `sr_new`;
`core_exc_tb` (g)).

## 6. FSGLMUL and FSGLDIV: hardware or software; FLOG2: missing from Table 9-10

**Followed: UM Table 9-10 for FSGLMUL and FSGLDIV, which are hardware; the FPSP for
FLOG2, which is unimplemented.**

PRM `instructions-by-cpu.csv` marks FSGLMUL, FSGLDIV and FLOG2 "68040: software (FPSP)".
UM Table 9-10, the list of what the MC68040 does not implement, has neither FSGLMUL nor
FSGLDIV, and has no FLOG2 either, though it lists every other transcendental. The FPSP,
which emulates exactly what the hardware does not, settles both: its dispatch table
(`tbldo.S`) has FSGLDIV ($24) and FSGLMUL ($27) as "illegal extension" -- never sent to
it -- and an FLOG2 entry ($16). So FSGLMUL and FSGLDIV are in hardware, and FLOG2 is
vector 11 with the rest of Table 9-10, which leaving it out was a slip (`doc/fpu.md`).
UAE040 and the cputest corpus agree on both.

## 7. FSGLDIV's operands: truncated to 24 bits, or not

**Followed: neither paragraph alone -- FSGLMUL truncates its operands, FSGLDIV does
not, as UAE040 has them.**

PRM 5, FSGLDIV (and FSGLMUL in the same words): "If either operand requires more than 24
bits of mantissa to be accurately represented, the extraneous mantissa bits are trancated
prior to the division, hence the accuracy of the result is not guaranteed." The next
paragraph: "The accuracy of the result is not affected by the number of mantissa bits
required to represent each input operand since the input operands just change to
extended precision." The corpus (UAE040) truncates FSGLMUL's operands -- all 198 sampled
tests agree with truncation -- and divides FSGLDIV's whole: with them truncated, 59 of
176 FSGLDIV tests came out one unit low in the 24th bit or exact where the corpus has
INEX2. The FPSP cannot settle it (it never sees either). `rd68041_fpu_dp.sv`, the
multiply and divide set-up.

## 8. FMOVEM of the control registers: which modes, which way

**Followed: the addressing-mode tables -- (An)+ and -(An) both ways.**

PRM 5, FMOVEM (control registers): "Memory-to-Register -- Only control addressing modes
or the postincrement addressing mode can be used", and "Register-to-Memory -- Only
control alterable addressing modes or the predecrement addressing mode". The tables
under each sentence list (An)+ *and* -(An), and the description says how each moves
"to or from" memory: "If the addressing mode is predecrement, the address register is
first decremented by the total size of the register images to be moved ... For the
postincrement addressing mode, the selected registers are transferred to or from the
specified address". The single-register FMOVE's tables, whose opcode "is the same", list
both modes both ways too ("all addressing modes" from memory, "alterable" to it). The
decoder followed the sentences until the cputest corpus ran FMOVE FPSR,(A7)+; it follows
the tables now (`rd68041_decode.sv`, opclasses 100 and 101).

## 9. E1 in the unimplemented-instruction frame: always, or for a packed source

**Followed: the field's definition, as the FPSP reads it -- E1 set only for a packed
source.**

UM Table 9-16, "Unimplemented Instruction Exceptions (For Opclass 000 and 010)": "E1 --
Always 1". UM 9.8, the field definitions two pages before it: "E1 -- ... For the
unimplemented instruction state frame, the source operand's unsupported data type is
packed if the E1 bit is set." The FPSP, which CLAUDE.md makes the definition of the
frames' internal fields, reads it the second way: `get_op.S`, on the unimplemented
instruction's path, `btstb #E1,E_BYTE(%a6) | if set, there is a packed operand`, and
then unpacks FPTEMP_LO and ETEMP as a packed number. With E1 always set, a register
FSIN or FATAN is emulated on garbage; Linux's awk printed nothing right. M11 followed the
table and `core_fpu_tb` checked it; M13's rd-virt lockstep found it, the FPSP taking
`pack_source` on the core and not on UAE040 (which sets E1 clear;
`doc/m13-mismatches.md`). `rd68041_fpu.sv`, the frame of an unimplemented instruction.

## 10. Figure 7-35's asterisk: asserted in the states, negated on the arcs

**Followed: the text of UM 7.8.2.1 and note 2 -- "\*" is asserted; the arcs are
corrected to it.** The core has no arbiter, so nothing in `rtl/` depends on this; it
matters to whoever builds a dual-MC68040 board from the example.

Figure 7-35 (UM p. 7-53), the dual MC68040 fairness arbiter, says in its note 2
"\*Indicates the signal is asserted for that device", and its state outputs follow it:
state A, "BG1\*, BG2", grants processor 1. Its ten arc conditions agree with the text
only if "\*" means *negated*: read with note 2, the arbiter leaves A when BR2 is
negated, goes from B to C when BB is asserted, and stays in C while BR1 is asserted --
the opposite of the text's cases 1 to 3. Every signal name in the figure is barred over
its whole length (measured from the PDF's strokes), so the overbars tell no literal from
another and resolve nothing. Figure 7-30 uses "\*" = asserted on its arcs, correctly;
Figure 7-36 has the same conflict as 7-35. Which half is the misprint cannot be told.
Motorola's addendum lists pages 7-52 to 7-58 among its errata only as "contains many
errors in various figures". `doc/um-7-8-2-1-fairness-arbitration.md` (F1) checks every
arc against every input under four readings (`tools/um_figures/um_7_8_2_1.py --check`)
and gives the corrected figure.

## 11. Figure 7-35's state A self-loop lacks an asterisk

**Followed: the mirror image -- state A stays put while a locked sequence has not
asserted LOCKE.**

State A's self-loop is "BR2\* V BR2 Λ LOCK Λ LOCKE"; its mirror image, state C's, is
"BR1\* V BR1 Λ LOCK Λ LOCKE\*", and Figure 7-36's A self-loop also ends "LOCKE\*". As
printed, under any reading of the asterisk, the A self-loop overlaps the A-to-B arc on
one input combination and leaves another with no arc. Under the reading that makes the
rest of the arcs agree with the text (entry 10), the uncovered one is BR2 asserted,
LOCK asserted, LOCKE negated: a locked sequence in progress, the very case (text, case
2) in which the arbiter must stay in A. With the asterisk added, as in C, A is complete
and exclusive. `doc/um-7-8-2-1-fairness-arbitration.md`, F2.

## 12. Figure 7-35 and its text hand the grant over with no edge between

**Followed: UM p. 7-48 -- every grant negated for at least one rising edge of BCLK
between tenures.**

The text of UM 7.8.2.1 (cases 1 and 2: state B, "in which BG1 is negated and BG2 is
asserted") and Figure 7-35's outputs (A and D "BG1\*, BG2"; B and C "BG1, BG2\*") move
the grant from one processor to the other in a single clock: going from A to B, the BG1
pin goes high and the BG2 pin low together, and no rising edge sees both high. UM p.
7-48: "External bus arbiters must be designed so that all bus grants to all bus masters
be nagated for at least one rising edge of BCLK between bus tenures", and the addendum's
General Operation item 4 says the same. The conflict is real, not academic: from
implicit ownership BB is already negated, so processor 2 starts driving the address
group on the edge it sees BG2 asserted (from 9 ns, specification 20) while processor 1,
seeing BG1 negated on that same edge, is still releasing it (to 18 ns, specification 38).
The corrected figure asserts no grant in B and D. `rd68041_biu` behaves as the overlap
needs (it releases on the edge it sees BG negated in implicit ownership, and starts on
the edge it sees BG asserted with BB negated), so a board pairing two of these cores
needs the gap. `doc/um-7-8-2-1-fairness-arbitration.md`, F3, with timing diagrams of
both handovers.
