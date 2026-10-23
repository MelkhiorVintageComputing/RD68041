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
//   UM 8.3     an instruction that faults after some of its micro-operations
//              completed restarts from where it began: CMPM's first address
//              register, MOVEM's address register and the registers it loaded
//              (doc/microarch.md, the undo log)
//   UM 8.2.1   a write that ends in a bus error is an access fault, taken on
//              the micro-operation in write-back (here a NOP that waits for
//              it), with the write in WB1, memory aligned, at its physical
//              address, and the writes queued behind it in WB2 and WB3,
//              register aligned, not made (UM 8.4.6.3, 8.4.6.5, Table 8-5);
//              MOVE16's line write: the line in PD0-PD3, WB1S clear; a traced
//              write: the access fault in place of the trace
//              (doc/divergences.md)
//   UM 8.2.1   a bus error while a vector is fetched for an exception: a
//              double bus fault, and the processor halts, the frame already
//              written
//
// No oracle is run here: UAE040's access error frame is M10's business
// (doc/oracles.md).

`timescale 1ns / 1ps

module core_fault_tb;

`include "rd68041_core_harness.svh"

  localparam logic [31:0] RES  = 32'h0000_FE00;
  localparam logic [31:0] RES2 = 32'h0000_FA00;
  localparam logic [31:0] RESB = 32'h0000_FB80;

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

  // A write's fault: record k at RESB, its write-backs at RES2 (fault n).
  task automatic record_wb(input int k, input int fn, input string what,
                           input logic [31:0] pc, input logic [15:0] ssw, input logic [31:0] fa,
                           input logic [15:0] wb3s, input logic [15:0] wb2s,
                           input logic [15:0] wb1s, input logic [31:0] wb3a,
                           input logic [31:0] wb3d, input logic [31:0] wb2a,
                           input logic [31:0] wb2d, input logic [31:0] wb1a,
                           input logic [31:0] wb1d);
    logic [31:0] r, q;
    r = RESB + 20 * k;
    q = RES2 + 36 * fn;
    check({what, ": the stacked PC"}, rdl(r + 2), pc);
    check({what, ": the format and vector word"}, {16'h0, rdw(r + 6)}, 32'h7008);
    check({what, ": the SSW"}, {16'h0, rdw(r + 8)}, {16'h0, ssw});
    check({what, ": FA"}, rdl(r + 10), fa);
    check({what, ": WB3S"}, {16'h0, rdw(r + 14)}, {16'h0, wb3s});
    check({what, ": WB2S"}, {16'h0, rdw(r + 16)}, {16'h0, wb2s});
    check({what, ": WB1S"}, {16'h0, rdw(r + 18)}, {16'h0, wb1s});
    if (wb3s != 16'h0) begin
      check({what, ": WB3A"}, rdl(q + 0), wb3a);
      check({what, ": WB3D"}, rdl(q + 4), wb3d);
    end
    if (wb2s != 16'h0) begin
      check({what, ": WB2A"}, rdl(q + 8), wb2a);
      check({what, ": WB2D"}, rdl(q + 12), wb2d);
    end
    check({what, ": WB1A"}, rdl(q + 16), wb1a);
    check({what, ": WB1D (PD0)"}, rdl(q + 20), wb1d);
  endtask

  task automatic finish_up();
    // SSW (UM 8.4.6.2): CP CU CT CM MA ATC LK RW X SIZE(2) TT(2) TM(3).
    record(0, "(a) a long read, supervisor", 8'h27, rdl(RES + 32'h80), 16'h0105, 32'h0000_8000);
    record(1, "(b) a word read, user",       8'h07, rdl(RES + 32'h84), 16'h0141, 32'h0000_8010);
    record(2, "(c) an instruction fetch",    8'h27, 32'h0000_8040,     16'h0106, 32'h0000_8040);
    record(3, "(d) TAS's locked read",       8'h27, rdl(RES + 32'h88), 16'h0225, 32'h0000_8020);
    check("(d) the bus after the locked fault: D3", reg_of(3), 32'h1234);
    check("(f) CMPM: A0 as it was before the instruction", rdl(RES + 32'h90), 32'h0000_5000);
    check("(f) CMPM: the FA of its frame", rdl(RES + 20*4 + 10), 32'h0000_8030);
    check("(g) MOVEM: A2 as it was before", rdl(RES + 32'h98), 32'h0000_7FF8);
    check("(g) MOVEM: D0 as it was before", rdl(RES + 32'h9C), 32'hFFFF_FFFF);
    check("(g) MOVEM: D1 as it was before", rdl(RES + 32'hA0), 32'hFFFF_FFFF);
    check("(g) MOVEM: the FA of its frame", rdl(RES + 20*5 + 10), 32'h0000_8000);
    // WBnS (UM Figure 8-8): V, SIZE(2), TT(2), TM(3).
    record_wb(0, 6, "(h) a write's bus error", rdl(RES + 32'hA4), 16'h0005, 32'h0000_8050,
              16'h0, 16'h0, 16'h0085, 32'h0, 32'h0, 32'h0, 32'h0, 32'h0000_8050, 32'h1122_3344);
    record_wb(1, 7, "(i) a long word across into it, two behind it", rdl(RES + 32'hA8),
              16'h0005, 32'h0000_8102, 16'h00A5, 16'h00C5, 16'h0085, 32'h0000_5203,
              32'h0000_00C3, 32'h0000_5200, 32'h0000_BBB2, 32'h0000_8102, 32'hCCDD_AABB);
    check("(i) the writes behind it not made", rdl(32'h0000_5200), 32'h0);
    record_wb(2, 8, "(j) MOVE16's line write", rdl(RES + 32'hAC), 16'h006D, 32'h0000_8080,
              16'h0, 16'h0, 16'h0000, 32'h0, 32'h0, 32'h0, 32'h0, 32'h0000_8080, 32'h0102_0304);
    check("(j) PD1", rdl(RES2 + 36 * 8 + 24), 32'h0506_0708);
    check("(j) PD2", rdl(RES2 + 36 * 8 + 28), 32'h090A_0B0C);
    check("(j) PD3", rdl(RES2 + 36 * 8 + 32), 32'h0D0E_0F10);
    check("(j) MOVE16 done: A0", rdl(RES + 32'hB4), 32'h0000_5110);
    check("(j) MOVE16 done: A1", rdl(RES + 32'hB8), 32'h0000_8090);
    record_wb(3, 9, "(k) a traced write's bus error", rdl(RES + 32'hBC), 16'h0005,
              32'h0000_8090, 16'h0, 16'h0, 16'h0085, 32'h0, 32'h0, 32'h0, 32'h0,
              32'h0000_8090, 32'h0000_ABCD);
    check("(k) the SR stacked traced", {16'h0, rdw(RESB + 60) & 16'hC000}, 32'h8000);
    check("(k) traces taken: the next instruction's, not the write's", rdl(RES + 32'hB0), 32'd1);
    check("(e) halted (a double bus fault)", {31'h0, dut.u_core.halted}, 32'h1);
    check("(e) TRAP #0's frame, written before the vector: its word", {16'h0, rdw(32'hEFFE)},
          32'h0080);
    check("no stray exception (D6)", reg_of(6), 32'h0);
    if (nfail == 0)
      $display("PASS: core_fault_tb: access faults on reads, fetches and writes, a double bus fault");
    else            $display("FAIL: core_fault_tb: %0d checks failed", nfail);
    $finish;
  endtask

  // +wftrace: the writes queued and the write faults, by clock (triage).
  always @(posedge clk) begin
    if ($test$plusargs("wftrace") && rst_n) begin
      if (dut.u_core.u_dmu.st_valid && dut.u_core.u_dmu.st_ready)
        $display("  %0d: queued %h (W pc %h)", cyc, dut.u_core.u_dmu.st_addr, dut.u_core.w_u.pc);
      if (dut.u_core.u_dmu.wf_now)
        $display("  %0d: write fault, x=%0d qn=%0d (W pc %h)", cyc, dut.u_core.u_dmu.x,
                 dut.u_core.u_dmu.qn, dut.u_core.w_u.pc);
      if (dut.u_core.u_dmu.d_valid && dut.u_core.u_dmu.d_ready)
        $display("  %0d: bus %h", cyc, dut.u_core.u_dmu.d_addr);
    end
  end

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
    // ... and in $8100-$81FF, after 40 wait states: (i).
    u_mem.set_region(2, 32'h0000_8100, 32'hFFFF_FF00, 40, 0, 0, 0, 0);
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
