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

  // ===========================================================================
  // The arbiter: the data memory unit first, then instruction fetch.
  // ===========================================================================
  logic        d_valid, d_ready, d_write, d_rsp, d_done, d_err;
  logic [31:0] d_addr, d_wdata;
  logic  [1:0] d_siz;
  logic  [2:0] d_tm;
  logic        f_valid, f_ready, f_rsp, f_done, f_err;
  logic [31:0] f_addr;
  logic  [2:0] f_tm;

  wire pick_d = d_valid;
  assign req_valid = d_valid || f_valid;
  assign req_addr  = pick_d ? d_addr : f_addr;
  assign req_write = pick_d && d_write;
  assign req_siz   = pick_d ? d_siz : rd68041_pkg::SIZ_LONG;
  assign req_tt    = rd68041_pkg::TT_NORMAL;
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
  logic [31:0] w_npc;                         // the next instruction's address
  logic  [4:0] w_ccr;                         // the CCR it leaves

  // ===========================================================================
  // Instruction fetch and decode
  // ===========================================================================
  logic [127:0] q_win;
  logic   [3:0] q_cnt, q_pop;
  logic  [31:0] q_pc;
  logic         go;
  logic  [31:0] go_pc;
  logic         redirect;
  logic  [31:0] redirect_pc;

  rd68041_ifu u_ifu (
      .clk(clk), .rst_n(rst_n), .crst(crst),
      .go(go), .go_pc(go_pc), .stop(halted), .sup(1'b1),
      .q_win(q_win), .q_cnt(q_cnt), .q_pc(q_pc), .q_pop(q_pop),
      .f_valid(f_valid), .f_ready(f_ready), .f_addr(f_addr), .f_tm(f_tm),
      .f_rsp(f_rsp), .f_data(rsp_data), .f_done(f_done), .f_err(f_err));

  logic        step;                          // decoding an instruction's second
  logic [15:0] de_op;
  logic [31:0] de_pc;
  logic        de_halted;                     // a halt has been issued

  logic [rd68041_pkg::UOP_W-1:0] dec_v;
  logic [2:0]  dec_need, dec_pop;
  logic        dec_more;

  rd68041_decode u_dec (
      .op   (step ? de_op : q_win[127:112]),
      .w    (step ? q_win[127:16] : q_win[111:0]),
      .step (step),
      .pc   (step ? de_pc : q_pc),
      .uop  (dec_v),
      .need (dec_need),
      .pop  (dec_pop),
      .more (dec_more));

  rd68041_pkg::uop_t dec_u;
  assign dec_u = dec_v;

  wire de_avail = step ? (q_cnt >= {1'b0, dec_pop})
                       : (q_cnt != 4'd0) && (q_cnt >= 4'd1 + {1'b0, dec_need});

  logic ea_stall, of_stall, ex_stall, w_stall;
  wire  running  = (rs == R_RUN) && !halted;
  wire  de_issue = running && de_avail && !de_halted && !ea_stall && !redirect;
  assign q_pop = de_issue ? (step ? {1'b0, dec_pop} : 4'd1 + {1'b0, dec_pop}) : 4'd0;

  // ===========================================================================
  // The register file
  // ===========================================================================
  logic [4:0]  ra, rb, rc, rd;
  logic [31:0] qa, qb, qc, qd;
  logic        we0, we1;
  logic [4:0]  wa0, wa1;
  logic [31:0] wd0, wd1;
  logic [3:0]  wm0;

  rd68041_regfile u_rf (
      .clk(clk), .rst_n(rst_n),
      .ra(ra), .rb(rb), .rc(rc), .rd(rd),
      .qa(qa), .qb(qb), .qc(qc), .qd(qd),
      .we0(we0), .wa0(wa0), .wd0(wd0), .wm0(wm0),
      .we1(we1), .wa1(wa1), .wd1(wd1));

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
  wire [4:0] base_r  = {2'b01, ea_u.ea_an};
  wire [4:0] index_r = {1'b0, ea_u.ea_xn};
  wire need_base  = ea_u.valid && ea_u.ea_en && (ea_u.ea_base == rd68041_pkg::B_AN);
  wire need_index = ea_u.valid && ea_u.ea_en && ea_u.ea_xen;

  // A result an older micro-operation has not computed yet.
  function automatic logic pending(input rd68041_pkg::uop_t u, input logic [4:0] r);
    pending = u.valid && u.wr && (u.wr_reg == r);
  endfunction
  function automatic logic upd_of(input rd68041_pkg::uop_t u, input logic [4:0] r);
    upd_of = u.valid && (u.ea_upd != rd68041_pkg::U_NONE) && ({2'b01, u.ea_an} == r);
  endfunction

  // The value of r as <ea> calculate must see it.
  function automatic logic [31:0] ea_val(input logic [4:0] r, input logic [31:0] rf,
                                         input rd68041_pkg::uop_t o, input logic [31:0] o_an,
                                         input rd68041_pkg::uop_t x, input logic [31:0] x_an,
                                         input rd68041_pkg::uop_t w, input logic [31:0] w_a,
                                         input logic [31:0] w_r);
    if (upd_of(o, r))                         ea_val = o_an;
    else if (upd_of(x, r))                    ea_val = x_an;
    else if (w.valid && w.wr && w.wr_reg == r) ea_val = merge(rf[31:8], w_r, w.wr_sz);
    else if (upd_of(w, r))                    ea_val = w_a;
    else                                      ea_val = rf;
  endfunction

  assign ra = base_r;
  assign rb = index_r;

  wire ea_wait = (need_base  && (pending(of_u, base_r)  || pending(ex_u, base_r))) ||
                 (need_index && (pending(of_u, index_r) || pending(ex_u, index_r)));

  wire [31:0] base_v  = ea_val(base_r,  qa, of_u, of_an, ex_u, ex_an, w_u, w_an, w_res);
  wire [31:0] index_v = ea_val(index_r, qb, of_u, of_an, ex_u, ex_an, w_u, w_an, w_res);

  logic [31:0] agu_base, agu_disp, agu_ea;
  always_comb begin
    case (ea_u.ea_base)
      rd68041_pkg::B_AN: agu_base = base_v;
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

  function automatic logic [31:0] ex_reg(input logic [4:0] r, input logic [31:0] rf,
                                         input rd68041_pkg::uop_t w, input logic [31:0] w_a,
                                         input logic [31:0] w_r);
    if (w.valid && w.wr && w.wr_reg == r) ex_reg = merge(rf[31:8], w_r, w.wr_sz);
    else if (upd_of(w, r))                ex_reg = w_a;
    else                                  ex_reg = rf;
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

  wire [31:0] a_raw = pick(ex_u.a_sel, ex_reg(ex_u.a_reg, qc, w_u, w_an, w_res), ex_u.imm, ex_md, ex_ea);
  wire [31:0] b_raw = pick(ex_u.b_sel, ex_reg(ex_u.b_reg, qd, w_u, w_an, w_res), ex_u.imm, ex_md, ex_ea);
  wire [31:0] av = ex_u.a_sxw ? {{16{a_raw[15]}}, a_raw[15:0]} : a_raw;
  wire [31:0] bv = ex_u.b_sxw ? {{16{b_raw[15]}}, b_raw[15:0]} : b_raw;

  // The operation, and the condition codes at the operation's size (PRM 3.4).
  logic [31:0] res;
  logic  [4:0] ccr_n;                       // X N Z V C
  always_comb begin
    logic [32:0] s;
    logic [31:0] m;
    logic        an, bn, rn, cy, vf;
    logic  [4:0] msb;
    m   = (ex_u.sz == rd68041_pkg::SZ_B) ? 32'h0000_00FF :
          (ex_u.sz == rd68041_pkg::SZ_W) ? 32'h0000_FFFF : 32'hFFFF_FFFF;
    msb = (ex_u.sz == rd68041_pkg::SZ_B) ? 5'd7 : (ex_u.sz == rd68041_pkg::SZ_W) ? 5'd15 : 5'd31;
    s   = 33'h0;
    case (ex_u.op)
      rd68041_pkg::OP_ADD, rd68041_pkg::OP_ADDA: s = {1'b0, bv} + {1'b0, av};
      rd68041_pkg::OP_SUB, rd68041_pkg::OP_SUBA,
      rd68041_pkg::OP_CMP:                       s = {1'b0, bv} - {1'b0, av};
      default: ;
    endcase
    case (ex_u.op)
      rd68041_pkg::OP_PASSB: res = bv;
      rd68041_pkg::OP_PASSA: res = av;
      rd68041_pkg::OP_ADD, rd68041_pkg::OP_ADDA,
      rd68041_pkg::OP_SUB, rd68041_pkg::OP_SUBA,
      rd68041_pkg::OP_CMP:   res = s[31:0];
      rd68041_pkg::OP_AND:   res = bv & av;
      rd68041_pkg::OP_OR:    res = bv | av;
      rd68041_pkg::OP_EOR:   res = bv ^ av;
      rd68041_pkg::OP_EXTW:  res = {bv[31:16], {8{bv[7]}}, bv[7:0]};
      rd68041_pkg::OP_EXTL:  res = {{16{bv[15]}}, bv[15:0]};
      rd68041_pkg::OP_EXTBL: res = {{24{bv[7]}}, bv[7:0]};
      rd68041_pkg::OP_SWAP:  res = {bv[15:0], bv[31:16]};
      rd68041_pkg::OP_CLR:   res = 32'h0;
      default:               res = bv;
    endcase
    an = av[msb];
    bn = bv[msb];
    rn = res[msb];
    // The carry or borrow out of the operation's size.
    case (ex_u.sz)
      rd68041_pkg::SZ_B: cy = (ex_u.op == rd68041_pkg::OP_ADD) ? (({1'b0, bv[7:0]} + {1'b0, av[7:0]}) > 9'h0FF)
                                                               : (bv[7:0] < av[7:0]);
      rd68041_pkg::SZ_W: cy = (ex_u.op == rd68041_pkg::OP_ADD) ? (({1'b0, bv[15:0]} + {1'b0, av[15:0]}) > 17'h0FFFF)
                                                               : (bv[15:0] < av[15:0]);
      default:           cy = s[32];
    endcase
    vf = (ex_u.op == rd68041_pkg::OP_ADD) ? ((an == bn) && (rn != bn))
                                          : ((an != bn) && (rn != bn));
    ccr_n = ccr_x;
    case (ex_u.cc)
      rd68041_pkg::CC_LOGIC: ccr_n = {ccr_x[4], rn, (res & m) == 32'h0, 1'b0, 1'b0};
      rd68041_pkg::CC_ADD,
      rd68041_pkg::CC_SUB:   ccr_n = {cy, rn, (res & m) == 32'h0, vf, cy};
      rd68041_pkg::CC_CMP:   ccr_n = {ccr_x[4], rn, (res & m) == 32'h0, vf, cy};
      rd68041_pkg::CC_SET: begin
        case (ex_u.cond)
          4'd0:    ccr_n = ccr_x & av[4:0];
          4'd1:    ccr_n = ccr_x | av[4:0];
          default: ccr_n = ccr_x ^ av[4:0];
        endcase
      end
      default: ;
    endcase
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

  wire ex_taken = ex_u.valid && (ex_u.br != rd68041_pkg::BR_NONE) &&
                  ((ex_u.br != rd68041_pkg::BR_DISP) || cond_true(ex_u.cond, ccr_x[3:0]));
  wire [31:0] ex_target = (ex_u.br == rd68041_pkg::BR_DISP) ? ex_u.tgt :
                          (ex_u.br == rd68041_pkg::BR_MEM)  ? ex_md : bv;
  wire [31:0] ex_npc    = ex_taken ? ex_target : ex_u.pc + {27'h0, ex_u.len};

  assign ex_stall    = w_stall;
  assign redirect    = ex_taken && !ex_stall && running;
  assign redirect_pc = ex_target;

  // ===========================================================================
  // Write-back
  // ===========================================================================
  // A halt stays in write-back, and the pipeline behind it with it.
  assign w_stall = w_u.valid && (w_u.halt || (w_u.st && !st_ready));
  wire   w_go    = w_u.valid && !w_stall && running && !w_u.halt;

  assign we0 = (w_go && w_u.wr) || (rs == R_SSP && ld_done);
  assign wa0 = (rs == R_SSP) ? 5'd15 : w_u.wr_reg;
  assign wd0 = (rs == R_SSP) ? ld_data : w_res;
  assign wm0 = (rs == R_SSP) ? 4'hF : lanes_of(w_u.wr_sz);
  // The address register update, unless the result goes to the same register
  // (MOVEA (An)+,An: the operand read wins, PRM 4).
  assign we1 = w_go && (w_u.ea_upd != rd68041_pkg::U_NONE) &&
               !(w_u.wr && w_u.wr_reg == {2'b01, w_u.ea_an});
  assign wa1 = {2'b01, w_u.ea_an};
  assign wd1 = w_an;

  rd68041_dmu u_dmu (
      .clk(clk), .rst_n(rst_n), .crst(crst), .sup(1'b1),
      .ld_valid(ld_valid), .ld_addr(ld_addr), .ld_sz(ld_sz),
      .ld_done(ld_done), .ld_data(ld_data), .ld_err(ld_err), .ld_cancel(ld_cancel),
      .st_valid(w_u.valid && w_u.st && running && !w_u.halt), .st_addr(w_ea),
      .st_sz(w_u.sz), .st_data(w_res), .st_ready(st_ready), .st_empty(st_empty),
      .d_valid(d_valid), .d_ready(d_ready), .d_addr(d_addr), .d_write(d_write),
      .d_siz(d_siz), .d_tm(d_tm), .d_wdata(d_wdata), .d_rsp(d_rsp),
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
      step      <= 1'b0;
      de_op     <= '0;
      de_pc     <= '0;
      de_halted <= 1'b0;
      ea_u      <= '0;
      of_u      <= '0;
      ex_u      <= '0;
      w_u       <= '0;
      of_ea     <= '0; ex_ea <= '0; w_ea <= '0;
      of_an     <= '0; ex_an <= '0; w_an <= '0;
      of_md     <= '0; of_got <= 1'b0; ex_md <= '0;
      w_res     <= '0; w_npc <= '0; w_ccr <= '0;
      reset_v   <= '0;
    end else if (crst) begin
      rs        <= R_SSP;
      halted    <= 1'b0;
      step      <= 1'b0;
      de_halted <= 1'b0;
      ea_u      <= '0;
      of_u      <= '0;
      ex_u      <= '0;
      w_u       <= '0;
      of_got    <= 1'b0;
    end else begin
      // --- reset ------------------------------------------------------------
      if (rs == R_SSP && ld_done) rs <= R_PC;
      if (rs == R_PC  && ld_done) begin rs <= R_RUN; reset_v <= ld_data; end

      // --- write-back -------------------------------------------------------
      if (w_u.valid && w_u.halt && running) halted <= 1'b1;
      if (w_go) begin
        if (w_u.last || w_u.cc != rd68041_pkg::CC_NONE) ccr_w <= w_ccr;
      end
      if (!w_stall) w_u <= '0;

      // --- execute -> write-back --------------------------------------------
      if (!ex_stall) begin
        w_u   <= ex_u;
        w_ea  <= ex_ea;
        w_an  <= ex_an;
        w_res <= res;
        w_npc <= ex_npc;
        w_ccr <= ccr_n;
        if (ex_u.valid) ccr_x <= ccr_n;
        ex_u  <= '0;
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
          step  <= 1'b1;
          de_op <= q_win[127:112];
          de_pc <= q_pc;
        end else begin
          step <= 1'b0;
        end
        if (dec_u.halt) de_halted <= 1'b1;
      end

      // --- a taken branch: everything younger goes ----------------------------
      if (redirect) begin
        ex_u      <= '0;
        ea_u      <= '0;
        of_u      <= '0;
        of_got    <= 1'b0;
        step      <= 1'b0;
        de_halted <= 1'b0;
      end
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, ld_err, st_empty, reset_v};

endmodule
