// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- SystemVerilog MC68040
//
// The data memory unit: the integer unit's operand reads (from OF) and writes
// (from W), turned into bus transfers.
//
// M6, no data cache and no MMU: every operand is a bus access. An operand the
// bus cannot move in one transfer is split into aligned ones as UM 7.3 and
// Table 7-3 say -- a long word at offset 1 is a byte, a word and a byte -- and
// each byte is put on the lanes Table 7-1 gives it.
//
// Writes go into a queue of three, oldest first, because the write-back stage
// may not wait for the bus (UM 2.1: the write-back "can stall indefinitely
// until either the data memory unit is free"). A read is let past them -- UM
// 7.7: "data read and write accesses [may] occur out of order" -- unless it
// touches a long word one of them writes, in which case the writes go first
// ("the processor detects a read access that references earlier data waiting
// to be written ... and allows the corresponding write access to complete").
// The three are the access error frame's WB3-WB1 (doc/checkpoint.md) once the
// data cache and the MMU give them their separate stages (M9, M10).

module rd68041_dmu (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          crst,
    input  logic          sup,       // supervisor data space (TM 101), else user (001)

    // A read, from OF: held until done.
    input  logic          ld_valid,
    input  logic [31:0]   ld_addr,
    input  logic  [1:0]   ld_sz,       // rd68041_pkg::SZ_*
    output logic          ld_done,     // one clock, with the data
    output logic [31:0]   ld_data,     // right justified, zero extended
    output logic          ld_err,
    input  logic          ld_cancel,   // the read is no longer wanted: finish it silently

    // A write, from W.
    input  logic          st_valid,
    input  logic [31:0]   st_addr,
    input  logic  [1:0]   st_sz,
    input  logic [31:0]   st_data,     // right justified
    output logic          st_ready,    // taken this clock
    output logic          st_empty,    // nothing waiting (NOP, M8)

    // The bus, through the arbiter.
    output logic          d_valid,
    input  logic          d_ready,
    output logic [31:0]   d_addr,
    output logic          d_write,
    output logic  [1:0]   d_siz,
    output logic  [2:0]   d_tm,
    output logic [31:0]   d_wdata,
    input  logic          d_rsp,
    input  logic [31:0]   d_data,
    input  logic          d_done,
    input  logic          d_err
);

  // --- the write queue ------------------------------------------------------
  logic [31:0] qa [0:2];
  logic  [1:0] qs [0:2];
  logic [31:0] qd [0:2];
  logic  [1:0] qn;               // writes held

  // The bytes an operand of size sz occupies at address a, as long words.
  function automatic logic [2:0] nbytes(input logic [1:0] sz);
    nbytes = (sz == rd68041_pkg::SZ_B) ? 3'd1 : (sz == rd68041_pkg::SZ_W) ? 3'd2 : 3'd4;
  endfunction
  function automatic logic overlap(input logic [31:0] a0, input logic [1:0] s0,
                                   input logic [31:0] a1, input logic [1:0] s1);
    logic [31:2] e0, e1;
    // The last long word each touches -- the next one when the operand runs
    // past its first; long-word granularity: the two overlap if they touch a
    // common long word.
    e0 = a0[31:2] + {29'h0, ({1'b0, a0[1:0]} + nbytes(s0)) > 3'd4};
    e1 = a1[31:2] + {29'h0, ({1'b0, a1[1:0]} + nbytes(s1)) > 3'd4};
    overlap = !((e0 < a1[31:2]) || (e1 < a0[31:2]));
  endfunction

  wire hit0 = (qn > 2'd0) && overlap(ld_addr, ld_sz, qa[0], qs[0]);
  wire hit1 = (qn > 2'd1) && overlap(ld_addr, ld_sz, qa[1], qs[1]);
  wire hit2 = (qn > 2'd2) && overlap(ld_addr, ld_sz, qa[2], qs[2]);
  wire ld_blocked = hit0 || hit1 || hit2;

  // --- the operand under way ------------------------------------------------
  typedef enum logic [1:0] { X_IDLE, X_LD, X_ST } x_e;
  x_e          x;
  logic [31:0] xa;               // the next byte's address
  logic  [2:0] xn;               // bytes still to move
  logic [31:0] xd;               // the store's data, or the load's so far
  logic        xbusy;            // a transfer of it is on the bus
  logic        xerr;
  logic        xcancel;          // the read under way was cancelled
  logic  [2:0] cur_n;            // the bytes of the transfer on the bus
  logic  [1:0] cur_siz;
  logic  [1:0] cur_a10;

  // The next transfer: a long word if aligned and four remain, else a word if
  // even and two remain, else a byte (UM Table 7-3).
  wire [1:0] t_siz = (xa[1:0] == 2'b00 && xn >= 3'd4) ? rd68041_pkg::SIZ_LONG :
                     (xa[0] == 1'b0 && xn >= 3'd2)    ? rd68041_pkg::SIZ_WORD :
                                                        rd68041_pkg::SIZ_BYTE;
  wire [2:0] t_n   = (t_siz == rd68041_pkg::SIZ_LONG) ? 3'd4 :
                     (t_siz == rd68041_pkg::SIZ_WORD) ? 3'd2 : 3'd1;

  // A store's bytes: xd holds the operand right justified; the transfer takes
  // the next t_n of them from the most significant end still unsent.
  // The `left` bytes still to send are the low ones of the right-justified
  // operand, the next of them its most significant: bits 8*left-1 down to
  // 8*(left-n).
  function automatic logic [31:0] st_bytes(input logic [31:0] d, input logic [2:0] left,
                                           input logic [2:0] n);
    logic [31:0] v;
    v = d >> (8 * (int'(left) - int'(n)));
    case (n)
      3'd1:    st_bytes = {24'h0, v[7:0]};
      3'd2:    st_bytes = {16'h0, v[15:0]};
      default: st_bytes = v;
    endcase
  endfunction

  // Table 7-1: where those bytes go on D31-D0.
  function automatic logic [31:0] to_lanes(input logic [31:0] v, input logic [1:0] siz);
    // A byte or a word on every lane it could be on: the slave takes the ones
    // SIZ and A1-A0 select (Table 7-1), and the rest are "driven with
    // undefined data" (UM 7.2).
    case (siz)
      rd68041_pkg::SIZ_BYTE: to_lanes = {4{v[7:0]}};
      rd68041_pkg::SIZ_WORD: to_lanes = {2{v[15:0]}};
      default:               to_lanes = v;
    endcase
  endfunction

  // ... and back from them, for a read.
  function automatic logic [31:0] from_lanes(input logic [31:0] d, input logic [1:0] siz,
                                             input logic [1:0] a10);
    case (siz)
      rd68041_pkg::SIZ_BYTE: from_lanes = {24'h0, d[31 - 8*a10 -: 8]};
      rd68041_pkg::SIZ_WORD: from_lanes = {16'h0, a10[1] ? d[15:0] : d[31:16]};
      default:               from_lanes = d;
    endcase
  endfunction

  assign d_valid = (x != X_IDLE) && !xbusy && (xn != 3'd0);
  assign d_addr  = xa;
  assign d_write = (x == X_ST);
  assign d_siz   = t_siz;
  assign d_tm    = sup ? rd68041_pkg::TM_SUP_DATA : rd68041_pkg::TM_USER_DATA;
  assign d_wdata = to_lanes(st_bytes(xd, xn, t_n), t_siz);

  // A read's bytes so far, and this transfer's added below them.
  wire [31:0] got   = from_lanes(d_data, cur_siz, cur_a10);
  wire [31:0] accum = (cur_n == 3'd4) ? got : ((xd << (8 * int'(cur_n))) | got);

  // A load starts when nothing is under way, nothing it reads is waiting to be
  // written, and it is asked for; a queued write starts otherwise.
  wire start_ld = (x == X_IDLE) && ld_valid && !ld_blocked && !ld_done && !ld_cancel;
  wire start_st = (x == X_IDLE) && !start_ld && (qn != 2'd0);

  assign st_ready = st_valid && (qn != 2'd3);

  // The oldest write leaves the queue on the clock its last transfer is
  // answered; a new one goes in behind what is left.
  wire       q_out = (x == X_ST) && xbusy && d_done && ((xn == cur_n) || d_err);
  wire [1:0] q_in  = qn - {1'b0, q_out};
  assign st_empty = (qn == 2'd0) && (x != X_ST);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 3; i++) begin qa[i] <= '0; qs[i] <= '0; qd[i] <= '0; end
      qn      <= '0;
      x       <= X_IDLE;
      xa      <= '0;
      xn      <= '0;
      xd      <= '0;
      xbusy   <= 1'b0;
      xerr    <= 1'b0;
      xcancel <= 1'b0;
      cur_n   <= '0;
      cur_siz <= '0;
      cur_a10 <= '0;
      ld_done <= 1'b0;
      ld_data <= '0;
      ld_err  <= 1'b0;
    end else if (crst) begin
      qn      <= '0;
      x       <= X_IDLE;
      xbusy   <= 1'b0;
      ld_done <= 1'b0;
    end else begin
      ld_done <= 1'b0;
      // A cancelled read still finishes on the bus, as every transfer must,
      // but answers nobody.
      if (ld_cancel && (x == X_LD || start_ld)) xcancel <= 1'b1;

      // A transfer taken by the bus.
      if (d_valid && d_ready) begin
        xbusy   <= 1'b1;
        cur_n   <= t_n;
        cur_siz <= t_siz;
        cur_a10 <= xa[1:0];
      end
      // ... and answered.
      if (xbusy && d_done) begin
        xbusy <= 1'b0;
        if (d_err) xerr <= 1'b1;
        if (x == X_LD && d_rsp) xd <= accum;
        xa <= xa + 32'(cur_n);
        xn <= xn - cur_n;
        if (xn == cur_n || d_err) begin
          if (x == X_LD) begin
            ld_done <= !(xcancel || ld_cancel);
            xcancel <= 1'b0;
            ld_err  <= d_err || xerr;
            ld_data <= accum;
          end else begin
            // The oldest write is done: the queue moves up.
            qa[0] <= qa[1]; qs[0] <= qs[1]; qd[0] <= qd[1];
            qa[1] <= qa[2]; qs[1] <= qs[2]; qd[1] <= qd[2];
          end
          x    <= X_IDLE;
          xerr <= 1'b0;
        end
      end

      if (start_ld) begin
        x    <= X_LD;
        xa   <= ld_addr;
        xn   <= nbytes(ld_sz);
        xd   <= '0;
      end else if (start_st) begin
        x    <= X_ST;
        xa   <= qa[0];
        xn   <= nbytes(qs[0]);
        xd   <= qd[0];
      end

      // A new write joins the queue behind those still there.
      if (st_ready) begin
        qa[q_in] <= st_addr; qs[q_in] <= st_sz; qd[q_in] <= st_data;
      end
      qn <= qn - {1'b0, q_out} + {1'b0, st_ready};
    end
  end

endmodule
