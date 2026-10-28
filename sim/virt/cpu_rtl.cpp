// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// rd-virt -- the RTL socket: rd68041_top under Verilator, and a pin-level bus
// agent that answers it on behalf of the machine.
//
// THE AGENT is sim/models/rd68041_slave.sv in C++, for the same reasons (UM
// 7.4-7.6): it recognises TS on a rising edge and drives TA (or TEA, TBI)
// from just after one rising edge to just after the next, `ram_waits` (or,
// for the devices, `io_waits`) clocks after TS at the earliest; a line is
// four long words in A3-A2 order from the one addressed, wrapping (UM
// 7.4.2), unless `tbi`, when the first long word is answered with TBI and the
// processor goes on with three long-word transfers; with `tci`, a line read's
// first long word comes with TCI, so the line is not allocated -- the caches
// off as far as the bus can make them (CDIS does not, here: doc/divergences.md).
// A read drives the whole
// aligned long word. A write's data is taken on the edge the processor
// samples TA on (UM 7.4.3).
//   - the devices: a line (which only a cachable mapping of them would ask
//     for) is answered with TBI and TCI; a read of a device register happens
//     once per transfer, when it is answered (a register may have a side
//     effect on read).
//   - an interrupt acknowledge (TT 11, A = $FFFFFFFF, the level in TM) is
//     answered with AVEC: every source on this board is autovectored (UM
//     7.5.1); a breakpoint acknowledge (TT 11, A = 0), and every hole in the
//     map, with TEA.
//
// A BOUNDARY is the testbenches' (sim/tb/core_cosim_tb.sv): `retire`, true in
// the clock before the edge that writes the instruction's results, its next
// PC `retire_npc`; the programmer's model is read after that edge. Two more
// are made here, which `retire` folds into the next: the end of an
// instruction an interrupt is taken after, and STOP's.
//
// THE WRITES the lockstep compares are taken where the write-back stage
// hands them to the data unit (st_ready: rd68041_dmu's queue took one): the
// logical address, the size and the data -- for MOVE16, the line from the
// MOVE16 buffer. Whether a copyback cache holds them or the bus carries them
// is the cache's business.

#include "cpu_rtl.h"

#include <cstdio>
#include <cstring>

#include "Vrd68041_top.h"
#include "Vrd68041_top___024root.h"
#include "verilated.h"
#if VM_TRACE
#include "verilated_vcd_c.h"
#endif

#include "bus_if.h"

#ifndef RDVIRT_FPU
#define RDVIRT_FPU 1
#endif

#define CORE(x) top->rootp->rd68041_top__DOT__u_core__DOT__##x
#define RF(x) top->rootp->rd68041_top__DOT__u_core__DOT__u_rf__DOT__##x
#define DMU(x) top->rootp->rd68041_top__DOT__u_core__DOT__u_dmu__DOT__##x
#define FPU(x) top->rootp->rd68041_top__DOT__u_core__DOT__g_fpu__DOT__u_fpu__DOT__##x

namespace {
constexpr int XS_SEQ = 2, XS_STOP = 3, R_RUN = 2;
}

struct RtlModel {
  VerilatedContext ctx;
  Vrd68041_top *top;
#if VM_TRACE
  VerilatedVcdC *vcd = nullptr;
#endif
  uint64_t clocks = 0, ts = 0;

  // The agent.
  enum Tgt { RAM, IO, HOLE, IACK, BKPT };
  bool busy = false;
  Tgt tgt = HOLE;
  uint32_t addr = 0;
  int tt = 0, tm = 0, siz = 0;
  bool rd = true, line = false, line_tbi = false;
  int beat = 0, wait = 0;
  // Its registered outputs.
  bool ta = false, tea = false, tbi = false, tci = false, avec = false;
  uint32_t dout = 0;
  bool doe = false;
  // What the last step saw.
  int iack = 0;
  uint64_t step = 0;
  bool booted = false;    // the reset exception is over (reset_pc's vectors)

