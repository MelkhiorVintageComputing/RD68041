// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- the MC68LC040's FP instructions (M12): sim/programs/m12_lc040_b.S
// on the core, whichever it is built as (TB_FPU), and the frames it recorded
// checked against the manual where UAE040 stacks something else
// (doc/oracles.md):
//
//   UM 8.4.1, A.5.1  an encoding PRM 5 has no FP instruction for, or a
//                    coprocessor ID other than 1: F-line, format $0, the PC
//                    the instruction's -- on both parts
//   UM A.5.1         on the MC68LC040, FDBcc: format $4, the address 0; and
//                    FMOVE.P FPn,-(An){Dn}: the address An - 12, An as it was
//   UM 8.4, A.5.2    RTE of a format $4 frame: taken on the MC68LC040, a
//                    format error (vector 14) on the MC68040
//
// make cosim-lc and the lc040 vector group check the rest of the format $4
// frame against UAE040 -L.

`timescale 1ns / 1ps

module core_lc040_tb;

`include "rd68041_core_harness.svh"

  localparam logic [31:0] OUT  = 32'h0000_FD00;
  localparam logic [31:0] DONE = 32'h0000_FDFC;
  localparam logic [31:0] REC  = 32'h0000_E800;
  localparam logic [31:0] DATA = 32'h0000_4000;

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

  // The k-th exception's record: format and vector word, PC, then the
  // frame's long words +$08 and +$0C at +6 and +10.
  task automatic exc(input int k, input string what, input logic [15:0] fv, input logic [31:0] pc);
    logic [31:0] r;
    r = REC + 16 * k;
    check({what, ": the format and vector word"}, {16'h0, rdw(r)}, {16'h0, fv});
    check({what, ": the stacked PC"}, rdl(r + 2), pc);
  endtask

  task automatic finish_up();
    logic [31:0] a_ill0, a_fdb, a_fdb_n, a_pk, a_pk_n, a_rte, a_ill5, r;
    int          k;
    a_ill0  = rdl(OUT + 0);
    a_fdb   = rdl(OUT + 4);
    a_fdb_n = rdl(OUT + 8);
    a_pk    = rdl(OUT + 12);
    a_pk_n  = rdl(OUT + 16);
    a_rte   = rdl(OUT + 20);
    a_ill5  = rdl(OUT + 24);
    check("no stray exception (D6)", reg_of(6), 32'h0);
    k = 0;
    if (`TB_FPU == 0) begin
      exc(k, "the first FNOP: format $4", 16'h402C, a_ill0 - 32'd2);
      k++;
    end
    // (a) every one F-line, format $0, the instruction's PC.
    for (int i = 0; i < 6; i++) begin
      exc(k, $sformatf("(a) F-line illegal %0d", i), 16'h002C, a_ill0 + 32'(4 * i));
      k++;
    end
    check("(a) the last's PC", a_ill5, a_ill0 + 32'd20);
    if (`TB_FPU == 0) begin
      // (b) FDBcc: format $4, the address 0, the PCs.
      r = REC + 16 * k;
      exc(k, "(b) FDBcc", 16'h402C, a_fdb_n);
      check("(b) FDBcc: the address", rdl(r + 6), 32'h0);
      check("(b) FDBcc: the faulted instruction's PC", rdl(r + 10), a_fdb);
      k++;
      // (c) FMOVE.P FP0,-(A1){D5}: An - 12, A1 untouched.
      r = REC + 16 * k;
      exc(k, "(c) FMOVE.P -(An){Dn}", 16'h402C, a_pk_n);
      check("(c) FMOVE.P: the address", rdl(r + 6), DATA + 32'h100 - 32'd12);
      check("(c) FMOVE.P: the faulted instruction's PC", rdl(r + 10), a_pk);
      check("(c) A1 after it", rdl(OUT + 28), DATA + 32'h100);
      k++;
    end else begin
      // (d) on the MC68040: a format error, the RTE's PC.
      exc(k, "(d) RTE of a $4 frame on the MC68040", 16'h0038, a_rte);
      k++;
    end
    check("(d) SP after the RTE", rdl(OUT + 32), 32'h0000_F000);
    check("no more exceptions", rdl(REC + 16 * k), 32'h0000_0000);
    if (nfail == 0 && `TB_FPU == 0)
      $display("PASS: core_lc040_tb: MC68LC040, F-line, FDBcc, FMOVE.P, RTE of $4");
    else if (nfail == 0)
      $display("PASS: core_lc040_tb: MC68040, F-line, RTE of $4 a format error");
    else
      $display("FAIL: core_lc040_tb: %0d checks failed", nfail);
    $finish;
  endtask

  always @(posedge clk) begin
    if (!done && rst_n && (u_mem.peek_long(DONE) == 32'hC0DE_0000 || dut.u_core.halted)) begin
      done = 1;
      repeat (8) @(posedge clk);
      finish_up();
    end
  end

  initial begin
    if (!$value$plusargs("image=%s", image)) image = "build/programs/m12_lc040_b.hex";
    nfail = 0; done = 0;
    boot(image);
  end

  initial begin
    #5000000;
    if (!done) begin
      $display("  FAIL: timed out at PC %h", dut.u_core.w_u.pc);
      $display("FAIL: core_lc040_tb");
      $finish;
    end
  end

endmodule
