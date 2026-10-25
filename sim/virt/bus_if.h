// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// rd-virt and rd-qvirt -- what the RTL socket's bus agent (cpu_rtl.cpp) needs
// of a machine: the RAM, which addresses are the devices', the devices'
// registers, the interrupt level, and the bus record. rd-virt's Machine
// (machine.h) implements it with its own devices; rd-qvirt's QemuMachine
// (sim/qvirt/qemu_machine.h) with QEMU's, over qtest. Both have the map of
// the m68k `virt` board:
//
//   $00000000  RAM (ram_size)
//   $FF000000  the devices, to $FF01FFFF
//
// and anything else is a hole, answered with a bus error.
#ifndef RDVIRT_BUS_IF_H
#define RDVIRT_BUS_IF_H

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <vector>

#include "cpu_if.h"

class BusIf {
 public:
  virtual ~BusIf() {}

  enum class Region { Ram, Io, Hole };
  Region classify(uint32_t pa) const {
    if (pa < ram_size) return Region::Ram;
    if (pa >= 0xFF000000u && pa < 0xFF020000u) return Region::Io;
    return Region::Hole;
  }
  // A device access: true means a bus error. size 1, 2 or 4, at any address
  // inside one long word.
  virtual bool io_read(uint32_t pa, int size, uint32_t &v) = 0;
  virtual bool io_write(uint32_t pa, int size, uint32_t v) = 0;

  // The interrupt priority level the devices present (0: none).
  virtual int ipl() const = 0;

  // DMA. A device that reads or writes memory itself does it as an alternate
  // bus master whose transfers the processor snoops (UM 4.4, 7.9), as a board
  // with a copyback-cached MC68040 must have it. When the processor writes a
  // register that makes a device move data, dma_hold() says so: the agent
  // answers that write with a retry, takes the bus (BG), and runs snooped
  // reads of what dma_reads() names -- asked again until it names nothing,
  // so that what the device reads can name more to read -- so that the
  // processor sources what its cache holds dirty; then the write is made;
  // then snooped writes of what dma_writes() names, the device's data from
  // RAM, so that the processor's caches drop or take it. The bus is given
  // back, and the processor's retried write is answered without being made
  // again. rd-virt's own devices move no data: none of this happens there.
  struct Dma { uint32_t a, n; };
  virtual bool dma_hold(uint32_t, int, uint32_t) { return false; }
  virtual std::vector<Dma> dma_reads() { return {}; }
  virtual std::vector<Dma> dma_writes() { return {}; }

  // The bus record: the last 4,096 transfers. RDVIRT_WATCH=<hex address>
  // prints every write to it.
  void log(const BusRec &r) {
    ring.push_back(r);
    if (ring.size() > 4096) ring.pop_front();
    static long watch = getenv("RDVIRT_WATCH") ? long(strtoul(getenv("RDVIRT_WATCH"), nullptr, 16)) : -1;
    if (r.write && watch >= 0 && uint32_t(watch) - r.addr < r.size)
      fprintf(stderr, "log %p: %c W %08x %d %08x step %llu berr %d\n", (void *)this, r.kind,
              r.addr, r.size, r.data, (unsigned long long)r.step, r.berr);
    // RDVIRT_WATCH_LINE=<hex address>: every transfer in its 16-byte line.
    static long wline = getenv("RDVIRT_WATCH_LINE") ? long(strtoul(getenv("RDVIRT_WATCH_LINE"), nullptr, 16) & ~15ul) : -1;
    if (wline >= 0 && (r.addr & ~15u) == uint32_t(wline))
      fprintf(stderr, "line: %c %s %08x %d %08x step %llu%s\n", r.kind, r.write ? "W" : "R",
              r.addr, r.size, r.data, (unsigned long long)r.step, r.berr ? " BERR" : "");
  }
  void dump_ring(FILE *f, size_t n = 4096) const {
    size_t s = ring.size() > n ? ring.size() - n : 0;
    for (size_t i = s; i < ring.size(); i++) {
      const BusRec &r = ring[i];
      fprintf(f, "%10llu %c %s tm%d %08x %d %08x%s\n", (unsigned long long)r.step,
              r.kind, r.write ? "W" : "R", r.tm, r.addr, r.size, r.data,
              r.berr ? " BERR" : "");
    }
  }
  std::deque<BusRec> ring;

  uint8_t *ram = nullptr;
  uint32_t ram_size = 0;
};

#endif
