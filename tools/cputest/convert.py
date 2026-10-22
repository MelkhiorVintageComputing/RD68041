#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041
"""Decode a WinUAE cputest data set (DATA_VERSION 24), for people and for the core.

    convert.py dump DIR MNEMONIC [--limit N] [--json]
    convert.py summary DIR... [--select ADD,MOVE.L]
    convert.py bench OUTDIR DIR... [--select ADD,MOVE.L] [--max N]

RD68031's convert.py (tools/cputest there), extended for the MC68040 corpus
(RD68041): the FPU's registers, FPCR, FPSR and FPIAR in the state, the FPU
test loops and register overrides, and `summary`, which decodes every test of
every instruction and counts them. The 68040's frames need nothing new: the
corpus has no bus or address errors (no format $7), and the FP ones -- format
$2 for an unimplemented instruction (vector 11) or data type (55), $3 for a
post-instruction exception, $0 -- were already decoded, with the generator's
"EA valid" flag (fpeaset). `bench` still writes RD68031's integer stream; an
FPU set is refused there until RD68041's bench defines its stream (M7, M11).

`dump` prints decoded tests. `bench` writes OUTDIR/cputest.vec, the stream
sim/tb/core_cputest_tb.sv runs (its format is BENCH_FORMAT below), with
OUTDIR/lmem<N>.hex and tmem<N>.hex, the memory images of the Nth set, and
OUTDIR/cputest.idx, which maps a failing test's number back to its
instruction, sub-test and opcode.

DIR is a generated set, e.g. build/spikes/uae030/cputest/data/3_RD030, holding
lmem.dat, tmem.dat (memory images) and one sub-directory per instruction with
0000.dat (merged container: header chunk, then data chunks).

The decoder is a transcription of the reader in Inputs/ref/winuae/cputest/main.c
(test_mnemo, process_test, restore_data, validate_test, validate_exception) for
cpu_lvl >= 1, with or without the FPU.  Each test is emitted as a dict:

  name, file, test, sub (ccr index), extraccr
  start_pc, end_pc, opcode (instruction words, hex), srcaddr, dstaddr
  init:     {D[8], A[8] (A7 = USP), SR, SSP, MSP, and with the FPU
             FP[8] as (exp, mant_hi, mant_lo), FPCR, FPSR, FPIAR}
  mem_init: [(addr, nbytes, value)]    patches over lmem/tmem for this test
                                      (the opcode bytes themselves are in 'opcode')
  expect:   {D[8], A[8], SR, SR_ignore, PC, and the FPU's as in init}
            or None when the test is skipped
  mem_writes: [(addr, nbytes, old, new)]
  exception: None, or {vector, extra, frame: {PC, format_vector, addr...}}

Runner conventions (main.c), which decode() replays and the bench reproduces:
- after the instruction the runner places NOP_OPCODE (0x2048, MOVEA.L A0,A0)
  + ILLEGAL (0x4AFC), or ILLEGAL first, alternating per sub-test; normal
  completion is "exception 4 at end_pc" (+2 when the NOP came first);
- a branch target holds a NOP or an ILLEGAL, toggled per sub-test;
- before each test, up to 32 bytes at the user A7 are copied to SSP;
- each test is entered with an RTE from SSP-8, with USP = A7, ISP = SSP =
  super_stack - $80 and MSP = super_stack;
- after each test, each expected memory write is checked and its old value put
  back; the set-up writes of a test group are rolled back at its end.
"""
import argparse
import json
import os
import struct
import sys

CT_DREG, CT_AREG, CT_SSP, CT_MSP, CT_SR, CT_PC = 0, 8, 16, 17, 18, 19
CT_FPIAR, CT_FPSR, CT_FPCR, CT_EDATA = 20, 21, 22, 23
CT_CYCLES, CT_ENDPC, CT_BRANCHTARGET, CT_SRCADDR, CT_DSTADDR = 25, 26, 27, 28, 29
CT_MEMWRITE, CT_MEMWRITES = 30, 31
CT_DATA_MASK, CT_EXCEPTION_MASK = 31, 63
CT_SIZE_BYTE, CT_SIZE_WORD, CT_SIZE_LONG, CT_SIZE_FPU = 0x00, 0x20, 0x40, 0x60
CT_SIZE_MASK = 0x60
CT_RELATIVE_START_WORD, CT_ABSOLUTE_WORD, CT_ABSOLUTE_LONG = 0x00, 0x20, 0x40
CT_RELATIVE_START_BYTE = CT_PC_BYTES = 0x60
CT_END, CT_END_FINISH, CT_END_INIT = 0x80, 0xFF, 0xC0
CT_END_SKIP, CT_SKIP_REGS, CT_EMPTY = 0xC1, 0xC2, 0xC0
CT_OVERRIDE_REG, CT_BRANCHED = 0xD0, 0x40
DATA_VERSION = 24


def s8(v):
    return v - 0x100 if v & 0x80 else v


def s16(v):
    return v - 0x10000 if v & 0x8000 else v


