# What the bus unit does on the pins

The clock-by-clock behaviour of `rtl/rd68041_biu.sv` (with `rtl/rd68041_snoop.sv` and
`rtl/rd68041_late_release.sv`) and `rtl/rd68041_rstctl.sv`, against UM section 7's
descriptions and figures, with the test that checks each. This is the document to argue
with when a behaviour is questioned. Where the design differs from the manual, it says
so here; `doc/ac-timing.md` is the nanosecond-level account (`make timing`), and
`doc/bus.md` the contract with the units above.

As of M3. The edges below are numbered from E0, the rising edge on which the transfer's
TS is asserted; "at E*n*" means a register changes on that edge and the pin follows one
pad delay later -- "during the first half of" the clock that begins there, in UM 7's
words. Every edge-level statement in this file is also visible in the event logs
`make timing` writes (`build/timing-*.log`, `python3 tools/timing/events.py`).

## The ruler

UM 7.1: "all timing specifications are referenced to [the rising edge of BCLK]". Every
register in the bus unit is a rising-edge register, and every output pin is one of them,
or a fixed function of them with no input in between (the testbench counts pin changes
off the clock edges: there are none). Every bus input -- TA, TEA, TBI, TCI, AVEC, BG, BB,
and when snooping TS, A, SIZ, TT, R/W, SC and D -- is sampled on the rising edge with no
synchroniser (UM 7.1: they "are synchronously sampled"); RSTI goes through two ranks
(`rd68041_rstctl`), and IPL2-IPL0 will (M8).

**The one exception is the release of BB, TA and TIP.** UM 7.1: these "transition between
logic levels during T4 but transition from a driven state to a high-impedance state
during T1" -- negated at a rising edge, released about half a clock later (specification
39). `rd68041_late_release` keeps the pad's enable on until the following **falling**
edge. The MC68040 times this from PCLK; this design has no PCLK, so the release moves
with BCLK's duty cycle, which specification 8 lets vary from 40 % to 60 %. `make timing`
judges both ends; the release path is then left a window of 3 to 4 ns at 25 MHz and of
exactly 3 ns at the MC68LC040's 20 MHz (`doc/ac-timing.md`).

## Read, byte, word or long word (UM 7.4.1, Figures 7-8 and 7-9)

| Edge | What moves | UM |
|---|---|---|
| E0 (C1) | A31-A0, TT, TM, TLN, UPA, SIZ, R/W high, CIOUT valid; TS asserted; TIP asserted if it was not; BB asserted and BR as below if the core was not already master; MI negated | "during the first half of C1, the processor places valid values on the address bus and transfer attributes ... asserts TS ... TIP is also asserted at this time" |
| E1 (C2) | TS negated. TA not sampled: C1 has ended | "during the first half of the clock after C1, the processor negates TS" |
| E2, E3, ... | TA sampled, with TEA and the data. Not seen: a wait state | "at the end of the first clock cycle after C1, the processor samples the level of TA and latches the current value on the data bus ... continues to sample TA on successive rising edges" |
| E*t* (TA seen) | the transfer ends. The next transfer's C1 begins on this same edge if one is waiting and BG is asserted -- TIP stays asserted; otherwise TIP is negated | "TIP remains asserted if the processor is ready to begin another bus cycle. Otherwise, the processor negates TIP during the first half of the next clock" |

Two clocks with no wait state (UM 7.4.1). The data is latched on the TA edge and handed
up on the clock after (`rsp_valid`). TCI is ignored on byte, word and long-word reads.
TA is ignored on every edge that ends a clock in which TS is asserted, which is also
what the published clarification asks of a burst-inhibited line's long words (UM
README, Sec. 5, "TA asserted with TS during burst-inhibited transfers").

**Checked by:** `bus_xfer_tb` (every size and lane, waits, back to back); `make timing`
(13, 14, 11; 15 and 16 on the TA edge; 22a and 23 on it).

