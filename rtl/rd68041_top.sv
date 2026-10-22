// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- SystemVerilog MC68040
//
// Top level: the MC68040's pins (doc/pinout.md), split into _i/_o/_oe.
//
// M0: no processor yet. Every pin is in the state UM 5.7.2 gives while RSTI is
// recognised -- "all three-state signals are set to the high-impedance state, and
// all outputs, except MI, are negated" -- and MI is asserted while RSTI is (UM
// 5.5.2: "MI is asserted during reset"). Out of reset nothing ever asks for the
// bus, so MI is negated and everything else stays as it was. The bus unit (M1)
// replaces this.

module rd68041_top #(
    // Whether the floating-point unit is built: 1 is the MC68040, 0 the
    // MC68LC040, which takes the F-line exception on every floating-point
    // instruction (UM Appendix A). doc/plan.md, M11 and M12.
    parameter int FPU = 1
) (
    // Clocks and reset (UM 5.7, 5.9) -------------------------------------------
    input  logic        clk,        // BCLK; every register is on its rising edge
    input  logic        pclk,       // PCLK, not used: doc/pinout.md
    input  logic        rst_n,      // not an MC68040 pin: async init, doc/pinout.md
    input  logic        rsti_n_i,
    output logic        rsto_n_o,

    // Address bus (UM 5.1) -----------------------------------------------------
    input  logic [31:0] a_i,
    output logic [31:0] a_o,
    output logic        a_oe,

    // Data bus (UM 5.2) --------------------------------------------------------
    input  logic [31:0] d_i,
    output logic [31:0] d_o,
    output logic        d_oe,

    // Transfer attributes (UM 5.3) ---------------------------------------------
    input  logic  [1:0] tt_i,
    output logic  [1:0] tt_o,
    output logic  [2:0] tm_o,
    output logic  [1:0] tln_o,
    output logic  [1:0] upa_o,
    input  logic        rw_i,
    output logic        rw_o,
    input  logic  [1:0] siz_i,
    output logic  [1:0] siz_o,
    output logic        lock_n_o,
    output logic        locke_n_o,
    output logic        ciout_n_o,
    output logic        attr_oe,

    // Transfer control (UM 5.4) ------------------------------------------------
    input  logic        ts_n_i,
    output logic        ts_n_o,
    output logic        ts_oe,
    output logic        tip_n_o,
    output logic        tip_oe,
    input  logic        ta_n_i,
    output logic        ta_n_o,
    output logic        ta_oe,
    input  logic        tea_n_i,
    input  logic        tci_n_i,
    input  logic        tbi_n_i,
    input  logic        dle_i,      // DLE (JS0 on the MC68LC040): not used

    // Snoop control (UM 5.5) ---------------------------------------------------
    input  logic  [1:0] sc_i,
    output logic        mi_n_o,

    // Arbitration (UM 5.6) -----------------------------------------------------
    output logic        br_n_o,
    input  logic        bg_n_i,
    input  logic        bb_n_i,
    output logic        bb_n_o,
    output logic        bb_oe,

    // Processor control (UM 5.7, 5.10) -----------------------------------------
    input  logic        cdis_n_i,
    input  logic        mdis_n_i,

    // Interrupts (UM 5.8) ------------------------------------------------------
    input  logic  [2:0] ipl_n_i,
    output logic        ipend_n_o,
    input  logic        avec_n_i,

    // Status (UM 5.9.1), stubbed -----------------------------------------------
    output logic  [3:0] pst_o,

    // Test (UM 6), stubbed -----------------------------------------------------
    input  logic        tck_i,
    input  logic        tms_i,
    input  logic        tdi_i,
    input  logic        trst_n_i,
    output logic        tdo_o,
    output logic        tdo_oe
);

  // RSTI, synchronised to the next rising edge of BCLK (UM 5.7.2). While rst_n
  // holds the design, RSTI reads as asserted, so the pins come out of rst_n in
  // their reset state.
  logic crst_n;

  rd68041_sync #(.WIDTH(1), .RESET_VAL(1'b0)) u_rsti_sync (
      .clk   (clk),
      .rst_n (rst_n),
      .d     (rsti_n_i),
      .q     (crst_n)
  );

  // MI is a two-state output: asserted during reset (UM 5.5.2), negated
  // otherwise until the snoop logic (M2) has a reason to hold it. Registered,
  // because a pin is a flop (doc/coding-standard.md).
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mi_n_o <= 1'b0;
    end else begin
      mi_n_o <= crst_n ? 1'b1 : 1'b0;
    end
  end

  // Everything else: released, or negated (UM 5.7.2).
  assign a_o       = '0;
  assign a_oe      = 1'b0;
  assign d_o       = '0;
  assign d_oe      = 1'b0;
  assign tt_o      = rd68041_pkg::TT_NORMAL;
  assign tm_o      = '0;
  assign tln_o     = '0;
  assign upa_o     = '0;
  assign rw_o      = 1'b1;
  assign siz_o     = rd68041_pkg::SIZ_LONG;
  assign lock_n_o  = 1'b1;
  assign locke_n_o = 1'b1;
  assign ciout_n_o = 1'b1;
  assign attr_oe   = 1'b0;
  assign ts_n_o    = 1'b1;
  assign ts_oe     = 1'b0;
  assign tip_n_o   = 1'b1;
  assign tip_oe    = 1'b0;
  assign ta_n_o    = 1'b1;
  assign ta_oe     = 1'b0;
  assign bb_n_o    = 1'b1;
  assign bb_oe     = 1'b0;
  assign br_n_o    = 1'b1;
  assign rsto_n_o  = 1'b1;
  assign ipend_n_o = 1'b1;
  assign pst_o     = rd68041_pkg::PST_USER_RUN;
  assign tdo_o     = 1'b0;
  assign tdo_oe    = 1'b0;

  // What M0 deliberately does not read. Each goes when the unit that needs it
  // arrives: the bus unit (M1-M2), the snooper (M2), the FPU (M11).
  logic unused_ok;
  assign unused_ok = &{1'b0, pclk, a_i, d_i, tt_i, rw_i, siz_i, ts_n_i, ta_n_i,
                       tea_n_i, tci_n_i, tbi_n_i, dle_i, sc_i, bg_n_i, bb_n_i,
                       cdis_n_i, mdis_n_i, ipl_n_i, avec_n_i, tck_i, tms_i, tdi_i,
                       trst_n_i, FPU != 0};

endmodule
