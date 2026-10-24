// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// rd-virt -- the UAE040 socket: the WinUAE MC68040 core of tools/cosim/uae040
// (MMU, both caches and, unless the machine is an MC68LC040, the FPU) behind
// cpu_if.h. RD68031's UAE030 socket, retargeted.
//
// The library enters the core once and stays in it; the only way back out is
// the instruction hook. So the core runs on its own stack, as a coroutine:
// run_until_retire() switches to it, and the hook switches back at the next
// boundary. Everything the core does between two switches -- its bus
// accesses, its exceptions and the longjmps they make -- stays on its stack.
//
// Linked with the GPL oracle, so GPL-2.0-or-later like everything else that
// links it (doc/oracles.md).

#include "cpu_uae.h"

#include <ucontext.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

extern "C" {
#include "uae040.h"
}

#include "machine.h"

namespace {

UaeCpu *self;                // the library is a singleton, and so is this
ucontext_t main_ctx, core_ctx;
const size_t CORE_STACK = 16u << 20;

}  // namespace

// ---------------------------------------------------------------------------
// The bus: RAM is the library's own (the machine was built on it); everything
// else is the machine's devices or a hole.
// ---------------------------------------------------------------------------
static int ext_read(uint32_t pa, int size, uint32_t *v, void *user) {
  Machine *m = static_cast<Machine *>(user);
  return m->io_read(pa, size, *v) ? 1 : 0;
}

static int ext_write(uint32_t pa, int size, uint32_t v, void *user) {
  Machine *m = static_cast<Machine *>(user);
  return m->io_write(pa, size, v) ? 1 : 0;
}

static void bus_hook(const uae040_bus *b, void *user) {
  (void)user;
  if (!self) return;
  BusRec r;
  r.step = self->retired();
  r.addr = b->pa;
  r.data = b->data;
  r.size = uint8_t(b->size);
  r.write = uint8_t(b->write);
  r.tm = uint8_t(b->tm);
  r.berr = uint8_t(b->berr);
  switch (b->kind) {
    case UAE040_KIND_WALK: r.kind = 'T'; break;
    case UAE040_KIND_IFETCH: r.kind = 'F'; break;
    case UAE040_KIND_PUSH: r.kind = 'P'; break;
    case UAE040_KIND_FILL: r.kind = 'L'; break;
    case UAE040_KIND_MOVE16: r.kind = 'M'; break;
    default: r.kind = 'D';
  }
  self->machine()->log(r);
}

static void op_hook(uint32_t la, uint32_t pa, int size, int write, uint32_t data, int fc,
                    int berr, void *user) {
  (void)pa; (void)fc; (void)user;
  if (!self || !write || berr) return;
  self->pend_writes.push_back({la, uint8_t(size), data});
}

static void exc_hook(int vector, void *user) {
  (void)user;
  if (self) self->exc(vector);
}

static int insn_hook(const uae040_state *s, void *user) {
  (void)user;
  return self->hook(s);
}

static void core_main() {
  uae040_run();
  // A halt (double bus fault): park here for good.
  for (;;) {
    self->halted_ = true;
    swapcontext(&core_ctx, &main_ctx);
  }
}

UaeCpu::UaeCpu(Machine *m) : m_(m) {
  self = this;
  uae040_set_ext_bus(ext_read, ext_write, m);
  uae040_set_hooks(insn_hook, bus_hook, nullptr);
  uae040_set_op_hook(op_hook);
  uae040_set_exc_hook(exc_hook);
  stack_ = malloc(CORE_STACK);
}

UaeCpu::~UaeCpu() { free(stack_); }

void UaeCpu::init_library(uint32_t ram_bytes, bool dcache, bool fpu) {
  uae040_init(ram_bytes, dcache ? 1 : 0, fpu ? 1 : 0);
}

uint8_t *UaeCpu::library_ram() { return uae040_ram(); }

void UaeCpu::publish(const uae040_state *s) {
  CpuRegs &r = regs_;
  r.pc = s->pc;
  for (int i = 0; i < 8; i++) { r.d[i] = s->d[i]; r.a[i] = s->a[i]; }
  r.usp = s->usp; r.isp = s->isp; r.msp = s->msp;
  r.sr = s->sr;
  r.vbr = s->vbr; r.sfc = s->sfc; r.dfc = s->dfc; r.cacr = s->cacr;
  r.tc = s->tc; r.urp = s->urp; r.srp = s->srp;
  r.itt0 = s->itt0; r.itt1 = s->itt1; r.dtt0 = s->dtt0; r.dtt1 = s->dtt1;
  r.mmusr = s->mmusr;
  for (int i = 0; i < 8; i++) { r.fp[i].exp = s->fp[i].exp; r.fp[i].mant = s->fp[i].mant; }
  r.fpcr = s->fpcr; r.fpsr = s->fpsr; r.fpiar = s->fpiar;
  r.stopped = uae040_stopped() != 0;
  // STOP leaves the core's program counter on the STOP itself, and the core
  // executes it again at every boundary until an interrupt moves it on (the
  // stacked PC is then the next instruction). The processor's boundary is
  // after the STOP (PRM 6), which is what is reported.
  if (r.stopped) r.pc += 4;
  last_vec_ = vec_now_;
  vec_now_ = -1;
  last_op_ = uae040_last_opcode();
  static bool ftrace = getenv("RDVIRT_FTRACE") != nullptr;
  if (ftrace && (last_op_ & 0xF000) == 0xF000)
    fprintf(stderr, "uae040 F-line %04x at step %llu, next pc %08x\n", last_op_,
            (unsigned long long)retired_, s->pc);
  writes.swap(pend_writes);
  pend_writes.clear();
}

