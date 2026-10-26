// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- two processors on one bus behind UM 7.8.2.1's fairness arbiter,
// corrected (doc/smp.md; the board: sim/tb/rd68041_smp_harness.svh). Both run
// sim/programs/m14_smp.S: interprocessor interrupts, spinlocks and lock-free
// CAS in cache-inhibited, write-through and copyback memory, false sharing, a
// producer and a consumer, MOVE16, an instruction cache kept coherent by
// snooping, a TLB shootdown. The program checks what it sees; the bench checks
// the bus (contention, the handover, locked sequences, fairness, each
// processor's protocol) and, once both are done, memory.
//
//   +iters=N   the program's ITERS (default 6)
//   +umask=H   ANDed into every page descriptor (cleared U bits: no snooping)
//   +gapless   the negative test: the printed arbiter's grants, which hand the
//              bus over with no clock between -- PASS only if the bench sees
//              the address group handed over with no clock between, so the
//              checker is shown to work and F3 shown to matter
// and the harness's plusargs (+nolocke, +retry=, +waits=, +rsti1=, +nomigate,
// +nosnarf).

`timescale 1ns / 1ps

module core_smp_tb;

`include "rd68041_smp_harness.svh"

  localparam logic [31:0] CI = 32'h0000_8000;
  localparam logic [31:0] ITERS_A = CI + 32'h00, UMASK_A = CI + 32'h04;
  localparam logic [31:0] ERR_A = CI + 32'h20, FIRST_A = CI + 32'h28, DONE_A = CI + 32'h30;
  localparam logic [31:0] IPICNT_A = CI + 32'h40, SHOOTDONE_A = CI + 32'h4C;

  string       image;
  int          iters;
  logic [31:0] umask;
  int unsigned nfail;
  bit          done;
  int          tmo;

  task automatic expect_mem(input string what, input logic [31:0] addr, input logic [31:0] v);
    if (u_mem.peek_long(addr) !== v) begin
      $display("  FAIL: %s at %h is %h, expected %h", what, addr, u_mem.peek_long(addr), v);
      nfail++;
    end
  endtask

  task automatic report_bus();
    $display("  bus: %0d transfers by CPU 0, %0d by CPU 1; %0d grants; %0d locked sequences; %0d snooped TAs, %0d long words sourced; %0d device accesses",
             n_ts[0], n_ts[1], n_handover, n_locked, n_snoop_ta, n_sourced, dev_n);
    $display("  checks: contention %0d, turnaround %0d, gap %0d, owner %0d, atomicity %0d, fairness %0d, busmon %0d/%0d",
             n_contention, n_turnaround, n_gap, n_owner, n_atomic, n_fair,
             cpu[0].u_mon.errors, cpu[1].u_mon.errors);
  endtask

  task automatic finish_up();
    logic [31:0] two_n;
    two_n = 32'(2 * iters);
    report_bus();
    if (arb_gapless) begin
      // The negative test: the printed arbiter must be caught.
      if (n_turnaround > 0 && n_gap > 0)
        $display("PASS: core_smp_tb +gapless: the printed arbiter hands the address group over with no clock between (%0d times)", n_turnaround);
      else
        $display("FAIL: core_smp_tb +gapless: the gapless handover was not seen (turnaround %0d, gap %0d)",
                 n_turnaround, n_gap);
      $finish;
    end
    for (int i = 0; i < 2; i++) begin
      if (u_mem.peek_long(ERR_A + 4 * i) != 0) begin
        $display("  FAIL: CPU %0d counted %0d errors, the first %h", i,
                 u_mem.peek_long(ERR_A + 4 * i), u_mem.peek_long(FIRST_A + 4 * i));
        nfail++;
      end
    end
    expect_mem("CPU 0's interrupts taken", IPICNT_A,     32'(iters));
    expect_mem("CPU 1's interrupts taken", IPICNT_A + 4, 32'(iters + 1));
    expect_mem("CPU 1's shootdown",        SHOOTDONE_A,  32'h1);
    expect_mem("CAS lock, cache-inhibited",  CI + 32'h54, two_n);
    expect_mem("TAS lock, cache-inhibited",  CI + 32'h5C, two_n);
    expect_mem("lock-free, cache-inhibited", CI + 32'h60, two_n);
    expect_mem("CAS lock, write-through",    32'h7004, two_n);
    expect_mem("TAS lock, write-through",    32'h7014, two_n);
    expect_mem("CAS lock, copyback",         32'h6004, two_n);
    expect_mem("TAS lock, copyback",         32'h6014, two_n);
    expect_mem("lock-free, copyback",        32'h6020, two_n);
    expect_mem("CPU 0's false-sharing count", 32'h6100, 32'(iters));
    expect_mem("CPU 1's false-sharing count", 32'h6104, 32'(iters));
    expect_mem("the producer's last SEQ",    32'h7100, 32'(iters));
    expect_mem("CAS word beside counters",   32'h6300, two_n);
    expect_mem("CPU 0's counter beside it",  32'h6304, 32'(iters));
    expect_mem("CPU 1's counter beside it",  32'h6308, 32'(iters));
    for (int k = 0; k < 4; k++)
      expect_mem("MOVE16's copy", 32'h6280 + 4 * k, 32'h1616_0000 + k);
    expect_mem("the rewritten routine",      32'h4000, 32'h7002_4E75);
    nfail = nfail + n_contention + n_turnaround + n_gap + n_owner + n_atomic + n_fair +
            cpu[0].u_mon.errors + cpu[1].u_mon.errors;
    if (nfail == 0)
      $display("PASS: core_smp_tb: two processors, %0d iterations: interrupts, locks, coherence, the instruction cache, a TLB shootdown",
               iters);
    else
      $display("FAIL: core_smp_tb: %0d checks failed", nfail);
    $finish;
  endtask

  // The negative test ends once the handover is seen: the printed arbiter
  // does not finish the program (its B-to-A path and the gapless grants can
  // keep a lock-free CAS from ever succeeding), and need not.
  always @(negedge clk)
    if (arb_gapless && !done && n_turnaround > 0 && n_gap > 0) begin
      done = 1;
      repeat (16) @(negedge clk);
      finish_up();
    end

  always @(negedge clk) begin
    if (rst_n && !done && u_mem.peek_long(DONE_A) == 32'hC0DE_0000 &&
        u_mem.peek_long(DONE_A + 4) == 32'hC0DE_0000) begin
      done = 1;
      repeat (16) @(negedge clk);
      finish_up();
    end
  end

  initial begin
    if (!$value$plusargs("image=%s", image)) image = "build/programs/m14_smp.hex";
    if (!$value$plusargs("iters=%d", iters)) iters = 6;
    if (!$value$plusargs("umask=%h", umask)) umask = 32'h0;
    if (!$value$plusargs("timeout=%d", tmo)) tmo = 4000000;
    nfail = 0; done = 0;
    boot2(image, 32'(iters), umask);
  end

  // +progress=N: where both are, every N clocks.
  int prog_every = 0;
  initial if (!$value$plusargs("progress=%d", prog_every)) prog_every = 0;
  always @(negedge clk)
    if (prog_every > 0 && cyc % prog_every == 0)
      $display("  [%0d] barriers %h %h, PCs %h %h, arbiter %0d, transfers %0d %0d, rsti1 %b, errors %0d %0d",
               cyc, u_mem.peek_long(CI + 32'h10), u_mem.peek_long(CI + 32'h14),
               cpu[0].dut.u_core.w_u.pc, cpu[1].dut.u_core.w_u.pc, arb_state, n_ts[0], n_ts[1],
               rsti_n[1], u_mem.peek_long(ERR_A), u_mem.peek_long(ERR_A + 4));
  always @(negedge clk)
    if (prog_every > 0 && cyc % prog_every == 0)
      $display("        bus: A %h ts %b tip %b bb %b(oe %b%b) ta %b mi %b%b->%b br %b%b bg %b%b lock %b locke %b",
               a_bus, ts_bus, tip_bus, bb_bus, bb_oe[0], bb_oe[1], ta_bus, mi_n_o[0], mi_n_o[1],
               mi_mem, br_n_o[0], br_n_o[1], bg_n[0], bg_n[1], lock_bus, locke_bus);

  // +watchline=H: that line in memory and in each processor's data cache, at
  // every progress line.
  logic [31:0] wline;
  initial if (!$value$plusargs("watchline=%h", wline)) wline = 32'hFFFF_FFFF;
`define SMP_DC_LOOK(C) \
  for (int w = 0; w < 4; w++) begin \
    logic [21:0] tg; logic [3:0] dy; logic [63:0] h0, h1; int st; \
    st = int'(wline[9:4]); \
    case (w) \
      0: begin tg = cpu[C].dut.u_core.u_dmu.u_arr.g_tag[0].tag_ram[st]; dy = cpu[C].dut.u_core.u_dmu.u_arr.g_tag[0].g_dirty.dirty_ram[st]; \
               h0 = cpu[C].dut.u_core.u_dmu.u_arr.g_data[0].u_ram.mem[2*st]; h1 = cpu[C].dut.u_core.u_dmu.u_arr.g_data[0].u_ram.mem[2*st+1]; end \
      1: begin tg = cpu[C].dut.u_core.u_dmu.u_arr.g_tag[1].tag_ram[st]; dy = cpu[C].dut.u_core.u_dmu.u_arr.g_tag[1].g_dirty.dirty_ram[st]; \
               h0 = cpu[C].dut.u_core.u_dmu.u_arr.g_data[1].u_ram.mem[2*st]; h1 = cpu[C].dut.u_core.u_dmu.u_arr.g_data[1].u_ram.mem[2*st+1]; end \
      2: begin tg = cpu[C].dut.u_core.u_dmu.u_arr.g_tag[2].tag_ram[st]; dy = cpu[C].dut.u_core.u_dmu.u_arr.g_tag[2].g_dirty.dirty_ram[st]; \
               h0 = cpu[C].dut.u_core.u_dmu.u_arr.g_data[2].u_ram.mem[2*st]; h1 = cpu[C].dut.u_core.u_dmu.u_arr.g_data[2].u_ram.mem[2*st+1]; end \
      default: begin tg = cpu[C].dut.u_core.u_dmu.u_arr.g_tag[3].tag_ram[st]; dy = cpu[C].dut.u_core.u_dmu.u_arr.g_tag[3].g_dirty.dirty_ram[st]; \
               h0 = cpu[C].dut.u_core.u_dmu.u_arr.g_data[3].u_ram.mem[2*st]; h1 = cpu[C].dut.u_core.u_dmu.u_arr.g_data[3].u_ram.mem[2*st+1]; end \
    endcase \
    if (cpu[C].dut.u_core.u_dmu.u_arr.v_q[w][st] && tg == wline[31:10]) \
      $display("        CPU %0d way %0d: dirty %b  %h %h %h %h", C, w, dy, h0[63:32], h0[31:0], h1[63:32], h1[31:0]); \
  end
  // ... and every transfer to it: who starts it, how, and how it ends.
  bit wl_on = 0;
  always @(posedge clk) if (rst_n && wline != 32'hFFFF_FFFF) begin
    if (!ts_bus) begin
      wl_on = (a_bus[31:4] == wline[31:4]) && (tt_bus != 2'b11);
      if (wl_on)
        $display("    [%0d] TS cpu%0d %s %h siz %b tt %b sc %b%s%s  push? tm %b", cyc,
                 (ts_oe[1] && !ts_n_o[1]) ? 1 : 0, rw_bus ? "R" : "W", a_bus, siz_bus, tt_bus,
                 sc_bus, !lock_bus ? " LOCK" : "", !locke_bus ? " LOCKE" : "", tm_bus);
    end
    if (wl_on && (!ta_bus || !tea_bus))
      $display("    [%0d]   %s%s d %h  by %s  mi %b%b", cyc, !ta_bus ? "TA" : "", !tea_bus ? " TEA" : "",
               d_bus, (ta_oe[0] && !ta_n_o[0]) ? "cpu0" : (ta_oe[1] && !ta_n_o[1]) ? "cpu1" : "memory",
               mi_n_o[0], mi_n_o[1]);
  end
  always @(negedge clk)
    if (prog_every > 0 && cyc % prog_every == 0 && wline != 32'hFFFF_FFFF) begin
      $display("        memory %h: %h %h %h %h", wline, u_mem.peek_long(wline), u_mem.peek_long(wline + 4),
               u_mem.peek_long(wline + 8), u_mem.peek_long(wline + 12));
      `SMP_DC_LOOK(0)
      `SMP_DC_LOOK(1)
    end

  initial begin
    #1;
    repeat (tmo) @(negedge clk);
    if (!done) begin
      $display("  FAIL: timed out at clock %0d: CPU 0 at PC %h, CPU 1 at PC %h; errors %0d/%0d, first %h/%h",
               cyc, cpu[0].dut.u_core.w_u.pc, cpu[1].dut.u_core.w_u.pc,
               u_mem.peek_long(ERR_A), u_mem.peek_long(ERR_A + 4),
               u_mem.peek_long(FIRST_A), u_mem.peek_long(FIRST_A + 4));
      $display("  barriers: CPU 0 at %h, CPU 1 at %h; arbiter state %0d",
               u_mem.peek_long(CI + 32'h10), u_mem.peek_long(CI + 32'h14), arb_state);
      report_bus();
      $display("FAIL: core_smp_tb");
      $finish;
    end
  end

endmodule
