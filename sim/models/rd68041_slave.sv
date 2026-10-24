// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- an MC68040 bus slave, for the testbenches.
//
// Memory behind the MC68040 bus as UM 7.4-7.6 describe the other side of it:
// the slave recognises TS on a rising edge, and from the clock after drives TA
// (or TEA, TBI, TCI) for the edge the processor samples it on -- the minimum
// transfer is C1 and C2, two clocks (UM 7.4.1). A line is four long words in
// A3-A2 order from the one addressed, wrapping (UM 7.4.2), unless the region
// burst-inhibits it, when the slave answers its first long word with TBI and
// then three ordinary long-word transfers.
//
// The QuadraFPGA gateware (Inputs/QuadraFPGA, a slave known to work with real
// MC68040s; CLAUDE.md) answers the same way: a line burst to its memory, TBI
// for the rest.
//
// The behaviour is per region, programmed by the testbench through the tasks
// at the bottom: wait states before each TA, burst-inhibit, cache-inhibit, a
// bus error on a given long word of a transfer, or a number of retries before
// it is accepted. An interrupt acknowledge (TT = 3, A = $FFFFFFFF) is answered
// with a vector, an autovector or TEA (UM 7.5.1, Table 7-4); a breakpoint
// acknowledge (TT = 3, A = 0) with TA or TEA.
//
// Every TA, TEA, TBI, TCI and AVEC is registered: driven from just after one
// rising edge to just after the next, as a synchronous slave drives them.

