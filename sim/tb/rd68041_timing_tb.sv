// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- the AC-timing event log, for the MC68040 / MC68LC040 specifications.
//
// Retargeted from RD68031's sim/tb/rd68031_timing_tb.sv. Emits times and nothing
// else. No testbench here knows what a specification is; the limits live in
// tools/timing/specs.py and the reading of UM section 11's figures in
// tools/timing/anchors.py. That separation is what lets a wrong anchor be fixed
// with a one-line edit and a re-analysis in milliseconds instead of a
// re-simulation.
//
// What runs: the bus unit (rtl/rd68041_biu.sv, with its snooper) and the reset
// controller (rtl/rd68041_rstctl.sv), wired as rd68041_top wires them, with the
// bus unit's request port fed by this testbench -- rd68041_top ties it off
// until the core exists. Around them: the slave model (sim/models/rd68041_slave.sv)
// for ordinary memory, a device of the testbench's own above $8000_0000 whose
// TA, TEA, TBI, TCI, AVEC and data it moves at chosen instants, an alternate
// master driven from here, the stand-in caches on the snoop port
// (sim/models/rd68041_snoopcache.sv) and the bus monitor.
//
// An RTL model has no pad delays, so every pin moves exactly on a clock edge.
// What is recorded is therefore which edge, and in which direction: the analysis
// adds the unknown pad delay to it and asks whether any assignment of those
// delays fits inside the manual's tables.
//
//     +period=<ns>   the clock period (default 40: 25 MHz)
//     +high=<ns>     how long BCLK is high in each period (default half): the
//                    analysis runs each grade at 40 % and 60 %, specification 8
//     +log=<path>    where the event log goes
//
// Output format, one line per record:
//
//     C <period_ns> <high_ns>               the clock this run used
//     H <name> <value>                      a fact about the run
//     S <scenario>                          the events that follow belong to it
//     T <time_ns> <R|F|X> <event>           a transition, on a rising or falling
//                                           edge, or (X) a stimulus at no edge
//     P <input> <R|F|?> <off_before> <off_after> <out_before> <out_after>
//
// THREE KINDS OF EVENT. `<pin>.<what>` is a pin of the core moving, and gets a
// pad delay. `in.<pin>.<what>` is this testbench moving an input, with no delay
// of the core's own. `smp.<what>` and `clk.<what>` are clock edges inside the
// core; they have no pad delay either. The vocabulary is fixed in
// tools/timing/anchors.py and nothing may invent one that is not in it.
//
// THE PROBES (P). An RTL model samples an input at one instant, and an input's
// setup and hold specifications are a window around one clock edge; the design
// meets them if that instant lies inside the window. A probe finds the instant:
// it makes the same input change twice, once half a nanosecond before an edge
// and once half a nanosecond after it, and records what the core did each
// time. If the two runs differ, the core sampled that input inside that
// nanosecond. The kind of edge (R or F) is read off the clock, not assumed.
//
// THE SAMPLING EDGES (smp.*) in the scenario logs are read off the bus unit's
// state -- the probes are what prove they are the edges the inputs are really
// sampled on.
//
// The testbench changes what the design samples away from the rising edge --
// at the falling edge, or at a probe's chosen instant -- except the slave
// model, which drives from the rising edge with non-blocking assignments as
// in every other bus testbench (doc/coding-standard.md).

