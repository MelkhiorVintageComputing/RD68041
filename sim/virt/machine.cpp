// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// rd-virt -- the machine. machine.h has the map.
//
// The devices are written from their documented register interfaces (the
// goldfish devices' and virt-ctrl's, as the Linux drivers in
// arch/m68k/virt/ and drivers/ use them), not from any processor oracle.

#include "machine.h"

#include <cstdlib>
#include <cstring>

namespace {

void be32(uint8_t *p, uint32_t v) {
  p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}
void be16(uint8_t *p, uint16_t v) { p[0] = v >> 8; p[1] = v; }
uint32_t rd32(const uint8_t *p) {
  return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
}
uint16_t rd16(const uint8_t *p) { return uint16_t((p[0] << 8) | p[1]); }

// Linux's numbering: IRQ n is PIC (n-8)/32, input (n-8)%32, and PIC i drives
// level i+1 (QEMU's PIC_IRQ, arch/m68k/virt/ints.c).
constexpr int IRQ_CTRL = 8, IRQ_TTY = 39, IRQ_VIRTIO = 40, IRQ_RTC = 168;

// bootinfo (arch/m68k/include/uapi/asm/bootinfo.h, bootinfo-virt.h)
constexpr uint16_t BI_LAST = 0, BI_MACHTYPE = 1, BI_CPUTYPE = 2, BI_FPUTYPE = 3, BI_MMUTYPE = 4,
                   BI_MEMCHUNK = 5, BI_RAMDISK = 6, BI_COMMAND_LINE = 7,
                   BI_RNG_SEED = 8, BI_VIRT_QEMU_VERSION = 0x8000,
                   BI_VIRT_GF_PIC_BASE = 0x8001, BI_VIRT_GF_RTC_BASE = 0x8002,
                   BI_VIRT_GF_TTY_BASE = 0x8003, BI_VIRT_VIRTIO_BASE = 0x8004,
                   BI_VIRT_CTRL_BASE = 0x8005;
constexpr uint32_t MACH_VIRT = 14, CPU_68040 = 4, MMU_68040 = 4, FPU_68040 = 4;

}  // namespace

Machine::Machine(const MachineConfig &c, uint8_t *ext_ram) : cfg(c) {
  ram_size = cfg.ram_mb << 20;
  own_ram = (ext_ram == nullptr);
  ram = own_ram ? static_cast<uint8_t *>(calloc(1, ram_size)) : ext_ram;
  if (!cfg.console_log.empty()) cons_log = fopen(cfg.console_log.c_str(), "w");
}

