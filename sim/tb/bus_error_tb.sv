// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- bus transfers that do not end normally, and the acknowledge
// cycles: UM 7.5, 7.6.
//
// Table 7-5: TEA alone is a bus error, reported with the long word it ended
// on; TA with TEA is a retry, run again with the same access information and
// never reported -- except on a line's second, third or fourth long word, or
// on any of a burst-inhibited line's three long-word transfers, where it is a
// bus error (UM 7.6.2). Table 7-4: an interrupt acknowledge ends with a
// vector, an autovector, TEA (spurious) or a retry; a breakpoint acknowledge
// with TA or TEA (UM 7.5.2).

`timescale 1ns/1ps

module bus_error_tb;

`include "rd68041_bus_harness.svh"

  localparam logic [1:0] B = 2'b01, W = 2'b10, L = 2'b00, LN = 2'b11;

  int base, nd, starts;

  initial begin
    for (int i = 0; i < 256; i++) u_slave.poke_long(32'h1000 + 4*i, 32'hC000_0000 + i);
    u_slave.set_region(0, 32'h0000_0000, 32'hFFFF_0000, 0, 0, 0, -1, 0);
    reset_all();

    // --- 1. TEA on a long-word read: reported, on long word 0 ----------------
    u_slave.set_region(1, 32'h0000_2000, 32'hFFFF_FF00, 0, 0, 0, 0, 0);
    nd = n_done; base = n_rsp;
    push(32'h2000, 0, L);
    run_queue();
    check(err_beat[nd] == 0 && n_rsp == base, "TEA on a read: error, no data");

    // --- 2. TEA on a write --------------------------------------------------
    nd = n_done;
    push(32'h2004, 1, L, {96'h0, 32'h1234_5678});
    run_queue();
    check(err_beat[nd] == 0, "TEA on a write: error");

    // --- 3. TEA on a line burst's third long word: the line stops there ----
    u_slave.set_region(2, 32'h0000_3000, 32'hFFFF_FF00, 0, 0, 0, 2, 0);
    nd = n_done; base = n_rsp;
    push(32'h3000, 0, LN);
    run_queue();
    check(n_rsp == base + 2 && err_beat[nd] == 2,
          $sformatf("TEA on a line's third long word: two moved, error on 2 (%0d, %0d)",
                    n_rsp - base, err_beat[nd]));

    // --- 4. a retry on a long-word read: run again, not reported ------------
    u_slave.set_region(3, 32'h0000_4000, 32'hFFFF_FF00, 0, 0, 0, -1, 2);
    u_slave.poke_long(32'h4000, 32'h5EED_0001);
    nd = n_done; base = n_rsp; starts = u_slave.n_starts;
    push(32'h4000, 0, L);
    run_queue();
    check(err_beat[nd] == -1 && n_rsp == base + 1 && r_data[base] == 32'h5EED_0001,
          "two retries, then the data");
    check(u_slave.n_starts - starts == 3, $sformatf("a retried read is run three times: %0d",
          u_slave.n_starts - starts));
    check(u_slave.last_a == 32'h4000 && u_slave.last_siz == L, "the retry has the same access information");

    // --- 5. a retry on a line's first transfer: the line is run again -------
    u_slave.set_region(3, 32'h0000_4000, 32'hFFFF_FF00, 0, 0, 0, -1, 1);
    nd = n_done; base = n_rsp; starts = u_slave.n_starts;
    push(32'h4010, 0, LN);
    run_queue();
    check(err_beat[nd] == -1 && n_rsp == base + 4, "retry on a line's first transfer: the line, again");
    check(u_slave.n_starts - starts == 2, "... from its TS");

    // --- 6. a retry on a later long word of a line is a bus error -----------
    // The slave retries beat 0 only; force one on beat 1 by hand.
    u_slave.set_region(4, 32'h0000_5000, 32'hFFFF_FF00, 0, 0, 0, -1, 0);
    nd = n_done; base = n_rsp;
    push(32'h5000, 0, LN);
    // TS at the first rising edge, beat 0's TA at the third: force TEA with
    // beat 1's TA.
    fork begin
      @(negedge clk); while (ts_w) @(negedge clk);   // the clock TS is asserted in
      @(negedge clk);                                 // C2
      @(negedge clk);                                 // C3: beat 1 is answered here
      force tea_n = 1'b0;
      @(negedge clk);
      release tea_n;
    end join
    run_queue();
    check(err_beat[nd] == 1 && n_rsp == base + 1,
          $sformatf("retry on a line's second long word is a bus error (%0d, %0d)",
                    err_beat[nd], n_rsp - base));

    // --- 7. ... and so on any of a burst-inhibited line's long words --------
    u_slave.set_region(5, 32'h0000_6000, 32'hFFFF_FF00, 0, 1, 0, -1, 0);
    nd = n_done; base = n_rsp;
    push(32'h6000, 0, LN);
    fork begin
      @(negedge clk); while (ts_w) @(negedge clk);   // C1 of the line
      @(negedge clk); @(negedge clk);                 // C1 of the first long word
      while (ts_w) @(negedge clk);
      @(negedge clk);                                 // its C2
      force tea_n = 1'b0;
      @(negedge clk);
      release tea_n;
    end join
    run_queue();
    check(err_beat[nd] == 1 && n_rsp == base + 1,
          $sformatf("retry on a burst-inhibited line's long word is a bus error (%0d, %0d)",
                    err_beat[nd], n_rsp - base));

    // --- 8. interrupt acknowledge: vector, autovector, spurious, retry ------
    u_slave.iack_kind[3] = 0; u_slave.iack_vec[3] = 8'h77;
    u_slave.iack_kind[5] = 1;
    u_slave.iack_kind[6] = 2;
    nd = n_done; base = n_rsp;
    push(32'hFFFF_FFFF, 0, B, '0, 2'b11, 3'd3);
    push(32'hFFFF_FFFF, 0, B, '0, 2'b11, 3'd5);
    push(32'hFFFF_FFFF, 0, B, '0, 2'b11, 3'd6);
    run_queue();
    check(err_beat[nd] == -1 && r_data[base][7:0] == 8'h77 && !r_avec[base],
          $sformatf("IACK level 3: vector %h on D7-D0", r_data[base][7:0]));
    check(err_beat[nd+1] == -1 && r_avec[base+1], "IACK level 5: AVEC with TA");
    check(err_beat[nd+2] == 0, "IACK level 6: TEA, spurious");
    check(u_slave.last_tt == 2'b11 && u_slave.last_a == 32'hFFFF_FFFF && u_slave.last_tm == 3'd6,
          "IACK: TT = 3, A = $FFFFFFFF, TM = the level (UM 7.5.1.1)");
    u_slave.iack_retry = 1;
    nd = n_done; base = n_rsp; starts = u_slave.n_starts;
    push(32'hFFFF_FFFF, 0, B, '0, 2'b11, 3'd5);
    run_queue();
    check(err_beat[nd] == -1 && r_avec[base] && u_slave.n_starts - starts == 2,
          "IACK retried, then answered");

    // --- 9. breakpoint acknowledge: TA or TEA (UM 7.5.2) ---------------------
    nd = n_done;
    u_slave.bkpt_kind = 1;
    push(32'h0000_0000, 0, B, '0, 2'b11, 3'd0);
    run_queue();
    u_slave.bkpt_kind = 0;
    check(err_beat[nd] == 0, "breakpoint acknowledge with TEA: reported as TEA");

    // --- 10. a good transfer after all that ---------------------------------
    base = n_rsp;
    push(32'h1004, 0, L);
    run_queue();
    check(r_data[base] == 32'hC000_0001, "a normal read after the errors");

    finish("bus_error_tb");
  end

  initial begin #2000000; $display("FAIL: bus_error_tb timed out"); $finish; end

endmodule
