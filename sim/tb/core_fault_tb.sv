// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- access faults and the double bus fault: sim/programs/m8_fault.S
// on the core, every transfer to $8000-$80FF answered with TEA, and what the
// format $7 frames held checked against the manual:
//
//   UM 8.4.6   the frame: format $7, vector 2, the PC of the instruction that
//              faulted (for an instruction fetch, the instruction the fetched
//              words were for), FA the faulted address, no write-back pending
//              (the core lets every write finish before it takes the fault)
//   UM 8.4.6.2 the SSW: RW, SIZE, TT, TM of the faulted access; a locked
//              read-modify-write's read is a write (RW clear, LK set); an
//              instruction fetch's TM is $6 (supervisor program)
//   UM 8.2.1   a bus error while a vector is fetched for an exception: a
//              double bus fault, and the processor halts, the frame already
//              written
//
// No oracle is run here: UAE040's access error frame is M10's business
// (doc/oracles.md).

`timescale 1ns / 1ps

module core_fault_tb;

`include "rd68041_core_harness.svh"

  localparam logic [31:0] RES = 32'h0000_FE00;

  string       image;
  int unsigned nfail;
  bit          done;

  task automatic check(input string what, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
      $display("  FAIL: %s is %h, expected %h", what, got, exp);
      nfail++;
    end
  endtask

  function automatic logic [15:0] rdw(input logic [31:0] a);
    logic [31:0] l;
    l = u_mem.peek_long({a[31:2], 2'b00});
    rdw = a[1] ? l[15:0] : l[31:16];
  endfunction
  function automatic logic [31:0] rdl(input logic [31:0] a);
    rdl = {rdw(a), rdw(a + 2)};
  endfunction

  // Record k: what the handler copied from the k-th frame.
  task automatic record(input int k, input string what, input logic [7:0] sys,
                        input logic [31:0] pc, input logic [15:0] ssw, input logic [31:0] fa);
    logic [31:0] r;
    logic [15:0] srw;
    r = RES + 20 * k;
    srw = rdw(r);
    check({what, ": the stacked SR's system byte"}, {24'h0, srw[15:8]}, {24'h0, sys});
    check({what, ": the stacked PC"}, rdl(r + 2), pc);
    check({what, ": the format and vector word"}, {16'h0, rdw(r + 6)}, 32'h7008);
    check({what, ": the SSW"}, {16'h0, rdw(r + 8)}, {16'h0, ssw});
    check({what, ": FA"}, rdl(r + 10), fa);
    check({what, ": WB3S, WB2S, WB1S"}, {rdw(r + 14), rdw(r + 16)} | {16'h0, rdw(r + 18)}, 32'h0);
  endtask

  task automatic finish_up();
    // SSW (UM 8.4.6.2): CP CU CT CM MA ATC LK RW X SIZE(2) TT(2) TM(3).
    record(0, "(a) a long read, supervisor", 8'h27, rdl(RES + 32'h80), 16'h0105, 32'h0000_8000);
    record(1, "(b) a word read, user",       8'h07, rdl(RES + 32'h84), 16'h0141, 32'h0000_8010);
    record(2, "(c) an instruction fetch",    8'h27, 32'h0000_8040,     16'h0106, 32'h0000_8040);
    record(3, "(d) TAS's locked read",       8'h27, rdl(RES + 32'h88), 16'h0225, 32'h0000_8020);
    check("(d) the bus after the locked fault: D3", reg_of(3), 32'h1234);
    check("(e) halted (a double bus fault)", {31'h0, dut.u_core.halted}, 32'h1);
    check("(e) TRAP #0's frame, written before the vector: its word", {16'h0, rdw(32'hEFFE)},
          32'h0080);
    check("no stray exception (D6)", reg_of(6), 32'h0);
    if (nfail == 0) $display("PASS: core_fault_tb: four access faults and a double bus fault");
    else            $display("FAIL: core_fault_tb: %0d checks failed", nfail);
    $finish;
  endtask

  // The end: the double bus fault halts the processor.
  always @(posedge clk) begin
    if (!done && rst_n && dut.u_core.halted) begin
      done = 1;
      repeat (8) @(posedge clk);
      finish_up();
    end
  end

  initial begin
    if (!$value$plusargs("image=%s", image)) image = "build/programs/m8_fault.hex";
    nfail = 0; done = 0;
    boot(image);
    // Every transfer in $8000-$80FF: TEA on its first long word.
    u_mem.set_region(1, 32'h0000_8000, 32'hFFFF_FF00, 0, 0, 0, 0, 0);
  end

  initial begin
    #5000000;
    if (!done) begin
      $display("  FAIL: timed out without the double bus fault");
      $display("FAIL: core_fault_tb");
      $finish;
    end
  end

endmodule
