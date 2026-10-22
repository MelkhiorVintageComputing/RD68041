# AC-specification conformance

Against the AC tables of UM section 11 (the MC68040) and Appendix A (the MC68LC040), as
transcribed in `Inputs/doc/MC68030_Doc_More_Readable/MC68040UM_split/ac-electrical-specifications.csv`.
Specification numbers here are that table's. The tool is `tools/timing/` (its
`README.md` is the map), the recording `sim/tb/rd68041_timing_tb.sv`, and both run
under `make timing`, which is in `make check`.

**Result, at M3:**

- **The MC68LC040 passes at all four grades** -- 20, 25, 33 and 40 MHz -- with 0, 1, 5
  and 5 ns of room on the binding constraint.
- **The MC68040 fails at all three grades, in both buffer columns, on one specification:
  54**, the hold of the mode selects after RSTI negates. It is an open defect in
  `rtl/rd68041_rstctl.sv`, below. Everything else is feasible: 1, 3 and 5.5 ns of room
  at 25, 33 and 40 MHz.
- 43 of the MC68040's 67 specifications are measured and 41 of the MC68LC040's 53; 3 of
  each are **pending** -- they are about logic that does not exist yet, and every run
  says so -- and the rest are not questions about this design, each with its reason.
- Every input is sampled inside its setup and hold window, on the rising edge, at every
  grade: 68 windows per grade.

```
MC68LC040 20 MHz                pads feasible, 41 of 53 measured, 3 pending, 9 not about this design; 0.0 ns of room on the binding constraint
           39 clk.bb_rel->bb.hiz (arb, 40% high, 20.0 ns apart)
           narrowest pad window: bb@F, 3.0 to 3.0 ns (0.0 ns wide)
           => LC040-20 PASS
MC68040 25 MHz, large buffers   pads feasible, 43 of 67 measured, 3 pending, 21 not about this design; 1.0 ns of room on the binding constraint
           39 clk.bb_rel->bb.hiz (arb, 40% high, 16.0 ns apart)
           narrowest pad window: bb@F, 3.0 to 4.0 ns (1.0 ns wide)
           FAIL 54     in.rsti.negate->smp.mode is 39.5 ns (reset, 40% high); it must be at most 2.0
           => 040-25L FAIL: 54
MC68LC040 25 MHz                pads feasible, 41 of 53 measured, 3 pending, 9 not about this design; 1.0 ns of room on the binding constraint
           => LC040-25 PASS
MC68040 33 MHz, large buffers   pads feasible, ...; 3.0 ns of room on the binding constraint
           FAIL 54     in.rsti.negate->smp.mode is 29.5 ns (reset, 40% high); it must be at most 2.0
MC68LC040 33 MHz                pads feasible, ...; 5.0 ns of room on the binding constraint
           => LC040-33 PASS
MC68040 40 MHz, large buffers   pads feasible, ...; 5.5 ns of room on the binding constraint
           FAIL 54     in.rsti.negate->smp.mode is 24.5 ns (reset, 40% high); it must be at most 2.0
MC68LC040 40 MHz                pads feasible, ...; 5.0 ns of room on the binding constraint
           49 smp.bbfree->bb.drive (arb, 40% high, 0.0 ns apart)
           narrowest pad window: bb@R, 9.0 to 14.0 ns (5.0 ns wide)
           => LC040-40 PASS
```

(abridged; every column also prints its input windows and its pending list.) So **`make
check` fails at M3**, on the MC68040's six columns, for that one reason.

## The columns, and the buffers

