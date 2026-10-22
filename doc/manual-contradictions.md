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