int UaeCpu::pending_level() {
  if (inject_) { int l = inject_; inject_ = 0; return l; }
  if (follower_) return 0;
  int mask = (regs_.sr >> 8) & 7;
  return (ipl_ > mask || (ipl_ == 7 && prev_ipl_ != 7)) ? ipl_ : 0;
}

void UaeCpu::yield(StepResult r) {
  result_ = r;
  swapcontext(&core_ctx, &main_ctx);
}

// At every boundary of the core. Returns to it only when the socket's caller
// wants the next instruction run.
int UaeCpu::hook(const uae040_state *s) {
  bool stopped = uae040_stopped() != 0;
  if (!(stopped && stop_reported_)) {
    publish(s);
    retired_++;
    iack_ = 0;
    stop_reported_ = stopped;
    yield(StepResult::Boundary);
  }
  for (;;) {
    int l = pending_level();
    if (l) {
      prev_ipl_ = ipl_;
      uae040_interrupt(l);
      uae040_state st;
      uae040_get_state(&st);
      stop_reported_ = false;
      publish(&st);
      retired_++;
      iack_ = l;
      yield(StepResult::Boundary);
      continue;
    }
    if (uae040_stopped()) {
      yield(StepResult::Stopped);
      continue;
    }
    break;
  }
  prev_ipl_ = ipl_;
  return 0;
}

StepResult UaeCpu::reset() {
  getcontext(&core_ctx);
  core_ctx.uc_stack.ss_sp = stack_;
  core_ctx.uc_stack.ss_size = CORE_STACK;
  core_ctx.uc_link = &main_ctx;
  makecontext(&core_ctx, core_main, 0);
  retired_ = 0;
  // The reset itself is the first boundary; retired() counts from there.
  StepResult r = run_until_retire();
  retired_ = 0;
  for (BusRec &b : m_->ring) b.step = 0;
  return r;
}

StepResult UaeCpu::run_until_retire() {
  if (halted_) return StepResult::Halted;
  swapcontext(&main_ctx, &core_ctx);
  return halted_ ? StepResult::Halted : result_;
}

void UaeCpu::set_ipl(int level) { ipl_ = level; }

void UaeCpu::inject_interrupt(int level) { inject_ = level; }

void UaeCpu::set_undefined(const CpuRegs &r) {
  // Only from a boundary, which is where the core is parked; and only what
  // differs, since installing a state refetches and installing the MMU's
  // registers flushes the ATCs.
  uae040_state s;
  uae040_get_state(&s);
  if (s.usp != r.usp || s.msp != r.msp || s.sfc != r.sfc || s.dfc != r.dfc) {
    s.usp = r.usp;
    s.msp = r.msp;
    s.sfc = r.sfc;
    s.dfc = r.dfc;
    uae040_set_state(&s);
  }
  uae040_get_state(&s);
  if (s.urp != r.urp || s.srp != r.srp || s.itt0 != r.itt0 || s.itt1 != r.itt1 ||
      s.dtt0 != r.dtt0 || s.dtt1 != r.dtt1 || s.mmusr != r.mmusr) {
    s.urp = r.urp; s.srp = r.srp;
    s.itt0 = r.itt0; s.itt1 = r.itt1; s.dtt0 = r.dtt0; s.dtt1 = r.dtt1;
    s.mmusr = r.mmusr;
    uae040_set_mmu(&s);
  }
  // The FP data registers: a NaN after reset on the core (UM 9.2.1), zero in
  // the oracle (doc/oracles.md).
  bool fp = false;
  for (int i = 0; i < 8; i++)
    if (s.fp[i].exp != r.fp[i].exp || s.fp[i].mant != r.fp[i].mant) fp = true;
  if (fp) {
    for (int i = 0; i < 8; i++) { s.fp[i].exp = r.fp[i].exp; s.fp[i].mant = r.fp[i].mant; }
    uae040_set_fpu(&s);
  }
  uae040_get_state(&s);
  std::vector<OpWrite> keep;
  keep.swap(writes);
  publish(&s);
  writes.swap(keep);
}

void UaeCpu::poke(uint32_t addr, int size, uint32_t v) {
  size_t n = pend_writes.size();
  uae040_poke(addr, size, v);
  pend_writes.resize(n);   // not the program's
}

void UaeCpu::set_regs(const CpuRegs &r) {
  uae040_state s;
  uae040_get_state(&s);
  for (int i = 0; i < 8; i++) s.d[i] = r.d[i];
  for (int i = 0; i < 7; i++) s.a[i] = r.a[i];
  s.usp = r.usp; s.isp = r.isp; s.msp = r.msp;
  s.sr = uint16_t((s.sr & 0xFF00) | (r.sr & 0x1F));
  uae040_set_regs(&s);
  uae040_get_state(&s);
  for (int i = 0; i < 8; i++) { regs_.d[i] = s.d[i]; regs_.a[i] = s.a[i]; }
  regs_.usp = s.usp; regs_.isp = s.isp; regs_.msp = s.msp;
  regs_.sr = s.sr;
}

void UaeCpu::set_fpsr(uint32_t v) {
  uae040_state s;
  uae040_get_state(&s);
  s.fpsr = v;
  uae040_set_fpu(&s);
  uae040_get_state(&s);
  regs_.fpsr = s.fpsr;
}
