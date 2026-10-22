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
