// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- sim/programs/m14_fetch_next.S on the core: an instruction fetch's
// ATC fault on a page, then code that runs into the next page, which the
// fault's handler made resident too. One fault, on the first page (UM 8.4.6,
// FA $16FF8), not a second on the next: the fetch must not have searched the
// tables for the next page, and left an entry not resident for it in the
// ATC, before the handler made it resident.

`timescale 1ns / 1ps

module core_fetchnext_tb;

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
    check("the access faults taken", u_mem.peek_long(OUT), 32'd1);
    check("the first fault's FA", u_mem.peek_long(OUT + 32'h20), 32'h0001_6FF8);
    if (u_mem.peek_long(OUT) > 1)
      $display("  (the second fault's FA: %h)", u_mem.peek_long(OUT + 32'h24));
    check("the code's result (D5)", u_mem.peek_long(OUT + 32'h04), 32'h2A2A_2A2B);
    check("no stray exception", u_mem.peek_long(OUT + 32'h08), 32'h0);
    if (nfail == 0) $display("PASS: core_fetchnext_tb: one ATC fault, none on the next page");
    else            $display("FAIL: core_fetchnext_tb: %0d checks failed", nfail);
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
    if (!$value$plusargs("image=%s", image)) image = "build/programs/m14_fetch_next.hex";
    nfail = 0; done = 0;
    boot(image);
  end

  initial begin
    #5000000;
    if (!done) begin
      $display("  FAIL: timed out at PC %h", dut.u_core.w_u.pc);
      $display("FAIL: core_fetchnext_tb");
      $finish;
    end
  end

endmodule
