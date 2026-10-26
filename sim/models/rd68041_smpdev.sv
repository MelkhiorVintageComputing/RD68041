// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- the two-processor board's devices, for sim/tb/core_smp_tb.sv
// (doc/smp.md): what a board with two MC68040s needs that the processors'
// wiring does not give it. Long-word registers at BASE, answered as the
// slave model answers (TA from the clock after TS, once MI lets memory
// respond, UM 7.9), normal accesses only:
//
//   BASE+$0  WHOAMI    read: the processor making the access -- the one the
//                      arbiter has granted the bus, or last granted (both
//                      processors fetch the same reset vectors, so this is
//                      how each learns its number)
//   BASE+$4  IPI_SET   write n: raise the interprocessor interrupt of CPU n
//   BASE+$8  IPI_ACK   write: lower the writer's own
//   BASE+$C  RELEASE   write: let CPU 1 out of reset
//
// A raised interprocessor interrupt holds that processor's IPL2-IPL0 at level
// 5 until it is acknowledged; the board grounds AVEC, so the acknowledge
// cycle is autovectored (vector 29).

`timescale 1ns/1ps

module rd68041_smpdev #(
    parameter logic [31:0] BASE = 32'hFFFF_0000
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [31:0] a,
    input  logic [31:0] d_in,
    output logic [31:0] d_out,
    output logic        d_oe,
    input  logic  [1:0] tt,
    input  logic        rw,
    input  logic        ts_n,
    input  logic        mi_n,
    input  logic        who,       // the arbiter's: the processor that may start a transfer
    output logic        ta_n,
    output logic  [1:0] ipi,       // CPU n's interprocessor interrupt raised
    output logic        release1,  // CPU 1 let out of reset
    output int          n_access
);

  bit          busy;
  logic  [3:2] x_reg;
  logic        x_rw, x_who;

  wire hit = (tt == 2'b00) && ((a & 32'hFFFF_FFF0) == BASE);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy = 0; ta_n <= 1; d_oe <= 0; d_out <= '0; ipi <= 2'b00; release1 <= 0;
      n_access = 0;
    end else begin
      // The edge the processor sampled our TA on: a write's data is on the bus.
      if (busy && !ta_n) begin
        busy = 0;
        if (!x_rw) begin
          case (x_reg)
            2'd1: ipi[d_in[0]] <= 1'b1;
            2'd2: ipi[x_who]   <= 1'b0;
            2'd3: release1     <= 1'b1;
            default: ;
          endcase
        end
      end
      ta_n <= 1; d_oe <= 0;
      if (!ts_n && hit) begin
        busy = 1; x_reg = a[3:2]; x_rw = rw; x_who = who;
        n_access = n_access + 1;
      end else if (busy && mi_n) begin
        ta_n <= 0;
        if (x_rw) begin
          d_out <= (x_reg == 2'd0) ? {31'h0, x_who} : 32'h0;
          d_oe  <= 1;
        end
      end
    end
  end

endmodule
