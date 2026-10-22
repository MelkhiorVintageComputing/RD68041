// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- SystemVerilog MC68040
//
// The integer register file: D0-D7 and A0-A7 (UM 2.2.1), sixteen 32-bit
// registers, A7 being whichever stack pointer the status register selects (the
// others are held beside it, M6). Flip-flops rather than LUT RAM: four reads and
// two writes a clock, and a reset value for every register (CLAUDE.md) -- the
// part leaves them undefined at reset (UM 8), and zero is as good a value as
// any other.
//
// Register numbers are the operation word's: 0-7 the data registers, 8-15 the
// address registers. Reads are combinational; a write is visible from the next
// clock. When both write ports name the same register, port 1 wins (the second
// result of an instruction is the one written later in the part's order).

module rd68041_regfile (
    input  logic        clk,
    input  logic        rst_n,

    input  logic  [3:0] ra, rb, rc, rd,
    output logic [31:0] qa, qb, qc, qd,

    input  logic        we0,
    input  logic  [3:0] wa0,
    input  logic [31:0] wd0,
    input  logic  [3:0] wm0,      // byte enables: a byte or word result leaves the rest (PRM 4)
    input  logic        we1,
    input  logic  [3:0] wa1,
    input  logic [31:0] wd1
);

  logic [31:0] r [0:15];

  for (genvar i = 0; i < 16; i++) begin : g_reg
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        r[i] <= 32'h0000_0000;
      end else if (we1 && wa1 == i[3:0]) begin
        r[i] <= wd1;
      end else if (we0 && wa0 == i[3:0]) begin
        if (wm0[3]) r[i][31:24] <= wd0[31:24];
        if (wm0[2]) r[i][23:16] <= wd0[23:16];
        if (wm0[1]) r[i][15:8]  <= wd0[15:8];
        if (wm0[0]) r[i][7:0]   <= wd0[7:0];
      end
    end
  end

  assign qa = r[ra];
  assign qb = r[rb];
  assign qc = r[rc];
  assign qd = r[rd];

endmodule
