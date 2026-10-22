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

## 3. The MC68LC040's output timing is not the MC68040's small-buffer timing

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
