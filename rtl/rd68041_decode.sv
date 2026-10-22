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
// extension words it has, and the decode stage waits until the queue holds
// them. Most instructions are one micro-operation. Where one has more -- a
// second memory address, a push beside its own address, a list of registers --
// they are issued one a clock: `more` says another follows, `seq` how many
// went before, and `pop` how many extension words this one takes (the
// operation word is the decode stage's to take, on the first). The decode stage
// holds the operation word, the instruction's address and the prelude flags
// (`ind_out`, returned as `ind_in`) for the rest.
//
// An <ea> with memory indirection (PRM 2.2.8-2.2.10) is two addresses: a
// prelude reads the pointer into T3, and the instruction then addresses from
// T3. The prelude comes first, before the instruction's own micro-operations,
// or -- for MOVE's destination -- before the micro-operation that needs it.
//
//   MOVE <mem>,<mem>   load the source into T0; store T0 at the destination
//   PEA <ea>           T0 = <ea>; push T0
//   JSR <ea>           T0 = <ea>; push the return address and jump to T0
//   ADDX, SUBX -(Ay),-(Ax)   load -(Ay) into T0; the operation on -(Ax)
//   CMPM (Ay)+,(Ax)+   load (Ay)+ into T0; compare (Ax)+ with it
//   RTR                the CCR from (A7)+; then RTS
//   ABCD, SBCD -(Ay),-(Ax)   as ADDX
//   PACK, UNPK -(Ax),-(Ay)   two reads and a write, or a read and two writes
//   CMP2, CHK2         the lower bound into T0; the upper, compared
//   CAS2               both operands read under LOCK into T0 and T1, the two
//                      compares, the two updates or the write-back, each
//                      conditional on the compares (`cx`), and Dc1, Dc2
//   MOVEP              one byte a micro-operation, two or four
//   MOVEM              one register a micro-operation, after T0 = <ea> for the
//                      control modes, or T0 = An - size for -(An) when An is
//                      in the list (PRM 4: the MC68020 on writes "the initial
//                      register value decremented by the size")
//
// MOVEM's registers and MOVEP's bytes are counted by the decode stage: it
// passes the next register (mv_reg), whether it is the last (mv_last), and how
// many have gone (mv_k), and is told when one is used (mv_used).
//
// Anything not built yet is a micro-operation with `halt`, which stops the
// pipeline when it reaches write-back: until M7 completes, the instructions
// still to come; until M8, those whose work is an exception (TRAP, RTE, STOP,
// RESET, BKPT, MOVE to SR, ILLEGAL, the unimplemented A- and F-lines).

