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
