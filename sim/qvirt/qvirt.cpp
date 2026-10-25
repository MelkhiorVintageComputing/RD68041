// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// rd-qvirt -- the core as the processor of QEMU's m68k `virt` machine
// (doc/qvirt.md, doc/plan.md section 7). The RTL socket is rd-virt's
// (sim/virt/cpu_rtl.cpp, its pin agent); the machine is QEMU's devices over
// qtest (qemu_machine.h). The console is compared with QEMU's own m68040's
// on the same machine by sim/qvirt/console-diff.py.
//
//   qvirt --qemu QEMU --dir DIR --kernel ELF [--initrd F] [--cmdline S]
//         [--disk IMG] [options]

#include <sys/time.h>

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "cpu_rtl.h"
#include "qemu_machine.h"
#include "script.h"

#ifndef RDVIRT_FPU
#define RDVIRT_FPU 1
#endif

namespace {

double wall() {
  struct timeval tv;
  gettimeofday(&tv, nullptr);
  return tv.tv_sec + tv.tv_usec * 1e-6;
}

void usage() {
  fprintf(stderr,
          "usage: qvirt --qemu QEMU --dir DIR --kernel ELF [options]\n"
          "  --initrd F          -initrd\n"
          "  --cmdline S         -append\n"
          "  --disk IMG          a raw image as a virtio-blk disk (snapshot=on)\n"
          "  --ram MB            RAM (128)\n"
          "  --rtc-base T        the RTC's start, QEMU's -rtc base= (2026-10-01T00:00:00)\n"
          "  --no-fpu            the bootinfo says no FPU (the MC68LC040 build needs it)\n"
          "  --ns N              virtual nanoseconds per clock (40: 25 MHz)\n"
          "  --step-ns N         ... or per instruction boundary, as rd-virt (its bare programs: 20)\n"
          "  --quantum NS        QEMU's clock trails the core's by at most this (50000)\n"
          "  --script F          console script: expect/send lines\n"
          "  --quiet-ns N        type the script's input once the console has been quiet\n"
          "                      this long, in virtual ns (250000000)\n"
          "  --expect S          pass only if the console shows S (repeatable)\n"
          "  --console-log F     copy the console to F\n"
          "  --quiet             do not echo the console\n"
          "  --progress N        report every N boundaries (10000000; 0: never)\n"
          "  --max-steps N       stop after N boundaries\n"
          "  --ram-waits N       wait states on RAM (0)\n"
          "  --io-waits N        wait states on the devices (1)\n"
          "  --tbi               RAM burst-inhibits lines (TBI)\n"
          "  --tci               TCI on every line read (caches off)\n"
          "  --trace-from N      print every boundary's PC and SR from step N\n");
}

}  // namespace

int main(int argc, char **argv) {
  QemuConfig qc;
  RtlOptions ro;
  std::string script;
  std::vector<std::string> expect;
  uint64_t ns = 40, step_ns = 0, quiet_ns = 250000000, progress = 10000000, max_steps = 0, trace_from = UINT64_MAX;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto next = [&]() -> std::string {
      if (i + 1 >= argc) { usage(); exit(2); }
      return argv[++i];
    };
    if (a == "--qemu") qc.qemu = next();
    else if (a == "--dir") qc.dir = next();
    else if (a == "--kernel") qc.kernel = next();
    else if (a == "--initrd") qc.initrd = next();
    else if (a == "--cmdline") qc.cmdline = next();
    else if (a == "--disk") qc.disk = next();
    else if (a == "--rtc-base") qc.rtc_base = next();
    else if (a == "--ram") qc.ram_mb = strtoul(next().c_str(), nullptr, 0);
    else if (a == "--no-fpu") qc.fpu = false;
    else if (a == "--ns") ns = strtoull(next().c_str(), nullptr, 0);
    else if (a == "--quiet-ns") quiet_ns = strtoull(next().c_str(), nullptr, 0);
    else if (a == "--step-ns") step_ns = strtoull(next().c_str(), nullptr, 0);
    else if (a == "--quantum") qc.quantum_ns = strtoull(next().c_str(), nullptr, 0);
    else if (a == "--script") script = next();
    else if (a == "--expect") expect.push_back(next());
    else if (a == "--console-log") qc.console_log = next();
    else if (a == "--quiet") qc.echo = false;
    else if (a == "--progress") progress = strtoull(next().c_str(), nullptr, 0);
    else if (a == "--max-steps") max_steps = strtoull(next().c_str(), nullptr, 0);
    else if (a == "--ram-waits") ro.ram_waits = atoi(next().c_str());
    else if (a == "--io-waits") ro.io_waits = atoi(next().c_str());
    else if (a == "--tbi") ro.tbi = true;
    else if (a == "--tci") ro.tci = true;
    else if (a == "--trace-from") trace_from = strtoull(next().c_str(), nullptr, 0);
    else { usage(); return 2; }
  }
  if (qc.qemu.empty() || qc.dir.empty() || qc.kernel.empty()) { usage(); return 2; }
  // The agent reads a device write's data when it decides how to answer it,
  // a clock after TS at the earliest (a DMA command is held off then).
  if (ro.io_waits < 1) { fprintf(stderr, "rd-qvirt: --io-waits must be 1 or more\n"); return 2; }
#if !RDVIRT_FPU
  if (qc.fpu) { fprintf(stderr, "rd-qvirt: this RTL is an MC68LC040 (FPU=0): --no-fpu\n"); return 2; }
