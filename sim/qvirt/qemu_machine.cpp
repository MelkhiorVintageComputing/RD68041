// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// rd-qvirt -- the machine. qemu_machine.h says what it is.
//
// Written against QEMU's interfaces, as harness code is (CLAUDE.md): the
// qtest protocol (system/qtest.c's command list), the virt board's map and
// wiring (hw/m68k/virt.c), and the device registers the guests program
// (goldfish-tty, virt-ctrl, virtio-mmio). Nothing of QEMU's m68k CPU.

#include "qemu_machine.h"

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstring>
#include <thread>

namespace {

uint32_t rd32(const uint8_t *p) {
  return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
}
uint16_t rd16(const uint8_t *p) { return uint16_t((p[0] << 8) | p[1]); }
void be32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

// The virt board (hw/m68k/virt.c).
constexpr uint32_t TTY = 0xFF008000u, CTRL = 0xFF009000u, VIRTIO = 0xFF010000u;
// The m68k-irq-controller, the second device the board creates (after the
// CPU): checked against QEMU 11.1.2 by QMP's qom-get (doc/qvirt.md).
const char *const IRQC_PATH = "/machine/unattached/device[1]";
// goldfish-tty's receive FIFO (GOLFISH_TTY_BUFFER_SIZE)
constexpr uint32_t TTY_FIFO = 128;
// bootinfo tags (asm-m68k/bootinfo.h)
constexpr uint16_t BI_LAST = 0, BI_MACHTYPE = 1, BI_FPUTYPE = 3, BI_RNG_SEED = 8;
constexpr uint32_t MACH_VIRT = 14;

int listen_unix(const std::string &path) {
  unlink(path.c_str());
  int s = socket(AF_UNIX, SOCK_STREAM, 0);
  if (s < 0) return -1;
  sockaddr_un a{};
  a.sun_family = AF_UNIX;
  if (path.size() >= sizeof a.sun_path) { close(s); return -1; }
  strcpy(a.sun_path, path.c_str());
  if (bind(s, (sockaddr *)&a, sizeof a) < 0 || listen(s, 1) < 0) { close(s); return -1; }
  return s;
}

int accept_within(int s, int ms) {
  pollfd p{s, POLLIN, 0};
  if (poll(&p, 1, ms) <= 0) return -1;
  return accept(s, nullptr, nullptr);
}

}  // namespace

QemuMachine::QemuMachine(const QemuConfig &c) : cfg_(c) {
  ram_size = cfg_.ram_mb << 20;
  if (!cfg_.console_log.empty()) cons_log_ = fopen(cfg_.console_log.c_str(), "w");
}

QemuMachine::~QemuMachine() {
  if (qt_ >= 0) close(qt_);
  if (con_ >= 0) close(con_);
  if (qt_listen_ >= 0) close(qt_listen_);
  if (con_listen_ >= 0) close(con_listen_);
  if (pid_ > 0) {
    int st;
    if (waitpid(pid_, &st, WNOHANG) == 0) {
      kill(pid_, SIGTERM);
      waitpid(pid_, &st, 0);
    }
  }
  if (ram) munmap(ram, ram_size);
  if (!ram_path_.empty()) unlink(ram_path_.c_str());
  if (cons_log_) fclose(cons_log_);
}

// ---------------------------------------------------------------------------
// Starting
// ---------------------------------------------------------------------------
bool QemuMachine::load_elf_info(const std::string &path, uint32_t &end, bool &covers0) {
  FILE *f = fopen(path.c_str(), "rb");
  if (!f) { fprintf(stderr, "rd-qvirt: cannot open %s\n", path.c_str()); return false; }
  std::vector<uint8_t> b;
  uint8_t buf[65536];
  size_t n;
  while ((n = fread(buf, 1, sizeof buf, f)) > 0) b.insert(b.end(), buf, buf + n);
  fclose(f);
  if (b.size() < 52 || memcmp(b.data(), "\177ELF", 4) || b[4] != 1 || b[5] != 2) {
    fprintf(stderr, "rd-qvirt: %s is not a 32-bit big-endian ELF\n", path.c_str());
    return false;
  }
  entry_ = rd32(&b[24]);
  uint32_t phoff = rd32(&b[28]);
  uint16_t phentsize = rd16(&b[42]), phnum = rd16(&b[44]);
  end = 0;
  covers0 = false;
  for (int i = 0; i < phnum; i++) {
    const uint8_t *ph = &b[phoff + i * phentsize];
    if (rd32(ph) != 1) continue;  // PT_LOAD
    uint32_t pa = rd32(ph + 12), msz = rd32(ph + 20);
    if (pa + msz > end) end = pa + msz;
    if (pa < 8 && msz) covers0 = true;
  }
  return true;
}