module rd68041_decode (
    input  logic [15:0]  op,           // the operation word
    input  logic [175:0] w,            // extension words: w[0] in 175:160, then w[1]...
    input  logic  [4:0]  seq,          // micro-operations of this instruction issued already
    input  logic  [1:0]  ind_in,       // the preludes issued (bit 0 the source's or op[5:0]'s)
    input  logic  [4:0]  len_in,       // the instruction's length, as the first one said
    input  logic [31:0]  pc,           // the instruction's address
    input  logic  [3:0]  mv_reg,       // MOVEM: the next register (0-7 D, 8-15 A)
    input  logic         mv_last,      // ... and it is the list's last
    input  logic  [4:0]  mv_k,         // MOVEM, MOVEP: transfers already issued
    output logic [rd68041_pkg::UOP_W-1:0] uop,
    output logic  [3:0]  need,         // extension words the instruction has (seq 0)
    output logic  [3:0]  pop,          // extension words this micro-operation takes
    output logic         more,         // another micro-operation follows
    output logic         mv_used,      // this one transfers mv_reg (or MOVEP's byte)
    output logic  [1:0]  ind_out       // seq 0: the preludes this instruction has
);

  // ---------------------------------------------------------------------------
  // Extension words, numbered from w[0].
  // ---------------------------------------------------------------------------
  function automatic logic [15:0] ew(input logic [175:0] v, input int k);
    ew = v[175 - 16*k -: 16];
  endfunction
  // Its low byte, and the word sign-extended (a select on a function's result
  // is not portable: yosys and iverilog refuse it).
  function automatic logic [7:0] ewb(input logic [175:0] v, input int k);
    ewb = v[167 - 16*k -: 8];
  endfunction
  function automatic logic [31:0] ews(input logic [175:0] v, input int k);
    ews = {{16{v[175 - 16*k]}}, v[175 - 16*k -: 16]};
  endfunction
  function automatic logic [31:0] ewl(input logic [175:0] v, input int k);
    ewl = {v[175 - 16*k -: 16], v[159 - 16*k -: 16]};
  endfunction

  // An indexed mode with the full extension-word format (PRM 2.2.6-2.2.10):
  // mode 6, or mode 7 register 3, whose first extension word has bit 8 set.
  function automatic logic is_full(input logic [2:0] m, input logic [2:0] r,
                                   input logic [15:0] x);
    is_full = ((m == 3'd6) || (m == 3'd7 && r == 3'd3)) && x[8];
  endfunction
  // Its words: the base displacement's (BD SIZE, bits 5-4: 01 none, 10 a word,
  // 11 a long) and the outer displacement's (I/IS, bits 1-0, the same).
  function automatic logic [3:0] bd_words(input logic [15:0] x);
    bd_words = (x[5:4] == 2'b10) ? 4'd1 : (x[5:4] == 2'b11) ? 4'd2 : 4'd0;
  endfunction
  function automatic logic [3:0] od_words(input logic [15:0] x);
    od_words = (x[2:0] == 3'd0 || x[2:0] == 3'd4) ? 4'd0 :
               (x[1:0] == 2'b10) ? 4'd1 : (x[1:0] == 2'b11) ? 4'd2 : 4'd0;
  endfunction
  // Memory indirect: I/IS not zero (PRM Table 2-2).
  function automatic logic is_ind(input logic [2:0] m, input logic [2:0] r,
                                  input logic [15:0] x);
    is_ind = is_full(m, r, x) && (x[2:0] != 3'd0);
  endfunction
  // ... and post-indexed (I/IS 101-111 with the index not suppressed).
  function automatic logic is_post(input logic [15:0] x);
    is_post = !x[6] && x[2];
  endfunction
  // The encodings PRM Table 2-2 reserves.
  function automatic logic full_bad(input logic [15:0] x);
    full_bad = x[3] || (x[5:4] == 2'b00) || (x[2:0] == 3'd4) || (x[6] && x[2]);
  endfunction

  // How many extension words an <ea> has (PRM 2.2), for an operand of `sz`,
  // its first extension word x.
  function automatic logic [3:0] ea_len(input logic [2:0] m, input logic [2:0] r,
                                        input logic [1:0] sz, input logic [15:0] x);
    if (is_full(m, r, x)) begin
      ea_len = 4'd1 + bd_words(x) + od_words(x);
    end else begin
      case (m)
        3'd5, 3'd6: ea_len = 4'd1;
        3'd7: case (r)
                3'd0, 3'd2, 3'd3: ea_len = 4'd1;
                3'd1:             ea_len = 4'd2;
                3'd4:             ea_len = (sz == rd68041_pkg::SZ_L) ? 4'd2 : 4'd1;
                default:          ea_len = 4'd0;
              endcase
        default: ea_len = 4'd0;
      endcase
    end
  endfunction

  // The immediate an <ea> of mode 7.4 carries, at extension word k.
  function automatic logic [31:0] imm_of(input logic [175:0] v, input int k,
                                         input logic [1:0] sz);
    case (sz)
      rd68041_pkg::SZ_B: imm_of = {24'h0, ewb(v, k)};
      rd68041_pkg::SZ_W: imm_of = {16'h0, ew(v, k)};
      default:           imm_of = ewl(v, k);
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

  // One <ea>'s fields into a micro-operation, for an operand of size sz, its
  // extension words at w[k]. With the full format and memory indirection,
  // `pre` asks for the first of the two addresses -- where the pointer is
  // read, into T3 -- and otherwise this is the second: T3 plus the post-index
  // and the outer displacement (PRM 2.2.8-2.2.10).
  function automatic rd68041_pkg::uop_t put_ea(input rd68041_pkg::uop_t ui,
                                               input logic [175:0] v,
                                               input logic [2:0] m, input logic [2:0] r,
                                               input logic [1:0] sz, input int k,
                                               input bit pre);
    rd68041_pkg::uop_t o;
    logic [15:0] x;
    logic [31:0] bd, od;
    int          kb, ko;
    o = ui;
    x = ew(v, k);
    o.ea_an   = r;
    o.ea_step = (sz == rd68041_pkg::SZ_L) ? 3'd4 :
                ((sz == rd68041_pkg::SZ_W) || (r == 3'd7)) ? 3'd2 : 3'd1;
    if (is_full(m, r, x)) begin
      kb = k + 1;
      ko = k + 1 + int'(bd_words(x));
      bd = (x[5:4] == 2'b10) ? ews(v, kb) : (x[5:4] == 2'b11) ? ewl(v, kb) : 32'h0;
      od = (od_words(x) == 4'd1) ? ews(v, ko) : (od_words(x) == 4'd2) ? ewl(v, ko) : 32'h0;
      o.ea_en    = 1'b1;
      o.ea_xn    = x[15:12];
      o.ea_xl    = x[11];
      o.ea_scale = x[10:9];
      if (full_bad(x)) o.halt = 1'b1;
      if (x[2:0] != 3'd0 && !pre) begin
        // The second address: T3, the post-index, the outer displacement.
        o.ea_base = rd68041_pkg::B_REG;
        o.ea_reg  = 5'd19;
        o.ea_xen  = is_post(x);
        o.ea_disp = od;
      end else begin
        // The base (An or the PC, unless BS suppresses it), the index (unless
        // IS does, or it comes after the indirection) and the base
        // displacement. PRM 2.2.11: the PC is the first extension word's.
        o.ea_xen  = !x[6] && !(x[2:0] != 3'd0 && is_post(x));
        if (x[7]) begin
          o.ea_base = rd68041_pkg::B_NONE;
          o.ea_disp = bd;
        end else if (m == 3'd7) begin
          o.ea_base = rd68041_pkg::B_PC;
          o.ea_disp = bd + 32'(2 + 2*k);
        end else begin
          o.ea_base = rd68041_pkg::B_AN;
          o.ea_disp = bd;
        end
      end
    end else begin
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
        end
        3'd7: begin
          o.ea_en = (r != 3'd4);
          case (r)
            3'd0: o.ea_disp = {{16{x[15]}}, x};
            3'd1: o.ea_disp = ewl(v, k);
            3'd2: begin o.ea_base = rd68041_pkg::B_PC; o.ea_disp = {{16{x[15]}}, x} + 32'(2 + 2*k); end
            3'd3: begin
              o.ea_base  = rd68041_pkg::B_PC;
              o.ea_xen   = 1'b1;
              o.ea_xn    = x[15:12];
              o.ea_xl    = x[11];
              o.ea_scale = x[10:9];
              o.ea_disp  = {{24{x[7]}}, x[7:0]} + 32'(2 + 2*k);
            end
            default: ;
          endcase
        end
        default: ;
      endcase
    end
    put_ea = o;
  endfunction

  // The first micro-operation of an <ea> with memory indirection: the pointer,
  // a long word, read into T3.
  function automatic rd68041_pkg::uop_t ind_uop(input rd68041_pkg::uop_t ui,
                                                input logic [175:0] v,
                                                input logic [2:0] m, input logic [2:0] r,
                                                input int k);
    rd68041_pkg::uop_t o;
    o = put_ea(ui, v, m, r, rd68041_pkg::SZ_L, k, 1'b1);
    o.ld     = 1'b1;
    o.sz     = rd68041_pkg::SZ_L;
    o.b_sel  = rd68041_pkg::S_MEM;
    o.op     = rd68041_pkg::OP_PASSB;
    o.cc     = rd68041_pkg::CC_NONE;
    o.br     = rd68041_pkg::BR_NONE;
    o.st     = 1'b0;
    o.wr     = 1'b1;
    o.wr_reg = 5'd19;
    o.wr_sz  = rd68041_pkg::SZ_L;
    o.wr2    = 1'b0;
    o.crw    = 1'b0;
    o.trap   = 1'b0;
    o.last   = 1'b0;
    ind_uop  = o;
  endfunction

  // The operand of an <ea> as a source on side A (to_a) or B: a register, the
  // immediate, or the memory operand (and then a load).
  function automatic rd68041_pkg::uop_t src_ea(input rd68041_pkg::uop_t ui,
                                               input logic [175:0] v,
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
      o = put_ea(o, v, m, r, sz, k, 1'b0);
    end
    if (to_a) begin o.a_sel = sel; o.a_reg = rr; end
    else      begin o.b_sel = sel; o.b_reg = rr; end
    src_ea = o;
  endfunction

  rd68041_pkg::uop_t u;
  logic bad;

  // Shorthands for the fields the operation words share.
  logic [2:0] sm, sr, dm, dr;     // <ea> mode and register; bits 8-6 and 11-9
  logic [1:0] sz;
  logic [3:0] n_src, n_dst;
  logic [4:0] dn, an_r;           // Dn and An at bits 11-9, as register numbers
  logic [4:0] dy, ay;             // Dn and An at bits 2-0
  logic [4:0] k;                  // the transfer this is (MOVEM, MOVEP)
  logic [4:0] sq;                 // the micro-operation, not counting a prelude
  logic       stp;                // ... not the instruction's first
  logic [3:0] eak;                // where op[5:0]'s <ea> extension words start
  logic       uses_ea;            // op[5:0] is an <ea> of this instruction
  logic       pre_s;              // a prelude was issued for op[5:0]'s <ea>

  // The data register of a 1-bit-wide field, as a register number.
  function automatic logic [4:0] dreg(input logic [2:0] r);
    dreg = {2'b00, r};
  endfunction
  function automatic logic [4:0] areg(input logic [2:0] r);
    areg = {2'b01, r};
  endfunction

  // MOVEC's control register field (PRM 6, MOVEC; UM 2.2.2, 3.1, 4.2): its
  // index, or 4'hF for one the MC68040 does not have (an illegal instruction).
  function automatic logic [3:0] cr_of(input logic [11:0] c);
    case (c)
      12'h000: cr_of = rd68041_pkg::CR_SFC;
      12'h001: cr_of = rd68041_pkg::CR_DFC;
      12'h002: cr_of = rd68041_pkg::CR_CACR;
      12'h003: cr_of = rd68041_pkg::CR_TC;
      12'h004: cr_of = rd68041_pkg::CR_ITT0;
      12'h005: cr_of = rd68041_pkg::CR_ITT1;
      12'h006: cr_of = rd68041_pkg::CR_DTT0;
      12'h007: cr_of = rd68041_pkg::CR_DTT1;
      12'h800: cr_of = rd68041_pkg::CR_USP;
      12'h801: cr_of = rd68041_pkg::CR_VBR;
      12'h803: cr_of = rd68041_pkg::CR_MSP;
      12'h804: cr_of = rd68041_pkg::CR_ISP;
      12'h805: cr_of = rd68041_pkg::CR_MMUSR;
      12'h806: cr_of = rd68041_pkg::CR_URP;
      12'h807: cr_of = rd68041_pkg::CR_SRP;
      default: cr_of = 4'hF;
    endcase
  endfunction

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
    need     =  4'd0;
    pop      =  4'd0;
    more     = 1'b0;
    mv_used  = 1'b0;
    ind_out  = 2'b00;
    sm = op[5:3];  sr = op[2:0];
    dm = op[8:6];  dr = op[11:9];
    dn = dreg(op[11:9]);  an_r = areg(op[11:9]);
    dy = dreg(op[2:0]);   ay = areg(op[2:0]);
    sz = rd68041_pkg::SZ_L;
    n_src =  4'd0;  n_dst =  4'd0;
    // The indirection prelude, if any, comes first; the instruction's own
    // micro-operations are counted after it (doc/microarch.md).
    pre_s = (seq == 5'd0) ? 1'b0 : ind_in[0];
    sq  = seq - {4'h0, pre_s};
    stp = (sq != 5'd0);
    k   = stp ? mv_k : 5'd0;
    // Where op[5:0]'s extension words start, and whether it is an <ea> at all,
    // for the prelude below. MOVE decides its own.
    eak = 4'd0;
    uses_ea = 1'b1;
    case (op[15:12])
      4'b0000: begin
        if (op[8] && sm == 3'd1)       uses_ea = 1'b0;                // MOVEP
        else if (op[8])                eak = 4'd0;                    // BTST Dn,<ea>...
        else if (op[11:8] == 4'b1000)  eak = 4'd1;                    // BTST #n,<ea>...
        else if (op[7:6] == 2'b11 || op[11:8] == 4'b1110) eak = 4'd1; // CAS, CMP2, MOVES
        else                           eak = (op[7:6] == 2'b10) ? 4'd2 : 4'd1; // the immediates
      end
      4'b0100: begin
        if (op[11:4] == 8'hE7)                      uses_ea = 1'b0;  // RTE, RTS, MOVEC...
        if (op[11:7] == 5'b11000 || op[11:7] == 5'b10001 || op[11:7] == 5'b11001)
                                                    eak = 4'd1;      // MUL.L, DIV.L, MOVEM
      end
      4'b0101: if (op[7:6] == 2'b11 && (sm == 3'd1 || sm == 3'd7 && sr >= 3'd2))
                 uses_ea = 1'b0;                                      // DBcc, TRAPcc
      4'b0110, 4'b0111, 4'b1010, 4'b1111: uses_ea = 1'b0;
      4'b1110: begin
        if (op[7:6] != 2'b11) uses_ea = 1'b0;                         // the register shifts
        else if (op[11])      eak = 4'd1;                             // the bit fields
      end
      default: ;
    endcase

    case (op[15:12])
      // =======================================================================
      // 0000: bit operations, MOVEP, the immediates, CAS, CMP2/CHK2, MOVES
      // =======================================================================
      4'b0000: begin
        if (op[8] && sm == 3'd1) begin
          // MOVEP (PRM 4): bytes at (d16,Ay), +2, +4, +6, one a micro-op.
          logic [2:0] nb;
          nb   = op[6] ? 3'd4 : 3'd2;
          need =  4'd1;
          u.len = 5'd4;
          pop  = (k == 5'(nb - 3'd1)) ? 4'd1 : 4'd0;
          more = (k != 5'(nb - 3'd1));
          u.last = !more;
          mv_used = 1'b1;
          u = put_ea(u, w, 3'd5, sr, rd68041_pkg::SZ_B, 0, 1'b0);
          u.ea_disp = u.ea_disp + {26'h0, k, 1'b0};
          u.sz = rd68041_pkg::SZ_B;
          u.op = rd68041_pkg::OP_MOVEP;
          u.b_reg = dn;
          // Byte k of the transfer is the register's byte nb-1-k, high first.
          u.fn = {op[7], 1'b0, 2'(nb - 3'd1 - k[2:0])};
          if (op[7]) begin
            u.st = 1'b1;
          end else begin
            u.ld = 1'b1;
            u.a_sel = rd68041_pkg::S_MEM;
            u.wr = 1'b1; u.wr_reg = dn;
          end
        end else if (op[8] || op[11:8] == 4'b1000) begin
          // BTST, BCHG, BCLR, BSET (PRM 4): the bit number from Dn or from an
          // immediate word; a long word in Dn, a byte in memory.
          logic st_form;
          st_form = !op[8];
          n_src   = st_form ? 4'd1 : 4'd0;
          sz      = (sm == 3'd0) ? rd68041_pkg::SZ_L : rd68041_pkg::SZ_B;
          n_dst   = ea_len(sm, sr, sz, ew(w, int'(n_src)));
          need    = n_src + n_dst;
          pop     = need;
          u.len   = 5'(2 + 2*need);
          u.sz    = sz;
          u.op    = rd68041_pkg::OP_BIT;
          u.fn    = {2'b00, op[7:6]};
          if (st_form) begin
            u.a_sel = rd68041_pkg::S_IMM; u.imm = {24'h0, ewb(w, 0)};
          end else begin
            u.a_reg = dn;
          end
          if (sm == 3'd1 || !ok_mode(sm, sr)) bad = 1'b1;
          // Only BTST reads an immediate or a PC-relative operand.
          if (op[7:6] != 2'b00 && !dalt(sm, sr)) bad = 1'b1;
          if (st_form && is_imm(sm, sr)) bad = 1'b1;
          u = src_ea(u, w, sm, sr, sz, int'(n_src), 1'b0);
          if (op[7:6] != 2'b00) begin
            if (sm == 3'd0) begin u.wr = 1'b1; u.wr_reg = dy; end
            else            u.st = 1'b1;
          end
        end else if (op[7:6] == 2'b11 && !op[11]) begin
          // CMP2, CHK2 (PRM 4): Rn against the bounds pair at <ea>, the lower
          // first. The lower into T0; then the upper, compared.
          logic [15:0] x;
          x  = ew(w, 0);
          sz = op[10:9];
          if (sz == 2'b11 || !ctrl(sm, sr) || x[10:0] != 11'h0) bad = 1'b1;
          need  = 4'd1 + ea_len(sm, sr, sz, ew(w, 1));
          u.len = 5'(2 + 2*need);
          u.sz  = sz;
          u = put_ea(u, w, sm, sr, sz, 1, 1'b0);
          u.ld = 1'b1;
          if (!stp) begin
            u.b_sel = rd68041_pkg::S_MEM;
            u.wr = 1'b1; u.wr_reg = 5'd16;
            u.last = 1'b0; more = 1'b1;
          end else begin
            u.ea_disp = u.ea_disp + ((sz == rd68041_pkg::SZ_B) ? 32'd1 :
                                     (sz == rd68041_pkg::SZ_W) ? 32'd2 : 32'd4);
            u.a_reg = 5'd16;
            u.b_sel = rd68041_pkg::S_MEM;
            u.wr2_reg = {1'b0, x[15:12]};          // Rn, the third operand
            u.op = rd68041_pkg::OP_CMP2;
            u.trap = x[11];                        // CHK2
            pop = need;
          end
        end else if (op[7:6] == 2'b11 && sm == 3'd7 && sr == 3'd4) begin
          // CAS2 (PRM 4): both read under LOCK, compared, then either both
          // updates written or the second operand written back (UM 7.4.5),
          // and the compare registers loaded.
          logic [15:0] x1, x2;
          logic [4:0]  rn1, rn2;
          x1 = ew(w, 0); x2 = ew(w, 1);
          rn1 = {1'b0, x1[15:12]}; rn2 = {1'b0, x2[15:12]};
          sz  = (op[10:9] == 2'b10) ? rd68041_pkg::SZ_W : rd68041_pkg::SZ_L;
          if (op[10:9] == 2'b00 || op[10:9] == 2'b01) bad = 1'b1;
          need  = 4'd2;
          u.len = 5'd6;
          u.sz  = sz;
          u.wr_sz = sz;
          more  = (sq != 5'd8);
          u.last = !more;
          case (sq)
            5'd0, 5'd1: begin                      // the two operands, locked
              u.ea_en = 1'b1; u.ea_base = rd68041_pkg::B_REG;
              u.ea_reg = (sq == 5'd0) ? rn1 : rn2;
              u.ld = 1'b1; u.lk = 1'b1;
              u.b_sel = rd68041_pkg::S_MEM;
              u.wr = 1'b1; u.wr_reg = (sq == 5'd0) ? 5'd16 : 5'd17;
            end
            5'd2: begin                            // compare the first
              u.a_reg = dreg(x1[2:0]); u.b_reg = 5'd16;
              u.op = rd68041_pkg::OP_CMP; u.cc = rd68041_pkg::CC_CMP;
            end
            5'd3: begin                            // ... and, if equal, the second
              u.a_reg = dreg(x2[2:0]); u.b_reg = 5'd17;
              u.op = rd68041_pkg::OP_CMP; u.cc = rd68041_pkg::CC_CMP;
              u.cx = 1'b1; u.cond = 4'h7;
            end
            5'd4, 5'd5: begin                      // equal: the updates, the second first
              u.ea_en = 1'b1; u.ea_base = rd68041_pkg::B_REG;
              u.ea_reg = (sq == 5'd4) ? rn2 : rn1;
              u.b_reg  = (sq == 5'd4) ? dreg(x2[8:6]) : dreg(x1[8:6]);
              u.st = 1'b1; u.lk = 1'b1; u.lke = (sq == 5'd5);
              u.cx = 1'b1; u.cond = 4'h7;
            end
            5'd6: begin                            // not: the second written back
              u.ea_en = 1'b1; u.ea_base = rd68041_pkg::B_REG; u.ea_reg = rn2;
              u.b_reg = 5'd17;
              u.st = 1'b1; u.lk = 1'b1; u.lke = 1'b1;
              u.cx = 1'b1; u.cond = 4'h6;
            end
            default: begin                         // ... and Dc1, Dc2 loaded
              u.b_reg = (sq == 5'd7) ? 5'd16 : 5'd17;
              u.wr = 1'b1; u.wr_reg = (sq == 5'd7) ? dreg(x1[2:0]) : dreg(x2[2:0]);
              u.cx = 1'b1; u.cond = 4'h6;
              if (sq == 5'd8) pop = 4'd2;
            end
          endcase
        end else if (op[7:6] == 2'b11) begin
          // CAS Dc,Du,<ea> (PRM 4): read under LOCK, compared with Dc; Du
          // written if equal, else the operand written back (UM 7.4.5) and Dc
          // loaded with it.
          logic [15:0] x;
          x  = ew(w, 0);
          sz = (op[10:9] == 2'b01) ? rd68041_pkg::SZ_B :
               (op[10:9] == 2'b10) ? rd68041_pkg::SZ_W : rd68041_pkg::SZ_L;
          if (op[10:9] == 2'b00 || !malt(sm, sr) || x[15:9] != 7'h0 || x[5:3] != 3'h0)
            bad = 1'b1;
          need  = 4'd1 + ea_len(sm, sr, sz, ew(w, 1)); pop = need;
          u.len = 5'(2 + 2*need);
          u.sz  = sz;
          u = put_ea(u, w, sm, sr, sz, 1, 1'b0);
          u.ld = 1'b1; u.st = 1'b1; u.lk = 1'b1; u.lke = 1'b1;
          u.a_reg = dreg(x[2:0]);
          u.b_sel = rd68041_pkg::S_MEM;
          u.wr2_reg = dreg(x[8:6]);                // Du, the third operand
          u.op = rd68041_pkg::OP_CAS; u.cc = rd68041_pkg::CC_CMP;
          u.wr = 1'b1; u.wr_reg = dreg(x[2:0]); u.wr_sz = sz;
        end else if (op[11:8] == 4'b1110) begin
          // MOVES (PRM 6): the source or destination in the space SFC or
          // DFC names (UM 7.4: an alternate function code access).
          logic [15:0] x;
          x  = ew(w, 0);
          sz = op[7:6];
          if (!malt(sm, sr) || x[10:0] != 11'h0) bad = 1'b1;
          need  = 4'd1 + ea_len(sm, sr, sz, ew(w, 1)); pop = need;
          u.len = 5'(2 + 2*need);
          u.sz  = sz;
          u = put_ea(u, w, sm, sr, sz, 1, 1'b0);
          u.alt = 1'b1;
          if (x[11]) begin
            u.st = 1'b1;
            u.b_reg = {1'b0, x[15:12]};
          end else begin
            u.ld = 1'b1;
            u.b_sel = rd68041_pkg::S_MEM;
            u.wr = 1'b1; u.wr_reg = {1'b0, x[15:12]};
            if (x[15]) begin
              // To An: the whole register, the operand sign-extended.
              u.b_sxw = (sz == rd68041_pkg::SZ_W);
              if (sz == rd68041_pkg::SZ_B) u.op = rd68041_pkg::OP_EXTBL;
            end else begin
              u.wr_sz = sz;
            end
          end
        end else if (op[11:9] == 3'd0 || op[11:9] == 3'd1 || op[11:9] == 3'd2 ||
                     op[11:9] == 3'd3 || op[11:9] == 3'd5 || op[11:9] == 3'd6) begin
          sz = op[7:6];
          if (sm == 3'd7 && sr == 3'd4) begin
            // To CCR (byte); to SR (word) is M8's.
            if (sz == rd68041_pkg::SZ_B &&
                (op[11:9] == 3'd0 || op[11:9] == 3'd1 || op[11:9] == 3'd5)) begin
              need =  4'd1; pop =  4'd1;
              u.len = 5'd4;
              u.a_sel = rd68041_pkg::S_IMM; u.imm = {24'h0, ewb(w, 0)};
              u.op = rd68041_pkg::OP_CCR;
              u.cc = rd68041_pkg::CC_SET;
              u.cond = (op[11:9] == 3'd0) ? 4'd1 : (op[11:9] == 3'd1) ? 4'd0 : 4'd2;
            end else begin
              bad = 1'b1;
            end
          end else begin
            n_src = (sz == rd68041_pkg::SZ_L) ? 4'd2 : 4'd1;
            n_dst = ea_len(sm, sr, sz, ew(w, int'(n_src)));
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
              if (sm == 3'd1 || is_imm(sm, sr) || !ok_mode(sm, sr)) bad = 1'b1;
              u = src_ea(u, w, sm, sr, sz, int'(n_src), 1'b0);
            end else if (!dalt(sm, sr)) begin
              bad = 1'b1;
            end else if (sm == 3'd0) begin
              u.b_reg = dy;
              u.wr = 1'b1; u.wr_reg = dy; u.wr_sz = sz;
            end else begin
              u = src_ea(u, w, sm, sr, sz, int'(n_src), 1'b0);
              u.st = 1'b1;
            end
          end
        end else begin
          bad = 1'b1;
        end
      end

      // =======================================================================
      // 0001, 0010, 0011: MOVE, MOVEA
      // =======================================================================
      4'b0001, 4'b0010, 4'b0011: begin
        // The phases (doc/microarch.md): [the source's prelude] [the source
        // into T0] [the destination's prelude] the move. ind_in says which
        // preludes were issued; ph counts the phases from 0.
        logic       mm;
        logic [4:0] ph;
        uses_ea = 1'b0;                          // MOVE handles its own preludes
        sz = (op[13:12] == 2'b01) ? rd68041_pkg::SZ_B :
             (op[13:12] == 2'b11) ? rd68041_pkg::SZ_W : rd68041_pkg::SZ_L;
        n_src = ea_len(sm, sr, sz, ew(w, 0));
        n_dst = ea_len(dm, dr, sz, ew(w, int'(n_src)));
        need  = n_src + n_dst;
        u.sz  = sz;
        u.len = 5'(2 + 2*need);
        mm    = (sm >= 3'd2) && !is_imm(sm, sr) && (dm >= 3'd2);
        if (!ok_mode(sm, sr) || (sm == 3'd1 && sz == rd68041_pkg::SZ_B)) bad = 1'b1;
        if (dm >= 3'd2 && !dalt(dm, dr)) bad = 1'b1;
        if (dm == 3'd1 && sz == rd68041_pkg::SZ_B) bad = 1'b1;
        if (seq == 5'd0) begin
          ind_out[0] = (sm >= 3'd2) && is_ind(sm, sr, ew(w, 0));
          ind_out[1] = (dm >= 3'd2) && is_ind(dm, dr, ew(w, int'(n_src)));
        end
        // Map the micro-operation to its phase: 0 source prelude, 1 source to
        // T0, 2 destination prelude, 3 the move.
        begin
          logic si, di;
          si = (seq == 5'd0) ? ind_out[0] : ind_in[0];
          di = (seq == 5'd0) ? ind_out[1] : ind_in[1];
          ph = 5'd3;
          if (mm) begin
            case (seq)
              5'd0: ph = si ? 5'd0 : 5'd1;
              5'd1: ph = si ? 5'd1 : (di ? 5'd2 : 5'd3);
              5'd2: ph = (si && di) ? 5'd2 : 5'd3;
              default: ph = 5'd3;
            endcase
          end else if (dm >= 3'd2) begin
            ph = (seq == 5'd0 && di) ? 5'd2 : 5'd3;
          end else begin
            ph = (seq == 5'd0 && si) ? 5'd0 : 5'd3;
          end
        end
        case (ph)
          5'd0: begin
            u = ind_uop(u, w, sm, sr, 0);
            more = 1'b1;
          end
          5'd2: begin
            // Before it, with memory to memory, the source took its words.
            u = ind_uop(u, w, dm, dr, mm ? 0 : int'(n_src));
            more = 1'b1;
          end
          5'd1: begin
            u = src_ea(u, w, sm, sr, sz, 0, 1'b0);
            u.last = 1'b0; more = 1'b1;
            u.wr = 1'b1; u.wr_reg = 5'd16;
            pop = n_src;
          end
          default: begin
            if (dm == 3'd1) begin
              // MOVEA: no byte form; the word is sign-extended (PRM 4).
              u = src_ea(u, w, sm, sr, sz, 0, 1'b0);
              u.b_sxw = (sz == rd68041_pkg::SZ_W);
              u.wr = 1'b1; u.wr_reg = an_r;
              pop = n_src;
            end else if (dm == 3'd0) begin
              u = src_ea(u, w, sm, sr, sz, 0, 1'b0);
              u.cc = rd68041_pkg::CC_LOGIC;
              u.wr = 1'b1; u.wr_reg = dn; u.wr_sz = sz;
              pop = n_src;
            end else if (mm) begin
              // T0 to the destination, its extension words now at w[0].
              u.b_reg = 5'd16;
              u = put_ea(u, w, dm, dr, sz, 0, 1'b0);
              u.st = 1'b1;
              u.cc = rd68041_pkg::CC_LOGIC;
              pop = n_dst;
            end else begin
              u = src_ea(u, w, sm, sr, sz, 0, 1'b0);
              u = put_ea(u, w, dm, dr, sz, int'(n_src), 1'b0);
              u.st = 1'b1;
              u.cc = rd68041_pkg::CC_LOGIC;
              pop = n_src + n_dst;
            end
          end
        endcase
      end

      // =======================================================================
      // 0100: the miscellaneous group
      // =======================================================================
      4'b0100: begin
        priority casez (op[11:0])
          12'b0000_11??_????: begin                // MOVE from SR
            if (!dalt(sm, sr)) bad = 1'b1;
            need = ea_len(sm, sr, rd68041_pkg::SZ_W, ew(w, 0)); pop = need;
            u.len = 5'(2 + 2*need);
            u.sz = rd68041_pkg::SZ_W;
            u.crr = 1'b1; u.cr = rd68041_pkg::CR_SR;
            if (sm == 3'd0) begin u.wr = 1'b1; u.wr_reg = dy; u.wr_sz = rd68041_pkg::SZ_W; end
            else begin u = put_ea(u, w, sm, sr, rd68041_pkg::SZ_W, 0, 1'b0); u.st = 1'b1; end
          end
          12'b0010_11??_????: begin                // MOVE from CCR
            if (!dalt(sm, sr)) bad = 1'b1;
            need = ea_len(sm, sr, rd68041_pkg::SZ_W, ew(w, 0)); pop = need;
            u.len = 5'(2 + 2*need);
            u.sz = rd68041_pkg::SZ_W;
            u.crr = 1'b1; u.cr = rd68041_pkg::CR_SR;
            u.op = rd68041_pkg::OP_AND; u.a_sel = rd68041_pkg::S_IMM; u.imm = 32'h1F;
            if (sm == 3'd0) begin u.wr = 1'b1; u.wr_reg = dy; u.wr_sz = rd68041_pkg::SZ_W; end
            else begin u = put_ea(u, w, sm, sr, rd68041_pkg::SZ_W, 0, 1'b0); u.st = 1'b1; end
          end
          12'b0100_11??_????: begin                // MOVE to CCR
            if (sm == 3'd1 || !ok_mode(sm, sr)) bad = 1'b1;
            need = ea_len(sm, sr, rd68041_pkg::SZ_W, ew(w, 0)); pop = need;
            u.len = 5'(2 + 2*need);
            u.sz = rd68041_pkg::SZ_W;
            u = src_ea(u, w, sm, sr, rd68041_pkg::SZ_W, 0, 1'b1);
            u.op = rd68041_pkg::OP_TOCCR;
            u.cc = rd68041_pkg::CC_SET; u.cond = 4'd3;
          end
          12'b0110_11??_????: bad = 1'b1;          // MOVE to SR: M8
          12'b0010_????_????: begin                // CLR <ea>
            sz = op[7:6];
            if (!dalt(sm, sr)) bad = 1'b1;
            need = ea_len(sm, sr, sz, ew(w, 0)); pop = need;
            u.len = 5'(2 + 2*need);
            u.sz = sz;
            u.op = rd68041_pkg::OP_CLR; u.cc = rd68041_pkg::CC_LOGIC;
            if (sm == 3'd0) begin
              u.wr = 1'b1; u.wr_reg = dy; u.wr_sz = sz;
            end else begin
              // PRM 4: the MC68020 on does not read the operand first.
              u = put_ea(u, w, sm, sr, sz, 0, 1'b0);
              u.st = 1'b1;
            end
          end
          12'b0000_????_????,                      // NEGX
          12'b0100_????_????,                      // NEG
          12'b0110_????_????: begin                // NOT
            sz = op[7:6];
            if (!dalt(sm, sr)) bad = 1'b1;
            need = ea_len(sm, sr, sz, ew(w, 0)); pop = need;
            u.len = 5'(2 + 2*need);
            u.sz = sz;
            case (op[10:9])
              2'b00:   begin u.op = rd68041_pkg::OP_NEGX; u.cc = rd68041_pkg::CC_SUB; end
              2'b10:   begin u.op = rd68041_pkg::OP_NEG;  u.cc = rd68041_pkg::CC_SUB; end
              default: begin u.op = rd68041_pkg::OP_NOT;  u.cc = rd68041_pkg::CC_LOGIC; end
            endcase
            u = src_ea(u, w, sm, sr, sz, 0, 1'b0);
            if (sm == 3'd0) begin u.wr = 1'b1; u.wr_reg = dy; u.wr_sz = sz; end
            else            u.st = 1'b1;
          end
          12'b1001_1100_0???: begin                // EXTB.L (before LEA, whose encoding it shares)
            u.len = 5'd2;
            u.b_reg = dy;
            u.op = rd68041_pkg::OP_EXTBL;
            u.cc = rd68041_pkg::CC_LOGIC;
            u.wr = 1'b1; u.wr_reg = dy;
          end
          12'b???1_11??_????: begin                // LEA <ea>,An
            if (!ctrl(sm, sr)) bad = 1'b1;
            need = ea_len(sm, sr, rd68041_pkg::SZ_L, ew(w, 0)); pop = need;
            u.len = 5'(2 + 2*need);
            u = put_ea(u, w, sm, sr, rd68041_pkg::SZ_L, 0, 1'b0);
            u.b_sel = rd68041_pkg::S_EA;
            u.wr = 1'b1; u.wr_reg = an_r;
          end
          12'b???1_10??_????,                      // CHK.W
          12'b???1_00??_????: begin                // CHK.L
            sz = op[7] ? rd68041_pkg::SZ_W : rd68041_pkg::SZ_L;
            if (sm == 3'd1 || !ok_mode(sm, sr)) bad = 1'b1;
            need = ea_len(sm, sr, sz, ew(w, 0)); pop = need;
            u.len = 5'(2 + 2*need);
            u.sz = sz;
            u = src_ea(u, w, sm, sr, sz, 0, 1'b1);
            u.b_reg = dn;
            u.op = rd68041_pkg::OP_CMP;
            u.trap = 1'b1;
          end
          12'b1000_0000_1???: begin                // LINK.L An,#d32
            need =  4'd2; pop =  4'd2;
            u.len = 5'd6;
            u = put_ea(u, w, 3'd4, 3'd7, rd68041_pkg::SZ_L, 0, 1'b0);
            u.a_reg = ay;
            u.imm = {ew(w, 0), ew(w, 1)};
            u.op = rd68041_pkg::OP_LINK;
            u.st = 1'b1; u.sz = rd68041_pkg::SZ_L;
            u.wr = (op[2:0] != 3'd7); u.wr_reg = ay;
            u.wr2 = 1'b1; u.wr2_reg = 5'd15;
          end
          12'b1000_00??_????: begin                // NBCD <ea>
            if (!dalt(sm, sr)) bad = 1'b1;
            need = ea_len(sm, sr, rd68041_pkg::SZ_B, ew(w, 0)); pop = need;
            u.len = 5'(2 + 2*need);
            u.sz = rd68041_pkg::SZ_B;
            u.op = rd68041_pkg::OP_BCD; u.fn = 4'd2;
            u = src_ea(u, w, sm, sr, rd68041_pkg::SZ_B, 0, 1'b0);
            if (sm == 3'd0) begin u.wr = 1'b1; u.wr_reg = dy; u.wr_sz = rd68041_pkg::SZ_B; end
            else            u.st = 1'b1;
          end
          12'b1000_0100_0???: begin                // SWAP Dn
            u.len = 5'd2;
            u.b_reg = dy;
            u.op = rd68041_pkg::OP_SWAP; u.cc = rd68041_pkg::CC_LOGIC;
            u.wr = 1'b1; u.wr_reg = dy;
          end
          12'b1000_0100_1???: bad = 1'b1;          // BKPT: M8
          12'b1000_01??_????: begin                // PEA <ea>
            if (!ctrl(sm, sr)) bad = 1'b1;
            need = ea_len(sm, sr, rd68041_pkg::SZ_L, ew(w, 0));
            u.len = 5'(2 + 2*need);
            if (!stp) begin
              u = put_ea(u, w, sm, sr, rd68041_pkg::SZ_L, 0, 1'b0);
              pop = need;
              u.b_sel = rd68041_pkg::S_EA;
              u.wr = 1'b1; u.wr_reg = 5'd16;
              u.last = 1'b0; more = 1'b1;
            end else begin
              u = put_ea(u, w, 3'd4, 3'd7, rd68041_pkg::SZ_L, 0, 1'b0);
              u.b_reg = 5'd16;
              u.st = 1'b1; u.sz = rd68041_pkg::SZ_L;
            end
          end
          12'b1000_1?00_0???: begin                // EXT.W, EXT.L
            u.len = 5'd2;
            u.b_reg = dy;
            u.op = op[6] ? rd68041_pkg::OP_EXTL : rd68041_pkg::OP_EXTW;
            u.sz = op[6] ? rd68041_pkg::SZ_L : rd68041_pkg::SZ_W;
            u.cc = rd68041_pkg::CC_LOGIC;
            u.wr = 1'b1; u.wr_reg = dy; u.wr_sz = u.sz;
          end
          12'b1?00_1???_????: begin                // MOVEM
            // op[10]: to registers; op[6]: long. The mask is w[0].
            logic ld_form, pre, post, prel;
            logic [15:0] mask0;
            ld_form = op[10];
            mask0 = ew(w, 0);
            pre  = (sm == 3'd4);
            post = (sm == 3'd3);
            sz   = op[6] ? rd68041_pkg::SZ_L : rd68041_pkg::SZ_W;
            if (ld_form ? !(ctrl(sm, sr) || post) : !((ctrl(sm, sr) && malt(sm, sr)) || pre))
              bad = 1'b1;
            need  =  4'd1 + ea_len(sm, sr, rd68041_pkg::SZ_L, ew(w, 1));
            u.len = 5'(2 + 2*need);
            u.sz  = sz;
            // A prelude for the control modes (T0 = <ea>), and for -(An) when
            // An is in the list (T0 = An - size, what PRM 4 says is written
            // for it). The list's bit for An under -(An), whose mask is
            // reversed, is 7 - n. Every extension word goes with the first
            // micro-operation; the decode stage keeps the mask from there.
            prel = !(pre || post) || (pre && mask0[4'(7 - sr)]);
            if (!stp) pop = need;
            if (!stp && mask0 == 16'h0000) begin
              // No registers: nothing moves, and An is left alone.
            end else if (!stp && prel) begin
              if (pre) begin
                u = put_ea(u, w, 3'd5, sr, rd68041_pkg::SZ_L, 0, 1'b0);
                u.ea_disp = (sz == rd68041_pkg::SZ_L) ? -32'd4 : -32'd2;
              end else begin
                u = put_ea(u, w, sm, sr, rd68041_pkg::SZ_L, 1, 1'b0);
              end
              u.b_sel = rd68041_pkg::S_EA;
              u.wr = 1'b1; u.wr_reg = 5'd16;
              u.last = 1'b0; more = 1'b1;
            end else begin
              // One register.
              mv_used = 1'b1;
              more    = !mv_last;
              u.last  = mv_last;
              if (pre || post) begin
                u = put_ea(u, w, sm, sr, sz, 0, 1'b0);
              end else begin
                u.ea_en = 1'b1;
                u.ea_base = rd68041_pkg::B_REG; u.ea_reg = 5'd16;
                u.ea_disp = (sz == rd68041_pkg::SZ_L) ? {25'h0, k, 2'b00} : {26'h0, k, 1'b0};
              end
              if (ld_form) begin
                u.ld = 1'b1;
                u.b_sel = rd68041_pkg::S_MEM;
                u.b_sxw = (sz == rd68041_pkg::SZ_W);
                // PRM 4: with (An)+, An itself is not loaded.
                u.wr = !(post && mv_reg == {1'b1, sr});
                u.wr_reg = {1'b0, mv_reg};
              end else begin
                u.st = 1'b1;
                u.b_reg = (pre && mv_reg == {1'b1, sr}) ? 5'd16 : {1'b0, mv_reg};
              end
            end
          end
          12'b1010_1111_1100: bad = 1'b1;          // ILLEGAL: M8
          12'b1010_11??_????: begin                // TAS <ea>: a locked read-modify-write
            if (!dalt(sm, sr)) bad = 1'b1;
            need = ea_len(sm, sr, rd68041_pkg::SZ_B, ew(w, 0)); pop = need;
            u.len = 5'(2 + 2*need);
            u.sz = rd68041_pkg::SZ_B;
            u.op = rd68041_pkg::OP_TAS;
            u = src_ea(u, w, sm, sr, rd68041_pkg::SZ_B, 0, 1'b0);
            if (sm == 3'd0) begin
              u.wr = 1'b1; u.wr_reg = dy; u.wr_sz = rd68041_pkg::SZ_B;
            end else begin
              u.st = 1'b1; u.lk = 1'b1; u.lke = 1'b1;
            end
          end
          12'b1010_????_????: begin                // TST <ea>
            sz = op[7:6];
            if (!ok_mode(sm, sr) || (sm == 3'd1 && sz == rd68041_pkg::SZ_B)) bad = 1'b1;
            need = ea_len(sm, sr, sz, ew(w, 0)); pop = need;
            u.len = 5'(2 + 2*need);
            u.sz = sz;
            u = src_ea(u, w, sm, sr, sz, 0, 1'b0);
            u.cc = rd68041_pkg::CC_LOGIC;
          end
          12'b1100_00??_????: begin                // MULU.L, MULS.L
            logic [15:0] x;
            x = ew(w, 0);
            if (sm == 3'd1 || !ok_mode(sm, sr) || x[15] || x[9:3] != 7'h0) bad = 1'b1;
            need =  4'd1 + ea_len(sm, sr, rd68041_pkg::SZ_L, ew(w, 1)); pop = need;
            u.len = 5'(2 + 2*need);
            u.sz = rd68041_pkg::SZ_L;
            u = src_ea(u, w, sm, sr, rd68041_pkg::SZ_L, 1, 1'b1);
            u.b_reg = dreg(x[14:12]);
            u.op = rd68041_pkg::OP_MUL;
            u.fn = {1'b0, x[10], 1'b1, x[11]};
            u.wr = 1'b1; u.wr_reg = dreg(x[14:12]);
            if (x[10]) begin u.wr2 = 1'b1; u.wr2_reg = dreg(x[2:0]); end
          end
          12'b1100_01??_????: begin                // DIVU.L, DIVS.L
            logic [15:0] x;
            x = ew(w, 0);
            if (sm == 3'd1 || !ok_mode(sm, sr) || x[15] || x[9:3] != 7'h0) bad = 1'b1;
            need =  4'd1 + ea_len(sm, sr, rd68041_pkg::SZ_L, ew(w, 1)); pop = need;
            u.len = 5'(2 + 2*need);
            u.sz = rd68041_pkg::SZ_L;
            u = src_ea(u, w, sm, sr, rd68041_pkg::SZ_L, 1, 1'b1);
            u.b_reg = dreg(x[14:12]);                // Dq
            u.op = rd68041_pkg::OP_DIV;
            u.fn = {1'b0, x[10], 1'b1, x[11]};
            u.wr = 1'b1; u.wr_reg = dreg(x[14:12]);
            // The remainder, when there is a register for it (DIVxL.L, or the
            // 64-bit form); wr2_reg is also the 64-bit dividend's high half.
            u.wr2_reg = dreg(x[2:0]);
            u.wr2 = (x[2:0] != x[14:12]);
            u.cc = rd68041_pkg::CC_NONE;
          end
          12'b1110_0100_????: bad = 1'b1;          // TRAP #n: M8
          12'b1110_0101_0???: begin                // LINK.W An,#d16
            need =  4'd1; pop =  4'd1;
            u.len = 5'd4;
            u = put_ea(u, w, 3'd4, 3'd7, rd68041_pkg::SZ_L, 0, 1'b0);
            u.a_reg = ay;
            u.imm = ews(w, 0);
            u.op = rd68041_pkg::OP_LINK;
            u.st = 1'b1; u.sz = rd68041_pkg::SZ_L;
            u.wr = (op[2:0] != 3'd7); u.wr_reg = ay;
            u.wr2 = 1'b1; u.wr2_reg = 5'd15;
          end
          12'b1110_0101_1???: begin                // UNLK An
            u.len = 5'd2;
            u = put_ea(u, w, 3'd2, sr, rd68041_pkg::SZ_L, 0, 1'b0);
            u.ld = 1'b1; u.sz = rd68041_pkg::SZ_L;
            u.b_sel = rd68041_pkg::S_MEM;
            u.wr = 1'b1; u.wr_reg = ay;
            u.imm = 32'd4;
            u.wr2 = 1'b1; u.wr2_reg = 5'd15;
          end
          12'b1110_0110_0???: begin                // MOVE An,USP
            u.len = 5'd2;
            u.b_reg = ay;
            u.crw = 1'b1; u.cr = rd68041_pkg::CR_USP;
          end
          12'b1110_0110_1???: begin                // MOVE USP,An
            u.len = 5'd2;
            u.crr = 1'b1; u.cr = rd68041_pkg::CR_USP;
            u.wr = 1'b1; u.wr_reg = ay;
          end
          12'b1110_0111_0001: begin                // NOP
            u.len = 5'd2;
          end
          12'b1110_0111_0100: begin                // RTD #d16
            need =  4'd1; pop =  4'd1;
            u.len = 5'd4;
            u = put_ea(u, w, 3'd3, 3'd7, rd68041_pkg::SZ_L, 0, 1'b0);
            u.ld = 1'b1; u.sz = rd68041_pkg::SZ_L;
            u.b_sel = rd68041_pkg::S_MEM;
            u.br = rd68041_pkg::BR_MEM;
            u.imm = ews(w, 0) + 32'd4;
            u.wr2 = 1'b1; u.wr2_reg = 5'd15;
          end
          12'b1110_0111_0101: begin                // RTS
            u.len = 5'd2;
            u = put_ea(u, w, 3'd3, 3'd7, rd68041_pkg::SZ_L, 0, 1'b0);
            u.ld = 1'b1; u.sz = rd68041_pkg::SZ_L;
            u.br = rd68041_pkg::BR_MEM;
          end
          12'b1110_0111_0110: begin                // TRAPV
            u.len = 5'd2;
            u.trap = 1'b1; u.cond = 4'h9;            // VS
          end
          12'b1110_0111_0111: begin                // RTR: the CCR, then RTS
            u.len = 5'd2;
            if (!stp) begin
              u = put_ea(u, w, 3'd3, 3'd7, rd68041_pkg::SZ_W, 0, 1'b0);
              u.ld = 1'b1; u.sz = rd68041_pkg::SZ_W;
              u.a_sel = rd68041_pkg::S_MEM;
              u.op = rd68041_pkg::OP_TOCCR;
              u.cc = rd68041_pkg::CC_SET; u.cond = 4'd3;
              u.last = 1'b0; more = 1'b1;
            end else begin
              u = put_ea(u, w, 3'd3, 3'd7, rd68041_pkg::SZ_L, 0, 1'b0);
              u.ld = 1'b1; u.sz = rd68041_pkg::SZ_L;
              u.br = rd68041_pkg::BR_MEM;
            end
          end
          12'b1110_0111_101?: begin                // MOVEC
            logic [15:0] x;
            logic [3:0]  c;
            x = ew(w, 0);
            c = cr_of(x[11:0]);
            need =  4'd1; pop =  4'd1;
            u.len = 5'd4;
            if (c == 4'hF) bad = 1'b1;
            if (op[0]) begin                     // Rn -> Rc
              u.b_reg = {1'b0, x[15:12]};
              if (c == rd68041_pkg::CR_ISP) begin u.wr = 1'b1; u.wr_reg = 5'd15; end
              else begin u.crw = 1'b1; u.cr = c; end
            end else begin                       // Rc -> Rn
              if (c == rd68041_pkg::CR_ISP) u.b_reg = 5'd15;
              else begin u.crr = 1'b1; u.cr = c; end
              u.wr = 1'b1; u.wr_reg = {1'b0, x[15:12]};
            end
          end
          12'b1110_10??_????: begin                // JSR <ea>
            if (!ctrl(sm, sr)) bad = 1'b1;
            need = ea_len(sm, sr, rd68041_pkg::SZ_L, ew(w, 0));
            u.len = 5'(2 + 2*need);
            if (!stp) begin
              u = put_ea(u, w, sm, sr, rd68041_pkg::SZ_L, 0, 1'b0);
              pop = need;
              u.b_sel = rd68041_pkg::S_EA;
              u.wr = 1'b1; u.wr_reg = 5'd16;
              u.last = 1'b0; more = 1'b1;
            end else begin
              u = put_ea(u, w, 3'd4, 3'd7, rd68041_pkg::SZ_L, 0, 1'b0);
              // The return address: the instruction's length is the first
              // micro-operation's, the extension words being gone by now.
              u.a_sel = rd68041_pkg::S_IMM; u.imm = pc + {27'h0, len_in};
              u.op = rd68041_pkg::OP_PASSA;
              u.st = 1'b1; u.sz = rd68041_pkg::SZ_L;
              u.b_reg = 5'd16;
              u.br = rd68041_pkg::BR_EA;
            end
          end
          12'b1110_11??_????: begin                // JMP <ea>
            if (!ctrl(sm, sr)) bad = 1'b1;
            need = ea_len(sm, sr, rd68041_pkg::SZ_L, ew(w, 0)); pop = need;
            u.len = 5'(2 + 2*need);
            u = put_ea(u, w, sm, sr, rd68041_pkg::SZ_L, 0, 1'b0);
            u.b_sel = rd68041_pkg::S_EA;
            u.br = rd68041_pkg::BR_EA;
          end
          default: bad = 1'b1;                    // RESET, STOP, RTE: M8
        endcase
      end

      // =======================================================================
      // 0101: ADDQ, SUBQ, Scc, DBcc, TRAPcc
      // =======================================================================
      4'b0101: begin
        if (op[7:6] == 2'b11) begin
          if (sm == 3'd1) begin
            // DBcc Dn,<label>
            need =  4'd1; pop =  4'd1;
            u.len = 5'd4;
            u.b_reg = dy;
            u.op = rd68041_pkg::OP_DBCC;
            u.cond = op[11:8];
            u.wr = 1'b1; u.wr_reg = dy; u.wr_sz = rd68041_pkg::SZ_W;
            u.br = rd68041_pkg::BR_DISP;
            u.tgt = pc + 32'd2 + ews(w, 0);
          end else if (sm == 3'd7 && sr >= 3'd2) begin
            // TRAPcc, with no operand, a word or a long (PRM 4).
            if (sr > 3'd4) bad = 1'b1;
            need = (sr == 3'd2) ? 4'd1 : (sr == 3'd3) ? 4'd2 : 4'd0;
            pop  = need;
            u.len = 5'(2 + 2*need);
            u.trap = 1'b1; u.cond = op[11:8];
          end else begin
            // Scc <ea>
            if (!dalt(sm, sr)) bad = 1'b1;
            need = ea_len(sm, sr, rd68041_pkg::SZ_B, ew(w, 0)); pop = need;
            u.len = 5'(2 + 2*need);
            u.sz = rd68041_pkg::SZ_B;
            u.op = rd68041_pkg::OP_SCC;
            u.cond = op[11:8];
            if (sm == 3'd0) begin u.wr = 1'b1; u.wr_reg = dy; u.wr_sz = rd68041_pkg::SZ_B; end
            else begin u = put_ea(u, w, sm, sr, rd68041_pkg::SZ_B, 0, 1'b0); u.st = 1'b1; end
          end
        end else begin
          sz = op[7:6];
          if (!ok_mode(sm, sr) || !((sm == 3'd1) || dalt(sm, sr)) ||
              (sm == 3'd1 && sz == rd68041_pkg::SZ_B)) begin
            bad = 1'b1;
          end else begin
            need = ea_len(sm, sr, sz, ew(w, 0)); pop = need;
            u.len = 5'(2 + 2*need);
            u.sz = sz;
            u.a_sel = rd68041_pkg::S_IMM; u.imm = (op[11:9] == 3'd0) ? 32'd8 : {29'h0, op[11:9]};
            if (sm == 3'd1) begin
              // To An: the whole register, no flags (PRM 4, ADDQ).
              u.op = op[8] ? rd68041_pkg::OP_SUBA : rd68041_pkg::OP_ADDA;
              u.sz = rd68041_pkg::SZ_L;
              u.b_reg = ay;
              u.wr = 1'b1; u.wr_reg = ay;
            end else begin
              u.op = op[8] ? rd68041_pkg::OP_SUB : rd68041_pkg::OP_ADD;
              u.cc = op[8] ? rd68041_pkg::CC_SUB : rd68041_pkg::CC_ADD;
              u = src_ea(u, w, sm, sr, sz, 0, 1'b0);
              if (sm == 3'd0) begin u.wr = 1'b1; u.wr_reg = dy; u.wr_sz = sz; end
              else            u.st = 1'b1;
            end
          end
        end
      end

      // =======================================================================
      // 0110: BRA, BSR, Bcc
      // =======================================================================
      4'b0110: begin
        logic [31:0] d;
        if (op[7:0] == 8'h00) begin
          need =  4'd1; d = ews(w, 0);
        end else if (op[7:0] == 8'hFF) begin
          need =  4'd2; d = {ew(w, 0), ew(w, 1)};
        end else begin
          need =  4'd0; d = {{24{op[7]}}, op[7:0]};
        end
        pop = need;
        u.len = 5'(2 + 2*need);
        // PRM 4: "the PC contains the instruction address plus two".
        u.tgt = pc + 32'd2 + d;
        u.br  = rd68041_pkg::BR_DISP;
        u.cond = (op[11:8] == 4'd1) ? 4'd0 : op[11:8];    // BSR's 1 is "true", as BRA's 0
        if (op[11:8] == 4'd1) begin
          u = put_ea(u, w, 3'd4, 3'd7, rd68041_pkg::SZ_L, 0, 1'b0);
          u.a_sel = rd68041_pkg::S_IMM; u.imm = pc + 32'(2 + 2*need);
          u.op = rd68041_pkg::OP_PASSA;
          u.st = 1'b1; u.sz = rd68041_pkg::SZ_L;
        end
      end

      // =======================================================================
      // 0111: MOVEQ
      // =======================================================================
      4'b0111: begin
        if (op[8]) bad = 1'b1;
        u.len = 5'd2;
        u.b_sel = rd68041_pkg::S_IMM; u.imm = {{24{op[7]}}, op[7:0]};
        u.cc = rd68041_pkg::CC_LOGIC;
        u.wr = 1'b1; u.wr_reg = dn;
      end

      // =======================================================================
      // 1000 OR, DIV.W, SBCD, PACK, UNPK; 1001 SUB, SUBA, SUBX; 1011 CMP, CMPA,
      // EOR, CMPM; 1100 AND, MUL.W, ABCD, EXG; 1101 ADD, ADDA, ADDX
      // =======================================================================
      4'b1000, 4'b1001, 4'b1011, 4'b1100, 4'b1101: begin
        logic [2:0] om;
        logic       addx_form;
        om = op[8:6];
        sz = (om == 3'd3) ? rd68041_pkg::SZ_W : (om == 3'd7) ? rd68041_pkg::SZ_L : om[1:0];
        addx_form = om[2] && om[1:0] != 2'b11 && (sm == 3'd0 || sm == 3'd1);
        if ((op[15:12] == 4'b1000 || op[15:12] == 4'b1100) && (om == 3'd3 || om == 3'd7)) begin
          // DIVU.W, DIVS.W (1000); MULU.W, MULS.W (1100)
          if (sm == 3'd1 || !ok_mode(sm, sr)) bad = 1'b1;
          need = ea_len(sm, sr, rd68041_pkg::SZ_W, ew(w, 0)); pop = need;
          u.len = 5'(2 + 2*need);
          u.sz = rd68041_pkg::SZ_W;
          u = src_ea(u, w, sm, sr, rd68041_pkg::SZ_W, 0, 1'b1);
          u.b_reg = dn;
          u.op = (op[15:12] == 4'b1000) ? rd68041_pkg::OP_DIV : rd68041_pkg::OP_MUL;
          u.fn = {2'b00, 1'b0, om[2]};
          u.wr = 1'b1; u.wr_reg = dn;
        end else if ((op[15:12] == 4'b1000 || op[15:12] == 4'b1100) && om[2] &&
                     (sm == 3'd0 || sm == 3'd1) && om[1:0] == 2'b00) begin
          // ABCD, SBCD: Dy,Dx or -(Ay),-(Ax), as ADDX and SUBX.
          u.sz = rd68041_pkg::SZ_B;
          u.op = rd68041_pkg::OP_BCD; u.fn = (op[15:12] == 4'b1100) ? 4'd0 : 4'd1;
          u.len = 5'd2;
          if (sm == 3'd0) begin
            u.a_reg = dy; u.b_reg = dn;
            u.wr = 1'b1; u.wr_reg = dn; u.wr_sz = rd68041_pkg::SZ_B;
          end else if (!stp) begin
            u = put_ea(u, w, 3'd4, sr, rd68041_pkg::SZ_B, 0, 1'b0);
            u.ld = 1'b1;
            u.b_sel = rd68041_pkg::S_MEM;
            u.op = rd68041_pkg::OP_PASSB;
            u.wr = 1'b1; u.wr_reg = 5'd16;
            u.last = 1'b0; more = 1'b1;
          end else begin
            u = put_ea(u, w, 3'd4, dr, rd68041_pkg::SZ_B, 0, 1'b0);
            u.ld = 1'b1; u.st = 1'b1;
            u.a_reg = 5'd16;
            u.b_sel = rd68041_pkg::S_MEM;
          end
        end else if (op[15:12] == 4'b1000 && om[2] && (sm == 3'd0 || sm == 3'd1)) begin
          // PACK (10100), UNPK (11000): Dx,Dy,#adj or -(Ax),-(Ay),#adj; the
          // source at bits 2-0, the destination at 11-9 (PRM 4).
          logic unpk;
          // Bits 8-4: 10100 PACK, 11000 UNPK.
          unpk = (op[7:4] == 4'b1000);
          if (op[7:4] != 4'b0100 && op[7:4] != 4'b1000) bad = 1'b1;
          need  = 4'd1;
          u.len = 5'd4;
          u.imm = {16'h0, ew(w, 0)};
          u.a_sel = rd68041_pkg::S_REG;
          if (sm == 3'd0) begin
            pop = 4'd1;
            u.b_reg = dy;
            u.op = unpk ? rd68041_pkg::OP_UNPK : rd68041_pkg::OP_PACK;
            u.wr = 1'b1; u.wr_reg = dn;
            u.wr_sz = unpk ? rd68041_pkg::SZ_W : rd68041_pkg::SZ_B;
          end else if (!unpk) begin
            // PACK: the first byte read is the low one; then the high, the
            // pack; then the byte written.
            u.sz = rd68041_pkg::SZ_B;
            more = (sq != 5'd2);
            u.last = !more;
            case (sq)
              5'd0: begin
                u = put_ea(u, w, 3'd4, sr, rd68041_pkg::SZ_B, 0, 1'b0);
                u.ld = 1'b1; u.b_sel = rd68041_pkg::S_MEM;
                u.wr = 1'b1; u.wr_reg = 5'd16;
              end
              5'd1: begin
                u = put_ea(u, w, 3'd4, sr, rd68041_pkg::SZ_B, 0, 1'b0);
                u.imm = {16'h0, ew(w, 0)};
                u.ld = 1'b1; u.b_sel = rd68041_pkg::S_MEM;
                u.a_reg = 5'd16;
                u.op = rd68041_pkg::OP_PACK; u.fn = 4'd1;
                u.wr = 1'b1; u.wr_reg = 5'd17;
              end
              default: begin
                u = put_ea(u, w, 3'd4, dr, rd68041_pkg::SZ_B, 0, 1'b0);
                u.b_reg = 5'd17;
                u.st = 1'b1;
                pop = 4'd1;
              end
            endcase
          end else begin
            // UNPK: the byte read and unpacked; the low byte written, then the
            // high.
            u.sz = rd68041_pkg::SZ_B;
            more = (sq != 5'd2);
            u.last = !more;
            case (sq)
              5'd0: begin
                u = put_ea(u, w, 3'd4, sr, rd68041_pkg::SZ_B, 0, 1'b0);
                u.imm = {16'h0, ew(w, 0)};
                u.ld = 1'b1; u.b_sel = rd68041_pkg::S_MEM;
                u.op = rd68041_pkg::OP_UNPK;
                u.wr = 1'b1; u.wr_reg = 5'd16;
              end
              5'd1: begin
                u = put_ea(u, w, 3'd4, dr, rd68041_pkg::SZ_B, 0, 1'b0);
                u.b_reg = 5'd16;
                u.st = 1'b1;
              end
              default: begin
                u = put_ea(u, w, 3'd4, dr, rd68041_pkg::SZ_B, 0, 1'b0);
                u.b_reg = 5'd16;
                u.op = rd68041_pkg::OP_MOVEP; u.fn = 4'b1001;
                u.st = 1'b1;
                pop = 4'd1;
              end
            endcase
          end
        end else if (op[15:12] == 4'b1100 && om[2] && (sm == 3'd0 || sm == 3'd1)) begin
          // EXG (PRM 4): 01000 Dx,Dy; 01001 Ax,Ay; 10001 Dx,Ay.
          u.len = 5'd2;
          case (op[7:3])
            5'b01000: begin u.a_reg = dn;   u.b_reg = dy; end
            5'b01001: begin u.a_reg = an_r; u.b_reg = ay; end
            5'b10001: begin u.a_reg = dn;   u.b_reg = ay; end
            default:  bad = 1'b1;
          endcase
          u.op = rd68041_pkg::OP_EXG;
          u.wr = 1'b1;  u.wr_reg = u.b_reg;        // the second register gets the first's
          u.wr2 = 1'b1; u.wr2_reg = u.a_reg;       // ... and the first the second's
        end else if ((op[15:12] == 4'b1001 || op[15:12] == 4'b1101) && addx_form) begin
          // ADDX, SUBX: Dy,Dx or -(Ay),-(Ax).
          u.sz = sz;
          u.op = (op[15:12] == 4'b1101) ? rd68041_pkg::OP_ADDX : rd68041_pkg::OP_SUBX;
          u.cc = (op[15:12] == 4'b1101) ? rd68041_pkg::CC_ADD : rd68041_pkg::CC_SUB;
          u.len = 5'd2;
          if (sm == 3'd0) begin
            u.a_reg = dy; u.b_reg = dn;
            u.wr = 1'b1; u.wr_reg = dn; u.wr_sz = sz;
          end else if (!stp) begin
            u = put_ea(u, w, 3'd4, sr, sz, 0, 1'b0);
            u.ld = 1'b1;
            u.b_sel = rd68041_pkg::S_MEM;
            u.op = rd68041_pkg::OP_PASSB; u.cc = rd68041_pkg::CC_NONE;
            u.wr = 1'b1; u.wr_reg = 5'd16;
            u.last = 1'b0; more = 1'b1;
          end else begin
            u = put_ea(u, w, 3'd4, dr, sz, 0, 1'b0);
            u.ld = 1'b1; u.st = 1'b1;
            u.a_reg = 5'd16;
            u.b_sel = rd68041_pkg::S_MEM;
          end
        end else if (op[15:12] == 4'b1011 && om[2] && om[1:0] != 2'b11 && sm == 3'd1) begin
          // CMPM (Ay)+,(Ax)+
          u.sz = sz;
          u.len = 5'd2;
          if (!stp) begin
            u = put_ea(u, w, 3'd3, sr, sz, 0, 1'b0);
            u.ld = 1'b1;
            u.b_sel = rd68041_pkg::S_MEM;
            u.wr = 1'b1; u.wr_reg = 5'd16;
            u.last = 1'b0; more = 1'b1;
          end else begin
            u = put_ea(u, w, 3'd3, dr, sz, 0, 1'b0);
            u.ld = 1'b1;
            u.a_reg = 5'd16;
            u.b_sel = rd68041_pkg::S_MEM;
            u.op = rd68041_pkg::OP_CMP; u.cc = rd68041_pkg::CC_CMP;
          end
        end else begin
          need = ea_len(sm, sr, sz, ew(w, 0)); pop = need;
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
            // ADDA, SUBA, CMPA.
            u = src_ea(u, w, sm, sr, sz, 0, 1'b1);
            u.a_sxw = (om == 3'd3);
            u.b_reg = an_r;
            if (op[15:12] == 4'b1011) begin
              u.op = rd68041_pkg::OP_CMP; u.cc = rd68041_pkg::CC_CMP;
              u.sz = rd68041_pkg::SZ_L;      // PRM 4: compared at 32 bits, the word extended
            end else begin
              u.op = (op[15:12] == 4'b1101) ? rd68041_pkg::OP_ADDA : rd68041_pkg::OP_SUBA;
              u.cc = rd68041_pkg::CC_NONE;
              u.wr = 1'b1; u.wr_reg = an_r;
            end
          end else if (!om[2]) begin
            // <ea> op Dn -> Dn (CMP: flags only). An as a source is word or long.
            if ((op[15:12] == 4'b1000 || op[15:12] == 4'b1100) && sm == 3'd1) bad = 1'b1;
            if (sm == 3'd1 && sz == rd68041_pkg::SZ_B) bad = 1'b1;
            u = src_ea(u, w, sm, sr, sz, 0, 1'b1);
            u.b_reg = dn;
            if (op[15:12] != 4'b1011) begin
              u.wr = 1'b1; u.wr_reg = dn; u.wr_sz = sz;
            end
          end else begin
            // Dn op <ea> -> <ea>; EOR's register form is EOR Dn,Dm.
            u.a_reg = dn;
            if (op[15:12] == 4'b1011 && sm == 3'd0) begin
              u.b_reg = dy;
              u.wr = 1'b1; u.wr_reg = dy; u.wr_sz = sz;
            end else if (sm <= 3'd1 || !malt(sm, sr)) begin
              bad = 1'b1;
            end else begin
              u = src_ea(u, w, sm, sr, sz, 0, 1'b0);
              u.st = 1'b1;
            end
          end
        end
      end

      // =======================================================================
      // 1110: the shifts and rotates (bit fields: M7, part 2)
      // =======================================================================
      4'b1110: begin
        if (op[7:6] == 2'b11) begin
          if (op[11]) begin
            // The bit fields (PRM 4): <ea>{offset:width}, both from the
            // extension word or from data registers. The width and offset
            // into T3 (and, for memory, the field's byte address into T0);
            // for memory, the five bytes read into T1 and T2; the operation;
            // for memory and a modifying one, the five bytes written back.
            logic [15:0] x;
            logic [2:0]  t;
            logic        rg, md, mm;
            x  = ew(w, 0);
            t  = op[10:8];              // 0 TST 1 EXTU 2 CHG 3 EXTS 4 CLR 5 FFO 6 SET 7 INS
            rg = (sm == 3'd0);
            md = (t == 3'd2) || (t == 3'd4) || (t == 3'd6) || (t == 3'd7);
            mm = md && !rg;
            if (!(rg || (md ? (ctrl(sm, sr) && malt(sm, sr)) : ctrl(sm, sr)))) bad = 1'b1;
            if (x[15]) bad = 1'b1;
            need  = 4'd1 + ea_len(sm, sr, rd68041_pkg::SZ_L, ew(w, 1));
            u.len = 5'(2 + 2*need);
            u.sz  = rd68041_pkg::SZ_L;
            more  = rg ? (sq == 5'd0) : (sq != (mm ? 5'd5 : 5'd3));
            u.last = !more;
            if (!more) pop = need;
            if (sq == 5'd0) begin
              // The parameters, and for memory the address.
              if (x[11]) u.a_reg = dreg(x[8:6]);
              else begin u.a_sel = rd68041_pkg::S_IMM; u.imm = {27'h0, x[10:6]}; end
              if (x[5])  u.b_reg = dreg(x[2:0]);
              else begin u.b_sel = rd68041_pkg::S_IMM; u.imm[15:8] = {3'h0, x[4:0]}; end
              u.fn = {2'b00, x[11], x[5]};
              u.op = rd68041_pkg::OP_BFPRM;
              u.wr = 1'b1; u.wr_reg = 5'd19;
              if (!rg) begin
                u = put_ea(u, w, sm, sr, rd68041_pkg::SZ_L, 1, 1'b0);
                u.wr2 = 1'b1; u.wr2_reg = 5'd16;
              end
            end else if (!rg && (sq == 5'd1 || sq == 5'd2)) begin
              // The five bytes: a long word, then the fifth with the
              // parameters beside it.
              u.ea_en = 1'b1; u.ea_base = rd68041_pkg::B_REG; u.ea_reg = 5'd16;
              u.ld = 1'b1;
              u.b_sel = rd68041_pkg::S_MEM;
              if (sq == 5'd1) begin
                u.wr = 1'b1; u.wr_reg = 5'd17;
              end else begin
                u.ea_disp = 32'd4; u.sz = rd68041_pkg::SZ_B;
                u.a_reg = 5'd19;
                u.op = rd68041_pkg::OP_BFPK;
                u.wr = 1'b1; u.wr_reg = 5'd18;
              end
            end else if (rg ? (sq == 5'd1) : (sq == 5'd3)) begin
              // The operation. A: what BFINS inserts, or BFFFO's offset; B:
              // the register or the first four bytes; C: the parameters (and
              // the fifth byte).
              if (t == 3'd5) begin
                if (x[11]) u.a_reg = dreg(x[8:6]);
                else begin u.a_sel = rd68041_pkg::S_IMM; u.imm = {27'h0, x[10:6]}; end
              end else begin
                u.a_reg = dreg(x[14:12]);
              end
              u.b_reg   = rg ? dy : 5'd17;
              u.wr2_reg = rg ? 5'd19 : 5'd18;
              u.op = rd68041_pkg::OP_BF;
              u.fn = {rg, t};
              u.cc = rd68041_pkg::CC_SET; u.cond = 4'hF;       // set by the operation
              if (t == 3'd1 || t == 3'd3 || t == 3'd5) begin
                u.wr = 1'b1; u.wr_reg = dreg(x[14:12]);
              end else if (md) begin
                u.wr = 1'b1; u.wr_reg = rg ? dy : 5'd17;
                if (!rg) begin u.wr2 = 1'b1; end
              end
            end else begin
              // Memory, modified: written back, a long word and a byte.
              u.ea_en = 1'b1; u.ea_base = rd68041_pkg::B_REG; u.ea_reg = 5'd16;
              u.st = 1'b1;
              if (sq == 5'd4) begin
                u.b_reg = 5'd17;
              end else begin
                u.ea_disp = 32'd4; u.sz = rd68041_pkg::SZ_B;
                u.b_reg = 5'd18;
              end
            end
          end else begin
            // A memory word, by one (PRM 4).
            if (!malt(sm, sr)) bad = 1'b1;
            need = ea_len(sm, sr, rd68041_pkg::SZ_W, ew(w, 0)); pop = need;
            u.len = 5'(2 + 2*need);
            u.sz = rd68041_pkg::SZ_W;
            u = src_ea(u, w, sm, sr, rd68041_pkg::SZ_W, 0, 1'b0);
            u.st = 1'b1;
            u.a_sel = rd68041_pkg::S_IMM; u.imm = 32'd1;
            u.op = rd68041_pkg::OP_SHIFT;
            u.fn = {1'b0, op[8], op[10:9]};
          end
        end else begin
          // A data register, by an immediate 1-8 or by Dx mod 64.
          u.len = 5'd2;
          u.sz = op[7:6];
          u.b_reg = dy;
          if (op[5]) begin
            u.a_reg = dn;
          end else begin
            u.a_sel = rd68041_pkg::S_IMM;
            u.imm = (op[11:9] == 3'd0) ? 32'd8 : {29'h0, op[11:9]};
          end
          u.op = rd68041_pkg::OP_SHIFT;
          u.fn = {1'b0, op[8], op[4:3]};
          u.wr = 1'b1; u.wr_reg = dy; u.wr_sz = u.sz;
        end
      end

      // 1010 and 1111: the A- and F-line (M8; the FPU's at M11).
      default: bad = 1'b1;
    endcase

    // The indirection prelude of an instruction whose <ea> is op[5:0]: its
    // first micro-operation reads the pointer into T3, and the instruction's
    // own follow (doc/microarch.md). It takes no extension word: the second
    // address needs them.
    if (uses_ea && seq == 5'd0 && sm >= 3'd2 && is_ind(sm, sr, ew(w, int'(eak)))) begin
      u = ind_uop(u, w, sm, sr, int'(eak));
      ind_out = 2'b01;
      pop  = 4'd0;
      more = 1'b1;
      mv_used = 1'b0;
    end

    // After the first micro-operation the instruction's extension words may
    // be gone from the queue, and with them what its length was computed from.
    if (seq != 5'd0) u.len = len_in;

    // put_ea marks an <ea> not built yet (the full extension-word format) with
    // halt. `need` is kept: whether an instruction is built can depend on its
    // extension words (MOVEC's register field, the full format's bit 8), so
    // it is decided only once they are all in the queue.
    if (bad || u.halt) begin
      u = '0;
      u.valid = 1'b1;
      u.last  = 1'b1;
      u.halt  = 1'b1;
      u.pc    = pc;
      pop     =  4'd0;
      more    = 1'b0;
      mv_used = 1'b0;
    end
  end

  assign uop = u;

endmodule
