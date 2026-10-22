// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- the bus unit on its own, against the slave model: shared by the
// bus_*_tb testbenches, `include`d inside each one's module.
//
// The bus unit's request port is fed from a queue (`push`), one request per
// accepted edge, so back-to-back transfers are what the bus unit makes of a
// queue that is never empty. Every response is logged (`r_*`); `run_queue`
// waits for the queue to drain and the last request to finish. The bus is
// resolved here as a board would: a pin nobody drives floats to its pull-up.
//
// The testbench changes what the design samples only away from the rising
// edge, at the falling edge (doc/coding-standard.md: a testbench that changes
// an input on the rising edge races the design).

logic clk = 1'b0;
always #20 clk = ~clk;              // BCLK, 25 MHz: the period does not matter here

logic rst_n = 1'b0;
logic crst  = 1'b1;

// --- the request port ---------------------------------------------------------
logic         req_valid, req_ready;
logic [31:0]  req_addr;
logic         req_write;
logic  [1:0]  req_siz, req_tt, req_tln, req_upa;
logic  [2:0]  req_tm;
logic         req_ciout, req_lock, req_locke, req_more;
logic [127:0] req_wdata;
logic         lock_seq = 1'b0;

logic         rsp_valid, rsp_tci, rsp_avec, rsp_done, rsp_err, owner;
logic  [1:0]  rsp_beat, rsp_lw;
logic [31:0]  rsp_data;

// --- the pins -----------------------------------------------------------------
logic [31:0] a_o, d_o, slave_d;
logic        a_oe, d_oe, attr_oe, slave_d_oe;
logic  [1:0] tt_o, tln_o, upa_o, siz_o;
logic  [2:0] tm_o;
logic        rw_o, lock_n_o, locke_n_o, ciout_n_o, ts_n_o, tip_n_o, tip_oe;
logic        br_n_o, bb_n_o, bb_oe, mi_n_o;
logic        ta_n, tea_n, tbi_n, tci_n, avec_n;
logic        bg_n = 1'b0;           // the arbiter: granted unless a test says otherwise
logic        alt_bb_n = 1'b1;       // an alternate master's BB
logic        alt_bb_oe = 1'b0;

