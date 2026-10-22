// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- the per-opcode sweep, against UAE040.
//
// tools/vectors/gen.c builds one test per (opcode, starting state), runs it
// through UAE040 as an MC68040 and records the state it finished in and every
// operand access it made. This replays each one through the core and compares:
// D0-D7, A0-A6, A7 (the active stack pointer, the ISP: supervisor, M clear),
// SR under the mask of the condition codes the manual defines, the next PC,
// and the operand accesses -- address, size and direction of each, and the
// value of each write. The stream's format is documented at the top of
// tools/vectors/gen.c; RD68031's core_vec_tb is the model.
//
// UAE040 is an ORACLE, not a source. Where the two disagree the manual decides.
//
// Each test is one of:
//   PASS        it ran, and everything compared agreed;
//   FAIL        it ran, and something did not (or it never finished);
//   NOT BUILT   the core halted on it: its decoder does not build the
//               instruction (or that form of it) yet;
//   PENDING M8  the oracle took an exception, or the test starts from a state
//               (user mode, tracing) the core cannot be put in, because it has
//               no exception processing and SR's system byte is fixed at $27
//               until M8. Not run.
// The bench PASSes when nothing FAILs.
//
// Per test: the data block is filled (the same arithmetic as gen.c), the
// instruction put at PROG_BASE with ILLEGAL after it, the pokes made, the core
// reset (the reset vectors at 0 and 4 are STACK and PROG_BASE), the state
// deposited at the one clock the pipeline is known empty, and the instruction
// run alone (rd68041_core_harness.svh: deposit, run_one). Whatever it wrote
// outside the refilled areas is put back afterwards.
//
// What is not compared yet: the function code of each access (the core's data
// memory unit drives supervisor data for every operand until M8-M10), and the
// control registers -- USP, MSP, SFC, DFC, VBR, CACR -- which the bench can
// neither deposit nor read until the core has them (they start at zero, the
// reset value, on both sides). The reads and the writes are compared each in
// order, but not their interleaving: UM 7.7 lets a read pass a write it does
// not touch.
//
//   +vec=FILE      the stream (default build/vectors.hex)
//   +faillog=FILE  every failing test, one line each, with both access lists
//   +show=N        how many failures to print in detail (default 15)

