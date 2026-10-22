// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- arbitration, locked sequences, MI and reset on the bus: UM 7.4.5,
// 7.6.2, 7.8.1, 7.9.1, 7.10.
//
// BR, BG and BB through the five states of UM 7.8.1 and Table 7-6: idle,
// implicit ownership, an active cycle, park, and giving the bus up -- with BB
// and TIP driven negated for half a clock before they are released
// (specification 39) and everything else released at the edge (38). A retry
// with BG negated is a relinquish and retry (UM 7.6.2). LOCK through a locked
// sequence and LOCKE on its last write (UM 7.4.5). MI asserted out of reset
// until the core's first cycle, negated while it is master, asserted when it
// gives the bus up (UM 7.9.1). And a reset in the middle of a transfer
// (UM 7.10).

`timescale 1ns/1ps

module bus_arb_tb;

`include "rd68041_bus_harness.svh"

  localparam logic [1:0] B = 2'b01, W = 2'b10, L = 2'b00, LN = 2'b11;

  int base, nd, starts, t;
  bit seen_ts, seen_lock_gap, seen_locke_read, seen_locke_write, seen_br_with_ts;

  // The values of BB and TIP in the middle of each half clock: specification 39
  // says how long after the rising edge they are released.
  logic bb_hi_first, bb_oe_first, bb_oe_second;
  task automatic sample_release();
    // Called 1 ns after a rising edge: look a quarter clock in, then three
    // quarters.
    #9; bb_hi_first = bb_n_o; bb_oe_first = bb_oe;
    #20; bb_oe_second = bb_oe;
  endtask

  initial begin
    for (int i = 0; i < 256; i++) u_slave.poke_long(32'h1000 + 4*i, 32'hA000_0000 + i);
    u_slave.set_region(0, 32'h0000_0000, 32'hFFFF_0000, 0, 0, 0, -1, 0);

    // --- 1. out of reset with BG asserted and the bus free: implicit ownership
    bg_n = 1'b0;
    reset_all();
    repeat (3) @(negedge clk);
    check(!mi_n_o, "MI asserted after reset, before the core's first cycle (UM 7.9.1)");
    check(a_oe && attr_oe && !bb_oe && tip_oe && tip_n_o && ts_n_o,
          "implicit ownership: the bus driven, BB three-stated, TS and TIP negated (UM 7.8.1)");
    check(br_n_o, "implicit ownership: BR negated, nothing pending");

    // BG taken away: the bus is released at the next edge.
    bg_n = 1'b1;
    @(negedge clk); @(negedge clk);
    check(!a_oe && !attr_oe && !bb_oe, "BG negated in implicit ownership: idle, nothing driven");

    // --- 2. a request with BG negated: BR, and no cycle -------------------
    push(32'h1000, 0, L);
    repeat (3) @(negedge clk);
    check(!br_n_o, "BR asserted for a pending access (UM 5.6.1)");
    check(ts_n_o && !a_oe && !bb_oe, "no cycle without BG");
    // The arbiter grants, but an alternate master still holds BB.
    alt_bb_n = 1'b0; alt_bb_oe = 1'b1;
    bg_n = 1'b0;
    repeat (3) @(negedge clk);
    check(ts_n_o && !a_oe, "no cycle while BB is asserted by another master (UM 5.6.2)");
    // It lets go: BB negated, then released.
    seen_ts = 0;
    fork begin
      repeat (4) begin @(posedge clk); #1; if (!ts_n_o && !bb_n_o && bb_oe && !tip_n_o) seen_ts = 1; end
    end join_none
    alt_bb_n = 1'b1; @(negedge clk); alt_bb_oe = 1'b0;
    run_queue();
    check(seen_ts, "BG and BB free: BB, TS and TIP asserted together");
    check(mi_n_o, "MI negated while the core is master (UM 5.5.2)");

    // --- 3. park: BG kept, nothing pending ----------------------------------
    repeat (3) @(negedge clk);
    check(!bb_n_o && bb_oe && tip_n_o && tip_oe && a_oe,
          "park: BB asserted, TIP negated, the bus driven (UM 7.8.1)");
    // Leaving park: BR, TIP and TS together.
    seen_br_with_ts = 0;
    push(32'h1004, 0, L);
    fork begin
      repeat (3) begin @(posedge clk); #1; if (!ts_n_o && !br_n_o && !tip_n_o) seen_br_with_ts = 1; end
    end join
    run_queue();
    check(seen_br_with_ts, "leaving park: BR asserted with TS and TIP (UM 7.8.1)");

    // --- 4. BG negated during a transfer: finished, then the bus given up ---
    u_slave.set_region(1, 32'h0000_2000, 32'hFFFF_FF00, 2, 0, 0, -1, 0);
    nd = n_done;
    push(32'h2000, 0, L);
    @(negedge clk); @(negedge clk);   // the transfer is under way
    bg_n = 1'b1;
    // rsp_done is registered on the edge that sampled the last TA: that edge
    // is also the release (C8 of Figure 7-32).
    t = 0;
    do begin @(posedge clk); #1; t++; end while (!rsp_done && t < 20);
    sample_release();
    check(!a_oe && !attr_oe, "given up: the address group released at the edge (specification 38)");
    check(bb_hi_first && bb_oe_first, "given up: BB driven negated for the first half clock");
    check(!bb_oe_second, "given up: BB released in the second half (specification 39)");
    @(negedge clk);
    check(!mi_n_o, "MI asserted once the core gives the bus up (UM 7.9.1)");
    check(!bb_oe && !tip_oe && !a_oe && !d_oe, "idle: nothing driven");

    // --- 5. a retry with BG negated: relinquish, and retry when granted -----
    u_slave.set_region(2, 32'h0000_3000, 32'hFFFF_FF00, 1, 0, 0, -1, 1);
    u_slave.poke_long(32'h3000, 32'h7E7E_7E7E);
    bg_n = 1'b0;
    nd = n_done; base = n_rsp; starts = u_slave.n_starts;
    push(32'h3000, 0, L);
    // Take BG away before the retry is signalled.
    @(negedge clk); while (ts_w) @(negedge clk);
    bg_n = 1'b1;
    repeat (6) @(negedge clk);
    check(!a_oe && !bb_oe && u_slave.n_starts - starts == 1,
          "retry with BG negated: the bus is given up (UM 7.6.2, Figure 7-31)");
    check(!br_n_o, "... and BR asserted for the retry");
    bg_n = 1'b0;
    run_queue();
    check(u_slave.n_starts - starts == 2 && n_rsp == base + 1 && r_data[base] == 32'h7E7E_7E7E,
          "... run again once the bus is granted, and answered once");

    // --- 6. a locked sequence: LOCK throughout, LOCKE on the last write -----
    seen_lock_gap = 0; seen_locke_read = 0; seen_locke_write = 0;
    lock_seq = 1'b1;
    push(32'h1010, 0, L, '0, 2'b00, 3'b101, 1, 0);
    push(32'h1010, 1, L, {96'h0, 32'h8000_0001}, 2'b00, 3'b101, 1, 1);
    fork begin
      repeat (8) begin
        @(posedge clk); #1;
        if (attr_oe && lock_n_o && !ts_n_o) seen_lock_gap = 1;
        if (!ts_n_o && rw_o && !locke_n_o) seen_locke_read = 1;
        if (!ts_n_o && !rw_o && !locke_n_o) seen_locke_write = 1;
      end
    end join
    run_queue();
    lock_seq = 1'b0;
    repeat (2) @(negedge clk);
    check(!seen_lock_gap, "LOCK asserted for every transfer of the locked sequence");
    check(!seen_locke_read && seen_locke_write, "LOCKE on the last write only (UM 7.4.5)");
    check(lock_n_o && locke_n_o, "LOCK and LOCKE negated after the sequence");
    check(u_slave.peek_long(32'h1010) == 32'h8000_0001, "the locked write landed");

    // --- 7. RSTI in the middle of a transfer (UM 7.10) ------------------------
    u_slave.set_region(3, 32'h0000_4000, 32'hFFFF_FF00, 6, 0, 0, -1, 0);
    nd = n_done;
    push(32'h4000, 0, L);
    @(negedge clk); while (ts_w) @(negedge clk);
    @(negedge clk);
    crst = 1'b1;
    @(negedge clk);
    check(!a_oe && !attr_oe && !d_oe && !mi_n_o && br_n_o,
          "internal reset: the bus released, MI asserted, BR negated");
    @(negedge clk);
    check(!bb_oe && !tip_oe, "internal reset: BB and TIP released");
    // The transfer the reset cut short is not reported.
    check(n_done == nd, "a transfer cut by reset is not reported");
    // The queue's head was taken; start the queue again past it.
    crst = 1'b0;
    repeat (10) @(negedge clk);
    check(n_done == nd, "... nor run again");
    q_tail = q_head;
    repeat (2) @(negedge clk);

    finish("bus_arb_tb");
  end

  initial begin #2000000; $display("FAIL: bus_arb_tb timed out"); $finish; end

endmodule