Machine::~Machine() {
  if (own_ram) free(ram);
  if (cons_log) fclose(cons_log);
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------
bool Machine::load_elf(const std::string &path, uint32_t &entry, uint32_t &end) {
  FILE *f = fopen(path.c_str(), "rb");
  if (!f) { fprintf(stderr, "rd-virt: cannot open %s\n", path.c_str()); return false; }
  std::vector<uint8_t> b;
  uint8_t buf[65536];
  size_t n;
  while ((n = fread(buf, 1, sizeof buf, f)) > 0) b.insert(b.end(), buf, buf + n);
  fclose(f);
  if (b.size() < 52 || memcmp(b.data(), "\177ELF", 4) || b[4] != 1 || b[5] != 2) {
    fprintf(stderr, "rd-virt: %s is not a 32-bit big-endian ELF\n", path.c_str());
    return false;
  }
  entry = rd32(&b[24]);
  uint32_t phoff = rd32(&b[28]);
  uint16_t phentsize = rd16(&b[42]), phnum = rd16(&b[44]);
  end = 0;
  for (int i = 0; i < phnum; i++) {
    const uint8_t *ph = &b[phoff + i * phentsize];
    if (rd32(ph) != 1) continue;  // PT_LOAD
    uint32_t off = rd32(ph + 4), pa = rd32(ph + 12), fsz = rd32(ph + 16), msz = rd32(ph + 20);
    if ((uint64_t)pa + msz > ram_size) {
      fprintf(stderr, "rd-virt: %s does not fit in RAM\n", path.c_str());
      return false;
    }
    memcpy(ram + pa, &b[off], fsz);
    memset(ram + pa + fsz, 0, msz - fsz);
    if (pa + msz > end) end = pa + msz;
  }
  return true;
}

bool Machine::load_bare(const std::string &elf) {
  uint32_t entry, end;
  return load_elf(elf, entry, end);
}

bool Machine::load_linux(const std::string &kernel, const std::string &initrd,
                         const std::string &cmdline) {
  uint32_t entry, end;
  if (!load_elf(kernel, entry, end)) return false;
  // The reset vectors. The kernel loads its own stack pointer before it uses
  // one (head.S), so the reset SSP only has to be somewhere harmless: just
  // below kernel_pg_dir at $1000, in the page that holds the ELF header.
  be32(ram + 0, 0x00001000u);
  be32(ram + 4, entry);

  uint32_t rd_base = 0, rd_size = 0;
  if (!initrd.empty()) {
    FILE *f = fopen(initrd.c_str(), "rb");
    if (!f) { fprintf(stderr, "rd-virt: cannot open %s\n", initrd.c_str()); return false; }
    fseek(f, 0, SEEK_END);
    rd_size = ftell(f);
    fseek(f, 0, SEEK_SET);
    rd_base = (ram_size - rd_size) & ~0xFFFu;
    if (fread(ram + rd_base, 1, rd_size, f) != rd_size) { fclose(f); return false; }
    fclose(f);
  }

  // The bootinfo, in the order QEMU's virt machine writes it.
  uint8_t *p = ram + ((end + 1) & ~1u);
  auto rec1 = [&](uint16_t tag, uint32_t v) {
    be16(p, tag); be16(p + 2, 8); be32(p + 4, v); p += 8;
  };
  auto rec2 = [&](uint16_t tag, uint32_t v1, uint32_t v2) {
    be16(p, tag); be16(p + 2, 12); be32(p + 4, v1); be32(p + 8, v2); p += 12;
  };
  rec1(BI_MACHTYPE, MACH_VIRT);
  rec1(BI_MMUTYPE, MMU_68040);
  rec1(BI_CPUTYPE, CPU_68040);
  // The FPU, said explicitly either way. Without the record head.S's
  // get_bi_record leaves its pointer on the terminator's size field and
  // m68k_fputype reads as $0004xxxx -- an FPU (RD68031's m13-b3). The
  // MC68LC040 has none (0), and the kernel's FPU emulation takes its F-line
  // exceptions.
  rec1(BI_FPUTYPE, cfg.fpu ? FPU_68040 : 0);
  rec2(BI_MEMCHUNK, 0, ram_size);
  rec1(BI_VIRT_QEMU_VERSION, 0x0B010200u);   // reported as 11.1.2: cosmetic
  rec2(BI_VIRT_GF_PIC_BASE, 0xFF000000u, 1);
  rec2(BI_VIRT_GF_RTC_BASE, 0xFF006000u, IRQ_RTC);
  rec2(BI_VIRT_GF_TTY_BASE, 0xFF008000u, IRQ_TTY);
  rec2(BI_VIRT_CTRL_BASE, 0xFF009000u, IRQ_CTRL);
  rec2(BI_VIRT_VIRTIO_BASE, 0xFF010000u, IRQ_VIRTIO);
  if (!cmdline.empty()) {
    uint16_t sz = (4 + cmdline.size() + 1 + 3) & ~3u;
    be16(p, BI_COMMAND_LINE); be16(p + 2, sz);
    memset(p + 4, 0, sz - 4);
    memcpy(p + 4, cmdline.data(), cmdline.size());
    p += sz;
  }
  // A fixed seed: the run is deterministic, randomness included.
  {
    uint16_t len = 32, sz = (4 + len + 2 + 3) & ~3u;
    be16(p, BI_RNG_SEED); be16(p + 2, sz); be16(p + 4, len);
    for (int i = 0; i < len; i++) p[6 + i] = uint8_t(0x5A ^ (i * 37));
    p += sz;
  }
  if (rd_size) rec2(BI_RAMDISK, rd_base, rd_size);
  be16(p, BI_LAST); be16(p + 2, 4);
  return true;
}

// ---------------------------------------------------------------------------
// Interrupts
// ---------------------------------------------------------------------------
void Machine::set_line(int irq, bool level) {
  int n = irq - 8;
  uint32_t bit = 1u << (n % 32);
  Pic &pc = pic[n / 32];
  if (level) pc.pending |= bit;
  else       pc.pending &= ~bit;
}

int Machine::ipl() const {
  for (int i = 5; i >= 0; i--)
    if (pic[i].pending & pic[i].enabled) return i + 1;
  return 0;
}

// ---------------------------------------------------------------------------
// The clock and the two goldfish-rtc
// ---------------------------------------------------------------------------
void Machine::rtc_update(int i) {
  set_line(IRQ_RTC + i, rtc[i].irq_pending && rtc[i].irq_enabled);
}

void Machine::rtc_check(int i) {
  Rtc &r = rtc[i];
  if (r.alarm_running && rtc_count() >= r.alarm_next) {
    r.alarm_running = 0;
    r.irq_pending = 1;
    rtc_update(i);
  }
}

void Machine::set_time(uint64_t ns) {
  now_ns = ns;
  rtc_check(0);
  rtc_check(1);
}

uint64_t Machine::next_event() const {
  uint64_t t = UINT64_MAX;
  for (const Rtc &r : rtc)
    if (r.alarm_running) {
      uint64_t at = r.alarm_next > cfg.epoch_ns ? r.alarm_next - cfg.epoch_ns : 0;
      if (at < t) t = at;
    }
  return t;
}

// ---------------------------------------------------------------------------
// The tty
// ---------------------------------------------------------------------------
void Machine::putc_console(uint8_t c) {
  cons.push_back(char(c));
  if (cfg.echo) { fputc(c, stdout); if (c == '\n') fflush(stdout); }
  if (cons_log) { fputc(c, cons_log); if (c == '\n') fflush(cons_log); }
}

void Machine::tty_update() { set_line(IRQ_TTY, tty_int && !rx.empty()); }

void Machine::tty_input(const std::string &s) {
  for (char c : s) rx.push_back(uint8_t(c));
  tty_update();
}

// ---------------------------------------------------------------------------
// Register files
// ---------------------------------------------------------------------------
uint32_t Machine::reg_read(uint32_t off) {
  if (off < 0x6000) {                       // goldfish-pic
    const Pic &pc = pic[off >> 12];
    switch (off & 0xFFF) {
      case 0x00: return __builtin_popcount(pc.pending & pc.enabled);
      case 0x04: return pc.pending & pc.enabled;
    }
    return 0;
  }
  if (off < 0x8000) {                       // goldfish-rtc
    Rtc &r = rtc[(off - 0x6000) >> 12];
    switch (off & 0xFFF) {
      case 0x00: { uint64_t c = rtc_count(); r.time_high = c >> 32; return uint32_t(c); }
      case 0x04: return r.time_high;
      case 0x08: return uint32_t(r.alarm_next);
      case 0x0C: return uint32_t(r.alarm_next >> 32);
      case 0x10: return r.irq_enabled;
      case 0x18: return r.alarm_running;
    }
    return 0;
  }
  if (off < 0x9000) {                       // goldfish-tty
    switch (off & 0xFFF) {
      case 0x04: return uint32_t(rx.size());
      case 0x20: return 1;                  // version 1: physical DMA pointers
    }
    return 0;
  }
  if (off < 0xA000) {                       // virt-ctrl
    return (off & 0xFFF) == 0x00 ? 1 : 0;   // FEATURES: power control
  }
  if (off >= 0x10000) {                     // virtio-mmio, every one empty
    // Little-endian registers (the virtio-mmio specification): the driver's
    // readl() swaps them, so on this big-endian bus they read byte-reversed.
    switch (off & 0x1FF) {
      case 0x000: return __builtin_bswap32(0x74726976);  // "virt"
      case 0x004: return __builtin_bswap32(1);           // legacy
      case 0x008: return 0;                              // no device
      case 0x00C: return __builtin_bswap32(0x554D4551);  // vendor
    }
    return 0;
  }
  return 0;
}

void Machine::reg_write(uint32_t off, uint32_t v) {
  if (off < 0x6000) {
    Pic &pc = pic[off >> 12];
    switch (off & 0xFFF) {
      case 0x08: pc.enabled = 0; pc.pending = 0; break;
      case 0x0C: pc.enabled &= ~v; break;
      case 0x10: pc.enabled |= v; break;
    }
    return;
  }
  if (off < 0x8000) {
    int i = (off - 0x6000) >> 12;
    Rtc &r = rtc[i];
    switch (off & 0xFFF) {
      case 0x08:
        r.alarm_next = (r.alarm_next & 0xFFFFFFFF00000000ull) | v;
        if (r.alarm_next <= rtc_count()) {
          r.alarm_running = 0;
          r.irq_pending = 1;
          rtc_update(i);
        } else {
          r.alarm_running = 1;
        }
        break;
      case 0x0C: r.alarm_next = (r.alarm_next & 0xFFFFFFFFull) | (uint64_t(v) << 32); break;
      case 0x10: r.irq_enabled = v & 1; rtc_update(i); break;
      case 0x14: r.alarm_running = 0; break;
      case 0x1C: r.irq_pending = 0; rtc_update(i); break;
      // Setting the time (0x00, 0x04) is not supported: the wall clock is
      // the deterministic one.
    }
    return;
  }
  if (off < 0x9000) {
    switch (off & 0xFFF) {
      case 0x00: putc_console(uint8_t(v)); break;
      case 0x08:
        switch (v) {
          case 0: tty_int = false; break;
          case 1: tty_int = true; break;
          case 2:  // WRITE_BUFFER: DMA from RAM
            for (uint32_t k = 0; k < tty_len; k++)
              if (tty_ptr + k < ram_size) putc_console(ram[tty_ptr + k]);
            break;
          case 3:  // READ_BUFFER: DMA into RAM
            for (uint32_t k = 0; k < tty_len && !rx.empty(); k++) {
              if (tty_ptr + k < ram_size) ram[tty_ptr + k] = rx.front();
              rx.pop_front();
            }
            break;
        }
        tty_update();
        break;
      case 0x10: tty_ptr = v; break;
      case 0x14: tty_len = v; break;
    }
    return;
  }
  if (off < 0xA000) {
    if ((off & 0xFFF) == 0x04) {
      if (v == 1) reset_req = true;
      if (v == 2) powered_off = true;
      if (v == 3) { panicked = true; powered_off = true; }
    }
    return;
  }
}

// A sub-long access reads the whole register and takes its bytes, or writes
// its bytes in place of the register's low-order ones: every driver here uses
// long words, and this keeps a stray byte access harmless and repeatable.
bool Machine::io_read(uint32_t pa, int size, uint32_t &v) {
  if (classify(pa) != Region::Io) return true;
  uint32_t off = pa - 0xFF000000u;
  uint32_t r = reg_read(off & ~3u);
  int sh = 8 * (4 - int(off & 3) - size);
  v = sh >= 0 ? (r >> sh) & (size == 4 ? 0xFFFFFFFFu : ((1u << (8 * size)) - 1)) : r;
  return false;
}

bool Machine::io_write(uint32_t pa, int size, uint32_t v) {
  if (classify(pa) != Region::Io) return true;
  uint32_t off = pa - 0xFF000000u;
  (void)size;
  reg_write(off & ~3u, v);
  return false;
}