UM 11.6 prints the MC68040's output limits twice for each grade: for its **large**
buffers, driving a terminated 50-ohm line (note 1), and its **small** buffers, driving an
unterminated 30-ohm line (note 2). The MC68040 chooses per pin group at reset from
IPL2-IPL0 (UM 7.11.1); the MC68LC040 has small buffers only (UM 11.8's note, Appendix A).
An FPGA's pads are neither, and which column a board needs depends on what it replaces.
So the design is judged in **every column there is**, ten:

| | 20 MHz | 25 MHz | 33 MHz | 40 MHz |
|---|---|---|---|---|
| MC68040, large buffers | -- | `040-25L` | `040-33L` | `040-40L` |
| MC68040, small buffers | -- | `040-25S` | `040-33S` | `040-40S` |
| MC68LC040 | `LC040-20` | `LC040-25` | `LC040-33` | `LC040-40` |

For the same grade the large-buffer column is never looser than the small one -- every
output maximum is smaller or equal, every minimum equal, the input tables shared -- so a
large-buffer pass implies a small-buffer pass, and here the two always agree. The
MC68LC040's column is *not* the MC68040's small-buffer one, although UM 11.8 says it
should be: Appendix A prints a different 39 at 33 MHz and a different 40 at 33 and 40 MHz
(`doc/manual-contradictions.md`, 4). Each column is judged as printed.

The MC68040 build (`FPU = 1`) is to be judged in the `040-*` columns and the MC68LC040
build (`FPU = 0`) in the `LC040-*` ones; the bus unit is the same in both, so one
recording serves both.

## Why this is decided rather than measured

An RTL model has no pad delays: every pin of `rd68041_biu` moves exactly on a clock edge.
A limit like "BCLK to Address Valid, 9 to 21 ns" cannot be measured from it. It can be
answered, because every limit is a statement about the same unknowns, the delay from a
clock edge to the pin moving: a **budget** on one delay, `9 <= d[addr] <= 21`, or a
**separation** between two events whose simulated times are constants, `(t_b + d_b) -
(t_a + d_a) >= m`. Both are difference constraints; the system is feasible exactly when
its constraint graph has no negative cycle, and Bellman-Ford's potentials are then a pad
assignment meeting every limit at once. This is RD68031's method, unchanged
(`tools/timing/feasible.py`).

## One grade, two recordings

The separations are measured in clock edges, so a recording is evidence about its own
frequency only: each grade is recorded at its minimum period (specification 5) -- 50, 40,
30 and 25 ns.

And each grade is recorded **twice**: with BCLK high for 40 % and for 60 % of the period,
the two ends of specification 8 (and of 8a and 8b, which are those percentages at each
grade's maximum frequency). Both logs go into one system over the same delay variables.
This matters for one thing: BB, TA and TIP are released on BCLK's **falling** edge
(`rtl/rd68041_late_release.sv`), so their release time moves with the duty cycle while a
board's pads do not. Judging a single 50 % recording would have claimed more
room than a board with a compliant 40/60 clock has: 8 ns instead of 1 at 25 MHz, 8 instead
of 0 at the MC68LC040's 20.

## The binding constraints

### 39, the release of BB, TA and TIP -- every grade but the MC68LC040's 40 MHz

"BCLK to BB, TA, TIP High Impedance": 19 to 28 ns after the rising edge at 25 MHz (and
14-23, 11.5-22 at 33 and 40; 23-33 for the MC68LC040 at 20). The three pins are negated
at a rising edge and released at the next falling edge, so the release comes BCLK's high
time plus the release path's own delay `d` after the edge:

    min(39) <= high + d <= max(39)    for every high time from 0.4 T to 0.6 T

which leaves `d` a window of `max(39) - min(39) - 0.2 T`:

| Column | 39 | high time | window for `d` (bb@F, ta@F, tip@F) |
|---|--:|--:|--:|
| LC040-20 | 23-33 | 20-30 | **3.0 to 3.0** |
| 040-25L/S, LC040-25 | 19-28 | 16-24 | 3.0 to 4.0 |
| 040-33L/S | 14-23 | 12-18 | 2.0 to 5.0 |
| LC040-33 | 14-25 | 12-18 | 2.0 to 7.0 |
| 040-40L/S, LC040-40 | 11.5-22 | 10-15 | 1.5 to 7.0 |

At the MC68LC040's 20 MHz the window has **no width**: with a clock at exactly 40 % and
another at exactly 60 %, a release path of exactly 3 ns meets 39 on both and nothing else
does. The design is feasible there, but only just, and only because the manual's own
numbers happen to fit: 39 is ten nanoseconds wide and 20 % of 50 ns is ten. A board
that knows its clock's duty cycle has more room -- at exactly 50 % it is 8 to 10 ns at
every grade.

This is the cost of having no PCLK. The MC68040 releases these pins from a PCLK edge
(UM 7.1), which does not move with BCLK's duty cycle. A release timed from a clock of
the design's own -- a PLL output at twice BCLK, as the part's PCLK is -- would not move
either; that is a change to the clocking (`CLAUDE.md`, "One clock") and a decision for
M4 or M15, not something M3 makes.

It is also why the pad model gives the release its own delay. Tie it to the rising-edge
delay of the same pin (`make timing TIMOPTS=--tie-edges`) and every column is infeasible:
at 25 MHz the release must come at most 28 - 24 = 4 ns after a 60 % falling edge, and
specifications 12, 14 and 40 hold the same pins to at least 9 ns after a rising one. The
part's own table could not be met by the part under that model either: its release path
is not its output path.

### 49, BB driven only after the other master has let go -- the MC68LC040 at 40 MHz

"BCLK to BB High Impedance (MC68040 Assumes Bus Mastership)", at most 9 ns (11 at the
MC68LC040's 20 MHz): an alternate master may take that long, after the edge on which the
core first sees its BB negated, to stop driving BB. The core starts its transfer **on that
edge** (UM 7.8.1: "after the alternate bus master negates BB, the processor asserts BB"),
so its own BB must not come out before then: **BB's rising-edge pad delay must be at
least 9 ns at every grade**, while every other output may be as fast as specification 12
allows (5.25 ns at 40 MHz). Against the MC68LC040's 40 MHz maximum for BB, 14 ns
(specification 40, as Appendix A prints it), that leaves 9 to 14 ns: the binding
constraint there, 5 ns. Against the MC68040's 16 and 24 it is not binding.

### What the others leave

| Pad | 040-25L | 040-25S, LC040-25 | 040-33L | 040-33S | 040-40L | 040-40S | LC040-20 | LC040-33 | LC040-40 |
|---|---|---|---|---|---|---|---|---|---|
| address group, TS (11, 13, 38) | 9-18 | 9-18 | 6.5-15 | 6.5-15 | 5.25-14 | 5.25-14 | 11.5-23 | 6.5-15 | 5.25-14 |
| data out (18, 19, 20, 21, 17) | 9-20 | 9-20 | 6.5-17 | 6.5-17 | 5.25-16 | 5.25-16 | 11.5-25 | 6.5-17 | 5.25-16 |
| BB (40, 20, 49) | 9-21 | 9-30 | 9-18 | 9-25 | 9-16 | 9-24 | 11.5-35 | 9-23 | 9-14 |
| BR | 9-21 | 9-30 | 6.5-18 | 6.5-25 | 5.25-16 | 5.25-24 | 11.5-35 | 6.5-23 | 5.25-14 |
| MI, TA, TIP | 9-21 | 9-30 | 6.5-18 | 6.5-25 | 5.25-17 | 5.25-24 | 11.5-35 | 6.5-25 | 5.25-24 |

The address group and TS are capped by 38 (their release) rather than 11; the data bus
by 21. **17** -- "BCLK to Data-In High Impedance (Read Followed by Write)", 49 ns at 25
MHz -- is one clock plus min(20) at every MC68040 grade: a slave may hold the data bus
that long after the edge that ends a read, and the core, starting a write back to back on
that edge, drives its data one clock later. It holds the data pad to at least min(20),
which 19 and 20 already do; 11 ns of room at 25 MHz.

## The failure: 54, the mode selects after RSTI

**Specifications 53 and 54** (MC68040 only; the MC68LC040 has no modes to select): CDIS,
MDIS and IPL2-IPL0 are valid from at least 20 ns before RSTI negates (53) to at least 2
ns after (54), measured from RSTI, not from the clock (Figure 11-2, note 3). The core must
capture them inside that window.

`rd68041_rstctl` captures them on every rising edge while its first synchroniser rank
still reads RSTI asserted, so the value kept is the one on the pins **at the edge on
which RSTI is first sampled negated** -- after RSTI has negated, by anything from a
fraction of a nanosecond to a whole clock, since RSTI is asynchronous (UM 7.10: 51 and 52
apply "only if recognition by a specific BCLK rising edge is required"). The testbench
negates RSTI half a nanosecond after a rising edge, and the modes are captured a clock
less half a nanosecond later -- 39.5 ns at 25 MHz, against at most 2. Its comment
says the opposite ("specifications 53 and 54 hold them from 20 ns before RSTI negates to
2 ns after"); the capture does not honour the 2.

**What it costs today: nothing.** Only the normal modes are built, and nothing reads
`mode_mux`, `mode_dle` or `mode_ipl` (`doc/divergences.md`). The failure is real all the
same, and `make timing` reports it rather than hiding it, because the captured values
are wrong for a board that changes its mode selects 2 ns after RSTI.

**Why no rising-edge capture can be right.** Capturing instead on the last edge on which
the pin itself (not the synchroniser) reads RSTI asserted meets 54, but then the capture
can be up to a clock *before* RSTI negates, and 53 only guarantees the modes 20 ns before
it: 39.5 ns early at 25 MHz, 29.5 at 33, 24.5 at 40, all more than 20. Sampling on both
edges halves the gap, but BCLK may be high for 60 % of 40 ns, 24 ns. What meets both is
a capture timed by RSTI itself -- a register clocked by RSTI's negation, or a latch
transparent while it is asserted -- which is what the part's 2 ns hold implies it has.
Either is a second clock or a latch in `rtl/`, against `doc/coding-standard.md`; the
choice between that, and recording 53/54 as a divergence of a mode capture nothing uses,
is left to the design (M3's report). The analysis measures both ends -- RSTI negated just
after an edge and just before one -- so either fix is judged when it comes.

## What is pending

Three specifications and part of two others are about logic that does not exist yet.
`make timing` prints them on every column; none is counted as measured; and each names
the probe or event that will anchor it, so that the analysis **fails** the day the log
holds that evidence and the entry has not been moved.

| Spec | What | Waits for |
|---|---|---|
| 41c | CDIS, MDIS setup, during operation | M9 (caches: CDIS), M10 (MMU: MDIS). Outside reset nothing samples them; at reset they are mode selects, measured by 53 and 54 |
| 41d | IPL2-IPL0 setup | M8: the interrupt logic and IPL's synchroniser. `rd68041_rstctl` reads IPL only as a mode select |
| 42 (part) | CDIS, MDIS, IPL hold | as 41c and 41d; BB's and BG's hold is measured |
| 50 | BCLK to IPEND, PST, RSTO valid | M7 (RSTO, the RESET instruction), M8 (IPEND). PST is stubbed, a constant, and cannot violate it |
| 12 (part) | output hold of IPEND, RSTO | as 50; every bus pin's hold is measured |

## Not about this design

| Spec | | Why |
|---|---|---|
| 1, 2, 3, 4, 4a, 4b, 10 | PCLK and its skew to BCLK | PCLK is not used: the core runs on BCLK alone (`doc/timing-divergences.md`) |
| 6, 7 | BCLK rise and fall time | the system's clock; an RTL model has no edge ramps |
| 9 | frequency stability | the system's oscillator; what the part needs it for is its PLL |
| 26-30 | multiplexed-mode outputs | the multiplexed bus mode is not built (`doc/divergences.md`); the MC68LC040 has none of these |
| 31-37 | DLE-mode inputs | the DLE mode is not built; DLE is sunk |

Output buffer strength itself has no specification of its own: it is the choice of
column.

## What each specification means here

| Spec | Kind | Measured as |
|---|---|---|
| 5, 8, 8a, 8b | the clock | each recording's period, duty cycle, high and low time, against the column |
| 11 | pad | address, TT, TM, TLN, UPA, R/W, SIZ, LOCK, LOCKE, CIOUT valid (`addr.valid`): one pad group, every change on a rising edge |
| 12 | pad (min) | output hold of every rising-edge output: address group, TS, TIP, BB, BR, MI, TA |
| 13, 14 | pad | TS, TIP valid |
| 18, 19 | pad | data out valid, data out hold |
| 20 | pad (min) | going low impedance: address group, TS, TIP, BB, TA, data |
| 21 | pad | data out high impedance after a write or a sourced snoop |
| 38 | pad | address group and TS high impedance on giving up the bus, at the rising edge |
| 39 | separation | from the rising edge whose release register drops to BB, TIP or TA going high impedance at the falling edge after (`clk.*_rel` to `*.hiz@F`) |
| 40, 43, 48 | pad | BR and BB valid; MI valid; TA valid (the core as a snooped slave) |
| 17 | separation, the core's side | a read's last TA edge (`smp.rdend`) to the next write's data driven: at least max(17) |
| 49 | separation, the core's side | the edge the core sees BB free and takes the bus (`smp.bbfree`) to its BB driven: at least max(49) |
| 53, 54 | separation, constant | RSTI negated (`in.rsti.negate`) to the mode capture (`smp.mode`): no earlier than min(53) before, no later than min(54) after; the mode probes prove `smp.mode` is the capture edge |
| 15, 16 | input | read data at the TA edge (`data_read`); a snooped write's data at the core's TA edge (`data_sink`) |
| 22a-22d, 23 | input | TA, TEA, TCI, TBI as master (`ta`, `tea`, `tci`, `tbi`), and memory's TA during a snooped transfer (`ta_snoop`) |
| 24, 25 | input | AVEC on an interrupt acknowledge |
| 41a, 41b, 42 | input | BB and BG, taking the bus from idle |
| 44a-44e, 45 | input | an alternate master's address, SIZ, TT, R/W, SC, on the edge its TS is seen |
| 46, 47 | input | an alternate master's TS |
| 51, 52 | input | RSTI, recognised by a given edge |

## What the testbench records

`sim/tb/rd68041_timing_tb.sv` runs the bus unit with its snooper and the reset controller,
wired as `rd68041_top` wires them, with the request port fed from the testbench (the top
level ties it off until the core exists). Each scenario is logged separately, so that the
pairing rule never reaches from one kind of transfer into another:

| Scenario | What |
|---|---|
| `read` | long words back to back, a byte, a word with a wait state, a long word with two |
| `write` | the same, written |
| `mixed` | read, write, read, write, a line read and a line write, back to back (17) |
| `line` | lines read and written by burst, burst-inhibited (TBI), cache-inhibited (TCI), with a wait state before each long word |
| `error` | TEA on a long word and on a line's third; a retried write; a relinquish and retry (BG negated before the retry) |
| `arb` | BR without BG; BG while another master holds BB, then BB released (49); park; BG taken away during a transfer (38, 39); implicit ownership, left for a transfer and for idle; BG taken away in park; a locked sequence |
| `snoop` | an alternate master: snoop-inhibited, a miss, a clean hit, a dirty line sourced by the core as a line and as a long word (TA and data driven by the core, 39 on TA), a dirty line sunk, a write that misses, a non-snoopable TT; then the bus back to the core |
| `reset` | RSTI in the middle of a transfer (BB and TIP negated, then released); RSTI negated half a nanosecond after a rising edge and half a nanosecond before one (53, 54) |

and then **20 probes**, each run twice (half a nanosecond before and after its edge):
`ta`, `tea`, `tci`, `tbi`, `avec`, `data_read` (the core as master, against a device of
the testbench's own that moves each signal at a chosen instant); `bg`, `bb` (taking the
bus); `snoop_ts`, `snoop_a`, `snoop_siz`, `snoop_tt`, `snoop_rw`, `snoop_sc`,
`data_sink`, `ta_snoop` (an alternate master's transfer, against the stand-in caches of
`sim/models/rd68041_snoopcache.sv`); `rsti`, `mode_cdis`, `mode_mdis`, `mode_ipl`. Every
one of them splits on the rising edge, at every grade and duty cycle. The tightest window
is a 2 ns hold (23, 25, 42, 45, 47, 52), with 1.5 ns left: the probe's own resolution,
not the design, which samples exactly on the edge. The input path's own budget -- the
FPGA's input delay plus its register's setup and hold -- must fit the window the column
prints: as narrow as 3 + 3 ns for read data at 40 MHz (15, 16).

The testbench also counts every change of a core pin that falls anywhere but on a clock
edge (none), and the bus monitor (`sim/models/rd68041_busmon.sv`) checks the protocol in
every scenario.

## Trusting the tool

`python3 tools/timing/feasible.py` runs RD68031's known-answer tests over the solver;
`make timing` runs it first. Three mutations of the bus unit, built in a scratch copy of
`rtl/` (none of them committed), were each caught:

- BB, TA and TIP released at the rising edge instead of half a clock later: they go
  from asserted straight to high impedance, and 12, 40 and 48 fail for want of the
  negation UM 7.10 and Figure 7-32 require.
- MI registered on the falling edge: 12 and 43 fail ("measured from BCLK rising, but
  mi.assert moved on a falling edge"), and the snoop probe that reads MI stops splitting.
- TA, TBI, TCI and data read through a falling-edge register: 15, 16, 22a, 22c, 22d and
  23 fail ("not sampled there").

And the analysis fails a column on anything it cannot measure: a specification with no
events in the log, a pin on the wrong edge, a probe whose two runs agree, a pin moving
off every edge, or a pending entry whose evidence has arrived.