  // The DMA master (bus_if.h): the bus taken from the core around a device
  // command, snooped transfers of what the device reads and writes.
  bool grant = true;                        // BG to the core
  enum MState { MS_IDLE, MS_WAIT, MS_PRE, MS_POST, MS_END } ms = MS_IDLE;
  struct MX { uint32_t a; int siz; bool write; int sc; };  // siz as SIZ1-0
  std::deque<MX> mq;
  bool mx_on = false;
  MX mx{};
  int mx_phase = 0, mx_beat = 0;
  bool m_own = false, m_ts = false, m_bb = false;
  // The core's write the retry held off, made by the master, and answered
  // when the core runs it again.
  bool held_done = false;
  uint32_t held_a = 0, held_v = 0;
  int held_n = 0;
  uint64_t dma_cmds = 0, dma_xfers = 0, dma_sourced = 0, wait_clocks = 0;

  BusIf *m;
  RtlOptions o;
  std::vector<OpWrite> *writes = nullptr;
  RtlModel(BusIf *mm, const RtlOptions &oo) : m(mm), o(oo) {
    top = new Vrd68041_top{&ctx};
  }
  ~RtlModel() {
#if VM_TRACE
    if (vcd) { vcd->close(); delete vcd; }
#endif
    top->final();
    delete top;
  }

  char kind() const {
    if (tgt == IACK) return 'I';
    if (tt == 1) return 'M';
    if (tm == 3 || tm == 4) return 'T';
    if (tm == 2 || tm == 6) return 'F';
    if (tm == 0 && line && !rd) return 'P';
    if (line && rd) return 'L';
    return 'D';
  }

  void log(uint32_t a, int size, bool write, uint32_t data, bool berr, char k = 0) {
    BusRec r;
    r.step = step;
    r.addr = a;
    r.data = data;
    r.size = uint8_t(size);
    r.write = write;
    r.tm = uint8_t(tm);
    r.berr = berr;
    r.kind = k ? k : kind();
    m->log(r);
  }

  uint32_t ram_long(uint32_t a) const {
    if (o.reset_pc >= 0 && !booted && a < 8) return uint32_t(a & 4 ? o.reset_pc : o.reset_ssp);
    if (a >= m->ram_size) return 0;
    const uint8_t *p = m->ram + (a & ~3u);
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
  }
  uint32_t beat_addr() const {
    if (line && !line_tbi) return (addr & ~0xFu) | ((((addr >> 2) + beat) & 3u) << 2);
    if (line) return (addr & ~0xFu) | ((((addr >> 2) + beat) & 3u) << 2);
    return addr;
  }
  int bytes() const { return siz == 1 ? 1 : siz == 2 ? 2 : 4; }

  void start() {
    busy = true;
    addr = top->a_o;
    tt = top->tt_o;
    tm = top->tm_o;
    rd = top->rw_o;
    siz = top->siz_o;
    line = siz == 3;
    line_tbi = false;
    beat = 0;
    if (tt == 3) {
      tgt = addr == 0xFFFFFFFFu ? IACK : BKPT;
      if (tgt == IACK) iack = tm;
      wait = 0;
      return;
    }
    switch (m->classify(addr)) {
      case BusIf::Region::Ram: tgt = RAM; wait = o.ram_waits; break;
      case BusIf::Region::Io: tgt = IO; wait = o.io_waits; break;
      default: tgt = HOLE; wait = 0;
    }
  }

  // A single write's bytes, right-justified, as the device sees them.
  void write_value(uint32_t d, uint32_t &v, int &n) const {
    unsigned off = addr & 3u;
    n = bytes();
    if (n > int(4 - off)) n = 4 - off;
    v = 0;
    for (int j = 0; j < n; j++) v = (v << 8) | uint8_t(d >> (8 * (3 - (off + j))));
  }

  void do_write() {
    uint32_t d = top->d_o;
    if (!line && tgt == IO && held_done) {
      uint32_t v;
      int n;
      write_value(d, v, n);
      if (addr == held_a && n == held_n && v == held_v) {
        // the write the master made for it, before the DMA it started
        held_done = false;
        log(addr, n, true, v, false);
        return;
      }
    }
    if (line) {
      uint32_t a = beat_addr() & ~3u;
      if (tgt == RAM && a + 4 <= m->ram_size)
        for (int j = 0; j < 4; j++) m->ram[a + j] = uint8_t(d >> (24 - 8 * j));
      if (tgt == IO) m->io_write(a, 4, d);
      log(a, 4, true, d, false);
      return;
    }
    unsigned off = addr & 3u;
    int n = bytes();
    if (n > int(4 - off)) n = 4 - off;
    uint32_t v = 0;
    for (int j = 0; j < n; j++) {
      uint8_t b = uint8_t(d >> (8 * (3 - (off + j))));
      v = (v << 8) | b;
      if (tgt == RAM && addr + j < m->ram_size) m->ram[addr + j] = b;
    }
    if (tgt == IO) {
      m->io_write(addr, n, v);
      top->ipl_n_i = ~m->ipl() & 7;
    }
    log(addr, n, true, v, false);
  }

