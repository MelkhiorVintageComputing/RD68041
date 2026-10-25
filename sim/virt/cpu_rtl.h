// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// rd-virt -- the RTL socket: rd68041_top under Verilator, with a pin-level bus
// agent in front of the machine. cpu_rtl.cpp says how the agent answers.
#ifndef RDVIRT_CPU_RTL_H
#define RDVIRT_CPU_RTL_H

#include <memory>
#include <string>

#include "cpu_if.h"

struct RtlOptions {
  int  ram_waits = 0;      // wait states before each TA of RAM
  int  io_waits = 1;       // ... and of the devices
  bool tbi = false;        // RAM answers a line with TBI: four long-word transfers
  bool tci = false;        // answer every line read with TCI: no line is ever
                           // allocated, so both caches stay empty (UM 7.4.2)
  uint64_t watchdog = 2000000;  // clocks without a boundary before giving up
  std::string vcd;
  uint64_t vcd_from = 0;
  // The reset exception's two vector reads ($0, $4) answered with these
  // instead of RAM's, when reset_pc >= 0: the state QEMU's virt machine starts
  // its own CPU in (rd-qvirt). Every other read of $0-$7 is RAM's.
  int64_t reset_ssp = -1, reset_pc = -1;
};

class BusIf;
struct RtlModel;

class RtlCpu : public CpuIf {
 public:
  RtlCpu(BusIf *m, const RtlOptions &o);
  ~RtlCpu() override;
  const char *name() const override { return "rtl"; }
  StepResult reset() override;
  StepResult run_until_retire() override;
  void set_ipl(int level) override;
  const CpuRegs &regs() override { return regs_; }
  uint64_t retired() const override { return retired_; }
  int last_iack() const override { return iack_; }
  int last_vector() const override { return vec_; }
  void inject_interrupt(int) override {}
  void set_undefined(const CpuRegs &) override {}
  uint64_t clocks() const;
  // The DMA master's commands, snooped transfers, and lines the core sourced.
  void dma_stats(uint64_t &cmds, uint64_t &xfers, uint64_t &sourced) const;

 private:
  BusIf *m_;
  RtlOptions o_;
  std::unique_ptr<RtlModel> v_;
  CpuRegs regs_;
  uint64_t retired_ = 0;
  int iack_ = 0, vec_ = -1;
  bool in_stop_ = false;
  void snapshot(uint32_t pc);
};

#endif
