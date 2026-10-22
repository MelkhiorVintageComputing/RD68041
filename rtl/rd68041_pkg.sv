// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 -- SystemVerilog MC68040
//
// Architectural constants transcribed from the manual, each with its citation.
// Written down once, here; a module that needs one refers to it by its full scope
// (doc/coding-standard.md: there is no portable `import`).

package rd68041_pkg;

  // UM 5.3.1, Table 5-2: transfer type, TT1-TT0.
  localparam logic [1:0] TT_NORMAL = 2'b00;
  localparam logic [1:0] TT_MOVE16 = 2'b01;
  localparam logic [1:0] TT_ALTFC  = 2'b10;  // alternate logical function code
  localparam logic [1:0] TT_ACK    = 2'b11;  // interrupt and breakpoint acknowledge

  // UM 5.3.2, Table 5-3: transfer modifier, TM2-TM0, for normal and MOVE16
  // accesses. MOVE16 uses only the two data encodings.
  localparam logic [2:0] TM_PUSH      = 3'b000;  // data cache push
  localparam logic [2:0] TM_USER_DATA = 3'b001;
  localparam logic [2:0] TM_USER_CODE = 3'b010;
  localparam logic [2:0] TM_TBL_DATA  = 3'b011;  // MMU table search, data
  localparam logic [2:0] TM_TBL_CODE  = 3'b100;  // MMU table search, code
  localparam logic [2:0] TM_SUP_DATA  = 3'b101;
  localparam logic [2:0] TM_SUP_CODE  = 3'b110;

  // UM 7: transfer size, SIZ1-SIZ0. There is no dynamic bus sizing on the
  // MC68040; a line is four long words, by burst or, with TBI, one at a time.
  localparam logic [1:0] SIZ_LONG = 2'b00;
  localparam logic [1:0] SIZ_BYTE = 2'b01;
  localparam logic [1:0] SIZ_WORD = 2'b10;
  localparam logic [1:0] SIZ_LINE = 2'b11;

  // UM 5.9.1, Table 5-6: processor status, PST3-PST0. Stubbed (doc/pinout.md);
  // the encodings are kept for when it is not.
  localparam logic [3:0] PST_USER_RUN = 4'h0;  // user, start/continue current instruction
  localparam logic [3:0] PST_SUP_RUN  = 4'h8;  // supervisor, start/continue

endpackage