class Reader:
    def __init__(self, data):
        self.d = data
        self.p = 0

    def peek(self):
        return self.d[self.p]

    def u8(self):
        v = self.d[self.p]
        self.p += 1
        return v

    def u16(self):
        v = (self.d[self.p] << 8) | self.d[self.p + 1]
        self.p += 2
        return v

    def u32(self):
        v = struct.unpack_from(">I", self.d, self.p)[0]
        self.p += 4
        return v

    # restore_value(): partial replacement of the low byte/word, or a long
    def value(self, old):
        mode = self.u8()
        sz = mode & CT_SIZE_MASK
        if sz == CT_SIZE_BYTE:
            return (old & 0xFFFFFF00) | self.u8(), 0
        if sz == CT_SIZE_WORD:
            return (old & 0xFFFF0000) | self.u16(), 1
        if sz == CT_SIZE_LONG:
            return self.u32(), 2
        raise ValueError("unexpected FPU value")

    # restore_fpvalue(): an extended value, partly replaced from both ends
    def fpvalue(self, old):
        mode = self.u8()
        if mode & CT_SIZE_MASK != CT_SIZE_FPU:
            raise ValueError("expected an FPU value, got %02x" % mode)
        size = self.u8()
        if size == 0x00:
            return (0, 0, 0)
        if size == 0xFF:
            e = self.u16()
            return (e, self.u32(), self.u32())
        f = bytearray(struct.pack(">HII", *old))
        for i in range((size >> 4) & 15):
            f[i] = self.u8()
        for i in range(size & 15):
            f[9 - i] = self.u8()
        return struct.unpack(">HII", bytes(f))

    # restore_rel()
    def rel(self, base):
        mode = self.u8() & CT_SIZE_MASK
        if mode == CT_RELATIVE_START_BYTE:
            return (base + s8(self.u8())) & 0xFFFFFFFF
        if mode == CT_RELATIVE_START_WORD:
            return (base + s16(self.u16())) & 0xFFFFFFFF
        if mode == CT_ABSOLUTE_WORD:
            return s16(self.u16()) & 0xFFFFFFFF
        return self.u32()

    def rel_ordered(self, base):
        if self.peek() == CT_EMPTY:
            self.p += 1
            return base
        return self.rel(base)


def chunks(path):
    """Split a merged .dat container (0xAF 'MRG' size data ... size 0)."""
    raw = open(path, "rb").read()
    if raw[:4] != b"\xafMRG":
        yield raw
        return
    off = 0
    while off + 8 <= len(raw) and raw[off:off + 4] == b"\xafMRG":
        size = struct.unpack_from(">I", raw, off + 4)[0]
        if size == 0:
            break
        yield raw[off + 8:off + 8 + size]
        off += 8 + size


def parse_header(h):
    r = Reader(h)
    hd = {}
    if r.u32() != DATA_VERSION:
        raise ValueError("unsupported DATA_VERSION")
    hd["starttime"] = r.u32()
    v = r.u32()
    hd["hmem_rom"], hd["lmem_rom"] = s16(v >> 16), s16(v & 0xFFFF)
    hd["test_memory_start"] = r.u32()
    hd["test_memory_size"] = r.u32()
    hd["opcode_memory_start"] = r.u32()
    v = r.u32()
    hd["cpu_lvl"] = (v >> 16) & 15
    hd["interrupt_mask"] = (v >> 20) & 7
    hd["addressing_mask"] = 0xFFFFFFFF if v & 0x80000000 else 0x00FFFFFF
    hd["interrupttest"] = (v >> 26) & 3
    hd["sr_undefined_mask"] = v & 0xFFFF
    hd["safe_memory_mode"] = (v >> 23) & 7
    v = r.u32()
    hd["initial_interrupt_mask"] = v & 7
    hd["fpu_max_precision"] = (v >> 6) & 3
    r.u32(), r.u32()
    hd["fpu_model"] = r.u32()
    hd["test_low_memory_start"] = r.u32()
    hd["test_low_memory_end"] = r.u32()
    hd["test_high_memory_start"] = r.u32()
    hd["test_high_memory_end"] = r.u32()
    hd["safe_memory_start"] = r.u32()
    hd["safe_memory_end"] = r.u32()
    hd["user_stack_memory"] = r.u32()
    hd["super_stack_memory"] = r.u32()
    hd["exception_vectors"] = r.u32()
    r.u32(), r.u32(), r.u32()
    hd["inst_name"] = h[r.p:r.p + 16].split(b"\0")[0].decode("ascii", "replace")
    return hd


class Memory:
    """lmem/tmem images plus a sparse overlay."""

    def __init__(self, base, hd):
        self.hd = hd
        self.low = bytearray(open(os.path.join(base, "lmem.dat"), "rb").read()) \
            if os.path.exists(os.path.join(base, "lmem.dat")) else bytearray()
        self.tmem = bytearray(open(os.path.join(base, "tmem.dat"), "rb").read())
        self.tbase = hd["test_memory_start"]

    def _loc(self, a):
        if a < len(self.low):
            return self.low, a
        if self.tbase <= a < self.tbase + len(self.tmem):
            return self.tmem, a - self.tbase
        raise ValueError("address %08x outside test memory" % a)

    def write(self, a, n, v):
        for i in range(n):
            buf, o = self._loc(a + i)
            buf[o] = (v >> (8 * (n - 1 - i))) & 0xFF

    def read(self, a, n):
        out = bytearray()
        for i in range(n):
            buf, o = self._loc(a + i)
            out.append(buf[o])
        return bytes(out)


def mem_addr(r, hd):
    """get_memory_addr(): returns a CPU address."""
    mode = r.u8() & CT_SIZE_MASK
    if mode == CT_ABSOLUTE_WORD:
        off = s16(r.u16())
        return off & 0xFFFFFFFF  # negative = high memory 0xFFFF8000+
    if mode == CT_ABSOLUTE_LONG:
        return r.u32()
    if mode == CT_RELATIVE_START_WORD:
        return (hd["opcode_memory_start"] + s16(r.u16())) & 0xFFFFFFFF
    raise ValueError("bad memory address mode")


def mem_record(r, hd):
    """CT_MEMWRITE: address, old value, new value (size from the encoding)."""
    a = mem_addr(r, hd)
    old, _ = r.value(0)
    new, size = r.value(0)
    return a, 1 << size, old, new


def opcode_bytes(r, mem, hd):
    """CT_MEMWRITES|CT_PC_BYTES: bytes at opcode_memory_start + offset."""
    r.u8()
    if r.peek() == 0xFF:
        r.u8()
        off, ln = r.u8(), r.u8()
        ln = ln or 256
    else:
        v = r.u8()
        off, ln = v >> 5, (v & 31) or 32
    base = hd["opcode_memory_start"] + off
    b = bytes(r.u8() for _ in range(ln))
    for i in range(ln):
        mem.write(base + i, 1, b[i])
    return [(base, b)]