## Write (UM 7.4.3, Figures 7-14 and 7-15)

As a read, with R/W low, and:

| Edge | What moves | UM |
|---|---|---|
| E1 (C2) | TS negated; the data driven on every lane (bytes outside the operand carry whatever the requester placed there) | "the processor negates TS and drives the appropriate bytes of the data bus with the data to be written. All other bytes are driven with undefined values" |
| E*t* (TA seen) | the data bus three-stated | "the processor also three-states the data bus during the first half of the next clock following termination" |

A write that follows on the same edge drives its own data one clock later, at its C2,
so the data bus is released for one clock between back-to-back writes. A write that
follows a read drives at its C2 too, one clock after the read's TA edge: specification
17 gives the slave until one clock plus min(20) after that edge to let go, and the core
waits exactly that long (`doc/ac-timing.md`).

**Checked by:** `bus_xfer_tb`; `make timing` (18, 19, 20, 21, 17).

## Line (UM 7.4.2, 7.4.4, Figures 7-10 to 7-13, 7-16, 7-17)

| Edge | What moves | UM |
|---|---|---|
| E0 (C1) | as a long word, SIZ = line; the address is the requested long word's, A1-A0 as given | "A1 and A0 are copied from the original operand address" |
| E1 (C2) | TS negated; a write drives long word 0 | |
| E2 ... | TA, TBI, TCI sampled with the first long word | "the processor samples the level of TA, TBI, and TCI" |
| first TA, TBI negated | C3: the address and attributes held; a write drives the next long word on this edge | "the processor holds the address and transfer attribute signals constant during C3"; "drives the second long word of data on the data bus ... during C3" |
| C4, C5 | the same, one long word per TA | |
| fourth TA | the line ends: as a long word's TA | |

