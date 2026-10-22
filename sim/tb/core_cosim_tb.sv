// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- a program, instruction by instruction, against UAE040.
//
// The trace (tools/cosim/uae040/uae040_trace.c) holds the state before each
// instruction: its PC, then D0-D7, A0-A6, USP, ISP, MSP, SR and the rest
// (positional hex, nfield values each; a reader takes what it knows and skips
// the rest). Each time the core completes an instruction, the state it leaves
// is compared with the trace's next entry, and its next PC with that entry's
// PC: a divergence is reported at the instruction that caused it.
//
// UAE040 is an ORACLE, not a source. Where the two disagree the manual decides.
//
//   +image=FILE   the program, as objcopy -O verilog --verilog-data-width=1
//   +trace=FILE   UAE040's trace of it
//
// The run ends when the core halts (M6: an instruction it does not build yet,
// the programs' ILLEGAL), and PASSes if every boundary before it agreed and the
// halt is at the trace's next PC.

`timescale 1ns / 1ps

module core_cosim_tb;

`include "rd68041_core_harness.svh"

  localparam int T_ISP = 16, T_SR = 18;

  integer      trc;
  int unsigned nstep, nfield, k, nret, nfail;
  logic [31:0] tpc;
  logic [31:0] treg [0:127];
  string       image, trace;
  bit          have_next;
  bit          verbose;

  task automatic read_entry();
    int r;
    r = $fscanf(trc, "%h", tpc);
    have_next = (r == 1);
    if (have_next) begin
      for (int i = 0; i < int'(nfield); i++) begin
        logic [31:0] v;
        r = $fscanf(trc, "%h", v);
        if (i < 128) treg[i] = v;
      end
    end
  endtask

  task automatic compare(input logic [31:0] pc_core);
    bit bad;
    bad = 0;
    if (pc_core !== tpc) begin
      $display("  FAIL: boundary %0d: next PC %h, the trace's %h", nret, pc_core, tpc);
      bad = 1;
    end
    for (int i = 0; i < 15; i++) begin
      if (reg_of(i) !== treg[i]) begin
        $display("  FAIL: boundary %0d (pc %h): %s%0d = %h, the trace's %h", nret, tpc,
                 (i < 8) ? "D" : "A", (i < 8) ? i : i - 8, reg_of(i), treg[i]);
        bad = 1;
      end
    end
    if (reg_of(15) !== treg[T_ISP]) begin
      $display("  FAIL: boundary %0d (pc %h): A7 (ISP) = %h, the trace's %h", nret, tpc,
               reg_of(15), treg[T_ISP]);
      bad = 1;
    end
    if (dut.u_core.sr !== treg[T_SR][15:0]) begin
      $display("  FAIL: boundary %0d (pc %h): SR = %h, the trace's %h", nret, tpc,
               dut.u_core.sr, treg[T_SR][15:0]);
      bad = 1;
    end
    if (bad) nfail = nfail + 1;
  endtask

  initial begin
    if (!$value$plusargs("image=%s", image) || !$value$plusargs("trace=%s", trace)) begin
      $display("FAIL: core_cosim_tb needs +image= and +trace=");
      $finish;
    end
    if ($bits(rd68041_pkg::uop_t) != rd68041_pkg::UOP_W) begin
      $display("FAIL: rd68041_pkg::UOP_W is %0d, the struct %0d bits",
               rd68041_pkg::UOP_W, $bits(rd68041_pkg::uop_t));
      $finish;
    end
    verbose = $test$plusargs("verbose");
    trc = $fopen(trace, "r");
    void'($fscanf(trc, "%h %h", nstep, nfield));
    read_entry();                   // the state before the first instruction
    nret = 0; nfail = 0;
    boot(image);
  end

  // At each completed instruction: the next entry, and the comparison.
  // retire is combinational, true in the clock before the edge that writes the
  // instruction's results: sample it at the edge, compare just after it.
  always @(posedge clk) begin
    bit          r;
    logic [31:0] npc;
    r   = dut.u_core.retire;
    npc = dut.u_core.retire_npc;
    #1;
    if (r) begin
      if (verbose) $display("  retire %0d: pc %h -> %h", nret, dut.u_core.w_u.pc, npc);
      read_entry();
      if (!have_next) begin
        $display("  FAIL: the core ran past the trace's end");
        nfail = nfail + 1;
      end else begin
        compare(npc);
      end
      nret = nret + 1;
      if (nfail >= 5) begin
        $display("FAIL: core_cosim_tb: stopped after %0d disagreements", nfail);
        $finish;
      end
    end
    if (dut.u_core.halted) begin
      // The programs end on ILLEGAL; a halt anywhere else is an instruction
      // the core does not build yet.
      logic [31:0] hw;
      hw = u_mem.peek_long({dut.u_core.w_u.pc[31:2], 2'b00});
      if ((dut.u_core.w_u.pc[1] ? hw[15:0] : hw[31:16]) != 16'h4AFC) begin
        $display("  FAIL: halted at %h, opcode %h: not the program's ILLEGAL",
                 dut.u_core.w_u.pc, dut.u_core.w_u.pc[1] ? hw[15:0] : hw[31:16]);
        nfail = nfail + 1;
      end
      if (nfail == 0)
        $display("PASS: core_cosim_tb: %0d instructions, every register at every boundary", nret);
      else
        $display("FAIL: core_cosim_tb: %0d of %0d boundaries disagree", nfail, nret);
      $finish;
    end
  end

  initial begin
    #20000000;
    $display("FAIL: core_cosim_tb timed out after %0d instructions", nret);
    $finish;
  end

endmodule
