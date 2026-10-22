// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- the bit-field unit against a model written the other way round.
//
// rd68041_bitfield works in whole words: a rotate or a shift puts the field at
// the top of a register and everything else is a function of that. The model
// here walks the field ONE BIT AT A TIME, straight off PRM 4's definition --
// offset 0 is the most significant bit of the base, and increasing offset moves
// toward less significant bits. The two share no arithmetic, which is the point.

`timescale 1ns / 1ps

module bitfield_tb;

  logic        is_reg;
  logic [31:0] reg_data;
  logic [39:0] mem_data;
  logic  [4:0] roff;
  logic  [2:0] boff;
  logic  [5:0] width;
  logic [31:0] ins;
  logic [31:0] field, sxfield, merged_reg;
  logic [39:0] merged_mem;
  logic        msb, zero;
  logic  [5:0] ffo;

  rd68041_bitfield dut (
      .is_reg (is_reg), .reg_data (reg_data), .mem_data (mem_data),
      .roff (roff), .boff (boff), .width (width), .ins (ins),
      .field (field), .sxfield (sxfield), .msb (msb), .zero (zero),
      .ffo (ffo), .merged_reg (merged_reg), .merged_mem (merged_mem));

  int unsigned fails, checks;

  task automatic check(input bit ok, input string what);
    checks = checks + 1;
    if (!ok) begin
      fails = fails + 1;
      if (fails <= 12) $display("  FAIL: %s", what);
    end
  endtask

  // One bit of the field, by PRM 4's definition and nothing else.
  function automatic bit fbit(input int unsigned k);
    int unsigned p;
    if (is_reg) begin
      p = (32'(roff) + k) % 32;              // the register wraps -- PRM 4
      fbit = reg_data[31 - p];
    end else begin
      p = 32'(boff) + k;
      fbit = mem_data[39 - p];
    end
  endfunction

  int unsigned t, k, w;
  logic [31:0] want_field, want_sx;
  logic  [5:0] want_ffo;
  logic [31:0] want_reg;
  logic [39:0] want_mem;
  bit          want_zero;

  initial begin
    $display("bitfield_tb: the bit-field unit against a bit-at-a-time model");
    fails = 0; checks = 0;

    for (t = 0; t < 4000; t = t + 1) begin
      is_reg   = t[0];
      reg_data = {$random} ^ (32'h9E37_79B9 * t);
      mem_data = {{$random}, {$random}};
      ins      = {$random} ^ (32'h85EB_CA6B * t);
      width    = 6'(1 + (t % 32));
      roff     = 5'({$random});
      boff     = 3'({$random});
      #1;

      // The field, most significant bit first.
      want_field = 32'd0;
      want_zero  = 1'b1;
      want_ffo   = width;
      for (k = 0; k < width; k = k + 1) begin
        want_field = {want_field[30:0], fbit(k)};
        if (fbit(k)) begin
          want_zero = 1'b0;
          if (want_ffo == width) want_ffo = 6'(k);
        end
      end
      want_sx = want_field;
      if (want_field[width - 1]) want_sx = want_field | (32'hFFFF_FFFF << width);

      check(field   === want_field, $sformatf("t=%0d field", t));
      check(sxfield === want_sx,    $sformatf("t=%0d sxfield", t));
      check(msb     === fbit(0),    $sformatf("t=%0d msb", t));
      check(zero    === want_zero,  $sformatf("t=%0d zero", t));
      check(ffo     === want_ffo,   $sformatf("t=%0d ffo", t));

      // Putting it back: every bit of the field replaced, every other bit left.
      want_reg = reg_data;
      want_mem = mem_data;
      for (k = 0; k < width; k = k + 1) begin
        w = 32'(width) - 1 - k;                 // which bit of `ins` this is
        if (is_reg) want_reg[31 - ((32'(roff) + k) % 32)] = ins[w];
        else        want_mem[39 - (32'(boff) + k)]        = ins[w];
      end
      if (is_reg) check(merged_reg === want_reg, $sformatf("t=%0d merged_reg", t));
      else        check(merged_mem === want_mem, $sformatf("t=%0d merged_mem", t));
    end

    $display("bitfield_tb: %0d checks, %0d failed", checks, fails);
    if (fails == 0) $display("PASS: bitfield_tb");
    else            $display("FAIL: bitfield_tb");
    $finish;
  end

endmodule
