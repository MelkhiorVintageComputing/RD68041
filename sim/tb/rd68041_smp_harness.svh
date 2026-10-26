// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- two processors on one MC68040 bus (doc/smp.md), `include`d inside
// a testbench module. The board:
//
//   - per processor: MI, BR, BG, IPL2-IPL0, RSTI, RSTO, IPEND;
//   - bussed: BB, TS, TIP, TA, TEA, TBI, TCI, LOCK, LOCKE, CIOUT, R/W, SIZ,
//     TLN, TM, TT, A31-A0, D31-D0, and SC1-SC0, which is UPA1-UPA0 through
//     one gate with SIZ: the master's page attributes are the snoop
//     operation the other performs (below);
//   - every bussed active-low line pulled up when undriven, SC pulled to 00;
//   - AVEC grounded on both: every interrupt autovectored (UM 7.5.1);
//   - CDIS, MDIS negated; DLE low; one BCLK;
//   - memory (the slave model) waits for both MIs negated, and ignores a
//     processor's MI from its reset to its first bus cycle (below);
//   - what a snooping processor sources goes into memory too (UM 4.5);
//   - the corrected fairness arbiter of UM 7.8.2.1 (rd68041_fairarb);
//   - the board's devices at $FFFF0000 (rd68041_smpdev): WHOAMI, the
//     interprocessor interrupts (level 5), CPU 1's release from reset.
//
// The checks, each counted (and printed while few):
//
//   contention  two drivers on a bussed line at once
//   turnaround  the address group handed from one processor to the other
//               with no clock between: the release (specification 38, to
//               18 ns) and the new master's drive (specification 20, from
//               9 ns) overlap on the board -- UM 7.8.1 p. 7-48's reason for
//               a clock with every grant negated
//   gap         a grant asserted on the edge after the other's was
//   owner       a transfer started by a processor the arbiter had not
//               granted the bus (WHOAMI relies on it)
//   atomicity   the other processor's TS inside a locked sequence (from a TS
//               with LOCK to the termination of the one with LOCKE)
//   fairness    a bus request left ungranted for FAIR_MAX clocks
//   busmon      each processor's own bus protocol (rd68041_busmon)
//
// Plusargs: +gapless (the printed arbiter's grants), +nolocke (the arbiter
// ignores LOCKE), +retry=N (a retry every N clocks or so, anywhere in
// memory), +waits=N (wait states), +rsti1=N (CPU 1's earliest release, in
// clocks), and the bench's own breakages for checking the checks: +nomigate,
// +nosnarf, +rawsc; and +wtshared, the program's policy (below).

logic clk = 1'b0;
always #20 clk = ~clk;

logic       rst_n = 1'b0;
logic       rsti0_n = 1'b0, rsti1_hold = 1'b1;
wire        rsti1_n;

// --- the processors' pins ------------------------------------------------------
logic [31:0] a_o [0:1];
logic [31:0] d_o [0:1];
logic        a_oe [0:1], d_oe [0:1], attr_oe [0:1];
logic  [1:0] tt_o [0:1], tln_o [0:1], upa_o [0:1], siz_o [0:1];
logic  [2:0] tm_o [0:1];
logic        rw_o [0:1], lock_n_o [0:1], locke_n_o [0:1], ciout_n_o [0:1];
logic        ts_n_o [0:1], ts_oe [0:1], tip_n_o [0:1], tip_oe [0:1];
logic        ta_n_o [0:1], ta_oe [0:1], br_n_o [0:1], bb_n_o [0:1], bb_oe [0:1];
logic        mi_n_o [0:1], rsto_n_o [0:1], ipend_n_o [0:1];
logic  [3:0] pst_o [0:1];
logic        tdo_o [0:1], tdo_oe [0:1];
logic        bg_n [0:1];
logic  [2:0] ipl_n [0:1];
wire         rsti_n [0:1];
assign rsti_n[0] = rsti0_n;
assign rsti_n[1] = rsti1_n;

// --- the slave (memory) and the devices -------------------------------------------
logic [31:0] slave_d, dev_d;
logic        slave_d_oe, dev_d_oe;
logic        s_ta_n, s_tea_n, s_tbi_n, s_tci_n, s_avec_n, dev_ta_n;
logic  [1:0] dev_ipi;
logic        dev_release1;
int          dev_n;

