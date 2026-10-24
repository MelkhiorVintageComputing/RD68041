// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- a serialised page's reads made once each (UM 4.3.2:
// "Serialization forces operand read accesses for an instruction to occur
// only once by preventing the instruction from being interrupted after the
// operand fetch stage"): sim/programs/m14_serial.S reads $40008000, on a page
// DTT0 makes serialised, four times a pass, behind a mispredicted branch past
// another read of it, while this bench raises level 2 every few clocks and
// arms a bus retry (TA with TEA, UM 7.6.2) of it every 37. The slave counts the
// transfers that start there: exactly the reads executed and the retries.
// (M14: MAME's Quadra found the core reading its SCSI controller's FIFO twice
// when an interrupt came between an instruction's read and its end.)

`timescale 1ns / 1ps

module core_ser_tb;

`include "rd68041_core_harness.svh"

  localparam logic [31:0] OUT  = 32'h0000_FD00;
  localparam logic [31:0] DONE = 32'h0000_FDFC;
  localparam int LOOPS = 200;

  string       image;
  bit          done;
  int          phase;

  // Level 2 for 4 clocks out of every 17, 19 or 23 in turn: interrupts land
  // everywhere in the loop. (Changed on the falling edge, as the harness
  // wants.)
  int period = 17;
  always @(negedge clk) begin
    if (rst_n && !done) begin
      phase = phase + 1;
      if (phase >= period) begin
        phase = 0;
        period = (period == 17) ? 19 : (period == 19) ? 23 : 17;
      end
      ipl_n = (phase < 4) ? 3'b101 : 3'b111;
    end else begin
      ipl_n = 3'b111;
    end
  end

  // A retry armed on the watched long word every 37 clocks (the slave's region
  // 1, over region 0's memory); how many were taken.
  int armed = 0, taken = 0, rclk = 0;
  bit phase_go = 0;           // the program is loaded: retries may be armed
  always @(negedge clk) begin
    if (rst_n && !done && phase_go) begin
      rclk++;
      if (rclk % 37 == 0) begin
        if (armed && u_mem.r_retry[1] == 0) taken++;
        u_mem.set_region(1, 32'h4000_8000, 32'hFFFF_FFFC, 0, 0, 0, -1, 1);
        armed = 1;
      end
    end
  end
  always @(posedge clk) begin
    if (!done && rst_n && (u_mem.peek_long(DONE) == 32'hC0DE_0000 || dut.u_core.halted)) begin
      int ints, bad, reads;
      done = 1;
      repeat (8) @(posedge clk);
      ints  = int'(u_mem.peek_long(OUT));
      bad   = int'(u_mem.peek_long(OUT + 4));
      reads = u_mem.watch_reads;
      if (armed && u_mem.r_retry[1] == 0) taken++;
      if (bad == 0 && ints > 20 && reads == 4 * LOOPS + taken && reg_of(3) == 4 * LOOPS)
        $display("PASS: core_ser_tb: %0d serialised reads, %0d executed and %0d retried, %0d interrupts", reads, 4 * LOOPS, taken, ints);
      else
        $display("FAIL: core_ser_tb: %0d serialised reads for %0d executed and %0d retried (D3 %0d), %0d interrupts, %0d bad exceptions",
                 reads, 4 * LOOPS, taken, reg_of(3), ints, bad);
      $finish;
    end
  end

  initial begin
    if (!$value$plusargs("image=%s", image)) image = "build/programs/m14_serial.hex";
    done = 0; phase = 0;
    boot(image);
    u_mem.set_watch(32'h4000_8000);
    phase_go = 1;
  end

  initial begin
    #20000000;
    if (!done) begin
      $display("  FAIL: timed out at PC %h", dut.u_core.w_u.pc);
      $display("FAIL: core_ser_tb");
      $finish;
    end
  end

endmodule
