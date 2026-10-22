// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- SystemVerilog MC68040
//
// The integer unit: decode, <ea> calculate, <ea> fetch, execute and write-back
// (UM 2.1; doc/microarch.md), with instruction fetch (rd68041_ifu) and the data
// memory unit (rd68041_dmu) beside it, and the arbiter that puts both on the bus
// unit's one request port.
//
// One micro-operation per stage, in order. A stage holds while the one after it
// does. The hazards and how each is met:
//
//   <ea> calculate needs an address or index register:
//     - an update an older micro-operation made here ((An)+, -(An)) is taken
//       from that one's OF, EX or W register, newest first;
//     - a result an older one will compute in EX is waited for until it is in W,
//       and taken from there; then the register file.
//   execute reads its operands from the register file, and from W for the one
//     micro-operation ahead of it, which is all that can be in flight.
//   <ea> fetch reads through the data memory unit, which waits for any queued
//     write to the same long word (UM 7.7).
//   a taken branch, resolved in EX, empties decode, <ea> calculate and <ea>
//     fetch -- cancelling a read already on the bus -- and restarts fetching.
//
// The condition codes exist twice: as EX has made them (for the next branch)
// and as write-back has committed them (the architectural ones, which an
// exception, M8, puts back into EX's).
//
// M6: no exceptions, no caches, no MMU, supervisor mode throughout, SR's system
// byte as reset leaves it. A micro-operation marked halt stops everything when
// it reaches write-back (`halted`).

