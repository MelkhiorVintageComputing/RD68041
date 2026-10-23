// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- interrupts, STOP, RESET and BKPT: sim/programs/m8_int.S on the
// core, IPL driven as the program asks (its DOOR long word: the level, how the
// acknowledge ends, a delay), and what it leaves checked against the manual:
//
//   UM 8.2.9   the level, autovector, vectored and spurious interrupts; a mask
//              that holds an interrupt off until MOVE to SR lowers it; level 7
//              under a mask of 7; STOP until an interrupt, the frame's PC the
//              instruction after it; with M set, the $0 frame on the master
//              stack and the throwaway $1 on the interrupt stack, and RTE of
//              it back through the master stack's (UM 8.4.2)
//   UM 7.5.1   each interrupt acknowledge cycle: TT 11, TM the level,
//              A31-A0 $FFFFFFFF, a byte; IPEND asserted before it
//   UM 7.5.2   BKPT's acknowledge cycle: TT 11, TM 0, A31-A0 0, a byte; then
//              the illegal instruction exception
//   UM 7.10    RESET: RSTO for 512 clocks
//
// No oracle runs interrupts (doc/oracles.md), so the expectations are written
// here, from the manual.

`timescale 1ns / 1ps

module core_exc_tb;

`include "rd68041_core_harness.svh"

  localparam logic [31:0] DOOR = 32'h0000_FF00;
  localparam logic [31:0] RES  = 32'h0000_FE00;

  string       image;
  int unsigned nfail, niack, nbkpt, rsto_clocks, delay;
  logic [31:0] door, door_was;
  logic  [2:0] pend_lvl;
  bit          ipend_seen, done;
  logic  [2:0] iack_lvl [0:15];
  bit          iack_ipend [0:15];

  // The levels the program asks for, in order, and the acknowledges' answers.
  localparam int NINT = 7;
  function automatic logic [31:0] want_lvl(input int i);
    case (i)
      0: want_lvl = 3;  1: want_lvl = 5;  2: want_lvl = 2;  3: want_lvl = 3;
      4: want_lvl = 7;  5: want_lvl = 4;  default: want_lvl = 6;
    endcase
  endfunction

  task automatic check(input string what, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
      $display("  FAIL: %s is %h, expected %h", what, got, exp);
      nfail++;
    end
  endtask

  // DOOR: the program's requests (the bench polls the memory behind it).
  always @(negedge clk) begin
    if (rst_n && !done) begin
      door = u_mem.peek_long(DOOR);
      if (door !== door_was) begin
        door_was = door;
        if (door[2:0] == 3'd0) begin
          ipl_n = 3'b111;
        end else begin
          u_mem.iack_kind[door[2:0]] = int'(door[9:8]);
          delay = door[31:16] + 1;
          pend_lvl = door[2:0];
        end
      end
      // A request's delay, counted down; then IPL.
      if (delay != 0) begin
        delay--;
        if (delay == 0) ipl_n = ~pend_lvl;
      end
    end
  end

  // The acknowledge cycles, as they start on the bus.
  always @(posedge clk) begin
    if (!ts_w && tt_o == 2'b11) begin
      if (a_o == 32'hFFFF_FFFF) begin
        if (niack < 16) begin
          iack_lvl[niack] = tm_o;
          iack_ipend[niack] = ipend_seen;
        end
        if (siz_o !== rd68041_pkg::SIZ_BYTE || !rw_o) begin
          $display("  FAIL: interrupt acknowledge %0d: SIZ %b R/W %b, a byte read expected",
                   niack, siz_o, rw_o);
          nfail++;
        end
        niack++;
        ipend_seen = 0;
      end else if (a_o == 32'h0000_0000) begin
        nbkpt++;
        if (tm_o !== 3'd0 || siz_o !== rd68041_pkg::SIZ_BYTE || !rw_o) begin
          $display("  FAIL: breakpoint acknowledge: TM %0d SIZ %b R/W %b", tm_o, siz_o, rw_o);
          nfail++;
        end
      end
    end
    if (!ipend_n_o) ipend_seen = 1;
    if (!rsto_n_o) rsto_clocks++;
  end

  // The end: the illegal instruction exception on the program's ILLEGAL.
  always @(posedge clk) begin
    logic [31:0] hw, pc;
    pc = dut.u_core.w_u.pc;
    hw = u_mem.peek_long({pc[31:2], 2'b00});
    if (!done && dut.u_core.x_flush && dut.u_core.w_u.xvec == 8'd4 &&
        (pc[1] ? hw[15:0] : hw[31:16]) == 16'h4AFC) begin
      done = 1;
      #1 finish_up();
    end
    if (!done && dut.u_core.halted) begin
      done = 1;
      $display("  FAIL: halted at %h", dut.u_core.w_u.pc);
      $display("FAIL: core_exc_tb");
      $finish;
    end
  end

  function automatic logic [15:0] rdw(input logic [31:0] a);
    logic [31:0] l;
    l = u_mem.peek_long({a[31:2], 2'b00});
    rdw = a[1] ? l[15:0] : l[31:16];
  endfunction

  task automatic finish_up();
    // (g)'s two frames, still below the stack pointers: the $0 on the master
    // stack and the $1 on the interrupt stack, the same PC; the throwaway's
    // SR the master copy's with S set (M too: doc/manual-contradictions.md).
    check("(g) the master frame's SR (system byte)", {16'h0, rdw(32'hDFF8) & 16'hFF00}, 32'h3000);
    check("(g) the master frame's word", {16'h0, rdw(32'hDFFE)}, 32'h0078);
    check("(g) the throwaway frame's SR (system byte)", {16'h0, rdw(32'hEFF8) & 16'hFF00}, 32'h3000);
    check("(g) the throwaway frame's word", {16'h0, rdw(32'hEFFE)}, 32'h1078);
    check("(g) the two frames' PC", u_mem.peek_long(32'hEFF8 + 2), u_mem.peek_long(32'hDFF8 + 2));
    // The program's last writes may still be on their way; the ILLEGAL's
    // frame waits for them (and is what overwrites the throwaway frame, read
    // above).
    wait (dut.u_core.st_empty);
    // What each interrupt left: its format and vector word, the system byte
    // its handler ran with.
    check("(a) level 3 autovector: the format and vector word", rdw(RES + 0), 16'h006C);
    check("(a) its handler's SR", rdw(RES + 2), 16'h2300);
    check("(b) level 5, vector $45", rdw(RES + 4), 16'h0114);
    check("(b) its handler's SR", rdw(RES + 6), 16'h2500);
    check("(c) level 2, TEA: the spurious interrupt", rdw(RES + 8), 16'h0060);
    check("(c) its handler's SR", rdw(RES + 10), 16'h2200);
    check("(d) the count while masked", u_mem.peek_long(RES + 12), 32'd3);
    check("(d) level 3 once the mask came down", rdw(RES + 16), 16'h006C);
    check("(d) its handler's SR", rdw(RES + 18), 16'h2300);
    check("(e) level 7 under a mask of 7", rdw(RES + 20), 16'h007C);
    check("(e) its handler's SR", rdw(RES + 22), 16'h2700);
    check("(f) STOP woken by level 4", rdw(RES + 24), 16'h0070);
    check("(f) its handler's SR", rdw(RES + 26), 16'h2400);
    check("(f) the frame's PC, the instruction after STOP", u_mem.peek_long(RES + 28),
          u_mem.peek_long(RES + 32));
    check("(g) level 6 with M set: the throwaway frame's word", rdw(RES + 36), 16'h1078);
    check("(g) its handler's SR (M cleared)", rdw(RES + 38), 16'h2600);
    check("(g) the MSP after both RTEs", u_mem.peek_long(RES + 40), 32'h0000_E000);
    check("(g) the ISP after both RTEs", u_mem.peek_long(RES + 44), 32'h0000_F000);
    // The acknowledge cycles.
    check("the interrupt acknowledges", niack, NINT);
    for (int i = 0; i < NINT && i < int'(niack); i++) begin
      check($sformatf("acknowledge %0d's level (TM)", i), {29'h0, iack_lvl[i]}, want_lvl(i));
      if (!iack_ipend[i]) begin
        $display("  FAIL: acknowledge %0d: IPEND was not asserted before it", i);
        nfail++;
      end
    end
    check("the breakpoint acknowledges", nbkpt, 1);
    check("BKPT's handler (vector 4)", reg_of(5), 1);
    check("RSTO's clocks (UM 7.10)", rsto_clocks, 512);
    check("the interrupts counted", reg_of(7), NINT);
    check("vectors that should not have been taken (D6)", reg_of(6), 0);
    if (nfail == 0) $display("PASS: core_exc_tb: %0d interrupts, STOP, RESET, BKPT", NINT);
    else            $display("FAIL: core_exc_tb: %0d checks failed", nfail);
    $finish;
  endtask

  initial begin
    if (!$value$plusargs("image=%s", image)) image = "build/programs/m8_int.hex";
    nfail = 0; niack = 0; nbkpt = 0; rsto_clocks = 0; done = 0; ipend_seen = 0; delay = 0;
    door_was = 32'h0;
    u_mem.iack_vec[5] = 8'h45;
    boot(image);
  end

  initial begin
    #5000000;
    if (!done) begin
      $display("  FAIL: timed out: %0d interrupts acknowledged, D7 %0d", niack, reg_of(7));
      $display("FAIL: core_exc_tb");
      $finish;
    end
  end

endmodule