def parse_exception(r, hd, exc, state):
    """validate_exception() for cpu_lvl > 0.  Returns a dict."""
    start = r.p
    n = r.u8()
    out = {"vector": exc}
    if n == 0:
        return out
    if n == 0xFF:
        out.update(state.get("last_exc", {}))
        out["same_as_previous"] = True
        out["vector"] = exc
        return out
    extra = r.u8()
    if extra & 0x40:
        out["group2_with_1"] = r.u8()
        extra &= ~0x40
    out["extra"] = extra
    om = hd["opcode_memory_start"]
    if extra & 0x80:
        out["trace_sr"] = r.u16()
        out["trace_pc"] = r.rel_ordered(om)
    if exc != 1:
        fr = {"PC": r.rel_ordered(om), "format_vector": r.u16()}
        fmt = fr["format_vector"] >> 12
        if fmt in (2, 3):
            fr["addr"] = r.rel_ordered(om)
            if fmt == 3 or exc in (11, 55):
                fr["fpeaset"] = r.u8() & 1
        elif fmt == 4:
            fr["addr"] = r.rel_ordered(om)
            fr["addr2"] = r.rel_ordered(om)
            fr["fpeaset"] = r.u8() & 1
        elif fmt == 8:
            fr["PC2"] = r.rel_ordered(om)
            fr["SSW"] = r.u16()
            fr["fault"] = r.rel_ordered(om)
            fr["dout"], fr["din"], fr["insn"], fr["din_prev"] = r.u16(), r.u16(), r.u16(), r.u16()
        elif fmt in (0xA, 0xB):
            pass  # 68020/030 bus/address error: only the first 8 bytes are recorded
        elif fmt != 0:
            raise ValueError("unknown frame %04x" % fr["format_vector"])
        out["frame"] = fr
    if r.p != start + n + 1:
        raise ValueError("exception data length mismatch")
    state["last_exc"] = {k: v for k, v in out.items() if k != "vector"}
    return out


NOP_OPCODE, ILLG_OPCODE = 0x2048, 0x4AFC


def valid_rw(hd, a):
    """is_valid_test_addr_readwrite(): one of the three test regions."""
    a &= hd["addressing_mask"]
    lo_s, lo_e = hd["test_low_memory_start"], hd["test_low_memory_end"]
    hi_s, hi_e = hd["test_high_memory_start"], hd["test_high_memory_end"]
    t_s = hd["test_memory_start"]
    t_e = t_s + hd["test_memory_size"]
    return ((lo_s != 0xFFFFFFFF and lo_s <= a < lo_e) or
            (hi_s != 0xFFFFFFFF and hi_s <= a < hi_e) or (t_s <= a < t_e))


def undefined_ccr(name, sr, exc):
    """The condition codes PRM 4 leaves undefined, as the sweep masks them
    (tools/vectors/gen.c). The generator sends masks of its own, but not on
    every test (it left one CHK2 test without), so these are added to them."""
    base = name.split(".")[0].upper()
    vec = exc["vector"] if exc else 0
    if base in ("ABCD", "SBCD", "NBCD"):
        return 0x000A                       # N and V
    if base in ("CHK2", "CMP2"):
        return 0x000A                       # N and V
    if base == "CHK":
        return 0x000F                       # N (in bounds), Z, V, C
    if base in ("DIVU", "DIVS", "DIVL"):
        if vec == 5:
            return 0x000E                   # N, Z, V after a divide by zero
        if sr & 0x0002:
            return 0x000C                   # N and Z after an overflow
    return 0


