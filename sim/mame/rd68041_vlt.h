// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 in MAME (M14) -- the interface between MAME's rd68041_device
// (sim/mame/rd68041.cpp, compiled into MAME) and the core under Verilator with
// its pin-level bus agent (sim/mame/rd68041_vlt.cpp, a shared object MAME
// loads at start). Neither side includes the other's headers: MAME's and
// Verilator's would not mix, and the split lets the RTL be rebuilt without
// relinking MAME. RD68031's, for the MC68040 bus.
#ifndef RD68041_VLT_H
#define RD68041_VLT_H

#include <cstdint>

#define RD68041_VLT_ABI 1

// What the bus agent asks of the machine. Addresses are physical, as on the
// pins; a read or write is of the bytes `mask` selects in the aligned long
// word at `addr & ~3` (big-endian lanes: $FF000000 is the byte at
// addr & ~3) -- a line is four of them.
struct rd68041_vlt_bus {
  virtual ~rd68041_vlt_bus() {}
  // `tm` is TM2-TM0 (UM Table 5-3). Return with *retry set for the machine to
  // be asked again later: the agent answers with a retry (TA and TEA, UM
  // 7.4.6) and the processor runs the transfer again.
  virtual uint32_t read(uint32_t addr, int tm, uint32_t mask, bool *retry) = 0;
  virtual void write(uint32_t addr, int tm, uint32_t data, uint32_t mask, bool *retry) = 0;
  // The interrupt acknowledge of `level` (UM 7.5.1): the vector number, or
  // -1 for an autovector (AVEC), or -2 for a spurious interrupt (TEA).
  virtual int iack(int level) = 0;
  // The RSTO pin, which the RESET instruction asserts (UM 7.10).
  virtual void reset_out(bool asserted) = 0;
};

// The programmer's model at the last boundary.
struct rd68041_vlt_regs {
  uint32_t pc, d[8], a[8], usp, isp, msp, vbr, sfc, dfc, cacr;
  uint32_t tc, urp, srp, itt0, itt1, dtt0, dtt1, mmusr;
  uint16_t sr;
};

struct rd68041_vlt {
  virtual ~rd68041_vlt() {}
  // rst_n and RSTI low for `clocks` clocks, then high (doc/pinout.md).
  virtual void power_on(int clocks) = 0;
  virtual void set_ipl(int level) = 0;
  // One clock. True when an instruction boundary passed in it.
  virtual bool clock() = 0;
  // STOP holds the processor and no transfer is in flight.
  virtual bool stopped() const = 0;
  // A double bus fault halted the processor.
  virtual bool halted() const = 0;
  virtual void regs(rd68041_vlt_regs &r) const = 0;
  virtual uint32_t pc() const = 0;
  virtual uint64_t clocks() const = 0;
  // Wait states before every TA.
  virtual void set_waits(int w) = 0;
  // 1: the MC68040, 0: the MC68LC040 (the FPU parameter it was built with).
  virtual int fpu() const = 0;
};

extern "C" {
typedef int (*rd68041_vlt_abi_fn)();
typedef rd68041_vlt *(*rd68041_vlt_create_fn)(rd68041_vlt_bus *bus);
int rd68041_vlt_abi();
rd68041_vlt *rd68041_vlt_create(rd68041_vlt_bus *bus);
}

#endif
