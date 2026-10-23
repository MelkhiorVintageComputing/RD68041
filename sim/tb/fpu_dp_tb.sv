// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- the floating-point data path alone (rtl/rd68041_fpu_dp.sv), for
// tools/fpu/check_testfloat.py, which writes the vectors, runs this, and
// compares what it prints with Berkeley TestFloat's results.
//
// Each vector, one a line (hex):  id op prec rmode isz infmt outfmt a b
//   infmt:  0 extended (80 bits), 1 single, 2 double, 3 a 32-bit integer
//   outfmt: 0 extended, 1 single, 2 double, 3 the integer D_INT makes
// a is the destination operand (dyadic operations), b the source.
// Each answer, one a line:  id result flags
//   flags: {snan, operr, ovfl, unfl, dz, inex} as six bits.

`timescale 1ns / 1ps

module fpu_dp_tb;
  import rd68041_fpu_pkg::*;

  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n = 1'b0;

  logic        start = 1'b0;
  logic  [3:0] op;
  fpn_t        a, b, r;
  logic  [1:0] prec, rmode, isz;
  logic        busy, done;
  logic        f_snan, f_operr, f_ovfl, f_unfl, f_dz, f_inex, f_spec;
  logic [17:0] i_exp;
  logic [66:0] i_man;
  logic [31:0] r_int;
  logic        c_lt, c_eq, c_un;

  rd68041_fpu_dp u_dp (
      .clk(clk), .rst_n(rst_n), .crst(1'b0), .kill(1'b0), .start_i(start), .op_i(op), .a_i(a),
      .b_i(b), .prec_i(prec), .rmode_i(rmode), .isz_i(isz), .busy(busy), .done(done), .r(r),
      .f_snan(f_snan), .f_operr(f_operr), .f_ovfl(f_ovfl), .f_unfl(f_unfl), .f_dz(f_dz),
      .f_inex(f_inex), .f_spec(f_spec), .f_dnz(), .i_exp(i_exp), .i_man(i_man), .r_int(r_int),
      .c_lt(c_lt), .c_eq(c_eq), .c_un(c_un));

  function automatic fpn_t unpack(input logic [1:0] f, input logic [79:0] v);
    case (f)
      2'd1:    unpack = unpack_s(v[31:0]);
      2'd2:    unpack = unpack_d(v[63:0]);
      2'd3:    unpack = unpack_i(v[31:0]);
      default: unpack = unpack_x(v);
    endcase
  endfunction

  string       vecf, outf;
  int          fi, fo, n;
  logic [31:0] id, vop, vprec, vrm, visz, vin, vout;
  logic [79:0] va, vb, res;

  initial begin
    if (!$value$plusargs("vec=%s", vecf)) vecf = "build/fpu_dp.vec";
    if (!$value$plusargs("out=%s", outf)) outf = "build/fpu_dp.out";
    fi = $fopen(vecf, "r");
    fo = $fopen(outf, "w");
    if (fi == 0) begin $display("FAIL: fpu_dp_tb: no %s", vecf); $finish; end
    a = '0; b = '0; op = '0; prec = '0; rmode = '0; isz = '0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
    n = 0;
    while ($fscanf(fi, "%h %h %h %h %h %h %h %h %h", id, vop, vprec, vrm, visz, vin, vout,
                   va, vb) == 9) begin
      op = vop[3:0]; prec = vprec[1:0]; rmode = vrm[1:0]; isz = visz[1:0];
      a = unpack(vin[1:0], va);
      b = unpack(vin[1:0], vb);
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      while (!done) @(negedge clk);
      case (vout[1:0])
        2'd1:    res = {48'h0, pack_s(r)};
        2'd2:    res = {16'h0, pack_d(r)};
        2'd3:    res = {48'h0, r_int};
        default: res = pack_x(r);
      endcase
      $fdisplay(fo, "%0h %0h %0h", id, res,
                {f_snan, f_operr, f_ovfl, f_unfl, f_dz, f_inex});
      n++;
      @(negedge clk);
    end
    $fclose(fo);
    $display("fpu_dp_tb: %0d vectors", n);
    $finish;
  end

endmodule
