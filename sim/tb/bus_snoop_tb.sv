// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- snooping an alternate master's transfers: UM 7.9, UM 4.4, Tables
// 4-1, 4-3 and 4-4, against a stand-in for the caches.
//
// Every row of Table 4-1 against a line that misses, a clean line and a dirty
// one: memory answers unless the core intervenes, and it intervenes only to
// source a dirty line to a snooped read or to sink a snooped non-line write
// into one (UM 7.9.3, 7.9.4); a write that hits invalidates the line, as does
// a read with SC = 10, and both invalidate an instruction-cache line. MI is
// negated at once for a transfer that cannot be snooped, after the lookup for
// one that is, and asserted between transfers. The core's TA is released half
// a clock after its last assertion (specification 39).

`timescale 1ns/1ps

module bus_snoop_tb;

`include "rd68041_bus_harness.svh"

  localparam logic [1:0] B = 2'b01, W = 2'b10, L = 2'b00, LN = 2'b11;
  localparam logic [1:0] SC_NONE = 2'b00, SC_LEAVE = 2'b01, SC_INV = 2'b10;

  int nw, ndi, nii, mem_answers;
  bit mi_seen_negated, core_ta_seen, mi_low_between;

  // How often the slave (memory) asserted TA, and whether the core did.
  always @(posedge clk) begin
    if (!s_ta_n) mem_answers = mem_answers + 1;
    if (ta_oe && !ta_n_o) core_ta_seen = 1;
    if (am_own && mi_n_o) mi_seen_negated = 1;
  end

  task automatic watch_reset();
    mem_answers = 0; core_ta_seen = 0; mi_seen_negated = 0;
    nw = u_cache.n_wr; ndi = u_cache.n_dinv; nii = u_cache.n_iinv;
  endtask

  initial begin
    mem_answers = 0;
    for (int i = 0; i < 64; i++) u_slave.poke_long(32'h8000 + 4*i, 32'h3E3E_0000 + i);
    u_slave.set_region(0, 32'h0000_0000, 32'hFFFF_0000, 0, 0, 0, -1, 0);
    u_slave.set_region(1, 32'h0000_9000, 32'hFFFF_F000, 0, 1, 0, -1, 0);   // burst-inhibits
    bg_n = 1'b1;                    // the core is not master
    reset_all();
    repeat (2) @(negedge clk);
    check(!mi_n_o, "MI asserted out of reset, before any transfer");

    // --- 1. snoop inhibited (SC = 00): MI negated at once, memory answers ---
    watch_reset();
    u_am.xfer(32'h8004, 0, L, SC_NONE);
    check(u_am.got[0] == 32'h3E3E_0001 && mem_answers == 1 && !core_ta_seen,
          "SC = 00: memory answers the read");
    check(mi_seen_negated, "SC = 00: MI negated during the transfer");
    @(negedge clk);
    check(!mi_n_o, "MI asserted again between transfers (UM 7.9.1)");

    // --- 2. SC = 01 read, no line: memory answers ----------------------------
    watch_reset();
    u_am.xfer(32'h8008, 0, L, SC_LEAVE);
    check(u_am.got[0] == 32'h3E3E_0002 && mem_answers == 1 && !core_ta_seen,
          "snooped read, miss: memory answers");

    // --- 3. SC = 01 read, clean line: memory answers, line kept (V9) --------
    u_cache.set_dline(0, 32'h8010, 4'b0000, 32'hC0, 32'hC1, 32'hC2, 32'hC3);
    watch_reset();
    u_am.xfer(32'h8014, 0, L, SC_LEAVE);
    check(u_am.got[0] == 32'h3E3E_0005 && mem_answers == 1 && !core_ta_seen,
          "snooped read, clean hit, SC = 01: memory answers (V9)");
    check(u_cache.n_dinv == ndi && u_cache.d_v[0], "... and the line stays valid");

    // --- 4. SC = 01 read, dirty line: the core sources it, memory inhibited (D9)
    u_cache.set_dline(0, 32'h8020, 4'b0100, 32'hD0, 32'hD1, 32'hD2, 32'hD3);
    watch_reset();
    u_am.xfer(32'h8028, 0, L, SC_LEAVE);
    check(u_am.got[0] == 32'hD2 && mem_answers == 0 && core_ta_seen,
          $sformatf("snooped read, dirty hit: the core supplies the data (%h), memory silent", u_am.got[0]));
    check(u_cache.d_v[0] && u_cache.n_dinv == ndi, "SC = 01: the dirty line stays (D9)");
    // Specification 39: TA released half a clock after its last assertion.
    check(!ta_oe, "the core's TA released after the transfer");

    // --- 5. SC = 10 line read of a dirty line: four long words, then invalid (D10)
    u_cache.set_dline(0, 32'h8030, 4'b0001, 32'hE0, 32'hE1, 32'hE2, 32'hE3);
    watch_reset();
    u_am.xfer(32'h8034, 0, LN, SC_INV);
    check(u_am.n_got == 4 && u_am.got[0] == 32'hE1 && u_am.got[1] == 32'hE2 &&
          u_am.got[2] == 32'hE3 && u_am.got[3] == 32'hE0 && mem_answers == 0,
          $sformatf("snooped line read, dirty: the core bursts the line in A3-A2 order (%h %h %h %h)",
                    u_am.got[0], u_am.got[1], u_am.got[2], u_am.got[3]));
    @(negedge clk);
    check(!u_cache.d_v[0] && u_cache.n_dinv == ndi + 1, "SC = 10: the line invalidated after (D10)");

    // --- 6. SC = 10 read, clean line: memory answers, line invalidated (V10)
    u_cache.set_dline(1, 32'h8040, 4'b0000, 32'h0, 32'h0, 32'h0, 32'h0);
    watch_reset();
    u_am.xfer(32'h8040, 0, L, SC_INV);
    @(negedge clk);
    check(u_am.got[0] == 32'h3E3E_0010 && mem_answers == 1 && !u_cache.d_v[1],
          "SC = 10 read, clean hit: memory answers, line invalidated (V10)");

    // --- 7. SC = 01 long-word write to a dirty line: sunk, D bit set (D12) --
    u_cache.set_dline(2, 32'h8050, 4'b0001, 32'hF0, 32'hF1, 32'hF2, 32'hF3);
    watch_reset();
    u_am.xfer(32'h8058, 1, L, SC_LEAVE, {96'h0, 32'h5151_5151});
    @(negedge clk);
    check(mem_answers == 0 && core_ta_seen && u_cache.d_data[2][2] == 32'h5151_5151,
          $sformatf("snooped write, dirty hit: sunk into the cache (%h)", u_cache.d_data[2][2]));
    check(u_cache.d_dirty[2] == 4'b0101 && u_cache.d_v[2], "... its D bit set, the line kept (D12)");
    check(u_slave.peek_long(32'h8058) == 32'h3E3E_0016, "... and memory not written");

    // --- 8. SC = 01 byte write to a dirty line: only that byte -------------
    watch_reset();
    u_am.xfer(32'h8051, 1, B, SC_LEAVE, {96'h0, 32'h00AB_0000});
    @(negedge clk);
    check(u_cache.d_data[2][0] == 32'h00AB_00F0 && mem_answers == 0,
          $sformatf("snooped byte write sunk on its lane: %h", u_cache.d_data[2][0]));

    // --- 9. SC = 01 line write to a dirty line: memory, line invalid (D13) --
    watch_reset();
    u_am.xfer(32'h8050, 1, LN, SC_LEAVE, {32'h4, 32'h3, 32'h2, 32'h1});
    @(negedge clk);
    check(mem_answers == 4 && !core_ta_seen && !u_cache.d_v[2] &&
          u_slave.peek_long(32'h8050) == 32'h1,
          "snooped line write, dirty hit: memory takes it, the line invalidated (D13)");

    // --- 10. SC = 10 write to a dirty line: memory, invalid, dirty data lost (D11)
    u_cache.set_dline(3, 32'h8060, 4'b1111, 32'h0, 32'h0, 32'h0, 32'h0);
    watch_reset();
    u_am.xfer(32'h8060, 1, L, SC_INV, {96'h0, 32'h6060_6060});
    @(negedge clk);
    check(mem_answers == 1 && !u_cache.d_v[3] && u_slave.peek_long(32'h8060) == 32'h6060_6060,
          "SC = 10 write, dirty hit: memory, line invalidated (D11)");

    // --- 11. SC = 01 write to a clean line: memory, invalidated (V12) -------
    u_cache.set_dline(0, 32'h8070, 4'b0000, 32'h0, 32'h0, 32'h0, 32'h0);
    watch_reset();
    u_am.xfer(32'h8070, 1, W, SC_LEAVE, {96'h0, 32'h7777_0000});
    @(negedge clk);
    check(mem_answers == 1 && !u_cache.d_v[0], "SC = 01 write, clean hit: memory, invalidated (V12)");

    // --- 12. the instruction cache: invalidated by writes and SC = 10 reads
    u_cache.set_iline(0, 32'h8080);
    watch_reset();
    u_am.xfer(32'h8080, 0, L, SC_LEAVE);
    @(negedge clk);
    check(u_cache.i_v[0], "SC = 01 read: the instruction-cache line is not touched (V4)");
    u_am.xfer(32'h8080, 0, L, SC_INV);
    @(negedge clk);
    check(!u_cache.i_v[0], "SC = 10 read: the instruction-cache line invalidated (V5)");
    u_cache.set_iline(0, 32'h8080);
    u_am.xfer(32'h8084, 1, L, SC_LEAVE, {96'h0, 32'h1});
    @(negedge clk);
    check(!u_cache.i_v[0], "a snooped write: the instruction-cache line invalidated (V6)");

    // --- 13. not a normal or MOVE16 access: not snooped (UM 5.3.1) -----------
    u_cache.set_dline(0, 32'h8090, 4'b1111, 32'h0, 32'h0, 32'h0, 32'h0);
    watch_reset();
    u_am.xfer(32'h8090, 0, L, SC_LEAVE, '0, 2'b10);
    @(negedge clk);
    check(mem_answers == 1 && !core_ta_seen && u_cache.d_v[0],
          "an alternate function code access with SC = 01 is not snooped");

    // --- 14. a line memory burst-inhibits: the snooper follows it to its end
    watch_reset();
    u_am.xfer(32'h9000, 0, LN, SC_NONE);
    check(u_am.n_got == 4 && mem_answers == 4, "a burst-inhibited line, snoop inhibited: four long words");
    watch_reset();
    u_am.xfer(32'h8004, 0, L, SC_LEAVE);
    check(u_am.got[0] == 32'h3E3E_0001 && mem_answers == 1, "... and the next transfer is snooped as usual");

    // --- 15. the core takes the bus back afterwards ------------------------
    bg_n = 1'b0;
    push(32'h8000, 0, L);
    run_queue();
    check(n_rsp == 1 && r_data[0] == 32'h3E3E_0000 && mi_n_o, "the core's own read after the snoops");

    finish("bus_snoop_tb");
  end

  initial begin #4000000; $display("FAIL: bus_snoop_tb timed out"); $finish; end

endmodule
