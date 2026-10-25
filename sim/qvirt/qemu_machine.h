// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// rd-qvirt -- QEMU's m68k `virt` machine with the core as its processor
// (doc/qvirt.md). QEMU 11.1.2 runs unmodified as a separate process, under
// its qtest accelerator, so that its own CPU never runs; this machine is its
// devices, seen through qtest's interface:
//
//   - the RAM is QEMU's, shared: a memory-backend-file both processes map, so
//     the core's RAM transfers go straight to it and QEMU's DMA (virtio-blk,
//     the goldfish tty's buffers) lands in the same memory;
//   - a device transfer is a qtest readl, or writeb/w/l;
//   - the interrupt controller's seven inputs (m68k-irq-controller) are
//     intercepted (irq_intercept_in): the level is the highest raised;
//   - time is the harness's: QEMU's virtual clock moves only by clock_step,
//     to the core's time (clocks x ns_per_clock, plus what STOP skipped)
//     before every device access, and at least every quantum.
//
// Two things QEMU does asynchronously are made to settle at a fixed virtual
// time, so that a run is the same from one execution to the next:
//   - a virtio queue notification: the harness waits until the device has
//     used every buffer the driver made available (the rings, in the shared
//     RAM, at the addresses the driver gave the transport);
//   - console input: bytes go to the console socket only while the goldfish
//     tty's FIFO has room, and the harness waits until BYTES_READY counts
//     them.
#ifndef RDQVIRT_QEMU_MACHINE_H
#define RDQVIRT_QEMU_MACHINE_H

#include <sys/types.h>

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "bus_if.h"

struct QemuConfig {
  std::string qemu;                     // qemu-system-m68k
  std::string dir;                      // the run's directory: sockets, logs
  uint32_t    ram_mb = 128;
  std::string kernel, initrd, cmdline;  // -kernel, -initrd, -append
  std::string disk;                     // a raw disk image, virtio-blk (snapshot=on)
  bool        fpu = true;               // false: the bootinfo says no FPU (MC68LC040)
  std::string rtc_base = "2026-10-01T00:00:00";  // after NetBSD 11.0's files' dates
  uint64_t    quantum_ns = 50000;       // QEMU's clock trails the core's by at most this
  bool        echo = true;              // console to stdout
  std::string console_log;              // ... and to this file
};

class QemuMachine : public BusIf {
 public:
  explicit QemuMachine(const QemuConfig &cfg);
  ~QemuMachine() override;

  // Start QEMU, connect to it, map its RAM, fix the bootinfo (a fixed RNG
  // seed; no FPU if !fpu). False, with a message, if anything fails.
  bool start();
  // The state QEMU's virt machine starts its CPU in (hw/m68k/virt.c,
  // main_cpu_reset): PC the kernel ELF's entry, SSP 0 -- or, for a bare
  // program linked at 0, its own reset SSP.
  uint32_t entry() const { return entry_; }
  uint32_t ssp() const { return ssp_; }

  bool io_read(uint32_t pa, int size, uint32_t &v) override;
  bool io_write(uint32_t pa, int size, uint32_t v) override;
  int ipl() const override;

  // DMA (bus_if.h): goldfish-tty's WRITE_BUFFER (it reads the buffer) and
  // READ_BUFFER (it writes it), and a virtio queue's notification (it reads
  // the rings and the driver's buffers, writes the used ring and the
  // device-writable buffers).
  bool dma_hold(uint32_t pa, int size, uint32_t v) override;
  std::vector<Dma> dma_reads() override;
  std::vector<Dma> dma_writes() override;

  // The core's time now, in virtual ns: set by the harness.
  std::function<uint64_t()> now;
  // QEMU's clock to the core's, if it trails by a quantum or more (exact=false)
  // or at all (exact=true).
  void sync(bool exact);
  // STOP: QEMU's clock to its next timer deadline. The new time, or
  // UINT64_MAX when nothing is armed.
  uint64_t step_to_deadline();
  uint64_t qemu_ns() const { return qns_; }

  // The console.
  void tty_input(const std::string &s) { pending_ += s; }
  bool input_pending() const { return !pending_.empty(); }
  void pump_input();              // as much of the pending input as the FIFO takes
  const std::string &console() const { return cons_; }

  // virt-ctrl, as the core wrote it; or QEMU went away.
  bool powered_off = false, panicked = false, reset_req = false, gone = false;

  // qtest round trips, for the report.
  uint64_t round_trips = 0, settles = 0;

 private:
  struct Queue {
    uint64_t desc = 0, avail = 0, used = 0;   // modern (version 2) transports
    uint32_t num = 0, pfn = 0, align = 4096;  // legacy (version 1)
    uint16_t seen = 0;                        // the available index walked to
  };
  // The DMA command being made: 1 the tty's (v its command), 2 a queue's.
  struct DmaCmd {
    int kind = 0, slot = 0, phase = 0;
    uint32_t v = 0, queue = 0;
    std::vector<Dma> rd, wr, tables;
  };
  DmaCmd dc_;
  uint32_t tty_ptr_ = 0, tty_len_ = 0;
  struct Transport {
    int version = 0;              // 0: not read yet
    uint32_t sel = 0, page = 4096;
    Queue q[8];
  };
  QemuConfig cfg_;
  pid_t pid_ = -1;
  int qt_ = -1, con_ = -1, qt_listen_ = -1, con_listen_ = -1;
  std::string ram_path_;
  uint32_t entry_ = 0, ssp_ = 0;
  uint64_t qns_ = 0;
  uint32_t irq_ = 0;              // the raised irqc inputs: bit i is level i+1
  std::string rx_;                // qtest bytes not yet a line
  std::string cons_, pending_;
  FILE *cons_log_ = nullptr;
  Transport vt_[128];
  // A queue's rings (version 1's laid out from QueuePFN), false if unset.
  bool rings(const Transport &t, const Queue &q, uint64_t &desc, uint64_t &avail,
             uint64_t &used) const;
  uint16_t r16(uint64_t a, bool le) const;
  uint32_t r32(uint64_t a, bool le) const;
  void walk_chains(bool tables_only);

  bool send(const std::string &cmd, std::string &reply);
  bool cmd_ok(const std::string &cmd, uint64_t *val = nullptr);
  void drain_console();
  void settle_virtio(int slot, uint32_t queue);
  void virtio_write(uint32_t off, uint32_t v);
  bool load_elf_info(const std::string &path, uint32_t &end, bool &covers0);
  bool fix_bootinfo(uint32_t end);
};

#endif
