// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- what the one-instruction sweeps (core_vec_tb, core_cputest_tb)
// add to the core harness. `include`d after rd68041_core_harness.svh, inside
// the testbench's module.
//
//   vec_boot      a reset with whatever is in memory: boot() without the image
//   mb/mw/ml      bytes, words and long words straight into the slave's array
//                 (64 KB, repeated through the address space)
//   rb/rw/rl      ... and out of it
//   the recorder  every operand access the core makes while cap_on is set,
//                 taken at the data memory unit's interface: a read when it
//                 completes (ld_done), a write when the unit takes it
//                 (st_valid && st_ready). Each is one operand, misaligned or
//                 not -- the unit splits it into bus transfers itself, as the
//                 oracles report them (uae040.h's operand hook). A read
//                 cancelled by a taken branch answers nobody and is not one.
//                 undo_writes() puts back what each write replaced.
//   the retires   the number of instructions completed while cap_on is set,
//                 and the next PC the last of them left (retire_npc)

localparam int VMEM = 65536;

task automatic vec_boot();
  u_mem.set_region(0, 32'h0000_0000, 32'h0000_0000, 0, 0, 0, -1, 0);
  rst_n = 1'b0; rsti_n = 1'b0;
  repeat (4) @(negedge clk);
  rst_n = 1'b1;
  repeat (12) @(negedge clk);
  rsti_n = 1'b1;
endtask

task automatic mb(input logic [31:0] a, input logic [7:0] v);
  u_mem.mem[a[15:0]] = v;
endtask
task automatic mw(input logic [31:0] a, input logic [15:0] v);
  logic [31:0] a1;
  a1 = a + 1;
  u_mem.mem[a[15:0]]  = v[15:8];
  u_mem.mem[a1[15:0]] = v[7:0];
endtask
task automatic ml(input logic [31:0] a, input logic [31:0] v);
  mw(a, v[31:16]);
  mw(a + 2, v[15:0]);
endtask

function automatic logic [7:0] rb(input logic [31:0] a);
  rb = u_mem.mem[a[15:0]];
endfunction
function automatic logic [15:0] rw(input logic [31:0] a);
  logic [31:0] a1;
  a1 = a + 1;
  rw = {u_mem.mem[a[15:0]], u_mem.mem[a1[15:0]]};
endfunction
function automatic logic [31:0] rl(input logic [31:0] a);
  rl = {rw(a), rw(a + 2)};
endfunction

// --- the recorder ------------------------------------------------------------
localparam int MAXCAP = 64;

bit          cap_on = 1'b0;
int          ncap;
logic [31:0] cap_addr [0:MAXCAP-1];
logic  [2:0] cap_bytes[0:MAXCAP-1];
logic        cap_rd   [0:MAXCAP-1];
logic [31:0] cap_data [0:MAXCAP-1];
logic [31:0] cap_old  [0:MAXCAP-1];   // what a write's four bytes held before it
int          nretire;
logic [31:0] last_npc;

function automatic logic [2:0] sz_bytes(input logic [1:0] sz);
  sz_bytes = (sz == rd68041_pkg::SZ_B) ? 3'd1 : (sz == rd68041_pkg::SZ_W) ? 3'd2 : 3'd4;
endfunction

task automatic cap_clear();
  ncap = 0;
  nretire = 0;
  last_npc = 32'hFFFF_FFFF;
endtask

// The handshakes are sampled at the edge they complete on, before it updates
// anything (every register is written with a nonblocking assignment).
// A read released to EX before its answer (rd68041_dmu ld_rel) is answered
// after <ea> fetch has moved on: its address and size are the ones asked for
// when it was released.
logic [31:0] rel_a;
logic  [1:0] rel_sz;
always @(posedge clk) begin
  if (cap_on && rst_n) begin
    // (A write's probe, with a TTR or translation on, is not an operand read.)
    if (dut.u_core.u_dmu.ld_done && dut.u_core.rs == 2'd2 &&
        (dut.u_core.u_dmu.rel_q || dut.u_core.u_dmu.rel_pend || !dut.u_core.u_dmu.ld_probe)) begin
      if (ncap < MAXCAP) begin
        if (dut.u_core.u_dmu.rel_q || dut.u_core.u_dmu.rel_pend) begin
          cap_addr[ncap]  = rel_a;
          cap_bytes[ncap] = sz_bytes(rel_sz);
        end else begin
          cap_addr[ncap]  = dut.u_core.u_dmu.ld_addr;
          cap_bytes[ncap] = sz_bytes(dut.u_core.u_dmu.ld_sz);
        end
        cap_rd[ncap]    = 1'b1;
        cap_data[ncap]  = dut.u_core.u_dmu.ld_data;
      end
      ncap = ncap + 1;
    end
    if (dut.u_core.u_dmu.ld_rel) begin
      rel_a  = dut.u_core.u_dmu.ld_addr;
      rel_sz = dut.u_core.u_dmu.ld_sz;
    end
    if (dut.u_core.u_dmu.st_valid && dut.u_core.u_dmu.st_ready) begin
      if (ncap < MAXCAP) begin
        cap_addr[ncap]  = dut.u_core.u_dmu.st_addr;
        cap_bytes[ncap] = sz_bytes(dut.u_core.u_dmu.st_sz);
        cap_rd[ncap]    = 1'b0;
        cap_old[ncap]   = rl(dut.u_core.u_dmu.st_addr);
        // Right justified; the unit sends only the operand's bytes of it.
        cap_data[ncap]  = dut.u_core.u_dmu.st_data &
                          ((dut.u_core.u_dmu.st_sz == rd68041_pkg::SZ_B) ? 32'h0000_00FF :
                           (dut.u_core.u_dmu.st_sz == rd68041_pkg::SZ_W) ? 32'h0000_FFFF :
                                                                          32'hFFFF_FFFF);
      end
      ncap = ncap + 1;
    end
    if (dut.u_core.retire) begin
      nretire  = nretire + 1;
      last_npc = dut.u_core.retire_npc;
    end
  end
end

// Undo every write the recorder saw, newest first: memory as it was before.
// (Each write is in the slave by the time run_one returns: it waits for the
// unit's queue to empty.)
task automatic undo_writes();
  logic [31:0] x;
  for (int q = ((ncap < MAXCAP) ? ncap : MAXCAP) - 1; q >= 0; q--)
    if (!cap_rd[q])
      for (int b = 0; b < int'(cap_bytes[q]); b++) begin
        x = cap_addr[q] + b;
        u_mem.mem[x[15:0]] = cap_old[q][31 - 8 * b -: 8];
      end
endtask