  // The DMA master's plans: what the device reads, as snooped line reads
  // (SC 01: a dirty line is sourced, UM 7.9.3, and memory takes the data, as
  // UM 4.5 has a memory controller do); what it wrote, as snooped writes of
  // the data now in RAM -- whole lines with SC 10 (the line replaced, so
  // invalidated), the rest as long words and bytes with SC 01, sunk into a
  // dirty line or else invalidating it (UM 4.4.4, Table 4-4; core_snoop_tb's
  // rules).
  void plan_reads(const std::vector<BusIf::Dma> &r) {
    for (const BusIf::Dma &x : r)
      for (uint32_t a = x.a & ~15u; a < x.a + x.n && a + 16 <= m->ram_size; a += 16)
        mq.push_back({a, 3, false, 1});
  }
  void plan_writes(const std::vector<BusIf::Dma> &r) {
    for (const BusIf::Dma &x : r) {
      uint32_t a = x.a, e = x.a + x.n;
      while (a < e && a < m->ram_size) {
        if ((a & 15) == 0 && a + 16 <= e) { mq.push_back({a, 3, true, 2}); a += 16; }
        else if ((a & 3) == 0 && a + 4 <= e) { mq.push_back({a, 0, true, 1}); a += 4; }
        else { mq.push_back({a, 1, true, 1}); a += 1; }
      }
    }
  }
  uint32_t mx_addr() const {
    return mx.siz == 3 ? (mx.a & ~15u) | ((((mx.a >> 2) + mx_beat) & 3u) << 2) : mx.a;
  }

  // The master's rising edge: one transfer at a time (rd68041_altmaster's
  // protocol, UM 7.4) -- TS for a clock with the address, SIZ, TT normal, R/W
  // and SC held to the end, the write data from the clock after -- answered
  // by memory once the snooper negates MI, or by the core when it intervenes.
  void master_edge() {
    bool core_ta = top->ta_oe && !top->ta_n_o;
    bool nta = false, ndoe = false;
    uint32_t nd = 0;
    if (mx_on && mx_phase == 2 && (ta || core_ta)) {
      uint32_t ba = mx_addr() & ~3u;
      if (!mx.write && core_ta) {
        uint32_t d = top->d_o;
        for (int j = 0; j < 4; j++) m->ram[ba + j] = uint8_t(d >> (24 - 8 * j));
        dma_sourced++;
      }
      log(ba, mx.siz == 1 ? 1 : 4, mx.write, ram_long(ba), false, 'S');
      mx_beat++;
      if (mx.siz != 3 || mx_beat == 4) { mx_on = false; mx_phase = 3; }
    }
    if (mx_on && mx_phase == 1) mx_phase = 2;
    if (mx_on && mx_phase == 0) mx_phase = 1;
    if (!mx_on) {
      if (mx_phase == 3) {
        mx_phase = 4;                      // an idle clock between transfers
      } else if (!mq.empty()) {
        mx = mq.front();
        mq.pop_front();
        mx_on = true;
        mx_phase = 0;
        mx_beat = 0;
        dma_xfers++;
      } else if (ms == MS_PRE) {
        std::vector<BusIf::Dma> r = m->dma_reads();
        if (!r.empty()) {
          plan_reads(r);
        } else {
          m->io_write(held_a, held_n, held_v);   // the command, and its DMA
          held_done = true;
          plan_writes(m->dma_writes());
          ms = MS_POST;
        }
      } else if (ms == MS_POST) {
        ms = MS_END;                       // BB negated for a clock, then released
        m_bb = false;
      } else if (ms == MS_END) {
        m_own = false;
        grant = true;
        ms = MS_IDLE;
        top->ipl_n_i = ~m->ipl() & 7;
      }
    }
    m_ts = mx_on && mx_phase == 1;
    if (mx_on && mx_phase == 2) {
      if (mx.write) { nd = ram_long(mx_addr()); ndoe = true; }
      if (top->mi_n_o) {
        nta = true;                        // memory answers this beat
        if (!mx.write) { nd = ram_long(mx_addr()); ndoe = true; }
      }
    }
    ta = nta; tea = false; tbi = false; tci = false; avec = false; dout = nd; doe = ndoe;
  }

