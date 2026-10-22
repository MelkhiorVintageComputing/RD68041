# The bus unit

`rtl/rd68041_biu.sv`, from M1: the MC68040's bus as a master (UM 7.4–7.6) and its
arbitration (UM 7.8). The snooper, `rtl/rd68041_snoop.sv` (M2), answers an alternate
master's transfers (UM 7.9); the bus unit instantiates it, so every pin has one owner. The
reset (UM 7.10) is `rtl/rd68041_rstctl.sv`.

## The contract above it

A request is **one bus transfer**. The MC68040 has no dynamic bus sizing (UM 7.2), so
whoever asks — the data memory unit, the instruction fetch, the table search — has already
split a misaligned operand into aligned transfers (UM 7.3, Table 7-3) and placed the bytes
on their lanes (Table 7-1). A line is four long words and is one request.

| Signal | Meaning |
|---|---|
| `req_valid` / `req_ready` | Handshake. The request is taken on the rising edge where both are high, and that edge starts its C1 (TS asserted). `req_ready` depends on the bus inputs sampled at that edge, so a requester must not make `req_valid` depend on it. |
| `req_addr`, `req_write`, `req_siz`, `req_tt`, `req_tm`, `req_tln`, `req_upa`, `req_ciout` | The transfer's pins, as Table 7-2 gives them for its kind. |
| `req_wdata[127:0]` | Write data: long word *k* of the transfer in bits 32*k*+31…32*k*. A line's long word 0 is the one at the request's own A3–A2, and the rest follow in the burst's wrapping order (UM 7.4.2). |
| `req_lock`, `req_locke`, `lock_seq` | A locked sequence (UM 7.4.5): every transfer in it has `req_lock`, its last write `req_locke`; `lock_seq` is held by the requester from the first transfer to the last, and keeps LOCK asserted between them. |
| `req_more` | Another request is already waiting behind this one; it keeps BR asserted when this one starts (UM 7.8.1). |
| `rsp_valid`, `rsp_data`, `rsp_beat`, `rsp_lw` | One per long word moved, registered: on the clock after the edge TA was sampled on. `rsp_beat` counts from 0; `rsp_lw` is that long word's A3–A2. |
| `rsp_tci` | TCI with a line's first TA (UM 7.4.2, 5.4.5). |
| `rsp_avec` | AVEC with TA, for an interrupt acknowledge (UM 7.5.1.2). |
| `rsp_done`, `rsp_err` | With the last response, or alone: the transfer is over. `rsp_err` with it is a bus error (TEA), on the long word `rsp_beat` names; a line stops there (UM 7.6.1). |

Never reported, because the bus unit deals with them:

- **retry** (TA with TEA, Table 7-5): the transfer is run again with the same access
  information (UM 7.6.2), after giving the bus up if BG was negated with it. A retry on a
  line's second, third or fourth long word, or on any of a burst-inhibited line's three
  long-word transfers, is a bus error.
- **burst inhibit** (TBI with a line's first TA): the rest of the line as three long-word
  transfers, A3–A2 incremented, A1–A0 kept (UM 7.2, 7.4.2). Still one request, one bus
  tenure, one set of responses.

## On the pins

Every output is registered on the rising edge of BCLK; every input is sampled on it. A
transfer's first clock (C1) has TS; TA is sampled from the end of the next (C2) — two
clocks with no wait state, five for a line burst, eight for a burst-inhibited line (UM 7.4).
A transfer can start on the edge that ends the one before it, with TIP held.

| State (UM 7.8.1) | BB | TIP | address group | data |
|---|---|---|---|---|
| idle | released | released | released | released |
| implicit ownership | released | driven, negated | driven | released (`doc/divergences.md`) |
| active cycle | asserted | asserted | driven | a write's, from C2 |
| park | asserted | driven, negated | driven | released |
| giving up the bus | driven negated, released half a clock later | the same | released at the edge | released |

Giving up the bus: the address group, TS and LOCK leave it at the rising edge
(specification 38); BB and TIP are set negated at that edge and released half a clock
later (specification 39) by `rtl/rd68041_late_release.sv`, the design's one falling-edge
register. MI is asserted out of reset and whenever the core is not master, and negated from
the edge the core asserts TS (UM 7.9.1); from M2 the snooper negates it for alternate
masters' transfers.

## Snooping (M2)

When the core is not master, the snooper latches an alternate master's address, SIZ, TT,
R/W and SC1–SC0 on the edge its TS is seen, and:

| Transfer | MI | Who answers | Caches (Tables 4-3, 4-4) |
|---|---|---|---|
| TT not normal or MOVE16, or SC = 00 or 11 | negated at once | memory | untouched |
| snoopable, miss | negated after the lookup | memory | untouched |
| read, clean hit | negated after the lookup | memory | SC = 10: invalidated (V10); SC = 01: kept (V9) |
| read, dirty hit | held | **the core**, from the data cache, a line in A3–A2 order | SC = 10: invalidated after (D10); SC = 01: kept (D9) |
| write of a byte, word or long word, dirty hit, SC = 01 | held | **the core**, into the data cache, D bit set (D12) | kept |
| any other write that hits | negated after the lookup | memory | invalidated (V11–V13, D11, D13) |
| any of these hitting an instruction-cache line | | | SC = 10 read or any write: invalidated (V5, V6) |

The lookup is one clock, so a snooped transfer memory answers takes two clocks more than
an unsnooped one: UM 7.9.2's best case, "the equivalent of two wait states". The core's
data comes as fast as memory's would: TA from the clock after the lookup. MI is asserted
between transfers whatever SC and TT say (UM 7.9.1), and while it is asserted the snooper
ignores TA and TEA (UM 5.5.2). The core's TA is released through
`rd68041_late_release`, as BB and TIP are (specification 39).

The caches answer on the `sn_*` port: tags looked up combinationally on `sn_addr`, data one
clock behind its address (a block RAM), writes and invalidations on the clock asked for. At
M2 nothing answers it in the top level — there are no caches until M9 — and
`sim/models/rd68041_snoopcache.sv` stands in for them in the testbench. The push buffer is
snooped with the data cache (M9).

## Tests

| Testbench | What |
|---|---|
| `bus_xfer_tb` | every size on every lane, waits, back to back, line bursts read and written, burst-inhibited lines, TCI, attributes |
| `bus_error_tb` | TEA on reads, writes and a line's third long word; retries, on a line's first transfer and as bus errors on later ones; interrupt acknowledge by vector, autovector, TEA and retry; breakpoint acknowledge |
| `bus_arb_tb` | implicit ownership, BR without BG, BB held by another master, park and leaving it, giving the bus up (specifications 38 and 39), relinquish and retry, a locked sequence, an internal reset in the middle of a transfer |
| `bus_snoop_tb` | an alternate master (`sim/models/rd68041_altmaster.sv`) against every row of Table 4-1 on missing, clean and dirty lines: inhibited, sourced (a long word, a line in burst order), sunk (a long word, a byte on its lane), invalidated; the instruction cache; a non-snoopable TT; a line memory burst-inhibits; MI between transfers; TA's release |

All four run the bus unit alone against `sim/models/rd68041_slave.sv` with
`sim/models/rd68041_busmon.sv` checking the protocol on every edge.