`timescale 1ns / 1ps

module rd68041_timing_tb;

  // ---------------------------------------------------------------------------
  // The clock
  // ---------------------------------------------------------------------------
  real T, H;
  localparam real SNAP = 1.0;    // snapshots, this long after every edge
  logic clk = 1'b0;
  realtime last_rise = 0.0, last_fall = 0.0, last_edge = 0.0;

  initial begin
    if (!$value$plusargs("period=%f", T)) T = 40.0;
    if (!$value$plusargs("high=%f", H)) H = T / 2.0;
    forever begin
      #(T - H) clk = 1'b1;
      #(H)     clk = 1'b0;
    end
  end
  always @(posedge clk) begin last_rise = $realtime; last_edge = $realtime; end
  always @(negedge clk) begin last_fall = $realtime; last_edge = $realtime; end

  // The next rising edge after now.
  function automatic real next_rise();
    next_rise = last_rise + T;
  endfunction

  // ---------------------------------------------------------------------------
  // The design: the bus unit and the reset, as rd68041_top wires them
  // ---------------------------------------------------------------------------
  logic rst_n = 1'b0;
  logic rsti_n = 1'b0;
  logic cdis_n = 1'b1, mdis_n = 1'b1;
  logic [2:0] ipl_n = 3'b111;
  logic crst, mode_mux, mode_dle;
  logic [2:0] mode_ipl;

  rd68041_rstctl u_rst (
      .clk(clk), .rst_n(rst_n), .rsti_n_i(rsti_n), .cdis_n_i(cdis_n),
      .mdis_n_i(mdis_n), .ipl_n_i(ipl_n), .crst(crst), .mode_mux(mode_mux),
      .mode_dle(mode_dle), .mode_ipl(mode_ipl));

  logic         req_valid, req_ready;
  logic [31:0]  req_addr;
  logic         req_write;
  logic  [1:0]  req_siz, req_tt, req_tln, req_upa;
  logic  [2:0]  req_tm;
  logic         req_ciout, req_lock, req_locke, req_more;
  logic [127:0] req_wdata;
  logic         lock_seq = 1'b0;

  logic         rsp_valid, rsp_tci, rsp_avec, rsp_done, rsp_err, owner;
  logic  [1:0]  rsp_beat, rsp_lw;
  logic [31:0]  rsp_data;

  logic [31:0] a_o, d_o, slave_d;
  logic        a_oe, d_oe, attr_oe, slave_d_oe;
  logic  [1:0] tt_o, tln_o, upa_o, siz_o;
  logic  [2:0] tm_o;
  logic        rw_o, lock_n_o, locke_n_o, ciout_n_o, ts_n_o, tip_n_o, tip_oe;
  logic        br_n_o, bb_n_o, bb_oe, mi_n_o;
  logic        ta_n_o, ta_oe;
  logic        s_ta_n, s_tea_n, s_tbi_n, s_tci_n, s_avec_n;   // the slave's
  logic        bg_n = 1'b0;

  // The testbench's own device, above $8000_0000 (the slave is told to wait
  // there for ever): every termination and its data, moved at chosen instants.
  logic        dev_ta_n = 1'b1, dev_tea_n = 1'b1, dev_tbi_n = 1'b1, dev_tci_n = 1'b1;
  logic        dev_avec_n = 1'b1;
  logic [31:0] dev_d = '0;
  logic        dev_d_oe = 1'b0;
  logic        dev_auto = 1'b1;       // answers by itself; a probe turns it off

  // The alternate master, driven from here.
  logic        am_own = 1'b0;         // drives the address group and TS
  logic        am_ts_n = 1'b1, am_rw = 1'b1;
  logic [31:0] am_a = '0, am_d = '0;
  logic  [1:0] am_tt = 2'b00, am_siz = 2'b00, am_sc = 2'b00;
  logic        am_d_oe = 1'b0;
  logic        am_bb_n = 1'b1, am_bb_oe = 1'b0;

  // The board: what is on each wire. A wire nobody drives reads as its pull-up.
  wire [31:0] dbus  = d_oe ? d_o : (slave_d_oe ? slave_d : (dev_d_oe ? dev_d :
                      (am_d_oe ? am_d : 32'hFFFF_FFFF)));
  wire        bb_w  = bb_oe ? bb_n_o : (am_bb_oe ? am_bb_n : 1'b1);
  wire        ts_w  = attr_oe ? ts_n_o : (am_own ? am_ts_n : 1'b1);
  wire [31:0] a_w   = a_oe ? a_o : (am_own ? am_a : 32'hFFFF_FFFF);
  wire  [1:0] tt_w  = attr_oe ? tt_o : (am_own ? am_tt : 2'b11);
  wire  [1:0] siz_w = attr_oe ? siz_o : (am_own ? am_siz : 2'b11);
  wire        rw_w  = attr_oe ? rw_o : (am_own ? am_rw : 1'b1);
  wire  [1:0] sc_w  = am_sc;
  wire        ta_w  = s_ta_n & dev_ta_n & (ta_oe ? ta_n_o : 1'b1);
  wire        tea_w = s_tea_n & dev_tea_n;
  wire        tbi_w = s_tbi_n & dev_tbi_n;
  wire        tci_w = s_tci_n & dev_tci_n;
  wire        avec_w = s_avec_n & dev_avec_n;

  logic [31:0] sn_addr, sn_rdata, sn_wdata;
  logic        sn_dhit, sn_ddirty, sn_ihit, sn_wr, sn_dinv, sn_iinv;
  logic  [3:0] sn_wbe;

  rd68041_biu u_biu (
      .clk(clk), .rst_n(rst_n), .crst(crst),
      .req_valid(req_valid), .req_ready(req_ready), .req_addr(req_addr),
      .req_write(req_write), .req_siz(req_siz), .req_tt(req_tt), .req_tm(req_tm),
      .req_tln(req_tln), .req_upa(req_upa), .req_ciout(req_ciout),
      .req_lock(req_lock), .req_locke(req_locke), .req_more(req_more),
      .req_wdata(req_wdata), .lock_seq(lock_seq),
      .rsp_valid(rsp_valid), .rsp_beat(rsp_beat), .rsp_lw(rsp_lw),
      .rsp_data(rsp_data), .rsp_tci(rsp_tci), .rsp_avec(rsp_avec),
      .rsp_done(rsp_done), .rsp_err(rsp_err), .owner(owner),
      .a_i(a_w), .a_o(a_o), .a_oe(a_oe), .d_i(dbus), .d_o(d_o), .d_oe(d_oe),
      .tt_i(tt_w), .tt_o(tt_o), .tm_o(tm_o), .tln_o(tln_o), .upa_o(upa_o),
      .rw_i(rw_w), .rw_o(rw_o), .siz_i(siz_w), .siz_o(siz_o),
      .lock_n_o(lock_n_o), .locke_n_o(locke_n_o),
      .ciout_n_o(ciout_n_o), .attr_oe(attr_oe), .ts_n_i(ts_w), .ts_n_o(ts_n_o),
      .tip_n_o(tip_n_o), .tip_oe(tip_oe), .ta_n_i(ta_w), .ta_n_o(ta_n_o),
      .ta_oe(ta_oe), .tea_n_i(tea_w),
      .tci_n_i(tci_w), .tbi_n_i(tbi_w), .avec_n_i(avec_w), .br_n_o(br_n_o),
      .bg_n_i(bg_n), .bb_n_i(bb_w), .bb_n_o(bb_n_o), .bb_oe(bb_oe),
      .sc_i(sc_w), .mi_n_o(mi_n_o),
      .sn_addr(sn_addr), .sn_dhit(sn_dhit), .sn_ddirty(sn_ddirty), .sn_ihit(sn_ihit),
      .sn_rdata(sn_rdata), .sn_wr(sn_wr), .sn_wbe(sn_wbe), .sn_wdata(sn_wdata),
      .sn_dinv(sn_dinv), .sn_iinv(sn_iinv)
  );

  rd68041_snoopcache u_cache (
      .clk(clk), .sn_addr(sn_addr), .sn_dhit(sn_dhit), .sn_ddirty(sn_ddirty),
      .sn_ihit(sn_ihit), .sn_rdata(sn_rdata), .sn_wr(sn_wr), .sn_wbe(sn_wbe),
      .sn_wdata(sn_wdata), .sn_dinv(sn_dinv), .sn_iinv(sn_iinv)
  );

  rd68041_slave #(.MEM_BYTES(65536)) u_slave (
      .clk(clk), .a(a_w), .d_in(dbus), .d_out(slave_d), .d_oe(slave_d_oe),
      .tt(tt_w), .tm(tm_o), .rw(rw_w), .siz(siz_w), .ts_n(ts_w), .mi_n(mi_n_o),
      .ta_n(s_ta_n), .tea_n(s_tea_n), .tbi_n(s_tbi_n), .tci_n(s_tci_n),
      .avec_n(s_avec_n)
  );

  logic mon_on = 1'b0;
  rd68041_busmon u_mon (
      .clk(clk), .active(mon_on && !crst), .a_o(a_o), .a_oe(a_oe), .attr_oe(attr_oe),
      .tt_o(tt_o), .tm_o(tm_o), .siz_o(siz_o), .rw_o(rw_o), .d_oe(d_oe),
      .ts_n_o(ts_n_o), .tip_n_o(tip_n_o), .tip_oe(tip_oe), .bb_n_o(bb_n_o),
      .bb_oe(bb_oe), .slave_d_oe(slave_d_oe), .ta_n(ta_w), .tea_n(tea_w),
      .tbi_n(tbi_w), .alt_owns(am_own), .core_slave(ta_oe)
  );

  localparam logic [1:0] L = 2'b00, B = 2'b01, W = 2'b10, LN = 2'b11;
  localparam logic [31:0] NOBODY  = 32'h8000_0100;   // the testbench's device
  localparam logic [31:0] DIRTY_X = 32'h8000_0600;   // a dirty line in the stand-in cache
  localparam logic [31:0] MISS_Y  = 32'h8000_0700;   // ... and one it does not hold
  localparam logic [31:0] DATA_A  = 32'hA5A5_A5A5;
  localparam logic [31:0] DATA_B  = 32'h5A5A_5A5A;

  // ---------------------------------------------------------------------------
  // The request queue, as in rd68041_bus_harness.svh
  // ---------------------------------------------------------------------------
  localparam int QN = 256;
  logic [31:0]  q_addr  [0:QN-1];
  logic         q_write [0:QN-1];
  logic  [1:0]  q_siz   [0:QN-1];
  logic  [1:0]  q_tt    [0:QN-1];
  logic  [2:0]  q_tm    [0:QN-1];
  logic         q_lock  [0:QN-1];
  logic         q_locke [0:QN-1];
  logic         q_ciout [0:QN-1];
  logic [127:0] q_wdata [0:QN-1];
  int q_head = 0, q_tail = 0;
  int n_done = 0, n_rsp = 0;
  int fails = 0;

  task automatic push(input logic [31:0] addr, input bit write, input logic [1:0] siz,
                      input logic [127:0] wdata = 128'h0123_4567_89AB_CDEF_FEDC_BA98_7654_3210,
                      input logic [1:0] tt = 2'b00, input logic [2:0] tm = 3'b101,
                      input bit lock = 0, input bit locke = 0, input bit ciout = 0);
    q_addr[q_tail] = addr; q_write[q_tail] = write; q_siz[q_tail] = siz;
    q_tt[q_tail] = tt; q_tm[q_tail] = tm; q_lock[q_tail] = lock;
    q_locke[q_tail] = locke; q_ciout[q_tail] = ciout; q_wdata[q_tail] = wdata;
    q_tail = q_tail + 1;
  endtask

  task automatic update_port();
    req_valid = (q_head < q_tail);
    req_addr  = q_addr[q_head];  req_write = q_write[q_head];
    req_siz   = q_siz[q_head];   req_tt    = q_tt[q_head];
    req_tm    = q_tm[q_head];    req_lock  = q_lock[q_head];
    req_locke = q_locke[q_head]; req_ciout = q_ciout[q_head];
    req_wdata = q_wdata[q_head];
    req_tln   = 2'b00;           req_upa   = 2'b00;
    req_more  = (q_head + 1 < q_tail);
  endtask

  always @(q_head, q_tail) update_port();
  initial update_port();

  always @(posedge clk) if (req_valid && req_ready) q_head <= q_head + 1;

  // What the responses said, for the probes' outcomes.
  realtime t_done = 0.0;
  logic        first_tci, first_avec;
  logic [31:0] first_data;
  bit          first_seen = 0;
  always @(posedge clk) begin
    #(0.1);
    if (rsp_valid) begin
      if (!first_seen) begin
        first_tci = rsp_tci; first_avec = rsp_avec; first_data = rsp_data;
        first_seen = 1;
      end
      n_rsp = n_rsp + 1;
    end
    if (rsp_done) begin
      n_done = n_done + 1;
      t_done = $realtime - 0.1;
      if (!first_seen) begin first_avec = rsp_avec; first_seen = 1; end
    end
  end

  // Wait until every queued request is done (or give up).
  task automatic run_queue(input int limit = 400);
    int t;
    t = 0;
    while ((q_head < q_tail || n_done < q_tail) && t < limit) begin
      @(negedge clk);
      t = t + 1;
    end
    if (n_done < q_tail) begin
      fails = fails + 1;
      $display("  FAIL: the queue did not drain (%0d of %0d done) at %0t", n_done, q_tail, $time);
      n_done = q_tail;
    end
    @(negedge clk);
  endtask

  // The data a snooped write left in the stand-in cache.
  logic [31:0] sink_data;
  always @(posedge clk) begin #(0.2); if (sn_wr) sink_data = sn_wdata; end

  // ---------------------------------------------------------------------------
  // The testbench's device: a registered memory above $8000_0000, deciding on
  // each rising edge and driving from the falling edge after, waiting for MI
  // negated before it answers (UM 7.9). A line is four beats unless it
  // answered the first with TBI.
  // ---------------------------------------------------------------------------
  bit dv_busy = 0, dv_line = 0, dv_rw = 1, dv_mi = 0;
  int dv_beat = 0;
  always @(posedge clk) begin : devfsm
    bit ta_was, tbi_was;
    ta_was  = !dev_ta_n;
    tbi_was = !dev_tbi_n;
    if (!ts_w) begin
      dv_busy = dev_auto && a_w[31];
      dv_line = (siz_w == LN);
      dv_rw   = rw_w;
      dv_beat = 0;
    end else if (dv_busy && ta_was) begin
      if (dv_line && dv_beat < 3 && !(dv_beat == 0 && tbi_was)) dv_beat = dv_beat + 1;
      else dv_busy = 0;
    end
    dv_mi = mi_n_o;
    @(negedge clk);
    if (dev_auto) begin
      if (dv_busy && dv_mi) begin
        dev_ta_n = 1'b0;
        if (dv_rw) begin dev_d = DATA_A; dev_d_oe = 1'b1; end
      end else begin
        dev_ta_n = 1'b1;
        dev_d_oe = 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // The log
  // ---------------------------------------------------------------------------
  integer log;
  string  logname;
  logic   recording = 1'b0;
  string  edge_c;
  bit     primed = 0;

  // The previous snapshot, so that a transition is a difference.
  logic [31:0] p_a, p_d;
  logic  [1:0] p_tt, p_tln, p_upa, p_siz;
  logic  [2:0] p_tm;
  logic        p_rw, p_lock, p_locke, p_ciout, p_aoe, p_doe;
  logic        p_ts, p_tip, p_tipoe, p_bb, p_bboe, p_ta, p_taoe, p_br, p_mi;
  logic        p_bbon, p_tipon, p_taon, p_rank0;
  logic  [2:0] p_st;
  realtime     last_cap = 0.0;      // the last edge the modes were captured on

  task automatic emit(input string name);
    if (recording) $fdisplay(log, "T %0.3f %s %s", $realtime - SNAP, edge_c, name);
  endtask

  task automatic emit_in(input string name);
    if (recording) $fdisplay(log, "T %0.3f X %s", $realtime, name);
  endtask

  // A three-state control pin, active low: driven, asserted, negated, released.
  task automatic tri_pin(input string name, input logic oe, input logic v,
                         input logic poe, input logic pv);
    string lvl;
    if (v) lvl = $sformatf("%s.negate", name);
    else   lvl = $sformatf("%s.assert", name);
    if (oe && !poe) begin
      emit($sformatf("%s.drive", name));
      emit(lvl);
    end else if (oe && poe && (v !== pv)) begin
      emit(lvl);
    end else if (!oe && poe) begin
      emit($sformatf("%s.hiz", name));
    end
  endtask

  task automatic snap(input string which);
    edge_c = which;
    if (primed) begin
      // Edges inside the core first, so that the pairing rule sees a sample
      // before a pin that moves on the same edge.
      if (which == "R") begin
        // The edge a read's last TA was sampled on: rsp_done is registered
        // there, and R/W before the edge says it was a read.
        if (rsp_done && p_rw && p_aoe) emit("smp.rdend");
        // The edge the core saw BB negated, with BG, and took the bus: out of
        // idle, into a transfer or implicit ownership (UM 7.8.1).
        if ((p_st == 3'd1) && (u_biu.st != 3'd1)) emit("smp.bbfree");
        // The late-release registers dropping: negated here, released half a
        // clock on (rtl/rd68041_late_release.sv).
        if (p_bbon  && !u_biu.u_bb_rel.on_q)  emit("clk.bb_rel");
        if (p_tipon && !u_biu.u_tip_rel.on_q) emit("clk.tip_rel");
        if (p_taon  && !u_biu.u_ta_rel.on_q)  emit("clk.ta_rel");
        // rd68041_rstctl captures the modes on every edge its first rank still
        // reads RSTI asserted.
        if (!p_rank0) last_cap = $realtime - SNAP;
      end

      // The address group: the address and every attribute specification 11
      // names with it move together and are judged together.
      if (a_oe !== attr_oe) begin
        fails = fails + 1;
        $display("  FAIL: a_oe and attr_oe differ at %0t", $time);
      end
      if (a_oe && !p_aoe) begin
        emit("addr.drive");
        emit("addr.valid");
      end else if (a_oe && p_aoe &&
                   ({a_o, tt_o, tm_o, tln_o, upa_o, rw_o, siz_o, lock_n_o, locke_n_o,
                     ciout_n_o} !== {p_a, p_tt, p_tm, p_tln, p_upa, p_rw, p_siz,
                                     p_lock, p_locke, p_ciout})) begin
        emit("addr.invalid");
        emit("addr.valid");
      end else if (!a_oe && p_aoe) begin
        emit("addr.invalid");
        emit("addr.hiz");
      end

      // The data bus, as the core drives it.
      if (d_oe && !p_doe) begin
        emit("dout.drive");
        emit("dout.valid");
      end else if (d_oe && p_doe && (d_o !== p_d)) begin
        emit("dout.invalid");
        emit("dout.valid");
      end else if (!d_oe && p_doe) begin
        emit("dout.invalid");
        emit("dout.hiz");
      end

      // TS shares the address group's enable (rd68041_top).
      tri_pin("ts", attr_oe, ts_n_o, p_aoe, p_ts);
      tri_pin("tip", tip_oe, tip_n_o, p_tipoe, p_tip);
      tri_pin("bb", bb_oe, bb_n_o, p_bboe, p_bb);
      tri_pin("ta", ta_oe, ta_n_o, p_taoe, p_ta);
      if (br_n_o !== p_br) emit(br_n_o ? "br.negate" : "br.assert");
      if (mi_n_o !== p_mi) emit(mi_n_o ? "mi.negate" : "mi.assert");
    end

    p_a = a_o; p_tt = tt_o; p_tm = tm_o; p_tln = tln_o; p_upa = upa_o; p_rw = rw_o;
    p_siz = siz_o; p_lock = lock_n_o; p_locke = locke_n_o; p_ciout = ciout_n_o;
    p_aoe = a_oe; p_d = d_o; p_doe = d_oe;
    p_ts = ts_n_o; p_tip = tip_n_o; p_tipoe = tip_oe; p_bb = bb_n_o; p_bboe = bb_oe;
    p_ta = ta_n_o; p_taoe = ta_oe; p_br = br_n_o; p_mi = mi_n_o;
    if (which == "R") begin
      p_bbon = u_biu.u_bb_rel.on_q; p_tipon = u_biu.u_tip_rel.on_q;
      p_taon = u_biu.u_ta_rel.on_q; p_rank0 = u_rst.rank0; p_st = u_biu.st;
    end
    primed = 1;
  endtask

  always @(posedge clk) begin #(SNAP); if (rst_n) snap("R"); end
  always @(negedge clk) begin #(SNAP); if (rst_n) snap("F"); end

  // Every pin of the core, watched for a change anywhere but on a clock edge.
  int offedge = 0;
  always @(a_o or a_oe or attr_oe or tt_o or tm_o or tln_o or upa_o or rw_o or siz_o or
           lock_n_o or locke_n_o or ciout_n_o or ts_n_o or tip_n_o or tip_oe or
           ta_n_o or ta_oe or d_o or d_oe or br_n_o or bb_n_o or bb_oe or mi_n_o)
    if (rst_n && ($realtime - last_edge > 0.001)) begin
      offedge = offedge + 1;
      $display("  FAIL: a pin of the core moved at %0t, off every clock edge", $time);
    end

  task automatic scenario(input string name);
    $fdisplay(log, "S %s", name);
    recording = 1'b1;
    mon_on = 1'b1;
  endtask

  task automatic quiesce();
    repeat (6) @(posedge clk);
    recording = 1'b0;
    mon_on = 1'b0;
    repeat (2) @(posedge clk);
  endtask

  // ---------------------------------------------------------------------------
  // Arbitration and the alternate master
  // ---------------------------------------------------------------------------
  // Take BG away from the core and wait until it has let go of everything.
  task automatic core_off();
    int t;
    @(negedge clk); bg_n = 1'b1;
    t = 0;
    while ((owner || bb_oe || tip_oe || a_oe || ta_oe) && t < 50) begin
      @(negedge clk); t = t + 1;
    end
    @(negedge clk);
  endtask

  task automatic core_on();
    @(negedge clk); bg_n = 1'b0;
    repeat (2) @(negedge clk);
  endtask

  // The alternate master takes the bus the core has let go of.
  task automatic am_acquire();
    @(negedge clk);
    am_bb_oe = 1'b1; am_bb_n = 1'b0; am_own = 1'b1; am_ts_n = 1'b1;
    am_a = 32'h0000_0000; am_tt = 2'b00; am_siz = L; am_rw = 1'b1; am_sc = 2'b00;
    @(negedge clk);
  endtask

  // ... and gives it back: BB negated, then released a clock later.
  task automatic am_release();
    @(negedge clk);
    am_bb_n = 1'b1; am_own = 1'b0; am_d_oe = 1'b0; am_sc = 2'b00;
    @(negedge clk);
    am_bb_oe = 1'b0;
  endtask

  // One transfer by the alternate master, as rd68041_altmaster runs it but
  // driven from falling edges: TS for one clock, the attributes held to the
  // termination, a line's four TAs, TBI's three long words.
  task automatic am_xfer(input logic [31:0] addr, input bit write, input logic [1:0] siz,
                         input logic [1:0] sc, input logic [1:0] tt = 2'b00,
                         input logic [127:0] wdata = 128'h1111_2222_3333_4444_5555_6666_7777_8888);
    int beat, k, t;
    bit fin, tbi_seen, line;
    line = (siz == LN);
    tbi_seen = 0;
    @(negedge clk);
    am_a = addr; am_tt = tt; am_siz = siz; am_rw = !write; am_sc = sc; am_ts_n = 1'b0;
    @(negedge clk);
    am_ts_n = 1'b1;
    if (write) begin am_d = wdata[31:0]; am_d_oe = 1'b1; end
    beat = 0; fin = 0; t = 0;
    while (!fin && t < 40) begin
      @(posedge clk);
      t = t + 1;
      if (!ta_w && !tea_w) fin = 1;
      else if (!tea_w) fin = 1;
      else if (!ta_w) begin
        if (!line) fin = 1;
        else if (beat == 0 && !tbi_w) begin tbi_seen = 1; fin = 1; end
        else if (beat == 3) fin = 1;
        else begin
          beat = beat + 1;
          @(negedge clk);
          if (write) am_d = wdata[32*beat +: 32];
        end
      end
    end
    if (tbi_seen) begin
      for (k = 1; k < 4; k++) begin
        @(negedge clk);
        am_a = {addr[31:4], addr[3:2] + k[1:0], addr[1:0]}; am_siz = L; am_ts_n = 1'b0;
        am_d_oe = 1'b0;
        @(negedge clk);
        am_ts_n = 1'b1;
        if (write) begin am_d = wdata[32*k +: 32]; am_d_oe = 1'b1; end
        fin = 0; t = 0;
        while (!fin && t < 40) begin
          @(posedge clk); t = t + 1;
          if (!ta_w || !tea_w) fin = 1;
        end
      end
    end
    @(negedge clk);
    am_d_oe = 1'b0;
    if (t >= 40) begin
      fails = fails + 1;
      $display("  FAIL: the alternate master's transfer at %h was never terminated", addr);
    end
  endtask

  // ---------------------------------------------------------------------------
  // The reset
  // ---------------------------------------------------------------------------
  // Wait for the internal reset to end, and say when the modes were captured.
  task automatic wait_crst_off();
    int t;
    t = 0;
    while (crst && t < 400) begin @(negedge clk); t = t + 1; end
    if (crst) begin
      fails = fails + 1;
      $display("  FAIL: the internal reset never ended");
    end
  endtask

  // ---------------------------------------------------------------------------
  // The probes
  // ---------------------------------------------------------------------------
  localparam int I_TA = 0, I_TEA = 1, I_TCI = 2, I_TBI = 3, I_AVEC = 4, I_DATA = 5;
  localparam int I_BG = 6, I_BB = 7;
  localparam int I_AM_TS = 8, I_AM_A = 9, I_AM_SIZ = 10, I_AM_TT = 11, I_AM_RW = 12;
  localparam int I_AM_SC = 13, I_AM_DATA = 14, I_TA_SNOOP = 15;
  localparam int I_RSTI = 16, I_CDIS = 17, I_MDIS = 18, I_IPL = 19;

  // Apply (v = 1) the probed change, or undo it (v = 0).
  task automatic stim(input int which, input bit v);
    case (which)
      I_TA, I_TA_SNOOP: dev_ta_n = !v;
      I_TEA:     dev_tea_n  = !v;
      I_TCI:     dev_tci_n  = !v;
      I_TBI:     dev_tbi_n  = !v;
      I_AVEC:    dev_avec_n = !v;
      I_DATA:    dev_d      = v ? DATA_B : DATA_A;
      I_BG:      bg_n       = !v;
      I_BB:      am_bb_n    = v;            // the alternate master negates BB
      I_AM_TS:   am_ts_n    = !v;
      I_AM_A:    am_a       = v ? DIRTY_X : MISS_Y;
      I_AM_SIZ:  am_siz     = v ? LN : L;
      I_AM_TT:   am_tt      = v ? 2'b00 : 2'b10;
      I_AM_RW:   am_rw      = !v;           // read -> write
      I_AM_SC:   am_sc      = v ? 2'b01 : 2'b00;
      I_AM_DATA: am_d       = v ? DATA_B : DATA_A;
      I_RSTI:    rsti_n     = v;            // RSTI negated
      I_CDIS:    cdis_n     = !v;
      I_MDIS:    mdis_n     = !v;
      I_IPL:     ipl_n      = v ? 3'b000 : 3'b111;
      default:   ;
    endcase
  endtask

  // A pulse: the probes of terminations and TS are held to one rising edge.
  function automatic bit is_pulse(input int which);
    is_pulse = (which == I_TA) || (which == I_TEA) || (which == I_TCI) ||
               (which == I_TBI) || (which == I_AVEC) || (which == I_AM_TS) ||
               (which == I_TA_SNOOP);
  endfunction

  // Apply a stimulus at e + off, read the kind of edge e is off the clock a
  // quarter nanosecond either side of it, and withdraw a pulse a nanosecond
  // after the first rising edge that follows it.
  task automatic place(input real e, input real off, input int which, output string kind);
    logic c0, c1;
    if (off < 0.0) begin
      #(e + off - $realtime);  stim(which, 1'b1);
      #(e - 0.25 - $realtime); c0 = clk;
      #(e + 0.25 - $realtime); c1 = clk;
    end else begin
      #(e - 0.25 - $realtime); c0 = clk;
      #(e + 0.25 - $realtime); c1 = clk;
      #(e + off - $realtime);  stim(which, 1'b1);
    end
    if (c0 === 1'b1 && c1 === 1'b0)      kind = "F";
    else if (c0 === 1'b0 && c1 === 1'b1) kind = "R";
    else                                 kind = "?";
    if (is_pulse(which)) begin
      @(posedge clk);
      #(1.0);
      stim(which, 1'b0);
    end
  endtask

  function automatic string both(input string a, input string b);
    if (a == b) both = a;
    else        both = "?";
  endfunction

  // Everything withdrawn, the bus idle.
  task automatic settle();
    dev_ta_n = 1'b1; dev_tea_n = 1'b1; dev_tbi_n = 1'b1; dev_tci_n = 1'b1;
    dev_avec_n = 1'b1; dev_d_oe = 1'b0; dev_d = DATA_A; dev_auto = 1'b1;
    am_ts_n = 1'b1; am_d_oe = 1'b0;
    repeat (6) @(posedge clk);
    @(negedge clk);
  endtask

  // Times of the core's pins, for the outcomes.
  realtime t_ts = 0.0, t_ta = 0.0, t_mi = 0.0, t_crst = 0.0;
  int      n_ts = 0, n_cta = 0;
  bit      seen_doe = 0;
  always @(negedge ts_n_o) if (attr_oe) begin t_ts = $realtime; n_ts = n_ts + 1; end
  always @(negedge mi_n_o) t_mi = $realtime;
  always @(negedge crst) t_crst = $realtime;
  always @(posedge clk) begin
    if (ta_oe && !ta_n_o) n_cta = n_cta + 1;     // core TAs sampled at this edge
    if (d_oe) seen_doe = 1;
  end
  always @(negedge ta_n_o) if (ta_oe || u_biu.u_ta_rel.on_d) t_ta = $realtime;

  // --- the core as master: TA, TEA, TCI, TBI, AVEC and read data ------------
  task automatic master_run(input int which, input real off, output real outc,
                            output string kind);
    real e;
    int  ts0, t;
    first_seen = 0;
    dev_auto = !((which == I_TA) || (which == I_TEA));
    ts0 = n_ts;
    case (which)
      I_TCI, I_TBI: push(NOBODY, 0, LN);
      I_AVEC:       push(32'hFFFF_FFFF, 0, B, '0, 2'b11, 3'd5);
      default:      push(NOBODY, 0, L);
    endcase
    t = 0;
    while (n_ts == ts0 && t < 50) begin @(negedge clk); t = t + 1; end
    // TS was asserted at last_rise: C1. TA is first sampled two edges on.
    e = last_rise + 2.0 * T;
    if (which == I_TA || which == I_TEA) begin
      @(negedge clk); dev_d = DATA_A; dev_d_oe = 1'b1;
    end
    place(e, off, which, kind);
    run_queue();
    case (which)
      I_TA, I_TEA: outc = t_done - e;
      I_TCI:       outc = first_tci;
      I_TBI:       outc = n_ts - ts0;
      I_AVEC:      outc = first_avec;
      I_DATA:      outc = (first_data === DATA_B) ? 1.0 : 0.0;
      default:     outc = -1.0;
    endcase
    settle();
  endtask

  // --- arbitration: BG and BB --------------------------------------------------
  task automatic arb_run(input int which, input real off, output real outc,
                         output string kind);
    real e;
    core_off();
    if (which == I_BB) begin
      am_bb_oe = 1'b1; am_bb_n = 1'b0;      // another master holds BB
      @(negedge clk); bg_n = 1'b0;
    end
    push(32'h0000_0800, 0, L);
    repeat (3) @(negedge clk);
    e = next_rise();
    place(e, off, which, kind);
    if (which == I_BB) begin
      @(negedge clk); am_bb_oe = 1'b0;      // ... and lets go of it
    end
    run_queue();
    outc = t_ts - e;
    settle();
  endtask

  // --- the snooper: TS, the attributes, the sunk data, memory's TA -------------
  task automatic snoop_run(input int which, input real off, output real outc,
                           output string kind);
    real e, ets;
    int  cta0, t;
    core_off();
    am_acquire();
    u_cache.clear();
    u_cache.set_dline(0, DIRTY_X, 4'b0001, 32'h0101_0101, 32'h0202_0202,
                      32'h0303_0303, 32'h0404_0404);
    dev_auto = (which != I_TA_SNOOP);
    cta0 = n_cta;
    seen_doe = 0;
    sink_data = '0;
    // The transfer's attributes, as they are before the probed change.
    am_a = DIRTY_X; am_siz = L; am_tt = 2'b00; am_rw = 1'b1; am_sc = 2'b01;
    case (which)
      I_AM_A:     am_a  = MISS_Y;
      I_AM_TT:    am_tt = 2'b10;
      I_AM_SC:    am_sc = 2'b00;
      I_AM_DATA:  begin am_rw = 1'b0; am_d = DATA_A; end
      I_TA_SNOOP: am_a  = MISS_Y;
      default:    ;
    endcase
    @(negedge clk);
    if (which == I_AM_TS) begin
      // TS itself, around the edge a clock after the attributes went out.
      e = next_rise() + T;
      place(e, off, which, kind);
      ets = e;
    end else begin
      am_ts_n = 1'b0;
      ets = next_rise();
      if (which == I_AM_DATA || which == I_TA_SNOOP) begin
        @(negedge clk); am_ts_n = 1'b1;
        if (which == I_AM_DATA) am_d_oe = 1'b1;
        // The sink captures the data on the edge after its TA goes out, two
        // after TS is seen; memory's TA is first possible three after.
        e = ets + ((which == I_AM_DATA) ? 2.0 : 3.0) * T;
        place(e, off, which, kind);
      end else begin
        e = ets;
        place(e, off, which, kind);
        @(negedge clk); am_ts_n = 1'b1;
      end
    end
    @(negedge clk); am_ts_n = 1'b1;
    if (!am_rw) am_d_oe = 1'b1;
    // Hold the bus while the transfer runs out.
    repeat (12) @(negedge clk);
    am_d_oe = 1'b0;
    case (which)
      I_AM_TS:    outc = t_ta - e;
      I_AM_SIZ:   outc = n_cta - cta0;
      I_AM_RW:    outc = seen_doe;
      I_AM_DATA:  outc = (sink_data === DATA_B) ? 1.0 : 0.0;
      I_TA_SNOOP: outc = t_mi - e;
      default:    outc = (n_cta - cta0) > 0;
    endcase
    t = 0;
    while (u_biu.u_snoop.st != 3'd0 && t < 40) begin @(negedge clk); t = t + 1; end
    am_release();
    u_cache.clear();
    core_on();
    settle();
  endtask

  // --- RSTI and the mode selects --------------------------------------------
  task automatic reset_run(input int which, input real off, output real outc,
                           output string kind);
    real e;
    @(negedge clk); rsti_n = 1'b0;
    repeat (12) @(negedge clk);
    e = next_rise();
    if (which == I_RSTI) begin
      place(e, off, which, kind);
    end else begin
      // RSTI negated just before the edge, so that the modes are captured on
      // that edge; the probed mode select moves around it.
      #(e - 0.5 - $realtime); rsti_n = 1'b1;
      place(e, off, which, kind);
    end
    wait_crst_off();
    case (which)
      I_RSTI: outc = t_crst - e;
      I_CDIS: outc = mode_mux;
      I_MDIS: outc = mode_dle;
      I_IPL:  outc = (mode_ipl == 3'b000);
      default: outc = -1.0;
    endcase
    cdis_n = 1'b1; mdis_n = 1'b1; ipl_n = 3'b111;
    settle();
  endtask

  task automatic probe(input string name, input int fam, input int which);
    real   ob, oa;
    string kb, ka;
    case (fam)
      0: begin master_run(which, -0.5, ob, kb); master_run(which, 0.5, oa, ka); end
      1: begin arb_run(which, -0.5, ob, kb);    arb_run(which, 0.5, oa, ka);    end
      2: begin snoop_run(which, -0.5, ob, kb);  snoop_run(which, 0.5, oa, ka);  end
      default: begin reset_run(which, -0.5, ob, kb); reset_run(which, 0.5, oa, ka); end
    endcase
    $fdisplay(log, "P %s %s %0.3f %0.3f %0.3f %0.3f", name, both(kb, ka), -0.5, 0.5, ob, oa);
  endtask

  // ---------------------------------------------------------------------------
  // The run
  // ---------------------------------------------------------------------------
  int t;
  initial begin
    if (!$value$plusargs("log=%s", logname)) logname = "build/timing-events.log";
    log = $fopen(logname, "w");
    for (int i = 0; i < 1024; i++) u_slave.poke_long(32'h0000_0000 + 4*i, 32'h1000_0000 + i);
    // Above $8000_0000 the slave waits for ever: the testbench's device answers.
    u_slave.set_region(0, 32'h8000_0000, 32'h8000_0000, 1000000, 0, 0, -1, 0);
    u_slave.set_region(1, 32'h0001_0000, 32'hFFFF_0000, 1, 0, 0, -1, 0);
    u_slave.set_region(2, 32'h0002_0000, 32'hFFFF_0000, 2, 0, 0, -1, 0);
    u_slave.set_region(3, 32'h0003_0000, 32'hFFFF_0000, 0, 1, 0, -1, 0);   // TBI
    u_slave.set_region(4, 32'h0004_0000, 32'hFFFF_0000, 0, 0, 1, -1, 0);   // TCI
    u_slave.set_region(5, 32'h0005_0000, 32'hFFFF_0000, 0, 0, 0, 2, 0);    // TEA, 3rd lw
    u_slave.set_region(6, 32'h0006_0000, 32'hFFFF_0000, 1, 0, 0, -1, 0);   // retry
    u_slave.set_region(7, 32'h0007_0000, 32'hFFFF_0000, 0, 0, 0, 0, 0);    // TEA
    wait (T > 0.0);
    $fdisplay(log, "C %0.3f %0.3f", T, H);

    // Out of power-on: RSTI asserted, BG asserted, the bus free.
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    repeat (12) @(negedge clk);
    rsti_n = 1'b1;
    wait_crst_off();
    repeat (4) @(negedge clk);

    // -----------------------------------------------------------------------
    // Reads: long words back to back, a byte, a word with a wait state, a
    // long word with two.
    // -----------------------------------------------------------------------
    scenario("read");
    push(32'h0000_0100, 0, L);
    push(32'h0000_0104, 0, L);
    push(32'h0000_0101, 0, B);
    push(32'h0001_0102, 0, W);
    push(32'h0002_0100, 0, L);
    run_queue();
    push(32'h0000_0108, 0, L);
    run_queue();
    quiesce();

    // -----------------------------------------------------------------------
    // Writes, the same.
    // -----------------------------------------------------------------------
    scenario("write");
    push(32'h0000_0200, 1, L, 128'h0000_0000_0000_0000_0000_0000_A1B2_C3D4);
    push(32'h0000_0204, 1, L, 128'h0000_0000_0000_0000_0000_0000_DEAD_BEEF);
    push(32'h0000_0203, 1, B, 128'h0000_0000_0000_0000_0000_0000_0000_0055);
    push(32'h0001_0202, 1, W, 128'h0000_0000_0000_0000_0000_0000_0000_1234);
    push(32'h0002_0200, 1, L, 128'h0000_0000_0000_0000_0000_0000_CAFE_F00D);
    run_queue();
    quiesce();

    // -----------------------------------------------------------------------
    // Read, write, read, write, back to back: R/W turns, and the data bus
    // goes from the slave's to the core's (specification 17).
    // -----------------------------------------------------------------------
    scenario("mixed");
    push(32'h0000_0300, 0, L);
    push(32'h0000_0300, 1, L, 128'h0000_0000_0000_0000_0000_0000_0102_0304);
    push(32'h0000_0304, 0, L);
    push(32'h0000_0308, 1, L, 128'h0000_0000_0000_0000_0000_0000_0506_0708);
    push(32'h0000_0310, 0, LN);
    push(32'h0000_0320, 1, LN);
    run_queue();
    quiesce();

    // -----------------------------------------------------------------------
    // Lines: read and written by burst, burst-inhibited (TBI), cache-inhibited
    // (TCI), and with a wait state before every long word.
    // -----------------------------------------------------------------------
    scenario("line");
    push(32'h0000_0404, 0, LN);
    push(32'h0000_0440, 1, LN);
    push(32'h0003_0408, 0, LN);
    push(32'h0003_0440, 1, LN);
    push(32'h0004_0400, 0, LN);
    push(32'h0001_0400, 0, LN);
    push(32'h0001_0440, 1, LN);
    run_queue();
    quiesce();

    // -----------------------------------------------------------------------
    // Bus errors and retries: TEA on a long word, TEA on a line's third long
    // word, a retried write run again, and a relinquish and retry -- BG taken
    // away before the retry, the bus given up, and the transfer run again
    // once it comes back (UM 7.6).
    // -----------------------------------------------------------------------
    scenario("error");
    push(32'h0007_0000, 0, L);
    push(32'h0005_0000, 0, LN);
    u_slave.set_region(6, 32'h0006_0000, 32'hFFFF_0000, 1, 0, 0, -1, 1);
    push(32'h0006_0000, 1, L);
    run_queue();
    u_slave.set_region(6, 32'h0006_0000, 32'hFFFF_0000, 1, 0, 0, -1, 1);
    t = n_ts;
    push(32'h0006_0010, 0, L);
    while (n_ts == t) @(negedge clk);
    bg_n = 1'b1;
    repeat (6) @(negedge clk);
    bg_n = 1'b0;
    run_queue();
    quiesce();

    // -----------------------------------------------------------------------
    // Arbitration (UM 7.8.1): a request without BG (BR); BG while another
    // master holds BB, then BB released (specification 49); park; BG taken
    // away in the middle of a transfer (38, 39); implicit ownership and
    // leaving it for a transfer and for idle; BG taken away in park; a locked
    // sequence.
    // -----------------------------------------------------------------------
    scenario("arb");
    core_off();
    push(32'h0000_0500, 0, L);
    repeat (3) @(negedge clk);
    am_bb_oe = 1'b1; am_bb_n = 1'b0;
    @(negedge clk); bg_n = 1'b0;
    repeat (3) @(negedge clk);
    am_bb_n = 1'b1;
    @(negedge clk); am_bb_oe = 1'b0;
    run_queue();
    repeat (3) @(negedge clk);                  // park
    push(32'h0002_0504, 1, L);
    repeat (2) @(negedge clk);
    bg_n = 1'b1;                                // given up at the end of it
    run_queue();
    repeat (4) @(negedge clk);
    bg_n = 1'b0;                                // implicit ownership
    repeat (4) @(negedge clk);
    push(32'h0000_0508, 0, L);                  // leaving it for a transfer
    run_queue();
    repeat (3) @(negedge clk);
    bg_n = 1'b1;                                // park, then given up
    repeat (4) @(negedge clk);
    bg_n = 1'b0;                                // implicit ownership ...
    repeat (4) @(negedge clk);
    bg_n = 1'b1;                                // ... and idle again
    repeat (4) @(negedge clk);
    bg_n = 1'b0;
    repeat (3) @(negedge clk);
    lock_seq = 1'b1;
    push(32'h0000_0510, 0, L, '0, 2'b00, 3'b101, 1, 0);
    push(32'h0000_0510, 1, L, 128'h0000_0000_0000_0000_0000_0000_8000_0001,
         2'b00, 3'b101, 1, 1);
    run_queue();
    lock_seq = 1'b0;
    repeat (3) @(negedge clk);
    quiesce();

    // -----------------------------------------------------------------------
    // Snooping (UM 7.9, Tables 4-3 and 4-4): an alternate master's transfers,
    // snoop-inhibited, missing, hitting a clean line, a dirty line sourced by
    // the core (a line, TA and the data driven by the core), a dirty line
    // sunk by the core, a write that misses, and a non-snoopable TT. Then the
    // bus back to the core (specification 49 again).
    // -----------------------------------------------------------------------
    scenario("snoop");
    core_off();
    am_acquire();
    u_cache.clear();
    u_cache.set_dline(0, 32'h0000_0620, 4'b0000, 32'h0, 32'h0, 32'h0, 32'h0);
    u_cache.set_dline(1, 32'h8000_0640, 4'b0010, 32'hD0D0_0000, 32'hD0D0_0001,
                      32'hD0D0_0002, 32'hD0D0_0003);
    u_cache.set_dline(2, 32'h8000_0680, 4'b1000, 32'hE0E0_0000, 32'hE0E0_0001,
                      32'hE0E0_0002, 32'hE0E0_0003);
    am_xfer(32'h0000_0600, 0, L, 2'b00);                 // snoop inhibited
    am_xfer(32'h0000_0610, 0, L, 2'b01);                 // miss
    am_xfer(32'h0000_0620, 0, L, 2'b10);                 // clean hit, invalidated
    am_xfer(32'h8000_0644, 0, LN, 2'b01);                // dirty: sourced, a line
    am_xfer(32'h8000_0680, 1, L, 2'b01);                 // dirty: sunk
    am_xfer(32'h0000_0630, 1, L, 2'b01);                 // a write that misses
    am_xfer(32'h0000_0634, 0, L, 2'b01, 2'b10);          // alternate function code
    am_xfer(32'h8000_0688, 0, L, 2'b10);                 // dirty: sourced, a long word
    am_release();
    u_cache.clear();
    push(32'h0000_0640, 0, L);
    core_on();
    run_queue();
    quiesce();

    // -----------------------------------------------------------------------
    // Reset (UM 7.10): RSTI in the middle of a transfer -- BB and TIP negated,
    // then released -- and negated twice, half a nanosecond after a rising
    // edge and half a nanosecond before one: the two ends of where the mode
    // selects can be captured relative to it (specifications 53 and 54).
    // -----------------------------------------------------------------------
    scenario("reset");
    dev_auto = 1'b0;
    push(NOBODY, 0, L);                         // nobody answers it
    repeat (4) @(negedge clk);
    rsti_n = 1'b0;
    repeat (12) @(negedge clk);
    #(next_rise() + 0.5 - $realtime);
    rsti_n = 1'b1; emit_in("in.rsti.negate");
    wait_crst_off();
    $fdisplay(log, "T %0.3f R smp.mode", last_cap);
    q_tail = q_head; n_done = q_tail;           // the transfer reset cut short
    dev_auto = 1'b1;
    repeat (4) @(negedge clk);
    rsti_n = 1'b0;
    repeat (12) @(negedge clk);
    #(next_rise() - 0.5 - $realtime);
    rsti_n = 1'b1; emit_in("in.rsti.negate");
    wait_crst_off();
    $fdisplay(log, "T %0.3f R smp.mode", last_cap);
    quiesce();

    // -----------------------------------------------------------------------
    // The probes: where each input is sampled. Not recorded as transitions.
    // -----------------------------------------------------------------------
    $fdisplay(log, "S probe");
    settle();
    probe("ta",        0, I_TA);
    probe("tea",       0, I_TEA);
    probe("tci",       0, I_TCI);
    probe("tbi",       0, I_TBI);
    probe("avec",      0, I_AVEC);
    probe("data_read", 0, I_DATA);
    probe("bg",        1, I_BG);
    probe("bb",        1, I_BB);
    probe("snoop_ts",  2, I_AM_TS);
    probe("snoop_a",   2, I_AM_A);
    probe("snoop_siz", 2, I_AM_SIZ);
    probe("snoop_tt",  2, I_AM_TT);
    probe("snoop_rw",  2, I_AM_RW);
    probe("snoop_sc",  2, I_AM_SC);
    probe("data_sink", 2, I_AM_DATA);
    probe("ta_snoop",  2, I_TA_SNOOP);
    probe("rsti",      3, I_RSTI);
    probe("mode_cdis", 3, I_CDIS);
    probe("mode_mdis", 3, I_MDIS);
    probe("mode_ipl",  3, I_IPL);

    $fdisplay(log, "H offedge_changes %0d", offedge);
    $fdisplay(log, "H monitor_errors %0d", u_mon.errors);
    $fclose(log);
    fails = fails + u_mon.errors + offedge;
    if (fails == 0) $display("PASS: rd68041_timing_tb (event log written, %0.3f ns, %0.3f high)", T, H);
    else            $display("FAIL: rd68041_timing_tb: %0d problems", fails);
    $finish;
  end

  initial begin
    wait (T > 0.0);
    #(40000.0 * T);
    $display("FAIL: rd68041_timing_tb timed out");
    $finish;
  end

endmodule
