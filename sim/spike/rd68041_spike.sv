// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- the M4 frequency spike. NOT part of the design: a harness that puts
// the design's storage and adders (rd68041_atc, rd68041_cache_arr,
// rd68041_regfile, rd68041_agu, rd68041_shifter, rd68041_biu) in the
// arrangement doc/microarch.md gives the pipeline, with control that is only
// plausible, so that Vivado can say whether each stage fits in one clock.
//
// The paths it is built to expose, one per stage:
//
//   IF2  fetch address register -> instruction ATC and TTR compare -> tag
//        compare -> way select -> instruction queue
//   DE   queue head -> decoder ROM address (a block RAM)
//   EA   decoder ROM output -> register file read and forwarding -> address
//        adder -> data cache RAM address, and the EA register
//   OF   EA register -> data ATC and TTR -> tag compare -> way select -> align
//        and extend -> the execute stage's operand register
//   EX   forwarding -> ALU or shifter -> result, condition codes, branch
//        decision -> next fetch address -> instruction cache RAM address
//
// Everything reaches an output (through the caches' fills from the bus, the
// register file, and a checksum port), so synthesis cannot delete a stage.

module rd68041_spike (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        rsti_n_i,

    // The bus (doc/pinout.md), less the pins the spike does not exercise.
    input  logic [31:0] a_i,
    output logic [31:0] a_o,
    output logic        a_oe,
    input  logic [31:0] d_i,
    output logic [31:0] d_o,
    output logic        d_oe,
    input  logic  [1:0] tt_i,
    output logic  [1:0] tt_o,
    output logic  [2:0] tm_o,
    output logic  [1:0] siz_o,
    input  logic  [1:0] siz_i,
    output logic        rw_o,
    input  logic        rw_i,
    output logic        attr_oe,
    input  logic        ts_n_i,
    output logic        ts_n_o,
    output logic        tip_n_o,
    output logic        tip_oe,
    input  logic        ta_n_i,
    output logic        ta_n_o,
    output logic        ta_oe,
    input  logic        tea_n_i,
    input  logic        tci_n_i,
    input  logic        tbi_n_i,
    output logic        br_n_o,
    input  logic        bg_n_i,
    input  logic        bb_n_i,
    output logic        bb_n_o,
    output logic        bb_oe,
    input  logic  [1:0] sc_i,
    output logic        mi_n_o,
    output logic [31:0] sum_o
);

  logic crst, mm, md;
  logic [2:0] mi;
  rd68041_rstctl u_rst (.clk(clk), .rst_n(rst_n), .rsti_n_i(rsti_n_i),
      .cdis_n_i(1'b1), .mdis_n_i(1'b1), .ipl_n_i(3'b111), .crst(crst),
      .mode_mux(mm), .mode_dle(md), .mode_ipl(mi));

  // ===========================================================================
  // Control registers the stages read (stand-ins for TC, ITTx/DTTx, CACR)
  // ===========================================================================
  logic        page8k, mmu_en, s_mode;
  logic [31:0] miss_a;        // the address a miss goes to the bus with
  logic [31:0] itt0, dtt0;

  // ===========================================================================
  // IF1 / IF2
  // ===========================================================================
  logic [31:0] fpc;           // the fetch address register (IF2's)
  logic [31:0] fpc_d;         // IF1: the next one
  logic        redirect;      // EX: a taken branch
  logic [31:0] redirect_pc;

  logic        i_hit;
  logic [31:12] i_pa;
  logic [1:0]  i_u, i_cm;
  logic        i_sp, i_m, i_w, i_r;
  logic        i_tt;
  logic        ifill_we;
  logic [31:12] ifill_la, ifill_pa;

  rd68041_atc u_iatc (
      .clk(clk), .rst_n(rst_n), .crst(crst), .page8k(page8k),
      .lk_la(fpc[31:12]), .lk_s(s_mode), .lk_count(1'b1),
      .lk_hit(i_hit), .lk_pa(i_pa), .lk_u(i_u), .lk_sprot(i_sp), .lk_cm(i_cm),
      .lk_m(i_m), .lk_w(i_w), .lk_r(i_r),
      .fill_we(ifill_we), .fill_la(ifill_la), .fill_s(s_mode), .fill_g(1'b0),
      .fill_pa(ifill_pa), .fill_u(2'b00), .fill_sprot(1'b0), .fill_cm(2'b01),
      .fill_m(1'b0), .fill_w(1'b0), .fill_r(1'b1),
      .fl_all(1'b0), .fl_page(1'b0), .fl_nonglobal(1'b0));

  // UM 3.4: a TTR matches on the eight high-order bits under its mask.
  function automatic logic tt_match(input logic [31:0] tt, input logic [31:24] la, input logic s);
    tt_match = tt[15] && (((la ^ tt[31:24]) & ~tt[23:16]) == 8'h00) &&
               (tt[14] || (tt[13] == s));
  endfunction
  assign i_tt = tt_match(itt0, fpc[31:24], s_mode);

  // The physical tag: the TTR's identity, the ATC's page, or the MMU off.
  wire [31:12] i_ppage = (!mmu_en || i_tt) ? fpc[31:12] : i_pa;

  logic        ic_hit;
  logic [1:0]  ic_way;
  logic [3:0]  ic_dirty, ic_valid;
  logic [255:0] ic_a, ic_b;
  logic        ic_twe;
  logic [5:0]  ic_tset;
  logic [1:0]  ic_tway;
  logic [6:0]  ic_baddr;
  logic [7:0]  ic_bwe;
  logic [63:0] ic_bwd;

  rd68041_cache_arr #(.DIRTY(1'b0)) u_icache (
      .clk(clk), .rst_n(rst_n), .crst(crst),
      .p0_set(fpc[9:4]), .p0_ptag({i_ppage, fpc[11:10]}), .p0_hit(ic_hit),
      .p0_way(ic_way), .p0_dirty(ic_dirty), .p0_valid(ic_valid),
      .p1_set(6'd0), .p1_ptag(22'd0), .p1_hit(), .p1_way(), .p1_dirty(),
      .p2_set(6'd0), .p2_way(2'd0), .p2_tag(), .p2_valid(), .p2_dirty(),
      .t_we(ic_twe), .t_set(ic_tset), .t_way(ic_tway), .t_tag({ifill_pa, miss_a[11:10]}),
      .t_valid(1'b1), .d_we(1'b0), .d_set(6'd0), .d_way(2'd0), .d_bits(4'd0),
      .inv_all(1'b0),
      .a_addr(fpc_d[9:3]), .a_rdata(ic_a),
      .b_addr(ic_baddr), .b_way(ic_tway), .b_we(ic_bwe), .b_wdata(ic_bwd),
      .b_rdata(ic_b));

  // The way's half-line.
  logic [63:0] ihalf;
  always_comb begin
    case (ic_way)
      2'd0: ihalf = ic_a[63:0];
      2'd1: ihalf = ic_a[127:64];
      2'd2: ihalf = ic_a[191:128];
      default: ihalf = ic_a[255:192];
    endcase
  end

  // The instruction queue: four words, refilled a half-line at a time.
  logic [15:0] q [0:3];
  logic        q_ok;
  wire  fetch_ok = ic_hit && (i_hit || i_tt || !mmu_en);

  // IF1: sequential, or EX's branch target (the long path into the RAM address).
  assign fpc_d = redirect ? redirect_pc : (fetch_ok ? fpc + 32'd8 : fpc);

  // ===========================================================================
  // DE: the decoder ROM, a block RAM read at the operation word
  // ===========================================================================
  logic [63:0] dec_rom [0:1023];
  logic [63:0] dec_q;
  always_ff @(posedge clk) begin
    if (!rst_n) dec_q <= '0;
    else        dec_q <= dec_rom[q[0][15:6]];
  end
  // The ROM's contents are written by the bus (the spike has no generator),
  // so that synthesis cannot treat it as constant.
  logic        rom_we;
  logic [9:0]  rom_wa;
  logic [63:0] rom_wd;
  always_ff @(posedge clk) if (rom_we) dec_rom[rom_wa] <= rom_wd;

  logic [15:0] de_ext;        // the first extension word, beside the ROM word
  logic [15:0] de_op;

  // ===========================================================================
  // EA: register file, forwarding, the adder
  // ===========================================================================
  logic [31:0] rf_a, rf_b, rf_c, rf_d;
  logic        w_we;
  logic [3:0]  w_reg;
  logic [31:0] w_val;
  logic        x_we;
  logic [3:0]  x_reg;
  logic [31:0] x_val;

  wire [3:0] ea_base_r  = {1'b1, de_op[2:0]};
  wire [3:0] ea_index_r = de_ext[15:12];

  rd68041_regfile u_rf (
      .clk(clk), .rst_n(rst_n),
      .ra(ea_base_r), .rb(ea_index_r), .rc(dec_q[3:0]), .rd(dec_q[7:4]),
      .qa(rf_a), .qb(rf_b), .qc(rf_c), .qd(rf_d),
      .we0(w_we), .wa0(w_reg), .wd0(w_val), .wm0(4'hF),
      .we1(1'b0), .wa1(4'd0), .wd1(32'd0));

  // W -> EA forwarding only (doc/plan.md: an E -> EA dependency costs a bubble).
  wire [31:0] ea_base  = (w_we && w_reg == ea_base_r)  ? w_val : rf_a;
  wire [31:0] ea_index = (w_we && w_reg == ea_index_r) ? w_val : rf_b;
  wire [31:0] ea_disp  = dec_q[8] ? {{24{de_ext[7]}}, de_ext[7:0]}
                                  : {{16{de_ext[15]}}, de_ext};
  logic [31:0] ea_sum;
  rd68041_agu u_agu (.base(ea_base), .index(ea_index), .index_w(!de_ext[11]),
                     .scale(de_ext[10:9]), .disp(ea_disp), .ea(ea_sum));

  logic [31:0] ea_q;          // OF's address
  logic [1:0]  ea_siz_q;
  logic        ea_sext_q;

  // ===========================================================================
  // OF: the data ATC, the data cache, the aligner
  // ===========================================================================
  logic        d_hit;
  logic [31:12] d_pa;
  logic [1:0]  d_u, d_cm;
  logic        d_sp, d_m, d_w, d_r, d_tt;
  logic        dfill_we;
  logic [31:12] dfill_la, dfill_pa;

  rd68041_atc u_datc (
      .clk(clk), .rst_n(rst_n), .crst(crst), .page8k(page8k),
      .lk_la(ea_q[31:12]), .lk_s(s_mode), .lk_count(1'b1),
      .lk_hit(d_hit), .lk_pa(d_pa), .lk_u(d_u), .lk_sprot(d_sp), .lk_cm(d_cm),
      .lk_m(d_m), .lk_w(d_w), .lk_r(d_r),
      .fill_we(dfill_we), .fill_la(dfill_la), .fill_s(s_mode), .fill_g(1'b0),
      .fill_pa(dfill_pa), .fill_u(2'b00), .fill_sprot(1'b0), .fill_cm(2'b01),
      .fill_m(1'b1), .fill_w(1'b0), .fill_r(1'b1),
      .fl_all(1'b0), .fl_page(1'b0), .fl_nonglobal(1'b0));
  assign d_tt = tt_match(dtt0, ea_q[31:24], s_mode);
  wire [31:12] d_ppage = (!mmu_en || d_tt) ? ea_q[31:12] : d_pa;

  logic        dc_hit;
  logic [1:0]  dc_way;
  logic [3:0]  dc_dirty, dc_valid;
  logic [255:0] dc_a, dc_b;
  logic        dc_twe;
  logic [5:0]  dc_tset;
  logic [1:0]  dc_tway;
  logic [6:0]  dc_baddr;
  logic [7:0]  dc_bwe;
  logic [63:0] dc_bwd;
  logic        sn_hit;
  logic [1:0]  sn_way;
  logic [3:0]  sn_dirty;
  logic [31:0] sn_addr;

  rd68041_cache_arr #(.DIRTY(1'b1)) u_dcache (
      .clk(clk), .rst_n(rst_n), .crst(crst),
      .p0_set(ea_q[9:4]), .p0_ptag({d_ppage, ea_q[11:10]}), .p0_hit(dc_hit),
      .p0_way(dc_way), .p0_dirty(dc_dirty), .p0_valid(dc_valid),
      .p1_set(sn_addr[9:4]), .p1_ptag(sn_addr[31:10]), .p1_hit(sn_hit),
      .p1_way(sn_way), .p1_dirty(sn_dirty),
      .p2_set(6'd0), .p2_way(2'd0), .p2_tag(), .p2_valid(), .p2_dirty(),
      .t_we(dc_twe), .t_set(dc_tset), .t_way(dc_tway), .t_tag({dfill_pa, miss_a[11:10]}),
      .t_valid(1'b1), .d_we(dc_twe), .d_set(dc_tset), .d_way(dc_tway), .d_bits(4'h1),
      .inv_all(1'b0),
      .a_addr(ea_sum[9:3]), .a_rdata(dc_a),
      .b_addr(dc_baddr), .b_way(dc_tway), .b_we(dc_bwe), .b_wdata(dc_bwd),
      .b_rdata(dc_b));

  logic [63:0] dhalf;
  always_comb begin
    case (dc_way)
      2'd0: dhalf = dc_a[63:0];
      2'd1: dhalf = dc_a[127:64];
      2'd2: dhalf = dc_a[191:128];
      default: dhalf = dc_a[255:192];
    endcase
  end

  // The aligner: the operand's bytes from the half-line, by A2-A0 and size,
  // then sign or zero extended (an operand inside the half-line; one that
  // crosses it takes a second access, UM 4.4.3).
  logic [31:0] opnd;
  always_comb begin
    logic [63:0] sh;
    sh = dhalf << (8 * ea_q[2:0]);
    case (ea_siz_q)
      2'd1:    opnd = ea_sext_q ? {{24{sh[63]}}, sh[63:56]} : {24'h0, sh[63:56]};
      2'd2:    opnd = ea_sext_q ? {{16{sh[63]}}, sh[63:48]} : {16'h0, sh[63:48]};
      default: opnd = sh[63:32];
    endcase
  end
  wire of_ok = dc_hit && (d_hit || d_tt || !mmu_en);

  // ===========================================================================
  // EX: forwarding, ALU, shifter, conditions, the branch
  // ===========================================================================
  logic [31:0] ex_a, ex_b;
  logic [3:0]  ex_op;
  logic [3:0]  ex_dst;
  logic [3:0]  ex_ra, ex_rb;
  logic [31:0] ex_disp;
  logic [31:0] ex_pc;

  wire [31:0] fa = (x_we && x_reg == ex_ra) ? x_val : (w_we && w_reg == ex_ra) ? w_val : ex_a;
  wire [31:0] fb = (x_we && x_reg == ex_rb) ? x_val : (w_we && w_reg == ex_rb) ? w_val : ex_b;

  logic [31:0] sh_res;
  logic        sh_c, sh_v, sh_x, sh_xw;
  rd68041_shifter u_sh (.op(fa), .count(fb[5:0]), .size(ex_op[1:0]), .kind(ex_op[3:2]),
                        .left(fb[6]), .x_in(1'b0), .res(sh_res), .c_out(sh_c),
                        .v_out(sh_v), .x_out(sh_x), .x_write(sh_xw));

  logic [32:0] alu;
  always_comb begin
    case (ex_op)
      4'd0:  alu = {1'b0, fa} + {1'b0, fb};
      4'd1:  alu = {1'b0, fa} - {1'b0, fb};
      4'd2:  alu = {1'b0, fa & fb};
      4'd3:  alu = {1'b0, fa | fb};
      4'd4:  alu = {1'b0, fa ^ fb};
      4'd5:  alu = {sh_c, sh_res};
      default: alu = {1'b0, fb};
    endcase
  end
  wire        z = (alu[31:0] == 32'h0);
  wire        n = alu[31];
  // A Bcc in EX: the condition on the flags just made, the target from the PC.
  wire        taken = ex_op[3] && (ex_dst[0] ? z : n);
  assign redirect    = taken;
  assign redirect_pc = ex_pc + ex_disp;

  // ===========================================================================
  // The pipeline registers, and bus-fed fills so nothing is constant
  // ===========================================================================
  logic         req_valid, req_ready, rsp_valid, rsp_done, rsp_err, rsp_tci, rsp_avec, owner;
  logic  [1:0]  rsp_beat, rsp_lw;
  logic [31:0]  rsp_data;
  logic         miss_i;
  logic [63:0]  fill_lo;
  logic [31:0]  sn_wdata;
  logic  [3:0]  sn_wbe;
  logic         sn_wr, sn_dinv, sn_iinv;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fpc <= 32'h0; for (int i = 0; i < 4; i++) q[i] <= 16'h0; q_ok <= 1'b0;
      de_op <= '0; de_ext <= '0;
      ea_q <= '0; ea_siz_q <= '0; ea_sext_q <= 1'b0;
      ex_a <= '0; ex_b <= '0; ex_op <= '0; ex_dst <= '0; ex_ra <= '0; ex_rb <= '0;
      ex_disp <= '0; ex_pc <= '0;
      x_we <= 1'b0; x_reg <= '0; x_val <= '0;
      w_we <= 1'b0; w_reg <= '0; w_val <= '0;
      page8k <= 1'b0; mmu_en <= 1'b0; s_mode <= 1'b1; itt0 <= '0; dtt0 <= '0;
      req_valid <= 1'b0; miss_a <= '0; miss_i <= 1'b0; fill_lo <= '0;
      ifill_we <= 1'b0; ifill_la <= '0; ifill_pa <= '0;
      dfill_we <= 1'b0; dfill_la <= '0; dfill_pa <= '0;
      ic_twe <= 1'b0; ic_tset <= '0; ic_tway <= '0; ic_baddr <= '0; ic_bwe <= '0; ic_bwd <= '0;
      dc_twe <= 1'b0; dc_tset <= '0; dc_tway <= '0; dc_baddr <= '0; dc_bwe <= '0; dc_bwd <= '0;
      rom_we <= 1'b0; rom_wa <= '0; rom_wd <= '0;
      sum_o <= '0;
    end else begin
      // IF
      fpc <= fpc_d;
      if (fetch_ok) begin
        q[0] <= ihalf[63:48]; q[1] <= ihalf[47:32]; q[2] <= ihalf[31:16]; q[3] <= ihalf[15:0];
      end else begin
        q[0] <= q[1]; q[1] <= q[2]; q[2] <= q[3];
      end
      q_ok <= fetch_ok;
      // DE
      de_op  <= q[0];
      de_ext <= q[1];
      // EA
      ea_q      <= ea_sum;
      ea_siz_q  <= dec_q[10:9];
      ea_sext_q <= dec_q[11];
      // OF -> EX
      ex_a    <= dec_q[12] ? opnd : rf_c;
      ex_b    <= dec_q[13] ? rf_d : {{16{de_ext[15]}}, de_ext};
      ex_op   <= dec_q[17:14];
      ex_dst  <= dec_q[21:18];
      ex_ra   <= dec_q[3:0];
      ex_rb   <= dec_q[7:4];
      ex_disp <= ea_disp;
      ex_pc   <= fpc;
      // EX -> W
      x_we  <= of_ok && dec_q[22];
      x_reg <= ex_dst;
      x_val <= alu[31:0];
      w_we  <= x_we;
      w_reg <= x_reg;
      w_val <= x_val;
      // Misses go to the bus; the answers fill the caches, the ATCs and the ROM.
      if (!req_valid && (!fetch_ok || !of_ok)) begin
        req_valid <= 1'b1;
        miss_i    <= !fetch_ok;
        miss_a    <= !fetch_ok ? {i_ppage, fpc[11:0]} : {d_ppage, ea_q[11:0]};
      end else if (req_ready) begin
        req_valid <= 1'b0;
      end
      ic_twe <= 1'b0; dc_twe <= 1'b0; ic_bwe <= '0; dc_bwe <= '0;
      ifill_we <= 1'b0; dfill_we <= 1'b0; rom_we <= 1'b0;
      if (rsp_valid) begin
        if (rsp_beat[0] == 1'b0) fill_lo[63:32] <= rsp_data;
        else begin
          fill_lo[31:0] <= rsp_data;
          if (miss_i) begin
            ic_bwd <= {fill_lo[63:32], rsp_data}; ic_bwe <= 8'hFF;
            ic_baddr <= {miss_a[9:4], rsp_lw[1]}; ic_tway <= ic_valid[1:0];
            ic_tset <= miss_a[9:4]; ic_twe <= rsp_done;
          end else begin
            dc_bwd <= {fill_lo[63:32], rsp_data}; dc_bwe <= 8'hFF;
            dc_baddr <= {miss_a[9:4], rsp_lw[1]}; dc_tway <= dc_valid[1:0];
            dc_tset <= miss_a[9:4]; dc_twe <= rsp_done;
          end
        end
        if (rsp_done) begin
          ifill_we <= miss_i;  ifill_la <= fpc[31:12]; ifill_pa <= rsp_data[31:12];
          dfill_we <= !miss_i; dfill_la <= ea_q[31:12]; dfill_pa <= rsp_data[31:12];
          rom_we <= 1'b1; rom_wa <= rsp_data[9:0]; rom_wd <= {fill_lo[63:32], rsp_data};
          if (rsp_data[31:28] == 4'hF) begin
            page8k <= rsp_data[0]; mmu_en <= rsp_data[1]; s_mode <= rsp_data[2];
            itt0 <= fill_lo[63:32]; dtt0 <= rsp_data;
          end
        end
      end
      sum_o <= w_val ^ {28'h0, sn_dirty} ^ {31'h0, sn_hit} ^ dc_b[31:0] ^ ic_b[63:32] ^
               {26'h0, i_u, i_cm, d_u} ^ {24'h0, i_sp, i_m, i_w, i_r, d_sp, d_m, d_w, d_r} ^
               {28'h0, sh_v, sh_x, sh_xw, q_ok} ^ {28'h0, ic_dirty} ^ {30'h0, sn_way} ^
               {16'h0, de_op} ^ {28'h0, mm, md, mi[1:0]} ^ {31'h0, rsp_err ^ rsp_tci ^ rsp_avec ^ owner ^ mi[2]} ^
               {28'h0, dc_dirty} ^ {sn_wdata ^ {28'h0, sn_wbe}} ^ {29'h0, sn_wr, sn_dinv, sn_iinv} ^ dec_q[63:32];
    end
  end

  logic [1:0] tln, upa;
  logic       lock_n, locke_n, ciout_n;
  rd68041_biu u_biu (
      .clk(clk), .rst_n(rst_n), .crst(crst),
      .req_valid(req_valid), .req_ready(req_ready), .req_addr(miss_a),
      .req_write(1'b0), .req_siz(2'b11), .req_tt(2'b00),
      .req_tm(miss_i ? 3'b110 : 3'b101), .req_tln(2'b00), .req_upa(2'b00),
      .req_ciout(1'b0), .req_lock(1'b0), .req_locke(1'b0), .req_more(1'b0),
      .req_wdata({dc_b[127:0]}), .lock_seq(1'b0),
      .rsp_valid(rsp_valid), .rsp_beat(rsp_beat), .rsp_lw(rsp_lw), .rsp_data(rsp_data),
      .rsp_tci(rsp_tci), .rsp_avec(rsp_avec), .rsp_done(rsp_done), .rsp_err(rsp_err),
      .owner(owner),
      .a_i(a_i), .a_o(a_o), .a_oe(a_oe), .d_i(d_i), .d_o(d_o), .d_oe(d_oe),
      .tt_i(tt_i), .tt_o(tt_o), .tm_o(tm_o), .tln_o(tln), .upa_o(upa),
      .rw_i(rw_i), .rw_o(rw_o), .siz_i(siz_i), .siz_o(siz_o),
      .lock_n_o(lock_n), .locke_n_o(locke_n), .ciout_n_o(ciout_n), .attr_oe(attr_oe),
      .ts_n_i(ts_n_i), .ts_n_o(ts_n_o), .tip_n_o(tip_n_o), .tip_oe(tip_oe),
      .ta_n_i(ta_n_i), .ta_n_o(ta_n_o), .ta_oe(ta_oe), .tea_n_i(tea_n_i),
      .tci_n_i(tci_n_i), .tbi_n_i(tbi_n_i), .avec_n_i(1'b1), .br_n_o(br_n_o),
      .bg_n_i(bg_n_i), .bb_n_i(bb_n_i), .bb_n_o(bb_n_o), .bb_oe(bb_oe),
      .sc_i(sc_i), .mi_n_o(mi_n_o),
      .sn_addr(sn_addr), .sn_dhit(sn_hit), .sn_ddirty(sn_dirty != 4'h0), .sn_ihit(1'b0),
      .sn_rdata(dc_b[63:32]), .sn_wr(sn_wr), .sn_wbe(sn_wbe), .sn_wdata(sn_wdata),
      .sn_dinv(sn_dinv), .sn_iinv(sn_iinv));

endmodule
