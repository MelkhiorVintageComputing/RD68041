// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- the MMU: sim/programs/m10_mmu.S on the core, its translation
// tables in the board's RAM, and what it did checked against the manual:
//
//   UM 3.2     translation through the tables, an indirect page descriptor,
//              code fetched through the instruction ATC
//   UM 3.2.5   U set in every descriptor a search reads (a table
//              descriptor's by a write, a page descriptor's by a locked
//              read-modify-write on a read); U and M by a write on a write
//              (Table 3-1); a write-protected page's M left clear
//   UM 8.4.6   the access faults' frames: ATC set, RW clear for the write,
//              MA for the second page of a long word across two, FA the
//              access's first byte, TM the space (an instruction fetch's $6)
//   UM 3.1.4   PTEST's MMUSR: PA, M, W, R; zero for an invalid page; T and
//              R for a TTR
//   UM 3.7.2   PFLUSH: the ATC's entry used until it is flushed
//
// +cacr=<hex> and +cm=<hex> run it with the caches on, the pages holding the
// tables cached in that mode (make cache). The program itself runs under make
// cosim too (PROGS=m10_mmu), against UAE040.

`timescale 1ns / 1ps

module core_mmu_tb;

`include "rd68041_core_harness.svh"

  localparam logic [31:0] RES  = 32'h0000_FE00;
  localparam logic [31:0] OUT  = 32'h0000_FD00;
  localparam logic [31:0] DONE = 32'h0000_FDFC;
  localparam logic [31:0] CFG  = 32'h0000_FDE8;

  logic [31:0] cacr, cm;

  string       image;
  int unsigned nfail;
  bit          done;

  task automatic check(input string what, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
      $display("  FAIL: %s is %h, expected %h", what, got, exp);
      nfail++;
    end
  endtask

  function automatic logic [15:0] rdw(input logic [31:0] a);
    logic [31:0] l;
    l = u_mem.peek_long({a[31:2], 2'b00});
    rdw = a[1] ? l[15:0] : l[31:16];
  endfunction
  function automatic logic [31:0] rdl(input logic [31:0] a);
    rdl = {rdw(a), rdw(a + 2)};
  endfunction

  task automatic record(input int k, input string what, input logic [7:0] sys,
                        input logic [31:0] pc, input logic [15:0] ssw, input logic [31:0] fa);
    logic [31:0] r;
    logic [15:0] srw;
    r = RES + 20 * k;
    srw = rdw(r);
    check({what, ": the stacked SR's system byte"}, {24'h0, srw[15:8]}, {24'h0, sys});
    if (pc != 32'h0) check({what, ": the stacked PC"}, rdl(r + 2), pc);
    check({what, ": the format and vector word"}, {16'h0, rdw(r + 6)}, 32'h7008);
    check({what, ": the SSW"}, {16'h0, rdw(r + 8)}, {16'h0, ssw});
    check({what, ": FA"}, rdl(r + 10), fa);
  endtask

  task automatic finish_up();
    // SSW (UM 8.4.6.2): CP CU CT CM MA ATC LK RW X SIZE(2) TT(2) TM(3).
    record(0, "(a) a write to a write-protected page", 8'h27, 32'h0, 16'h0405, 32'h0001_1000);
    record(1, "(b) a read of an invalid page",         8'h27, 32'h0, 16'h0505, 32'h0001_2000);
    record(2, "(c) a long word across into it",        8'h27, 32'h0, 16'h0D05, 32'h0001_1FFE);
    record(3, "(d) a user read of a supervisor page",  8'h07, 32'h0, 16'h0541, 32'h0001_3000);
    record(4, "(e) a fetch from an invalid page",      8'h27, 32'h0001_6000, 16'h0506,
           32'h0001_6000);
    check("a read through page $10", rdl(OUT + 32'h00), 32'h1122_3344);
    check("a write through page $10, in $C008", rdl(32'h0000_C008), 32'h5566_7788);
    check("a read through the indirect page $14", rdl(OUT + 32'h04), 32'h1122_3344);
    check("code run from page $15 (D5)", rdl(OUT + 32'h08), 32'd42);
    check("PTESTR of page $10: MMUSR", rdl(OUT + 32'h10), 32'h0000_C011);
    check("PTESTR of the invalid page: MMUSR", rdl(OUT + 32'h14), 32'h0000_0000);
    check("PTESTW of the write-protected page: MMUSR", rdl(OUT + 32'h18), 32'h0000_D005);
    check("PTESTR of a DTT0 address: MMUSR", rdl(OUT + 32'h1C), 32'h0000_0003);
    check("PTESTR of page $15, program space: MMUSR", rdl(OUT + 32'h20), rdl(OUT + 32'h30));
    check("page $10's descriptor: U and M", rdl(OUT + 32'h24), 32'h0000_C019);
    check("PFLUSH: before, the old entry", rdl(OUT + 32'h28), 32'h1122_3344);
    check("PFLUSH: after, the new one", rdl(OUT + 32'h2C), 32'h99AA_BBCC);
    check("the root descriptor: U", rdl(32'h0000_A000), 32'h0000_A20A);
    check("the pointer descriptor: U", rdl(32'h0000_A200), 32'h0000_A40A);
    check("page 0's descriptor: U", rdl(32'h0000_A400), 32'h0000_0009 | cm);
    check("page $F's descriptor (the stack): U and M", rdl(32'h0000_A43C), 32'h0000_F019 | cm);
    check("page $11's descriptor: U, not M", rdl(32'h0000_A444), 32'h0000_D00D);
    check("page $12's descriptor: invalid, untouched", rdl(32'h0000_A448), 32'h0000_0000);
    check("page $13's descriptor: U", rdl(32'h0000_A44C), 32'h0000_E089);
    check("page $14's indirect descriptor: untouched", rdl(32'h0000_A450), 32'h0000_A5F2);
    check("the page descriptor it points to: U", rdl(32'h0000_A5F0), 32'h0000_C009);
    check("no stray exception (D6)", reg_of(6), 32'h0);
    if (nfail == 0 && cacr != 0)
      $display("PASS: core_mmu_tb: translation, five ATC faults, PTEST, PFLUSH (CACR %h, CM %h)",
               cacr, cm);
    else if (nfail == 0)
      $display("PASS: core_mmu_tb: translation, five ATC faults, PTEST, PFLUSH");
    else            $display("FAIL: core_mmu_tb: %0d checks failed", nfail);
    $finish;
  endtask

  always @(posedge clk) begin
    if (!done && rst_n && (u_mem.peek_long(DONE) == 32'hC0DE_0000 || dut.u_core.halted)) begin
      done = 1;
      repeat (8) @(posedge clk);
      finish_up();
    end
  end

  initial begin
    if (!$value$plusargs("image=%s", image)) image = "build/programs/m10_mmu.hex";
    if (!$value$plusargs("cacr=%h", cacr)) cacr = 32'h0;
    if (!$value$plusargs("cm=%h", cm)) cm = 32'h0;
    nfail = 0; done = 0;
    boot(image);
    // Before the program reads them, which it does well after the reset.
    u_mem.poke_long(CFG, cacr);
    u_mem.poke_long(CFG + 4, cm);
  end

  initial begin
    #5000000;
    if (!done) begin
      $display("  FAIL: timed out at PC %h", dut.u_core.w_u.pc);
      $display("FAIL: core_mmu_tb");
      $finish;
    end
  end

endmodule
