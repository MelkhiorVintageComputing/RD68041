// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// rd-virt -- the UAE040 socket. cpu_uae.cpp says how it works.
#ifndef RDVIRT_CPU_UAE_H
#define RDVIRT_CPU_UAE_H

#include "cpu_if.h"

struct uae040_state;

class UaeCpu : public CpuIf {
 public:
  // The library owns the RAM: call init_library() first, build the Machine on
  // library_ram(), then this.
  static void init_library(uint32_t ram_bytes, bool dcache, bool fpu);
  static uint8_t *library_ram();
  // Write into the oracle's memory as a supervisor data write would.
  void poke(uint32_t addr, int size, uint32_t v);
  // Replace D0-D7, A0-A6, the stack pointers and the condition codes, at the
  // boundary the socket is at, touching nothing else (the caches above all).
  void set_regs(const CpuRegs &r);
  // Replace FPSR alone.
  void set_fpsr(uint32_t v);

  explicit UaeCpu(Machine *m);
  ~UaeCpu() override;
  const char *name() const override { return "uae040"; }
  StepResult reset() override;
  StepResult run_until_retire() override;
  void set_ipl(int level) override;
  const CpuRegs &regs() override { return regs_; }
  uint64_t retired() const override { return retired_; }
  int last_iack() const override { return iack_; }
  int last_vector() const override { return last_vec_; }
  void inject_interrupt(int level) override;
  void set_undefined(const CpuRegs &r) override;
  // The opcode of the instruction that ended at this boundary.
  int last_opcode() const { return last_op_; }
  void exc(int v) { vec_now_ = v; }

  // In lockstep the socket takes no interrupt of its own: only the leader's.
  void set_follower(bool f) { follower_ = f; }

  // For the library's callbacks.
  Machine *machine() { return m_; }
  int hook(const uae040_state *s);
  bool halted_ = false;
  std::vector<OpWrite> pend_writes;

 private:
  Machine *m_;
  void *stack_;
  CpuRegs regs_;
  uint64_t retired_ = 0;
  int ipl_ = 0, prev_ipl_ = 0, inject_ = 0, iack_ = 0, last_op_ = -1;
  int last_vec_ = -1, vec_now_ = -1;
  bool follower_ = false, stop_reported_ = false;
  StepResult result_ = StepResult::Boundary;
  void publish(const uae040_state *s);
  int pending_level();
  void yield(StepResult r);
};

#endif
