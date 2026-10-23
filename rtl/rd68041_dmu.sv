// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- SystemVerilog MC68040
//
// The data memory unit: the integer unit's operand reads (from OF) and writes
// (from W), and the data cache (UM 4).
//
// Writes go into a queue of three, oldest first, because the write-back stage
// may not wait (UM 2.1: the write-back "can stall indefinitely until either
// the data memory unit is free"). A read is let past them -- UM 7.7: "data read
// and write accesses [may] occur out of order" -- unless it touches a long word
// one of them writes, in which case the writes go first; or unless its page is
// serialised (UM 4.3.2), when they all do. The three are the access error
// frame's WB3-WB1 (doc/checkpoint.md) once the MMU gives them their separate
// stages (M10).
//
// An access's cache mode comes from DTT0/DTT1 (rd68041_attr; until M10 the
// rest is cachable write-through). With the cache enabled (CACR's DE):
//
//   - a read in one half-line that hits is answered on the clock after it is
//     asked: the cache's port A is addressed with the address <ea> fetch will
//     hold next (ld_pre), and the tags compared on the clock it does;
//   - everything else goes a piece at a time -- each piece aligned within a
//     long word, as UM 7.3 and Table 7-3 split an operand for the bus -- through
//     the state machine below:
//       a cachable piece is looked up (its half-line read on port B, then the
//       tags compared); a hit is read from, or written into, the cache, a
//       copyback write setting the long word's D bit (UM 4.4.4) and a
//       write-through one going to the bus as well; a read miss, and a write
//       miss to a copyback page, allocate the line (UM 4.4.1, 4.4.2): the way
//       that is invalid or the one the replacement counter names (UM 4.1),
//       pushed first if it is dirty (below), filled by a line read the long
//       word wanted first, and made valid unless the slave said TCI or a
//       transfer faulted -- then the piece is looked up again, or, if the line
//       did not become valid, taken from the line read buffer (a read) or
//       written through (a write; UM 4.6.1);
//       a write miss to a write-through page goes to the bus alone;
//       exception processing's reads and writes, and MOVE16's (M9, part 3),
//       never allocate (UM 4.3.3);
//       a cache-inhibited piece (CM 1x), a locked one (UM 7.4.5: "a
//       read-modify-write operation is treated as noncachable"), a MOVES and
//       an acknowledge cycle go to the bus, after a matching line has been
//       pushed if dirty and invalidated (UM 4.3.2) -- not an acknowledge.
//   - a push (UM 4.6.2) copies the line into the push buffer, writes the dirty
//     long word alone (SIZ long) or the whole line (SIZ line), TM 000, and then
//     invalidates the line. Here the push goes before the fill that needs the
//     way, not after it (doc/divergences.md). While it waits for the bus, the
//     line stays valid and dirty in the cache, where the snooper finds it; a
//     snooped write sunk into it is copied into the buffer too, and a snoop
//     that invalidates it cancels the push (Table 4-4, D10, D11, D13).
//   - CINV and CPUSH (dc_op; UM 4.2): every line at once (CINVA), the line, or
//     a walk of the 256 lines for a page or (CPUSHA) everything, pushing a
//     dirty one first when it is CPUSH.
//
// The snooper (rd68041_snoop) has the cache's second port, its tags and its
// dirty bits first, whenever it uses them (sn_rd, sn_wr, sn_dinv): what the
// state machine wanted from them that clock waits. A snoop happens only while
// another master has the bus, so never during a fill or a push on the bus.

