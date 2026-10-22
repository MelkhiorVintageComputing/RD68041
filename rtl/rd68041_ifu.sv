// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- SystemVerilog MC68040
//
// Instruction fetch (IF1, IF2; doc/microarch.md): the fetch address, the
// instruction queue, and the decode stage's window on it.
//
// M6, uncached: one long-word read at a time from the bus, two instruction
// words each, into a queue of twelve words. Decode sees the first eight and how
// many of them are there, and says how many it took. A redirect -- a taken
// branch, from EX -- empties the queue and fetches from the target; a read
// already on the bus when it comes is let finish and its words thrown away.
//
// The cached front end, the half-line queue and the instruction ATC (M9, M10)
// replace the bus port with the instruction memory unit's.

module rd68041_ifu (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          crst,

    input  logic          go,          // start (or restart) fetching at go_pc
    input  logic [31:0]   go_pc,
    input  logic          stop,        // fetch nothing more (halted)
    input  logic          sup,       // supervisor program space (TM 110), else user (010)

    // To decode.
    output logic [127:0]  q_win,       // words 0-7 from the head, word 0 in 127:112
    output logic  [3:0]   q_cnt,       // how many of them are there (0-8)
    output logic [31:0]   q_pc,        // the head word's address
    input  logic  [3:0]   q_pop,       // words decode takes this clock (0-8)

    // The bus, through the arbiter.
    output logic          f_valid,
    input  logic          f_ready,
    output logic [31:0]   f_addr,
    output logic  [2:0]   f_tm,
    input  logic          f_rsp,       // a response to our read
    input  logic [31:0]   f_data,
    input  logic          f_done,
    input  logic          f_err
);

  localparam int QN = 12;

  logic [15:0] q [0:QN-1];
  logic  [3:0] head, cnt;       // the head index, the words held
  logic [31:0] hpc;             // the head word's address
  logic [31:0] fa;              // the next word to fetch
  logic        busy;            // a read is on the bus
  logic        drop;            // ... and its words are to be thrown away
  logic        on;              // fetching

  // The window.
  always_comb begin
    for (int k = 0; k < 8; k++) begin
      logic [3:0] i;
      i = 4'((int'(head) + k) % QN);
      q_win[127 - 16*k -: 16] = q[i];
    end
  end
  assign q_cnt = (cnt > 4'd8) ? 4'd8 : cnt;
  assign q_pc  = hpc;

  // Room for a long word's two, counting those already asked for.
  wire room = (int'(cnt) <= QN - 2);
  assign f_valid = on && !stop && !busy && room && !go;
  assign f_addr  = {fa[31:2], 2'b00};
  assign f_tm    = sup ? rd68041_pkg::TM_SUP_CODE : rd68041_pkg::TM_USER_CODE;

  // How many words a response adds: two, or one when the fetch address was the
  // long word's second half (after a branch to it).
  wire        skip = fa[1];

  // The queue's next count, and where the words of a response go. Computed
  // here, not as variables inside the clocked process: yosys keeps such a
  // variable as a register (doc/coding-standard.md).
  wire        take    = f_rsp && !drop;
  wire  [3:0] tail    = 4'((int'(head) + int'(cnt)) % QN);
  wire  [3:0] tail1   = 4'((int'(tail) + 1) % QN);
  wire  [3:0] cnt_nxt = cnt - q_pop + (take ? (skip ? 4'd1 : 4'd2) : 4'd0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < QN; i++) q[i] <= 16'h0000;
      head <= '0;
      cnt  <= '0;
      hpc  <= '0;
      fa   <= '0;
      busy <= 1'b0;
      drop <= 1'b0;
      on   <= 1'b0;
    end else if (crst) begin
      head <= '0;
      cnt  <= '0;
      busy <= 1'b0;
      drop <= 1'b0;
      on   <= 1'b0;
    end else begin
      if (q_pop != 4'd0) begin
        head <= 4'((int'(head) + int'(q_pop)) % QN);
        hpc  <= hpc + {27'h0, q_pop, 1'b0};
      end

      if (f_valid && f_ready) busy <= 1'b1;

      if (f_rsp || (busy && f_done)) begin
        if (take) begin
          if (skip) begin
            q[tail] <= f_data[15:0];
          end else begin
            q[tail]  <= f_data[31:16];
            q[tail1] <= f_data[15:0];
          end
          fa <= {fa[31:2] + 30'd1, 2'b00};
        end
        if (f_done) begin
          busy <= 1'b0;
          drop <= 1'b0;
        end
      end
      cnt <= cnt_nxt;

      if (go) begin
        // A redirect: everything queued goes, and a read on the bus is
        // dropped when it comes back.
        head <= '0;
        cnt  <= '0;
        hpc  <= go_pc;
        fa   <= go_pc;
        on   <= 1'b1;
        if (busy && !f_done) drop <= 1'b1;
        if (f_valid && f_ready) drop <= 1'b1;
      end
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, f_err, fa[0]};

endmodule