`timescale 1ns / 1ps

module core_vec_tb;

`include "rd68041_core_harness.svh"
`include "rd68041_vec_harness.svh"

  localparam logic [31:0] PROG_BASE = 32'h0000_1000;
  localparam logic [31:0] DATA_BASE = 32'h0000_2000;
  localparam int          DATA_SIZE = 'h800;
  localparam int          PROG_FILL = 'h40;
  localparam logic [31:0] STACK     = 32'h0000_2700;
  localparam int          MAXACC    = 24;
  localparam int          MAXG      = 64;

  integer      vec, flog;
  int unsigned ntests, ngroups;
  string       gname [0:MAXG-1];
  reg [8*32:1] gbuf;
  int unsigned idx, grp, nwords, npoke, nread;
  logic [31:0] w    [0:5];
  logic [31:0] dv   [0:7];
  logic [31:0] av   [0:6];
  logic [31:0] uspv, ispv, srv, mspv, sfcv, dfcv, vbrv, cacrv;
  logic [31:0] pa   [0:3];
  logic [31:0] pv   [0:3];
  logic [31:0] srmask, fill, excv;
  logic [31:0] fd   [0:7];
  logic [31:0] fa   [0:6];
  logic [31:0] fusp, fisp, fsr, fpc, fmsp, fvbr, fsfc, fdfc, fcacr;
  logic [31:0] racc [0:MAXACC-1];
  logic [31:0] rrw  [0:MAXACC-1];
  logic [31:0] rby  [0:MAXACC-1];
  logic [31:0] rfc  [0:MAXACC-1];
  logic [31:0] rval [0:MAXACC-1];
  logic [31:0] rmsk [0:MAXACC-1];
  logic [31:0] fw;

  int unsigned g_pass [0:MAXG-1];
  int unsigned g_fail [0:MAXG-1];
  int unsigned g_nb   [0:MAXG-1];
  int unsigned g_pend [0:MAXG-1];
  int unsigned g_seen [0:MAXG-1];

  int unsigned t, n, k, i, j, shown, maxshow;
  int unsigned passed, failed, notbuilt, pending, cas_waived, split_waived;
  bit          bad_pre;
  bit          ok, built, bad;
  string       what, why, s;

  // gen.c's fill_word: two truncating 32-bit multiplications and an exclusive or.
  function automatic logic [31:0] fill_word(input int unsigned ti, input int unsigned off);
    fill_word = (32'(ti) * 32'h9E37_79B9) ^ (32'(off) * 32'h0100_0193);
  endfunction

  // gen.c's bcd_word: every nibble modulo ten.
  function automatic logic [3:0] bcd_digit(input logic [3:0] d);
    bcd_digit = (d >= 4'd10) ? (d - 4'd10) : d;
  endfunction
  function automatic logic [31:0] bcd_word32(input logic [31:0] v);
    bcd_word32 = {bcd_digit(v[31:28]), bcd_digit(v[27:24]), bcd_digit(v[23:20]),
                  bcd_digit(v[19:16]), bcd_digit(v[15:12]), bcd_digit(v[11:8]),
                  bcd_digit(v[7:4]),   bcd_digit(v[3:0])};
  endfunction

  // What a byte holds before any test: the vector table (every vector at its
  // own $9000 + 4n, the reset vectors STACK and PROG_BASE), zero elsewhere.
  // The data block and the program area are rewritten by every test anyway.
  function automatic logic [7:0] base_byte(input logic [15:0] a);
    logic [31:0] v;
    if (a < 16'h0400) begin
      v = (a[15:2] == 0) ? STACK : (a[15:2] == 1) ? PROG_BASE : 32'h0000_9000 + {16'h0, a[15:2], 2'b00};
      base_byte = v[31 - 8 * a[1:0] -: 8];
    end else begin
      base_byte = 8'h00;
    end
  endfunction

  task automatic restore(input logic [31:0] a, input int unsigned nb);
    logic [31:0] x;
    for (int q = 0; q < int'(nb); q++) begin
      x = a + q;
      u_mem.mem[x[15:0]] = base_byte(x[15:0]);
    end
  endtask

  // The core's reads (or writes) in order: the k-th of them.
  function automatic int nth(input bit rd, input int unsigned kk);
    int c;
    nth = -1;
    c = 0;
    for (int q = 0; q < ncap && q < MAXCAP; q++)
      if (cap_rd[q] == rd) begin
        if (c == int'(kk)) begin nth = q; return nth; end
        c++;
      end
  endfunction

  task automatic lists(inout string l);
    l = {l, " | core:"};
    for (int q = 0; q < ncap && q < MAXCAP; q++)
      // (iverilog makes a conditional between two strings an empty one.)
      if (cap_rd[q]) l = {l, $sformatf(" R%0d@%0h", cap_bytes[q], cap_addr[q])};
      else           l = {l, $sformatf(" W%0d@%0h=%0h", cap_bytes[q], cap_addr[q], cap_data[q])};
    l = {l, " | oracle:"};
    for (int q = 0; q < int'(nread); q++)
      if (rrw[q][0]) l = {l, $sformatf(" R%0d@%0h", rby[q], racc[q])};
      else           l = {l, $sformatf(" W%0d@%0h=%0h", rby[q], racc[q], rval[q])};
  endtask

  // One test, read; returns early for the ones not run or not built.
  task automatic run_test();
    begin : one
      // --------------------------------------------------------------------
      // Pending M8: an exception, or a starting state the core cannot have.
      // --------------------------------------------------------------------
      if (excv != 0 || srv[15:8] != 8'h27 || mspv != 0 || uspv != 0 || sfcv != 0 ||
          dfcv != 0 || vbrv != 0 || cacrv != 0) begin
        pending++;
        g_pend[grp]++;
        disable one;
      end

      // --------------------------------------------------------------------
      // Memory, as the oracle laid it out.
      // --------------------------------------------------------------------
      for (n = 0; n < DATA_SIZE; n += 4) begin
        fw = fill_word(idx, n);
        if (fill == 1) fw = bcd_word32(fw);
        else if (fill == 2) fw = 32'h0000_3000 + n;
        u_mem.mem[DATA_BASE[15:0] + 16'(n)]     = fw[31:24];
        u_mem.mem[DATA_BASE[15:0] + 16'(n) + 1] = fw[23:16];
        u_mem.mem[DATA_BASE[15:0] + 16'(n) + 2] = fw[15:8];
        u_mem.mem[DATA_BASE[15:0] + 16'(n) + 3] = fw[7:0];
      end
      for (n = 0; n < PROG_FILL; n += 2) mw(PROG_BASE + n, 16'h4AFC);
      for (n = 0; n < nwords; n++) mw(PROG_BASE + 2 * n, w[n][15:0]);
      for (n = 0; n < npoke; n++) ml(pa[n], pv[n]);

      // --------------------------------------------------------------------
      // Reset, deposit, one instruction.
      // --------------------------------------------------------------------
      vec_boot();
      for (n = 0; n < 8; n++) dep_d[n] = dv[n];
      for (n = 0; n < 7; n++) dep_a[n] = av[n];
      dep_a[7] = ispv;
      dep_sr = srv[15:0];
      deposit();
      cap_clear();
      cap_on = 1'b1;
      run_one(3000, ok, built);
      cap_on = 1'b0;
      end_one();

      // Put back whatever it wrote outside what the next test rewrites.
      for (n = 0; n < ncap && n < MAXCAP; n++)
        if (!cap_rd[n]) restore(cap_addr[n], cap_bytes[n]);
      for (n = 0; n < npoke; n++) restore(pa[n], 4);

      if (!built) begin
        notbuilt++;
        g_nb[grp]++;
        disable one;
      end

      // --------------------------------------------------------------------
      // Compare.
      // --------------------------------------------------------------------
      bad = 1'b0;
      why = "";
      if (!ok) begin
        bad = 1'b1;
        why = "the instruction never completed";
      end
      for (n = 0; n < 8; n++)
        if (!bad && reg_of(n) !== fd[n]) begin
          bad = 1'b1;
          $sformat(why, "D%0d is %08h, UAE040 says %08h", n, reg_of(n), fd[n]);
        end
      for (n = 0; n < 7; n++)
        if (!bad && reg_of(8 + n) !== fa[n]) begin
          bad = 1'b1;
          $sformat(why, "A%0d is %08h, UAE040 says %08h", n, reg_of(8 + n), fa[n]);
        end
      if (!bad && reg_of(15) !== fisp) begin
        bad = 1'b1;
        $sformat(why, "A7 (ISP) is %08h, UAE040 says %08h", reg_of(15), fisp);
      end
      if (!bad && ((dut.u_core.sr ^ fsr[15:0]) & srmask[15:0]) !== 16'd0) begin
        bad = 1'b1;
        $sformat(why, "SR is %04h, UAE040 says %04h (comparing %04h)",
                 dut.u_core.sr, fsr[15:0], srmask[15:0]);
      end
      if (!bad && nretire == 0) begin
        bad = 1'b1;
        why = "nothing retired";
      end
      if (!bad && last_npc !== fpc) begin
        bad = 1'b1;
        $sformat(why, "the next PC is %08h, UAE040 says %08h", last_npc, fpc);
      end
      if (!bad && ncap > MAXCAP) begin
        bad = 1'b1;
        $sformat(why, "it made %0d operand accesses, more than the bench records", ncap);
      end
      // The reads in order, then the writes in order.
      bad_pre = bad;
      for (k = 0; k < 2 && !bad; k++) begin
        int nc, no, q;
        nc = 0; no = 0;
        for (q = 0; q < ncap; q++) if (cap_rd[q] == (k == 0)) nc++;
        for (q = 0; q < int'(nread); q++) if (rrw[q][0] == (k == 0)) no++;
        // UM 7.7.3: a CAS or CAS2 whose compare fails still writes the
        // operand it read back, to end the locked sequence; UAE040 makes no
        // write (doc/oracles.md). That one write is accepted.
        if (k == 1 && no == 0 && nc == 1 && is_cas(w[0]) &&
            cap_addr[nth(1'b0, 0)] === cap_addr[nth(1'b1, nth_last_rd())]) begin
          cas_waived++;
        end else if (nc != no) begin
          bad = 1'b1;
          if (k == 0) $sformat(why, "it made %0d operand reads, UAE040 made %0d", nc, no);
          else        $sformat(why, "it made %0d operand writes, UAE040 made %0d", nc, no);
        end else begin
          j = 0;
          for (q = 0; q < int'(nread) && !bad; q++) begin
            int c;
            if (rrw[q][0] == (k == 0)) begin
            c = nth(k == 0, j);
            j++;
            if (cap_addr[c] !== racc[q] || {29'd0, cap_bytes[c]} !== rby[q] ||
                (k == 1 && ((cap_data[c] ^ rval[q]) & rmsk[q] & bmask(rby[q])) !== 32'd0)) begin
              bad = 1'b1;
              if (k == 0)
                $sformat(why, "read %0d is %0d bytes at %08h, UAE040's %0d bytes at %08h",
                         j - 1, cap_bytes[c], cap_addr[c], rby[q], racc[q]);
              else
                $sformat(why, "write %0d is %0d bytes at %08h of %08h, UAE040's %0d bytes at %08h of %08h",
                         j - 1, cap_bytes[c], cap_addr[c], cap_data[c], rby[q], racc[q], rval[q]);
            end
            end
          end
        end
      end

      // PACK, UNPK and the bit fields: the bytes, however they were split
      // into accesses (doc/oracles.md).
      if (!bad_pre && bad && (gname[grp] == "packunpk_mem" || gname[grp] == "bitfield_mem") &&
          same_bytes()) begin
        bad = 1'b0;
        split_waived++;
      end

      if (bad) begin
        failed++;
        g_fail[grp]++;
        s = "";
        lists(s);
        if (flog != 0)
          $fdisplay(flog, "%0h %s %04h %04h %04h %04h | %s%s", idx, gname[grp], w[0][15:0],
                    w[1][15:0], w[2][15:0], w[3][15:0], why, s);
        if (shown < maxshow) begin
          shown++;
          $display("  FAIL: vector %0h [%s] %04h %04h %04h: %s", idx, gname[grp],
                   w[0][15:0], w[1][15:0], w[2][15:0], why);
          $display("        from D=%08h %08h %08h %08h %08h %08h %08h %08h", dv[0], dv[1],
                   dv[2], dv[3], dv[4], dv[5], dv[6], dv[7]);
          $display("             A=%08h %08h %08h %08h %08h %08h %08h %08h SR=%04h",
                   av[0], av[1], av[2], av[3], av[4], av[5], av[6], ispv, srv[15:0]);
          $display("       %s", s.substr(3, s.len() - 1));
        end
      end else begin
        passed++;
        g_pass[grp]++;
      end
    end
  endtask

  // The bytes of the core's accesses against UAE040's: the same bytes read,
  // the same bytes written with the same values, in whatever accesses.
  // Byte i of an access of n at a is at a + i, the data's byte n-1-i.
  function automatic bit same_bytes();
    logic [31:0] ca [0:4*MAXCAP-1];
    logic  [7:0] cv [0:4*MAXCAP-1];
    logic        cr [0:4*MAXCAP-1];
    int          nc, q, i, j;
    bit          hit;
    logic  [7:0] v;
    nc = 0;
    for (q = 0; q < ncap && q < MAXCAP; q++)
      for (i = 0; i < int'(cap_bytes[q]); i++) begin
        ca[nc] = cap_addr[q] + i;
        cv[nc] = 8'(cap_data[q] >> (8 * (int'(cap_bytes[q]) - 1 - i)));
        cr[nc] = cap_rd[q];
        nc++;
      end
    // Every one of UAE040's is among the core's, and as many of each kind.
    j = 0;
    for (q = 0; q < int'(nread); q++)
      for (i = 0; i < int'(rby[q]); i++) begin
        v = 8'(rval[q] >> (8 * (int'(rby[q]) - 1 - i)));
        hit = 1'b0;
        for (int c = 0; c < nc; c++)
          if (ca[c] == racc[q] + i && cr[c] == rrw[q][0] && (cr[c] || cv[c] == v)) hit = 1'b1;
        if (!hit) return 1'b0;
        j++;
      end
    same_bytes = (j == nc);
  endfunction

  // CAS and CAS2: 0000 1ss0 11 <ea>, ss not 00.
  function automatic logic is_cas(input logic [31:0] op);
    is_cas = (op[15:11] == 5'b00001) && (op[10:9] != 2'b00) && (op[8:6] == 3'b011);
  endfunction
  // The index, among the reads, of the last one.
  function automatic int nth_last_rd();
    int c;
    c = 0;
    for (int q = 0; q < ncap && q < MAXCAP; q++) if (cap_rd[q]) c++;
    nth_last_rd = c - 1;
  endfunction

  // The bytes an access of n carries: UAE040 reports a byte or word write
  // with whatever the register held above it.
  function automatic logic [31:0] bmask(input logic [31:0] n);
    bmask = (n == 32'd1) ? 32'h0000_00FF : (n == 32'd2) ? 32'h0000_FFFF :
            (n == 32'd3) ? 32'h00FF_FFFF : 32'hFFFF_FFFF;
  endfunction

  initial begin
    flog = 0;
    if ($value$plusargs("faillog=%s", why)) flog = $fopen(why, "w");
    if (!$value$plusargs("show=%d", maxshow)) maxshow = 15;
    if (!$value$plusargs("vec=%s", what)) what = "build/vectors.hex";
    if ($bits(rd68041_pkg::uop_t) != rd68041_pkg::UOP_W) begin
      $display("FAIL: rd68041_pkg::UOP_W is %0d, the struct %0d bits",
               rd68041_pkg::UOP_W, $bits(rd68041_pkg::uop_t));
      $finish;
    end
    vec = $fopen(what, "r");
    if (vec == 0) begin
      $display("FAIL: core_vec_tb cannot open %s", what);
      $finish;
    end
    void'($fscanf(vec, "%h %h", ntests, ngroups));
    for (n = 0; n < ngroups; n++) begin
      void'($fscanf(vec, "%s", gbuf));
      gname[n] = $sformatf("%0s", gbuf);
      g_pass[n] = 0; g_fail[n] = 0; g_nb[n] = 0; g_pend[n] = 0; g_seen[n] = 0;
    end
    $display("core_vec_tb: %0d vectors from UAE040", ntests);

    passed = 0; failed = 0; notbuilt = 0; pending = 0; shown = 0; cas_waived = 0; split_waived = 0;

    for (n = 0; n < VMEM; n++) u_mem.mem[n] = base_byte(n[15:0]);

    for (t = 0; t < ntests; t++) begin
      void'($fscanf(vec, "%h %h %h %h %h %h %h %h %h",
                    idx, grp, nwords, w[0], w[1], w[2], w[3], w[4], w[5]));
      for (n = 0; n < 8; n++) void'($fscanf(vec, "%h", dv[n]));
      for (n = 0; n < 7; n++) void'($fscanf(vec, "%h", av[n]));
      void'($fscanf(vec, "%h %h %h %h %h %h %h %h",
                    uspv, ispv, srv, mspv, sfcv, dfcv, vbrv, cacrv));
      void'($fscanf(vec, "%h", npoke));
      for (n = 0; n < npoke; n++) void'($fscanf(vec, "%h %h", pa[n], pv[n]));
      void'($fscanf(vec, "%h %h %h", srmask, fill, excv));
      for (n = 0; n < 8; n++) void'($fscanf(vec, "%h", fd[n]));
      for (n = 0; n < 7; n++) void'($fscanf(vec, "%h", fa[n]));
      void'($fscanf(vec, "%h %h %h %h %h %h %h %h %h",
                    fusp, fisp, fsr, fpc, fmsp, fvbr, fsfc, fdfc, fcacr));
      void'($fscanf(vec, "%h", nread));
      for (n = 0; n < nread; n++)
        void'($fscanf(vec, "%h %h %h %h %h %h", racc[n], rrw[n], rby[n], rfc[n],
                      rval[n], rmsk[n]));
      if (grp >= MAXG) grp = MAXG - 1;
      g_seen[grp]++;

      run_test();
    end

    $fclose(vec);
    if (flog != 0) $fclose(flog);
    $display("core_vec_tb: %-14s %7s %7s %9s %10s", "group", "passed", "failed",
             "not built", "pending M8");
    for (n = 0; n < ngroups; n++)
      if (g_seen[n] != 0)
        $display("core_vec_tb: %-14s %7d %7d %9d %10d", gname[n], g_pass[n], g_fail[n],
                 g_nb[n], g_pend[n]);
    $display("core_vec_tb: %0d passed, %0d failed, %0d not built, %0d pending M8, of %0d",
             passed, failed, notbuilt, pending, ntests);
    if (split_waived != 0)
      $display("core_vec_tb: %0d matched byte for byte, split into accesses as UAE040 does not",
               split_waived);
    if (cas_waived != 0)
      $display("core_vec_tb: %0d failed CAS/CAS2 compares wrote the operand back (UM 7.7.3; UAE040 does not)",
               cas_waived);
    if (failed == 0) $display("PASS: core_vec_tb");
    else             $display("FAIL: core_vec_tb");
    $finish;
  end

endmodule