#endif
  Script sc;
  if (!script.empty() && !sc.load(script)) {
    fprintf(stderr, "rd-qvirt: cannot read %s\n", script.c_str());
    return 2;
  }

  QemuMachine m(qc);
  if (!m.start()) return 2;
  ro.reset_ssp = m.ssp();
  ro.reset_pc = m.entry();
  RtlCpu cpu(&m, ro);
  uint64_t skip = 0;
  m.now = [&]() { return (step_ns ? cpu.retired() * step_ns : cpu.clocks() * ns) + skip; };

  // The script's input is typed once the console has been quiet for
  // quiet_ns of virtual time since the text it waited for: a guest echoes
  // what is typed, and the prompt must be out first, as it is for a person.
  std::string typed;
  size_t cons_seen = 0;
  uint64_t quiet_from = 0;
  auto feed = [&]() {
    const std::string &c = m.console();
    uint64_t t = m.now();
    if (c.size() != cons_seen) { cons_seen = c.size(); quiet_from = t; }
    typed += sc.poll(c);
    if (!typed.empty() && t - quiet_from >= quiet_ns) { m.tty_input(typed); typed.clear(); }
    m.pump_input();
  };

  double t0 = wall();
  StepResult r = cpu.reset();
  uint64_t next_prog = progress, stops = 0;
  while (r != StepResult::Halted && !m.powered_off && !m.gone) {
    r = cpu.run_until_retire();
    if (r == StepResult::Halted) break;
    if (r == StepResult::Stopped) {
      // STOP: to QEMU's next deadline, or the script's next input.
      feed();
      if (m.input_pending()) {
        m.sync(true);
        m.pump_input();
      } else {
        uint64_t before = m.now();
        uint64_t t = m.step_to_deadline();
        if (t == UINT64_MAX) {
          if (typed.empty()) { fprintf(stderr, "rd-qvirt: stopped with nothing armed\n"); break; }
          m.tty_input(typed);   // nothing else will ever happen: type it now
          typed.clear();
        } else {
          if (t > before) skip += t - before;
          stops++;
        }
      }
      cpu.set_ipl(m.ipl());
      continue;
    }
    uint64_t n = cpu.retired();
    // QVIRT_WATCH=<hex address>: every operand write that covers it.
    static long wwatch = getenv("QVIRT_WATCH") ? long(strtoul(getenv("QVIRT_WATCH"), nullptr, 16)) : -1;
    if (wwatch >= 0)
      for (const OpWrite &w : cpu.writes)
        if (uint32_t(wwatch) - w.la < w.size)
          fprintf(stderr, "write %08x/%d=%0*x step %" PRIu64 " pc %08x sr %04x a7 %08x\n", w.la, w.size,
                  2 * w.size, w.data, n, cpu.regs().pc, cpu.regs().sr, cpu.regs().a[7]);
    if (n >= trace_from) {
      const CpuRegs &g = cpu.regs();
      fprintf(stderr, "%10" PRIu64 " %08x %04x d %08x %08x %08x %08x a %08x %08x %08x %08x%s\n", n,
              g.pc, g.sr, g.d[0], g.d[1], g.d[2], g.d[3], g.a[0], g.a[1], g.a[5], g.a[7],
              cpu.last_iack() ? " IRQ" : "");
    }
    m.sync(false);
    // The console is looked at, and input fed, every 256 boundaries: at a
    // boundary count, so at the same point in every run.
    if ((n & 255) == 0) feed();
    cpu.set_ipl(m.ipl());
    if (progress && n >= next_prog) {
      double dt = wall() - t0;
      fprintf(stderr, "[qvirt] %" PRIu64 " steps, %.1f s, %.0f steps/s, virtual %.3f s, pc %08x\n",
              n, dt, n / dt, m.now() * 1e-9, cpu.regs().pc);
      next_prog += progress;
    }
    if (max_steps && n >= max_steps) {
      fprintf(stderr, "rd-qvirt: step limit reached\n");
      break;
    }
  }
  double dt = wall() - t0;
  uint64_t n = cpu.retired(), dcmds, dxfers, dsrc;
  cpu.dma_stats(dcmds, dxfers, dsrc);
  fprintf(stderr, "[qvirt] end: %" PRIu64 " steps in %.1f s (%.0f steps/s), virtual %.3f s, "
          "%" PRIu64 " clocks, %" PRIu64 " qtest round trips, %" PRIu64 " virtio settles, "
          "%" PRIu64 " DMA commands (%" PRIu64 " snooped transfers, %" PRIu64 " lines sourced), "
          "%" PRIu64 " STOP skips, %s\n",
          n, dt, n / (dt > 0 ? dt : 1), m.now() * 1e-9, cpu.clocks(), m.round_trips, m.settles,
          dcmds, dxfers, dsrc, stops,
          r == StepResult::Halted ? "HALTED"
          : m.panicked ? "virt-ctrl PANIC"
          : m.powered_off ? "powered off"
          : m.gone ? "QEMU went away" : "stopped");
  if (r == StepResult::Halted || !m.powered_off) {
    const CpuRegs &g = cpu.regs();
    fprintf(stderr, "PC %08x SR %04x A7 %08x\n", g.pc, g.sr, g.a[7]);
    m.dump_ring(stderr, getenv("RDVIRT_RING") ? atoi(getenv("RDVIRT_RING")) : 32);
  }
  bool ok = m.powered_off && !m.panicked;
  for (const std::string &e : expect)
    if (m.console().find(e) == std::string::npos) {
      fprintf(stderr, "rd-qvirt: console never showed \"%s\"\n", e.c_str());
      ok = false;
    }
  if (!sc.done() || !typed.empty()) { fprintf(stderr, "rd-qvirt: the script did not finish\n"); ok = false; }
  printf("%s: rd-qvirt, %" PRIu64 " steps, %" PRIu64 " clocks\n", ok ? "PASS" : "FAIL", n,
         cpu.clocks());
  return ok ? 0 : 1;
}
