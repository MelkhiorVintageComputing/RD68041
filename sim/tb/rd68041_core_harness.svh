// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- the whole processor on a board: rd68041_top, the slave model as
// 64 KB of RAM repeated through the address space, and the bus always granted.
// `include`d inside each core testbench's module.
//
// The testbench changes what the design samples only on the falling edge
// (doc/coding-standard.md).

logic clk = 1'b0;
always #20 clk = ~clk;

logic rst_n  = 1'b0;
logic rsti_n = 1'b0;

logic [31:0] a_o, d_o, slave_d;
logic        a_oe, d_oe, attr_oe, slave_d_oe;
logic  [1:0] tt_o, tln_o, upa_o, siz_o;
logic  [2:0] tm_o;
logic        rw_o, lock_n_o, locke_n_o, ciout_n_o, ts_n_o, ts_oe, tip_n_o, tip_oe;
logic        ta_n_o, ta_oe, br_n_o, bb_n_o, bb_oe, mi_n_o, rsto_n_o, ipend_n_o;
logic  [3:0] pst_o;
logic        tdo_o, tdo_oe;
logic        s_ta_n, tea_n, tbi_n, tci_n, avec_n;
logic        bg_n = 1'b0;

wire [31:0] dbus  = d_oe ? d_o : (slave_d_oe ? slave_d : 32'hzzzz_zzzz);
wire        bb_w  = bb_oe ? bb_n_o : 1'b1;
wire        ts_w  = ts_oe ? ts_n_o : 1'b1;
wire        ta_n  = s_ta_n & (ta_oe ? ta_n_o : 1'b1);

rd68041_top #(.FPU(`TB_FPU)) dut (
    .clk(clk), .pclk(1'b0), .rst_n(rst_n), .rsti_n_i(rsti_n), .rsto_n_o(rsto_n_o),
    .a_i(a_o), .a_o(a_o), .a_oe(a_oe), .d_i(dbus), .d_o(d_o), .d_oe(d_oe),
    .tt_i(tt_o), .tt_o(tt_o), .tm_o(tm_o), .tln_o(tln_o), .upa_o(upa_o),
    .rw_i(rw_o), .rw_o(rw_o), .siz_i(siz_o), .siz_o(siz_o),
    .lock_n_o(lock_n_o), .locke_n_o(locke_n_o), .ciout_n_o(ciout_n_o), .attr_oe(attr_oe),
    .ts_n_i(ts_w), .ts_n_o(ts_n_o), .ts_oe(ts_oe), .tip_n_o(tip_n_o), .tip_oe(tip_oe),
    .ta_n_i(ta_n), .ta_n_o(ta_n_o), .ta_oe(ta_oe), .tea_n_i(tea_n), .tci_n_i(tci_n),
    .tbi_n_i(tbi_n), .dle_i(1'b0), .sc_i(2'b00), .mi_n_o(mi_n_o),
    .br_n_o(br_n_o), .bg_n_i(bg_n), .bb_n_i(bb_w), .bb_n_o(bb_n_o), .bb_oe(bb_oe),
    .cdis_n_i(1'b1), .mdis_n_i(1'b1), .ipl_n_i(3'b111), .ipend_n_o(ipend_n_o),
    .avec_n_i(avec_n), .pst_o(pst_o),
    .tck_i(1'b0), .tms_i(1'b0), .tdi_i(1'b0), .trst_n_i(1'b1), .tdo_o(tdo_o), .tdo_oe(tdo_oe));

rd68041_slave #(.MEM_BYTES(65536)) u_mem (
    .clk(clk), .a(a_o), .d_in(dbus), .d_out(slave_d), .d_oe(slave_d_oe),
    .tt(tt_o), .tm(tm_o), .rw(rw_o), .siz(siz_o), .ts_n(ts_w), .mi_n(mi_n_o),
    .ta_n(s_ta_n), .tea_n(tea_n), .tbi_n(tbi_n), .tci_n(tci_n), .avec_n(avec_n));

// The architectural registers, as the trace orders them.
function automatic logic [31:0] reg_of(input int i);
  reg_of = dut.u_core.u_rf.r[i];
endfunction

int cyc = 0;
always @(posedge clk) cyc <= cyc + 1;

task automatic boot(input string image);
  u_mem.load_hex(image);
  u_mem.set_region(0, 32'h0000_0000, 32'h0000_0000, 0, 0, 0, -1, 0);
  rst_n = 1'b0; rsti_n = 1'b0;
  repeat (4) @(negedge clk);
  rst_n = 1'b1;
  repeat (12) @(negedge clk);
  rsti_n = 1'b1;
endtask
