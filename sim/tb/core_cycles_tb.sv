// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- integer instruction timings (make cycles): the program
// tools/cycles/cycles.py generates runs each case's copies three times; on the
// third pass this counts the clocks from the first copy's retirement to the
// last's, and prints them ("CYC <case> <clocks>") for cycles.py's report. The
// program's table, at the address in $1004: the count of cases, then each
// one's first and last copy.

`timescale 1ns / 1ps

module core_cycles_tb;

`include "rd68041_core_harness.svh"

  string       image;
  logic [31:0] tab, f, l;
  int          n, i, pass, t0;
  bit          on;

  task automatic load_case();
    f = u_mem.peek_long(tab + 32'd4 + 32'(8 * i));
    l = u_mem.peek_long(tab + 32'd8 + 32'(8 * i));
  endtask

  // The design's signals are read on the falling edge, settled.
  always @(negedge clk) begin
    if (on && dut.u_core.retire) begin
      if (dut.u_core.retire_pc == f) t0 = cyc;
      if (dut.u_core.retire_pc == l) begin
        pass++;
        if (pass == 3) begin
          $display("CYC %0d %0d", i, cyc - t0);
          pass = 0;
          i++;
          if (i == n) begin
            $display("PASS: core_cycles_tb: %0d cases", n);
            $finish;
          end
          load_case();
        end
      end
    end
    if (dut.u_core.halted) begin
      $display("FAIL: core_cycles_tb: halted in case %0d", i);
      $finish;
    end
  end

  initial begin
    if (!$value$plusargs("image=%s", image)) image = "build/cycles/m15_cycles.hex";
    on = 0; i = 0; pass = 0;
    boot(image);
    tab = u_mem.peek_long(32'h1004);
    n   = int'(u_mem.peek_long(tab));
    load_case();
    on = 1;
  end

  initial begin
    #200000000;
    $display("FAIL: core_cycles_tb: timed out in case %0d", i);
    $finish;
  end

endmodule
