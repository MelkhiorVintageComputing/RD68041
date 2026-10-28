// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- sim/programs/m14_fetch_ext.S on the core: an instruction whose
// operation word is on a resident page and whose extension words are on one
// that is not. Its fetch faults with the instruction only partly in the queue,
// and fetching stops at the fault (xstop): the access fault must be taken
// then (UM 8.4.6, FA $17000, then $19000 with the instruction cache on),
// not waited on for words that will never come.

`timescale 1ns / 1ps

module core_fetchext_tb;

`include "rd68041_core_harness.svh"

  localparam logic [31:0] OUT  = 32'h0000_FD00;
  localparam logic [31:0] DONE = 32'h0000_FDFC;

  string       image;
  int unsigned nfail;
  bit          done;

  task automatic check(input string what, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
      $display("  FAIL: %s is %h, expected %h", what, got, exp);
      nfail++;
    end
  endtask

  task automatic finish_up();
    check("the access faults taken", u_mem.peek_long(OUT), 32'd2);
    check("the first fault's FA", u_mem.peek_long(OUT + 32'h20), 32'h0001_7000);
    check("the second fault's FA", u_mem.peek_long(OUT + 32'h24), 32'h0001_9000);
    check("the store, caches off", u_mem.peek_long(OUT + 32'h30), 32'h2A2A_2A2A);
    check("the store, instruction cache on", u_mem.peek_long(OUT + 32'h34), 32'h2A2A_2A2A);
    check("the code's result (D5)", u_mem.peek_long(OUT + 32'h04), 32'h0000_0004);
    check("no stray exception", u_mem.peek_long(OUT + 32'h08), 32'h0);
    if (nfail == 0) $display("PASS: core_fetchext_tb: the fault taken with the instruction part-fetched");
    else            $display("FAIL: core_fetchext_tb: %0d checks failed", nfail);
    $finish;
  endtask

  always @(posedge clk) begin
    if (!done && rst_n && (u_mem.peek_long(DONE) == 32'hC0DE_0000 || dut.u_core.halted ||
                           u_mem.peek_long(OUT) >= 3)) begin
      done = 1;
      repeat (8) @(posedge clk);
      finish_up();
    end
  end

  initial begin
    if (!$value$plusargs("image=%s", image)) image = "build/programs/m14_fetch_ext.hex";
    nfail = 0; done = 0;
    boot(image);
  end

  initial begin
    #5000000;
    if (!done) begin
      $display("  FAIL: timed out, decode at %h, %0d faults", dut.u_core.q_pc, u_mem.peek_long(OUT));
      $display("FAIL: core_fetchext_tb");
      $finish;
    end
  end

endmodule