// QEMU writes the bootinfo at (high + 1) & ~1, high the kernel's end
// (hw/m68k/virt.c), with a random RNG seed it draws again at every reset. The
// seed is made fixed -- rd-virt's -- so that the guest is the same from one
// run to the next, and with !fpu the FPU record says none (the MC68LC040).
bool QemuMachine::fix_bootinfo(uint32_t end) {
  uint32_t base = (end + 1) & ~1u;
  auto is_start = [&](uint32_t a) {
    return a + 8 <= ram_size && rd16(ram + a) == BI_MACHTYPE && rd16(ram + a + 2) == 8 &&
           rd32(ram + a + 4) == MACH_VIRT;
  };
  if (!is_start(base)) {
    uint32_t a = base;
    for (; a < base + 0x10000 && !is_start(a); a += 2) {}
    if (!is_start(a)) { fprintf(stderr, "rd-qvirt: no bootinfo after the kernel\n"); return false; }
    base = a;
  }
  bool fpu_done = cfg_.fpu, seed_done = false;
  for (uint32_t a = base; a + 4 <= ram_size;) {
    uint16_t tag = rd16(ram + a), sz = rd16(ram + a + 2);
    if (tag == BI_LAST || sz < 4) break;
    if (tag == BI_FPUTYPE && !cfg_.fpu) { be32(ram + a + 4, 0); fpu_done = true; }
    if (tag == BI_RNG_SEED) {
      uint16_t len = rd16(ram + a + 4);
      for (int i = 0; i < len && 6u + i < sz; i++) ram[a + 6 + i] = uint8_t(0x5A ^ (i * 37));
      seed_done = true;
    }
    a += sz;
  }
  if (!fpu_done) { fprintf(stderr, "rd-qvirt: the bootinfo has no FPU record to clear\n"); return false; }
  if (!seed_done) fprintf(stderr, "rd-qvirt: the bootinfo has no RNG seed (left as it is)\n");
  return true;
}

