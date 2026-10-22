# RD68041 pinout

Derived from **Table 5-1, Signal Index** and §5.1–5.12 of
`Inputs/doc/MC68030_Doc_More_Readable/MC68040UM_split/08-section-05-signal-description.pdf`,
Appendix A (MC68LC040), and `MC68040UM_split/pin-assignments.csv`. This design implements
the MC68040 and the MC68LC040 (`FPU = 0`); the pins are the same set, but for the four
differences in "MC68LC040" below.

**Status: M1.** Every pin below exists on `rtl/rd68041_top.sv`. The bus unit
(`rtl/rd68041_biu.sv`, `doc/bus.md`) drives the master side of the bus and arbitration,
and the reset controller (`rtl/rd68041_rstctl.sv`) RSTI and the modes sampled at reset;
nothing above the bus unit asks it for a transfer yet. The snooper (M2) drives TA and
MI's snoop behaviour; RSTO, IPEND and PST arrive with the core.

The original has three-state and bidirectional pins. This core has none: every such pin is
split into an input `_i`, an output `_o` and an output-enable `_oe`. An external wrapper
recombines them:

```systemverilog
assign pad = core_oe ? core_o : 1'bz;   // three-state pin
assign core_i = pad;
```

`_oe` is **active high — asserted means the core is driving**. Active-low signals keep the
`_n` suffix and are active-low *on the pin*, so `ts_n_o == 0` means TS asserted.

Pins that are bidirectional on the part (§5) have all three: the core samples them while
an alternate master owns the bus, to snoop (§4, §7). Where one `_oe` serves a group, it is
because §5 releases the group together when the processor gives up the bus.

## Port list

### Clocks and reset (§5.7, §5.9)

| Port | Dir | Notes |
|---|---|---|
| `clk` | in | **BCLK.** Every register in the design is clocked on its rising edge, the bus's reference edge (§5.9.2, §11). |
| `pclk` | in | **PCLK, not used.** The part derives its internal timing from PCLK = 2 × BCLK (§5.9.3); this core runs entirely on BCLK (`doc/timing-divergences.md`). The port exists so a board wrapper is pin-for-pin; it is sunk. |
| `rst_n` | in | **Not an MC68040 pin.** Asynchronous hardware initialisation for simulation and FPGA bring-up, so that every register has a defined value without power-on state. The architectural reset is `rsti_n_i`. |
| `rsti_n_i` | in | RSTI, asynchronous, synchronised to the next rising edge of BCLK (§5.7.2). |
| `rsto_n_o` | out | RSTO, asserted by the RESET instruction (§5.7.3). Always driven. |

### Address bus (§5.1)

| Port | Dir | Notes |
|---|---|---|
| `a_i[31:0]` | in | Snooped during alternate-master transfers. |
| `a_o[31:0]` | out | The address of the first item of a transfer. |
| `a_oe` | out | |

### Data bus (§5.2)

| Port | Dir | Notes |
|---|---|---|
| `d_i[31:0]` | in | Read data, sampled on the rising edge TA is recognised on; snoop write data. |
| `d_o[31:0]` | out | Write data; snoop read data supplied by intervention. |
| `d_oe` | out | |

### Transfer attributes (§5.3)

| Port | Dir | Notes |
|---|---|---|
| `tt_i[1:0]`, `tt_o[1:0]` | in/out | Table 5-2: normal, MOVE16, alternate function code, acknowledge. Sampled when snooping: only normal and MOVE16 are snooped. |
| `tm_o[2:0]` | out | Tables 5-3 and 5-4; the level for an interrupt acknowledge. |
| `tln_o[1:0]` | out | The line within the set, for pushes and data line reads. |
| `upa_o[1:0]` | out | From the U1-U0 bits of the ATC entry or TTR; zero otherwise (§5.3.4). |
| `rw_i`, `rw_o` | in/out | High read. Sampled when snooping. |
| `siz_i[1:0]`, `siz_o[1:0]` | in/out | Byte, word, long, line (§7). Sampled when snooping. |
| `lock_n_o`, `locke_n_o` | out | Locked read-modify-write sequences. "LOCK drives high before three-stating" (§5.3.7), and LOCKE likewise (§5.3.8). |
| `ciout_n_o` | out | The cache mode of the ATC entry or TTR (§5.3.9). |
| `attr_oe` | out | One enable for A's companions: TT, TM, TLN, UPA, R/W, SIZ, LOCK, LOCKE, CIOUT. |

