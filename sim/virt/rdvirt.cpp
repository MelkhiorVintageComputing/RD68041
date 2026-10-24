// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// rd-virt -- the deterministic m68k `virt` machine, with the RTL, the UAE040
// oracle, or both in lockstep (doc/plan.md Layer 3, doc/virt.md). RD68031's
// rd-virt for the MC68040 and MC68LC040.
//
//   rdvirt --cpu uae|rtl|lockstep  (--kernel vmlinux [--initrd f] [--cmdline s]
//                                   | --bare prog.elf) [options]
//
// The lockstep: the RTL leads. After each of its steps the oracle takes the
// same step -- an interrupt the RTL acknowledged is taken by the oracle at the
// same boundary -- and the two are compared: every register, and the operand
// writes the step made. Each side has its own machine; both are told the same
// time at every boundary, so their devices agree without being shared.
//
// Linked with the GPL oracle, hence GPL-2.0-or-later.

#include <sys/time.h>

#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "cpu_if.h"
#include "cpu_uae.h"
#include "machine.h"
#ifdef RDVIRT_RTL
#include "cpu_rtl.h"
#endif

namespace {

struct Options {
  std::string cpu = "uae";
  std::string kernel, initrd, cmdline, bare, script, dump = "rdvirt-divergence.txt";
  std::vector<std::string> expect;
  MachineConfig mc;
  uint64_t max_steps = 0;            // 0: no limit
  uint64_t progress = 10000000;
  bool dcache = true;
  bool compare_writes = true;
  bool frames_whole = false;         // lockstep: compare $7 and FSAVE frames byte for byte
  bool align_wfault = true;          // lockstep: a write's access fault, restarted here (m13-c1)
  bool align_fsize = true;           // lockstep: a fetch fault's SIZE in the oracle's frame (m13-c2)
  bool align_unimp_fpsr = true;      // lockstep: the FPSR at an unimplemented FP instruction (m13-c6)
  int maxdiv = 1;
  uint64_t dump_at = 0;
  uint64_t trace_from = UINT64_MAX;  // print every boundary from this step
#ifdef RDVIRT_RTL
  RtlOptions rtl;
#endif
};

double wall() {
  struct timeval tv;
  gettimeofday(&tv, nullptr);
  return tv.tv_sec + tv.tv_usec * 1e-6;
}

// ---------------------------------------------------------------------------
// The console script: `expect <text>` waits for the text to appear in the
// console after the last match, `send <text>` types it (\n, \r, \t escapes).
// ---------------------------------------------------------------------------
struct Script {
  struct Item { bool send; std::string text; };
  std::vector<Item> items;
  size_t pos = 0, seen = 0;
  bool load(const std::string &path) {
    FILE *f = fopen(path.c_str(), "r");
    if (!f) return false;
    char line[4096];
    while (fgets(line, sizeof line, f)) {
      std::string l(line);
      while (!l.empty() && (l.back() == '\n' || l.back() == '\r')) l.pop_back();
      if (l.empty() || l[0] == '#') continue;
      bool send = l.compare(0, 5, "send ") == 0;
      bool exp = l.compare(0, 7, "expect ") == 0;
      if (!send && !exp) continue;
      std::string t = l.substr(send ? 5 : 7), u;
      for (size_t i = 0; i < t.size(); i++) {
        if (t[i] == '\\' && i + 1 < t.size()) {
          char c = t[++i];
          u.push_back(c == 'n' ? '\n' : c == 'r' ? '\r' : c == 't' ? '\t' : c);
        } else {
          u.push_back(t[i]);
        }
      }
      items.push_back({send, u});
    }
    fclose(f);
    return true;
  }
  // What to type now, given the console so far.
  std::string poll(const std::string &cons) {
    std::string out;
    while (pos < items.size()) {
      Item &it = items[pos];
      if (it.send) { out += it.text; pos++; continue; }
      size_t at = cons.find(it.text, seen);
      if (at == std::string::npos) break;
      seen = at + it.text.size();
      pos++;
    }
    return out;
  }
  bool done() const { return pos >= items.size(); }
};

std::string fmt_regs(const CpuRegs &r) {
  char b[2048];
  int n = snprintf(b, sizeof b,
           "PC %08x SR %04x%s\n"
           "D  %08x %08x %08x %08x %08x %08x %08x %08x\n"
           "A  %08x %08x %08x %08x %08x %08x %08x %08x\n"
           "USP %08x ISP %08x MSP %08x VBR %08x SFC %x DFC %x CACR %08x\n"
           "TC %04x URP %08x SRP %08x ITT %08x %08x DTT %08x %08x MMUSR %08x\n"
           "FPCR %08x FPSR %08x FPIAR %08x\n",
           r.pc, r.sr, r.stopped ? " (stopped)" : "", r.d[0], r.d[1], r.d[2], r.d[3],
           r.d[4], r.d[5], r.d[6], r.d[7], r.a[0], r.a[1], r.a[2], r.a[3], r.a[4], r.a[5],
           r.a[6], r.a[7], r.usp, r.isp, r.msp, r.vbr, r.sfc, r.dfc, r.cacr, r.tc, r.urp,
           r.srp, r.itt0, r.itt1, r.dtt0, r.dtt1, r.mmusr, r.fpcr, r.fpsr, r.fpiar);
  for (int i = 0; i < 8; i++)
    n += snprintf(b + n, sizeof b - n, "FP%d %04x %016" PRIx64 "%s", i, r.fp[i].exp,
                  r.fp[i].mant, (i & 3) == 3 ? "\n" : "  ");
  return b;
}

// Register comparison, under the bits UM 3.1 gives the MMU's registers.
[[maybe_unused]] std::vector<std::string> compare(const CpuRegs &a, const CpuRegs &b) {
  std::vector<std::string> why;
  char s[160];
  auto chk = [&](const char *n, uint64_t x, uint64_t y) {
    if (x != y) {
      snprintf(s, sizeof s, "%s: rtl %08" PRIx64 " uae %08" PRIx64, n, x, y);
      why.push_back(s);
    }
  };
  chk("PC", a.pc, b.pc);
  chk("SR", a.sr, b.sr);
  static const char *dn[] = {"D0", "D1", "D2", "D3", "D4", "D5", "D6", "D7"};
  static const char *an[] = {"A0", "A1", "A2", "A3", "A4", "A5", "A6", "A7"};
  for (int i = 0; i < 8; i++) chk(dn[i], a.d[i], b.d[i]);
  for (int i = 0; i < 8; i++) chk(an[i], a.a[i], b.a[i]);
  chk("USP", a.usp, b.usp);
  chk("ISP", a.isp, b.isp);
  chk("MSP", a.msp, b.msp);
  chk("VBR", a.vbr, b.vbr);
  chk("SFC", a.sfc, b.sfc);
  chk("DFC", a.dfc, b.dfc);
  chk("CACR", a.cacr, b.cacr);
  chk("TC", a.tc & 0xC000u, b.tc & 0xC000u);
  chk("URP", a.urp & 0xFFFFFE00u, b.urp & 0xFFFFFE00u);
  chk("SRP", a.srp & 0xFFFFFE00u, b.srp & 0xFFFFFE00u);
  chk("ITT0", a.itt0 & 0xFFFFE364u, b.itt0 & 0xFFFFE364u);
  chk("ITT1", a.itt1 & 0xFFFFE364u, b.itt1 & 0xFFFFE364u);
  chk("DTT0", a.dtt0 & 0xFFFFE364u, b.dtt0 & 0xFFFFE364u);
  chk("DTT1", a.dtt1 & 0xFFFFE364u, b.dtt1 & 0xFFFFE364u);
  chk("MMUSR", a.mmusr, b.mmusr);
  chk("FPCR", a.fpcr, b.fpcr);
  chk("FPSR", a.fpsr, b.fpsr);
  chk("FPIAR", a.fpiar, b.fpiar);
  static const char *fn[] = {"FP0", "FP1", "FP2", "FP3", "FP4", "FP5", "FP6", "FP7"};
  for (int i = 0; i < 8; i++)
    if (a.fp[i] != b.fp[i]) {
      snprintf(s, sizeof s, "%s: rtl %04x %016" PRIx64 " uae %04x %016" PRIx64, fn[i],
               a.fp[i].exp, a.fp[i].mant, b.fp[i].exp, b.fp[i].mant);
      why.push_back(s);
    }
  return why;
}

// A step's operand writes, cut into bytes: the last value each byte got.
[[maybe_unused]] std::map<uint32_t, uint8_t> bytes_of(const std::vector<OpWrite> &w) {
  std::map<uint32_t, uint8_t> m;
  for (const OpWrite &x : w)
    for (int i = 0; i < x.size; i++) m[x.la + i] = uint8_t(x.data >> (8 * (x.size - 1 - i)));
  return m;
}

// One processor on one machine: virt-uae, virt-linux-solo.
int run_solo(Options &o, CpuIf &cpu, Machine &m) {
  Script sc;
  if (!o.script.empty() && !sc.load(o.script)) {
    fprintf(stderr, "rd-virt: cannot read %s\n", o.script.c_str());
    return 2;
  }
  double t0 = wall();
  uint64_t skip = 0;
  StepResult r = cpu.reset();
  uint64_t next_prog = o.progress;
  uint64_t idle_skips = 0;
  while (r != StepResult::Halted && !m.powered_off) {
    r = cpu.run_until_retire();
    if (r == StepResult::Halted) break;
    if (r == StepResult::Stopped) {
      uint64_t t = m.next_event();
      if (t == UINT64_MAX) {
        // Nothing will ever wake it, unless the script types something.
        std::string in = sc.poll(m.console());
        if (in.empty()) { fprintf(stderr, "rd-virt: stopped with nothing armed\n"); break; }
        m.tty_input(in);
      } else if (t > m.now()) {
        skip += t - m.now();
        idle_skips++;
        m.set_time(t);
      }
      cpu.set_ipl(m.ipl());
      continue;
    }
    uint64_t n = cpu.retired();
    if (n >= o.trace_from) {
      const CpuRegs &g = cpu.regs();
      fprintf(stderr, "%10" PRIu64 " %08x %04x d %08x %08x %08x %08x a %08x %08x %08x %08x%s\n", n,
              g.pc, g.sr, g.d[0], g.d[1], g.d[2], g.d[3], g.a[0], g.a[1], g.a[5], g.a[7],
              cpu.last_iack() ? " IRQ" : "");
    }
    m.set_time(n * o.mc.ns_per_step + skip);
    std::string in = sc.poll(m.console());
    if (!in.empty()) m.tty_input(in);
    cpu.set_ipl(m.ipl());
    if (o.progress && n >= next_prog) {
      double dt = wall() - t0;
      fprintf(stderr, "[%s] %" PRIu64 " steps, %.1f s, %.0f steps/s, virtual %.3f s, pc %08x\n",
              cpu.name(), n, dt, n / dt, m.now() * 1e-9, cpu.regs().pc);
      next_prog += o.progress;
    }
    if (o.max_steps && n >= o.max_steps) {
      fprintf(stderr, "rd-virt: step limit reached\n");
      break;
    }
  }
  double dt = wall() - t0;
  uint64_t n = cpu.retired();
  fprintf(stderr, "[%s] end: %" PRIu64 " steps in %.1f s (%.0f steps/s), virtual %.3f s, "
          "%" PRIu64 " idle skips, %s\n",
          cpu.name(), n, dt, n / (dt > 0 ? dt : 1), m.now() * 1e-9, idle_skips,
          r == StepResult::Halted ? "HALTED"
          : m.panicked ? "virt-ctrl PANIC"
          : m.powered_off ? "powered off" : "stopped");
  if (r == StepResult::Halted || !m.powered_off) {
    fprintf(stderr, "%s", fmt_regs(cpu.regs()).c_str());
    m.dump_ring(stderr, getenv("RDVIRT_RING") ? atoi(getenv("RDVIRT_RING")) : 32);
  }
  bool ok = m.powered_off && !m.panicked;
  for (const std::string &e : o.expect)
    if (m.console().find(e) == std::string::npos) {
      fprintf(stderr, "rd-virt: console never showed \"%s\"\n", e.c_str());
      ok = false;
    }
  if (!sc.done()) { fprintf(stderr, "rd-virt: the script did not finish\n"); ok = false; }
  printf("%s: rd-virt %s, %" PRIu64 " steps\n", ok ? "PASS" : "FAIL", cpu.name(), n);
  return ok ? 0 : 1;
}

#ifdef RDVIRT_RTL
// The bytes of a step's writes the comparison leaves out: the internal part
// of an exception frame the step stacked -- an access error frame's
// ($7, UM 8.4.6) beyond its format and vector word, and its effective address
// too unless a continuation bit says it holds one (UM 8.4.6.1) -- and of an
// FSAVE frame beyond its first long word (UM 9.8). What the two processors
// keep there is each one's own; the handler that reads it is compared in
// what it then does.
struct Skip { uint32_t lo = 0, hi = 0; };

Skip frame_skip(const CpuIf &cpu, const std::map<uint32_t, uint8_t> &w, int opcode_fsave) {
  Skip k;
  const CpuRegs &r = const_cast<CpuIf &>(cpu).regs();
  if (cpu.last_vector() >= 0) {
    uint32_t sp = r.a[7];
    auto f = w.find(sp + 6);
    if (f != w.end() && (f->second >> 4) == 0x7) {
      auto c = w.find(sp + 0x0C);
      bool cont = c != w.end() && (c->second & 0xF0);
      k.lo = sp + (cont ? 0x0C : 0x08);
      k.hi = sp + 60;
    }
  } else if (opcode_fsave && !w.empty()) {
    uint32_t lo = w.begin()->first;
    k.lo = lo + 4;
    k.hi = w.rbegin()->first + 1;
  }
  return k;
}

int run_lockstep(Options &o, RtlCpu &rtl, Machine &mr, UaeCpu &uae, Machine &mu) {
  Script sc;
  if (!o.script.empty() && !sc.load(o.script)) {
    fprintf(stderr, "rd-virt: cannot read %s\n", o.script.c_str());
    return 2;
  }
  uae.set_follower(true);
  double t0 = wall();
  uint64_t skip = 0, next_prog = o.progress, frames = 0, fsaves = 0, wbytes = 0, wfaults = 0, fsizes = 0, unimp_fpsr = 0;
  StepResult rr = rtl.reset();
  StepResult ru = uae.reset();
  // A reset defines the status register, VBR, CACR and TC's E and P, and the
  // FPU's control registers (UM 8.1, 3.1, 9.2); the rest is whatever it was.
  // The oracle takes the RTL's.
  uae.set_undefined(rtl.regs());
  int ndiv = 0;
  FILE *dump = nullptr;
  auto diverge = [&](const char *what, const std::vector<std::string> &why) {
    if (!dump) dump = fopen(o.dump.c_str(), "w");
    FILE *outs[2] = {stderr, dump};
    for (FILE *f : outs) {
      if (!f) continue;
      fprintf(f, "DIVERGENCE (%s) at step %" PRIu64 ", virtual time %" PRIu64 " ns\n", what,
              rtl.retired(), mr.now());
      for (auto &w : why) fprintf(f, "  %s\n", w.c_str());
      fprintf(f, "RTL (vector %d):\n%sUAE040 (last opcode %04x, vector %d):\n%s",
              rtl.last_vector(), fmt_regs(rtl.regs()).c_str(), uae.last_opcode() & 0xFFFF,
              uae.last_vector(), fmt_regs(uae.regs()).c_str());
      fprintf(f, "the step's writes, rtl:");
      for (const OpWrite &x : rtl.writes) fprintf(f, " %08x/%d=%0*x", x.la, x.size, 2 * x.size, x.data);
      fprintf(f, "\n                   uae:");
      for (const OpWrite &x : uae.writes) fprintf(f, " %08x/%d=%0*x", x.la, x.size, 2 * x.size, x.data);
      fprintf(f, "\n");
    }
    if (dump) {
      fprintf(dump, "--- RTL bus, last 4096 transfers\n");
      mr.dump_ring(dump);
      fprintf(dump, "--- UAE040 bus, last 4096 accesses\n");
      mu.dump_ring(dump);
      fflush(dump);
    }
    ndiv++;
  };
  while (rr != StepResult::Halted && ru != StepResult::Halted && !mr.powered_off) {
    rr = rtl.run_until_retire();
    if (rr == StepResult::Halted) break;
    if (rr == StepResult::Stopped) {
      uint64_t t = mr.next_event();
      if (t == UINT64_MAX) {
        std::string in = sc.poll(mr.console());
        if (in.empty()) { fprintf(stderr, "rd-virt: stopped with nothing armed\n"); break; }
        mr.tty_input(in);
        mu.tty_input(in);
      } else if (t > mr.now()) {
        skip += t - mr.now();
        mr.set_time(t);
        mu.set_time(t);
      }
      rtl.set_ipl(mr.ipl());
      continue;
    }
    int lvl = rtl.last_iack();
    if (lvl) uae.inject_interrupt(lvl);
    ru = uae.run_until_retire();
    if (ru == StepResult::Halted) break;
    uint64_t n = rtl.retired();
    if (n >= o.trace_from) {
      const CpuRegs &g = rtl.regs();
      fprintf(stderr, "%10" PRIu64 " %08x %04x d %08x %08x %08x %08x a %08x %08x %08x %08x%s\n", n,
              g.pc, g.sr, g.d[0], g.d[1], g.d[2], g.d[3], g.a[0], g.a[1], g.a[5], g.a[7],
              lvl ? " IRQ" : "");
    }
    // m13-c1 (doc/m13-mismatches.md): a write whose translation faults is
    // taken before it is made here -- the frame's PC the instruction's, no
    // write-back pending, An as it was, and RTE runs the instruction again --
    // and after the instruction in the oracle, as on the part: the write in
    // a write-back slot for the handler, the PC the next instruction's, An
    // moved (doc/divergences.md, "A write's access fault is taken before the
    // write"). The handler would take two paths, so the oracle is given the
    // core's frame, its address registers and its condition codes, the frame
    // through the oracle's own write path; its RTE then runs the instruction
    // again as the core's does.
    bool aligned_now = false;
    if (o.align_wfault && rtl.last_vector() == 2 && uae.last_vector() == 2 &&
        rtl.regs().a[7] == uae.regs().a[7]) {
      uint32_t sp = rtl.regs().a[7];
      std::map<uint32_t, uint8_t> fr = bytes_of(rtl.writes), fu = bytes_of(uae.writes);
      auto w16 = [](const std::map<uint32_t, uint8_t> &m, uint32_t a) -> int {
        auto p = m.find(a), q = m.find(a + 1);
        return (p == m.end() || q == m.end()) ? -1 : (p->second << 8) | q->second;
      };
      int rfv = w16(fr, sp + 6), ufv = w16(fu, sp + 6), rssw = w16(fr, sp + 0x0C);
      bool whole = true;
      for (uint32_t k = 0; k < 60; k++) whole = whole && fr.count(sp + k);
      auto wb = [&](const std::map<uint32_t, uint8_t> &m) {
        bool v = false;
        for (uint32_t o2 : {0x0Fu, 0x11u, 0x13u}) { auto p = m.find(sp + o2); v = v || (p != m.end() && (p->second & 0x80)); }
        return v;
      };
      if (whole && rfv >= 0 && ufv >= 0 && (rfv >> 12) == 7 && (ufv >> 12) == 7 && rssw >= 0 &&
          !(rssw & 0x0100) && !wb(fr) && wb(fu)) {
        for (uint32_t k = 0; k < 60; k += 4)
          uae.poke(sp + k, 4, (uint32_t(fr[sp + k]) << 24) | (fr[sp + k + 1] << 16) |
                                  (fr[sp + k + 2] << 8) | fr[sp + k + 3]);
        CpuRegs x = uae.regs();
        for (int i = 0; i < 7; i++) {
          int32_t d = int32_t(x.a[i] - rtl.regs().a[i]);
          if (d != 0 && d >= -16 && d <= 16) x.a[i] = rtl.regs().a[i];
        }
        int32_t du = int32_t(x.usp - rtl.regs().usp);
        if (du != 0 && du >= -16 && du <= 16) x.usp = rtl.regs().usp;
        // ... and the condition codes the instruction did not set here.
        x.sr = uint16_t((x.sr & 0xFF00) | (rtl.regs().sr & 0x1F));
        uae.set_regs(x);
        wfaults++;
        aligned_now = true;
      } else if (whole && rfv >= 0 && ufv >= 0 && (rfv >> 12) == 7 && (ufv >> 12) == 7 &&
                 rssw >= 0 && w16(fu, sp + 0x0C) >= 0 && o.align_fsize) {
        // m13-c2: an instruction fetch's fault: SIZE word and FA the
        // instruction word's in the oracle's frame; SIZE long and FA the
        // long word's in the core's -- the access the MC68040 makes (UM
        // 8.4.6.2 "the original access size", 7.3; doc/oracles.md, M10).
        // When the two differ in those alone, for a fetch (TM 010 or 110),
        // the oracle's frame gets the core's.
        int ussw = w16(fu, sp + 0x0C);
        auto w32 = [&](const std::map<uint32_t, uint8_t> &m, uint32_t a) -> int64_t {
          int h = w16(m, a), l = w16(m, a + 2);
          return (h < 0 || l < 0) ? -1 : (int64_t(h) << 16) | l;
        };
        int64_t rfa = w32(fr, sp + 0x14), ufa = w32(fu, sp + 0x14);
        if ((rssw & 3) == 2 && ((ussw ^ rssw) & ~0x0060) == 0 && rfa >= 0 && ufa >= 0 &&
            (rfa >> 2) == (ufa >> 2) && (ussw != rssw || rfa != ufa)) {
          uae.poke(sp + 0x0C, 2, uint32_t(rssw));
          uae.poke(sp + 0x14, 4, uint32_t(rfa));
          fsizes++;
        }
      }
    }
    // m13-c6: an unimplemented FP instruction's trap (vector 11, format $2):
    // the core leaves the FPSR's condition codes and EXC byte as the
    // instruction before left them, the oracle clears them. The manual
    // leaves it open (UM 9.2.3.3: "the start of most operations clears this
    // byte" -- the hardware never starts this one), and the FPSP clears both
    // first thing (x_unimp.S's "D25B fix"). The oracle gets the core's FPSR.
    if (o.align_unimp_fpsr && rtl.last_vector() == 11 && uae.last_vector() == 11 &&
        rtl.regs().fpsr != uae.regs().fpsr &&
        ((rtl.regs().fpsr ^ uae.regs().fpsr) & ~0xFF00FF00u) == 0) {
      std::map<uint32_t, uint8_t> fr = bytes_of(rtl.writes);
      auto f = fr.find(rtl.regs().a[7] + 6);
      if (f != fr.end() && (f->second >> 4) == 0x2) {
        uae.set_fpsr(rtl.regs().fpsr);
        unimp_fpsr++;
      }
    }
    std::vector<std::string> why = compare(rtl.regs(), uae.regs());
    if (!why.empty()) {
      diverge("registers", why);
      if (ndiv >= o.maxdiv) break;
    }
    if (o.compare_writes) {
      std::map<uint32_t, uint8_t> wr = bytes_of(rtl.writes), wu = bytes_of(uae.writes);
      wbytes += wr.size();
      bool fsave = (uae.last_opcode() & 0xFFC0) == 0xF300 && uae.last_vector() < 0;
      Skip k;
      if (!o.frames_whole) {
        k = frame_skip(rtl, wr, fsave);
        if (aligned_now) { k.lo = rtl.regs().a[7]; k.hi = k.lo + 60; }
        if (k.hi > k.lo) { if (fsave) fsaves++; else frames++; }
      }
      std::vector<std::string> wd;
      char s[160];
      auto in_skip = [&](uint32_t a) { return a >= k.lo && a < k.hi; };
      for (auto &p : wr) {
        if (in_skip(p.first)) continue;
        auto q = wu.find(p.first);
        if (q == wu.end())
          snprintf(s, sizeof s, "byte %08x: rtl wrote %02x, uae did not", p.first, p.second);
        else if (q->second != p.second)
          snprintf(s, sizeof s, "byte %08x: rtl wrote %02x, uae %02x", p.first, p.second, q->second);
        else
          continue;
        if (wd.size() < 32) wd.push_back(s);
      }
      for (auto &p : wu) {
        if (in_skip(p.first) || wr.count(p.first)) continue;
        snprintf(s, sizeof s, "byte %08x: uae wrote %02x, rtl did not", p.first, p.second);
        if (wd.size() < 32) wd.push_back(s);
      }
      if (!wd.empty()) {
        diverge("writes", wd);
        if (ndiv >= o.maxdiv) break;
      }
    }
    if (o.dump_at && n >= o.dump_at) {
      diverge("requested dump", {});
      ndiv--;
      break;
    }
    uint64_t t = n * o.mc.ns_per_step + skip;
    mr.set_time(t);
    mu.set_time(t);
    std::string in = sc.poll(mr.console());
    if (!in.empty()) { mr.tty_input(in); mu.tty_input(in); }
    rtl.set_ipl(mr.ipl());
    if (o.progress && n >= next_prog) {
      double dt = wall() - t0;
      fprintf(stderr, "[lockstep] %" PRIu64 " steps, %.1f s, %.0f steps/s, virtual %.3f s, pc %08x\n",
              n, dt, n / dt, mr.now() * 1e-9, rtl.regs().pc);
      next_prog += o.progress;
    }
    if (o.max_steps && n >= o.max_steps) {
      fprintf(stderr, "rd-virt: step limit reached\n");
      break;
    }
  }
  if (dump) fclose(dump);
  double dt = wall() - t0;
  uint64_t n = rtl.retired();
  fprintf(stderr, "[lockstep] end: %" PRIu64 " steps in %.1f s (%.0f steps/s), virtual %.3f s, "
          "%" PRIu64 " clocks, %" PRIu64 " bytes written and compared, %" PRIu64
          " access error frames and %" PRIu64 " FSAVE frames compared in part, %" PRIu64
          " write faults aligned (m13-c1), %" PRIu64 " fetch fault SIZE/FA aligned (m13-c2), %" PRIu64
          " FPSRs at an unimplemented FP instruction aligned (m13-c6), %d divergences, %s\n",
          n, dt, n / (dt > 0 ? dt : 1), mr.now() * 1e-9, rtl.clocks(), wbytes, frames, fsaves, wfaults,
          fsizes, unimp_fpsr, ndiv,
          rr == StepResult::Halted ? "RTL HALTED"
          : ru == StepResult::Halted ? "UAE040 HALTED"
          : mr.panicked ? "virt-ctrl PANIC"
          : mr.powered_off ? "powered off" : "stopped");
  if (rr == StepResult::Halted || ru == StepResult::Halted)
    fprintf(stderr, "RTL:\n%sUAE040:\n%s", fmt_regs(rtl.regs()).c_str(), fmt_regs(uae.regs()).c_str());
  bool ok = ndiv == 0 && mr.powered_off && !mr.panicked && mu.console() == mr.console();
  if (mu.console() != mr.console()) fprintf(stderr, "rd-virt: the two consoles differ\n");
  for (const std::string &e : o.expect)
    if (mr.console().find(e) == std::string::npos) {
      fprintf(stderr, "rd-virt: console never showed \"%s\"\n", e.c_str());
      ok = false;
    }
  if (!sc.done()) { fprintf(stderr, "rd-virt: the script did not finish\n"); ok = false; }
  printf("%s: rd-virt lockstep, %" PRIu64 " steps, %d divergences\n", ok ? "PASS" : "FAIL", n, ndiv);
  return ok ? 0 : 1;
}
#endif

void usage() {
  fprintf(stderr,
          "usage: rdvirt --cpu uae|rtl|lockstep (--kernel F [--initrd F] [--cmdline S] | --bare ELF)\n"
          "  --ram MB            RAM size (64)\n"
          "  --no-fpu            an MC68LC040: the bootinfo says no FPU, the oracle has none\n"
          "  --ns N              virtual nanoseconds per instruction boundary (20)\n"
          "  --max-steps N       stop after N boundaries\n"
          "  --script F          console script: expect/send lines\n"
          "  --expect S          pass only if the console shows S (repeatable)\n"
          "  --console-log F     copy the console to F\n"
          "  --quiet             do not echo the console\n"
          "  --progress N        report every N boundaries (0: never)\n"
          "  --no-dcache         UAE040 without its data-cache emulation\n"
          "  --dump F            the divergence dump (rdvirt-divergence.txt)\n"
          "  --no-writes         lockstep: registers only\n"
          "  --frames-whole      lockstep: compare access error and FSAVE frames byte for byte\n"
          "  --strict-wfault     lockstep: do not give the oracle the core's frame for a write's fault\n"
          "  --strict-fsize      lockstep: leave the oracle's SIZE and FA in a fetch fault's frame\n"
          "  --strict-fpsr       lockstep: leave the oracle's FPSR at an unimplemented FP instruction\n"
          "  --maxdiv N          lockstep: go on after N-1 divergences\n"
          "  --trace-from N      print every boundary's PC, SR and some registers from step N\n"
          "  --dump-at N         lockstep: dump both states and buses at step N, and stop\n"
#ifdef RDVIRT_RTL
          "  --ram-waits N       RTL: wait states on RAM (0)\n"
          "  --io-waits N        RTL: wait states on the devices (1)\n"
          "  --tbi               RTL: RAM burst-inhibits lines (TBI)\n"
          "  --tci               RTL: TCI on every line read (no line allocated: caches off)\n"
          "  --vcd F --vcd-from N  RTL: dump a VCD from boundary N\n"
#endif
  );
}

}  // namespace