def decode(setdir, mnemonic, limit=None):
    """Replay one instruction's data file the way the runner (main.c) does.

    Every record the runner would execute is yielded, skipped ones included,
    with what the runner does to memory around it:

      pre   [(addr, bytes)]  written before the test, in order: the set-up
                             writes of a new test group, the opcode bytes, the
                             end-of-test sentinel, the branch-target toggle --
                             and, at the first record after a group, the
                             restores that ended it
      copy  (src, dst, n) or None
                             the runner copies n bytes from the user stack
                             (A7) to the supervisor stack before every test
      post  [(addr, bytes)]  written after it: each expected write's old value
                             (the runner checks the new one, then puts the old
                             one back), and any opcode bytes the result stream
                             carries
      run   False for a test the data file marks skipped (CT_END_SKIP)
      exp_pc  the PC the core must stop at: the sentinel's address, or the
              faulting instruction's for an exception (frame PC)

    plus the fields fmt_rec() prints.  A final record with run=False and no
    test carries the restores of the last group."""
    path = os.path.join(setdir, mnemonic, "0000.dat")
    it = chunks(path)
    hd = parse_header(next(it))
    if hd["cpu_lvl"] < 1:
        raise SystemExit("only cpu_lvl >= 1 is decoded")
    fpu = hd["fpu_model"] != 0
    mem = Memory(setdir, hd)
    count = 0
    state = {}
    pending = []          # writes waiting for the next record
    # The runner compares SR under the last ignore mask the stream sent it
    # (main.c keeps it in a static and only a CT_SR item changes it), so a
    # test whose SR is not in the result stream inherits the previous mask --
    # and before the first one, nothing is compared.
    sr_cmp = 0

    def put(a, n, v):
        b = bytes(((v >> (8 * (n - 1 - i))) & 0xFF) for i in range(n))
        pending.append((a, b))
        mem.write(a, n, v)

    for ci, data in enumerate(it):
        r = Reader(data)
        if r.u32() != DATA_VERSION or r.u32() != hd["starttime"]:
            raise ValueError("chunk header mismatch")
        r.u32(), r.u32()
        cur = {"regs": [0] * 16, "sr": hd["interrupt_mask"] << 8, "pc": hd["opcode_memory_start"],
               "endpc": hd["opcode_memory_start"], "srcaddr": 0xFFFFFFFF, "dstaddr": 0xFFFFFFFF,
               "branchtarget": 0xFFFFFFFF, "branchtarget_mode": 0,
               "fp": [(0, 0, 0)] * 8, "fpcr": 0, "fpsr": 0, "fpiar": 0}
        startpc = endpc = hd["opcode_memory_start"]
        lregs = None
        test_no = 0
        while True:
            cur["endpc"], cur["pc"] = endpc, startpc
            hist = []  # memory set-up, rolled back after the test group
            # ---- restore_data() stream up to CT_END_INIT ----
            while r.peek() not in (CT_END_INIT, CT_END_FINISH):
                v = r.peek()
                mode = v & CT_DATA_MASK
                if mode < CT_AREG + 8 and v & CT_SIZE_MASK == CT_SIZE_FPU:
                    cur["fp"][mode] = r.fpvalue(cur["fp"][mode])
                elif mode < CT_AREG + 8:
                    cur["regs"][mode], _ = r.value(cur["regs"][mode])
                elif mode in (CT_FPIAR, CT_FPCR, CT_FPSR):
                    k = {CT_FPIAR: "fpiar", CT_FPCR: "fpcr", CT_FPSR: "fpsr"}[mode]
                    cur[k], _ = r.value(cur[k])
                elif mode == CT_SR:
                    cur["sr"], _ = r.value(cur["sr"])
                elif mode in (CT_PC, CT_ENDPC, CT_SRCADDR, CT_DSTADDR):
                    key = {CT_PC: "pc", CT_ENDPC: "endpc", CT_SRCADDR: "srcaddr", CT_DSTADDR: "dstaddr"}[mode]
                    cur[key], _ = r.value(cur[key])
                elif mode == CT_BRANCHTARGET:
                    cur["branchtarget"], _ = r.value(cur["branchtarget"])
                    cur["branchtarget_mode"] = r.u8()
                elif mode == CT_MEMWRITE:
                    a, size, old, new = mem_record(r, hd)
                    hist.append((a, size, old, new))
                    put(a, size, new)
                elif mode == CT_MEMWRITES:
                    for a, b in opcode_bytes(r, mem, hd):
                        pending.append((a, b))
                elif mode == CT_EDATA:
                    r.u8(), r.u8(), r.u8()
                elif mode == CT_CYCLES:
                    r.value(0)
                else:
                    raise ValueError("unexpected init item %02x at %d" % (v, r.p))
            if r.u8() == CT_END_FINISH:
                break
            startpc, endpc = cur["pc"], cur["endpc"]
            # an FPU test (main.c: fpumode): the FPU registers are part of
            # the state copied in and out
            fpumode = fpu and mem.read(hd["opcode_memory_start"], 1)[0] & 0xF0 == 0xF0
            # copyregs(&last_regs, &cur_regs): the result stream is a delta
            # against the group's starting registers (the FPU's only in an
            # FPU test; otherwise they keep the last ones)
            fpl = lregs if lregs is not None and not fpumode else cur
            lregs = {"regs": list(cur["regs"]), "sr": cur["sr"], "pc": cur["pc"],
                     "fp": list(fpl["fp"]), "fpcr": fpl["fpcr"], "fpsr": fpl["fpsr"],
                     "fpiar": fpl["fpiar"]}
            stackcopy = 0
            for i in range(0, 32, 2):
                if not valid_rw(hd, cur["regs"][15] + i):
                    break
                stackcopy += 2
            validend = 2 if valid_rw(hd, endpc + 2) else (1 if valid_rw(hd, endpc) else 0)
            original_end = (NOP_OPCODE << 16) | ILLG_OPCODE
            opcodeend = original_end
            ssp = (hd["super_stack_memory"] - 0x80) & 0xFFFFFFFF
            msp = hd["super_stack_memory"]
            extraccr = 0
            while True:
                sr_mask = ((0x2000 if extraccr & 1 else 0) | (0x4000 if extraccr & 2 else 0) |
                           (0x8000 if extraccr & 4 else 0) | (0x1000 if extraccr & 8 else 0))
                ccrmode = r.u8()
                maxccr = ccrmode & 0x3F
                for ccrcnt in range(maxccr):
                    ccr = ccrcnt & (maxccr - 1)
                    if hd["interrupttest"] < 2:
                        opcodeend = ((opcodeend >> 16) | (opcodeend << 16)) & 0xFFFFFFFF
                    extra = 2 if (opcodeend >> 16) == NOP_OPCODE else 0
                    if validend == 2:
                        put(endpc, 4, opcodeend)
                    elif validend == 1:
                        put(endpc, 2, opcodeend >> 16)
                    bt = cur["branchtarget"]
                    if bt != 0xFFFFFFFF and not (bt & 1):
                        if cur["branchtarget_mode"] == 1:
                            bv = int.from_bytes(mem.read(bt, 4), "big")
                            put(bt, 4, ((bv >> 16) | (bv << 16)) & 0xFFFFFFFF)
                        elif cur["branchtarget_mode"] == 2:
                            bv = int.from_bytes(mem.read(bt, 2), "big")
                            put(bt, 2, ILLG_OPCODE if bv == NOP_OPCODE else NOP_OPCODE)
                    test_regs = list(cur["regs"])
                    copy = None
                    if stackcopy:
                        copy = (test_regs[15], ssp, stackcopy)
                        try:
                            mem.write(ssp, stackcopy, int.from_bytes(mem.read(test_regs[15], stackcopy), "big"))
                        except ValueError:
                            pass
                    if maxccr >= 32:
                        sr = ccr & 0xFF
                    else:
                        sr = 31 if ccr & 1 else 0
                    sr |= sr_mask | (hd["initial_interrupt_mask"] << 8)
                    cur["fpiar"] = 0xFFFFFFFF
                    tfp = list(cur["fp"])
                    tfpiar = cur["fpiar"]
                    tfpcr, tfpsr = cur["fpcr"], cur["fpsr"]
                    if fpumode:
                        # the FPU loops: both all off / all on, or FPSR's
                        # condition codes, or FPCR's precision and rounding
                        tfpcr = tfpsr = 0
                        if maxccr < 16:
                            tfpsr = (15 if ccr & 1 else 0) << 24
                            tfpcr = (15 if ccr & 1 else 0) << 4
                        elif ccrmode & 0x40:
                            tfpsr = (ccr & 15) << 24
                        else:
                            tfpcr = (ccr & 15) << 4
                    if hd["interrupttest"] == 1:
                        r.u8()
                    while r.peek() == CT_OVERRIDE_REG:
                        r.u8()
                        v = r.u8()
                        reg, size = v & CT_DATA_MASK, v & CT_SIZE_MASK
                        if reg == CT_SR:
                            sr = (sr & 0xFF00) | r.u8() if size == CT_SIZE_BYTE else r.u16()
                        elif reg == CT_FPSR:
                            tfpsr = cur["fpsr"] = r.u32()
                        elif reg == CT_FPCR:
                            tfpcr = cur["fpcr"] = r.u32()
                        elif reg == CT_FPIAR:
                            tfpiar = cur["fpiar"] = r.u32()
                        elif reg < 16 and size == CT_SIZE_FPU:
                            e = r.u32()     # main.c: affects test_regs only
                            tfp[reg] = (e >> 16, r.u32(), r.u32())
                        elif reg < 16:
                            cur["regs"][reg] = r.u32()  # main.c: affects cur_regs only
                        else:
                            raise ValueError("unknown override register %02x" % v)
                    cur["sr"] = sr
                    cur["fpsr"], cur["fpcr"] = tfpsr, tfpcr
                    if not sr_mask and not ccr:
                        lregs["sr"] = sr
                        lregs["fpsr"], lregs["fpcr"] = tfpsr, tfpcr
                    rec = {
                        "name": hd["inst_name"], "file": path, "chunk": ci, "test": test_no,
                        "sub": ccrcnt, "extraccr": extraccr,
                        "start_pc": startpc, "end_pc": endpc, "end_extra": extra,
                        "opcode": mem.read(startpc, max(0, endpc - startpc)).hex(),
                        "srcaddr": cur["srcaddr"], "dstaddr": cur["dstaddr"],
                        "init": {"D": test_regs[:8], "A": test_regs[8:], "SR": sr,
                                 "SSP": ssp, "MSP": msp},
                        "fpu": fpumode,
                        "mem_init": [(a, s, n) for (a, s, o, n) in hist],
                        "expect": None, "mem_writes": [], "exception": None,
                        "pre": pending, "copy": copy, "post": [], "run": False,
                        "mem": mem,
                    }
                    pending = []
                    if fpumode:
                        rec["init"].update({"FP": tfp, "FPCR": tfpcr, "FPSR": tfpsr, "FPIAR": tfpiar})
                    if r.peek() == CT_END_SKIP:
                        r.u8()
                    else:
                        rec["run"] = True
                        # ---- validate_test() stream up to CT_END|exc ----
                        skip_regs = False
                        while True:
                            v = r.peek()
                            if v == CT_SKIP_REGS:
                                r.u8()
                                skip_regs = True
                                continue
                            if v & CT_END:
                                r.u8()
                                exc = v & CT_EXCEPTION_MASK
                                rec["branched"] = bool(v & CT_BRANCHED)
                                if exc:
                                    rec["exception"] = parse_exception(r, hd, exc, state)
                                break
                            mode = v & CT_DATA_MASK
                            if mode < CT_AREG and v & CT_SIZE_MASK == CT_SIZE_FPU:
                                lregs["fp"][mode] = r.fpvalue(lregs["fp"][mode])
                            elif mode in (CT_FPIAR, CT_FPCR, CT_FPSR):
                                k = {CT_FPIAR: "fpiar", CT_FPCR: "fpcr", CT_FPSR: "fpsr"}[mode]
                                lregs[k], _ = r.value(lregs[k])
                            elif mode < CT_AREG + 8:
                                lregs["regs"][mode], _ = r.value(lregs["regs"][mode])
                            elif mode == CT_SR:
                                lregs["sr"], _ = r.value(lregs["sr"])
                                sr_cmp = (~(lregs["sr"] >> 16)) & 0xFFFF
                            elif mode == CT_PC:
                                lregs["pc"] = r.rel(lregs["pc"])
                            elif mode == CT_CYCLES:
                                r.value(0)
                            elif mode == CT_MEMWRITE:
                                a, size, old, new = mem_record(r, hd)
                                rec["mem_writes"].append((a, size, old, new))
                                rec["post"].append((a, bytes(((old >> (8 * (size - 1 - i))) & 0xFF)
                                                             for i in range(size))))
                                mem.write(a, size, old)
                            elif mode == CT_MEMWRITES:
                                rec["post"].extend(opcode_bytes(r, mem, hd))
                            else:
                                raise ValueError("unexpected result item %02x at %d" % (v, r.p))
                        rec["expect"] = {"D": lregs["regs"][:8], "A": lregs["regs"][8:],
                                         "SR": lregs["sr"] & 0xFFFF,
                                         "SR_ignore": ((~sr_cmp) | undefined_ccr(
                                             hd["inst_name"], lregs["sr"],
                                             rec["exception"])) & 0xFFFF,
                                         "PC": lregs["pc"], "skip_regs": skip_regs}
                        if fpumode:
                            rec["expect"].update({"FP": list(lregs["fp"]), "FPCR": lregs["fpcr"],
                                                  "FPSR": lregs["fpsr"], "FPIAR": lregs["fpiar"]})
                        exc = rec["exception"]
                        if exc is None:
                            rec["exp_pc"] = (lregs["pc"] + extra) & 0xFFFFFFFF
                        else:
                            rec["exp_pc"] = exc.get("frame", {}).get("PC", 0)
                    yield rec
                    count += 1
                    if limit and count >= limit:
                        return
                if r.peek() == CT_END:
                    r.u8()
                    break
                extraccr = r.u8()
            # the end of a test group: the sentinel goes back to what it was,
            # and the set-up writes are rolled back (restoreahist)
            if validend == 2:
                put(endpc, 4, original_end)
            elif validend == 1:
                put(endpc, 2, original_end >> 16)
            for a, size, old, new in reversed(hist):
                put(a, size, old)
            test_no += 1
    yield {"name": hd["inst_name"], "run": False, "pre": pending, "copy": None, "post": [],
           "final": True, "mem": mem}


