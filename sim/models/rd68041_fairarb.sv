// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- the dual-MC68040 fairness arbiter of UM 7.8.2.1, corrected, for
// the two-processor testbench (sim/tb/core_smp_tb.sv; doc/smp.md).
//
// Figure 7-35 as doc/um-7-8-2-1-fairness-arbitration.md section 6.1 corrects
// it (F1: every arc's asterisk is "asserted", as note 2 says; F2: state A's
// self-loop has /LOCKE*; F3: no grant in B and D), synchronous on BCLK:
//
//   A  /BG1 asserted  -> B if /BR2 asserted and (/LOCK negated, or /LOCK and
//                        /LOCKE asserted)
//   B  neither        -> C if /BB negated; back to A if /BB and /LOCK
//                        asserted and /LOCKE negated (a locked sequence begun)
//   C  /BG2 asserted  -> D, as A -> B with /BR1
//   D  neither        -> A, as B -> C; back to C as B -> A
//
// Processor 1 is the bench's CPU 0, processor 2 its CPU 1. The inputs are the
// bus lines as resolved on the board (pulled up when undriven); the grants
// are registered, so they change just after the edge the state does.
//
//   use_locke = 0  /LOCKE is taken as always negated: UM 7.8.2.1's arbiter
//                  for a system that retries the last write of a locked
//                  sequence (section 5 of the corrected text). A state is
//                  left only when /LOCK is negated.
//   gapless   = 1  B and D grant as the printed figure does ("/BG1, /BG2*"
//                  and "/BG1*, /BG2"), the handover F3 is about: kept only
//                  for the bench's negative test.

`timescale 1ns/1ps

module rd68041_fairarb (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       use_locke,
    input  logic       gapless,
    input  logic       br1_n,
    input  logic       br2_n,
    input  logic       bb_n,
    input  logic       lock_n,
    input  logic       locke_n,
    output logic       bg1_n,
    output logic       bg2_n,
    output logic [1:0] state,     // 0 A, 1 B, 2 C, 3 D
    output logic       who        // the processor that may start a transfer: the one
                                  // granted, else the one granted last (A, B: 0)
);

  localparam logic [1:0] S_A = 2'd0, S_B = 2'd1, S_C = 2'd2, S_D = 2'd3;

  wire br1   = !br1_n;
  wire br2   = !br2_n;
  wire bb    = !bb_n;
  wire lock  = !lock_n;
  wire locke = use_locke && !locke_n;

  logic [1:0] nx;
  always_comb begin
    nx = state;
    case (state)
      S_A: if (br2 && (!lock || locke)) nx = S_B;
      S_B: if (!bb) nx = S_C; else if (lock && !locke) nx = S_A;
      S_C: if (br1 && (!lock || locke)) nx = S_D;
      default: if (!bb) nx = S_A; else if (lock && !locke) nx = S_C;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_A;
      bg1_n <= 1'b0;
      bg2_n <= 1'b1;
    end else begin
      state <= nx;
      bg1_n <= !((nx == S_A) || (gapless && nx == S_D));
      bg2_n <= !((nx == S_C) || (gapless && nx == S_B));
    end
  end

  assign who = !bg2_n ? 1'b1 : !bg1_n ? 1'b0 : state[1];

endmodule
