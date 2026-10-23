// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- SystemVerilog MC68040
//
// Instruction fetch (IF1, IF2; doc/microarch.md): the fetch address, the
// instruction queue, and the decode stage's window on it.
//
// M6, uncached: one long-word read at a time from the bus, two instruction
// words each, into a queue of twelve words -- room for the longest
// instruction, eleven (PRM 2.2: MOVE with two full-format <ea>s). Decode sees
// all of it and how many words are there, and says how many it took. A redirect -- a taken
// branch, from EX -- empties the queue and fetches from the target; a read
// already on the bus when it comes is let finish and its words thrown away.
//
// A fetch that ends in a bus error puts its words in the queue marked
// (q_err), and decode turns the instruction that needs one into an access
// fault (UM 8.2.1: "bus errors that occur during instruction prefetches are
// deferred until the processor attempts to use the information"). A redirect
// to an odd address fetches nothing and says so (q_aerr): the address error
// (UM 8.2.2).
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
    output logic [191:0]  q_win,       // the queue from its head, word 0 in 191:176
    output logic  [3:0]   q_cnt,       // how many words are there (0-12)
    output logic [31:0]   q_pc,        // the head word's address
    output logic [11:0]   q_err,       // which of them came from a faulted fetch (bit k: word k)
    output logic          q_aerr,      // fetching was redirected to an odd address
    input  logic  [3:0]   q_pop,       // words decode takes this clock (0-12)

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
  logic        qe [0:QN-1];     // ... from a fetch that faulted
  logic  [3:0] head, cnt;       // the head index, the words held
  logic [31:0] hpc;             // the head word's address
  logic [31:0] fa;              // the next word to fetch
  logic        busy;            // a read is on the bus
  logic        drop;            // ... and its words are to be thrown away
  logic        on;              // fetching

  // The window.
  always_comb begin
    for (int k = 0; k < QN; k++) begin
      logic [3:0] i;
      i = 4'((int'(head) + k) % QN);
      q_win[191 - 16*k -: 16] = q[i];
      q_err[k] = qe[i];
    end
  end
  assign q_cnt = cnt;
  assign q_pc  = hpc;

  // Room for a long word's two, counting those already asked for.
  wire room = (int'(cnt) <= QN - 2);
  logic aerr;                   // redirected to an odd address: nothing to fetch
  assign q_aerr  = aerr;
  assign f_valid = on && !stop && !busy && room && !go && !aerr;
  assign f_addr  = {fa[31:2], 2'b00};
  assign f_tm    = sup ? rd68041_pkg::TM_SUP_CODE : rd68041_pkg::TM_USER_CODE;

  // How many words a response adds: two, or one when the fetch address was the
  // long word's second half (after a branch to it).
  wire        skip = fa[1];

  // The queue's next count, and where the words of a response go. Computed
  // here, not as variables inside the clocked process: yosys keeps such a
  // variable as a register (doc/coding-standard.md).
  // A fault answers with no data: its words go in marked.
  wire        bad     = busy && f_done && f_err && !drop;
  wire        take    = (f_rsp && !drop) || bad;
  wire  [3:0] tail    = 4'((int'(head) + int'(cnt)) % QN);
  wire  [3:0] tail1   = 4'((int'(tail) + 1) % QN);
  wire  [3:0] cnt_nxt = cnt - q_pop + (take ? (skip ? 4'd1 : 4'd2) : 4'd0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < QN; i++) begin q[i] <= 16'h0000; qe[i] <= 1'b0; end
      aerr <= 1'b0;
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
      aerr <= 1'b0;
    end else begin
      if (q_pop != 4'd0) begin
        head <= 4'((int'(head) + int'(q_pop)) % QN);
        hpc  <= hpc + {27'h0, q_pop, 1'b0};
      end

      if (f_valid && f_ready) busy <= 1'b1;

      if (f_rsp || (busy && f_done)) begin
        if (take) begin
          if (skip) begin
            q[tail]  <= f_data[15:0];
            qe[tail] <= bad;
          end else begin
            q[tail]   <= f_data[31:16];
            q[tail1]  <= f_data[15:0];
            qe[tail]  <= bad;
            qe[tail1] <= bad;
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
        aerr <= go_pc[0];
        if (busy && !f_done) drop <= 1'b1;
        if (f_valid && f_ready) drop <= 1'b1;
      end
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, fa[0]};

endmodule