bool QemuMachine::start() {
  uint32_t end;
  bool covers0;
  if (!load_elf_info(cfg_.kernel, end, covers0)) return false;
  struct stat st;
  ram_path_ = (stat("/dev/shm", &st) == 0 && S_ISDIR(st.st_mode) ? std::string("/dev/shm")
                                                                    : cfg_.dir) +
              "/rdqvirt-" + std::to_string(getpid()) + ".ram";
  unlink(ram_path_.c_str());
  std::string qsock = cfg_.dir + "/qtest.sock", csock = cfg_.dir + "/con.sock";
  qt_listen_ = listen_unix(qsock);
  con_listen_ = listen_unix(csock);
  if (qt_listen_ < 0 || con_listen_ < 0) {
    fprintf(stderr, "rd-qvirt: cannot listen on %s and %s\n", qsock.c_str(), csock.c_str());
    return false;
  }
  std::string mb = std::to_string(cfg_.ram_mb) + "M";
  std::vector<std::string> a = {
      cfg_.qemu, "-M", "virt", "-accel", "qtest", "-qtest", "unix:" + qsock,
      "-qtest-log", "/dev/null", "-m", mb,
      "-object", "memory-backend-file,id=ram,size=" + mb + ",mem-path=" + ram_path_ + ",share=on",
      "-machine", "memory-backend=ram", "-kernel", cfg_.kernel,
      "-rtc", "base=" + cfg_.rtc_base + ",clock=vm",
      "-chardev", "socket,id=con,path=" + csock, "-serial", "chardev:con",
      "-nic", "none", "-display", "none", "-monitor", "none"};
  if (!cfg_.initrd.empty()) { a.push_back("-initrd"); a.push_back(cfg_.initrd); }
  if (!cfg_.cmdline.empty()) { a.push_back("-append"); a.push_back(cfg_.cmdline); }
  if (!cfg_.disk.empty()) {
    a.push_back("-drive");
    a.push_back("if=none,id=hd0,format=raw,snapshot=on,file=" + cfg_.disk);
    a.push_back("-device");
    a.push_back("virtio-blk-device,drive=hd0");
  }
  std::string cmdline;
  for (auto &s : a) cmdline += (cmdline.empty() ? "" : " ") + s;
  FILE *cl = fopen((cfg_.dir + "/qemu.cmdline").c_str(), "w");
  if (cl) { fprintf(cl, "%s\n", cmdline.c_str()); fclose(cl); }
  pid_ = fork();
  if (pid_ == 0) {
    // QEMU goes when the harness does, however it ends.
    prctl(PR_SET_PDEATHSIG, SIGKILL);
    int e = open((cfg_.dir + "/qemu.err").c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (e >= 0) { dup2(e, 2); dup2(e, 1); }
    std::vector<char *> argv;
    for (auto &s : a) argv.push_back(const_cast<char *>(s.c_str()));
    argv.push_back(nullptr);
    execv(argv[0], argv.data());
    _exit(127);
  }
  if (pid_ < 0) { fprintf(stderr, "rd-qvirt: fork: %s\n", strerror(errno)); return false; }
  con_ = accept_within(con_listen_, 30000);
  qt_ = accept_within(qt_listen_, 30000);
  if (con_ < 0 || qt_ < 0) {
    fprintf(stderr, "rd-qvirt: QEMU did not connect (%s/qemu.err)\n", cfg_.dir.c_str());
    return false;
  }
  fcntl(con_, F_SETFL, fcntl(con_, F_GETFL) | O_NONBLOCK);
  std::string r;
  if (!send(std::string("irq_intercept_in ") + IRQC_PATH, r) || r != "OK") {
    fprintf(stderr, "rd-qvirt: irq_intercept_in %s: %s\n", IRQC_PATH, r.c_str());
    return false;
  }
  int fd = open(ram_path_.c_str(), O_RDWR);
  if (fd < 0) { fprintf(stderr, "rd-qvirt: cannot open QEMU's RAM %s\n", ram_path_.c_str()); return false; }
  void *p = mmap(nullptr, ram_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  close(fd);
  // Both processes have it mapped now: the file goes when they do.
  unlink(ram_path_.c_str());
  ram_path_.clear();
  if (p == MAP_FAILED) { fprintf(stderr, "rd-qvirt: mmap: %s\n", strerror(errno)); return false; }
  ram = static_cast<uint8_t *>(p);
  ssp_ = covers0 ? rd32(ram) : 0;
  if (!fix_bootinfo(end) && !(covers0 && cfg_.fpu)) return false;
  // The clock's start: 0, or wherever QEMU's start-up left it.
  uint64_t t = 0;
  cmd_ok("clock_set 0", &t);
  qns_ = t;
  return true;
}

// ---------------------------------------------------------------------------
// qtest
// ---------------------------------------------------------------------------
// QVIRT_IOLOG=1: every device access, with the core's time, on stderr.
static const bool iolog = getenv("QVIRT_IOLOG") != nullptr;

// One command and its reply line; the IRQ lines that come before it are the
// interrupt controller's inputs changing.
bool QemuMachine::send(const std::string &cmd, std::string &reply) {
  if (gone) return false;
  std::string c = cmd + "\n";
  const char *p = c.data();
  size_t left = c.size();
  while (left) {
    ssize_t w = write(qt_, p, left);
    if (w <= 0) { if (errno == EINTR) continue; gone = true; return false; }
    p += w;
    left -= size_t(w);
  }
  round_trips++;
  for (;;) {
    size_t nl;
    while ((nl = rx_.find('\n')) != std::string::npos) {
      std::string l = rx_.substr(0, nl);
      rx_.erase(0, nl + 1);
      if (l.compare(0, 4, "IRQ ") == 0) {
        bool up = l.compare(4, 5, "raise") == 0;
        int n = atoi(l.c_str() + (up ? 10 : 10));
        if (n >= 0 && n < 7) irq_ = up ? (irq_ | (1u << n)) : (irq_ & ~(1u << n));
        continue;
      }
      reply = l;
      return true;
    }
    char b[4096];
    ssize_t n = read(qt_, b, sizeof b);
    if (n <= 0) {
      if (n < 0 && errno == EINTR) continue;
      gone = true;
      return false;
    }
    rx_.append(b, size_t(n));
  }
}

bool QemuMachine::cmd_ok(const std::string &cmd, uint64_t *val) {
  std::string r;
  if (!send(cmd, r)) return false;
  size_t sp = r.find(' ');
  if (val) *val = sp == std::string::npos ? 0 : strtoull(r.c_str() + sp + 1, nullptr, 0);
  return r.compare(0, 2, "OK") == 0;
}

int QemuMachine::ipl() const {
  for (int i = 6; i >= 0; i--)
    if (irq_ & (1u << i)) return i + 1;
  return 0;
}

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------
void QemuMachine::sync(bool exact) {
  uint64_t t = now ? now() : 0;
  if (t <= qns_ || (!exact && t - qns_ < cfg_.quantum_ns)) return;
  uint64_t got = 0;
  if (cmd_ok("clock_set " + std::to_string(t), &got)) qns_ = t;
  else if (got > qns_) qns_ = got;
  drain_console();
}

uint64_t QemuMachine::step_to_deadline() {
  sync(true);
  std::string r;
  if (!send("clock_step", r) || r.compare(0, 3, "OK ") != 0) return UINT64_MAX;
  qns_ = strtoull(r.c_str() + 3, nullptr, 0);
  drain_console();
  return qns_;
}

// ---------------------------------------------------------------------------
// The devices
// ---------------------------------------------------------------------------
void QemuMachine::drain_console() {
  char b[4096];
  for (;;) {
    ssize_t n = read(con_, b, sizeof b);
    if (n <= 0) return;
    for (ssize_t i = 0; i < n; i++) {
      cons_.push_back(b[i]);
      if (cfg_.echo) { fputc(b[i], stdout); if (b[i] == '\n') fflush(stdout); }
      if (cons_log_) { fputc(b[i], cons_log_); if (b[i] == '\n') fflush(cons_log_); }
    }
  }
}

bool QemuMachine::io_read(uint32_t pa, int size, uint32_t &v) {
  if (classify(pa) != Region::Io) return true;
  sync(true);
  char c[64];
  const char *op = size == 1 ? "readb" : size == 2 ? "readw" : "readl";
  snprintf(c, sizeof c, "%s 0x%x", op, pa);
  uint64_t x = 0;
  // QEMU gone (after a power-off) reads as 0, not as a bus error.
  if (!cmd_ok(c, &x)) { v = 0; return !gone; }
  v = uint32_t(x);
  if (iolog) fprintf(stderr, "io %llu R %08x/%d %08x\n", (unsigned long long)qns_, pa, size, v);
  uint32_t off = pa - VIRTIO;
  if (pa >= VIRTIO && (off & 0x1FF) == 0x004) vt_[off >> 9].version = int(__builtin_bswap32(v));
  return false;
}

bool QemuMachine::io_write(uint32_t pa, int size, uint32_t v) {
  if (classify(pa) != Region::Io) return true;
  sync(true);
  if (iolog) fprintf(stderr, "io %llu W %08x/%d %08x\n", (unsigned long long)qns_, pa, size, v);
  if ((pa & ~3u) == CTRL + 4) {
    if (v == 1) reset_req = true;
    if (v == 2) powered_off = true;
    if (v == 3) { panicked = true; powered_off = true; }
  }
  char c[64];
  const char *op = size == 1 ? "writeb" : size == 2 ? "writew" : "writel";
  snprintf(c, sizeof c, "%s 0x%x 0x%x", op, pa, v);
  if (!cmd_ok(c) && !gone) return true;
  if (pa >= VIRTIO && size == 4) virtio_write(pa - VIRTIO, v);
  if (pa == TTY + 0x10 && size == 4) tty_ptr_ = v;
  if (pa == TTY + 0x14 && size == 4) tty_len_ = v;
  drain_console();
  return false;
}

// ---------------------------------------------------------------------------
// DMA: what each command makes its device read and write (bus_if.h)
// ---------------------------------------------------------------------------
bool QemuMachine::rings(const Transport &t, const Queue &q, uint64_t &desc, uint64_t &avail,
                        uint64_t &used) const {
  if (!q.num) return false;
  if (t.version == 1) {
    if (!q.pfn) return false;
    desc = uint64_t(q.pfn) * t.page;
    avail = desc + 16ull * q.num;
    uint32_t al = q.align ? q.align : 4096;
    used = (avail + 4 + 2ull * q.num + 2 + al - 1) & ~uint64_t(al - 1);
  } else {
    desc = q.desc;
    avail = q.avail;
    used = q.used;
  }
  return desc + 16ull * q.num <= ram_size && avail + 6 + 2ull * q.num <= ram_size &&
         used + 6 + 8ull * q.num <= ram_size;
}

uint16_t QemuMachine::r16(uint64_t a, bool le) const {
  if (a + 2 > ram_size) return 0;
  const uint8_t *p = ram + a;
  return le ? uint16_t(p[0] | (p[1] << 8)) : uint16_t((p[0] << 8) | p[1]);
}

uint32_t QemuMachine::r32(uint64_t a, bool le) const {
  return le ? uint32_t(r16(a, true)) | (uint32_t(r16(a + 2, true)) << 16)
            : (uint32_t(r16(a, false)) << 16) | r16(a + 2, false);
}

bool QemuMachine::dma_hold(uint32_t pa, int size, uint32_t v) {
  if (pa == TTY + 0x08 && size == 4 && (v == 2 || v == 3)) {
    dc_ = DmaCmd();
    dc_.kind = 1;
    dc_.v = v;
    return true;
  }
  if (pa >= VIRTIO && pa < VIRTIO + 0x10000 && ((pa - VIRTIO) & 0x1FF) == 0x050 && size == 4) {
    dc_ = DmaCmd();
    dc_.kind = 2;
    dc_.slot = int((pa - VIRTIO) >> 9);
    dc_.queue = __builtin_bswap32(v) & 7;
    return true;
  }
  return false;
}

// The descriptor chains made available since the last notification: the
// buffers the device reads (rd) and writes (wr), and the indirect tables
// (tables), which are read first and walked once they are coherent.
void QemuMachine::walk_chains(bool tables_only) {
  Transport &t = vt_[dc_.slot];
  Queue &q = t.q[dc_.queue];
  uint64_t desc, avail, used;
  if (!rings(t, q, desc, avail, used)) return;
  bool le = t.version != 1;
  constexpr uint16_t F_NEXT = 1, F_WRITE = 2, F_INDIRECT = 4;
  uint16_t end = r16(avail + 2, le);
  for (uint16_t k = q.seen; k != end; k++) {
    uint16_t head = r16(avail + 4 + 2ull * (k % q.num), le);
    uint64_t table = desc;
    uint32_t tsize = q.num;
    uint32_t i = head;
    for (uint32_t hops = 0; hops <= q.num + 1 && i < tsize; hops++) {
      uint64_t e = table + 16ull * i;
      uint64_t a = r32(e, le);                     // the low half: 32-bit physical
      uint32_t len = r32(e + 8, le);
      uint16_t fl = r16(e + 12, le), nx = r16(e + 14, le);
      if (fl & F_INDIRECT) {
        if (tables_only) dc_.tables.push_back({uint32_t(a), len});
        else { table = a; tsize = len / 16; i = 0; continue; }
        break;
      }
      if (!tables_only) (fl & F_WRITE ? dc_.wr : dc_.rd).push_back({uint32_t(a), len});
      if (!(fl & F_NEXT)) break;
      i = nx;
    }
  }
}

std::vector<BusIf::Dma> QemuMachine::dma_reads() {
  if (dc_.kind == 1) {
    if (dc_.v != 2 || dc_.phase++) return {};
    return {{tty_ptr_, tty_len_}};
  }
  if (dc_.kind != 2) return {};
  Transport &t = vt_[dc_.slot];
  Queue &q = t.q[dc_.queue];
  uint64_t desc, avail, used;
  if (!rings(t, q, desc, avail, used)) return {};
  switch (dc_.phase++) {
    case 0:   // the rings the driver wrote
      return {{uint32_t(desc), 16 * q.num}, {uint32_t(avail), 6 + 2 * q.num}};
    case 1:   // the indirect tables
      walk_chains(true);
      if (!dc_.tables.empty()) return dc_.tables;
      dc_.phase++;
      [[fallthrough]];
    case 2:   // the buffers the device reads
      walk_chains(false);
      if (!dc_.rd.empty()) return dc_.rd;
      return {};
  }
  return {};
}

std::vector<BusIf::Dma> QemuMachine::dma_writes() {
  if (dc_.kind == 1) {
    if (dc_.v != 3) return {};
    return {{tty_ptr_, tty_len_}};
  }
  if (dc_.kind != 2) return {};
  Transport &t = vt_[dc_.slot];
  Queue &q = t.q[dc_.queue];
  uint64_t desc, avail, used;
  if (!rings(t, q, desc, avail, used)) return {};
  q.seen = r16(avail + 2, t.version != 1);
  std::vector<Dma> w = dc_.wr;
  w.push_back({uint32_t(used), 6 + 8 * q.num});
  return w;
}

// The transports' queue registers, as the driver writes them, and the
// notification. virtio-mmio's registers are little-endian: a long word the
// big-endian processor stores reads byte-reversed here.
void QemuMachine::virtio_write(uint32_t off, uint32_t raw) {
  Transport &t = vt_[off >> 9];
  uint32_t v = __builtin_bswap32(raw);
  Queue &q = t.q[t.sel & 7];
  switch (off & 0x1FF) {
    case 0x028: t.page = v; break;
    case 0x030: t.sel = v; break;
    case 0x038: q.num = v; break;
    case 0x03C: q.align = v; break;
    case 0x040: q.pfn = v; break;
    case 0x080: q.desc = (q.desc & ~0xFFFFFFFFull) | v; break;
    case 0x090: q.avail = (q.avail & ~0xFFFFFFFFull) | v; break;
    case 0x0A0: q.used = (q.used & ~0xFFFFFFFFull) | v; break;
    case 0x050: settle_virtio(int(off >> 9), v); break;
  }
}

// Wait, with QEMU's clock held, until the device has used every buffer the
// driver made available on the queue: QEMU's block requests complete on its
// own threads, at host-dependent times, and the guest must see them at a
// virtual time of the harness's choosing. Version 2 rings are little-endian;
// version 1's are the guest's order, big-endian here.
void QemuMachine::settle_virtio(int slot, uint32_t queue) {
  Transport &t = vt_[slot];
  Queue &q = t.q[queue & 7];
  uint64_t desc, avail, used;
  bool le = t.version != 1;
  if (!rings(t, q, desc, avail, used)) return;
  auto idx = [&](uint64_t a) -> uint16_t {
    const volatile uint8_t *p = ram + a + 2;
    return le ? uint16_t(p[0] | (p[1] << 8)) : uint16_t((p[0] << 8) | p[1]);
  };
  auto t0 = std::chrono::steady_clock::now();
  while (idx(used) != idx(avail)) {
    if (std::chrono::steady_clock::now() - t0 > std::chrono::seconds(20)) {
      fprintf(stderr, "rd-qvirt: virtio %d queue %u: used %u never reached avail %u\n", slot,
              queue, idx(used), idx(avail));
      return;
    }
    std::this_thread::sleep_for(std::chrono::microseconds(20));
  }
  settles++;
  // One round trip after: the interrupt the completion raised is reported
  // before its reply.
  std::string r;
  send("readl 0xff010000", r);
}

// Console input goes into the goldfish tty only as far as its FIFO has room,
// and is waited for there, so that the guest's receive interrupt is raised
// at the virtual time it is typed.
void QemuMachine::pump_input() {
  if (pending_.empty() || gone) return;
  uint64_t have = 0;
  if (!cmd_ok("readl 0xff008004", &have)) return;
  if (have >= TTY_FIFO) return;
  size_t k = std::min<size_t>(TTY_FIFO - have, pending_.size());
  size_t done = 0;
  while (done < k) {
    ssize_t w = write(con_, pending_.data() + done, k - done);
    if (w < 0 && (errno == EAGAIN || errno == EINTR)) {
      std::this_thread::sleep_for(std::chrono::microseconds(50));
      continue;
    }
    if (w <= 0) { gone = true; return; }
    done += size_t(w);
  }
  pending_.erase(0, k);
  auto t0 = std::chrono::steady_clock::now();
  uint64_t now_have = have;
  while (now_have < have + k) {
    if (!cmd_ok("readl 0xff008004", &now_have)) return;
    if (std::chrono::steady_clock::now() - t0 > std::chrono::seconds(20)) {
      fprintf(stderr, "rd-qvirt: the console FIFO took %llu of %zu bytes\n",
              (unsigned long long)(now_have - have), k);
      return;
    }
  }
}