int main(int argc, char **argv) {
  Options o;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto next = [&]() -> std::string {
      if (i + 1 >= argc) { usage(); exit(2); }
      return argv[++i];
    };
    if (a == "--cpu") o.cpu = next();
    else if (a == "--kernel") o.kernel = next();
    else if (a == "--initrd") o.initrd = next();
    else if (a == "--cmdline") o.cmdline = next();
    else if (a == "--bare") o.bare = next();
    else if (a == "--ram") o.mc.ram_mb = strtoul(next().c_str(), nullptr, 0);
    else if (a == "--no-fpu") o.mc.fpu = false;
    else if (a == "--ns") o.mc.ns_per_step = strtoull(next().c_str(), nullptr, 0);
    else if (a == "--max-steps") o.max_steps = strtoull(next().c_str(), nullptr, 0);
    else if (a == "--script") o.script = next();
    else if (a == "--expect") o.expect.push_back(next());
    else if (a == "--console-log") o.mc.console_log = next();
    else if (a == "--quiet") o.mc.echo = false;
    else if (a == "--progress") o.progress = strtoull(next().c_str(), nullptr, 0);
    else if (a == "--no-dcache") o.dcache = false;
    else if (a == "--dump") o.dump = next();
    else if (a == "--no-writes") o.compare_writes = false;
    else if (a == "--frames-whole") o.frames_whole = true;
    else if (a == "--strict-wfault") o.align_wfault = false;
    else if (a == "--strict-fsize") o.align_fsize = false;
    else if (a == "--strict-fpsr") o.align_unimp_fpsr = false;
    else if (a == "--maxdiv") o.maxdiv = atoi(next().c_str());
    else if (a == "--trace-from") o.trace_from = strtoull(next().c_str(), nullptr, 0);
    else if (a == "--dump-at") o.dump_at = strtoull(next().c_str(), nullptr, 0);
#ifdef RDVIRT_RTL
    else if (a == "--ram-waits") o.rtl.ram_waits = atoi(next().c_str());
    else if (a == "--io-waits") o.rtl.io_waits = atoi(next().c_str());
    else if (a == "--tbi") o.rtl.tbi = true;
    else if (a == "--tci") o.rtl.tci = true;
    else if (a == "--vcd") o.rtl.vcd = next();
    else if (a == "--vcd-from") o.rtl.vcd_from = strtoull(next().c_str(), nullptr, 0);
#endif
    else { usage(); return 2; }
  }
  if (o.kernel.empty() == o.bare.empty()) { usage(); return 2; }
