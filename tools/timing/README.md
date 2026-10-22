# AC-timing analysis

Judges event logs from `sim/tb/rd68041_timing_tb.sv` against the AC tables of UM section
11 (the MC68040, large and small output buffers) and Appendix A (the MC68LC040), in
`Inputs/doc/MC68030_Doc_More_Readable/MC68040UM_split/ac-electrical-specifications.csv`.
Carried over from RD68031's `tools/timing/` and retargeted. `doc/ac-timing.md` is the
account of what it found; this is the map.

```sh
make timing                                    # record and judge, every grade and column
make timing-verbose                            # ... and every column in detail
make timing PADSKEW=2                          # loosen the pad model
make timing TIMOPTS=--tie-edges                # tighten it: one delay per pin, whatever the edge

python3 tools/timing/specs.py --dump --column 040-25L   # the limits of one column
python3 tools/timing/anchors.py                # what each specification measures
python3 tools/timing/anchors.py --unanchored   # what it does not, and why
python3 tools/timing/anchors.py --pending      # what it does not YET, and which milestone will
python3 tools/timing/events.py build/timing-25-40.log   # what a log holds, probes included
python3 tools/timing/feasible.py               # the solver's own self-test
```

| | |
|---|---|
| `specs.py` | the manual as data: the MC68040's 67 specifications and the MC68LC040's 53, and the ten **columns** they are judged in -- MC68040 at 25, 33 and 40 MHz with large and with small buffers (`040-25L` ... `040-40S`), MC68LC040 at 20, 25, 33 and 40 MHz (`LC040-20` ...). Checks specification 5 against each grade's period on load |
| `anchors.py` | which events each specification separates, read off Figures 11-3 to 11-7; where each input must be sampled; what is not about this core (PCLK, the clock's edges, the multiplexed and DLE modes); what is **pending** (IPL, CDIS and MDIS during operation, IPEND, RSTO) and which milestone brings it. Fails if a specification of either part is in no table |
| `events.py` | reads a log; the pairing rule, stated once |
| `feasible.py` | the difference-constraint system, Bellman-Ford, the margin calculation, and a known-answer self-test that `make timing` runs first. Unchanged in substance from RD68031 |
| `analyse.py` | builds one system from a grade's logs, solves it per column, prints the verdict |

## What is different from RD68031's

**The MC68040's bus is synchronous.** Nearly every limit is "BCLK to *pin*" or "*input*
to BCLK", all from the rising edge: pad budgets and sampling windows. The few
separations are where something other than one rising edge is involved: the release of
BB, TA and TIP half a clock after the edge that negates them (39), the processor's side
of two limits on other devices (17, 49), and the mode selects around RSTI (53, 54).

**Columns, not grades.** One recording per grade serves the three columns of that
grade. The large-buffer column is never looser than the small one for the same grade,
but both are judged.

**Two recordings per grade.** Specification 8 lets BCLK's duty cycle be anything from
40 % to 60 %, and this design's one falling-edge register -- the late release of BB, TA
and TIP, `rtl/rd68041_late_release.sv` -- moves with the falling edge. So each grade is
recorded with BCLK high for 40 % and for 60 % of the period, and **both logs go into one
system** over the same delay variables: a board's pads do not change with the clock.
That is the difference between "it works with some clock" and "it works with any clock
the manual allows".

**The pad model.** Each pin transition has a delay variable. The transitions of one pin
launched from the **same edge** are tied (`PADSKEW`, default 0: one delay); the late
release, launched by a falling-edge register through an OR into the pad's enable, gets a
delay of its own. Every delay is at least zero. `TIMOPTS=--tie-edges` ties the release to
the rising-edge delay too, and is infeasible at every grade: 39's maximum minus BCLK's
longest high time is less than the minimum delay 12, 14 and 40 require of the same pin
(at 25 MHz, 28 − 24 = 4 ns against 9). The MC68040 itself releases these pins from a
PCLK edge on a path of its own (UM 7.1: they "transition from a driven state to a
high-impedance state during T1"); a model that ties the two is stricter than the part.

**Pending is a state of its own.** A specification whose logic does not exist yet -- IPL's
synchroniser (M8), CDIS and MDIS during normal operation (M9, M10), IPEND and RSTO (M7,
M8) -- is listed with its milestone and the probe or event that will anchor it. Every run
prints the pending list; a pending specification is never counted as measured and never
fails a column. And it cannot be forgotten: if the log already holds the evidence a
pending entry waits for, the analysis fails and says to anchor it.

**Constant separations** -- both ends inside the core or the testbench, no pad delay at
either -- are judged directly rather than put in the graph, so that one broken constant
(specification 54, at present) does not hide the rest of the system behind a single
negative cycle.

**A pad window per pin.** For each pad the analysis prints the range of delays consistent
with every limit at once (`make timing-verbose`), and the narrowest of them on the summary
line. That range is what a board or an FPGA's I/O constraints must hit; it is more useful
here than a margin, because most of the MC68040's limits are budgets.

## The things worth knowing before changing any of it

These are RD68031's, and still true.

**The limits live here and not in SystemVerilog.** The testbench emits times and nothing
else; no testbench knows what a specification is. A wrong anchor is a one-line edit and a
re-analysis in milliseconds, not a re-simulation.

**Three kinds of event.** A pin of the core (`ts.assert`) has a pad delay, which the
solver chooses. An input as the testbench drives it (`in.rsti.negate`) and an edge inside
the core (`smp.rdend`, the edge a read's last TA is sampled on; `clk.bb_rel`, the edge
BB's release register drops) have none: they are the fixed node `#0`.

**Inputs are probed, not assumed.** The testbench changes each input half a nanosecond
before and half a nanosecond after an edge; if the core behaves differently the two
times, it sampled inside that nanosecond. The analysis checks the nanosecond against the
input's setup and hold window at each grade, and that the edge is the one the manual
names. A probe that does not split fails.

**INFEASIBLE is a proof; FEASIBLE is conditional** on the pad model.

**A bound's margin is not a margin.** The binding constraint is the tightest
*separation*; the pad windows say what the budgets leave.

**Nothing is quietly skipped.** A specification with no events in the log, a pin that
moves on the other edge from the one its specification is measured from, a probe that
does not split, a pin of the core that moves anywhere but on a clock edge (the
testbench counts them), a stale pending entry: each fails the column.