def fmt_rec(t):
    h = lambda v: "%08x" % v
    s = ["%s chunk%d test%d sub%d x%d pc=%08x op=%s" % (t["name"], t["chunk"], t["test"], t["sub"],
                                                       t["extraccr"], t["start_pc"], t["opcode"])]
    i = t["init"]
    fx = lambda f: "%04x:%08x%08x" % tuple(f)
    s.append("  in : SR=%04x D=%s A=%s" % (i["SR"], " ".join(map(h, i["D"])), " ".join(map(h, i["A"]))))
    if "FP" in i:
        s.append("       FPCR=%08x FPSR=%08x FPIAR=%08x FP=%s" % (i["FPCR"], i["FPSR"], i["FPIAR"],
                                                             " ".join(map(fx, i["FP"]))))
    if t["mem_init"]:
        s.append("  mem: " + " ".join("%08x.%d=%x" % m for m in t["mem_init"]))
    e = t["expect"]
    if e is None:
        s.append("  (skipped)")
    else:
        s.append("  out: SR=%04x(ign %04x) PC=%08x D=%s A=%s" % (e["SR"], e["SR_ignore"], e["PC"],
                                                                 " ".join(map(h, e["D"])), " ".join(map(h, e["A"]))))
        if "FP" in e:
            s.append("       FPCR=%08x FPSR=%08x FPIAR=%08x FP=%s" % (e["FPCR"], e["FPSR"], e["FPIAR"],
                                                                 " ".join(map(fx, e["FP"]))))
        for a, sz, o, n in t["mem_writes"]:
            s.append("  wr : %08x.%d %x -> %x" % (a, sz, o, n))
        if t["exception"]:
            s.append("  exc: %s" % json.dumps(t["exception"]))
    return "\n".join(s)


