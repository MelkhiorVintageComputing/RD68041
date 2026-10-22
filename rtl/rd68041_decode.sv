// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- SystemVerilog MC68040
//
// The decode stage's decoder: an operation word and the extension words after
// it, in, one micro-operation out (rd68041_pkg::uop_t, doc/microarch.md).
// Combinational.
//
// The instruction is decoded once it is all in the queue: `need` is how many
// words it is, and the decode stage waits until the queue holds them. Most
// instructions are one micro-operation. Two are issued, one a clock, where an
// instruction has two memory addresses or a push beside its own address:
//
//   MOVE <mem>,<mem>   load the source into T0; store T0 at the destination
//   PEA <ea>           T0 = <ea>; push T0
//   JSR <ea>           T0 = <ea>; push the return address and jump to T0
//
// `step` says which is wanted; the second sees its operation word as `op` (the
// decode stage holds it) and its extension words from w[0], the first having
// taken the operation word and the source's extension words (`pop`).
//
// M6 decodes the instructions the walking skeleton runs (doc/plan.md): MOVE,
// MOVEA, MOVEQ, LEA, PEA, CLR, TST, NOP, RTS, JMP, JSR, BRA, BSR, Bcc, ADDQ,
// SUBQ, the immediate group, ADD, ADDA, SUB, SUBA, CMP, CMPA, AND, OR, EOR,
// EXT, EXTB, SWAP, and ANDI/ORI/EORI to CCR, with every addressing mode but the
// full extension-word format. Anything else is a micro-operation with `halt`,
// which stops the pipeline when it reaches write-back (M7 and M8 replace it
// with the instruction or with the exception PRM 4 gives).

