// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- the caches on the bus: sim/programs/m9_cache.S on the core, its
// phases (begun by writes to MARK) watched transfer by transfer and checked
// against UM 4 and 7.4:
//
//   1  a loop run from the instruction cache makes almost no fetches (only
//      the lines after it): its own lines were filled before the phase
//   2  CPUSHL and CPUSHP of the instruction cache invalidate the line and the
//      page (UM 4.2), so changed code runs: D7 = $123
//   3  with ITT0 cache-inhibited (CM 11), every long-word fetch has CIOUT
//      (UM 5.3.9), and a fill is never a line read
//   4  a line answered with TCI is not cached (UM 4.6.1): three calls to it,
//      three line reads of it
//
// What the caches hold is not compared with an oracle here: core_cosim_tb
// runs programs with them on (m9_icache) against UAE040.

`timescale 1ns / 1ps

module core_cache_tb;

`include "rd68041_core_harness.svh"

  localparam logic [31:0] MARK = 32'h0000_FF00;

  string       image;
  int unsigned nfail;
  int          phase;
  bit          done;
  // Per phase: fetch transfers, line fetches, long fetches without CIOUT,
  // line reads of $3000.
  int unsigned n_fetch [0:7];
  int unsigned n_line  [0:7];
  int unsigned n_nocio [0:7];
  int unsigned n_cio   [0:7];
  int unsigned n_tci   [0:7];

  task automatic check(input string what, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
      $display("  FAIL: %s is %0h, expected %0h", what, got, exp);
      nfail++;
    end
  endtask

  // Every transfer as it starts; the MARK writes move the phase on.
  always @(posedge clk) begin
    if (!ts_w && !done) begin
      if (tt_o == 2'b00 && (tm_o == 3'd6 || tm_o == 3'd2)) begin
        n_fetch[phase]++;
        if (siz_o == 2'b11) n_line[phase]++;
        else if (ciout_n_o) n_nocio[phase]++;
        else n_cio[phase]++;
        if (siz_o == 2'b11 && a_o[31:4] == 28'h0000_300) n_tci[phase]++;
      end
    end
  end
  always @(negedge clk) begin
    if (rst_n && !done) begin
      logic [31:0] m;
      m = u_mem.peek_long(MARK);
      if (int'(m) != phase && m < 8) phase = int'(m);
    end
  end

  // The end: the illegal instruction exception on the program's ILLEGAL.
  always @(posedge clk) begin
    logic [31:0] hw, pc;
    pc = dut.u_core.w_u.pc;
    hw = u_mem.peek_long({pc[31:2], 2'b00});
    if (!done && dut.u_core.x_flush && dut.u_core.w_u.xvec == 8'd4 &&
        (pc[1] ? hw[15:0] : hw[31:16]) == 16'h4AFC) begin
      done = 1;
      #1 finish_up();
    end
    if (!done && dut.u_core.halted) begin
      done = 1;
      $display("  FAIL: halted at %h", dut.u_core.w_u.pc);
      $display("FAIL: core_cache_tb");
      $finish;
    end
  end

  task automatic finish_up();
    if (n_fetch[1] > 4) begin
      $display("  FAIL: (1) the cached loop made %0d fetches (%0d lines)", n_fetch[1], n_line[1]);
      nfail++;
    end
    check("(2) the changed code, as CPUSHL and CPUSHP let it run (D7)", reg_of(7), 32'h123);
    check("(3) long-word fetches without CIOUT while cache-inhibited", n_nocio[3], 0);
    if (n_cio[3] < 4) begin
      $display("  FAIL: (3) only %0d cache-inhibited fetches", n_cio[3]);
      nfail++;
    end
    check("(4) line reads of the TCI line, one a call", n_tci[4], 3);
    check("(4) the routine's result (D6)", reg_of(6), 9);
    if (nfail == 0)
      $display("PASS: core_cache_tb: a cached loop in %0d fetches, CPUSH, CIOUT, TCI", n_fetch[1]);
    else
      $display("FAIL: core_cache_tb: %0d checks failed", nfail);
    $finish;
  endtask

  initial begin
    if (!$value$plusargs("image=%s", image)) image = "build/programs/m9_cache.hex";
    nfail = 0; done = 0; phase = 0;
    for (int i = 0; i < 8; i++) begin
      n_fetch[i] = 0; n_line[i] = 0; n_nocio[i] = 0; n_cio[i] = 0; n_tci[i] = 0;
    end
    boot(image);
    // $3000-$300F: lines answered with TCI.
    u_mem.set_region(1, 32'h0000_3000, 32'hFFFF_FFF0, 0, 0, 1, -1, 0);
  end

  initial begin
    #5000000;
    if (!done) begin
      $display("  FAIL: timed out in phase %0d", phase);
      $display("FAIL: core_cache_tb");
      $finish;
    end
  end

endmodule