#if defined(RDVIRT_RTL) && !RDVIRT_FPU
  if (o.cpu != "uae" && o.mc.fpu) {
    fprintf(stderr, "rd-virt: this RTL is an MC68LC040 (FPU=0): --no-fpu\n");
    return 2;
  }
#endif

  auto load = [&](Machine &m) {
    return o.bare.empty() ? m.load_linux(o.kernel, o.initrd, o.cmdline) : m.load_bare(o.bare);
  };

  if (o.cpu == "uae") {
    UaeCpu::init_library(o.mc.ram_mb << 20, o.dcache, o.mc.fpu);
    Machine m(o.mc, UaeCpu::library_ram());
    if (!load(m)) return 2;
    UaeCpu cpu(&m);
    return run_solo(o, cpu, m);
  }
#ifdef RDVIRT_RTL
  if (o.cpu == "rtl") {
    Machine m(o.mc);
    if (!load(m)) return 2;
    RtlCpu cpu(&m, o.rtl);
    return run_solo(o, cpu, m);
  }
  if (o.cpu == "lockstep") {
    MachineConfig mcu = o.mc;
    mcu.echo = false;
    mcu.console_log.clear();
    UaeCpu::init_library(o.mc.ram_mb << 20, o.dcache, o.mc.fpu);
    Machine mu(mcu, UaeCpu::library_ram());
    Machine mr(o.mc);
    if (!load(mr) || !load(mu)) return 2;
    RtlCpu rtl(&mr, o.rtl);
    UaeCpu uae(&mu);
    return run_lockstep(o, rtl, mr, uae, mu);
  }
#endif
  usage();
  return 2;
}
