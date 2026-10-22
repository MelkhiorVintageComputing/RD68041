// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- a protocol monitor for the MC68040 bus, for the testbenches.
//
// Watches the core's side of the bus on every rising edge and prints a line
// starting "  FAIL: busmon" for each rule broken; the testbench counts them
// (`errors`). The rules are UM 7's, as they read at a sampling edge:
//
//   - TS is asserted for one clock (UM 5.4.1), with TIP (UM 5.4.2), BB (UM
//     5.6.3) and the address group driven (UM 7.4.1, step 1-9);
//   - from TS to the termination, address and attributes do not change (UM
//     7.4.2: "the address and transfer attributes supplied by the processor
//     remain stable during the transfers");
//   - two drivers never meet on the data bus, and the core never drives BB,
//     TIP or the address group while another master owns the bus;
//   - BB and TIP are released half a clock after the edge that negates them
//     (specification 39), never at a rising edge while asserted.

`timescale 1ns/1ps

module rd68041_busmon (
    input  logic        clk,
    input  logic        active,      // check only when this is high
    // The core's outputs and enables.
    input  logic [31:0] a_o,
    input  logic        a_oe,
    input  logic        attr_oe,
    input  logic  [1:0] tt_o,
    input  logic  [2:0] tm_o,
    input  logic  [1:0] siz_o,
    input  logic        rw_o,
    input  logic        d_oe,
    input  logic        ts_n_o,
    input  logic        tip_n_o,
    input  logic        tip_oe,
    input  logic        bb_n_o,
    input  logic        bb_oe,
    // The other side.
    input  logic        slave_d_oe,
    input  logic        ta_n,
    input  logic        tea_n,
    input  logic        tbi_n,
    input  logic        alt_owns,    // an alternate master has the bus
    input  logic        core_slave   // the core answers it as a slave (snoop intervention)
);

  int errors;
  bit in_xfer;
  logic [31:0] h_a;
  logic  [1:0] h_tt, h_siz;
  logic  [2:0] h_tm;
  logic        h_rw;
  logic        ts_prev;
  int          nta;         // TA seen in this transfer

  initial begin errors = 0; in_xfer = 0; ts_prev = 1; end

  task automatic fail(input string what);
    errors = errors + 1;
    $display("  FAIL: busmon @%0t: %s", $time, what);
  endtask

  always @(posedge clk) if (!active) in_xfer = 0;

  always @(posedge clk) if (active) begin
    if (!ts_n_o) begin
      if (!ts_prev)          fail("TS asserted for two clocks running");
      if (!(a_oe && attr_oe)) fail("TS asserted with the address group released");
      if (tip_n_o || !tip_oe) fail("TS asserted without TIP");
      if (bb_n_o || !bb_oe)   fail("TS asserted without BB");
      in_xfer = 1; nta = 0;
      h_a = a_o; h_tt = tt_o; h_tm = tm_o; h_siz = siz_o; h_rw = rw_o;
    end else if (in_xfer) begin
      if (a_o !== h_a || tt_o !== h_tt || tm_o !== h_tm || siz_o !== h_siz || rw_o !== h_rw)
        fail($sformatf("address or attributes changed during a transfer: %h -> %h", h_a, a_o));
      if (!(a_oe && attr_oe)) fail("address group released during a transfer");
      if (tip_n_o)            fail("TIP negated during a transfer");
    end
    // A transfer ends on TEA, on its TA unless it is a line burst, on a
    // line's first TA with TBI, or on a line burst's fourth TA.
    if (in_xfer && ts_n_o) begin
      if (!tea_n) in_xfer = 0;
      else if (!ta_n) begin
        nta = nta + 1;
        if (h_siz != 2'b11 || !tbi_n || nta == 4) in_xfer = 0;
      end
    end
    ts_prev = ts_n_o;

    if (d_oe && slave_d_oe) fail("the core and the slave both drive the data bus");
    // As a slave the core drives the data bus and TA (UM 7.9.3), nothing else.
    if (alt_owns && (a_oe || attr_oe || (d_oe && !core_slave) || (bb_oe && !bb_n_o) ||
                     (tip_oe && !tip_n_o)))
      fail("the core drives the bus while an alternate master owns it");
  end

  // Specification 39: at a rising edge BB and TIP are either driven or
  // released, but never released while the value the core holds is asserted
  // (it would have to be driven); the half-clock hold is checked by the
  // testbench at the falling edge.
  always @(posedge clk) if (active) begin
    #1;
    if (!bb_oe && !bb_n_o)   fail("BB asserted but not driven");
    if (!tip_oe && !tip_n_o) fail("TIP asserted but not driven");
  end

endmodule
