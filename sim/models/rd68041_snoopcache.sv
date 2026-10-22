// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- a stand-in for the caches on the snooper's port, for the M2
// testbenches: a handful of data-cache lines (tag, valid, four dirty bits, four
// long words) and instruction-cache lines (tag, valid), set by the testbench,
// answering the port the way rd68041_snoop expects (rtl/rd68041_snoop.sv):
// the lookup combinationally, the data one clock behind its address, writes
// and invalidations on the clock they are asked for. The real caches take its
// place at M9.

`timescale 1ns/1ps

module rd68041_snoopcache (
    input  logic        clk,
    input  logic [31:0] sn_addr,
    output logic        sn_dhit,
    output logic        sn_ddirty,
    output logic        sn_ihit,
    output logic [31:0] sn_rdata,
    input  logic        sn_wr,
    input  logic  [3:0] sn_wbe,
    input  logic [31:0] sn_wdata,
    input  logic        sn_dinv,
    input  logic        sn_iinv
);

  localparam int N = 4;
  logic [27:0] d_tag  [0:N-1];     // A31-A4
  bit          d_v    [0:N-1];
  logic  [3:0] d_dirty[0:N-1];     // one per long word, A3-A2
  logic [31:0] d_data [0:N-1][0:3];
  logic [27:0] i_tag  [0:N-1];
  bit          i_v    [0:N-1];

  int n_wr, n_dinv, n_iinv;

  initial begin
    for (int i = 0; i < N; i++) begin d_v[i] = 0; i_v[i] = 0; d_dirty[i] = 0; end
    n_wr = 0; n_dinv = 0; n_iinv = 0;
    sn_rdata = '0;
  end

  // The line that hits, or -1. Recomputed wherever it is needed rather than
  // kept in a variable a combinational block both writes and reads.
  function automatic int dline(input logic [31:0] ad);
    dline = -1;
    for (int i = 0; i < N; i++) if (d_v[i] && d_tag[i] == ad[31:4]) dline = i;
  endfunction
  function automatic int iline(input logic [31:0] ad);
    iline = -1;
    for (int i = 0; i < N; i++) if (i_v[i] && i_tag[i] == ad[31:4]) iline = i;
  endfunction

  // Re-evaluated on every clock edge and address change: the tags only change
  // on a clock edge (here or from a testbench task between edges).
  always @(sn_addr or clk) begin
    sn_dhit   = (dline(sn_addr) >= 0);
    sn_ddirty = sn_dhit && (d_dirty[dline(sn_addr)] != 4'b0000);
    sn_ihit   = (iline(sn_addr) >= 0);
  end

  int dh, ih;
  always @(posedge clk) begin
    dh = dline(sn_addr);
    ih = iline(sn_addr);
    if (dh >= 0) sn_rdata <= d_data[dh][sn_addr[3:2]];
    else         sn_rdata <= 32'hXXXX_XXXX;
    if (sn_wr && dh >= 0) begin
      for (int b = 0; b < 4; b++)
        if (sn_wbe[3-b]) d_data[dh][sn_addr[3:2]][31-8*b -: 8] <= sn_wdata[31-8*b -: 8];
      d_dirty[dh][sn_addr[3:2]] <= 1'b1;
      n_wr = n_wr + 1;
    end
    if (sn_dinv && dh >= 0) begin d_v[dh] <= 0; n_dinv = n_dinv + 1; end
    if (sn_iinv && ih >= 0) begin i_v[ih] <= 0; n_iinv = n_iinv + 1; end
  end

  task automatic set_dline(input int i, input logic [31:0] addr, input logic [3:0] dirty,
                           input logic [31:0] w0, input logic [31:0] w1,
                           input logic [31:0] w2, input logic [31:0] w3);
    d_tag[i] = addr[31:4]; d_v[i] = 1; d_dirty[i] = dirty;
    d_data[i][0] = w0; d_data[i][1] = w1; d_data[i][2] = w2; d_data[i][3] = w3;
  endtask

  task automatic set_iline(input int i, input logic [31:0] addr);
    i_tag[i] = addr[31:4]; i_v[i] = 1;
  endtask

  task automatic clear();
    for (int i = 0; i < N; i++) begin d_v[i] = 0; i_v[i] = 0; d_dirty[i] = 0; end
  endtask

endmodule
