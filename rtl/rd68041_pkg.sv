// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- SystemVerilog MC68040
//
// Architectural constants transcribed from the manual, each with its citation.
// Written down once, here; a module that needs one refers to it by its full scope
// (doc/coding-standard.md: there is no portable `import`).

package rd68041_pkg;

  // UM 5.3.1, Table 5-2: transfer type, TT1-TT0.
  localparam logic [1:0] TT_NORMAL = 2'b00;
  localparam logic [1:0] TT_MOVE16 = 2'b01;
  localparam logic [1:0] TT_ALTFC  = 2'b10;  // alternate logical function code
  localparam logic [1:0] TT_ACK    = 2'b11;  // interrupt and breakpoint acknowledge

  // UM 5.3.2, Table 5-3: transfer modifier, TM2-TM0, for normal and MOVE16
  // accesses. MOVE16 uses only the two data encodings.
  localparam logic [2:0] TM_PUSH      = 3'b000;  // data cache push
  localparam logic [2:0] TM_USER_DATA = 3'b001;
  localparam logic [2:0] TM_USER_CODE = 3'b010;
  localparam logic [2:0] TM_TBL_DATA  = 3'b011;  // MMU table search, data
  localparam logic [2:0] TM_TBL_CODE  = 3'b100;  // MMU table search, code
  localparam logic [2:0] TM_SUP_DATA  = 3'b101;
  localparam logic [2:0] TM_SUP_CODE  = 3'b110;

  // UM 7: transfer size, SIZ1-SIZ0. There is no dynamic bus sizing on the
  // MC68040; a line is four long words, by burst or, with TBI, one at a time.
  localparam logic [1:0] SIZ_LONG = 2'b00;
  localparam logic [1:0] SIZ_BYTE = 2'b01;
  localparam logic [1:0] SIZ_WORD = 2'b10;
  localparam logic [1:0] SIZ_LINE = 2'b11;

  // UM 5.9.1, Table 5-6: processor status, PST3-PST0. Stubbed (doc/pinout.md);
  // the encodings are kept for when it is not.
  localparam logic [3:0] PST_USER_RUN = 4'h0;  // user, start/continue current instruction
  localparam logic [3:0] PST_SUP_RUN  = 4'h8;  // supervisor, start/continue

  // ===========================================================================
  // The micro-operation: what decode issues and every later stage carries
  // (doc/microarch.md, "Micro-operations"). One a clock; an instruction is one
  // or more, the last with `last` set.
  // ===========================================================================

  // Where EA's base comes from.
  localparam logic [1:0] B_NONE = 2'd0;   // zero: absolute, immediate, register direct
  localparam logic [1:0] B_AN   = 2'd1;   // address register ea_an
  localparam logic [1:0] B_PC   = 2'd2;   // the instruction's address (disp folded, PRM 2.2.11)
  localparam logic [1:0] B_REG  = 2'd3;   // any register, a_reg (a temporary holding an address)

  // An update in EA.
  localparam logic [1:0] U_NONE = 2'd0;
  localparam logic [1:0] U_POST = 2'd1;   // (An)+: the address is An, An becomes An + step
  localparam logic [1:0] U_PRE  = 2'd2;   // -(An): An becomes An - step, which is the address

  // An EX operand.
  localparam logic [1:0] S_REG  = 2'd0;
  localparam logic [1:0] S_IMM  = 2'd1;
  localparam logic [1:0] S_MEM  = 2'd2;   // the operand OF loaded
  localparam logic [1:0] S_EA   = 2'd3;   // the effective address itself

  // Operation sizes, as everywhere below.
  localparam logic [1:0] SZ_B = 2'd0;
  localparam logic [1:0] SZ_W = 2'd1;
  localparam logic [1:0] SZ_L = 2'd2;

  // EX operations: the result from A (the register or immediate side) and B
  // (the memory, register or immediate side).
  localparam logic [4:0] OP_PASSB = 5'd0;   // MOVE, MOVEA, LEA, MOVEQ: B
  localparam logic [4:0] OP_ADD   = 5'd1;   // B + A
  localparam logic [4:0] OP_SUB   = 5'd2;   // B - A
  localparam logic [4:0] OP_AND   = 5'd3;
  localparam logic [4:0] OP_OR    = 5'd4;
  localparam logic [4:0] OP_EOR   = 5'd5;
  localparam logic [4:0] OP_CMP   = 5'd6;   // B - A, flags only
  localparam logic [4:0] OP_EXTW  = 5'd7;   // B's byte sign-extended to a word
  localparam logic [4:0] OP_EXTL  = 5'd8;   // B's word sign-extended to a long
  localparam logic [4:0] OP_EXTBL = 5'd9;   // B's byte sign-extended to a long
  localparam logic [4:0] OP_SWAP  = 5'd10;
  localparam logic [4:0] OP_CLR   = 5'd11;  // zero
  localparam logic [4:0] OP_PASSA = 5'd12;  // A (a store of a register)
  localparam logic [4:0] OP_ADDA  = 5'd13;  // B + A at 32 bits, no flags (ADDA, SUBQ to An...)
  localparam logic [4:0] OP_SUBA  = 5'd14;
  localparam logic [4:0] OP_CCR   = 5'd15;  // ANDI/ORI/EORI to CCR: CCR op= the immediate

  // How the condition codes are set (PRM 3.4, Table 3-18).
  localparam logic [2:0] CC_NONE  = 3'd0;
  localparam logic [2:0] CC_LOGIC = 3'd1;   // N, Z from the result; V, C cleared; X kept
  localparam logic [2:0] CC_ADD   = 3'd2;   // X N Z V C of an add
  localparam logic [2:0] CC_SUB   = 3'd3;   // X N Z V C of a subtract
  localparam logic [2:0] CC_CMP   = 3'd4;   // N Z V C of a subtract, X kept
  localparam logic [2:0] CC_SET   = 3'd5;   // the CCR operations

  // A control transfer, resolved in EX.
  localparam logic [1:0] BR_NONE = 2'd0;
  localparam logic [1:0] BR_DISP = 2'd1;    // to pc + 2 + imm, if cond holds (Bcc, BRA, BSR)
  localparam logic [1:0] BR_EA   = 2'd2;    // to B: the effective address (JMP), or a temporary (JSR)
  localparam logic [1:0] BR_MEM  = 2'd3;    // to the long word OF loaded (RTS)

  typedef struct packed {
    logic        valid;
    logic        last;       // the instruction's last micro-operation
    logic        halt;       // stop the pipeline here (an instruction not built yet, M6)
    logic [31:0] pc;         // the instruction's address
    logic  [4:0] len;        // the instruction's length in bytes
    // <ea> calculate
    logic        ea_en;
    logic  [1:0] ea_base;
    logic  [2:0] ea_an;
    logic        ea_xen;     // an index register
    logic  [3:0] ea_xn;
    logic        ea_xl;      // the index is long (else its low word, sign-extended)
    logic  [1:0] ea_scale;
    logic [31:0] ea_disp;
    logic  [1:0] ea_upd;
    logic  [2:0] ea_step;
    // <ea> fetch and write-back
    logic        ld;
    logic        st;
    logic  [1:0] sz;
    // execute
    logic  [1:0] a_sel;
    logic  [4:0] a_reg;      // 0-7 D, 8-15 A, 16-19 temporaries
    logic  [1:0] b_sel;
    logic  [4:0] b_reg;
    logic        a_sxw;      // A is a word, sign-extended to a long first (ADDA.W, CMPA.W)
    logic        b_sxw;      // B likewise (MOVEA.W)
    logic [31:0] imm;
    logic  [4:0] op;
    logic  [2:0] cc;
    logic  [3:0] cond;       // Bcc's condition (PRM Table 3-19); 0 = true
    logic  [1:0] br;
    logic [31:0] tgt;        // BR_DISP's target, computed in decode
    // the register result
    logic        wr;
    logic  [4:0] wr_reg;
    logic  [1:0] wr_sz;      // the size written: an address register is always long
  } uop_t;

  // Its width, written out: yosys has no $bits of a type. 40 (valid, last, halt,
  // pc, len) + 51 (the <ea>) + 4 (ld, st, sz) + 94 (execute) + 8 (the result).
  // sim/tb/core_*_tb check it against $bits.
  localparam int UOP_W = 197;

endpackage
