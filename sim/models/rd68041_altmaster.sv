// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- an alternate bus master on the MC68040 bus, for the snoop
// testbenches: a DMA controller, as UM 4 and 7.9 have in mind.
//
// It runs one transfer at a time with the protocol of UM 7.4 -- TS for one
// clock, the address, SIZ, TT, R/W and the snoop control SC1-SC0 held until
// the termination -- and counts the terminations the way the MC68040 does: TA
// per long word of a line, TEA, a retry, and TBI on a line's first long word,
// after which it finishes the line as three long-word transfers. It drives
// everything from just after a rising edge and samples on the next, as a
// synchronous master does. The testbench gives it the bus (BG) and checks that
// the core has let go of BB first.

`timescale 1ns/1ps

module rd68041_altmaster (
    input  logic        clk,
    output logic        own,       // driving the bus
    output logic [31:0] a,
    output logic [31:0] d,
    output logic        d_oe,
    output logic  [1:0] tt,
    output logic  [1:0] siz,
    output logic        rw,
    output logic  [1:0] sc,
    output logic        ts_n,
    output logic        bb_n,
    input  logic [31:0] d_in,      // the resolved data bus
    input  logic        ta_n,
    input  logic        tea_n,
    input  logic        tbi_n
);

  initial begin
    own = 0; a = '0; d = '0; d_oe = 0; tt = 2'b00; siz = 2'b00; rw = 1;
    sc = 2'b00; ts_n = 1; bb_n = 1;
  end

  // What the last transfer moved, and how it ended.
  logic [31:0] got [0:3];
  int          n_got;
  bit          got_err, got_retry;
  int          clocks;       // from TS to the last termination

  // One transfer: a byte, word or long word (lanes as Table 7-1), or a line of
  // four long words in A3-A2 order from `addr`.
  task automatic xfer(input logic [31:0] addr, input bit write, input logic [1:0] s,
                      input logic [1:0] snoop, input logic [127:0] wdata = '0,
                      input logic [1:0] ttype = 2'b00);
    int beat, t0;
    bit line, tbi_seen, fin;
    line = (s == 2'b11);
    n_got = 0; got_err = 0; got_retry = 0; tbi_seen = 0;
    @(posedge clk);
    own <= 1; bb_n <= 0;
    a <= addr; tt <= ttype; siz <= s; rw <= !write; sc <= snoop; ts_n <= 0;
    t0 = $time;
    @(posedge clk);
    ts_n <= 1;
    if (write) begin d <= wdata[31:0]; d_oe <= 1; end
    beat = 0;
    fin = 0;
    while (!fin) begin
      @(posedge clk);
      if (!ta_n && !tea_n) begin got_retry = 1; fin = 1; end
      else if (!tea_n) begin got_err = 1; fin = 1; end
      else if (!ta_n) begin
        if (!write) got[n_got] = d_in;
        n_got = n_got + 1;
        if (!line) fin = 1;
        else if (beat == 0 && !tbi_n) begin tbi_seen = 1; fin = 1; end
        else if (beat == 3) fin = 1;
        else begin
          beat = beat + 1;
          if (write) d <= wdata[32*beat +: 32];
        end
      end
    end
    // A burst-inhibited line: three more long-word transfers.
    if (tbi_seen) begin
      for (int k = 1; k < 4 && !got_err; k++) begin
        a <= {addr[31:4], addr[3:2] + k[1:0], addr[1:0]}; siz <= 2'b00; ts_n <= 0;
        d_oe <= 0;
        @(posedge clk);
        ts_n <= 1;
        if (write) begin d <= wdata[32*k +: 32]; d_oe <= 1; end
        fin = 0;
        while (!fin) begin
          @(posedge clk);
          if (!tea_n) begin got_err = 1; fin = 1; end
          else if (!ta_n) begin if (!write) got[n_got] = d_in; n_got = n_got + 1; fin = 1; end
        end
      end
    end
    clocks = ($time - t0) / 40;
    d_oe <= 0;
    // Give the bus back: BB negated, then released, an idle clock after.
    bb_n <= 1;
    @(posedge clk);
    own <= 0;
  endtask

endmodule
