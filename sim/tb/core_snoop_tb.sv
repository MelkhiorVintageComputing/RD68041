// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- snooping, on the whole processor: sim/programs/m9_snoop.S on the
// core, copyback-cached, and an alternate master (sim/models/rd68041_altmaster)
// on the same memory, given the bus by a random arbiter (UM 7.8), its every
// transfer snooped (UM 7.9, 4.4, Tables 4-1, 4-4). Each side writes only its
// own words, and only upwards, so coherence is checked without knowing how
// the two interleave:
//
//   - the master's reads of the program's words (A) never go down -- read as
//     words with SC 01 (the core sources a dirty line's word, leaving it
//     dirty), or as lines with SC 01 or SC 10 (sourced, then invalidated: the
//     board's memory takes the data the core drives, as UM 4.5 says a memory
//     controller must; UM 4.4.3 has mark invalid for line reads only, since a
//     word read would lose the rest of a dirty line);
//   - the program's reads of the master's words (B) never go down (D7), and
//     its last reads, after the master stops, are the master's last writes --
//     written as words with SC 01 (sunk into a dirty line, else memory and the
//     line invalidated) or as lines with SC 01 or 10 (the line invalidated).
//     UM 4.4.4 has a master sink its writes to copyback pages: an SC 10 word
//     write would drop the rest of a dirty line (D11);
//   - memory holds every A word at PASSES once the program has pushed its
//     cache (CPUSHA).
//
// The program's flags are in a cache-inhibited page; the board's memory
// repeats every 64 KB.

