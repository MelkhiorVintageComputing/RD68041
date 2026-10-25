#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041
"""The reference of rd-qvirt (doc/qvirt.md): the same guest on the same QEMU
virt machine, with QEMU's own m68040 (TCG) as its processor.

    qemu-ref.py --qemu QEMU --dir DIR --kernel ELF [--initrd F] [--cmdline S]
                [--disk IMG]... [--disk-rw IMG]... [--ram MB] [--rtc-base T] [--no-fpu]
                [--script F] [--log FILE]
                [--expect TEXT] [--timeout S]

The machine is set up as qvirt sets up its own: the RAM a shared file, the
same RTC base, each --disk a virtio-blk disk with snapshot=on (--disk-rw:
written, for an install). QEMU starts held (-S); the bootinfo
it wrote is given rd-virt's fixed RNG seed, and with --no-fpu its FPU record
is cleared (the MC68LC040's), through the shared RAM; then QMP's `cont`.
The console (-serial stdio) is logged to FILE and driven by the script's
`expect <text>` / `send <text>` lines, as sim/virt/linux/qemu-run.py does.
Exit status 0 when every expect matched, the --expect texts are in the log,
and QEMU exited by itself (the guest powered off through virt-ctrl).
"""
import argparse
import ctypes
import json
import mmap
import os
import select
import socket
import struct
import subprocess
import sys
import time

BI_LAST, BI_MACHTYPE, BI_FPUTYPE, BI_RNG_SEED = 0, 1, 3, 8
MACH_VIRT = 14


def elf_end(path):
    """The kernel's end (QEMU's `high`, from the program headers' paddr)."""
    b = open(path, "rb").read()
    if b[:4] != b"\x7fELF" or b[4] != 1 or b[5] != 2:
        sys.exit(f"qemu-ref.py: {path} is not a 32-bit big-endian ELF")
    phoff, = struct.unpack_from(">I", b, 28)
    phentsize, phnum = struct.unpack_from(">HH", b, 42)
    end = 0
    for i in range(phnum):
        t, _, _, pa, _, msz = struct.unpack_from(">IIIIII", b, phoff + i * phentsize)
        if t == 1:
            end = max(end, pa + msz)
    return end


def fix_bootinfo(ram, end, nofpu):
    def is_start(a):
        return struct.unpack_from(">HHI", ram, a) == (BI_MACHTYPE, 8, MACH_VIRT)
    base = (end + 1) & ~1
    a = base
    while not is_start(a) and a < base + 0x10000:
        a += 2
    if not is_start(a):
        sys.exit("qemu-ref.py: no bootinfo after the kernel")
    fpu_done = not nofpu
    while True:
        tag, sz = struct.unpack_from(">HH", ram, a)
        if tag == BI_LAST or sz < 4:
            break
        if tag == BI_FPUTYPE and nofpu:
            struct.pack_into(">I", ram, a + 4, 0)
            fpu_done = True
        if tag == BI_RNG_SEED:
            n, = struct.unpack_from(">H", ram, a + 4)
            for i in range(min(n, sz - 6)):
                ram[a + 6 + i] = (0x5A ^ (i * 37)) & 0xFF
        a += sz
    if not fpu_done:
        sys.exit("qemu-ref.py: the bootinfo has no FPU record to clear")