`timescale 1ns/1ps

module rd68041_slave #(
    parameter int MEM_BYTES = 65536
) (
    input  logic        clk,
    // The bus as the slave sees it (already resolved).
    input  logic [31:0] a,
    input  logic [31:0] d_in,      // the data bus, for writes
    output logic [31:0] d_out,
    output logic        d_oe,
    input  logic  [1:0] tt,
    input  logic  [2:0] tm,
    input  logic        rw,
    input  logic  [1:0] siz,
    input  logic        ts_n,
    input  logic        mi_n,      // the slave waits for MI negated (UM 7.9)
    output logic        ta_n,
    output logic        tea_n,
    output logic        tbi_n,
    output logic        tci_n,
    output logic        avec_n
);

  logic [7:0] mem [0:MEM_BYTES-1];

  // --- the regions ----------------------------------------------------------
  localparam int NREG = 8;
  logic [31:0] r_base [0:NREG-1];
  logic [31:0] r_mask [0:NREG-1];
  int          r_wait [0:NREG-1];   // wait states before each TA
  bit          r_tbi  [0:NREG-1];   // burst-inhibit lines
  bit          r_tci  [0:NREG-1];   // cache-inhibit lines
  int          r_berr [0:NREG-1];   // TEA on this long word of a transfer, -1 never
  int          r_retry[0:NREG-1];   // retries left before a transfer is accepted
  bit          r_on   [0:NREG-1];

  // Interrupt acknowledge, per level 1-7: 0 vector, 1 autovector, 2 TEA.
  int          iack_kind [1:7];
  logic [7:0]  iack_vec  [1:7];
  int          iack_retry;
  // Breakpoint acknowledge: 0 TA, 1 TEA.
  int          bkpt_kind;

  initial begin
    for (int i = 0; i < NREG; i++) r_on[i] = 0;
    for (int i = 1; i <= 7; i++) begin iack_kind[i] = 1; iack_vec[i] = 8'h40 + i[7:0]; end
    iack_retry = 0;
    bkpt_kind  = 0;
    for (int i = 0; i < MEM_BYTES; i++) mem[i] = 8'h00;
  end

  function automatic int region_of(input logic [31:0] addr);
    region_of = -1;
    // The highest-numbered region that matches wins, so a test can carve a
    // window out of a larger one.
    for (int i = 0; i < NREG; i++)
      if (r_on[i] && ((addr & r_mask[i]) == r_base[i])) region_of = i;
  endfunction

  // --- the transfer the slave is answering ---------------------------------
  bit          busy;
  logic [31:0] x_a;
  logic  [1:0] x_tt, x_siz;
  logic  [2:0] x_tm;
  logic        x_rw;
  int          x_reg, x_wait, x_beat, x_nbeats;
  bit          x_tbi;          // this is a line the slave burst-inhibits
  bit          x_iack, x_bkpt;

  // Log of what it saw, for the testbenches.
  int          n_starts;       // TS recognised
  logic [31:0] watch_a;        // reads that start at this long word (M14) ...
  int          watch_reads;    // ... counted (set_watch)
  logic [31:0] last_a;
  logic  [1:0] last_siz, last_tt;
  logic  [2:0] last_tm;
  logic        last_rw;

  function automatic logic [31:0] rd_long(input logic [31:0] addr);
    int b;
    b = int'(addr & (MEM_BYTES - 1)) & ~3;
    rd_long = {mem[b], mem[b+1], mem[b+2], mem[b+3]};
  endfunction

  // UM Table 7-1: the lanes a byte, word or long word occupies.
  function automatic logic [3:0] lanes(input logic [1:0] s, input logic [1:0] a10);
    case (s)
      2'b01:   lanes = 4'b1000 >> a10;                 // byte
      2'b10:   lanes = a10[1] ? 4'b0011 : 4'b1100;     // word
      default: lanes = 4'b1111;                        // long, line
    endcase
  endfunction

  task automatic wr_long(input logic [31:0] addr, input logic [31:0] v, input logic [3:0] ln);
    int b;
    b = int'(addr & (MEM_BYTES - 1)) & ~3;
    if (ln[3]) mem[b]   = v[31:24];
    if (ln[2]) mem[b+1] = v[23:16];
    if (ln[1]) mem[b+2] = v[15:8];
    if (ln[0]) mem[b+3] = v[7:0];
  endtask

  // The A3-A2 of beat k of a line burst.
  function automatic logic [31:0] beat_addr(input logic [31:0] base, input int k);
    beat_addr = {base[31:4], base[3:2] + k[1:0], base[1:0]};
  endfunction

  initial begin
    busy = 0; n_starts = 0; watch_a = 32'hFFFF_FFFC; watch_reads = 0;
    ta_n = 1; tea_n = 1; tbi_n = 1; tci_n = 1; avec_n = 1; d_oe = 0; d_out = '0;
  end

  always @(posedge clk) begin : slave
    bit acked;
    acked = (ta_n == 1'b0) || (tea_n == 1'b0);

    // The edge the processor sampled our TA on: a write's data is on the bus
    // now (UM 7.4.3).
    if (busy && !ta_n && tea_n && !x_rw && !x_iack && !x_bkpt) begin
      if (x_siz == 2'b11 && !x_tbi)
        wr_long(beat_addr(x_a, x_beat), d_in, 4'b1111);
      else
        wr_long(x_a, d_in, lanes(x_siz, x_a[1:0]));
    end

    // Default: nothing driven next clock.
    ta_n <= 1; tea_n <= 1; tbi_n <= 1; tci_n <= 1; avec_n <= 1; d_oe <= 0;

    if (busy && acked) begin
      // The transfer (or this beat of it) is over.
      if (!ta_n && !tea_n) begin
        busy = 0;                         // a retry: the processor starts again
      end else if (!tea_n) begin
        busy = 0;                         // a bus error ends a line too
      end else if (x_siz == 2'b11 && !x_tbi && x_beat < 3) begin
        x_beat = x_beat + 1;
        x_wait = (x_reg >= 0) ? r_wait[x_reg] : 0;
      end else begin
        busy = 0;
      end
    end

    if (!ts_n) begin
      // UM 7.4.1: TS for one clock starts a transfer. The address and
      // attributes are valid on the edge it is seen on.
      busy     = 1;
      x_a      = a;
      x_tt     = tt;
      x_tm     = tm;
      x_rw     = rw;
      x_siz    = siz;
      x_beat   = 0;
      x_reg    = region_of(a);
      x_wait   = (x_reg >= 0) ? r_wait[x_reg] : 0;
      x_iack   = (tt == 2'b11) && (a == 32'hFFFF_FFFF);
      x_bkpt   = (tt == 2'b11) && (a == 32'h0000_0000);
      x_tbi    = 0;
      n_starts = n_starts + 1;
      last_a   = a; last_siz = siz; last_tt = tt; last_tm = tm; last_rw = rw;
      if (rw && tt != 2'b11 && {a[31:2], 2'b00} == watch_a) watch_reads = watch_reads + 1;
    end else if (busy && x_wait > 0) begin
      x_wait = x_wait - 1;
    end

    // Answer for the next edge, once the wait states are spent and MI lets
    // memory respond (UM 7.9: "the memory unit must wait for each snooping bus
    // master to negate MI before responding").
    if (busy && !(!ts_n && x_wait > 0) && x_wait == 0 && mi_n) begin
      if (x_iack) begin
        int lvl;
        lvl = int'(x_tm);
        if (iack_retry > 0) begin
          iack_retry = iack_retry - 1;
          ta_n <= 0; tea_n <= 0;
        end else if (lvl < 1 || iack_kind[lvl] == 2) begin
          tea_n <= 0;
        end else begin
          ta_n <= 0;
          if (iack_kind[lvl] == 1) avec_n <= 0;
          else begin d_out <= {24'h0, iack_vec[lvl]}; d_oe <= 1; end
        end
      end else if (x_bkpt) begin
        if (bkpt_kind == 1) tea_n <= 0; else ta_n <= 0;
      end else if (x_reg >= 0 && r_retry[x_reg] > 0 && x_beat == 0) begin
        r_retry[x_reg] = r_retry[x_reg] - 1;
        ta_n <= 0; tea_n <= 0;
      end else if (x_reg >= 0 && r_berr[x_reg] == x_beat) begin
        tea_n <= 0;
      end else begin
        ta_n <= 0;
        if (x_siz == 2'b11 && x_beat == 0 && x_reg >= 0) begin
          if (r_tbi[x_reg]) begin tbi_n <= 0; x_tbi = 1; end
          if (r_tci[x_reg]) tci_n <= 0;
        end
        if (x_rw) begin
          d_out <= rd_long((x_siz == 2'b11 && !x_tbi) ? beat_addr(x_a, x_beat) : x_a);
          d_oe  <= 1;
        end
      end
    end
  end

  // --- programming, from the testbench --------------------------------------
  task automatic set_region(input int i, input logic [31:0] base, input logic [31:0] mask,
                            input int waits, input bit tbi, input bit tci,
                            input int berr_beat, input int retries);
    r_base[i] = base; r_mask[i] = mask; r_wait[i] = waits; r_tbi[i] = tbi;
    r_tci[i] = tci; r_berr[i] = berr_beat; r_retry[i] = retries; r_on[i] = 1;
  endtask

  // Count the reads that start at the long word holding `addr`.
  task automatic set_watch(input logic [31:0] addr);
    watch_a = {addr[31:2], 2'b00};
    watch_reads = 0;
  endtask

  task automatic clear_regions();
    for (int i = 0; i < NREG; i++) r_on[i] = 0;
  endtask

  // A program image, as `objcopy -O verilog --verilog-data-width=1` writes it.
  task automatic load_hex(input string path);
    $readmemh(path, mem);
  endtask

  task automatic poke_long(input logic [31:0] addr, input logic [31:0] v);
    wr_long(addr, v, 4'b1111);
  endtask

  function automatic logic [31:0] peek_long(input logic [31:0] addr);
    peek_long = rd_long(addr);
  endfunction

endmodule