Five clocks with no wait state. TBI with the first TA: the next C1 starts on that edge,
with A3-A2 incremented, A1-A0 kept and SIZ long, and the line finishes as three
long-word transfers -- eight clocks, one tenure, BG not looked at in between ("does not
allow other unrelated processor accesses or bus arbitration to intervene"). TCI is taken
with the first TA only, and not at all in the burst-inhibited long words. The slave
increments A3-A2 itself in a burst; the core's address does not move.

**Checked by:** `bus_xfer_tb`; `make timing` (`line` scenario; 22c and 22d probes).

## Locked transfers (UM 7.4.5)

LOCK is asserted with C1 of the first transfer of a locked sequence and stays asserted,
between transfers too, until the sequence's last write ends; LOCKE is asserted with that
write only. Both are part of the address group (specification 11). If BG is taken away
in the middle of a sequence -- which UM 7.8.1 allows -- LOCK leaves the bus with the
address group at the edge (specification 38), not "driven high before three-stating"
(UM 5.3.7): `doc/manual-contradictions.md`, 2.

**Checked by:** `bus_arb_tb`; `make timing` (`arb` scenario).

## Acknowledge cycles (UM 7.5)

An interrupt acknowledge is a byte read with TT = 3, TM = the level, A31-A0 all ones;
TA with data is a vector, TA with AVEC an autovector (AVEC sampled with TA,
specifications 24 and 25), TEA a spurious interrupt, TA with TEA a retry. A breakpoint
acknowledge has A = 0. Clock for clock they are reads.

**Checked by:** `bus_error_tb`; `make timing` (`avec` probe).

## Bus errors and retry (UM 7.6, Figures 7-26 to 7-29)

| Termination (Table 7-5) | On the edge it is seen |
|---|---|
| TEA alone | the transfer ends as on TA: TIP negated unless another begins; a line stops at that long word; reported with `rsp_err` |
| TA and TEA, first long word of a transfer | a retry: C1 of the same transfer, same address and attributes, **on that same edge**, LOCK and LOCKE as they were ("immediately retries the cycle using the same access information"; Figure 7-28: C1 C2 CW C1 C2) |
| TA and TEA, later long word of a line, or any long word of a burst-inhibited line | a bus error |
| TA and TEA with BG negated | relinquish and retry: the bus given up at that edge (38, 39), BR kept asserted, and the transfer run again once the bus comes back |

**Checked by:** `bus_error_tb`, `bus_arb_tb`; `make timing` (`error` scenario; `tea` probe).

## Arbitration (UM 7.8.1, Figure 7-30, Table 7-6)

| State | BB | TIP | TS | address group | data | entered |
|---|---|---|---|---|---|---|
| idle | released | released | released | released | released | out of reset; BG negated |
| implicit ownership | released | driven, negated | driven, negated | driven | released | BG asserted and BB seen negated, nothing to do |
| active | asserted | asserted | C1 only | driven | a write's, from C2 | a transfer starts |
| park | asserted | driven, negated | driven, negated | driven | released | a transfer ends with BG still asserted |
| giving up | negated at the edge, released half a clock later | the same | released at the edge | released at the edge | released | BG seen negated at the last TA, or in park |

- **Taking the bus from idle**: on the first edge that sees BG asserted and BB negated
  (UM 7.8.1: "after the alternate bus master negates BB, the processor asserts BB ... and
  begins the bus cycle by asserting TS"), C1 starts on that very edge. BB is therefore
  driven one pad delay after the edge on which the other master's BB was seen negated --
  which is what specification 49 is about, and why BB's pad must be at least 9 ns
  (`doc/ac-timing.md`).
- **From implicit ownership or park**, a transfer starts on the edge it is asked for:
  "the processor must assert BR, TIP, and TS simultaneously" -- and in the logs BR, TIP
  and TS do move on one edge. Implicit ownership needs BG and an internal request to
  become a transfer (the addendum's correction to Figure 7-30).
- **BR** is asserted while a transfer is pending without the bus, with TS when the bus is
  already the core's, and negated when a transfer starts with nothing behind it.
- **BG** is sampled on every edge. UM 7.8.1 guarantees the bus is given up only if BG
  was negated "prior to the rising edge of the BCLK in which the last TA or TEA is
  asserted"; this design looks at BG on that edge itself, which honours the guarantee and
  also a later negation.
- **Giving up**: everything but BB, TIP and TA leaves the bus at the edge (38); BB and
  TIP are driven negated for half a clock and released (39), as Figure 7-32 draws. MI is
  asserted at that edge (UM 7.9.1: "from the last TA of the current bus cycle if the
  M68040 owns the bus and loses it").
- Leaving the bus with one clock in which no master's BG is asserted is the arbiter's
  duty (the published addendum), not the processor's.

**Differences.** The data bus is not driven in park or implicit ownership, where the
manual says "the bus is driven with undefined values" (`doc/divergences.md`). TIP is
negated in park, as the text says and Table 7-6 does not (`doc/manual-contradictions.md`,
1).

**Checked by:** `bus_arb_tb`; `make timing` (`arb` scenario; 38, 39, 40, 49; `bg` and `bb`
probes, 41a, 41b, 42).

## Snooping (UM 7.9, Figures 7-40 to 7-43, 11-5, 11-6)

E*s* below is the rising edge on which the alternate master's TS is first seen; the
address, SIZ, TT, R/W and SC are latched on it (UM 7.9: "during the rising edge of BCLK
for which TS is first asserted"; specifications 44-47). MI is asserted between transfers
and from reset; it is negated while the core is master.

| Case | MI negated | First TA the alternate master can see | UM's figure, best case |
|---|---|---|---|
| snoop inhibited (SC = 00, 11, or TT not normal or MOVE16) | at E*s* | E*s*+2 from a memory that registers MI; E*s*+1 from one that answers within the clock MI negates in | **same**: Figure 7-40 draws MI negated in the clock after TS, TA one clock later |
| snoopable, no intervention | at E*s*+1, after a one-clock lookup | E*s*+3 registered, E*s*+2 combinational | Figure 7-41: MI negated at E*s*+2, TA at E*s*+3; "the negation of MI [can be delayed] by up to two additional clocks". **This design is one clock faster than the part's best case** |
| dirty line, read (SC = 01, 10): the core sources it | held | the core's, at E*s*+3, then one long word a clock | **same**: Figure 7-42, data and TA from C5 |
| dirty line, byte/word/long write, SC = 01: the core sinks it | held | the core's, at E*s*+2, for one clock; the data taken on that edge | Figure 7-43: TA at E*s*+3. **One clock faster** |

The core's TA is driven from the edge it is asserted on, negated at the edge after its
last long word, and released half a clock later, as BB and TIP are (39; Figure 7-42 draws
TA high for a moment before three-stating). The sourced data is released at that last
edge (21). While MI is asserted the snooper ignores TA and TEA (UM 5.5.2); a memory must
not answer until it has seen MI negated (UM 7.9), so neither faster case breaks a memory
that follows the protocol -- a memory that waits for MI simply answers sooner. A system
that *assumed* the part's minimum latency, timing its responses from TS instead of
watching MI, would see the difference; nothing in UM 7.9 allows that. The lookup is one
clock because the stand-in caches answer combinationally (`doc/bus.md`); the real caches
arrive at M9, and the latency is re-measured then.

The cache actions (Tables 4-3, 4-4), and a burst-inhibited alternate-master line snooped
as four long words (UM 7.9), are `doc/bus.md`'s.

**Checked by:** `bus_snoop_tb`; `make timing` (`snoop` scenario; 43, 48, 39 on TA; the
`snoop_*`, `data_sink` and `ta_snoop` probes, 15, 16, 22a, 23, 44a-47).

## Reset (UM 7.10, Figures 7-44 and 7-45)

- RSTI is synchronised by two rising-edge ranks ("internally synchronized for two BCLKs
  before being used") and recognised by the edge it meets 51 and 52 for (the `rsti`
  probe).
- Once through the two ranks, the internal reset (a register of its own) holds the bus
  unit: on the edge it takes effect every output that can be three-stated is -- BB and
  TIP (and TA if a snoop was being answered) driven negated for half a clock first, as
  Figure 7-45 notes -- MI is asserted, BR negated, and a transfer in progress dropped and
  not reported ("as if TA or TEA had been asserted").
- The internal reset ends 128 clocks after the synchronised RSTI negates; the bus stays
  released until BG, then implicit ownership (Figure 7-44).
- **The mode selects** (CDIS, MDIS, IPL2-IPL0) are captured on the edge that first
  samples RSTI negated -- up to a clock after RSTI negates, while specification 54
  guarantees them only 2 ns. **This is wrong** and `make timing` fails the MC68040's
  columns on it; nothing reads the captured modes yet. `doc/ac-timing.md` has the
  analysis and what a fix needs.

**Checked by:** `bus_arb_tb` (reset in a transfer); `make timing` (`reset` scenario; 39;
51, 52; 53, 54 and the `mode_*` probes).

## Known differences and gaps at M3

| | |
|---|---|
| Mode capture after RSTI | specification 54 fails (above): open defect in `rd68041_rstctl` |
| BB, TA, TIP release | from BCLK's falling edge, not PCLK's: meets 39 at every grade only within a 1 ns window at 25 MHz and an exact 3 ns at the MC68LC040's 20 MHz, for any compliant duty cycle |
| Snoop, no intervention | MI negated one clock earlier than Figure 7-41's best case |
| Snoop, sink | TA one clock earlier than Figure 7-43's best case |
| Park, implicit ownership | the data bus not driven (`doc/divergences.md`) |
| LOCK on a broken locked sequence | released at the edge, not driven high first (`doc/manual-contradictions.md`, 2) |
| IPL, IPEND, RSTO, PST, CDIS and MDIS during operation | no logic yet: M7-M10; pending in `make timing` |
| The multiplexed and DLE modes, buffer selection | not built (`doc/divergences.md`) |