def qmp(path):
    for _ in range(200):
        try:
            s = socket.socket(socket.AF_UNIX)
            s.connect(path)
            break
        except OSError:
            time.sleep(0.05)
    else:
        sys.exit("qemu-ref.py: no QMP socket")
    f = s.makefile("rw")
    f.readline()

    def cmd(c):
        f.write(json.dumps({"execute": c}) + "\n")
        f.flush()
        while True:
            r = json.loads(f.readline())
            if "return" in r or "error" in r:
                return r
    cmd("qmp_capabilities")
    return s, cmd


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qemu", required=True)
    ap.add_argument("--dir", required=True)
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--initrd")
    ap.add_argument("--cmdline")
    ap.add_argument("--disk", action="append", default=[])
    ap.add_argument("--disk-rw", action="append", default=[])
    ap.add_argument("--ram", type=int, default=128)
    ap.add_argument("--rtc-base", default="2026-10-01T00:00:00")
    ap.add_argument("--no-fpu", action="store_true")
    ap.add_argument("--script")
    ap.add_argument("--log", required=True)
    ap.add_argument("--expect", action="append", default=[])
    ap.add_argument("--timeout", type=float, default=1800)
    ap.add_argument("--qemu-arg", action="append", default=[],
                    help="one more QEMU argument (repeatable): a -plugin, say")
    o = ap.parse_args()
    steps = []
    if o.script:
        for line in open(o.script):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            verb, _, text = line.partition(" ")
            if verb not in ("expect", "send"):
                continue
            steps.append((verb, text.encode().decode("unicode_escape")))

    shm = "/dev/shm" if os.path.isdir("/dev/shm") else o.dir
    ram_path = f"{shm}/rdqvirt-ref-{os.getpid()}.ram"
    qmp_path = os.path.join(o.dir, "qmp.sock")
    for p in (ram_path, qmp_path):
        if os.path.exists(p):
            os.unlink(p)
    mb = f"{o.ram}M"
    args = [o.qemu, "-M", "virt", "-cpu", "m68040", "-accel", "tcg",
            "-icount", "shift=0,sleep=off", "-m", mb,
            "-object", f"memory-backend-file,id=ram,size={mb},mem-path={ram_path},share=on",
            "-machine", "memory-backend=ram", "-kernel", o.kernel,
            "-rtc", f"base={o.rtc_base},clock=vm", "-serial", "stdio",
            "-nic", "none", "-display", "none", "-monitor", "none",
            "-S", "-qmp", f"unix:{qmp_path},server=on,wait=off"]
    if o.initrd:
        args += ["-initrd", o.initrd]
    if o.cmdline:
        args += ["-append", o.cmdline]
    disks = [(d, "on") for d in o.disk] + [(d, "off") for d in o.disk_rw]
    for i, (d, snap) in enumerate(disks):
        args += ["-drive", f"if=none,id=hd{i},format=raw,snapshot={snap},file={d}",
                 "-device", f"virtio-blk-device,drive=hd{i}"]
    args += o.qemu_arg
    open(os.path.join(o.dir, "qemu.cmdline"), "w").write(" ".join(args) + "\n")
    t0 = time.time()
    def die_with_parent():
        ctypes.CDLL(None).prctl(1, 9)          # PR_SET_PDEATHSIG, SIGKILL
    p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=open(os.path.join(o.dir, "qemu.err"), "wb"),
                         preexec_fn=die_with_parent)
    qs, cmd = qmp(qmp_path)
    fd = os.open(ram_path, os.O_RDWR)
    ram = mmap.mmap(fd, o.ram << 20)
    os.close(fd)
    os.unlink(ram_path)                        # both have it mapped now
    fix_bootinfo(ram, elf_end(o.kernel), o.no_fpu)
    ram.flush()
    cmd("cont")

    log = open(o.log, "wb")
    out = b""
    mark = 0
    k = 0
    ok = True
    while True:
        while k < len(steps) and steps[k][0] == "send":
            time.sleep(0.05)
            p.stdin.write(steps[k][1].encode("latin-1"))
            p.stdin.flush()
            k += 1
        left = o.timeout - (time.time() - t0)
        if left <= 0:
            print(f"qemu-ref.py: timeout after {o.timeout:.0f} s"
                  + (f", waiting for '{steps[k][1]}'" if k < len(steps) else ""))
            ok = False
            p.kill()
            break
        r, _, _ = select.select([p.stdout], [], [], min(left, 1.0))
        if r:
            b = os.read(p.stdout.fileno(), 65536)
            if not b:
                break
            log.write(b)
            log.flush()
            out += b
        if k < len(steps) and steps[k][0] == "expect":
            i = out.find(steps[k][1].encode("latin-1"), mark)
            if i >= 0:
                mark = i + len(steps[k][1])
                k += 1
    rc = p.wait()
    qs.close()
    ram.close()
    if k < len(steps):
        print(f"qemu-ref.py: the script stopped at step {k}: {steps[k][0]} '{steps[k][1]}'")
        ok = False
    for e in o.expect:
        if e.encode() not in out:
            print(f"qemu-ref.py: the console never showed '{e}'")
            ok = False
    print(f"qemu-ref.py: QEMU exited with {rc} after {time.time() - t0:.1f} s wall")
    sys.exit(0 if ok and rc == 0 else 1)


if __name__ == "__main__":
    main()