# ---------------------------------------------------------------------------
# The stream sim/tb/core_cputest_tb.sv reads
# ---------------------------------------------------------------------------
BENCH_FORMAT = """
The bench stream, read positionally with $fscanf("%h"), one record after another
until kind 3:

  kind                      0 run a test, 1 memory only (a test the runner skips,
                            or one this conversion samples out), 2 reload the
                            memory images, 3 the end
  -- kind 2 only:
  set                       which images: lmem<set>.hex and tmem<set>.hex
  npre  (addr byte)*npre    bytes written before the test, in order
  ncopy (src dst len)*ncopy the runner's user-to-supervisor stack copy
  -- kind 0 only:
  id  w0  w1                the test's number in the .idx file, and its first
                            two instruction words, for messages
  pc  sr  d0..d7  a0..a7  ssp  msp
                            the starting state: a7 is the user stack pointer,
                            ssp the interrupt stack pointer before the runner's
                            RTE frame is pushed below it
  vec  epc  efmt  naddr  eaddr
                            the exception that ends it -- vec 0 is the ILLEGAL
                            sentinel, taken at epc; otherwise the frame's PC,
                            format word, and, when naddr is 1, the address
                            word of a format $2 frame
  skipregs  ed0..ed7  ea0..ea7  esr  esrmask
                            the registers at that exception (ea7 = USP), and
                            the stacked SR under the generator's mask
  nwr  (addr size new old)*nwr
                            the memory writes the test must have made
  -- every kind:
  npost (addr byte)*npost   bytes written after it (each expected write's old
                            value goes back, as the runner does)
"""


