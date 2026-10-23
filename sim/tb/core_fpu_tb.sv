// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- the FPU's state frames: sim/programs/m11_fpu_c.S on the core, and
// what it stored checked against the manual and the FPSP's frame contract
// (fpsp.h: the fields' bits; doc/fpu.md, "The state frames"):
//
//   UM 9.8          the null and idle frames; FRESTORE of a null frame
//   UM 9.2.1, 9.2.2 FP0-FP7 NaN and FPCR zero after it
//   UM 9.6.1        an unimplemented instruction: vector 11, format $2, the
//                   unimplemented frame, E1 and U set, CMDREG1B
//   UM 9.6.2        an unsupported data type in opclass 010: vector 55, format
//                   $0, the PC the next instruction's; the busy frame, E1,
//                   CMDREG1B, ETEMP, STAG, NMCEXC (Table 9-16)
//   UM 9.7.6        DZ posted, taken by the next FP instruction: format $0,
//                   that instruction's PC, FPIAR the FDIV's; E1, not U
//   UM 9.8          a busy frame FRESTOREd comes back from FSAVE unchanged;
//                   CU_SAVEPC $FE resumes CMDREG1B on ETEMP and FPTEMP
//                   (res_func.S), the FPU idle after
//
// UAE040 stacks format $3 for (e) and sets neither E1 nor U for (d), and its
// FSAVE frames are its own (doc/oracles.md): this bench is the check.

`timescale 1ns / 1ps

module core_fpu_tb;

`include "rd68041_core_harness.svh"

  localparam logic [31:0] OUT  = 32'h0000_FD00;
  localparam logic [31:0] DONE = 32'h0000_FDFC;
  localparam logic [31:0] FRM  = 32'h0000_E000;
  localparam logic [31:0] REC  = 32'h0000_E800;
  localparam logic [31:0] BUF2 = 32'h0000_EC00;

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

  // The k-th exception's record: format and vector word, PC, address, FPIAR.
  task automatic exc(input int k, input string what, input logic [15:0] fv,
                     input logic [31:0] pc, input logic [31:0] fpiar);
    logic [31:0] r;
    r = REC + 16 * k;
    check({what, ": the format and vector word"}, {16'h0, rdw(r)}, {16'h0, fv});
    check({what, ": the stacked PC"}, rdl(r + 2), pc);
    check({what, ": FPIAR"}, rdl(r + 10), fpiar);
  endtask

  task automatic finish_up();
    logic [31:0] f, a_fsin, a_fsin_n, a_fadd, a_after, a_fdiv, a_fnop;
    a_fsin   = rdl(OUT + 48);
    a_fsin_n = rdl(OUT + 52);
    a_fadd   = rdl(OUT + 56);
    a_after  = rdl(OUT + 60);
    a_fdiv   = rdl(OUT + 64);
    a_fnop   = rdl(OUT + 68);
    check("no stray exception (D6)", reg_of(6), 32'h0);
    // (a), (b), (c)
    check("(a) FSAVE after reset: the null frame", rdl(OUT + 0), 32'h0000_0000);
    check("(b) FSAVE after an FP instruction: the idle frame", rdl(OUT + 4), 32'h4100_0000);
    check("(c) FPCR after FRESTORE of a null frame", rdl(OUT + 8), 32'h0000_0000);
    check("(c) FP0 after it: the exponent", rdl(OUT + 12), 32'h7FFF_0000);
    check("(c) FP0 after it: the mantissa, high", rdl(OUT + 16), 32'hFFFF_FFFF);
    check("(c) FP0 after it: the mantissa, low", rdl(OUT + 20), 32'hFFFF_FFFF);
    // (d) FSIN: the unimplemented frame, long k the busy frame's k + 12.
    exc(0, "(d) FSIN", 16'h202C, a_fsin_n, a_fsin);
    f = FRM;
    check("(d) the frame's format long word", rdl(f), 32'h4130_0000);
    check("(d) CMDREG1B", rdl(f + 4*4), 32'h008E_0000);
    check("(d) E1, E3, U", rdl(f + 4*6) & 32'h0620_0000, 32'h0420_0000);
    // (e) FADD.X of a denormal: the busy frame.
    exc(1, "(e) FADD.X of a denormal", 16'h00DC, a_after, a_fadd);
    f = FRM + 32'h70;
    check("(e) the frame's format long word", rdl(f), 32'h4160_0000);
    check("(e) CU_SAVEPC", rdl(f + 4*2) & 32'hFF00_0000, 32'h0000_0000);
    check("(e) FPIARCU", rdl(f + 4*10), a_fadd);
    check("(e) NMCEXC: unsupported", rdl(f + 4*14) & 32'h00FF_0000, 32'h0010_0000);
    check("(e) STAG: a denormal", rdl(f + 4*15) & 32'hE000_0000, 32'h8000_0000);
    check("(e) CMDREG1B", rdl(f + 4*16), 32'h4922_0000);
    check("(e) E1, E3, U", rdl(f + 4*18) & 32'h0620_0000, 32'h0400_0000);
    check("(e) ETEMP: the exponent", rdl(f + 4*22), 32'h0000_0000);
    check("(e) ETEMP: the mantissa, high", rdl(f + 4*23), 32'h4000_0000);
    check("(e) ETEMP: the mantissa, low", rdl(f + 4*24), 32'h0000_0000);
    // (f) DZ, posted to the FNOP: an E1 frame in the unimplemented frame's size.
    exc(2, "(f) DZ, taken by the FNOP", 16'h00C8, a_fnop, a_fdiv);
    f = FRM + 32'hE0;
    check("(f) the frame's format long word", rdl(f), 32'h4130_0000);
    check("(f) E1, E3, U", rdl(f + 4*6) & 32'h0620_0000, 32'h0400_0000);
    // (g) the round trip.
    for (int k = 0; k < 25; k++)
      check($sformatf("(g) the busy frame FRESTOREd and FSAVEd: long %0d", k),
            rdl(BUF2 + 4*k), rdl(FRM + 32'h70 + 4*k));
    // (h) FRESTORE that resumes: 1.0 + 2.0 into FP3, then idle.
    check("(h) FP3: the exponent", rdl(OUT + 24), 32'h4000_0000);
    check("(h) FP3: the mantissa, high", rdl(OUT + 28), 32'hC000_0000);
    check("(h) FP3: the mantissa, low", rdl(OUT + 32), 32'h0000_0000);
    check("(h) FSAVE after it: idle", rdl(OUT + 36), 32'h4100_0000);
    check("three exceptions, no more", rdl(REC + 48), 32'h0000_0000);
    if (nfail == 0)
      $display("PASS: core_fpu_tb: null, idle, unimplemented and busy frames, FRESTORE");
    else
      $display("FAIL: core_fpu_tb: %0d checks failed", nfail);
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
    if (!$value$plusargs("image=%s", image)) image = "build/programs/m11_fpu_c.hex";
    nfail = 0; done = 0;
    boot(image);
  end

  initial begin
    #5000000;
    if (!done) begin
      $display("  FAIL: timed out at PC %h", dut.u_core.w_u.pc);
      $display("FAIL: core_fpu_tb");
      $finish;
    end
  end

endmodule