module rd68041_core (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          crst,

    // The bus unit's request port (doc/bus.md).
    output logic          req_valid,
    input  logic          req_ready,
    output logic [31:0]   req_addr,
    output logic          req_write,
    output logic  [1:0]   req_siz,
    output logic  [1:0]   req_tt,
    output logic  [2:0]   req_tm,
    output logic          req_lock,
    output logic          req_locke,
    output logic          lock_seq,
    output logic [127:0]  req_wdata,
    input  logic          rsp_valid,
    input  logic [31:0]   rsp_data,
    input  logic          rsp_done,
    input  logic          rsp_err,

    // For testbenches and, later, PST.
    output logic          retire,       // an instruction completed this clock
    output logic [31:0]   retire_pc,    // its address
    output logic [31:0]   retire_npc,   // the next instruction's
    output logic          halted,
    output logic [15:0]   sr
);

  // ===========================================================================
  // State
  // ===========================================================================
  localparam logic [7:0] SR_SYS = 8'h27;     // UM 8.2.10: S set, I = 7, T clear

  logic [4:0] ccr_x, ccr_w;                  // EX's and the committed CCR
  assign sr = {SR_SYS, 3'b000, ccr_w};

  // The control registers (UM 2.2.2, 3.1, 4.2), written at write-back. M7 holds
  // the MMU's as plain registers for MOVEC; M10 gives them meaning. With M = 0
  // the interrupt stack pointer is A7 (register 15), and the master stack
  // pointer is held here (M8 swaps them).
  logic  [2:0] sfc, dfc;
  logic [31:0] cacr, tc, itt0, itt1, dtt0, dtt1, usp, vbr, msp, mmusr, urp, srp;

  // ===========================================================================
  // The arbiter: the data memory unit first, then instruction fetch.
  // ===========================================================================
  logic        d_valid, d_ready, d_write, d_rsp, d_done, d_err;
  logic [31:0] d_addr, d_wdata;
  logic  [1:0] d_siz, d_tt;
  logic  [2:0] d_tm;
  logic        d_lock, d_locke, lock_open;
  logic        f_valid, f_ready, f_rsp, f_done, f_err;
  logic [31:0] f_addr;
  logic  [2:0] f_tm;

  wire pick_d = d_valid;
  assign req_valid = d_valid || f_valid;
  assign req_addr  = pick_d ? d_addr : f_addr;
  assign req_write = pick_d && d_write;
  assign req_siz   = pick_d ? d_siz : rd68041_pkg::SIZ_LONG;
  assign req_tt    = pick_d ? d_tt : rd68041_pkg::TT_NORMAL;
  assign req_lock  = pick_d && d_lock;
  assign req_locke = pick_d && d_locke;
  assign lock_seq  = lock_open;
  assign req_tm    = pick_d ? d_tm : f_tm;
  assign req_wdata = {96'h0, d_wdata};
  assign d_ready   = pick_d && req_ready;
  assign f_ready   = !pick_d && req_ready;

  // Whose transfer is on the bus, and whose the responses are: those are
  // registered on the edge after the event, which may also be the edge the next
  // transfer is taken on, so they go to whoever owned the bus before that edge.
  logic own_d, rsp_own_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      own_d     <= 1'b0;
      rsp_own_d <= 1'b0;
    end else begin
      if (req_valid && req_ready) own_d <= pick_d;
      rsp_own_d <= own_d;
    end
  end
  assign d_rsp  = rsp_valid &&  rsp_own_d;
  assign d_done = rsp_done  &&  rsp_own_d;
  assign d_err  = rsp_err   &&  rsp_own_d;
  assign f_rsp  = rsp_valid && !rsp_own_d;
  assign f_done = rsp_done  && !rsp_own_d;
  assign f_err  = rsp_err   && !rsp_own_d;

  // ===========================================================================
  // Reset (UM 8.2.10): the interrupt stack pointer from 0, the PC from 4.
  // ===========================================================================
  typedef enum logic [1:0] { R_SSP, R_PC, R_RUN, R_HALT } rs_e;
  rs_e rs;

  // ===========================================================================
  // Pipeline registers
  // ===========================================================================
  rd68041_pkg::uop_t ea_u, of_u, ex_u, w_u;
  logic [31:0] of_ea, ex_ea, w_ea;            // the effective address
  logic [31:0] of_an, ex_an, w_an;            // the address register's update
  logic [31:0] of_md;                         // the operand read
  logic        of_got;                        // ... is in of_md
  logic [31:0] ex_md;
  logic [31:0] w_res;                         // the result
  logic [31:0] w_res2;                        // the second result
  logic [31:0] w_std;                         // the store's data
  logic        w_nowr;                        // EX cancelled the register results
  logic        w_nost;                        // ... and the store
  logic        w_trap;                        // EX took a conditional trap (M8)
  logic        div_go, div_done;              // the divider was started; it has answered
  logic [31:0] w_npc;                         // the next instruction's address
  logic  [4:0] w_ccr;                         // the CCR it leaves

  // ===========================================================================
  // Instruction fetch and decode
  // ===========================================================================
  logic [191:0] q_win;
  logic   [3:0] q_cnt, q_pop;
  logic  [31:0] q_pc;
  logic         go;
  logic  [31:0] go_pc;
  logic         redirect;
  logic  [31:0] redirect_pc;

  rd68041_ifu u_ifu (
      .clk(clk), .rst_n(rst_n), .crst(crst),
      .go(go), .go_pc(go_pc), .stop(halted || lock_open), .sup(1'b1),
      .q_win(q_win), .q_cnt(q_cnt), .q_pc(q_pc), .q_pop(q_pop),
      .f_valid(f_valid), .f_ready(f_ready), .f_addr(f_addr), .f_tm(f_tm),
      .f_rsp(f_rsp), .f_data(rsp_data), .f_done(f_done), .f_err(f_err));

  logic  [4:0] seq;                           // micro-operations issued of this instruction
  logic  [1:0] de_ind, dec_ind;               // the indirection preludes it has
  logic  [4:0] de_len;                        // its length
  wire         step = (seq != 5'd0);
  logic [15:0] de_op;
  logic [31:0] de_pc;
  logic        de_halted;                     // a halt has been issued

  logic [rd68041_pkg::UOP_W-1:0] dec_v;
  logic [3:0]  dec_need, dec_pop;
  logic        dec_more;

  // MOVEM's register list (PRM 4): the mask from its first extension word, then
  // what is left of it. The next register is its lowest set bit -- which for
  // -(An), whose mask is reversed, is A7 first and D0 last.
  logic [15:0] mv_mask, mv_src, mv_bit;
  logic  [4:0] mv_k;
  logic  [3:0] mv_reg;
  logic        mv_last, mv_used;
  wire  [15:0] cur_op = step ? de_op : q_win[191:176];
  assign mv_src = step ? mv_mask : q_win[175:160];
  always_comb begin
    mv_bit = 16'h0;
    mv_reg = 4'd0;
    for (int b = 15; b >= 0; b--) begin
      if (mv_src[b]) begin
        mv_bit = 16'h1 << b;
        mv_reg = (cur_op[5:3] == 3'd4) ? 4'(15 - b) : 4'(b);
      end
    end
  end
  assign mv_last = (mv_src & (mv_src - 16'h1)) == 16'h0;

  rd68041_decode u_dec (
      .op      (cur_op),
      .w       (step ? q_win[191:16] : q_win[175:0]),
      .seq     (seq),
      .ind_in  (de_ind),
      .len_in  (de_len),
      .pc      (step ? de_pc : q_pc),
      .mv_reg  (mv_reg),
      .mv_last (mv_last),
      .mv_k    (mv_k),
      .uop     (dec_v),
      .need    (dec_need),
      .pop     (dec_pop),
      .more    (dec_more),
      .mv_used (mv_used),
      .ind_out (dec_ind));

  rd68041_pkg::uop_t dec_u;
  assign dec_u = dec_v;

  wire de_avail = step ? (q_cnt >= dec_pop)
                       : (q_cnt != 4'd0) && ({1'b0, q_cnt} >= 5'd1 + {1'b0, dec_need});

  logic ea_stall, of_stall, ex_stall, w_stall;
  wire  running  = (rs == R_RUN) && !halted;
  wire  de_issue = running && de_avail && !de_halted && !ea_stall && !redirect;
  assign q_pop = de_issue ? (step ? dec_pop : 4'd1 + dec_pop) : 4'd0;

  // ===========================================================================
  // The register file
  // ===========================================================================
  logic [4:0]  ra, rb, rc, rd, re;
  logic [31:0] qa, qb, qc, qd, qe;
  logic        we0, we1, we2;
  logic [4:0]  wa0, wa1, wa2;
  logic [31:0] wd0, wd1, wd2;
  logic [3:0]  wm0;

  rd68041_regfile u_rf (
      .clk(clk), .rst_n(rst_n),
      .ra(ra), .rb(rb), .rc(rc), .rd(rd), .re(re),
      .qa(qa), .qb(qb), .qc(qc), .qd(qd), .qe(qe),
      .we0(we0), .wa0(wa0), .wd0(wd0), .wm0(wm0),
      .we1(we1), .wa1(wa1), .wd1(wd1),
      .we2(we2), .wa2(wa2), .wd2(wd2));

  function automatic logic [3:0] lanes_of(input logic [1:0] sz);
    lanes_of = (sz == rd68041_pkg::SZ_B) ? 4'b0001 :
               (sz == rd68041_pkg::SZ_W) ? 4'b0011 : 4'b1111;
  endfunction
  // A register as a byte or word write leaves it: only the low bytes change.
  function automatic logic [31:0] merge(input logic [31:8] old, input logic [31:0] nw,
                                        input logic [1:0] sz);
    case (sz)
      rd68041_pkg::SZ_B: merge = {old[31:8], nw[7:0]};
      rd68041_pkg::SZ_W: merge = {old[31:16], nw[15:0]};
      default:           merge = nw;
    endcase
  endfunction

  // W's own writes, as a forwarding source: the result, else the update.
  function automatic logic w_has(input rd68041_pkg::uop_t u, input logic [4:0] r);
    w_has = u.valid && ((u.wr && u.wr_reg == r) ||
                        (u.ea_upd != rd68041_pkg::U_NONE && {2'b01, u.ea_an} == r));
  endfunction

  // ===========================================================================
  // <ea> calculate
  // ===========================================================================
  wire [4:0] base_r  = (ea_u.ea_base == rd68041_pkg::B_REG) ? ea_u.ea_reg : {2'b01, ea_u.ea_an};
  wire [4:0] index_r = {1'b0, ea_u.ea_xn};
  wire need_base  = ea_u.valid && ea_u.ea_en &&
                    (ea_u.ea_base == rd68041_pkg::B_AN || ea_u.ea_base == rd68041_pkg::B_REG);
  wire need_index = ea_u.valid && ea_u.ea_en && ea_u.ea_xen;

  // A result an older micro-operation has not computed yet.
  function automatic logic pending(input rd68041_pkg::uop_t u, input logic [4:0] r);
    pending = u.valid && ((u.wr && (u.wr_reg == r)) || (u.wr2 && (u.wr2_reg == r)) ||
                          (u.crw && u.cr == rd68041_pkg::CR_ISP && r == 5'd15));
  endfunction
  function automatic logic upd_of(input rd68041_pkg::uop_t u, input logic [4:0] r);
    upd_of = u.valid && (u.ea_upd != rd68041_pkg::U_NONE) && ({2'b01, u.ea_an} == r);
  endfunction

  // The value of r as <ea> calculate must see it.
  function automatic logic [31:0] ea_val(input logic [4:0] r, input logic [31:0] rf,
                                         input rd68041_pkg::uop_t o, input logic [31:0] o_an,
                                         input rd68041_pkg::uop_t x, input logic [31:0] x_an,
                                         input rd68041_pkg::uop_t w, input logic w_ok,
                                         input logic [31:0] w_a,
                                         input logic [31:0] w_r, input logic [31:0] w_r2);
    if (upd_of(o, r))                                     ea_val = o_an;
    else if (upd_of(x, r))                                ea_val = x_an;
    else if (w.valid && w.wr && w_ok && w.wr_reg == r)    ea_val = merge(rf[31:8], w_r, w.wr_sz);
    else if (w.valid && w.wr2 && w_ok && w.wr2_reg == r)  ea_val = w_r2;
    else if (upd_of(w, r))                                ea_val = w_a;
    else                                                  ea_val = rf;
  endfunction

  assign ra = base_r;
  assign rb = index_r;

  wire ea_wait = (need_base  && (pending(of_u, base_r)  || pending(ex_u, base_r))) ||
                 (need_index && (pending(of_u, index_r) || pending(ex_u, index_r)));

  wire [31:0] base_v  = ea_val(base_r,  qa, of_u, of_an, ex_u, ex_an, w_u, !w_nowr, w_an, w_res, w_res2);
  wire [31:0] index_v = ea_val(index_r, qb, of_u, of_an, ex_u, ex_an, w_u, !w_nowr, w_an, w_res, w_res2);

  logic [31:0] agu_base, agu_disp, agu_ea;
  always_comb begin
    case (ea_u.ea_base)
      rd68041_pkg::B_AN,
      rd68041_pkg::B_REG: agu_base = base_v;
      rd68041_pkg::B_PC: agu_base = ea_u.pc;
      default:           agu_base = 32'h0;
    endcase
    agu_disp = (ea_u.ea_upd == rd68041_pkg::U_PRE) ? -{29'h0, ea_u.ea_step} : ea_u.ea_disp;
  end

  rd68041_agu u_agu (.base(agu_base), .index(ea_u.ea_xen ? index_v : 32'h0),
                     .index_w(!ea_u.ea_xl), .scale(ea_u.ea_scale), .disp(agu_disp),
                     .ea(agu_ea));

  // (An)+ leaves An + step; -(An) the address itself.
  wire [31:0] ea_an_new = (ea_u.ea_upd == rd68041_pkg::U_POST) ? base_v + {29'h0, ea_u.ea_step}
                                                               : agu_ea;

  assign ea_stall = of_stall || ea_wait;

  // ===========================================================================
  // <ea> fetch
  // ===========================================================================
  logic        ld_done, ld_err, st_ready, st_empty, ld_cancel;
  logic [31:0] ld_data;
  logic        ld_valid;
  logic [31:0] ld_addr;
  logic  [1:0] ld_sz;
  logic [31:0] reset_v;

  // A read waits for any older write it overlaps that is not in the data
  // memory unit's queue yet -- one in EX or in W; the unit checks its queue
  // itself (UM 7.7).
  function automatic logic [2:0] nb(input logic [1:0] sz);
    nb = (sz == rd68041_pkg::SZ_B) ? 3'd1 : (sz == rd68041_pkg::SZ_W) ? 3'd2 : 3'd4;
  endfunction
  function automatic logic touches(input logic [31:0] a0, input logic [1:0] s0,
                                   input logic [31:0] a1, input logic [1:0] s1);
    logic [31:2] e0, e1;
    e0 = a0[31:2] + {29'h0, ({1'b0, a0[1:0]} + nb(s0)) > 3'd4};
    e1 = a1[31:2] + {29'h0, ({1'b0, a1[1:0]} + nb(s1)) > 3'd4};
    touches = !((e0 < a1[31:2]) || (e1 < a0[31:2]));
  endfunction
  wire st_ahead = (ex_u.valid && ex_u.st && touches(of_ea, of_u.sz, ex_ea, ex_u.sz)) ||
                  (w_u.valid  && w_u.st  && touches(of_ea, of_u.sz, w_ea,  w_u.sz));

  wire of_wants = of_u.valid && of_u.ld && !of_got && running && !st_ahead;
  assign ld_valid = (rs == R_SSP || rs == R_PC) || of_wants;
  assign ld_addr  = (rs == R_SSP) ? 32'h0 : (rs == R_PC) ? 32'h4 : of_ea;
  assign ld_sz    = (rs == R_RUN) ? of_u.sz : rd68041_pkg::SZ_L;

  wire of_ready = !of_u.ld || of_got || ld_done;
  assign of_stall = ex_stall || (of_u.valid && !of_ready);

  // ===========================================================================
  // Execute
  // ===========================================================================
  assign rc = ex_u.a_reg;
  assign rd = ex_u.b_reg;
  assign re = ex_u.wr2_reg;                  // the high half of a 64-bit dividend

  function automatic logic [31:0] ex_reg(input logic [4:0] r, input logic [31:0] rf,
                                         input rd68041_pkg::uop_t w, input logic w_ok,
                                         input logic [31:0] w_a,
                                         input logic [31:0] w_r, input logic [31:0] w_r2);
    if (w.valid && w.wr && w_ok && w.wr_reg == r)        ex_reg = merge(rf[31:8], w_r, w.wr_sz);
    else if (w.valid && w.wr2 && w_ok && w.wr2_reg == r) ex_reg = w_r2;
    else if (upd_of(w, r))                        ex_reg = w_a;
    else                                          ex_reg = rf;
  endfunction

  function automatic logic [31:0] pick(input logic [1:0] sel, input logic [31:0] rv,
                                       input logic [31:0] imm, input logic [31:0] md,
                                       input logic [31:0] ea);
    case (sel)
      rd68041_pkg::S_REG: pick = rv;
      rd68041_pkg::S_IMM: pick = imm;
      rd68041_pkg::S_MEM: pick = md;
      default:            pick = ea;
    endcase
  endfunction

  // A control register as EX reads it: W's write to it first.
  function automatic logic [31:0] cr_val(input logic [3:0] c, input rd68041_pkg::uop_t w,
                                         input logic [31:0] w_r, input logic [31:0] cur);
    if (w.valid && w.crw && w.cr == c) cr_val = w_r;
    else                               cr_val = cur;
  endfunction

  logic [31:0] cr_cur;
  always_comb begin
    case (ex_u.cr)
      rd68041_pkg::CR_SFC:   cr_cur = {29'h0, sfc};
      rd68041_pkg::CR_DFC:   cr_cur = {29'h0, dfc};
      rd68041_pkg::CR_CACR:  cr_cur = cacr;
      rd68041_pkg::CR_TC:    cr_cur = tc;
      rd68041_pkg::CR_ITT0:  cr_cur = itt0;
      rd68041_pkg::CR_ITT1:  cr_cur = itt1;
      rd68041_pkg::CR_DTT0:  cr_cur = dtt0;
      rd68041_pkg::CR_DTT1:  cr_cur = dtt1;
      rd68041_pkg::CR_USP:   cr_cur = usp;
      rd68041_pkg::CR_VBR:   cr_cur = vbr;
      rd68041_pkg::CR_MSP:   cr_cur = msp;
      rd68041_pkg::CR_MMUSR: cr_cur = mmusr;
      rd68041_pkg::CR_URP:   cr_cur = urp;
      rd68041_pkg::CR_SRP:   cr_cur = srp;
      default:               cr_cur = {16'h0, SR_SYS, 3'b000, ccr_x};
    endcase
  end

  wire [31:0] b_reg_v = ex_reg(ex_u.b_reg, qd, w_u, !w_nowr, w_an, w_res, w_res2);
  wire [31:0] a_raw = pick(ex_u.a_sel, ex_reg(ex_u.a_reg, qc, w_u, !w_nowr, w_an, w_res, w_res2),
                           ex_u.imm, ex_md, ex_ea);
  wire [31:0] b_raw = ex_u.crr ? cr_val(ex_u.cr, w_u, w_res, cr_cur)
                               : pick(ex_u.b_sel, b_reg_v, ex_u.imm, ex_md, ex_ea);
  wire [31:0] c_v   = ex_reg(ex_u.wr2_reg, qe, w_u, !w_nowr, w_an, w_res, w_res2);
  wire [31:0] av = ex_u.a_sxw ? {{16{a_raw[15]}}, a_raw[15:0]} : a_raw;
  wire [31:0] bv = ex_u.b_sxw ? {{16{b_raw[15]}}, b_raw[15:0]} : b_raw;

  // --- the shifter (fn: {left, kind}) ---------------------------------------
  logic [31:0] sh_res;
  logic        sh_c, sh_v, sh_x, sh_xw;
  rd68041_shifter u_shift (
      .op(bv), .count(av[5:0]), .size(ex_u.sz), .kind(ex_u.fn[1:0]), .left(ex_u.fn[2]),
      .x_in(ccr_x[4]), .res(sh_res), .c_out(sh_c), .v_out(sh_v), .x_out(sh_x),
      .x_write(sh_xw));

  // --- the bit-field unit (OP_BF) -----------------------------------------------
  // C holds the parameters OP_BFPRM made -- width in 18-13, offset 12-8 -- and
  // for memory the fifth byte in 7-0; B the register or the first four bytes.
  logic [31:0] bf_field, bf_sx, bf_ins, bf_mreg;
  logic [39:0] bf_mmem;
  logic        bf_msb, bf_zero;
  logic  [5:0] bf_ffo;
  always_comb begin
    case (ex_u.fn[2:0])
      3'd2:    bf_ins = ~bf_field;                     // BFCHG
      3'd4:    bf_ins = 32'h0;                         // BFCLR
      3'd6:    bf_ins = 32'hFFFF_FFFF;                 // BFSET
      default: bf_ins = av;                            // BFINS
    endcase
  end
  rd68041_bitfield u_bf (
      .is_reg(ex_u.fn[3]), .reg_data(bv), .mem_data({bv, c_v[7:0]}),
      .roff(c_v[12:8]), .boff(c_v[10:8]), .width(c_v[18:13]), .ins(bf_ins),
      .field(bf_field), .sxfield(bf_sx), .msb(bf_msb), .zero(bf_zero), .ffo(bf_ffo),
      .merged_reg(bf_mreg), .merged_mem(bf_mmem));

  // --- the multiplier (fn: {64-bit, long, signed}) ------------------------------
  // 32 x 32 to 64, signed or not, the word forms on sign- or zero-extended
  // halves (PRM 4, MULS and MULU).
  logic [63:0] prod;
  always_comb begin
    logic [63:0] pa, pb;
    if (ex_u.fn[1]) begin
      pa = ex_u.fn[0] ? {{32{av[31]}}, av} : {32'h0, av};
      pb = ex_u.fn[0] ? {{32{bv[31]}}, bv} : {32'h0, bv};
    end else begin
      pa = ex_u.fn[0] ? {{48{av[15]}}, av[15:0]} : {48'h0, av[15:0]};
      pb = ex_u.fn[0] ? {{48{bv[15]}}, bv[15:0]} : {48'h0, bv[15:0]};
    end
    prod = pa * pb;
  end

  // --- the divider (fn: {64-bit dividend, long, signed}) --------------------------
  // B the dividend (Dq), A the divisor, c_v the dividend's high half (Dr).
  logic        div_start, div_busy, div_zero, div_ovf, div_qneg;
  logic [31:0] div_q, div_r, div_qmag;
  logic [63:0] div_n;
  logic [31:0] div_d;
  always_comb begin
    if (ex_u.fn[2])      div_n = {c_v, bv};
    else if (ex_u.fn[0]) div_n = {{32{bv[31]}}, bv};
    else                 div_n = {32'h0, bv};
    if (ex_u.fn[1])      div_d = av;
    else                 div_d = ex_u.fn[0] ? {{16{av[15]}}, av[15:0]} : {16'h0, av[15:0]};
  end
  rd68041_divider u_div (
      .clk(clk), .rst_n(rst_n), .start(div_start), .dividend(div_n), .divisor(div_d),
      .is_signed(ex_u.fn[0]), .busy(div_busy), .quotient(div_q), .remainder(div_r),
      .div_zero(div_zero), .overflow(div_ovf), .q_mag(div_qmag), .q_neg(div_qneg));

  wire ex_is_div = ex_u.valid && (ex_u.op == rd68041_pkg::OP_DIV);
  assign div_start = ex_is_div && !div_go && running;
  // div_go: started; div_done: the answer is there (the clock after busy falls).
  wire div_wait = ex_is_div && !(div_go && !div_busy && div_done);

  // The quotient's fit (PRM 4): sixteen bits for the word forms, thirty-two
  // signed or unsigned for the long.
  wire div_fits = ex_u.fn[1] ? !div_ovf
                             : (ex_u.fn[0] ? (div_qneg ? (div_qmag <= 32'h8000) : (div_qmag <= 32'h7FFF))
                                           : (div_qmag <= 32'hFFFF)) && !div_ovf;

  // --- the operation, and the condition codes at its size (PRM 3.4) ------------
  logic [31:0] res, res2, st_val;              // the result, the second, the store's data
  logic  [4:0] ccr_n;                       // X N Z V C
  logic        ex_nowr;                     // the register results are not written
  logic        ex_nost;                     // nor the store (CAS2's conditional ones)
  logic        ex_trap;                     // a conditional trap is taken
  logic        bcd_c, cmp2_out;
  always_comb begin
    logic [32:0] s;
    logic [31:0] m, p, q;
    logic        cin, sub, an, bn, rn, cy, vf, xop, z;
    logic  [4:0] msb;
    logic  [4:0] bitn;
    m   = (ex_u.sz == rd68041_pkg::SZ_B) ? 32'h0000_00FF :
          (ex_u.sz == rd68041_pkg::SZ_W) ? 32'h0000_FFFF : 32'hFFFF_FFFF;
    msb = (ex_u.sz == rd68041_pkg::SZ_B) ? 5'd7 : (ex_u.sz == rd68041_pkg::SZ_W) ? 5'd15 : 5'd31;

    // The adder: p + q + cin, or p - q - cin.
    p = bv; q = av; cin = 1'b0; sub = 1'b0; xop = 1'b0;
    case (ex_u.op)
      rd68041_pkg::OP_SUB, rd68041_pkg::OP_SUBA, rd68041_pkg::OP_CMP,
      rd68041_pkg::OP_CAS: sub = 1'b1;
      rd68041_pkg::OP_ADDX: begin cin = ccr_x[4]; xop = 1'b1; end
      rd68041_pkg::OP_SUBX: begin cin = ccr_x[4]; sub = 1'b1; xop = 1'b1; end
      rd68041_pkg::OP_NEG:  begin p = 32'h0; q = bv; sub = 1'b1; end
      rd68041_pkg::OP_NEGX: begin p = 32'h0; q = bv; sub = 1'b1; cin = ccr_x[4]; xop = 1'b1; end
      default: ;
    endcase
    s = sub ? ({1'b0, p} - {1'b0, q} - {32'h0, cin}) : ({1'b0, p} + {1'b0, q} + {32'h0, cin});

    res   = bv;
    res2  = 32'h0;
    ex_nowr = 1'b0;
    ex_nost = 1'b0;
    ex_trap = 1'b0;
    bcd_c   = 1'b0;
    cmp2_out = 1'b0;
    bitn  = ex_u.sz == rd68041_pkg::SZ_L ? av[4:0] : {2'b00, av[2:0]};
    case (ex_u.op)
      rd68041_pkg::OP_PASSB: res = bv;
      rd68041_pkg::OP_PASSA: res = av;
      rd68041_pkg::OP_ADD, rd68041_pkg::OP_ADDA, rd68041_pkg::OP_SUB, rd68041_pkg::OP_SUBA,
      rd68041_pkg::OP_CMP, rd68041_pkg::OP_ADDX, rd68041_pkg::OP_SUBX,
      rd68041_pkg::OP_NEG, rd68041_pkg::OP_NEGX: res = s[31:0];
      rd68041_pkg::OP_AND:   res = bv & av;
      rd68041_pkg::OP_OR:    res = bv | av;
      rd68041_pkg::OP_EOR:   res = bv ^ av;
      rd68041_pkg::OP_NOT:   res = ~bv;
      rd68041_pkg::OP_EXTW:  res = {bv[31:16], {8{bv[7]}}, bv[7:0]};
      rd68041_pkg::OP_EXTL:  res = {{16{bv[15]}}, bv[15:0]};
      rd68041_pkg::OP_EXTBL: res = {{24{bv[7]}}, bv[7:0]};
      rd68041_pkg::OP_SWAP:  res = {bv[15:0], bv[31:16]};
      rd68041_pkg::OP_CLR:   res = 32'h0;
      rd68041_pkg::OP_SHIFT: res = sh_res;
      rd68041_pkg::OP_SCC:   res = cond_true(ex_u.cond, ccr_x[3:0]) ? 32'hFF : 32'h00;
      rd68041_pkg::OP_DBCC: begin
        res = {bv[31:16], bv[15:0] - 16'd1};
        ex_nowr = cond_true(ex_u.cond, ccr_x[3:0]);
      end
      rd68041_pkg::OP_BIT: begin
        case (ex_u.fn[1:0])
          2'd1:    res = bv ^  (32'h1 << bitn);
          2'd2:    res = bv & ~(32'h1 << bitn);
          2'd3:    res = bv |  (32'h1 << bitn);
          default: res = bv;
        endcase
      end
      rd68041_pkg::OP_MUL: begin
        res  = prod[31:0];
        res2 = prod[63:32];
      end
      rd68041_pkg::OP_DIV: begin
        // The word forms: the remainder in the high word, the quotient low.
        res     = ex_u.fn[1] ? div_q : {div_r[15:0], div_q[15:0]};
        res2    = div_r;
        ex_nowr = !div_fits;
        // PRM 4: division by zero traps (M8).
        ex_trap = div_zero;
      end
      rd68041_pkg::OP_EXG: begin
        res  = av;
        res2 = bv;
      end
      rd68041_pkg::OP_LINK: begin
        res  = ex_ea;
        res2 = ex_ea + ex_u.imm;
      end
      rd68041_pkg::OP_BCD: begin
        // PRM 4, ABCD, SBCD, NBCD: decimal, with X; the carry is decimal.
        logic [8:0] lo, v9;
        logic [7:0] dd, ss;
        dd = (ex_u.fn[1:0] == 2'd2) ? 8'h00 : bv[7:0];
        ss = (ex_u.fn[1:0] == 2'd2) ? bv[7:0] : av[7:0];
        if (ex_u.fn[1:0] == 2'd0) begin
          lo = {5'h0, dd[3:0]} + {5'h0, ss[3:0]} + {8'h0, ccr_x[4]};
          v9 = {1'b0, dd[7:4], 4'h0} + {1'b0, ss[7:4], 4'h0} + lo;
          if (lo > 9'd9) v9 = v9 + 9'd6;
          bcd_c = (v9 > 9'h099);
          if (bcd_c) v9 = v9 + 9'h060;
        end else begin
          lo = {5'h0, dd[3:0]} - {5'h0, ss[3:0]} - {8'h0, ccr_x[4]};
          v9 = {1'b0, dd[7:4], 4'h0} - {1'b0, ss[7:4], 4'h0} + lo;
          if (lo[8]) v9 = v9 - 9'd6;
          bcd_c = v9[8];
          if (bcd_c) v9 = v9 - 9'h060;
        end
        res = {bv[31:8], v9[7:0]};
      end
      rd68041_pkg::OP_PACK: begin
        // PRM 4: the word plus the adjustment, bits 11-8 and 3-0 packed.
        logic [15:0] t;
        t   = (ex_u.fn[0] ? {bv[7:0], av[7:0]} : bv[15:0]) + ex_u.imm[15:0];
        res = {24'h0, t[11:8], t[3:0]};
      end
      rd68041_pkg::OP_UNPK: begin
        logic [15:0] t;
        t   = {4'h0, bv[7:4], 4'h0, bv[3:0]} + ex_u.imm[15:0];
        res = {16'h0, t};
      end
      rd68041_pkg::OP_CAS: begin
        // Dc loaded with the operand unless they compared equal; the operand
        // written back with Du if equal, or with itself (UM 7.4.5).
        res     = bv;
        ex_nowr = ((bv & m) == (av & m));
      end
      rd68041_pkg::OP_TAS: res = bv | 32'h80;
      rd68041_pkg::OP_BFPRM: begin
        // The offset from Dn is signed and whole; from the extension word,
        // 0 to 31. A width of 0 is 32 (PRM 4).
        logic [31:0] off;
        logic  [4:0] w5;
        off  = ex_u.fn[1] ? av : {27'h0, av[4:0]};
        w5   = ex_u.fn[0] ? bv[4:0] : bv[12:8];
        res  = {13'h0, (w5 == 5'd0) ? 6'd32 : {1'b0, w5}, off[4:0], 8'h00};
        res2 = ex_ea + {{3{off[31]}}, off[31:3]};
      end
      rd68041_pkg::OP_BFPK: res = {av[31:8], bv[7:0]};
      rd68041_pkg::OP_BF: begin
        case (ex_u.fn[2:0])
          3'd1:    res = bf_field;                     // BFEXTU
          3'd3:    res = bf_sx;                        // BFEXTS
          3'd5:    res = av + {26'h0, bf_ffo};          // BFFFO: the offset plus
          default: begin
            res  = ex_u.fn[3] ? bf_mreg : bf_mmem[39:8];
            res2 = {24'h0, bf_mmem[7:0]};
          end
        endcase
      end
      rd68041_pkg::OP_CMP2: res = bv;
      rd68041_pkg::OP_MOVEP: begin
        // fn[3]: out of B's byte fn[1:0]; else A's byte into it.
        if (ex_u.fn[3]) res = (bv >> {ex_u.fn[1:0], 3'b000}) & 32'hFF;
        else            res = (bv & ~(32'hFF << {ex_u.fn[1:0], 3'b000})) |
                              ({24'h0, av[7:0]} << {ex_u.fn[1:0], 3'b000});
      end
      default: res = bv;
    endcase
    // The store's data is the result, but for LINK, which stores the register,
    // and CAS, which stores Du if equal.
    st_val = (ex_u.op == rd68041_pkg::OP_LINK) ? av :
             (ex_u.op == rd68041_pkg::OP_CAS)  ? (((bv & m) == (av & m)) ? c_v : bv) : res;
    // UNLK and RTD: the stack pointer past the frame (decode's imm).
    if (ex_u.op == rd68041_pkg::OP_PASSB && ex_u.wr2) res2 = ex_ea + ex_u.imm;

    an = av[msb];
    bn = bv[msb];
    // CAS's flags are its compare's: the difference, not the result.
    rn = (ex_u.op == rd68041_pkg::OP_CAS) ? s[{1'b0, msb}] : res[msb];
    if (ex_u.op == rd68041_pkg::OP_NEG || ex_u.op == rd68041_pkg::OP_NEGX) begin
      an = bv[msb]; bn = 1'b0;
    end
    // The carry or borrow out of the operation's size.
    case (ex_u.sz)
      rd68041_pkg::SZ_B: cy = sub ? ({1'b0, p[7:0]}  < ({1'b0, q[7:0]} + {8'h0, cin}))
                                  : (({1'b0, p[7:0]}  + {1'b0, q[7:0]}  + {8'h0, cin}) > 9'h0FF);
      rd68041_pkg::SZ_W: cy = sub ? ({1'b0, p[15:0]} < ({1'b0, q[15:0]} + {16'h0, cin}))
                                  : (({1'b0, p[15:0]} + {1'b0, q[15:0]} + {16'h0, cin}) > 17'h0FFFF);
      default:           cy = s[32];
    endcase
    vf = sub ? ((an != bn) && (rn != bn)) : ((an == bn) && (rn != bn));
    z  = (res & m) == 32'h0;

    ccr_n = ccr_x;
    case (ex_u.cc)
      rd68041_pkg::CC_LOGIC: ccr_n = {ccr_x[4], rn, z, 1'b0, 1'b0};
      rd68041_pkg::CC_ADD,
      rd68041_pkg::CC_SUB:   ccr_n = {cy, rn, xop ? (z && ccr_x[2]) : z, vf, cy};
      rd68041_pkg::CC_CMP:   ccr_n = {ccr_x[4], rn, z, vf, cy};
      rd68041_pkg::CC_SET: begin
        case (ex_u.cond)
          4'd0:    ccr_n = ccr_x & av[4:0];
          4'd1:    ccr_n = ccr_x | av[4:0];
          4'd2:    ccr_n = ccr_x ^ av[4:0];
          default: ccr_n = av[4:0];                 // MOVE to CCR, RTR
        endcase
      end
      default: ;
    endcase
    // The operations whose condition codes follow rules of their own.
    case (ex_u.op)
      rd68041_pkg::OP_SHIFT: ccr_n = {sh_xw ? sh_x : ccr_x[4], rn, z, sh_v, sh_c};
      rd68041_pkg::OP_BIT:   ccr_n = {ccr_x[4:3], !bv[bitn], ccr_x[1:0]};
      // PRM 4: X and C the decimal carry, Z cleared if not zero; N and V are
      // undefined, and are left as they were, as UAE040 leaves them
      // (doc/divergences.md).
      rd68041_pkg::OP_BCD:   ccr_n = {bcd_c, ccr_x[3], ccr_x[2] && (res[7:0] == 8'h00), ccr_x[1], bcd_c};
      rd68041_pkg::OP_TAS:   ccr_n = {ccr_x[4], bv[7], bv[7:0] == 8'h00, 1'b0, 1'b0};
      // PRM 4: N the field's top bit, Z the field all zero, V and C cleared;
      // for BFINS, of the field inserted.
      rd68041_pkg::OP_BF: begin
        if (ex_u.fn[2:0] == 3'd7) begin
          logic [31:0] lm;
          lm = (c_v[18:13] == 6'd32) ? 32'hFFFF_FFFF : ((32'h1 << c_v[18:13]) - 32'h1);
          ccr_n = {ccr_x[4], av[c_v[17:13] - 5'd1], (av & lm) == 32'h0, 1'b0, 1'b0};
        end else begin
          ccr_n = {ccr_x[4], bf_msb, bf_zero, 1'b0, 1'b0};
        end
      end
      // CAS: the compare's, of the operand less Dc.
      rd68041_pkg::OP_CAS:   ccr_n = {ccr_x[4], rn, (s[31:0] & m) == 32'h0, vf, cy};
      rd68041_pkg::OP_CMP2: begin
        // Out of bounds when (Rn - lower) > (upper - lower), modulo the size:
        // right for signed and for unsigned bounds alike (PRM 4). An address
        // register is compared whole, the bounds sign-extended.
        logic [31:0] rv, lb, ub;
        logic        wide;
        wide = ex_u.wr2_reg[3] || (ex_u.sz == rd68041_pkg::SZ_L);
        case (ex_u.sz)
          rd68041_pkg::SZ_B: begin
            lb = wide ? {{24{av[7]}}, av[7:0]} : {24'h0, av[7:0]};
            ub = wide ? {{24{bv[7]}}, bv[7:0]} : {24'h0, bv[7:0]};
            rv = wide ? c_v : {24'h0, c_v[7:0]};
          end
          rd68041_pkg::SZ_W: begin
            lb = wide ? {{16{av[15]}}, av[15:0]} : {16'h0, av[15:0]};
            ub = wide ? {{16{bv[15]}}, bv[15:0]} : {16'h0, bv[15:0]};
            rv = wide ? c_v : {16'h0, c_v[15:0]};
          end
          default: begin lb = av; ub = bv; rv = c_v; end
        endcase
        if (wide) cmp2_out = (rv - lb) > (ub - lb);
        else if (ex_u.sz == rd68041_pkg::SZ_B) cmp2_out = (8'(rv - lb)) > (8'(ub - lb));
        else cmp2_out = (16'(rv - lb)) > (16'(ub - lb));
        ccr_n = {ccr_x[4], ccr_x[3], (rv == lb) || (rv == ub), ccr_x[1], cmp2_out};
      end
      rd68041_pkg::OP_MUL: begin
        // PRM 4: N and Z of the whole result; V set when a 32-bit result has
        // lost bits; C cleared.
        if (ex_u.fn[2])
          ccr_n = {ccr_x[4], prod[63], prod == 64'h0, 1'b0, 1'b0};
        else if (ex_u.fn[1])
          ccr_n = {ccr_x[4], prod[31], prod[31:0] == 32'h0,
                   ex_u.fn[0] ? (prod[63:32] != {32{prod[31]}}) : (prod[63:32] != 32'h0), 1'b0};
        else
          ccr_n = {ccr_x[4], prod[31], prod[31:0] == 32'h0, 1'b0, 1'b0};
      end
      rd68041_pkg::OP_DIV: begin
        if (!div_fits)
          ccr_n = {ccr_x[4], ccr_x[3], ccr_x[2], 1'b1, 1'b0};
        else if (ex_u.fn[1])
          ccr_n = {ccr_x[4], div_q[31], div_q == 32'h0, 1'b0, 1'b0};
        else
          ccr_n = {ccr_x[4], div_q[15], div_q[15:0] == 16'h0, 1'b0, 1'b0};
      end
      default: ;
    endcase
    // Traps (M8 takes the exception; until then they halt): TRAPcc and TRAPV on
    // their condition, CHK when the register is out of bounds (PRM 4: "if Dn <
    // 0 or Dn > source", N set for the first and cleared for the second).
    if (ex_u.trap) begin
      if (ex_u.op == rd68041_pkg::OP_CMP2) begin
        ex_trap = cmp2_out;
      end else if (ex_u.op == rd68041_pkg::OP_CMP) begin
        logic lt0, gtb;
        lt0 = bv[msb];
        gtb = !lt0 && ((ex_u.sz == rd68041_pkg::SZ_W) ? ($signed(bv[15:0]) > $signed(av[15:0]))
                                                       : ($signed(bv) > $signed(av)));
        ex_trap = lt0 || gtb;
        ccr_n = {ccr_x[4], lt0 ? 1'b1 : (gtb ? 1'b0 : ccr_x[3]), ccr_x[2:0]};
      end else begin
        ex_trap = cond_true(ex_u.cond, ccr_x[3:0]);
      end
    end
    // A micro-operation only if its condition holds (CAS2): otherwise it
    // writes nothing, stores nothing and leaves the CCR.
    if (ex_u.cx && !cond_true(ex_u.cond, ccr_x[3:0])) begin
      ex_nowr = 1'b1;
      ex_nost = 1'b1;
      ccr_n   = ccr_x;
    end
  end

  // PRM Table 3-19: the conditions, on the CCR as the instructions before left it.
  function automatic logic cond_true(input logic [3:0] c, input logic [3:0] f);
    logic n, z, v, cf;
    n = f[3]; z = f[2]; v = f[1]; cf = f[0];
    case (c)
      4'h0: cond_true = 1'b1;
      4'h1: cond_true = 1'b0;
      4'h2: cond_true = !cf && !z;
      4'h3: cond_true = cf || z;
      4'h4: cond_true = !cf;
      4'h5: cond_true = cf;
      4'h6: cond_true = !z;
      4'h7: cond_true = z;
      4'h8: cond_true = !v;
      4'h9: cond_true = v;
      4'hA: cond_true = !n;
      4'hB: cond_true = n;
      4'hC: cond_true = (n == v);
      4'hD: cond_true = (n != v);
      4'hE: cond_true = !z && (n == v);
      default: cond_true = z || (n != v);
    endcase
  endfunction

  // DBcc branches unless the condition holds or the counter has run out.
  wire dbcc_take = (ex_u.op == rd68041_pkg::OP_DBCC) && !cond_true(ex_u.cond, ccr_x[3:0]) &&
                   (bv[15:0] != 16'h0000);
  wire ex_taken = ex_u.valid && !ex_u.halt && (ex_u.br != rd68041_pkg::BR_NONE) &&
                  ((ex_u.op == rd68041_pkg::OP_DBCC) ? dbcc_take :
                   ((ex_u.br != rd68041_pkg::BR_DISP) || cond_true(ex_u.cond, ccr_x[3:0])));
  wire [31:0] ex_target = (ex_u.br == rd68041_pkg::BR_DISP) ? ex_u.tgt :
                          (ex_u.br == rd68041_pkg::BR_MEM)  ? ex_md : bv;
  wire [31:0] ex_npc    = ex_taken ? ex_target : ex_u.pc + {27'h0, ex_u.len};

  assign ex_stall    = w_stall || div_wait;
  assign redirect    = ex_taken && !ex_stall && running;
  assign redirect_pc = ex_target;

  // ===========================================================================
  // Write-back
  // ===========================================================================
  // A halt stays in write-back, and the pipeline behind it with it; so does a
  // trap EX took, until M8 makes it an exception.
  wire   w_halts = w_u.halt || w_trap;
  wire   w_st    = w_u.valid && w_u.st && !w_nost;
  assign w_stall = w_u.valid && (w_halts || (w_st && !st_ready));
  wire   w_go    = w_u.valid && !w_stall && running && !w_halts;
  wire   w_wr    = w_go && !w_nowr;

  assign we0 = (w_wr && w_u.wr) || (rs == R_SSP && ld_done) ||
               (w_go && w_u.crw && w_u.cr == rd68041_pkg::CR_ISP);
  assign wa0 = (rs == R_SSP || (w_u.crw && w_u.cr == rd68041_pkg::CR_ISP)) ? 5'd15 : w_u.wr_reg;
  assign wd0 = (rs == R_SSP) ? ld_data : w_res;
  assign wm0 = (rs == R_SSP || w_u.crw) ? 4'hF : lanes_of(w_u.wr_sz);
  // The address register update; the register file lets a result or a second
  // result to the same register win over it.
  assign we1 = w_go && (w_u.ea_upd != rd68041_pkg::U_NONE);
  assign wa1 = {2'b01, w_u.ea_an};
  assign wd1 = w_an;
  assign we2 = w_wr && w_u.wr2;
  assign wa2 = w_u.wr2_reg;
  assign wd2 = w_res2;

  rd68041_dmu u_dmu (
      .clk(clk), .rst_n(rst_n), .crst(crst), .sup(1'b1), .sfc(sfc), .dfc(dfc),
      .ld_valid(ld_valid), .ld_addr(ld_addr), .ld_sz(ld_sz),
      .ld_done(ld_done), .ld_data(ld_data), .ld_err(ld_err), .ld_cancel(ld_cancel),
      .ld_lock(of_u.lk && rs == R_RUN), .ld_alt(of_u.alt && rs == R_RUN),
      .st_valid(w_st && running && !w_halts), .st_addr(w_ea),
      .st_sz(w_u.sz), .st_data(w_std), .st_lock(w_u.lk), .st_locke(w_u.lke),
      .st_alt(w_u.alt), .st_ready(st_ready), .st_empty(st_empty), .lock_open(lock_open),
      .d_valid(d_valid), .d_ready(d_ready), .d_addr(d_addr), .d_write(d_write),
      .d_siz(d_siz), .d_tt(d_tt), .d_tm(d_tm), .d_lock(d_lock), .d_locke(d_locke),
      .d_wdata(d_wdata), .d_rsp(d_rsp),
      .d_data(rsp_data), .d_done(d_done), .d_err(d_err));

  // A redirect kills <ea> fetch: its read, if one is on the bus, is cancelled.
  assign ld_cancel = redirect && of_u.valid && of_u.ld && !of_got;

  assign go    = (rs == R_PC && ld_done) || redirect;
  assign go_pc = (rs == R_PC) ? ld_data : redirect_pc;

  assign retire     = w_go && w_u.last;
  assign retire_pc  = w_u.pc;
  assign retire_npc = w_npc;

  // ===========================================================================
  // The pipeline's registers
  // ===========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rs        <= R_SSP;
      halted    <= 1'b0;
      ccr_x     <= 5'h00;
      ccr_w     <= 5'h00;
      sfc       <= 3'd0;
      dfc       <= 3'd0;
      cacr      <= '0; tc <= '0; itt0 <= '0; itt1 <= '0; dtt0 <= '0; dtt1 <= '0;
      usp       <= '0; vbr <= '0; msp <= '0; mmusr <= '0; urp <= '0; srp <= '0;
      seq       <= 5'd0;
      de_ind    <= 2'b00;
      de_len    <= 5'd0;
      de_op     <= '0;
      de_pc     <= '0;
      de_halted <= 1'b0;
      mv_mask   <= '0;
      mv_k      <= '0;
      ea_u      <= '0;
      of_u      <= '0;
      ex_u      <= '0;
      w_u       <= '0;
      of_ea     <= '0; ex_ea <= '0; w_ea <= '0;
      of_an     <= '0; ex_an <= '0; w_an <= '0;
      of_md     <= '0; of_got <= 1'b0; ex_md <= '0;
      w_res     <= '0; w_res2 <= '0; w_std <= '0; w_npc <= '0; w_ccr <= '0;
      w_nowr    <= 1'b0; w_nost <= 1'b0; w_trap <= 1'b0;
      div_go    <= 1'b0; div_done <= 1'b0;
      reset_v   <= '0;
    end else if (crst) begin
      // UM 8.2.10: the reset clears VBR and CACR, and TC's and the TTRs'
      // enables (UM 3.6.1).
      rs        <= R_SSP;
      halted    <= 1'b0;
      vbr       <= '0;
      cacr      <= '0;
      tc        <= '0;
      itt0      <= '0; itt1 <= '0; dtt0 <= '0; dtt1 <= '0;
      seq       <= 5'd0;
      de_halted <= 1'b0;
      ea_u      <= '0;
      of_u      <= '0;
      ex_u      <= '0;
      w_u       <= '0;
      w_trap    <= 1'b0;
      of_got    <= 1'b0;
      div_go    <= 1'b0;
      div_done  <= 1'b0;
    end else begin
      // --- reset ------------------------------------------------------------
      if (rs == R_SSP && ld_done) rs <= R_PC;
      if (rs == R_PC  && ld_done) begin rs <= R_RUN; reset_v <= ld_data; end

      // --- write-back -------------------------------------------------------
      if (w_u.valid && w_halts && running) halted <= 1'b1;
      if (w_go) begin
        ccr_w <= w_ccr;
        if (w_u.crw) begin
          case (w_u.cr)
            rd68041_pkg::CR_SFC:   sfc   <= w_res[2:0];
            rd68041_pkg::CR_DFC:   dfc   <= w_res[2:0];
            // UM 4.2: CACR has DE (31) and IE (15); the rest reads as zero.
            rd68041_pkg::CR_CACR:  cacr  <= w_res & 32'h8000_8000;
            rd68041_pkg::CR_TC:    tc    <= w_res & 32'h0000_C000;
            rd68041_pkg::CR_ITT0:  itt0  <= w_res & 32'hFFFF_E364;
            rd68041_pkg::CR_ITT1:  itt1  <= w_res & 32'hFFFF_E364;
            rd68041_pkg::CR_DTT0:  dtt0  <= w_res & 32'hFFFF_E364;
            rd68041_pkg::CR_DTT1:  dtt1  <= w_res & 32'hFFFF_E364;
            rd68041_pkg::CR_USP:   usp   <= w_res;
            rd68041_pkg::CR_VBR:   vbr   <= w_res;
            rd68041_pkg::CR_MSP:   msp   <= w_res;
            rd68041_pkg::CR_MMUSR: mmusr <= w_res;
            rd68041_pkg::CR_URP:   urp   <= w_res & 32'hFFFF_FE00;
            rd68041_pkg::CR_SRP:   srp   <= w_res & 32'hFFFF_FE00;
            default: ;
          endcase
        end
      end
      if (!w_stall) w_u <= '0;

      // --- the divider ------------------------------------------------------
      if (div_start) div_go <= 1'b1;
      if (div_go && !div_busy) div_done <= 1'b1;

      // --- execute -> write-back --------------------------------------------
      if (!ex_stall) begin
        w_u    <= ex_u;
        w_ea   <= ex_ea;
        w_an   <= ex_an;
        w_res  <= res;
        w_res2 <= res2;
        w_std  <= st_val;
        w_npc  <= ex_npc;
        w_ccr  <= ccr_n;
        w_nowr <= ex_nowr;
        w_nost <= ex_nost;
        w_trap <= ex_u.valid && ex_trap;
        if (ex_u.valid) ccr_x <= ccr_n;
        ex_u   <= '0;
        div_go   <= 1'b0;
        div_done <= 1'b0;
      end

      // --- <ea> fetch -> execute --------------------------------------------
      if (of_u.valid && of_u.ld && !of_got && ld_done) begin
        of_md  <= ld_data;
        of_got <= 1'b1;
      end
      if (!of_stall) begin
        ex_u   <= of_u;
        ex_ea  <= of_ea;
        ex_an  <= of_an;
        ex_md  <= (of_got) ? of_md : ld_data;
        of_u   <= '0;
        of_got <= 1'b0;
      end

      // --- <ea> calculate -> <ea> fetch -------------------------------------
      if (!ea_stall) begin
        of_u  <= ea_u;
        of_ea <= agu_ea;
        of_an <= ea_an_new;
        ea_u  <= '0;
      end

      // --- decode -> <ea> calculate ----------------------------------------
      if (de_issue) begin
        ea_u <= dec_u;
        if (dec_more) begin
          seq <= seq + 5'd1;
          if (!step) begin
            de_op  <= q_win[191:176];
            de_pc  <= q_pc;
            de_ind <= dec_ind;
            de_len <= dec_u.len;
          end
        end else begin
          seq <= 5'd0;
        end
        // MOVEM's registers: the mask, less each one transferred.
        if (!step) begin
          mv_mask <= mv_used ? (mv_src & ~mv_bit) : mv_src;
          mv_k    <= mv_used ? 5'd1 : 5'd0;
        end else if (mv_used) begin
          mv_mask <= mv_mask & ~mv_bit;
          mv_k    <= mv_k + 5'd1;
        end
        if (dec_u.halt) de_halted <= 1'b1;
      end

      // --- a taken branch: everything younger goes ----------------------------
      if (redirect) begin
        ex_u      <= '0;
        ea_u      <= '0;
        of_u      <= '0;
        of_got    <= 1'b0;
        seq       <= 5'd0;
        de_halted <= 1'b0;
      end
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, ld_err, st_empty, reset_v};

endmodule
