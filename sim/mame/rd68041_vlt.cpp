// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// RD68041 in MAME (M14) -- rd68041_top under Verilator, and a pin-level bus
// agent that turns its transfers into the machine's accesses. Built into a
// shared object (sim/mame/build.sh vlt) that MAME's rd68041_device loads; the
// interface is sim/mame/rd68041_vlt.h.
//
// THE AGENT is rd-virt's (sim/virt/cpu_rtl.cpp; sim/models/rd68041_slave.sv)
// with the machine's accesses made where a board would make them:
//   - TS is seen on a rising edge (UM 7.4.1). A read -- each long word of a
//     line, in A3-A2 order from the one addressed, wrapping (UM 7.4.2) -- is
//     made on the edge its long word is asked for, and answered with TA for
//     the next, `waits` clocks later at the earliest: a device register with
//     a side effect on read sees one read a transfer.
//   - a write's data is on the bus from the clock after TS (C2, UM 7.4.3), so
//     it is made on the edge after that, and answered for the next: one clock
//     more than a read, so that the machine sees the data before it answers.
//   - when the machine asks for an access to be made again (MAME's
//     retry_access, which the Quadra's SCSI pseudo-DMA uses), the transfer is
//     answered with a retry, TA and TEA (UM 7.4.6), and the processor runs
//     it again.
//   - an interrupt acknowledge (TT 11, A = $FFFFFFFF, the level in TM) asks
//     the machine for the vector: AVEC, the vector with TA, or TEA (UM
//     7.5.1); a breakpoint acknowledge ends with TEA.
//
// A BOUNDARY is rd-virt's: `retire` in the clock before the edge.

#include "rd68041_vlt.h"

#include "Vrd68041_top.h"
#include "Vrd68041_top___024root.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>

#ifndef RDVIRT_FPU
#define RDVIRT_FPU 1
#endif

#define CORE(x) top->rootp->rd68041_top__DOT__u_core__DOT__##x
#define RF(x) top->rootp->rd68041_top__DOT__u_core__DOT__u_rf__DOT__##x

namespace {

constexpr int XS_STOP = 3;

class Agent : public rd68041_vlt {
 public:
  explicit Agent(rd68041_vlt_bus *b) : bus(b) {
    top = new Vrd68041_top{&ctx};
    top->clk = 0; top->pclk = 0; top->rst_n = 0; top->rsti_n_i = 0;
    top->d_i = 0; top->ta_n_i = 1; top->tea_n_i = 1; top->tci_n_i = 1; top->tbi_n_i = 1;
    top->dle_i = 0; top->sc_i = 0; top->bg_n_i = 0; top->bb_n_i = 1; top->ts_n_i = 1;
    top->cdis_n_i = 1; top->mdis_n_i = 1; top->ipl_n_i = 7; top->avec_n_i = 1;
    top->tck_i = 0; top->tms_i = 0; top->tdi_i = 0; top->trst_n_i = 1;
    top->eval();
  }
  ~Agent() override { top->final(); delete top; }

  void power_on(int n) override {
    busy = false; ta = tea = avec = doe = false;
    top->rst_n = 0; top->rsti_n_i = 0;
    for (int i = 0; i < n; i++) clock();
    top->rst_n = 1;
    for (int i = 0; i < 12; i++) clock();
    top->rsti_n_i = 1;
  }
  void set_ipl(int level) override { top->ipl_n_i = ~level & 7; }

  bool clock() override {
    fall();
    bool b = CORE(retire);
    if (b) last_pc = CORE(retire_npc);
    rise();
    if (bool(!top->rsto_n_o) != rsto) { rsto = !top->rsto_n_o; bus->reset_out(rsto); }
    return b;
  }
  bool stopped() const override { return CORE(xs) == XS_STOP && !busy; }
  bool halted() const override { return CORE(halted); }
  uint32_t pc() const override { return last_pc; }
  uint64_t clocks() const override { return nclk; }
  void set_waits(int w) override { waits = w < 0 ? 0 : w; }
  int fpu() const override { return RDVIRT_FPU; }

  void regs(rd68041_vlt_regs &r) const override {
    for (int i = 0; i < 8; i++) { r.d[i] = RF(r)[i]; r.a[i] = RF(r)[8 + i]; }
    r.sr = CORE(sr);
    bool s = r.sr & 0x2000, m = r.sr & 0x1000;
    r.usp = s ? CORE(usp) : r.a[7];
    r.isp = (s && !m) ? r.a[7] : CORE(isp);
    r.msp = (s && m) ? r.a[7] : CORE(msp);
    r.vbr = CORE(vbr); r.sfc = CORE(sfc); r.dfc = CORE(dfc); r.cacr = CORE(cacr);
    r.tc = CORE(tc); r.urp = CORE(urp); r.srp = CORE(srp);
    r.itt0 = CORE(itt0); r.itt1 = CORE(itt1); r.dtt0 = CORE(dtt0); r.dtt1 = CORE(dtt1);
    r.mmusr = CORE(mmusr);
    r.pc = last_pc;
  }