module rd68041_dmu (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          crst,
    input  logic          sup,       // supervisor data space (TM 101), else user (001)
    input  logic  [2:0]   sfc,       // MOVES's spaces (UM 7.4, Table 5-4)
    input  logic  [2:0]   dfc,
    input  logic          de,        // CACR's DE
    input  logic [31:0]   dtt0,
    input  logic [31:0]   dtt1,

    // A read, from OF: held until done.
    input  logic          ld_valid,
    input  logic [31:0]   ld_addr,
    input  logic [31:0]   ld_pre,      // the address OF will hold next (port A's)
    input  logic  [1:0]   ld_sz,       // rd68041_pkg::SZ_*
    output logic          ld_done,     // one clock, with the data
    output logic [31:0]   ld_data,     // right justified, zero extended
    output logic          ld_err,
    input  logic          ld_cancel,   // the read is no longer wanted: finish it silently
    input  logic          ld_lock,     // a locked read (UM 7.4.5)
    input  logic          ld_alt,      // in SFC's space
    input  logic          ld_ack,      // an acknowledge cycle (TT 11; UM 7.5) ...
    input  logic  [2:0]   ld_tm,       // ... with this TM
    output logic          ld_avec,     // ... ended with AVEC (with ld_done)
    input  logic          ld_noalloc,  // a miss does not allocate (exception processing)
    input  logic          ld_m16,      // MOVE16's read: the line, into the MOVE16 buffer

    // A write, from W.
    input  logic          st_valid,
    input  logic [31:0]   st_addr,
    input  logic  [1:0]   st_sz,
    input  logic [31:0]   st_data,     // right justified
    input  logic          st_lock,     // a locked write
    input  logic          st_locke,    // ... the sequence's last
    input  logic          st_alt,      // in DFC's space
    input  logic          st_noalloc,
    input  logic          st_m16,      // MOVE16's write: the line, from the buffer
    output logic          st_ready,    // taken this clock
    output logic          st_empty,    // nothing waiting
    output logic          lock_open,   // a locked sequence is under way

    // CINV and CPUSH of the data cache: one clock; busy until done.
    input  logic          dc_op,
    input  logic  [1:0]   dc_scope,    // 01 a line, 10 a page, 11 all
    input  logic          dc_push,     // CPUSH: dirty lines are pushed first
    input  logic [31:0]   dc_addr,
    input  logic          dc_p8k,      // TC's P: 8 KB pages
    output logic          dc_busy,

    // The bus, through the arbiter.
    output logic          d_valid,
    input  logic          d_ready,
    output logic [31:0]   d_addr,
    output logic          d_write,
    output logic  [1:0]   d_siz,
    output logic  [1:0]   d_tt,
    output logic  [2:0]   d_tm,
    output logic  [1:0]   d_tln,
    output logic  [1:0]   d_upa,
    output logic          d_ci,
    output logic          d_lock,
    output logic          d_locke,
    output logic [127:0]  d_wdata,     // a line's long word k at [32k+31:32k]
    input  logic          d_rsp,
    input  logic  [1:0]   d_lw,
    input  logic [31:0]   d_data,
    input  logic          d_tci,
    input  logic          d_done,
    input  logic          d_err,
    input  logic          d_avec,

    // The snooper.
    input  logic [31:0]   sn_addr,
    input  logic          sn_rd,       // it reads the line's long word at sn_addr (port B)
    output logic          sn_dhit,
    output logic          sn_ddirty,
    output logic [31:0]   sn_rdata,
    input  logic          sn_wr,
    input  logic  [3:0]   sn_wbe,
    input  logic [31:0]   sn_wdata,
    input  logic          sn_dinv
);

  // ===========================================================================
  // The write queue
  // ===========================================================================
  logic [31:0] qa [0:2];
  logic  [1:0] qs [0:2];
  logic [31:0] qd [0:2];
  logic  [4:0] qf [0:2];         // per write: MOVE16, lock, locke, alternate, no-allocate
  logic  [1:0] qn;               // writes held

  // The bytes an operand of size sz occupies.
  function automatic logic [2:0] nbytes(input logic [1:0] sz);
    nbytes = (sz == rd68041_pkg::SZ_B) ? 3'd1 : (sz == rd68041_pkg::SZ_W) ? 3'd2 : 3'd4;
  endfunction
  function automatic logic overlap(input logic [31:0] a0, input logic [1:0] s0,
                                   input logic [31:0] a1, input logic [1:0] s1);
    logic [31:2] e0, e1;
    // The last long word each touches; the two overlap if they touch a common
    // long word.
    e0 = a0[31:2] + {29'h0, ({1'b0, a0[1:0]} + nbytes(s0)) > 3'd4};
    e1 = a1[31:2] + {29'h0, ({1'b0, a1[1:0]} + nbytes(s1)) > 3'd4};
    overlap = !((e0 < a1[31:2]) || (e1 < a0[31:2]));
  endfunction

  // A MOVE16 write covers its line.
  function automatic logic q_hit(input logic [31:0] a, input logic [1:0] sz,
                                 input logic [31:0] qa_i, input logic [1:0] qs_i,
                                 input logic m);
    q_hit = m ? (a[31:4] == qa_i[31:4]) : overlap(a, sz, qa_i, qs_i);
  endfunction
  wire hit0 = (qn > 2'd0) && q_hit(ld_addr, ld_sz, qa[0], qs[0], qf[0][4]);
  wire hit1 = (qn > 2'd1) && q_hit(ld_addr, ld_sz, qa[1], qs[1], qf[1][4]);
  wire hit2 = (qn > 2'd2) && q_hit(ld_addr, ld_sz, qa[2], qs[2], qf[2][4]);

  // ===========================================================================
  // Attributes
  // ===========================================================================
  // The read asked for, and the piece under way: each from DTT0/DTT1, in the
  // space each is in (a MOVES's is SFC's or DFC's, whose bit 2 is S).
  logic [1:0] la_cm, x_cm, x_upa, la_upa;
  logic       la_wp, la_tt, x_wp, x_tt;
  logic [31:0] xa;               // the next byte's address
  logic        xsup;             // ... in the supervisor space
  rd68041_attr u_attr_ld (
      .addr(ld_addr[31:24]), .sup(ld_alt ? sfc[2] : sup), .ttr0(dtt0), .ttr1(dtt1),
      .cm(la_cm), .upa(la_upa), .wp(la_wp), .tt(la_tt));
  rd68041_attr u_attr_x (
      .addr(xa[31:24]), .sup(xsup), .ttr0(dtt0), .ttr1(dtt1),
      .cm(x_cm), .upa(x_upa), .wp(x_wp), .tt(x_tt));

  // ===========================================================================
  // The cache
  // ===========================================================================
  logic          p0_hit, p1_hit, p2_valid;
  logic   [1:0]  p0_way, p1_way, p2_way;
  logic   [3:0]  p0_dirty, p1_dirty, p2_dirty, p0_valid;
  logic  [31:10] p0_ptag, p2_tag;
  logic   [5:0]  p0_set, p2_set;
  logic          t_we, t_valid, d_we, inv_all;
  logic   [5:0]  t_set, d_set;
  logic   [1:0]  t_way, d_way;
  logic  [31:10] t_tag;
  logic   [3:0]  d_bits;
  logic   [6:0]  a_addr, b_addr;
  logic   [1:0]  b_way;
  logic   [7:0]  b_we;
  logic  [63:0]  b_wdata;
  logic [255:0]  a_rdata, b_rdata;

  rd68041_cache_arr #(.DIRTY(1'b1)) u_arr (
      .clk(clk), .rst_n(rst_n), .crst(crst),
      .p0_set(p0_set), .p0_ptag(p0_ptag), .p0_hit(p0_hit), .p0_way(p0_way),
      .p0_dirty(p0_dirty), .p0_valid(p0_valid),
      .p1_set(sn_addr[9:4]), .p1_ptag(sn_addr[31:10]), .p1_hit(p1_hit), .p1_way(p1_way),
      .p1_dirty(p1_dirty),
      .p2_set(p2_set), .p2_way(p2_way), .p2_tag(p2_tag), .p2_valid(p2_valid),
      .p2_dirty(p2_dirty),
      .t_we(t_we), .t_set(t_set), .t_way(t_way), .t_tag(t_tag), .t_valid(t_valid),
      .d_we(d_we), .d_set(d_set), .d_way(d_way), .d_bits(d_bits), .inv_all(inv_all),
      .a_addr(a_addr), .a_rdata(a_rdata),
      .b_addr(b_addr), .b_way(b_way), .b_we(b_we), .b_wdata(b_wdata), .b_rdata(b_rdata));

  // ===========================================================================
  // The state machine
  // ===========================================================================
  //   X_IDLE   nothing under way: a read that hits is answered from here
  //   X_RD     a piece's half-line is being read on port B
  //   X_LOOK   ... and its tags compared: hit, miss, or the bus
  //   X_BUS    a piece on the bus
  //   X_VRD0   a line to push: its first half-line read; X_VRD1 its second
  //   X_PUSH   the push on the bus
  //   X_VINV   a line made invalid (a victim, or CINV, or before a bypass)
  //   X_FILL   a line read
  //   X_CMO    CINV and CPUSH walking the lines
  //   X_M16L   MOVE16's read: the line looked up; X_M16H0 and X_M16H1 its
  //            half-lines from the cache, or X_M16B the line from the bus
  //   X_M16I   MOVE16's write: a line the cache has is invalidated (UM 4.3.3);
  //            X_M16W the line on the bus
  typedef enum logic [4:0] { X_IDLE, X_RD, X_LOOK, X_BUS, X_VRD0, X_VRD1, X_VRD2, X_PUSH,
                             X_VINV, X_FILL, X_CMO, X_M16L, X_M16H0, X_M16H1, X_M16B,
                             X_M16I, X_M16W } x_e;
  logic [127:0] mb;              // the MOVE16 buffer, long word k at [32k+31:32k]
  logic         xm16;            // the operation is MOVE16's
  x_e          x;
  logic        xld;              // the operation is a read (else a write)
  logic  [2:0] xn;               // bytes still to move
  logic [31:0] xd;               // the write's data, or the read's so far
  logic        xbusy;            // a transfer of it is on the bus
  logic        xerr;
  logic        xcancel;          // the read under way was cancelled
  logic        xlk, xlke, xalt;  // locked, its last, in SFC's or DFC's space
  logic        xack;             // an acknowledge cycle, with TM xtm
  logic  [2:0] xtm;
  logic        xna;              // does not allocate
  logic  [2:0] cur_n;            // the bytes of the transfer on the bus
  logic  [1:0] cur_siz;
  logic  [1:0] cur_a10;

  // The line being pushed, invalidated or filled.
  logic  [5:0] vset;
  logic  [1:0] vway;
  logic [31:10] vtag;
  logic  [3:0] vdirty;
  logic        vfill;            // after it, a fill (else back to the piece, or CMO)
  logic [127:0] pb;              // the push buffer, long word k at [32k+31:32k]
  logic [127:0] lb;              // the line read buffer
  logic        ftci, ferr, fe0;  // the fill was cache-inhibited, faulted, on its first

  // CINV and CPUSH.
  logic  [1:0] cscope;
  logic        cpush, cp8k;
  logic [31:0] caddr;
  logic  [7:0] ck;               // the walk: set and way
  logic        cmo_on;
  logic        cmo_req;          // dc_op came, and has not started yet
  assign dc_busy = cmo_on || cmo_req;

  logic  [1:0] rnd;              // the replacement counter (UM 4.1)

  // The next piece: a long word if aligned and four remain, else a word if
  // even and two remain, else a byte (UM Table 7-3).
  wire [1:0] t_siz = (xa[1:0] == 2'b00 && xn >= 3'd4) ? rd68041_pkg::SIZ_LONG :
                     (xa[0] == 1'b0 && xn >= 3'd2)    ? rd68041_pkg::SIZ_WORD :
                                                        rd68041_pkg::SIZ_BYTE;
  wire [2:0] t_n   = (t_siz == rd68041_pkg::SIZ_LONG) ? 3'd4 :
                     (t_siz == rd68041_pkg::SIZ_WORD) ? 3'd2 : 3'd1;

  // A write's bytes: xd right justified; the piece takes the next t_n of them
  // from the most significant end still unsent.
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

  // Table 7-1: where those bytes go on D31-D0, and back.
  function automatic logic [31:0] to_lanes(input logic [31:0] v, input logic [1:0] siz);
    case (siz)
      rd68041_pkg::SIZ_BYTE: to_lanes = {4{v[7:0]}};
      rd68041_pkg::SIZ_WORD: to_lanes = {2{v[15:0]}};
      default:               to_lanes = v;
    endcase
  endfunction
  function automatic logic [31:0] from_lanes(input logic [31:0] d, input logic [1:0] siz,
                                             input logic [1:0] a10);
    case (siz)
      rd68041_pkg::SIZ_BYTE: from_lanes = {24'h0, d[31 - 8*a10 -: 8]};
      rd68041_pkg::SIZ_WORD: from_lanes = {16'h0, a10[1] ? d[15:0] : d[31:16]};
      default:               from_lanes = d;
    endcase
  endfunction

  // The piece's bytes in a half-line, and the half-line's byte enables for them.
  function automatic logic [63:0] hl_place(input logic [31:0] v, input logic [2:0] off,
                                           input logic [2:0] n);
    hl_place = {32'h0, v} << (8 * (8 - int'(off) - int'(n)));
  endfunction
  function automatic logic [7:0] hl_be(input logic [2:0] off, input logic [2:0] n);
    logic [7:0] m;
    m = (n == 3'd4) ? 8'h0F : (n == 3'd2) ? 8'h03 : 8'h01;
    hl_be = m << (8 - int'(off) - int'(n));
  endfunction
  function automatic logic [31:0] hl_take(input logic [63:0] h, input logic [2:0] off,
                                          input logic [2:0] n);
    logic [31:0] v;
    v = 32'(h >> (8 * (8 - int'(off) - int'(n))));
    case (n)
      3'd1:    hl_take = {24'h0, v[7:0]};
      3'd2:    hl_take = {16'h0, v[15:0]};
      default: hl_take = v;
    endcase
  endfunction

  // --- the piece's mode ----------------------------------------------------------
  // Cachable: the cache enabled, the mode 0x, and not locked, alternate or an
  // acknowledge. A bypass of a mode that is not: the matching line pushed or
  // invalidated first (not for an acknowledge, which is not memory).
  wire x_cach  = de && !x_cm[1] && !xlk && !xalt && !xack;
  wire x_byp   = de && !x_cach && !xack;
  wire x_cb    = (x_cm == 2'b01);
  wire x_alloc = !xna && (xld || x_cb);

  // --- the snooper's claims, this clock ------------------------------------------
  wire sn_b = sn_rd || sn_wr;            // port B
  wire sn_t = sn_dinv;                   // the tag port
  wire sn_d = sn_wr;                     // the dirty bits

  // --- the read asked for, from port A -----------------------------------------
  // Port A reads, on each edge, the half-line ld_pre is in: on the clock <ea>
  // fetch holds a read, its half-line is out -- unless port B wrote that
  // half-line on the edge it was read (the read is then undefined).
  logic  [6:0] a_q;              // what port A read on the last edge
  logic        bw_q;             // port B wrote it then
  logic  [6:0] bw_a;
  wire  [2:0] ld_n   = nbytes(ld_sz);
  wire        ld_in1 = ({1'b0, ld_addr[2:0]} + {1'b0, ld_n}) <= 4'd8;
  wire        a_ok   = (a_q == ld_addr[9:3]) && !(bw_q && bw_a == a_q);
  wire        ld_cach = de && !la_cm[1] && !ld_lock && !ld_alt && !ld_ack && !ld_m16;
  wire        ld_req = ld_valid && !ld_done && !ld_cancel && !(hit0 || hit1 || hit2) &&
                       !(la_cm == 2'b10 && qn != 2'd0);
  // The fast read: in the state machine's rest, its tags on port 0.
  wire        fast   = (x == X_IDLE) && ld_req && ld_cach && ld_in1 && a_ok && p0_hit;
  wire [63:0] a_hl   = a_rdata[64*p0_way +: 64];

  // A read starts on the state machine when nothing is under way, nothing it
  // reads is waiting to be written, and it is not the fast one. A locked
  // sequence: its first read waits for the queue to empty, and while it is
  // open nothing unlocked starts (UM 7.4.5: the transfers are indivisible).
  // MOVE16's read waits for every write: its buffer is free then.
  wire start_ld = (x == X_IDLE) && ld_req && !fast &&
                  ((ld_lock || ld_m16) ? (qn == 2'd0) : !lock_open) && !(ld_m16 && lock_open);
  wire start_st = (x == X_IDLE) && !start_ld && !fast && (qn != 2'd0) &&
                  (!lock_open || qf[0][3]);
  wire start_c  = (x == X_IDLE) && !ld_req && (qn == 2'd0) && cmo_req;

  assign st_ready = st_valid && (qn != 2'd3);

  // --- port 0: the fast read's tags in the rest, else the piece's or CMO's line --
  logic [31:0] p0_a;
  always_comb begin
    if (x == X_IDLE)     p0_a = ld_addr;
    else if (x == X_CMO) p0_a = caddr;
    else                 p0_a = xa;
  end
  assign p0_set  = p0_a[9:4];
  assign p0_ptag = p0_a[31:10];

  // Port 2: the line the walk or the victim choice looks at.
  function automatic logic [1:0] victim(input logic [3:0] v, input logic [1:0] r);
    victim = r;
    for (int w = 3; w >= 0; w--) if (!v[w]) victim = 2'(w);
  endfunction
  wire [1:0] pick = victim(p0_valid, rnd);
  assign p2_set = (x == X_CMO) ? ck[7:2] : xa[9:4];
  assign p2_way = (x == X_CMO) ? ck[1:0] : pick;
  wire  c_match = p2_valid && (cscope == 2'b11 ||
                  (cp8k ? (p2_tag[31:13] == caddr[31:13]) : (p2_tag[31:12] == caddr[31:12])));

  // --- the bus -------------------------------------------------------------------
  wire [31:0] w_long = st_bytes(xd, xn, t_n);
  // A push of one dirty long word is a long-word transfer, of more a line.
  function automatic logic [1:0] dirty_one(input logic [3:0] d);
    case (d)
      4'b0010: dirty_one = 2'd1;
      4'b0100: dirty_one = 2'd2;
      4'b1000: dirty_one = 2'd3;
      default: dirty_one = 2'd0;
    endcase
  endfunction
  wire        one_dirty = (vdirty == 4'b0001) || (vdirty == 4'b0010) ||
                          (vdirty == 4'b0100) || (vdirty == 4'b1000);
  wire  [1:0] one_k     = dirty_one(vdirty);

  always_comb begin
    d_valid = 1'b0; d_addr = xa; d_write = 1'b0; d_siz = t_siz;
    d_tt = rd68041_pkg::TT_NORMAL; d_tm = xsup ? rd68041_pkg::TM_SUP_DATA : rd68041_pkg::TM_USER_DATA;
    d_tln = 2'b00; d_upa = x_upa; d_ci = 1'b0; d_lock = xlk; d_locke = 1'b0;
    d_wdata = {96'h0, to_lanes(w_long, t_siz)};
    case (x)
      X_BUS: begin
        d_valid = !xbusy;
        d_write = !xld;
        // UM 5.3.2 and Table 5-4: an alternate function code access carries
        // the function code on TM; an acknowledge cycle its own TM (UM 7.5).
        if (xack) begin
          d_tt = rd68041_pkg::TT_ACK; d_tm = xtm;
        end else if (xalt) begin
          d_tt = rd68041_pkg::TT_ALTFC; d_tm = xld ? sfc : dfc;
        end
        d_ci = x_cm[1];
        // UM 7.4.5: LOCKE on the last write's last transfer.
        d_locke = xlke && (xn == t_n);
      end
      X_FILL: begin
        d_valid = !xbusy;
        d_addr  = {xa[31:2], 2'b00};
        d_siz   = rd68041_pkg::SIZ_LINE;
        d_tln   = vway;
      end
      X_M16B, X_M16W: begin
        // MOVE16: a line, TT 01, from the long word the address names
        // (PRM 4: "line transfers ... begin with the long word pointed to by
        // the effective address"), the burst wrapping in the line.
        d_valid = !xbusy;
        d_write = (x == X_M16W);
        d_addr  = {xa[31:2], 2'b00};
        d_siz   = rd68041_pkg::SIZ_LINE;
        d_tt    = rd68041_pkg::TT_MOVE16;
        d_ci    = x_cm[1];
        for (int k = 0; k < 4; k++)
          d_wdata[32*k +: 32] = mb[32*((int'(xa[3:2]) + k) % 4) +: 32];
      end
      X_PUSH: begin
        // UM 4.6.2: a push is TM 000; LOCK too if a locked access caused it.
        d_valid = !xbusy;
        d_write = 1'b1;
        d_tm    = rd68041_pkg::TM_PUSH;
        d_tln   = vway;
        d_upa   = 2'b00;
        d_locke = 1'b0;
        if (one_dirty) begin
          d_addr  = {vtag, vset, one_k, 2'b00};
          d_siz   = rd68041_pkg::SIZ_LONG;
          d_wdata = {96'h0, pb[32*one_k +: 32]};
        end else begin
          d_addr  = {vtag, vset, 4'h0};
          d_siz   = rd68041_pkg::SIZ_LINE;
          d_wdata = pb;
        end
      end
      default: ;
    endcase
  end

  // A read's bytes so far, and this transfer's added below them.
  wire [31:0] got   = from_lanes(d_data, cur_siz, cur_a10);
  wire [31:0] accum = (cur_n == 3'd4) ? got : ((xd << (8 * int'(cur_n))) | got);
  // ... or a piece's from the cache, or from the line read buffer.
  wire [63:0] b_hl  = b_rdata[64*p0_way +: 64];
  wire [31:0] c_got = hl_take(b_hl, xa[2:0], t_n);
  wire [63:0] lb_hl = xa[3] ? lb[63:0] : lb[127:64];
  wire [31:0] l_got = hl_take(lb_hl, xa[2:0], t_n);
  function automatic logic [31:0] acc_in(input logic [31:0] d, input logic [31:0] g,
                                         input logic [2:0] n);
    acc_in = (n == 3'd4) ? g : ((d << (8 * int'(n))) | g);
  endfunction

  // --- the ports, each clock -------------------------------------------------------
  // Port B: the snooper's, else the state machine's.
  // The snooper on the port, the dirty bits or the tags: a hit decided now
  // could be on a line it is invalidating -- the piece waits.
  wire       sn_any  = sn_b || sn_d || sn_t;
  wire       look_w  = (x == X_LOOK) && !xld && x_cach && p0_hit && !sn_any;
  wire       fill_w  = (x == X_FILL) && xbusy && d_rsp;
  always_comb begin
    b_addr = {xa[9:4], xa[3]}; b_way = p0_way; b_we = 8'h00; b_wdata = 64'h0;
    if (sn_b) begin
      b_addr = {sn_addr[9:4], sn_addr[3]}; b_way = p1_way;
      if (sn_wr) begin
        b_we    = sn_addr[2] ? {4'h0, sn_wbe} : {sn_wbe, 4'h0};
        b_wdata = {sn_wdata, sn_wdata};
      end
    end else if (look_w) begin
      b_we    = hl_be(xa[2:0], t_n);
      b_wdata = hl_place(w_long, xa[2:0], t_n);
    end else if (fill_w) begin
      b_addr  = {xa[9:4], d_lw[1]}; b_way = vway;
      b_we    = d_lw[0] ? 8'h0F : 8'hF0;
      b_wdata = {d_data, d_data};
    end else if (x == X_VRD0 || x == X_VRD1) begin
      b_addr  = {vset, (x == X_VRD1)}; b_way = vway;
    end else if (x == X_M16L || x == X_M16H0) begin
      b_addr  = {xa[9:4], (x == X_M16H0)};
    end
  end
  assign a_addr = ld_pre[9:3];

  // The snooper reads the long word it named on the clock before.
  logic [1:0] sn_way_q;
  logic       sn_lw_q;
  wire [63:0] sn_hl = b_rdata[64*sn_way_q +: 64];
  assign sn_rdata  = sn_lw_q ? sn_hl[31:0] : sn_hl[63:32];
  assign sn_dhit   = p1_hit;
  assign sn_ddirty = p1_hit && (p1_dirty != 4'b0000);

  // The tag port.
  wire m16_t   = (x == X_M16I) && de && p0_hit && !sn_t;
  wire vinv_t  = ((x == X_VINV) && !sn_t) || m16_t;
  wire fill_t  = (x == X_FILL) && xbusy && d_done && !d_err && !ferr && !ftci && !(fe0 && d_tci);
  wire fill_ok = fill_t;
  always_comb begin
    t_we = 1'b0; t_set = vset; t_way = vway; t_tag = vtag; t_valid = 1'b0;
    if (sn_t) begin
      t_we = p1_hit; t_set = sn_addr[9:4]; t_way = p1_way;
    end else if (m16_t) begin
      t_we = 1'b1; t_set = xa[9:4]; t_way = p0_way;
    end else if (vinv_t) begin
      t_we = 1'b1;
    end else if (fill_t) begin
      t_we = 1'b1; t_set = xa[9:4]; t_tag = xa[31:10]; t_valid = 1'b1;
    end
  end
  assign inv_all = start_c && (dc_scope == 2'b11) && !dc_push;
  // dc_scope, dc_push, dc_addr and dc_p8k hold until the operation is done.

  // The dirty bits: the snooper's sink, a copyback write's hit, a fill's clean line.
  always_comb begin
    d_we = 1'b0; d_set = xa[9:4]; d_way = p0_way; d_bits = 4'h0;
    if (sn_d) begin
      d_we = p1_hit; d_set = sn_addr[9:4]; d_way = p1_way;
      d_bits = p1_dirty | (4'b0001 << sn_addr[3:2]);
    end else if (look_w && x_cb) begin
      d_we = 1'b1; d_bits = p0_dirty | (4'b0001 << xa[3:2]);
    end else if (fill_t) begin
      d_we = 1'b1; d_way = vway; d_bits = 4'h0;
    end
  end

  // The queue's head leaves on the clock its last piece is done: written into
  // the cache (a copyback hit), or on the bus.
  wire q_out = !xld && (((x == X_LOOK) && x_cach && p0_hit && x_cb && !sn_any &&
                          (xn == t_n)) ||
                        ((x == X_BUS) && xbusy && d_done && (xn == cur_n || d_err)) ||
                        ((x == X_M16W) && xbusy && d_done));
  wire [1:0] q_in = qn - {1'b0, q_out};
  assign st_empty = (qn == 2'd0) && !(x != X_IDLE && x != X_CMO && !xld);

  // A snoop on the line a push is waiting with: a sink is copied into the push
  // buffer, an invalidation cancels the push.
  wire sn_on_v = (sn_addr[9:4] == vset) && (sn_addr[31:10] == vtag) && p1_hit && (p1_way == vway);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 3; i++) begin qa[i] <= '0; qs[i] <= '0; qd[i] <= '0; qf[i] <= '0; end
      lock_open <= 1'b0;
      qn      <= '0;
      x       <= X_IDLE;
      xld     <= 1'b0;
      xa      <= '0;
      xsup    <= 1'b0;
      xn      <= '0;
      xd      <= '0;
      xbusy   <= 1'b0;
      xerr    <= 1'b0;
      xcancel <= 1'b0;
      xlk     <= 1'b0;
      xlke    <= 1'b0;
      xalt    <= 1'b0;
      xack    <= 1'b0;
      xtm     <= '0;
      xna     <= 1'b0;
      cur_n   <= '0;
      cur_siz <= '0;
      cur_a10 <= '0;
      vset    <= '0; vway <= '0; vtag <= '0; vdirty <= '0; vfill <= 1'b0;
      pb      <= '0;
      lb      <= '0;
      mb      <= '0;
      xm16    <= 1'b0;
      ftci    <= 1'b0; ferr <= 1'b0; fe0 <= 1'b0;
      cscope  <= '0; cpush <= 1'b0; cp8k <= 1'b0; caddr <= '0; ck <= '0; cmo_on <= 1'b0;
      cmo_req <= 1'b0;
      rnd     <= '0;
      a_q     <= '0; bw_q <= 1'b0; bw_a <= '0;
      sn_way_q <= '0; sn_lw_q <= 1'b0;
      ld_done <= 1'b0;
      ld_data <= '0;
      ld_err  <= 1'b0;
      ld_avec <= 1'b0;
    end else if (crst) begin
      qn      <= '0;
      x       <= X_IDLE;
      xbusy   <= 1'b0;
      ld_done <= 1'b0;
      lock_open <= 1'b0;
      cmo_on  <= 1'b0;
      cmo_req <= 1'b0;
    end else begin
      if (dc_op)   cmo_req <= 1'b1;
      if (start_c) cmo_req <= 1'b0;
      ld_done <= 1'b0;
      a_q      <= a_addr;
      bw_q     <= (b_we != 8'h00);
      bw_a     <= b_addr;
      sn_way_q <= p1_way;
      sn_lw_q  <= sn_addr[2];
      // A cancelled read still finishes, as every transfer must, but answers
      // nobody.
      if (ld_cancel && x != X_IDLE && xld) xcancel <= 1'b1;

      // --- the fast read -----------------------------------------------------------
      if (fast) begin
        ld_done <= 1'b1;
        ld_err  <= 1'b0;
        ld_avec <= 1'b0;
        ld_data <= hl_take(a_hl, ld_addr[2:0], ld_n);
        rnd     <= rnd + 2'd1;
      end

      // --- a transfer on the bus -----------------------------------------------------
      if (d_valid && d_ready) begin
        xbusy   <= 1'b1;
        cur_n   <= t_n;
        cur_siz <= t_siz;
        cur_a10 <= xa[1:0];
        if (x == X_FILL) begin ftci <= 1'b0; ferr <= 1'b0; fe0 <= 1'b1; end
      end

      case (x)
        X_IDLE: begin
          if (start_ld) begin
            xld  <= 1'b1;
            xa   <= ld_addr;
            xsup <= ld_alt ? sfc[2] : sup;
            xn   <= nbytes(ld_sz);
            xd   <= '0;
            xlk  <= ld_lock;
            xlke <= 1'b0;
            xalt <= ld_alt;
            xack <= ld_ack;
            xtm  <= ld_tm;
            xna  <= ld_noalloc;
            xerr <= 1'b0;
            xcancel <= ld_cancel;
            xm16 <= ld_m16;
            x    <= ld_m16 ? X_M16L : X_RD;
            if (ld_lock) lock_open <= 1'b1;
          end else if (start_st) begin
            xld  <= 1'b0;
            xa   <= qa[0];
            xsup <= qf[0][1] ? dfc[2] : sup;
            xn   <= nbytes(qs[0]);
            xd   <= qd[0];
            xlk  <= qf[0][3];
            xlke <= qf[0][2];
            xalt <= qf[0][1];
            xack <= 1'b0;
            xna  <= qf[0][0];
            xerr <= 1'b0;
            xm16 <= qf[0][4];
            x    <= qf[0][4] ? X_M16I : X_RD;
          end else if (start_c) begin
            cscope <= dc_scope;
            cpush  <= dc_push;
            cp8k   <= dc_p8k;
            caddr  <= dc_addr;
            ck     <= '0;
            if (!(dc_scope == 2'b11 && !dc_push)) begin
              cmo_on <= 1'b1;
              x      <= X_CMO;
            end
          end
        end

        // A piece: its half-line read on port B, unless the snooper has it.
        X_RD: begin
          if (!(x_cach || x_byp)) x <= X_BUS;
          else if (!sn_b)         x <= X_LOOK;
        end

        X_LOOK: begin
          if (sn_any) begin
            // The snooper took the port: read again.
            x <= X_RD;
          end else if (x_cach && p0_hit) begin
            rnd <= rnd + 2'd1;
            if (xld) begin
              xd <= acc_in(xd, c_got, t_n);
              xa <= xa + 32'(t_n);
              xn <= xn - t_n;
              x  <= (xn == t_n) ? X_IDLE : X_RD;
              if (xn == t_n) begin
                ld_done <= !(xcancel || ld_cancel);
                ld_err  <= 1'b0;
                ld_avec <= 1'b0;
                ld_data <= acc_in(xd, c_got, t_n);
                xcancel <= 1'b0;
              end
            end else if (!x_cb) begin
              // Write-through: the cache written, and the bus.
              x <= X_BUS;
            end else begin
              xa <= xa + 32'(t_n);
              xn <= xn - t_n;
              x <= (xn == t_n) ? X_IDLE : X_RD;
            end
          end else if (x_cach && x_alloc) begin
            // A miss that allocates: the way, pushed first if dirty.
            vset   <= xa[9:4];
            vway   <= pick;
            vtag   <= p2_tag;
            vdirty <= p2_dirty;
            vfill  <= 1'b1;
            x      <= (p2_valid && (p2_dirty != 4'h0)) ? X_VRD0 : (p2_valid ? X_VINV : X_FILL);
          end else if (x_byp && p0_hit) begin
            // A bypass of a line the cache has: pushed if dirty, invalidated.
            vset   <= xa[9:4];
            vway   <= p0_way;
            vtag   <= xa[31:10];
            vdirty <= p0_dirty;
            vfill  <= 1'b0;
            x      <= (p0_dirty != 4'h0) ? X_VRD0 : X_VINV;
          end else begin
            x <= X_BUS;
          end
        end

        X_BUS: begin
          if (xbusy && d_done) begin
            xbusy <= 1'b0;
            if (d_err) xerr <= 1'b1;
            if (xld && d_rsp) xd <= accum;
            xa <= xa + 32'(cur_n);
            xn <= xn - cur_n;
            if (xn == cur_n || d_err) begin
              if (xld) begin
                ld_done <= !(xcancel || ld_cancel);
                xcancel <= 1'b0;
                ld_err  <= d_err || xerr;
                ld_avec <= d_avec;
                ld_data <= accum;
                // A locked read that faulted ends the sequence: its writes
                // will not come (the instruction takes the access fault).
                if (xlk && (d_err || xerr)) lock_open <= 1'b0;
              end else begin
                if (xlke) lock_open <= 1'b0;
              end
              x    <= X_IDLE;
              xerr <= 1'b0;
            end else begin
              x <= X_RD;
            end
          end
        end

        // The line to push, into the push buffer: half-line 0, then 1.
        X_VRD0: if (!sn_b) x <= X_VRD1;
        X_VRD1: begin
          if (sn_b) begin
            x <= X_VRD0;
          end else begin
            // A half-line holds its first long word high; the push buffer,
            // as the bus unit takes a line, long word k at [32k+31:32k].
            pb[31:0]   <= b_rdata[64*vway + 32 +: 32];   // long word 0
            pb[63:32]  <= b_rdata[64*vway      +: 32];   // long word 1
            x <= X_VRD2;
          end
        end
        X_VRD2: begin
          pb[95:64]  <= b_rdata[64*vway + 32 +: 32];     // long word 2
          pb[127:96] <= b_rdata[64*vway      +: 32];     // long word 3
          x <= X_PUSH;
        end

        X_PUSH: begin
          if (!xbusy && sn_dinv && sn_on_v) begin
            // A snoop invalidated the line: its dirty data is not ours to
            // write any more.
            x <= vfill ? X_FILL : ((cmo_on && !xld && xn == 3'd0) ? X_CMO : X_BUS);
            if (cmo_on) x <= X_CMO;
          end else if (xbusy && d_done) begin
            xbusy <= 1'b0;
            x <= X_VINV;
          end
        end

        X_VINV: begin
          if (!sn_t) begin
            if (cmo_on)     x <= X_CMO;
            else if (vfill) x <= X_FILL;
            else            x <= X_BUS;
          end
        end

        X_FILL: begin
          if (xbusy && d_rsp) begin
            lb[32*(3 - int'(d_lw)) +: 32] <= d_data;
            fe0 <= 1'b0;
            if (fe0 && d_tci) ftci <= 1'b1;
          end
          if (xbusy && d_done) begin
            xbusy <= 1'b0;
            if (fill_ok) begin
              x <= X_RD;                          // now it hits
            end else if (fe0 && d_err) begin
              // The long word wanted faulted (it is the first of the burst).
              if (xld) begin
                ld_done <= !(xcancel || ld_cancel);
                ld_err  <= 1'b1;
                ld_avec <= 1'b0;
                ld_data <= xd;
                xcancel <= 1'b0;
                x       <= X_IDLE;
              end else begin
                x <= X_BUS;                       // the write goes through
              end
            end else if (xld) begin
              // Not cached (TCI, or a later long word faulted): the piece from
              // the line read buffer.
              xd <= acc_in(xd, l_got, t_n);
              xa <= xa + 32'(t_n);
              xn <= xn - t_n;
              if (xn == t_n) begin
                ld_done <= !(xcancel || ld_cancel);
                ld_err  <= 1'b0;
                ld_avec <= 1'b0;
                ld_data <= acc_in(xd, l_got, t_n);
                xcancel <= 1'b0;
                x       <= X_IDLE;
              end else begin
                x <= X_RD;
              end
            end else begin
              x <= X_BUS;                         // a copyback write misses after all
            end
          end
        end

        // MOVE16's read: from the cache if the line is there (UM 4.3.3:
        // "read hits on either valid or dirty cache lines are read from the
        // cache"), else from the bus, not allocated.
        X_M16L: begin
          if (!sn_b) x <= (de && p0_hit) ? X_M16H0 : X_M16B;
        end
        X_M16H0: begin
          if (sn_b) begin
            x <= X_M16L;
          end else begin
            mb[31:0]  <= b_rdata[64*p0_way + 32 +: 32];
            mb[63:32] <= b_rdata[64*p0_way      +: 32];
            x <= X_M16H1;
          end
        end
        X_M16H1: begin
          mb[95:64]  <= b_rdata[64*p0_way + 32 +: 32];
          mb[127:96] <= b_rdata[64*p0_way      +: 32];
          ld_done <= !(xcancel || ld_cancel);
          ld_err  <= 1'b0;
          ld_avec <= 1'b0;
          xcancel <= 1'b0;
          x <= X_IDLE;
        end
        X_M16B: begin
          if (xbusy && d_rsp) mb[32*int'(d_lw) +: 32] <= d_data;
          if (xbusy && d_done) begin
            xbusy   <= 1'b0;
            ld_done <= !(xcancel || ld_cancel);
            ld_err  <= d_err;
            ld_avec <= 1'b0;
            xcancel <= 1'b0;
            x <= X_IDLE;
          end
        end
        // MOVE16's write: "write hits invalidate a matching line and perform
        // an external access" (UM 4.3.3).
        X_M16I: begin
          if (!sn_t) x <= X_M16W;
        end
        X_M16W: begin
          if (xbusy && d_done) begin
            xbusy <= 1'b0;
            x <= X_IDLE;
          end
        end

        // CINV and CPUSH: a line, or the walk.
        X_CMO: begin
          if (cscope == 2'b01) begin
            if (p0_hit) begin
              vset <= caddr[9:4]; vway <= p0_way; vtag <= caddr[31:10]; vdirty <= p0_dirty;
              vfill <= 1'b0;
              x <= (cpush && p0_dirty != 4'h0) ? X_VRD0 : X_VINV;
            end
            cscope <= 2'b00;                      // the one line is done after this
          end else if (cscope == 2'b00) begin
            cmo_on <= 1'b0;
            x      <= X_IDLE;
          end else begin
            if (c_match) begin
              vset <= ck[7:2]; vway <= ck[1:0]; vtag <= p2_tag; vdirty <= p2_dirty;
              vfill <= 1'b0;
              x <= (cpush && p2_dirty != 4'h0) ? X_VRD0 : X_VINV;
            end
            ck <= ck + 8'd1;
            if (ck == 8'hFF) cscope <= 2'b00;
          end
        end

        default: x <= X_IDLE;
      endcase

      // A sink into the line a push holds: the push buffer has it too.
      // (Written out: a loop variable here would be a register to yosys.)
      if (sn_wr && sn_on_v && (x == X_PUSH || x == X_VRD2)) begin
        if (sn_wbe[3]) pb[32*int'(sn_addr[3:2]) + 24 +: 8] <= sn_wdata[31:24];
        if (sn_wbe[2]) pb[32*int'(sn_addr[3:2]) + 16 +: 8] <= sn_wdata[23:16];
        if (sn_wbe[1]) pb[32*int'(sn_addr[3:2]) +  8 +: 8] <= sn_wdata[15:8];
        if (sn_wbe[0]) pb[32*int'(sn_addr[3:2])      +: 8] <= sn_wdata[7:0];
      end

      // The oldest write is done: the queue moves up.
      if (q_out) begin
        qa[0] <= qa[1]; qs[0] <= qs[1]; qd[0] <= qd[1]; qf[0] <= qf[1];
        qa[1] <= qa[2]; qs[1] <= qs[2]; qd[1] <= qd[2]; qf[1] <= qf[2];
      end
      // A new write joins the queue behind those still there.
      if (st_ready) begin
        qa[q_in] <= st_addr; qs[q_in] <= st_sz; qd[q_in] <= st_data;
        qf[q_in] <= {st_m16, st_lock, st_locke, st_alt, st_noalloc};
      end
      qn <= qn - {1'b0, q_out} + {1'b0, st_ready};
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, la_wp, la_tt, la_upa, x_wp, x_tt, sn_addr[1:0], p0_a[3:0], xm16,
                       ld_pre[31:10], ld_pre[2:0]};

endmodule