  // The agent's rising edge, on the pins as they are before it.
  void posedge() {
    if (ms == MS_PRE || ms == MS_POST || ms == MS_END) { master_edge(); return; }
    bool acked = ta || tea;
    if (busy && ta && !tea && !rd && (tgt == RAM || tgt == IO)) do_write();
    bool nta = false, ntea = false, ntbi = false, ntci = false, navec = false, ndoe = false;
    uint32_t nd = 0;
    if (busy && acked) {
      if (tea) {
        log(beat_addr(), line ? 4 : bytes(), !rd, 0, true);
        busy = false;
      } else if (line && beat < 3) {
        beat++;
        wait = tgt == IO ? o.io_waits : o.ram_waits;
      } else {
        busy = false;
      }
    }
    if (top->ts_oe && !top->ts_n_o) {
      start();
    } else if (busy && wait > 0) {
      wait--;
    }
    if (busy && wait == 0 && top->mi_n_o) {
      switch (tgt) {
        case IACK:
          nta = true; navec = true;
          log(addr, 0, false, 0, false);
          break;
        case BKPT:
        case HOLE:
          ntea = true;
          break;
        case RAM:
          nta = true;
          if (line && beat == 0 && o.tbi) { ntbi = true; line_tbi = true; }
          if (line && rd && beat == 0 && o.tci) ntci = true;
          if (rd) {
            uint32_t a = line ? beat_addr() : (addr & ~3u);
            nd = ram_long(a); ndoe = true;
            log(a, line ? 4 : bytes(), false, nd, false);
          }
          break;
        case IO:
          nta = true;
          if (line && beat == 0) { ntbi = true; ntci = true; line_tbi = true; }
          if (rd) {
            uint32_t a = (line ? beat_addr() : addr) & ~3u;
            if (m->io_read(a, 4, nd)) { nta = false; ntea = true; nd = 0; }
            else { ndoe = true; log(a, 4, false, nd, false); }
          } else if (!line) {
            // A command that starts DMA: held off with a retry (TA with TEA,
            // UM 7.4.6) and the bus taken; the master makes it (master_edge).
            uint32_t v;
            int n;
            write_value(top->d_o, v, n);
            bool again = held_done && addr == held_a && n == held_n && v == held_v;
            if (!again && m->dma_hold(addr, n, v)) {
              ntea = true;
              held_a = addr; held_n = n; held_v = v;
              grant = false;
              ms = MS_WAIT;
              wait_clocks = 0;
              dma_cmds++;
            }
          }
          break;
      }
    }
    ta = nta; tea = ntea; tbi = ntbi; tci = ntci; avec = navec; dout = nd; doe = ndoe;
    // The core leaves the bus once it has seen the retry and lost BG.
    if (ms == MS_WAIT) {
      if (!busy && !nta && !ntea && !top->bb_oe && !top->tip_oe && !top->ts_oe) {
        ms = MS_PRE;
        m_own = true;
        m_bb = true;
        mx_on = false;
        mx_phase = 4;
        plan_reads(m->dma_reads());
      } else if (++wait_clocks == 1000000) {
        fprintf(stderr, "rtl: the core has not left the bus in a million clocks after a DMA retry\n");
      }
    }
  }

  void drive() {
    top->ta_n_i = !(ta) && !(top->ta_oe && !top->ta_n_o) ? 1 : 0;
    top->tea_n_i = !tea;
    top->tbi_n_i = !tbi;
    top->tci_n_i = !tci;
    top->avec_n_i = !avec;
    top->d_i = top->d_oe ? top->d_o : (doe ? dout : 0);
    if (m_own) {
      top->ts_n_i = !m_ts;
      top->bb_n_i = !m_bb;
      top->a_i = mx.a;
      top->tt_i = 0;
      top->rw_i = !mx.write;
      top->siz_i = mx.siz;
      top->sc_i = mx.sc;
    } else {
      top->ts_n_i = top->ts_oe ? top->ts_n_o : 1;
      top->bb_n_i = top->bb_oe ? top->bb_n_o : 1;
      top->a_i = top->a_o;
      top->tt_i = top->tt_o;
      top->rw_i = top->rw_o;
      top->siz_i = top->siz_o;
      top->sc_i = 0;
    }
    top->bg_n_i = grant ? 0 : 1;
  }