// --- the bus, resolved ---------------------------------------------------------------
wire [31:0] a_bus  = a_oe[0] ? a_o[0] : a_oe[1] ? a_o[1] : 32'hFFFF_FFFF;
wire        attr0  = attr_oe[0];
wire        attr1  = attr_oe[1];
wire  [1:0] tt_bus  = attr0 ? tt_o[0]  : attr1 ? tt_o[1]  : 2'b11;
wire  [2:0] tm_bus  = attr0 ? tm_o[0]  : attr1 ? tm_o[1]  : 3'b111;
wire  [1:0] siz_bus = attr0 ? siz_o[0] : attr1 ? siz_o[1] : 2'b11;
wire        rw_bus  = attr0 ? rw_o[0]  : attr1 ? rw_o[1]  : 1'b1;
// SC1-SC0: the master's UPA1-UPA0, through the board's one gate. A page
// whose U bits ask for mark invalid (10) gets it for line transfers only, and
// supply/sink with the line left dirty (01) for anything smaller: UM 4.4.3,
// "alternate bus masters should indicate mark invalid only for line reads to
// ensure the entire line is transferred before invalidating", and 4.4.4,
// sink for word writes to copyback pages. Wired straight (+rawsc), a locked
// CAS or TAS -- a long word or byte, never cached -- to a copyback page
// invalidates the other processor's dirty line and loses the rest of it.
bit         raw_sc  = $test$plusargs("rawsc");
bit         wt_shared = $test$plusargs("wtshared");
wire  [1:0] upa_bus = attr0 ? upa_o[0] : attr1 ? upa_o[1] : 2'b00;
wire        is_line = (siz_bus == 2'b11);
wire  [1:0] sc_bus  = raw_sc ? upa_bus :
                      {upa_bus[1] & is_line, upa_bus[0] | (upa_bus[1] & !is_line)};
wire        lock_bus  = (attr0 ? lock_n_o[0]  : 1'b1) & (attr1 ? lock_n_o[1]  : 1'b1);
wire        locke_bus = (attr0 ? locke_n_o[0] : 1'b1) & (attr1 ? locke_n_o[1] : 1'b1);
wire [31:0] d_bus  = d_oe[0] ? d_o[0] : d_oe[1] ? d_o[1] :
                     slave_d_oe ? slave_d : dev_d_oe ? dev_d : 32'hzzzz_zzzz;
wire        ts_bus  = (ts_oe[0]  ? ts_n_o[0]  : 1'b1) & (ts_oe[1]  ? ts_n_o[1]  : 1'b1);
wire        tip_bus = (tip_oe[0] ? tip_n_o[0] : 1'b1) & (tip_oe[1] ? tip_n_o[1] : 1'b1);
wire        bb_bus  = (bb_oe[0]  ? bb_n_o[0]  : 1'b1) & (bb_oe[1]  ? bb_n_o[1]  : 1'b1);
wire        ta_bus  = s_ta_n & dev_ta_n & (ta_oe[0] ? ta_n_o[0] : 1'b1) &
                      (ta_oe[1] ? ta_n_o[1] : 1'b1);
wire        tea_bus = s_tea_n;
wire        tbi_bus = s_tbi_n;
wire        tci_bus = s_tci_n;

// Memory's MI: both processors', each ignored from that processor's reset
// until its first bus cycle. Ignoring it only while RSTI is asserted is not
// enough: MI stays asserted after reset until the processor's first cycle
// (UM 5.5.2) and between bus cycles (UM 7.9.1), and a processor let out of
// reset in the middle of the other's transfer never saw its TS, so never
// negates MI for it -- memory waits for ever. Until its first cycle a
// processor's caches are empty (they are invalid after reset), so there is
// nothing for its MI to protect. +nomigate breaks the board: MI used as is.
bit         no_migate = $test$plusargs("nomigate");
logic       mi_ignore [0:1];
always @(posedge clk)
  for (int i = 0; i < 2; i++)
    if (!rsti_n[i])                      mi_ignore[i] <= 1'b1;
    else if (ts_oe[i] && !ts_n_o[i])     mi_ignore[i] <= 1'b0;
wire        mi_mem = (mi_ignore[0] && !no_migate ? 1'b1 : mi_n_o[0]) &
                     (mi_ignore[1] && !no_migate ? 1'b1 : mi_n_o[1]);

// --- the processors ---------------------------------------------------------------------
for (genvar i = 0; i < 2; i++) begin : cpu
  rd68041_top #(.FPU(`TB_FPU)) dut (
      .clk(clk), .pclk(1'b0), .rst_n(rst_n), .rsti_n_i(rsti_n[i]), .rsto_n_o(rsto_n_o[i]),
      .a_i(a_bus), .a_o(a_o[i]), .a_oe(a_oe[i]), .d_i(d_bus), .d_o(d_o[i]), .d_oe(d_oe[i]),
      .tt_i(tt_bus), .tt_o(tt_o[i]), .tm_o(tm_o[i]), .tln_o(tln_o[i]), .upa_o(upa_o[i]),
      .rw_i(rw_bus), .rw_o(rw_o[i]), .siz_i(siz_bus), .siz_o(siz_o[i]),
      .lock_n_o(lock_n_o[i]), .locke_n_o(locke_n_o[i]), .ciout_n_o(ciout_n_o[i]),
      .attr_oe(attr_oe[i]),
      .ts_n_i(ts_bus), .ts_n_o(ts_n_o[i]), .ts_oe(ts_oe[i]), .tip_n_o(tip_n_o[i]),
      .tip_oe(tip_oe[i]),
      .ta_n_i(ta_bus), .ta_n_o(ta_n_o[i]), .ta_oe(ta_oe[i]), .tea_n_i(tea_bus),
      .tci_n_i(tci_bus), .tbi_n_i(tbi_bus), .dle_i(1'b0), .sc_i(sc_bus), .mi_n_o(mi_n_o[i]),
      .br_n_o(br_n_o[i]), .bg_n_i(bg_n[i]), .bb_n_i(bb_bus), .bb_n_o(bb_n_o[i]),
      .bb_oe(bb_oe[i]),
      .cdis_n_i(1'b1), .mdis_n_i(1'b1), .ipl_n_i(ipl_n[i]), .ipend_n_o(ipend_n_o[i]),
      .avec_n_i(1'b0), .pst_o(pst_o[i]),
      .tck_i(1'b0), .tms_i(1'b0), .tdi_i(1'b0), .trst_n_i(1'b1), .tdo_o(tdo_o[i]),
      .tdo_oe(tdo_oe[i]));

  // Each processor's own protocol; the other one, or memory, is its
  // "alternate master" and "slave".
  rd68041_busmon u_mon (
      .clk(clk), .active(rsti_n[i]),
      .a_o(a_o[i]), .a_oe(a_oe[i]), .attr_oe(attr_oe[i]), .tt_o(tt_o[i]), .tm_o(tm_o[i]),
      .siz_o(siz_o[i]), .rw_o(rw_o[i]), .d_oe(d_oe[i]), .ts_n_o(ts_n_o[i]),
      .tip_n_o(tip_n_o[i]), .tip_oe(tip_oe[i]), .bb_n_o(bb_n_o[i]), .bb_oe(bb_oe[i]),
      .slave_d_oe(slave_d_oe | dev_d_oe | d_oe[1 - i]), .ta_n(ta_bus), .tea_n(tea_bus),
      .tbi_n(tbi_bus), .alt_owns(a_oe[1 - i] | attr_oe[1 - i]), .core_slave(ta_oe[i]));

  assign ipl_n[i] = dev_ipi[i] ? 3'b010 : 3'b111;      // level 5
end

// --- the arbiter -----------------------------------------------------------------------
bit         arb_gapless   = $test$plusargs("gapless");
bit         arb_use_locke = !$test$plusargs("nolocke");
logic [1:0] arb_state;
logic       arb_who, arb_who_q;

rd68041_fairarb u_arb (
    .clk(clk), .rst_n(rst_n), .use_locke(arb_use_locke), .gapless(arb_gapless),
    .br1_n(br_n_o[0]), .br2_n(br_n_o[1]), .bb_n(bb_bus), .lock_n(lock_bus),
    .locke_n(locke_bus), .bg1_n(bg_n[0]), .bg2_n(bg_n[1]), .state(arb_state),
    .who(arb_who));

// The grant the processors sampled on the last edge: a transfer whose TS is
// seen on this edge was started on that one.
always @(posedge clk) arb_who_q <= arb_who;

rd68041_slave #(.MEM_BYTES(65536)) u_mem (
    .clk(clk), .a(a_bus), .d_in(d_bus), .d_out(slave_d), .d_oe(slave_d_oe),
    .tt(tt_bus), .tm(tm_bus), .rw(rw_bus), .siz(siz_bus), .ts_n(ts_bus), .mi_n(mi_mem),
    .ta_n(s_ta_n), .tea_n(s_tea_n), .tbi_n(s_tbi_n), .tci_n(s_tci_n), .avec_n(s_avec_n));

rd68041_smpdev u_dev (
    .clk(clk), .rst_n(rst_n), .a(a_bus), .d_in(d_bus), .d_out(dev_d), .d_oe(dev_d_oe),
    .tt(tt_bus), .rw(rw_bus), .ts_n(ts_bus), .mi_n(mi_mem), .who(arb_who_q),
    .ta_n(dev_ta_n), .ipi(dev_ipi), .release1(dev_release1), .n_access(dev_n));

// CPU 1 leaves reset when CPU 0 lets it (RELEASE) and +rsti1 has passed.
int rsti1_min = 0;
initial if (!$value$plusargs("rsti1=%d", rsti1_min)) rsti1_min = 0;
int cyc = 0;
always @(posedge clk) cyc <= cyc + 1;
assign rsti1_n = !rsti1_hold && dev_release1 && (cyc >= rsti1_min);

// --- memory takes what a snooping processor sources (UM 4.5) -------------------
bit          no_snarf = $test$plusargs("nosnarf");
logic [31:0] src_a;
int          src_k;
int          n_sourced;
always @(posedge clk) begin
  if (!ts_bus) begin src_a = a_bus; src_k = 0; end
  for (int i = 0; i < 2; i++)
    if (ta_oe[i] && !ta_n_o[i] && d_oe[i] && rw_bus) begin
      if (!no_snarf)
        u_mem.poke_long({src_a[31:4], 4'h0} + 4 * ((int'(src_a[3:2]) + src_k) % 4), d_o[i]);
      src_k++;
      n_sourced++;
    end
end

// --- the checks -------------------------------------------------------------------------
localparam int FAIR_MAX = 4000;
int n_contention, n_turnaround, n_gap, n_owner, n_atomic, n_fair;
int n_ts [0:1];
int n_handover, n_snoop_ta, n_locked;
int fair_wait [0:1];
int lk_owner;                 // -1: no locked sequence under way
bit lk_end;                   // the transfer under way carries LOCKE
bit en_prev [0:1];
logic bg_prev [0:1];

initial begin
  n_contention = 0; n_turnaround = 0; n_gap = 0; n_owner = 0; n_atomic = 0; n_fair = 0;
  n_ts[0] = 0; n_ts[1] = 0; n_handover = 0; n_snoop_ta = 0; n_locked = 0;
  fair_wait[0] = 0; fair_wait[1] = 0; lk_owner = -1; lk_end = 0;
  en_prev[0] = 0; en_prev[1] = 0; bg_prev[0] = 1; bg_prev[1] = 1; n_sourced = 0;
end

function automatic int count_of(input bit x0, input bit x1, input bit x2, input bit x3);
  count_of = int'(x0) + int'(x1) + int'(x2) + int'(x3);
endfunction

task automatic bus_fail(inout int n, input string what);
  n++;
  if (n <= 4) $display("  FAIL: [%0d] %s", cyc, what);
endtask

// Drivers, between edges (the values the next edge samples).
always @(negedge clk) if (rst_n) begin
  bit en [0:1];
  if (count_of(a_oe[0], a_oe[1], 0, 0) > 1)       bus_fail(n_contention, "both processors drive A");
  if (count_of(attr_oe[0], attr_oe[1], 0, 0) > 1) bus_fail(n_contention, "both processors drive the attributes");
  if (count_of(d_oe[0], d_oe[1], slave_d_oe, dev_d_oe) > 1) bus_fail(n_contention, "two drivers on D");
  if (count_of(ts_oe[0], ts_oe[1], 0, 0) > 1)     bus_fail(n_contention, "both processors drive TS");
  if (count_of(tip_oe[0], tip_oe[1], 0, 0) > 1)   bus_fail(n_contention, "both processors drive TIP");
  if (count_of(bb_oe[0], bb_oe[1], 0, 0) > 1)     bus_fail(n_contention, "both processors drive BB");
  if (count_of(ta_oe[0], ta_oe[1], !s_ta_n, !dev_ta_n) > 1) bus_fail(n_contention, "two drivers on TA");
  for (int i = 0; i < 2; i++) begin
    en[i] = a_oe[i] || attr_oe[i];
    if (en[i] && !en_prev[i] && en_prev[1 - i])
      bus_fail(n_turnaround, $sformatf("CPU %0d drives the address group the clock after CPU %0d did", i, 1 - i));
  end
  for (int i = 0; i < 2; i++) en_prev[i] = en[i];
end

always @(posedge clk) if (rst_n) begin
  int d;
  // Grants: never both, and a clock with neither between them.
  for (int i = 0; i < 2; i++)
    if (!bg_n[i] && bg_prev[i] && !bg_prev[1 - i])
      bus_fail(n_gap, $sformatf("BG%0d asserted on the edge after BG%0d", i + 1, 2 - i));
  if (bg_n[0] != bg_prev[0] && !bg_n[0]) n_handover++;
  if (bg_n[1] != bg_prev[1] && !bg_n[1]) n_handover++;
  for (int i = 0; i < 2; i++) bg_prev[i] = bg_n[i];
  // Fairness.
  for (int i = 0; i < 2; i++) begin
    if (rsti_n[i] && !br_n_o[i] && bg_n[i]) fair_wait[i]++; else fair_wait[i] = 0;
    if (fair_wait[i] == FAIR_MAX)
      bus_fail(n_fair, $sformatf("CPU %0d's bus request ungranted for %0d clocks", i, FAIR_MAX));
  end
  // A transfer starts: who, and locked sequences.
  if (!ts_bus) begin
    d = (ts_oe[1] && !ts_n_o[1]) ? 1 : 0;
    n_ts[d]++;
    if (d != int'(arb_who_q))
      bus_fail(n_owner, $sformatf("CPU %0d started a transfer granted to CPU %0d", d, arb_who_q));
    if (lk_owner >= 0 && lk_owner != d)
      bus_fail(n_atomic, $sformatf("CPU %0d's transfer at %h inside CPU %0d's locked sequence",
                                   d, a_bus, lk_owner));
    if (!lock_bus) begin
      if (lk_owner != d) n_locked++;
      lk_owner = d;
      lk_end   = !locke_bus;
    end else begin
      lk_owner = -1;
      lk_end   = 0;
    end
  end else if (lk_end && (!ta_bus || !tea_bus) && !(!ta_bus && !tea_bus)) begin
    lk_owner = -1;              // the sequence's last transfer terminated
    lk_end   = 0;
  end
  if (ta_oe[0] && !ta_n_o[0] || ta_oe[1] && !ta_n_o[1]) n_snoop_ta++;
end

// --- the run ------------------------------------------------------------------------------
// Random wait states and retries, if asked for.
int waits = 0, retry_every = 0;
initial begin
  if (!$value$plusargs("waits=%d", waits)) waits = 0;
  if (!$value$plusargs("retry=%d", retry_every)) retry_every = 0;
end
always @(negedge clk)
  if (rst_n && retry_every > 0 && ($urandom % retry_every) == 0) u_mem.add_retries(0, 1);

// Load the image, then the program's parameters into memory: ITERS at
// $8000, UMASK at $8004, WTSHARED at $8008 (sim/programs/m14_smp.S).
// +wtshared: every shared page write-through, U 01 -- the software policy
// for the board without the SC gate (doc/smp.md).
task automatic boot2(input string image, input logic [31:0] iters_v, input logic [31:0] umask_v);
  u_mem.load_hex(image);
  u_mem.poke_long(32'h0000_8000, iters_v);
  u_mem.poke_long(32'h0000_8004, umask_v);
  u_mem.poke_long(32'h0000_8008, {31'h0, wt_shared});
  u_mem.set_region(0, 32'h0000_0000, 32'h0000_0000, waits, 0, 0, -1, 0);
  u_mem.set_region(1, 32'hFFFF_0000, 32'hFFFF_FFF0, 0, 0, 0, -1, 0);
  u_mem.set_external(1);
  rst_n = 1'b0; rsti0_n = 1'b0; rsti1_hold = 1'b1;
  repeat (4) @(negedge clk);
  rst_n = 1'b1;
  repeat (12) @(negedge clk);
  rsti0_n = 1'b1;
  rsti1_hold = 1'b0;
endtask

// +vcd=FILE +vcd_from=N: the board's signals from clock N on, for debugging.
string vcd_file;
int    vcd_from = 0;
initial if ($value$plusargs("vcd=%s", vcd_file)) begin
  if (!$value$plusargs("vcd_from=%d", vcd_from)) vcd_from = 0;
  wait (cyc >= vcd_from);
  $dumpfile(vcd_file);
  $dumpvars(1, u_arb, u_dev);
  $dumpvars(1, cpu[0].dut, cpu[1].dut);
end
