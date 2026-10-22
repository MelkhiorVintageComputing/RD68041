// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- bus transfers that end normally: UM 7.2-7.4.
//
// Byte, word and long-word reads and writes on every lane (Table 7-1), with
// and without wait states; back-to-back transfers with TIP held (UM 7.4.1);
// line bursts read and written in A3-A2 order (UM 7.4.2, 7.4.4); the same
// lines burst-inhibited by TBI, finished as three long-word transfers; TCI on
// a line. Each is timed in clocks against the manual's figures.

`timescale 1ns/1ps

module bus_xfer_tb;

`include "rd68041_bus_harness.svh"

  localparam logic [1:0] B = 2'b01, W = 2'b10, L = 2'b00, LN = 2'b11;

  int base;
  logic [31:0] exp;

  // The bytes of long word `a` as the slave holds them.
  function automatic logic [31:0] mem_l(input logic [31:0] a);
    mem_l = u_slave.peek_long(a);
  endfunction

  // Watching the pins for one transfer: how many TS the slave saw, with what.
  int ts_seen;
  always @(posedge clk) if (!ts_w && !crst) ts_seen = ts_seen + 1;

  initial begin
    ts_seen = 0;
    for (int i = 0; i < 1024; i++) u_slave.poke_long(32'h1000 + 4*i, 32'h1000_0000 + 32'h0101_0101 * i);
    u_slave.set_region(0, 32'h0000_0000, 32'hFFFF_0000, 0, 0, 0, -1, 0);
    reset_all();

    // --- 1. a long-word read, no wait: C1 and C2 (UM 7.4.1, Figure 7-9) -----
    base = n_rsp;
    push(32'h1010, 0, L);
    run_queue();
    check(n_rsp == base + 1 && r_data[base] == mem_l(32'h1010),
          $sformatf("long read data %h", r_data[base]));
    check(clocks_of(0) == 2, $sformatf("long read takes 2 clocks, took %0d", clocks_of(0)));

    // --- 2. bytes and words on their lanes (Table 7-1) -----------------------
    for (int off = 0; off < 4; off++) begin
      int i;
      i = q_tail;
      base = n_rsp;
      push(32'h1020 + off, 0, B);
      run_queue();
      exp = mem_l(32'h1020);
      check(r_data[base][31 - 8*off -: 8] == exp[31 - 8*off -: 8],
            $sformatf("byte read at offset %0d on its lane: %h", off, r_data[base]));
      check(u_slave.last_siz == B && u_slave.last_a == 32'h1020 + off,
            "byte read: SIZ and A1-A0 on the pins");
    end
    for (int off = 0; off < 4; off += 2) begin
      base = n_rsp;
      push(32'h1030 + off, 0, W);
      run_queue();
      exp = mem_l(32'h1030);
      check(r_data[base][31 - 8*off -: 16] == exp[31 - 8*off -: 16],
            $sformatf("word read at offset %0d on its lanes: %h", off, r_data[base]));
    end

    // --- 3. writes: only the lanes Table 7-1 selects are written --------------
    u_slave.poke_long(32'h2000, 32'h1122_3344);
    push(32'h2001, 1, B, {96'h0, 32'hAA_BB_CC_DD});      // byte at offset 1: D23-D16
    push(32'h2002, 1, W, {96'h0, 32'h5566_7788});        // word at offset 2: D15-D0
    push(32'h2004, 1, L, {96'h0, 32'hCAFE_F00D});
    run_queue();
    check(mem_l(32'h2000) == 32'h11BB_7788, $sformatf("byte and word writes: %h", mem_l(32'h2000)));
    check(mem_l(32'h2004) == 32'hCAFE_F00D, "long write");
    check(u_slave.last_rw == 1'b0, "R/W low for a write");

    // --- 4. wait states: one more clock each (UM 7.4.1, CW) -------------------
    u_slave.set_region(1, 32'h0000_3000, 32'hFFFF_F000, 3, 0, 0, -1, 0);
    u_slave.poke_long(32'h3000, 32'hDEAD_BEEF);
    begin
      int i; i = q_tail; base = n_rsp;
      push(32'h3000, 0, L);
      run_queue();
      check(r_data[base] == 32'hDEAD_BEEF, "read with waits: data");
      check(clocks_of(i) == 5, $sformatf("three wait states: 5 clocks, took %0d", clocks_of(i)));
    end

    // --- 5. back to back: TS again on the clock after TA, TIP held -----------
    begin
      int i; bit tip_gap;
      i = q_tail; tip_gap = 0;
      push(32'h1100, 0, L);
      push(32'h1104, 0, L);
      push(32'h1108, 1, L, {96'h0, 32'h0BAD_CAFE});
      fork
        begin
          @(posedge clk); @(posedge clk);      // into the first transfer
          repeat (5) begin @(posedge clk); if (tip_w) tip_gap = 1; end
        end
      join_none
      run_queue();
      check(done_edge[i] - acc_edge[i] == 2 && done_edge[i+1] - acc_edge[i] == 4 &&
            done_edge[i+2] - acc_edge[i] == 6,
            $sformatf("three transfers back to back in six clocks: %0d %0d %0d",
                      done_edge[i] - acc_edge[i], done_edge[i+1] - acc_edge[i],
                      done_edge[i+2] - acc_edge[i]));
      check(!tip_gap, "TIP stays asserted between back-to-back transfers");
      check(mem_l(32'h1108) == 32'h0BAD_CAFE, "back-to-back write landed");
    end

    // --- 6. a line read burst from $..08: A3-A2 = 10, 11, 00, 01 (UM 7.4.2) ---
    begin
      int i, ts0; i = q_tail; base = n_rsp; ts0 = ts_seen;
      push(32'h1208, 0, LN);
      run_queue();
      check(n_rsp == base + 4, $sformatf("line read: 4 long words, got %0d", n_rsp - base));
      for (int k = 0; k < 4; k++) begin
        check(r_lw[base+k] == 2'(2 + k), $sformatf("line read beat %0d is A3-A2 %0d", k, r_lw[base+k]));
        check(r_data[base+k] == mem_l(32'h1200 + 4*((2 + k) % 4)),
              $sformatf("line read beat %0d data %h", k, r_data[base+k]));
      end
      check(clocks_of(i) == 5, $sformatf("line burst: 5 clocks, took %0d", clocks_of(i)));
      check(ts_seen - ts0 == 1, "line burst: one TS");
      check(u_slave.last_siz == LN, "line burst: SIZ = line");
    end

    // --- 7. a line write burst ----------------------------------------------
    begin
      int i; i = q_tail;
      push(32'h2014, 1, LN, {32'h4444_4444, 32'h3333_3333, 32'h2222_2222, 32'h1111_1111});
      run_queue();
      // From A3-A2 = 01: beats go to $..14, $..18, $..1C, $..10.
      check(mem_l(32'h2014) == 32'h1111_1111 && mem_l(32'h2018) == 32'h2222_2222 &&
            mem_l(32'h201C) == 32'h3333_3333 && mem_l(32'h2010) == 32'h4444_4444,
            "line write: each long word at its A3-A2");
      check(clocks_of(i) == 5, $sformatf("line write burst: 5 clocks, took %0d", clocks_of(i)));
    end

    // --- 8. burst-inhibited: TBI with the first TA, three long words after ---
    u_slave.set_region(2, 32'h0000_4000, 32'hFFFF_F000, 0, 1, 0, -1, 0);
    for (int k = 0; k < 4; k++) u_slave.poke_long(32'h4000 + 4*k, 32'hB000_0000 + k);
    begin
      int i, ts0; i = q_tail; base = n_rsp; ts0 = ts_seen;
      push(32'h400E, 0, LN);                       // A3-A2 = 11, A1-A0 = 10
      run_queue();
      check(n_rsp == base + 4, "burst-inhibited line read: 4 long words");
      for (int k = 0; k < 4; k++)
        check(r_data[base+k] == 32'hB000_0000 + ((3 + k) % 4) && r_lw[base+k] == 2'(3 + k),
              $sformatf("burst-inhibited beat %0d: lw %0d data %h", k, r_lw[base+k], r_data[base+k]));
      check(clocks_of(i) == 8, $sformatf("burst-inhibited line read: 8 clocks (UM 7.4.2), took %0d", clocks_of(i)));
      check(ts_seen - ts0 == 4, $sformatf("burst-inhibited line: four TS, saw %0d", ts_seen - ts0));
      // UM 7.2: "A1 and A0 for each of the four accesses ... are copied from the
      // lowest two bits of the access address".
      check(u_slave.last_a == 32'h400A && u_slave.last_siz == L,
            $sformatf("last of the three long words: A = %h, SIZ = long", u_slave.last_a));
    end
    begin
      int i; i = q_tail;
      push(32'h4020, 1, LN, {32'hD4, 32'hD3, 32'hD2, 32'hD1});
      run_queue();
      check(mem_l(32'h4020) == 32'hD1 && mem_l(32'h4024) == 32'hD2 &&
            mem_l(32'h4028) == 32'hD3 && mem_l(32'h402C) == 32'hD4,
            "burst-inhibited line write: each long word at its address");
      check(clocks_of(i) == 8, $sformatf("burst-inhibited line write: 8 clocks, took %0d", clocks_of(i)));
    end

    // --- 9. TCI with a line's first TA is reported (UM 7.4.2) -----------------
    u_slave.set_region(3, 32'h0000_5000, 32'hFFFF_F000, 1, 0, 1, -1, 0);
    begin
      base = n_rsp;
      push(32'h5000, 0, LN);
      run_queue();
      check(r_tci[base+3] == 1'b1, "TCI on a line is reported");
      base = n_rsp;
      push(32'h1000, 0, LN);
      run_queue();
      check(r_tci[base+3] == 1'b0, "no TCI, none reported");
    end

    // --- 10. attributes reach the pins as requested ---------------------------
    push(32'h1300, 0, L, '0, 2'b10, 3'b011);
    run_queue();
    check(u_slave.last_tt == 2'b10 && u_slave.last_tm == 3'b011, "TT and TM on the pins");

    check(n_err == 0, "no transfer reported an error");
    finish("bus_xfer_tb");
  end

  initial begin #2000000; $display("FAIL: bus_xfer_tb timed out"); $finish; end

endmodule
