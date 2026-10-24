// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// rd-virt -- the machine: the Linux and QEMU m68k `virt` board (RD68031's), at the
// addresses doc/oracles.md records ("rd-virt"), with a deterministic clock.
//
//   $00000000  RAM (ram_mb)
//   $FF000000  goldfish-pic x6, $1000 apart, driving levels 1-6, autovectored
//   $FF006000  goldfish-rtc, the scheduler's timer (Linux IRQ 168)
//   $FF007000  goldfish-rtc, the wall clock (IRQ 169)
//   $FF008000  goldfish-tty (IRQ 39)
//   $FF009000  virt-ctrl (IRQ 8): CMD 1 reset, 2 halt (power off), 3 panic
//   $FF010000  128 virtio-mmio transports, $200 apart, legacy (version 1),
//              every one empty (device ID 0): the initramfs needs no disk
//
// Anything else is a hole and answers with a bus error.
//
// TIME is never the host's. The machine is told the time at every instruction
// boundary -- steps x ns_per_step, plus whatever was skipped while STOP held
// the processor -- and every device derives what it reports from that, so two
// runs, or the two sides of a lockstep, see the same clock at the same
// instruction.
#ifndef RDVIRT_MACHINE_H
#define RDVIRT_MACHINE_H

#include <cstdint>
#include <cstdio>
#include <deque>
#include <string>
#include <vector>

#include "cpu_if.h"

struct MachineConfig {
  uint32_t    ram_mb       = 64;
  bool        fpu          = true;        // the bootinfo's FPU: 68040, or none (LC040)
  uint64_t    ns_per_step  = 20;          // 50 M steps per virtual second
  uint64_t    epoch_ns     = 1798761600ull * 1000000000ull;  // 2027-01-01
  bool        echo         = true;        // console to stdout
  std::string console_log;                // ... and to this file
};

class Machine {
 public:
  explicit Machine(const MachineConfig &cfg, uint8_t *ram = nullptr);
  ~Machine();

  // Loading. A Linux kernel: the ELF physical = virtual, the bootinfo at
  // (_end + 1) & ~1, the initrd page-aligned at the top of RAM, and the reset
  // vectors at 0 (the ELF header's page, which nothing uses) pointing at the
  // entry. A bare program: an ELF linked at 0 with its own vectors.
  bool load_linux(const std::string &kernel, const std::string &initrd,
                  const std::string &cmdline);
  bool load_bare(const std::string &elf);

  // The bus.
  enum class Region { Ram, Io, Hole };
  Region classify(uint32_t pa) const {
    if (pa < ram_size) return Region::Ram;
    if (pa >= 0xFF000000u && pa < 0xFF020000u) return Region::Io;
    return Region::Hole;
  }
  // A device access: true means a bus error. size 1, 2 or 4, at any address
  // inside one long word; the devices are long-word registers.
  bool io_read(uint32_t pa, int size, uint32_t &v);
  bool io_write(uint32_t pa, int size, uint32_t v);

  // The interrupt priority level the six PICs present.
  int ipl() const;

  // The clock.
  void     set_time(uint64_t ns);
  uint64_t now() const { return now_ns; }
  uint64_t next_event() const;   // UINT64_MAX when nothing is armed

  // The console.
  void tty_input(const std::string &s);
  const std::string &console() const { return cons; }

  // virt-ctrl.
  bool powered_off = false;
  bool panicked    = false;
  bool reset_req   = false;

  // The bus record: the last 4,096 transfers.
  void log(const BusRec &r);
  std::deque<BusRec> ring;
  void dump_ring(FILE *f, size_t n = 4096) const;

  uint8_t *ram;
  uint32_t ram_size;

 private:
  struct Pic { uint32_t pending = 0, enabled = 0; };
  struct Rtc {
    uint64_t alarm_next = 0;
    uint32_t time_high = 0, irq_enabled = 0, irq_pending = 0, alarm_running = 0;
  };
  MachineConfig cfg;
  bool own_ram;
  uint64_t now_ns = 0;
  Pic pic[6];
  Rtc rtc[2];
  // tty
  std::deque<uint8_t> rx;
  uint32_t tty_ptr = 0, tty_len = 0;
  bool tty_int = false;
  std::string cons;
  FILE *cons_log = nullptr;

  void set_line(int linux_irq, bool level);
  void rtc_update(int i);
  uint64_t rtc_count() const { return cfg.epoch_ns + now_ns; }
  void rtc_check(int i);
  void tty_update();
  void putc_console(uint8_t c);
  uint32_t reg_read(uint32_t off);
  void reg_write(uint32_t off, uint32_t v);

  bool load_elf(const std::string &path, uint32_t &entry, uint32_t &end);
};

#endif