  // The writes the data unit's queue takes this clock (before the edge).
  void tap_store() {
    if (!writes || !DMU(st_ready)) return;
    uint32_t a = DMU(st_addr);
    if (DMU(st_m16)) {
      for (int k = 0; k < 4; k++) writes->push_back({(a & ~0xFu) + 4u * k, 4, DMU(mb)[k]});
      return;
    }
    int sz = DMU(st_sz);
    uint32_t d = DMU(st_data);
    writes->push_back({a, uint8_t(sz == 0 ? 1 : sz == 1 ? 2 : 4),
                       sz == 0 ? (d & 0xFF) : sz == 1 ? (d & 0xFFFF) : d});
  }

  // One clock: the falling half (after which the core's combinational
  // outputs say what the rising edge will do), then the rising edge.
  void fall() {
    top->clk = 0;
    top->eval();
    drive();
    top->eval();
#if VM_TRACE
    if (vcd) vcd->dump(ts);
#endif
    ts += 10;
  }
  void rise() {
    tap_store();
    posedge();
    top->clk = 1;
    top->eval();
    drive();
    top->eval();
#if VM_TRACE
    if (vcd) vcd->dump(ts);
#endif
    ts += 10;
    clocks++;
  }
  void clock() { fall(); rise(); }
};

RtlCpu::RtlCpu(BusIf *m, const RtlOptions &o) : m_(m), o_(o) {
  v_.reset(new RtlModel(m, o));
  Vrd68041_top *top = v_->top;
  top->clk = 0;
  top->pclk = 0;
  top->rst_n = 0;
  top->rsti_n_i = 0;
  top->d_i = 0;
  top->ta_n_i = 1;
  top->tea_n_i = 1;
  top->tci_n_i = 1;
  top->tbi_n_i = 1;
  top->dle_i = 0;
  top->sc_i = 0;
  top->bg_n_i = 0;
  top->bb_n_i = 1;
  top->ts_n_i = 1;
  top->cdis_n_i = 1;
  top->mdis_n_i = 1;
  top->ipl_n_i = 7;
  top->avec_n_i = 1;
  top->tck_i = 0;
  top->tms_i = 0;
  top->tdi_i = 0;
  top->trst_n_i = 1;
  top->eval();
  v_->writes = &writes;
#if VM_TRACE
  if (!o.vcd.empty()) Verilated::traceEverOn(true);
#endif
}

RtlCpu::~RtlCpu() {}

uint64_t RtlCpu::clocks() const { return v_->clocks; }

void RtlCpu::dma_stats(uint64_t &cmds, uint64_t &xfers, uint64_t &sourced) const {
  cmds = v_->dma_cmds;
  xfers = v_->dma_xfers;
  sourced = v_->dma_sourced;
}

void RtlCpu::snapshot(uint32_t pc) {
  Vrd68041_top *top = v_->top;
  CpuRegs &r = regs_;
  for (int i = 0; i < 8; i++) r.d[i] = RF(r)[i];
  for (int i = 0; i < 8; i++) r.a[i] = RF(r)[8 + i];
  r.sr = CORE(sr);
  bool s = r.sr & 0x2000, mm = r.sr & 0x1000;
  r.usp = s ? CORE(usp) : r.a[7];
  r.isp = (s && !mm) ? r.a[7] : CORE(isp);
  r.msp = (s && mm) ? r.a[7] : CORE(msp);
  r.vbr = CORE(vbr);
  r.sfc = CORE(sfc);
  r.dfc = CORE(dfc);
  r.cacr = CORE(cacr);
  r.tc = CORE(tc);
  r.urp = CORE(urp);
  r.srp = CORE(srp);
  r.itt0 = CORE(itt0);
  r.itt1 = CORE(itt1);
  r.dtt0 = CORE(dtt0);
  r.dtt1 = CORE(dtt1);
  r.mmusr = CORE(mmusr);
#if RDVIRT_FPU
  for (int i = 0; i < 8; i++) {
    const auto &w = FPU(fpr)[i];
    r.fp[i].exp = uint16_t(w[2] & 0xFFFF);
    r.fp[i].mant = (uint64_t(w[1]) << 32) | w[0];
  }
  r.fpcr = FPU(fpcr);
  r.fpsr = FPU(fpsr);
  r.fpiar = FPU(fpiar);
#endif
  r.pc = pc;
  r.stopped = CORE(xs) == XS_STOP;
}