`timescale 1ns / 1ps

module core_snoop_tb;

  localparam logic [31:0] A = 32'h0000_6000, B = 32'h0000_6100, C = 32'h0000_6200;
  localparam logic [31:0] MARK = 32'h0000_FF00, FLAG = 32'h0000_FF04;
  localparam int PASSES = 24;

  logic clk = 1'b0;
  always #20 clk = ~clk;
  logic rst_n  = 1'b0;
  logic rsti_n = 1'b0;

  // --- the board -------------------------------------------------------------
  logic [31:0] a_o, d_o, slave_d;
  logic        a_oe, d_oe, attr_oe, slave_d_oe;
  logic  [1:0] tt_o, tln_o, upa_o, siz_o;
  logic  [2:0] tm_o;
  logic        rw_o, lock_n_o, locke_n_o, ciout_n_o, ts_n_o, ts_oe, tip_n_o, tip_oe;
  logic        ta_n_o, ta_oe, br_n_o, bb_n_o, bb_oe, mi_n_o, rsto_n_o, ipend_n_o;
  logic  [3:0] pst_o;
  logic        tdo_o, tdo_oe;
  logic        s_ta_n, tea_n, tbi_n, tci_n, avec_n;
  logic        bg_n = 1'b0;
  logic        am_own, am_d_oe, am_ts_n, am_bb_n, am_rw;
  logic [31:0] am_a, am_d;
  logic  [1:0] am_tt, am_siz, am_sc;

  wire [31:0] dbus  = d_oe ? d_o : (slave_d_oe ? slave_d : (am_d_oe ? am_d : 32'hzzzz_zzzz));
  wire        bb_w  = bb_oe ? bb_n_o : (am_own ? am_bb_n : 1'b1);
  wire        ts_w  = ts_oe ? ts_n_o : (am_own ? am_ts_n : 1'b1);
  wire [31:0] a_w   = a_oe ? a_o : (am_own ? am_a : 32'hFFFF_FFFF);
  wire  [1:0] tt_w  = attr_oe ? tt_o : (am_own ? am_tt : 2'b11);
  wire  [1:0] siz_w = attr_oe ? siz_o : (am_own ? am_siz : 2'b11);
  wire        rw_w  = attr_oe ? rw_o : (am_own ? am_rw : 1'b1);
  wire  [1:0] sc_w  = am_own ? am_sc : 2'b00;
  // TA: the slave's, or the core's as it answers a snooped transfer. Memory
  // answers only when MI lets it (the slave model waits for MI itself).
  wire        ta_n  = s_ta_n & (ta_oe ? ta_n_o : 1'b1);

  rd68041_top #(.FPU(`TB_FPU)) dut (
      .clk(clk), .pclk(1'b0), .rst_n(rst_n), .rsti_n_i(rsti_n), .rsto_n_o(rsto_n_o),
      .a_i(a_w), .a_o(a_o), .a_oe(a_oe), .d_i(dbus), .d_o(d_o), .d_oe(d_oe),
      .tt_i(tt_w), .tt_o(tt_o), .tm_o(tm_o), .tln_o(tln_o), .upa_o(upa_o),
      .rw_i(rw_w), .rw_o(rw_o), .siz_i(siz_w), .siz_o(siz_o),
      .lock_n_o(lock_n_o), .locke_n_o(locke_n_o), .ciout_n_o(ciout_n_o), .attr_oe(attr_oe),
      .ts_n_i(ts_w), .ts_n_o(ts_n_o), .ts_oe(ts_oe), .tip_n_o(tip_n_o), .tip_oe(tip_oe),
      .ta_n_i(ta_n), .ta_n_o(ta_n_o), .ta_oe(ta_oe), .tea_n_i(tea_n), .tci_n_i(tci_n),
      .tbi_n_i(tbi_n), .dle_i(1'b0), .sc_i(sc_w), .mi_n_o(mi_n_o),
      .br_n_o(br_n_o), .bg_n_i(bg_n), .bb_n_i(bb_w), .bb_n_o(bb_n_o), .bb_oe(bb_oe),
      .cdis_n_i(1'b1), .mdis_n_i(1'b1), .ipl_n_i(3'b111), .ipend_n_o(ipend_n_o),
      .avec_n_i(avec_n), .pst_o(pst_o),
      .tck_i(1'b0), .tms_i(1'b0), .tdi_i(1'b0), .trst_n_i(1'b1), .tdo_o(tdo_o), .tdo_oe(tdo_oe));

  rd68041_slave #(.MEM_BYTES(65536)) u_mem (
      .clk(clk), .a(a_w), .d_in(dbus), .d_out(slave_d), .d_oe(slave_d_oe),
      .tt(tt_w), .tm(tm_o), .rw(rw_w), .siz(siz_w), .ts_n(ts_w), .mi_n(mi_n_o),
      .ta_n(s_ta_n), .tea_n(tea_n), .tbi_n(tbi_n), .tci_n(tci_n), .avec_n(avec_n));

  rd68041_altmaster u_am (
      .clk(clk), .own(am_own), .a(am_a), .d(am_d), .d_oe(am_d_oe), .tt(am_tt),
      .siz(am_siz), .rw(am_rw), .sc(am_sc), .ts_n(am_ts_n), .bb_n(am_bb_n),
      .d_in(dbus), .ta_n(ta_n), .tea_n(tea_n), .tbi_n(tbi_n));

  int cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // --- the memory controller: what the core sources goes to memory too -------
  // (UM 4.5: "the memory controller must monitor the data transfer between the
  // processors and update memory with the transferred data".)
  logic [31:0] src_a;
  int          src_k;
  always @(posedge clk) begin
    if (!ts_w && am_own) begin src_a = a_w; src_k = 0; end
    if (am_own && ta_oe && !ta_n_o && d_oe && rw_w) begin
      u_mem.poke_long({src_a[31:4], 4'h0} + 4 * ((src_a[3:2] + src_k) % 4), d_o);
      src_k++;
    end
  end

  // --- the alternate master ------------------------------------------------------
  int unsigned nfail, nxfer, nsrc_seen;
  logic [31:0] seen_a [0:63];       // the largest each A word has read as
  logic [31:0] last_b [0:63];       // what the master last wrote to each B word
  bit          stop_am, done;
  int unsigned seed;

  task automatic am_one();
    int k, kind;
    logic [1:0] snoop;
    logic [127:0] wd;
    k     = $urandom % 64;
    kind  = $urandom % 6;
    snoop = ($urandom % 2) ? 2'b01 : 2'b10;
    case (kind)
      0, 1: begin                       // read an A word: SC 01 only -- UM 4.4.3:
                                        // "mark invalid only for line reads"
        u_am.xfer(A + 4*k, 0, 2'b00, 2'b01);
        check_a(k, u_am.got[0]);
      end
      2: begin                          // read an A line
        u_am.xfer(A + 16*(k/4), 0, 2'b11, snoop);
        for (int j = 0; j < 4; j++) check_a(4*(k/4) + j, u_am.got[j]);
      end
      3, 4: begin                       // write a B word: sunk (SC 01) -- UM 4.4.4,
                                        // "sink data for copyback pages"
        last_b[k] = last_b[k] + 1 + ($urandom % 5);
        u_am.xfer(B + 4*k, 1, 2'b00, 2'b01, {96'h0, last_b[k]});
      end
      default: begin                    // write a B line: either way, it replaces
                                        // the whole line (D13)
        for (int j = 0; j < 4; j++) begin
          last_b[4*(k/4) + j] = last_b[4*(k/4) + j] + 1;
          wd[32*j +: 32] = last_b[4*(k/4) + j];
        end
        u_am.xfer(B + 16*(k/4), 1, 2'b11, snoop, wd);
      end
    endcase
    nxfer++;
  endtask

  task automatic check_a(input int k, input logic [31:0] v);
    if (v < seen_a[k] || v > PASSES) begin
      if (nfail < 10)
        $display("  FAIL: [%0d] the master read A[%0d] as %0d, after %0d", cyc, k, v, seen_a[k]);
      nfail++;
    end else begin
      seen_a[k] = v;
    end
  endtask

  // The arbiter: the core has the bus; now and then it is taken away, the
  // master runs one transfer once the core has let go of BB, and the bus is
  // given back.
  initial begin
    @(posedge rsti_n);
    repeat (200) @(negedge clk);
    while (!stop_am) begin
      repeat (5 + $urandom % 40) @(negedge clk);
      if (!stop_am) begin
        bg_n = 1'b1;
        // Wait for the core to leave the bus: BB released and no transfer.
        while (!(bb_w && !bb_oe && !tip_oe)) @(negedge clk);
        am_one();
        @(negedge clk);
        bg_n = 1'b0;
      end
    end
    // The master has stopped: the program may read B for the last time.
    u_mem.poke_long(FLAG, 32'h1);
  end

  // The program's MARK: 1 when its passes are done, 2 at the very end.
  always @(negedge clk) begin
    logic [31:0] m;
    if (rst_n && !done) begin
      m = u_mem.peek_long(MARK);
      if (m == 32'h1) stop_am = 1;
      if (m == 32'h2) begin done = 1; finish_up(); end
    end
  end

  task automatic finish_up();
    int bad_a, bad_c;
    // The program's last write (MARK) has gone; its CPUSHA's pushes before it.
    bad_a = 0; bad_c = 0;
    for (int k = 0; k < 64; k++) begin
      if (u_mem.peek_long(A + 4*k) !== PASSES) begin
        if (bad_a < 4) $display("  FAIL: A[%0d] in memory is %0d, expected %0d",
                                k, u_mem.peek_long(A + 4*k), PASSES);
        bad_a++;
      end
      if (u_mem.peek_long(C + 4*k) !== last_b[k]) begin
        if (bad_c < 4) $display("  FAIL: the program's last read of B[%0d] was %0d, the master wrote %0d",
                                k, u_mem.peek_long(C + 4*k), last_b[k]);
        bad_c++;
      end
    end
    if (dut.u_core.u_rf.r[7] !== 32'h0) begin
      $display("  FAIL: the program saw %0d B words go down", dut.u_core.u_rf.r[7]);
      nfail++;
    end
    nfail = nfail + bad_a + bad_c;
    if (nfail == 0)
      $display("PASS: core_snoop_tb: %0d snooped transfers, coherent both ways", nxfer);
    else
      $display("FAIL: core_snoop_tb: %0d checks failed (%0d transfers)", nfail, nxfer);
    $finish;
  endtask

  initial begin
    string image;
    if (!$value$plusargs("image=%s", image)) image = "build/programs/m9_snoop.hex";
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    nfail = 0; nxfer = 0; stop_am = 0; done = 0;
    for (int k = 0; k < 64; k++) begin seen_a[k] = 0; last_b[k] = 0; end
    u_mem.load_hex(image);
    u_mem.set_region(0, 32'h0000_0000, 32'h0000_0000, 0, 0, 0, -1, 0);
    rst_n = 1'b0; rsti_n = 1'b0;
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (12) @(negedge clk);
    rsti_n = 1'b1;
  end

  initial begin
    #40000000;
    if (!done) begin
      $display("  FAIL: timed out: %0d transfers, MARK %0d", nxfer, u_mem.peek_long(MARK));
      $display("FAIL: core_snoop_tb");
      $finish;
    end
  end

endmodule