def bench(setdir, mnemonics, out, idx, max_run=0, setno=0, tid0=0):
    """Convert the named instructions of one set into a bench stream."""
    nrun = nskip = nsampled = ntrace = nundef = 0
    tid = tid0

    def bcd_ok(b):
        return (b & 0x0F) <= 9 and (b >> 4) <= 9

    def byte_at(t, a):
        """A byte as the test starts: the replay's memory (old values already
        put back), with the runner's user-to-supervisor stack copy applied."""
        if t["copy"]:
            src, dst, n = t["copy"]
            if dst <= a < dst + n:
                a = src + (a - dst)
        return t["mem"].read(a, 1)[0]

    def undefined(t):
        """Tests whose result the manual leaves undefined:

        - MULU.L/MULS.L with a 64-bit product and Dh = Dl ("the results of the
          operation are undefined", PRM 4);
        - ABCD, SBCD and NBCD with an operand byte that is not binary-coded
          decimal. PRM 4 defines them on BCD digits only; the user decided to
          follow the manual rather than match what the part does with other
          bytes (doc/divergences.md), so these tests are not compared."""
        op = bytes.fromhex(t["opcode"])
        w0 = int.from_bytes(op[0:2], "big") if len(op) >= 2 else 0
        if len(op) >= 4 and (w0 & 0xFFC0) == 0x4C00:
            ext = int.from_bytes(op[2:4], "big")
            if ext & 0x0400 and (ext >> 12) & 7 == ext & 7:
                return True
        d, a = t["init"]["D"], t["init"]["A"]
        if (w0 & 0xB1F0) == 0x8100:             # ABCD $C1xx / SBCD $81xx
            rx, ry = (w0 >> 9) & 7, w0 & 7
            if w0 & 0x0008:                     # -(Ay),-(Ax)
                try:
                    # Computed from the registers, not from the corpus's
                    # source/destination address fields, which record the same
                    # address twice when Ax = Ay. Ay is decremented first, so
                    # with Ax = Ay the destination is the byte below the source;
                    # A7 steps by two.
                    src = a[ry] - (2 if ry == 7 else 1)
                    dst = (src if rx == ry else a[rx]) - (2 if rx == 7 else 1)
                    ops = (byte_at(t, src & 0xFFFFFFFF), byte_at(t, dst & 0xFFFFFFFF))
                except ValueError:
                    return False
            else:                               # Dy,Dx
                ops = (d[ry] & 0xFF, d[rx] & 0xFF)
            return not all(bcd_ok(b) for b in ops)
        if (w0 & 0xFFC0) == 0x4800 and (w0 >> 3) & 7 != 1:    # NBCD <ea>
            if (w0 >> 3) & 7 == 0:
                return not bcd_ok(d[w0 & 7] & 0xFF)
            if t["dstaddr"] != 0xFFFFFFFF:
                try:
                    return not bcd_ok(byte_at(t, t["dstaddr"]))
                except ValueError:
                    return False
        return False

    def emit_mem(f, writes):
        bs = [(a + i, b) for a, data in writes for i, b in enumerate(data)]
        f.write("%x" % len(bs))
        for a, b in bs:
            f.write(" %x %x" % (a, b))
        f.write("\n")

    for mn in mnemonics:
        total = 0
        if max_run:
            total = sum(1 for t in decode(setdir, mn) if t.get("run"))
        step = max(1, -(-total // max_run)) if max_run and total > max_run else 1
        out.write("2\n%x\n0\n0\n0\n" % setno)
        seen = 0
        # What the records that are not run do to memory is folded into the
        # next one that is: the net bytes, read from the replay's own memory,
        # which holds every write the runner makes (the core's writes in a test
        # that is not run are the ones it does not make).
        fold = {}

        def touched(t):
            for a, data in t["pre"] + t["post"]:
                for i in range(len(data)):
                    yield a + i
            if t["copy"]:
                for i in range(t["copy"][2]):
                    yield t["copy"][1] + i

        for t in decode(setdir, mn):
            if t.get("fpu"):
                raise SystemExit("bench: %s is an FPU test set; RD68041's bench stream for the "
                                 "FPU is not defined yet (use summary)" % setdir)
            run = t["run"]
            if run and t["exception"] and "trace_sr" in t["exception"]:
                run = False     # an exception followed by a trace: two frames
                ntrace += 1
            if run and undefined(t):
                run = False
                nundef += 1
            if run:
                if seen % step:
                    run = False
                    nsampled += 1
                seen += 1
            elif not t.get("final") and not t["run"]:
                nskip += 1          # only the generator's own skips
            if not run:
                for a in touched(t):
                    try:
                        fold[a] = t["mem"].read(a, 1)[0]
                    except ValueError:
                        pass
                if not t.get("final"):
                    continue
                out.write("1\n")
                emit_mem(out, [(a, bytes([v])) for a, v in sorted(fold.items())])
                out.write("0\n0\n")
                fold = {}
                continue
            out.write("0\n")
            emit_mem(out, [(a, bytes([v])) for a, v in sorted(fold.items())] + t["pre"])
            fold = {}
            if t["copy"]:
                out.write("1 %x %x %x\n" % t["copy"])
            else:
                out.write("0\n")
            op = bytes.fromhex(t["opcode"]) + bytes(4)
            i, e, x = t["init"], t["expect"], t["exception"]
            out.write("%x %x %x\n" % (tid, int.from_bytes(op[0:2], "big"),
                                      int.from_bytes(op[2:4], "big")))
            out.write("%x %x %s %s %x %x\n" % (t["start_pc"], i["SR"],
                      " ".join("%x" % v for v in i["D"]),
                      " ".join("%x" % v for v in i["A"]), i["SSP"], i["MSP"]))
            fr = (x or {}).get("frame", {})
            out.write("%x %x %x %x %x\n" % (x["vector"] if x else 0, t["exp_pc"],
                      fr.get("format_vector", 0), 1 if "addr" in fr else 0,
                      fr.get("addr", 0)))
            out.write("%x %s %s %x %x\n" % (1 if e["skip_regs"] else 0,
                      " ".join("%x" % v for v in e["D"]),
                      " ".join("%x" % v for v in e["A"]), e["SR"],
                      (~e["SR_ignore"]) & 0xFFFF))
            out.write("%x" % len(t["mem_writes"]))
            for a, sz, old, new in t["mem_writes"]:
                out.write(" %x %x %x %x" % (a, sz, new, old))
            out.write("\n")
            idx.write("%x %s chunk%d test%d sub%d x%d pc=%08x op=%s\n" % (
                tid, mn, t["chunk"], t["test"], t["sub"], t["extraccr"],
                t["start_pc"], t["opcode"]))
            tid += 1
            nrun += 1
            emit_mem(out, t["post"])
    return nrun, nskip, nsampled, ntrace, nundef


def summary(sets, sel):
    """Decode every test of every instruction of the sets, and count them."""
    grand = {"files": 0, "tests": 0, "run": 0, "skip": 0, "fpu": 0}
    excs, frames, fpu_mn, mns = {}, {}, set(), set()
    fails = []
    for sdir in sets:
        sub = sorted(d for d in os.listdir(sdir) if os.path.isdir(os.path.join(sdir, d)))
        if sel:
            sub = [m for m in sub if any(m.upper() == x or m.upper().split(".")[0] == x for x in sel)]
        print("%s: %d instruction files" % (sdir, len(sub)))
        for mn in sub:
            n = nrun = nskip = nfpu = 0
            try:
                for t in decode(sdir, mn):
                    if t.get("final"):
                        continue
                    n += 1
                    if not t["run"]:
                        nskip += 1
                        continue
                    nrun += 1
                    if t.get("fpu"):
                        nfpu += 1
                    x = t["exception"]
                    if x:
                        excs[x["vector"]] = excs.get(x["vector"], 0) + 1
                        fr = x.get("frame")
                        if fr:
                            k = (fr["format_vector"] >> 12, x["vector"])
                            frames[k] = frames.get(k, 0) + 1
            except (ValueError, IndexError, struct.error) as e:
                fails.append((sdir, mn, str(e)))
                print("  %-12s DECODE ERROR after %d tests: %s" % (mn, n, e))
                continue
            print("  %-12s %8d tests, %8d run, %6d skipped by the generator%s" % (
                mn, n, nrun, nskip, (", %d FPU" % nfpu) if nfpu else ""))
            grand["files"] += 1
            grand["tests"] += n
            grand["run"] += nrun
            grand["skip"] += nskip
            grand["fpu"] += nfpu
            mns.add(mn.split(".")[0])
            if nfpu:
                fpu_mn.add(mn.split(".")[0])
    print("total: %(files)d instruction files, %(tests)d tests (%(run)d run, %(skip)d skipped by "
          "the generator, %(fpu)d FPU)" % grand)
    print("instructions: %d mnemonics, %d of them FPU" % (len(mns), len(fpu_mn)))
    print("exceptions by vector: " + ", ".join("%d: %d" % kv for kv in sorted(excs.items())))
    print("frames (format, vector): " + ", ".join("$%X/%d: %d" % (k[0], k[1], v)
                                                  for k, v in sorted(frames.items())))
    if fails:
        print("DECODE ERRORS: %d files" % len(fails))
    return not fails


def images(setdir, outdir, setno):
    """lmem.dat and tmem.dat as $readmemh files, and the set's header."""
    sub = sorted(d for d in os.listdir(setdir) if os.path.isdir(os.path.join(setdir, d)))
    hd = parse_header(next(chunks(os.path.join(setdir, sub[0], "0000.dat"))))
    for name in ("lmem", "tmem"):
        p = os.path.join(setdir, name + ".dat")
        data = open(p, "rb").read() if os.path.exists(p) else b""
        with open(os.path.join(outdir, "%s%d.hex" % (name, setno)), "w") as f:
            f.write("@%x\n" % (0 if name == "lmem" else hd["test_memory_start"]))
            for i in range(0, len(data), 16):
                f.write(" ".join("%02x" % b for b in data[i:i + 16]) + "\n")
    return hd, sub


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sp = ap.add_subparsers(dest="cmd")
    d = sp.add_parser("dump", help="print decoded tests")
    d.add_argument("set", help="data/<lvl>_<name> directory")
    d.add_argument("mnemonic", help="sub-directory, e.g. ADD.L")
    d.add_argument("--limit", type=int, default=20)
    d.add_argument("--json", action="store_true", help="one JSON object per line")
    d.add_argument("--header", action="store_true", help="print the set header")
    b = sp.add_parser("bench", help="write the stream core_cputest_tb reads")
    b.add_argument("out", help="output directory")
    b.add_argument("sets", nargs="+", help="data/<lvl>_<name> directories")
    b.add_argument("--select", default="", help="comma-separated mnemonics or "
                   "prefixes (ADD matches ADD.B ADD.W ADD.L); empty = all")
    b.add_argument("--max", type=int, default=0, help="at most this many tests run "
                   "per instruction, evenly sampled (0 = all)")
    sm = sp.add_parser("summary", help="decode every test and count them")
    sm.add_argument("sets", nargs="+", help="data/<lvl>_<name> directories")
    sm.add_argument("--select", default="", help="as for bench")
    a = ap.parse_args()
    if a.cmd == "summary":
        sel = [x.strip().upper() for x in a.select.split(",") if x.strip()]
        sys.exit(0 if summary(a.sets, sel) else 1)
    if a.cmd == "dump":
        if a.header:
            print(json.dumps(parse_header(next(chunks(os.path.join(a.set, a.mnemonic, "0000.dat")))), indent=1))
        for t in decode(a.set, a.mnemonic, a.limit or None):
            if not t.get("final"):
                print(json.dumps(t, default=lambda o: o.hex() if isinstance(o, bytes) else str(o))
                      if a.json else fmt_rec(t))
        return
    if a.cmd != "bench":
        ap.print_help()
        return
    sel = [x.strip().upper() for x in a.select.split(",") if x.strip()]
    os.makedirs(a.out, exist_ok=True)
    tot = [0, 0, 0, 0, 0]
    with open(os.path.join(a.out, "cputest.vec"), "w") as out, \
         open(os.path.join(a.out, "cputest.idx"), "w") as idx, \
         open(os.path.join(a.out, "cputest.sets"), "w") as sets:
        sets_ok = [d for d in a.sets
                   if any(os.path.isdir(os.path.join(d, x)) for x in os.listdir(d))]
        for si, sdir in enumerate(sets_ok):
            hd, sub = images(sdir, a.out, si)
            if sel:
                sub = [m for m in sub if any(m.upper() == x or m.upper().split(".")[0] == x
                                             for x in sel)]
            sets.write("%d %s %x %x %x %x\n" % (si, sdir, hd["test_memory_start"],
                                                hd["test_memory_size"], hd["super_stack_memory"],
                                                hd["user_stack_memory"]))
            r = bench(sdir, sub, out, idx, a.max, si, tot[0])
            tot = [x + y for x, y in zip(tot, r)]
        out.write("3\n")
    print("cputest: %d tests to run; %d skipped by the generator, %d sampled out, "
          "%d with a trace after an exception, %d whose result the manual leaves "
          "undefined" % tuple(tot))


if __name__ == "__main__":
    main()