### Transfer control (§5.4)

| Port | Dir | Notes |
|---|---|---|
| `ts_n_i`, `ts_n_o`, `ts_oe` | in/out | One clock per transfer; monitored when snooping. |
| `tip_n_o`, `tip_oe` | out | Asserted through back-to-back transfers; negated, then released, when the bus is lost. |
| `ta_n_i`, `ta_n_o`, `ta_oe` | in/out | Input when the core is master; driven by the core only when it intervenes in a snooped transfer. |
| `tea_n_i` | in | With TA: retry (§5.4.4). |
| `tci_n_i` | in | Read data not to be cached; ignored on writes and after the first transfer of a line (§5.4.5). |
| `tbi_n_i` | in | With TA on the first transfer of a line: the rest as three long words (§5.4.6). |
| `dle_i` | in | **DLE, stubbed.** Only used in DLE mode, which is not built (below). On the MC68LC040 this pin is JS0, to be tied (Appendix A). Sunk. |

### Snoop control (§5.5)

| Port | Dir | Notes |
|---|---|---|
| `sc_i[1:0]` | in | The snoop operation for an alternate-master transfer. Ignored when the core is master. |
| `mi_n_o` | out | Always driven. Asserted during reset, and while a snooped transfer's intervention is undecided. |

### Arbitration (§5.6)

| Port | Dir | Notes |
|---|---|---|
| `br_n_o` | out | Always driven. |
| `bg_n_i` | in | |
| `bb_n_i`, `bb_n_o`, `bb_oe` | in/out | Negated, then released, on giving up the bus (§5.6.3). |

### Processor control (§5.7, §5.10)

| Port | Dir | Notes |
|---|---|---|
| `cdis_n_i` | in | Disables the caches dynamically. Its level at reset selects normal (high) or multiplexed (low) bus mode. **Only the normal mode is built**: a low level at reset is recorded and otherwise ignored (`doc/divergences.md`, from M2). On the MC68LC040, CDIS is ignored at reset. |
| `mdis_n_i` | in | Disables translation dynamically. Its level at reset selects normal (high) or DLE (low) mode; **DLE mode is not built**, as above. |

### Interrupts (§5.8)

| Port | Dir | Notes |
|---|---|---|
| `ipl_n_i[2:0]` | in | Synchronised. The levels at reset select output buffer strengths (Table 5-5), which have no meaning inside an FPGA; they are not used. |
| `ipend_n_o` | out | Always driven. |
| `avec_n_i` | in | With TA on an interrupt acknowledge. |

### Status (§5.9.1)

| Port | Dir | Notes |
|---|---|---|
| `pst_o[3:0]` | out | **Stubbed.** Always driven. Table 5-6. At M0 a constant `0000` (user, start/continue); a minimal encoding from the pipeline's last stage is an option recorded in `doc/plan.md`, not a commitment. |

### Test (§6) — stubbed

| Port | Dir | Notes |
|---|---|---|
| `tck_i`, `tms_i`, `tdi_i`, `trst_n_i` | in | Sunk. |
| `tdo_o`, `tdo_oe` | out | `tdo_oe` is held low: the TAP is not built. |

## MC68LC040 (`FPU = 0`)

Appendix A. The pins are the same set, with these differences:

- no DLE: the pin is JS0, to be tied high or low. `dle_i` is sunk in both builds.
- CDIS is ignored at reset: there is no multiplexed mode. Neither build has one.
- the IPL levels at reset do not select buffers. Neither build uses them.
- no FPU: every floating-point instruction takes the F-line exception with a format $4
  frame. That is behaviour, not a pin; `doc/plan.md`, M12.

The other names in `pin-assignments.csv` belong to parts not in scope: JS1 (the
MC68EC040's MDIS position), and JS2, SCD, LOC and LFO (the MC68040V and MC68EC040V).