StepResult RtlCpu::reset() {
  RtlModel &v = *v_;
  Vrd68041_top *top = v.top;
  // sim/tb/rd68041_core_harness.svh's boot: RSTI held 12 clocks past the
  // asynchronous initialisation.
  top->rst_n = 0;
  top->rsti_n_i = 0;
  for (int i = 0; i < 4; i++) v.clock();
  top->rst_n = 1;
  for (int i = 0; i < 12; i++) v.clock();
  top->rsti_n_i = 1;
  // The reset exception's end is the first boundary, step 0: the clock the
  // core has its PC from the vector and starts fetching (rs R_RUN).
  for (uint64_t i = 0; CORE(rs) != R_RUN; i++) {
    v.clock();
    if (CORE(halted) || i > o_.watchdog) {
      fprintf(stderr, "rtl: the reset exception never ended\n");
      return StepResult::Halted;
    }
  }
  retired_ = 0;
  writes.clear();
  snapshot(v.ram_long(4));
  v.booted = true;
  for (BusRec &b : m_->ring) b.step = 0;
  return StepResult::Boundary;
}

StepResult RtlCpu::run_until_retire() {
  RtlModel &v = *v_;
  Vrd68041_top *top = v.top;
  v.iack = 0;
  v.step = retired_;
  vec_ = -1;
  writes.clear();
  uint64_t start = v.clocks;
  unsigned stopped = 0;
#if VM_TRACE
  if (!o_.vcd.empty() && !v.vcd && retired_ >= o_.vcd_from) {
    v.vcd = new VerilatedVcdC;
    top->trace(v.vcd, 99);
    v.vcd->open(o_.vcd.c_str());
  }
#endif
  for (;;) {
    // The boundary is decided before the edge, and read after it.
    v.fall();
    // An instruction an interrupt follows (w_int) is folded into the
    // interrupt's boundary by `retire`; the processor's model, and the
    // oracle, have one between the two (UM 8.3), made here.
    bool b = CORE(retire) || (CORE(w_end) && CORE(w_int));
    uint32_t npc = CORE(retire) ? CORE(retire_npc) : CORE(w_npc);
    if (CORE(xs) == XS_SEQ) vec_ = CORE(x_vec);
    v.rise();
    if (b) {
      retired_++;
      iack_ = v.iack;
      snapshot(npc);
      return StepResult::Boundary;
    }
    if (CORE(halted)) {
      snapshot(regs_.pc);
      fprintf(stderr, "rtl: halted (a double bus fault, or an instruction not built)\n");
      return StepResult::Halted;
    }
    if (CORE(xs) == XS_STOP) {
      // STOP has no boundary of its own here -- the interrupt that ends it
      // makes the next one -- but the processor's model has one, after the
      // STOP (PRM 6), which is what the oracle shows: made here, once.
      if (!in_stop_) {
        in_stop_ = true;
        retired_++;
        snapshot(CORE(x_npc));
        return StepResult::Boundary;
      }
      if (++stopped > 16 && !v.busy) return StepResult::Stopped;
    } else {
      in_stop_ = false;
      stopped = 0;
    }
#if VM_TRACE
    // vcd_from all ones: the last 2000 clocks before the watchdog fires, the
    // hung core's state.
    if (!o_.vcd.empty() && !v.vcd && o_.vcd_from == UINT64_MAX &&
        v.clocks - start > o_.watchdog - 2000) {
      v.vcd = new VerilatedVcdC;
      top->trace(v.vcd, 99);
      v.vcd->open(o_.vcd.c_str());
    }
#endif
    if (v.clocks - start > o_.watchdog) {
      snapshot(regs_.pc);
      fprintf(stderr, "rtl: no boundary in %llu clocks\n", (unsigned long long)o_.watchdog);
      return StepResult::Halted;
    }
  }
}

void RtlCpu::set_ipl(int level) { v_->top->ipl_n_i = ~level & 7; }