 private:
  VerilatedContext ctx;
  Vrd68041_top *top;
  rd68041_vlt_bus *bus;
  uint64_t nclk = 0;
  uint32_t last_pc = 0;   // the next PC at the last boundary
  int waits = 0;
  bool rsto = false;

  // The transfer in flight.
  enum Kind { MEM, IACK, BKPT };
  bool busy = false, rd = true, line = false, made = false, retry = false;
  Kind kind = MEM;
  uint32_t addr = 0, data = 0;
  int tm = 0, siz = 0, beat = 0, wait = 0;
  // The agent's registered outputs.
  bool ta = false, tea = false, avec = false, doe = false;
  uint32_t dout = 0;

  uint32_t beat_addr() const {
    return line ? ((addr & ~0xFu) | ((((addr >> 2) + beat) & 3u) << 2)) : (addr & ~3u);
  }
  uint32_t mask() const {
    if (line || siz == 0) return 0xFFFFFFFFu;
    unsigned off = addr & 3u, n = siz == 1 ? 1 : 2;
    uint32_t m = 0;
    for (unsigned j = off; j < off + n && j < 4; j++) m |= 0xFFu << (8 * (3 - j));
    return m;
  }

  void start() {
    busy = true;
    addr = top->a_o; tm = top->tm_o; siz = top->siz_o; rd = top->rw_o;
    line = siz == 3; beat = 0; made = false; retry = false;
    kind = top->tt_o == 3 ? (addr == 0xFFFFFFFFu ? IACK : BKPT) : MEM;
    wait = waits + ((kind == MEM && !rd) ? 1 : 0);
  }

  // The agent's rising edge, on the pins as they are before it.
  void posedge() {
    bool acked = ta || tea;
    bool nta = false, ntea = false, navec = false, ndoe = false;
    uint32_t nd = 0;
    if (busy && acked) {
      if (tea || (line && beat == 3) || !line) busy = false;
      else { beat++; made = false; wait = waits + (rd ? 0 : 1); }
    }
    if (top->ts_oe && !top->ts_n_o) start();
    // A read is made on the edge its long word is asked for.
    if (busy && kind == MEM && rd && !made) {
      data = bus->read(beat_addr(), tm, mask(), &retry);
      made = true;
    }
    if (busy && wait > 0) {
      wait--;
    } else if (busy) {
      switch (kind) {
        case IACK: {
          int v = bus->iack(tm);
          if (v == -1) { nta = true; navec = true; }
          else if (v < 0) ntea = true;
          else { nta = true; nd = uint32_t(v & 0xFF) * 0x01010101u; ndoe = true; }
          break;
        }
        case BKPT: ntea = true; break;
        case MEM:
          if (!rd && !made) {
            bus->write(beat_addr(), tm, top->d_o, mask(), &retry);
            made = true;
          }
          if (retry && beat == 0) { nta = true; ntea = true; }
          else {
            nta = true;
            if (rd) { nd = data; ndoe = true; }
          }
          break;
      }
    }
    ta = nta; tea = ntea; avec = navec; dout = nd; doe = ndoe;
  }

  void drive() {
    top->ta_n_i = (!ta && !(top->ta_oe && !top->ta_n_o)) ? 1 : 0;
    top->tea_n_i = !tea;
    top->avec_n_i = !avec;
    top->d_i = top->d_oe ? top->d_o : (doe ? dout : 0);
    top->ts_n_i = top->ts_oe ? top->ts_n_o : 1;
    top->bb_n_i = top->bb_oe ? top->bb_n_o : 1;
    top->a_i = top->a_o; top->tt_i = top->tt_o; top->rw_i = top->rw_o; top->siz_i = top->siz_o;
  }
  void fall() { top->clk = 0; top->eval(); drive(); top->eval(); }
  void rise() { posedge(); top->clk = 1; top->eval(); drive(); top->eval(); nclk++; }
};

}  // namespace

extern "C" int rd68041_vlt_abi() { return RD68041_VLT_ABI; }
extern "C" rd68041_vlt *rd68041_vlt_create(rd68041_vlt_bus *bus) { return new Agent(bus); }