module rd68041_decode (
    input  logic [15:0]  op,           // the operation word
    input  logic [111:0] w,            // extension words: w[0] in 111:96, then w[1]...
    input  logic         step,         // 0: the first micro-operation, 1: the second
    input  logic [31:0]  pc,           // the instruction's address
    output logic [rd68041_pkg::UOP_W-1:0] uop,
    output logic  [2:0]  need,         // extension words the instruction has (step 0)
    output logic  [2:0]  pop,          // extension words this micro-operation takes
    output logic         more          // a second micro-operation follows
);

  // ---------------------------------------------------------------------------
  // Extension words, numbered from w[0].
  // ---------------------------------------------------------------------------
  function automatic logic [15:0] ew(input logic [111:0] v, input int k);
    ew = v[111 - 16*k -: 16];
  endfunction
  // Its low byte, and the word sign-extended (a select on a function's result
  // is not portable: yosys and iverilog refuse it).
  function automatic logic [7:0] ewb(input logic [111:0] v, input int k);
    ewb = v[103 - 16*k -: 8];
  endfunction
  function automatic logic [31:0] ews(input logic [111:0] v, input int k);
    ews = {{16{v[111 - 16*k]}}, v[111 - 16*k -: 16]};
  endfunction

  // How many extension words an <ea> has (PRM 2.2, Table 2-?), for an operand
  // of `sz`; mode 6 with bit 8 set is the full format, which M6 does not build
  // (`full`).
  function automatic logic [2:0] ea_len(input logic [2:0] m, input logic [2:0] r,
                                        input logic [1:0] sz);
    case (m)
      3'd5, 3'd6: ea_len = 3'd1;
      3'd7: case (r)
              3'd0, 3'd2, 3'd3: ea_len = 3'd1;
              3'd1:             ea_len = 3'd2;
              3'd4:             ea_len = (sz == rd68041_pkg::SZ_L) ? 3'd2 : 3'd1;
              default:          ea_len = 3'd0;
            endcase
      default: ea_len = 3'd0;
    endcase
  endfunction

  // The immediate an <ea> of mode 7.4 carries, at extension word k.
  function automatic logic [31:0] imm_of(input logic [111:0] v, input int k,
                                         input logic [1:0] sz);
    case (sz)
      rd68041_pkg::SZ_B: imm_of = {24'h0, ewb(v, k)};
      rd68041_pkg::SZ_W: imm_of = {16'h0, ew(v, k)};
      default:           imm_of = {ew(v, k), ew(v, k + 1)};
    endcase
  endfunction

  // PRM 2.2: the classes of <ea> an instruction allows.
  function automatic logic is_imm(input logic [2:0] m, input logic [2:0] r);
    is_imm = (m == 3'd7) && (r == 3'd4);
  endfunction
  function automatic logic ok_mode(input logic [2:0] m, input logic [2:0] r);
    ok_mode = (m != 3'd7) || (r <= 3'd4);
  endfunction
  // Data alterable: not An, not PC-relative, not immediate.
  function automatic logic dalt(input logic [2:0] m, input logic [2:0] r);
    dalt = (m != 3'd1) && ((m != 3'd7) || (r <= 3'd1));
  endfunction
  // Memory alterable.
  function automatic logic malt(input logic [2:0] m, input logic [2:0] r);
    malt = (m >= 3'd2) && ((m != 3'd7) || (r <= 3'd1));
  endfunction
  // Control: (An), (d16,An), (d8,An,Xn), abs, PC-relative.
  function automatic logic ctrl(input logic [2:0] m, input logic [2:0] r);
    ctrl = (m == 3'd2) || (m == 3'd5) || (m == 3'd6) || ((m == 3'd7) && (r <= 3'd3));
  endfunction

  // ---------------------------------------------------------------------------
  // The decoder.
  // ---------------------------------------------------------------------------
  // One <ea>'s fields into a micro-operation, for an operand of size sz, its
  // extension words at w[k].
  function automatic rd68041_pkg::uop_t put_ea(input rd68041_pkg::uop_t ui,
                                               input logic [111:0] v,
                                               input logic [2:0] m, input logic [2:0] r,
                                               input logic [1:0] sz, input int k);
    rd68041_pkg::uop_t o;
    logic [15:0] x;
    o = ui;
    x = ew(v, k);
    o.ea_an   = r;
    o.ea_step = (sz == rd68041_pkg::SZ_L) ? 3'd4 :
                ((sz == rd68041_pkg::SZ_W) || (r == 3'd7)) ? 3'd2 : 3'd1;
    case (m)
      3'd2: begin o.ea_en = 1'b1; o.ea_base = rd68041_pkg::B_AN; end
      3'd3: begin o.ea_en = 1'b1; o.ea_base = rd68041_pkg::B_AN; o.ea_upd = rd68041_pkg::U_POST; end
      3'd4: begin o.ea_en = 1'b1; o.ea_base = rd68041_pkg::B_AN; o.ea_upd = rd68041_pkg::U_PRE; end
      3'd5: begin o.ea_en = 1'b1; o.ea_base = rd68041_pkg::B_AN; o.ea_disp = {{16{x[15]}}, x}; end
      3'd6: begin
        o.ea_en    = 1'b1;
        o.ea_base  = rd68041_pkg::B_AN;
        o.ea_xen   = 1'b1;
        o.ea_xn    = x[15:12];
        o.ea_xl    = x[11];
        o.ea_scale = x[10:9];
        o.ea_disp  = {{24{x[7]}}, x[7:0]};
        if (x[8]) o.halt = 1'b1;                      // the full format: M7
      end
      3'd7: begin
        o.ea_en = (r != 3'd4);
        case (r)
          3'd0: o.ea_disp = {{16{x[15]}}, x};
          3'd1: o.ea_disp = {x, ew(v, k + 1)};
          // PRM 2.2.11: the PC is "the address of the extension word".
          3'd2: begin o.ea_base = rd68041_pkg::B_PC; o.ea_disp = {{16{x[15]}}, x} + 32'(2 + 2*k); end
          3'd3: begin
            o.ea_base  = rd68041_pkg::B_PC;
            o.ea_xen   = 1'b1;
            o.ea_xn    = x[15:12];
            o.ea_xl    = x[11];
            o.ea_scale = x[10:9];
            o.ea_disp  = {{24{x[7]}}, x[7:0]} + 32'(2 + 2*k);
            if (x[8]) o.halt = 1'b1;
          end
          default: ;
        endcase
      end
      default: ;
    endcase
    put_ea = o;
  endfunction

  // The operand of an <ea> as a source on side A (to_a) or B: a register, the
  // immediate, or the memory operand (and then a load).
  function automatic rd68041_pkg::uop_t src_ea(input rd68041_pkg::uop_t ui,
                                               input logic [111:0] v,
                                               input logic [2:0] m, input logic [2:0] r,
                                               input logic [1:0] sz, input int k,
                                               input bit to_a);
    rd68041_pkg::uop_t o;
    logic [1:0] sel;
    logic [4:0] rr;
    o  = ui;
    rr = {1'b0, (m == 3'd1), r};
    if (m <= 3'd1) begin
      sel = rd68041_pkg::S_REG;
    end else if (is_imm(m, r)) begin
      sel = rd68041_pkg::S_IMM;
      o.imm = imm_of(v, k, sz);
    end else begin
      sel = rd68041_pkg::S_MEM;
      o.ld = 1'b1;
      o = put_ea(o, v, m, r, sz, k);
    end
    if (to_a) begin o.a_sel = sel; o.a_reg = rr; end
    else      begin o.b_sel = sel; o.b_reg = rr; end
    src_ea = o;
  endfunction

  rd68041_pkg::uop_t u;
  logic bad;

  logic [2:0] sm, sr, dm, dr;     // source and destination <ea> fields
  logic [1:0] sz;
  logic [2:0] n_src, n_dst;
  logic [4:0] dn;

  always_comb begin
    u        = '0;
    u.valid  = 1'b1;
    u.last   = 1'b1;
    u.pc     = pc;
    u.a_sel  = rd68041_pkg::S_REG;
    u.b_sel  = rd68041_pkg::S_REG;
    u.op     = rd68041_pkg::OP_PASSB;
    u.cc     = rd68041_pkg::CC_NONE;
    u.br     = rd68041_pkg::BR_NONE;
    u.wr_sz  = rd68041_pkg::SZ_L;
    bad      = 1'b0;
    need     = 3'd0;
    pop      = 3'd0;
    more     = 1'b0;
    sm = op[5:3];  sr = op[2:0];
    dm = op[8:6];  dr = op[11:9];
    dn = {2'b00, op[11:9]};
    sz = rd68041_pkg::SZ_L;
    n_src = 3'd0;  n_dst = 3'd0;

    casez (op)
      // --- MOVE, MOVEA (PRM 4: 00ss) --------------------------------------
      16'b00??_????_????_????: begin
        if (op[13:12] == 2'b00) begin
          bad = 1'b1;                              // the bit and immediate group: below
        end else begin
          sz = (op[13:12] == 2'b01) ? rd68041_pkg::SZ_B :
               (op[13:12] == 2'b11) ? rd68041_pkg::SZ_W : rd68041_pkg::SZ_L;
          n_src = ea_len(sm, sr, sz);
          n_dst = ea_len(dm, dr, sz);
          need  = n_src + n_dst;
          u.sz  = sz;
          if (!ok_mode(sm, sr) || (sm == 3'd1 && sz == rd68041_pkg::SZ_B)) bad = 1'b1;
          if (dm == 3'd1) begin
            // MOVEA: no byte form; the word is sign-extended (PRM 4).
            if (sz == rd68041_pkg::SZ_B) bad = 1'b1;
            u = src_ea(u, w, sm, sr, sz, 0, 1'b0);
            u.b_sxw = (sz == rd68041_pkg::SZ_W);
            u.wr = 1'b1; u.wr_reg = {2'b01, dr};
            u.len = 5'(2 + 2*need);
            pop = n_src;
          end else if (!dalt(dm, dr)) begin
            bad = 1'b1;
          end else if (dm == 3'd0) begin
            u = src_ea(u, w, sm, sr, sz, 0, 1'b0);
            u.cc = rd68041_pkg::CC_LOGIC;
            u.wr = 1'b1; u.wr_reg = {2'b00, dr}; u.wr_sz = sz;
            u.len = 5'(2 + 2*need);
            pop = n_src;
          end else if (step == 1'b0 && sm >= 3'd2 && !is_imm(sm, sr)) begin
            // Memory to memory, first: the source into T0.
            u = src_ea(u, w, sm, sr, sz, 0, 1'b0);
            u.last = 1'b0; more = 1'b1;
            u.wr = 1'b1; u.wr_reg = 5'd16; u.wr_sz = rd68041_pkg::SZ_L;
            u.len = 5'(2 + 2*need);
            pop = n_src;
          end else if (step == 1'b1) begin
            // ... second: T0 to the destination, its extension words now at w[0].
            u.b_sel = rd68041_pkg::S_REG; u.b_reg = 5'd16;
            u = put_ea(u, w, dm, dr, sz, 0);
            u.st = 1'b1;
            u.cc = rd68041_pkg::CC_LOGIC;
            u.len = 5'(2 + 2*need);
            pop = n_dst;
          end else begin
            // A register or an immediate to memory: one micro-operation.
            u = src_ea(u, w, sm, sr, sz, 0, 1'b0);
            u = put_ea(u, w, dm, dr, sz, int'(n_src));
            u.st = 1'b1;
            u.cc = rd68041_pkg::CC_LOGIC;
            u.len = 5'(2 + 2*need);
            pop = n_src + n_dst;
          end
        end
      end
      default: ;
    endcase

    // The group that shares 00 with MOVE: the immediate operations and the
    // CCR forms (PRM 4: ORI, ANDI, SUBI, ADDI, EORI, CMPI).
    if (op[15:12] == 4'b0000) begin
      bad = 1'b0;
      if (op[8] == 1'b0 && op[7:6] != 2'b11 &&
          (op[11:9] == 3'd0 || op[11:9] == 3'd1 || op[11:9] == 3'd2 ||
           op[11:9] == 3'd3 || op[11:9] == 3'd5 || op[11:9] == 3'd6)) begin
        sz = op[7:6];
        if (sm == 3'd7 && sr == 3'd4) begin
          // To CCR (byte) or SR (word, M8).
          if (sz == rd68041_pkg::SZ_B &&
              (op[11:9] == 3'd0 || op[11:9] == 3'd1 || op[11:9] == 3'd5)) begin
            need = 3'd1; pop = 3'd1;
            u.len = 5'd4;
            u.a_sel = rd68041_pkg::S_IMM; u.imm = {24'h0, ewb(w, 0)};
            u.op = rd68041_pkg::OP_CCR;
            u.cc = rd68041_pkg::CC_SET;
            u.cond = (op[11:9] == 3'd0) ? 4'd1 : (op[11:9] == 3'd1) ? 4'd0 : 4'd2; // or, and, eor
          end else begin
            bad = 1'b1;
          end
        end else begin
          n_src = (sz == rd68041_pkg::SZ_L) ? 3'd2 : 3'd1;
          n_dst = ea_len(sm, sr, sz);
          need  = n_src + n_dst;
          pop   = need;
          u.len = 5'(2 + 2*need);
          u.sz  = sz;
          u.a_sel = rd68041_pkg::S_IMM; u.imm = imm_of(w, 0, sz);
          case (op[11:9])
            3'd0: begin u.op = rd68041_pkg::OP_OR;  u.cc = rd68041_pkg::CC_LOGIC; end
            3'd1: begin u.op = rd68041_pkg::OP_AND; u.cc = rd68041_pkg::CC_LOGIC; end
            3'd2: begin u.op = rd68041_pkg::OP_SUB; u.cc = rd68041_pkg::CC_SUB;   end
            3'd3: begin u.op = rd68041_pkg::OP_ADD; u.cc = rd68041_pkg::CC_ADD;   end
            3'd5: begin u.op = rd68041_pkg::OP_EOR; u.cc = rd68041_pkg::CC_LOGIC; end
            default: begin u.op = rd68041_pkg::OP_CMP; u.cc = rd68041_pkg::CC_CMP; end
          endcase
          if (op[11:9] == 3'd6) begin
            // CMPI: any data <ea> but immediate (PC-relative on the 68020 on).
            if (sm == 3'd1 || is_imm(sm, sr) || !ok_mode(sm, sr)) bad = 1'b1;
            u = src_ea(u, w, sm, sr, sz, int'(n_src), 1'b0);
          end else if (!dalt(sm, sr)) begin
            bad = 1'b1;
          end else if (sm == 3'd0) begin
            u.b_reg = {2'b00, sr};
            u.wr = 1'b1; u.wr_reg = {2'b00, sr}; u.wr_sz = sz;
          end else begin
            u = src_ea(u, w, sm, sr, sz, int'(n_src), 1'b0);
            u.st = 1'b1;
          end
        end
      end else begin
        bad = 1'b1;                                // bit operations, MOVEP, MOVES...: M7
      end
    end

    // --- 0100: the miscellaneous group --------------------------------------
    if (op[15:12] == 4'b0100) begin
      priority casez (op[11:0])
        12'b1001_1100_0???: begin                  // EXTB.L (before LEA, whose encoding it shares with Dn)
          u.len = 5'd2;
          u.b_reg = {2'b00, sr};
          u.op = rd68041_pkg::OP_EXTBL; u.sz = rd68041_pkg::SZ_L;
          u.cc = rd68041_pkg::CC_LOGIC;
          u.wr = 1'b1; u.wr_reg = {2'b00, sr};
        end
        12'b???1_11??_????: begin                  // LEA <ea>,An
          if (!ctrl(sm, sr)) bad = 1'b1;
          need = ea_len(sm, sr, rd68041_pkg::SZ_L); pop = need;
          u.len = 5'(2 + 2*need);
          u = put_ea(u, w, sm, sr, rd68041_pkg::SZ_L, 0);
          u.b_sel = rd68041_pkg::S_EA;
          u.wr = 1'b1; u.wr_reg = {2'b01, dr};
        end
        12'b1000_0100_0???: begin                  // SWAP Dn
          u.len = 5'd2;
          u.b_reg = {2'b00, sr};
          u.op = rd68041_pkg::OP_SWAP; u.cc = rd68041_pkg::CC_LOGIC;
          u.wr = 1'b1; u.wr_reg = {2'b00, sr};
        end
        12'b1000_01??_????: begin                  // PEA <ea>
          if (!ctrl(sm, sr)) bad = 1'b1;
          need = ea_len(sm, sr, rd68041_pkg::SZ_L);
          u.len = 5'(2 + 2*need);
          if (step == 1'b0) begin
            u = put_ea(u, w, sm, sr, rd68041_pkg::SZ_L, 0);
            pop = need;
            u.b_sel = rd68041_pkg::S_EA;
            u.wr = 1'b1; u.wr_reg = 5'd16;
            u.last = 1'b0; more = 1'b1;
          end else begin
            u = put_ea(u, w, 3'd4, 3'd7, rd68041_pkg::SZ_L, 0);
            u.b_reg = 5'd16;
            u.st = 1'b1; u.sz = rd68041_pkg::SZ_L;
          end
        end
        12'b1000_1?00_0???: begin                  // EXT.W, EXT.L
          u.len = 5'd2;
          u.b_reg = {2'b00, sr};
          u.op = op[6] ? rd68041_pkg::OP_EXTL : rd68041_pkg::OP_EXTW;
          u.sz = op[6] ? rd68041_pkg::SZ_L : rd68041_pkg::SZ_W;
          u.cc = rd68041_pkg::CC_LOGIC;
          u.wr = 1'b1; u.wr_reg = {2'b00, sr}; u.wr_sz = u.sz;
        end
        12'b0010_????_????: begin                  // CLR <ea>
          sz = op[7:6];
          if (sz == 2'b11 || !dalt(sm, sr)) bad = 1'b1;
          need = ea_len(sm, sr, sz); pop = need;
          u.len = 5'(2 + 2*need);
          u.sz = sz;
          u.op = rd68041_pkg::OP_CLR; u.cc = rd68041_pkg::CC_LOGIC;
          if (sm == 3'd0) begin
            u.wr = 1'b1; u.wr_reg = {2'b00, sr}; u.wr_sz = sz;
          end else begin
            // PRM 4: the MC68020 on does not read the operand first.
            u = put_ea(u, w, sm, sr, sz, 0);
            u.st = 1'b1;
          end
        end
        12'b1010_????_????: begin                  // TST <ea> (TAS, ILLEGAL: M7, M8)
          sz = op[7:6];
          if (sz == 2'b11 || !ok_mode(sm, sr) || (sm == 3'd1 && sz == rd68041_pkg::SZ_B)) bad = 1'b1;
          need = ea_len(sm, sr, sz); pop = need;
          u.len = 5'(2 + 2*need);
          u.sz = sz;
          u = src_ea(u, w, sm, sr, sz, 0, 1'b0);
          u.cc = rd68041_pkg::CC_LOGIC;
        end
        12'b1110_0111_0001: begin                  // NOP
          u.len = 5'd2;
        end
        12'b1110_0111_0101: begin                  // RTS
          u.len = 5'd2;
          u = put_ea(u, w, 3'd3, 3'd7, rd68041_pkg::SZ_L, 0);
          u.ld = 1'b1; u.sz = rd68041_pkg::SZ_L;
          u.br = rd68041_pkg::BR_MEM;
        end
        12'b1110_11??_????: begin                  // JMP <ea>
          if (!ctrl(sm, sr)) bad = 1'b1;
          need = ea_len(sm, sr, rd68041_pkg::SZ_L); pop = need;
          u.len = 5'(2 + 2*need);
          u = put_ea(u, w, sm, sr, rd68041_pkg::SZ_L, 0);
          u.b_sel = rd68041_pkg::S_EA;
          u.br = rd68041_pkg::BR_EA;
        end
        12'b1110_10??_????: begin                  // JSR <ea>
          if (!ctrl(sm, sr)) bad = 1'b1;
          need = ea_len(sm, sr, rd68041_pkg::SZ_L);
          u.len = 5'(2 + 2*need);
          if (step == 1'b0) begin
            u = put_ea(u, w, sm, sr, rd68041_pkg::SZ_L, 0);
            pop = need;
            u.b_sel = rd68041_pkg::S_EA;
            u.wr = 1'b1; u.wr_reg = 5'd16;
            u.last = 1'b0; more = 1'b1;
          end else begin
            // Push the return address, then go to T0.
            u = put_ea(u, w, 3'd4, 3'd7, rd68041_pkg::SZ_L, 0);
            u.a_sel = rd68041_pkg::S_IMM; u.imm = pc + 32'(2 + 2*need);
            u.op = rd68041_pkg::OP_PASSA;
            u.st = 1'b1; u.sz = rd68041_pkg::SZ_L;
            u.b_reg = 5'd16;
            u.br = rd68041_pkg::BR_EA;
          end
        end
        default: bad = 1'b1;
      endcase
    end

    // --- 0101: ADDQ, SUBQ (Scc, DBcc, TRAPcc: M7) ---------------------------
    if (op[15:12] == 4'b0101) begin
      sz = op[7:6];
      if (sz == 2'b11 || !ok_mode(sm, sr) || !((sm == 3'd1) || dalt(sm, sr)) ||
          (sm == 3'd1 && sz == rd68041_pkg::SZ_B)) begin
        bad = 1'b1;
      end else begin
        need = ea_len(sm, sr, sz); pop = need;
        u.len = 5'(2 + 2*need);
        u.sz = sz;
        u.a_sel = rd68041_pkg::S_IMM; u.imm = (op[11:9] == 3'd0) ? 32'd8 : {29'h0, op[11:9]};
        if (sm == 3'd1) begin
          // To An: the whole register, no flags (PRM 4, ADDQ).
          u.op = op[8] ? rd68041_pkg::OP_SUBA : rd68041_pkg::OP_ADDA;
          u.sz = rd68041_pkg::SZ_L;
          u.b_reg = {2'b01, sr};
          u.wr = 1'b1; u.wr_reg = {2'b01, sr};
        end else begin
          u.op = op[8] ? rd68041_pkg::OP_SUB : rd68041_pkg::OP_ADD;
          u.cc = op[8] ? rd68041_pkg::CC_SUB : rd68041_pkg::CC_ADD;
          u = src_ea(u, w, sm, sr, sz, 0, 1'b0);
          if (sm == 3'd0) begin
            u.wr = 1'b1; u.wr_reg = {2'b00, sr}; u.wr_sz = sz;
          end else begin
            u.st = 1'b1;
          end
        end
      end
    end

    // --- 0110: BRA, BSR, Bcc ------------------------------------------------
    if (op[15:12] == 4'b0110) begin
      logic [31:0] d;
      if (op[7:0] == 8'h00) begin
        need = 3'd1; d = ews(w, 0);
      end else if (op[7:0] == 8'hFF) begin
        need = 3'd2; d = {ew(w, 0), ew(w, 1)};
      end else begin
        need = 3'd0; d = {{24{op[7]}}, op[7:0]};
      end
      pop = need;
      u.len = 5'(2 + 2*need);
      // PRM 4: "the PC contains the instruction address plus two".
      u.tgt = pc + 32'd2 + d;
      u.br  = rd68041_pkg::BR_DISP;
      u.cond = (op[11:8] == 4'd1) ? 4'd0 : op[11:8];    // BSR's 1 is "true", as BRA's 0
      if (op[11:8] == 4'd1) begin
        u = put_ea(u, w, 3'd4, 3'd7, rd68041_pkg::SZ_L, 0);
        u.a_sel = rd68041_pkg::S_IMM; u.imm = pc + 32'(2 + 2*need);
        u.op = rd68041_pkg::OP_PASSA;
        u.st = 1'b1; u.sz = rd68041_pkg::SZ_L;
      end
    end

    // --- 0111: MOVEQ --------------------------------------------------------
    if (op[15:12] == 4'b0111) begin
      if (op[8]) bad = 1'b1;
      u.len = 5'd2;
      u.b_sel = rd68041_pkg::S_IMM; u.imm = {{24{op[7]}}, op[7:0]};
      u.cc = rd68041_pkg::CC_LOGIC;
      u.wr = 1'b1; u.wr_reg = {2'b00, dr};
    end

    // --- 1000 OR, 1001 SUB, 1011 CMP/EOR, 1100 AND, 1101 ADD -----------------
    if (op[15:12] == 4'b1000 || op[15:12] == 4'b1001 || op[15:12] == 4'b1011 ||
        op[15:12] == 4'b1100 || op[15:12] == 4'b1101) begin
      logic [2:0] om;
      om = op[8:6];
      sz = (om == 3'd3) ? rd68041_pkg::SZ_W : (om == 3'd7) ? rd68041_pkg::SZ_L : om[1:0];
      need = ea_len(sm, sr, sz); pop = need;
      u.len = 5'(2 + 2*need);
      u.sz = sz;
      case (op[15:12])
        4'b1000: begin u.op = rd68041_pkg::OP_OR;  u.cc = rd68041_pkg::CC_LOGIC; end
        4'b1100: begin u.op = rd68041_pkg::OP_AND; u.cc = rd68041_pkg::CC_LOGIC; end
        4'b1001: begin u.op = rd68041_pkg::OP_SUB; u.cc = rd68041_pkg::CC_SUB;   end
        4'b1101: begin u.op = rd68041_pkg::OP_ADD; u.cc = rd68041_pkg::CC_ADD;   end
        default: begin
          u.op = om[2] ? rd68041_pkg::OP_EOR : rd68041_pkg::OP_CMP;
          u.cc = om[2] ? rd68041_pkg::CC_LOGIC : rd68041_pkg::CC_CMP;
        end
      endcase
      if (!ok_mode(sm, sr)) bad = 1'b1;
      if (om == 3'd3 || om == 3'd7) begin
        // ADDA, SUBA, CMPA; on OR and AND these are DIV and MUL (M7).
        if (op[15:12] == 4'b1000 || op[15:12] == 4'b1100) bad = 1'b1;
        u = src_ea(u, w, sm, sr, sz, 0, 1'b1);
        u.a_sxw = (om == 3'd3);
        u.b_reg = {2'b01, dr};
        if (op[15:12] == 4'b1011) begin
          u.op = rd68041_pkg::OP_CMP; u.cc = rd68041_pkg::CC_CMP;
          u.sz = rd68041_pkg::SZ_L;        // PRM 4: compared at 32 bits, the word extended
        end else begin
          u.op = (op[15:12] == 4'b1101) ? rd68041_pkg::OP_ADDA : rd68041_pkg::OP_SUBA;
          u.cc = rd68041_pkg::CC_NONE;
          u.wr = 1'b1; u.wr_reg = {2'b01, dr};
        end
      end else if (!om[2] || (op[15:12] == 4'b1011 && !om[2])) begin
        // <ea> op Dn -> Dn (CMP: flags only). An as a source is word or long.
        if ((op[15:12] == 4'b1000 || op[15:12] == 4'b1100) && sm == 3'd1) bad = 1'b1;
        if (sm == 3'd1 && sz == rd68041_pkg::SZ_B) bad = 1'b1;
        u = src_ea(u, w, sm, sr, sz, 0, 1'b1);
        u.b_reg = dn;
        if (op[15:12] != 4'b1011) begin
          u.wr = 1'b1; u.wr_reg = dn; u.wr_sz = sz;
        end
      end else begin
        // Dn op <ea> -> <ea>; register forms here are ADDX, SUBX, ABCD, SBCD,
        // EXG, CMPM: M7. EOR's register form is EOR Dn,Dm.
        u.a_reg = dn;
        if (op[15:12] == 4'b1011 && sm == 3'd0) begin
          u.b_reg = {2'b00, sr};
          u.wr = 1'b1; u.wr_reg = {2'b00, sr}; u.wr_sz = sz;
        end else if (sm <= 3'd1 || !malt(sm, sr)) begin
          bad = 1'b1;
        end else begin
          u = src_ea(u, w, sm, sr, sz, 0, 1'b0);
          u.st = 1'b1;
        end
      end
    end

    // --- 1010, 1110, 1111: the line-A, shift and coprocessor groups: M7, M8 --
    if (op[15:12] == 4'b1010 || op[15:12] == 4'b1110 || op[15:12] == 4'b1111) bad = 1'b1;

    // put_ea marks an <ea> M6 does not build (the full format) with halt.
    if (bad || u.halt) begin
      u = '0;
      u.valid = 1'b1;
      u.last  = 1'b1;
      u.halt  = 1'b1;
      u.pc    = pc;
      need    = 3'd0;
      pop     = 3'd0;
      more    = 1'b0;
    end
  end

  assign uop = u;

endmodule