// The board: what is on each wire.
wire [31:0] dbus  = d_oe ? d_o : (slave_d_oe ? slave_d : 32'hzzzz_zzzz);
wire        bb_w  = bb_oe ? bb_n_o : (alt_bb_oe ? alt_bb_n : 1'b1);
wire        tip_w = tip_oe ? tip_n_o : 1'b1;
wire        ts_w  = attr_oe ? ts_n_o : 1'b1;

rd68041_biu u_biu (
    .clk(clk), .rst_n(rst_n), .crst(crst),
    .req_valid(req_valid), .req_ready(req_ready), .req_addr(req_addr),
    .req_write(req_write), .req_siz(req_siz), .req_tt(req_tt), .req_tm(req_tm),
    .req_tln(req_tln), .req_upa(req_upa), .req_ciout(req_ciout),
    .req_lock(req_lock), .req_locke(req_locke), .req_more(req_more),
    .req_wdata(req_wdata), .lock_seq(lock_seq),
    .rsp_valid(rsp_valid), .rsp_beat(rsp_beat), .rsp_lw(rsp_lw),
    .rsp_data(rsp_data), .rsp_tci(rsp_tci), .rsp_avec(rsp_avec),
    .rsp_done(rsp_done), .rsp_err(rsp_err), .owner(owner),
    .a_o(a_o), .a_oe(a_oe), .d_i(dbus), .d_o(d_o), .d_oe(d_oe),
    .tt_o(tt_o), .tm_o(tm_o), .tln_o(tln_o), .upa_o(upa_o), .rw_o(rw_o),
    .siz_o(siz_o), .lock_n_o(lock_n_o), .locke_n_o(locke_n_o),
    .ciout_n_o(ciout_n_o), .attr_oe(attr_oe), .ts_n_o(ts_n_o),
    .tip_n_o(tip_n_o), .tip_oe(tip_oe), .ta_n_i(ta_n), .tea_n_i(tea_n),
    .tci_n_i(tci_n), .tbi_n_i(tbi_n), .avec_n_i(avec_n), .br_n_o(br_n_o),
    .bg_n_i(bg_n), .bb_n_i(bb_w), .bb_n_o(bb_n_o), .bb_oe(bb_oe),
    .mi_n_o(mi_n_o)
);

rd68041_slave #(.MEM_BYTES(65536)) u_slave (
    .clk(clk), .a(a_o), .d_in(dbus), .d_out(slave_d), .d_oe(slave_d_oe),
    .tt(tt_o), .tm(tm_o), .rw(rw_o), .siz(siz_o), .ts_n(ts_w), .mi_n(mi_n_o),
    .ta_n(ta_n), .tea_n(tea_n), .tbi_n(tbi_n), .tci_n(tci_n), .avec_n(avec_n)
);

rd68041_busmon u_mon (
    .clk(clk), .active(!crst), .a_o(a_o), .a_oe(a_oe), .attr_oe(attr_oe),
    .tt_o(tt_o), .tm_o(tm_o), .siz_o(siz_o), .rw_o(rw_o), .d_oe(d_oe),
    .ts_n_o(ts_n_o), .tip_n_o(tip_n_o), .tip_oe(tip_oe), .bb_n_o(bb_n_o),
    .bb_oe(bb_oe), .slave_d_oe(slave_d_oe), .ta_n(ta_n), .tea_n(tea_n),
    .tbi_n(tbi_n), .alt_owns(alt_bb_oe && !alt_bb_n)
);

// --- the request queue --------------------------------------------------------
localparam int QN = 64;
logic [31:0]  q_addr  [0:QN-1];
logic         q_write [0:QN-1];
logic  [1:0]  q_siz   [0:QN-1];
logic  [1:0]  q_tt    [0:QN-1];
logic  [2:0]  q_tm    [0:QN-1];
logic         q_lock  [0:QN-1];
logic         q_locke [0:QN-1];
logic         q_ciout [0:QN-1];
logic [127:0] q_wdata [0:QN-1];
int q_head = 0, q_tail = 0;
int acc_edge [0:QN-1];          // the cycle each request was taken on

int cyc = 0;                    // rising edges since reset was released
always @(posedge clk) cyc <= cyc + 1;

task automatic push(input logic [31:0] addr, input bit write, input logic [1:0] siz,
                    input logic [127:0] wdata = '0, input logic [1:0] tt = 2'b00,
                    input logic [2:0] tm = 3'b101, input bit lock = 0,
                    input bit locke = 0, input bit ciout = 0);
  q_addr[q_tail] = addr; q_write[q_tail] = write; q_siz[q_tail] = siz;
  q_tt[q_tail] = tt; q_tm[q_tail] = tm; q_lock[q_tail] = lock;
  q_locke[q_tail] = locke; q_ciout[q_tail] = ciout; q_wdata[q_tail] = wdata;
  q_tail = q_tail + 1;
endtask

// The port shows the head of the queue; req_more says another one follows.
// q_head moves by a non-blocking assignment on the rising edge that takes a
// request, so the port changes after the bus unit has sampled it on that edge,
// as a registered requester's would.
task automatic update_port();
  req_valid = (q_head < q_tail);
  req_addr  = q_addr[q_head];  req_write = q_write[q_head];
  req_siz   = q_siz[q_head];   req_tt    = q_tt[q_head];
  req_tm    = q_tm[q_head];    req_lock  = q_lock[q_head];
  req_locke = q_locke[q_head]; req_ciout = q_ciout[q_head];
  req_wdata = q_wdata[q_head];
  req_tln   = 2'b00;           req_upa   = 2'b00;
  req_more  = (q_head + 1 < q_tail);
endtask

always @(q_head, q_tail) update_port();
initial update_port();

always @(posedge clk) if (req_valid && req_ready) begin
  acc_edge[q_head] = cyc + 1;     // cyc as the response log reads it, after this edge
  q_head <= q_head + 1;
end

// --- the response log ---------------------------------------------------------
int          n_rsp = 0, n_done = 0, n_err = 0;
logic [31:0] r_data [0:255];
logic  [1:0] r_lw   [0:255];
logic  [1:0] r_beat [0:255];
logic        r_tci  [0:255];
logic        r_avec [0:255];
int          done_edge [0:QN-1];
int          err_beat  [0:QN-1];

always @(posedge clk) begin
  #1;
  if (rsp_valid) begin
    r_data[n_rsp] = rsp_data; r_lw[n_rsp] = rsp_lw; r_beat[n_rsp] = rsp_beat;
    r_tci[n_rsp] = rsp_tci; r_avec[n_rsp] = rsp_avec;
    n_rsp = n_rsp + 1;
  end
  if (rsp_done) begin
    done_edge[n_done] = cyc;
    err_beat[n_done]  = rsp_err ? int'(rsp_beat) : -1;
    if (rsp_err) n_err = n_err + 1;
    n_done = n_done + 1;
  end
end

// --- checking -----------------------------------------------------------------
int fails = 0;
int checks = 0;

task automatic check(input bit ok, input string what);
  checks = checks + 1;
  if (!ok) begin
    fails = fails + 1;
    $display("  FAIL: %s", what);
  end
endtask

task automatic reset_all();
  rst_n = 1'b0; crst = 1'b1;
  repeat (2) @(negedge clk);
  rst_n = 1'b1;
  repeat (2) @(negedge clk);
  crst = 1'b0;
  @(negedge clk);
endtask

// Wait, a cycle at a time, until every queued request is done (or give up).
task automatic run_queue(input int limit = 200);
  int t;
  t = 0;
  while ((q_head < q_tail || n_done < q_tail) && t < limit) begin
    @(negedge clk);
    t = t + 1;
  end
  check(n_done == q_tail, $sformatf("queue drained (%0d of %0d done)", n_done, q_tail));
  @(negedge clk);
endtask

// The edges from a request being taken to its response: 2 for a zero-wait
// transfer (C1, C2; UM 7.4.1).
function automatic int clocks_of(input int i);
  clocks_of = done_edge[i] - acc_edge[i];
endfunction

task automatic finish(input string name);
  fails = fails + u_mon.errors;
  if (fails == 0) $display("PASS: %s: %0d checks", name, checks);
  else            $display("FAIL: %s: %0d of %0d checks, %0d monitor", name, fails, checks, u_mon.errors);
  $finish;
endtask
