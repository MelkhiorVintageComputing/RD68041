#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041

"""The MC68040's stack frames and FSAVE state frames, written down once.

    python3 tools/ucode/frames.py           # write rtl/gen/rd68041_frame_pkg.sv
                                            # and doc/checkpoint.md's tables
    python3 tools/ucode/frames.py --check   # ... or fail if either is stale

The layouts are UM 8.4 (Figures in 8.4.1-8.4.6), UM Appendix A (format $4) and
UM 9.8 (Figure 9-10). Everything the RTL needs about a frame -- where each field
sits, how big each frame is, which formats RTE accepts on which part, the SSW's
bits -- comes from the package this writes, and doc/checkpoint.md's tables come
from the same lists, so the two cannot disagree. The bit positions inside the
FSAVE busy and unimplemented frames' words are the FPSP's interface (CLAUDE.md)
and are added at M11; the offsets are frozen here.
"""

import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PKG = os.path.join(ROOT, 'rtl', 'gen', 'rd68041_frame_pkg.sv')
DOC = os.path.join(ROOT, 'doc', 'checkpoint.md')

# Exception stack frames: format -> (name, [(offset, bytes, field, what)], where).
# Offsets from the stack pointer after stacking.
COMMON = [
    (0x00, 2, 'SR',  'the status register, as it was before the exception'),
    (0x02, 4, 'PC',  'the program counter (which instruction: UM 8.4, per format)'),
    (0x06, 2, 'FV',  'format (15-12) and vector offset (11-0)'),
]
FRAMES = {
    0x0: ('four-word', COMMON, 'UM 8.4.1'),
    0x1: ('four-word throwaway', COMMON, 'UM 8.4.2'),
    0x2: ('six-word', COMMON + [
        (0x08, 4, 'ADDR', 'the instruction address (CHK, CHK2, TRAPcc, FTRAPcc, '
                          'TRAPV, trace, divide by zero), the calculated <ea> '
                          '(unimplemented FP instruction), or the faulted address '
                          '(address error)'),
    ], 'UM 8.4.3'),
    0x3: ('floating-point post-instruction', COMMON + [
        (0x08, 4, 'EA', 'the calculated <ea> of the FP instruction'),
    ], 'UM 8.4.4'),
    0x4: ('eight-word (MC68LC040 only)', COMMON + [
        (0x08, 4, 'EA',  'the calculated <ea> of the FP instruction, $0 for '
                         'immediate and register direct'),
        (0x0C, 4, 'PCF', 'the PC of the faulted FP instruction'),
    ], 'UM A.5.1, A.5.2'),
    0x7: ('access error', COMMON + [
        (0x08, 4, 'EA',   'the calculated <ea> when CM, CT, CU or CP is set'),
        (0x0C, 2, 'SSW',  'the special status word (below)'),
        (0x0E, 2, 'WB3S', 'write-back 3 status (low byte; below)'),
        (0x10, 2, 'WB2S', 'write-back 2 status'),
        (0x12, 2, 'WB1S', 'write-back 1 status'),
        (0x14, 4, 'FA',   'the fault address: logical, physical for a push'),
        (0x18, 4, 'WB3A', 'write-back 3 address (the integer unit\'s, WB3)'),
        (0x1C, 4, 'WB3D', 'write-back 3 data, register aligned'),
        (0x20, 4, 'WB2A', 'write-back 2 address (the data memory unit\'s, WB2)'),
        (0x24, 4, 'WB2D', 'write-back 2 data, register aligned'),
        (0x28, 4, 'WB1A', 'write-back 1 address (the bus controller\'s, WB1)'),
        (0x2C, 4, 'WB1D', 'write-back 1 data, memory aligned; push data LW0'),
        (0x30, 4, 'PD1',  'push data LW1'),
        (0x34, 4, 'PD2',  'push data LW2'),
        (0x38, 4, 'PD3',  'push data LW3'),
    ], 'UM 8.4.6'),
}
SIZES = {0x0: 8, 0x1: 8, 0x2: 12, 0x3: 12, 0x4: 16, 0x7: 60}

# RTE (UM 8.4, A.5.2): the formats each part accepts; any other is a format
# error (vector 14). "The MC68040 does not generate or recognize" $4; "the
# MC68LC040 can handle all MC68040 stack frame formats".
RTE_040   = [0x0, 0x1, 0x2, 0x3, 0x7]
RTE_LC040 = [0x0, 0x1, 0x2, 0x3, 0x4, 0x7]

# The special status word of format $7 (UM 8.4.6.2, Figure 8-7).
SSW = [
    (15, 15, 'CP',   'continuation: FP post-instruction exception pending'),
    (14, 14, 'CU',   'continuation: unimplemented FP instruction exception pending'),
    (13, 13, 'CT',   'continuation: trace exception pending'),
    (12, 12, 'CM',   'continuation: MOVEM pending; EA holds its calculated <ea>'),
    (11, 11, 'MA',   'misaligned: the ATC fault is on the second page of an access '
                     'that spans two'),
    (10, 10, 'ATC',  'an ATC fault (nonresident, write protected, supervisor only), '
                     'not a bus error'),
    (9,  9,  'LK',   'the faulted transfer was locked'),
    (8,  8,  'RW',   'the faulted transfer was a read'),
    (7,  7,  'X',    'undefined (written as zero here)'),
    (6,  5,  'SIZE', 'the original access\'s size: 00 long, 01 byte, 10 word, 11 line'),
    (4,  3,  'TT',   'TT1-TT0 of the faulted transfer'),
    (2,  0,  'TM',   'TM2-TM0 of the faulted transfer'),
]

# The write-back status bytes (UM 8.4.6.3, Figure 8-8).
WBS = [
    (7, 7, 'V',    'a write-back is pending'),
    (6, 5, 'SIZE', 'its size'),
    (4, 3, 'TT',   'its TT1-TT0'),
    (2, 0, 'TM',   'its TM2-TM0'),
]

# FSAVE state frames (UM 9.8, Figure 9-10): (name, first long word's version
# and size bytes, total bytes, [(offset, bytes, field)]).
FSAVE = [
    ('null', 0x00, 0x00, 4, []),
    ('idle', 0x41, 0x00, 4, []),
    ('unimplemented instruction', 0x41, 0x30, 52, [
        (0x04, 4, 'CMDREG3B'),
        (0x0C, 4, 'STAG, WBTM66, WBTM1, WBTM0, SBIT'),
        (0x10, 4, 'CMDREG1B'),
        (0x14, 4, 'DTAG, WBTE15'),
        (0x18, 4, 'E1, E3, T'),
        (0x1C, 4, 'FPTS, FPTE'),
        (0x20, 4, 'FPTM 63-32'),
        (0x24, 4, 'FPTM 31-0'),
        (0x28, 4, 'ETS, ETE'),
        (0x2C, 4, 'ETM 63-32'),
        (0x30, 4, 'ETM 31-0'),
    ]),
    ('busy', 0x41, 0x60, 100, [
        (0x08, 4, 'CU_SAVEPC'),
        (0x18, 4, 'WBTS, WBTE 14-0'),
        (0x1C, 4, 'WBTM 65-34'),
        (0x20, 4, 'WBTM 33-2'),
        (0x28, 4, 'FPIARCU'),
        (0x34, 4, 'CMDREG3B'),
        (0x3C, 4, 'STAG, WBTM66, WBTM1, WBTM0, SBIT'),
        (0x40, 4, 'CMDREG1B'),
        (0x44, 4, 'DTAG, WBTE15'),
        (0x48, 4, 'E1, E3, T'),
        (0x4C, 4, 'FPTS, FPTE'),
        (0x50, 4, 'FPTM 63-32'),
        (0x54, 4, 'FPTM 31-0'),
        (0x58, 4, 'ETS, ETE'),
        (0x5C, 4, 'ETM 63-32'),
        (0x60, 4, 'ETM 31-0'),
    ]),
]

# The exception vectors (UM 8.1, PRM Appendix B) this design takes.
VECTORS = [
    (0,  'RESET_SSP', 'reset: initial interrupt stack pointer'),
    (1,  'RESET_PC',  'reset: initial PC'),
    (2,  'ACCESS',    'access error'),
    (3,  'ADDRESS',   'address error'),
    (4,  'ILLEGAL',   'illegal instruction'),
    (5,  'ZERODIV',   'integer divide by zero'),
    (6,  'CHK',       'CHK, CHK2'),
    (7,  'TRAPCC',    'FTRAPcc, TRAPcc, TRAPV'),
    (8,  'PRIV',      'privilege violation'),
    (9,  'TRACE',     'trace'),
    (10, 'ALINE',     'A-line'),
    (11, 'FLINE',     'F-line; unimplemented FP instruction; every FP instruction on the MC68LC040'),
    (14, 'FORMAT',    'format error'),
    (15, 'UNINIT',    'uninitialised interrupt'),
    (24, 'SPURIOUS',  'spurious interrupt'),
    (25, 'AUTOVEC1',  'level 1-7 autovectors (25-31)'),
    (32, 'TRAP0',     'TRAP #0-15 (32-47)'),
    (48, 'FP_BSUN',   'FP branch or set on unordered (BSUN)'),
    (49, 'FP_INEX',   'FP inexact result'),
    (50, 'FP_DZ',     'FP divide by zero'),
    (51, 'FP_UNFL',   'FP underflow'),
    (52, 'FP_OPERR',  'FP operand error'),
    (53, 'FP_OVFL',   'FP overflow'),
    (54, 'FP_SNAN',   'FP signaling NAN'),
    (55, 'FP_UNSUPP', 'FP unimplemented data type'),
]

# --------------------------------------------------------------------------


def check_layouts():
    """The design rules the lists above must keep."""
    for fmt, (_, fields, _) in FRAMES.items():
        at = 0
        for off, size, name, _ in fields:
            if off != at:
                raise SystemExit(f'frames.py: format ${fmt:X}: {name} at +${off:02X}, '
                                 f'expected +${at:02X}')
            at += size
        if at != SIZES[fmt]:
            raise SystemExit(f'frames.py: format ${fmt:X} is {at} bytes, not {SIZES[fmt]}')
    if SIZES[0x7] != 60:
        raise SystemExit('frames.py: UM 8.4.6: the access error frame is 30 words')
    for name, ver, size, total, fields in FSAVE:
        if total != 4 + size:
            raise SystemExit(f'frames.py: FSAVE {name}: {total} bytes for size ${size:02X}')
        for off, nbytes, field in fields:
            if off + nbytes > total:
                raise SystemExit(f'frames.py: FSAVE {name}: {field} past the end')
    bits = set()
    for hi, lo, name, _ in SSW:
        for b in range(lo, hi + 1):
            if b in bits:
                raise SystemExit(f'frames.py: SSW bit {b} twice')
            bits.add(b)
    if bits != set(range(16)):
        raise SystemExit('frames.py: the SSW does not cover 16 bits')


def gen_pkg():
    out = []
    w = out.append
    w('// SPDX-License-Identifier: CERN-OHL-S-2.0')
    w('// Copyright 2026 Romain Dolbeau')
    w('// Source location: https://github.com/MelkhiorVintageComputing/RD68041')
    w('')
    w('// GENERATED by tools/ucode/frames.py -- do not edit. The MC68040\'s stack')
    w('// frames (UM 8.4, A.5) and FSAVE state frames (UM 9.8): offsets, sizes, the')
    w('// SSW and write-back status bits. doc/checkpoint.md has the same tables.')
    w('')
    w('package rd68041_frame_pkg;')
    w('')
    for fmt in sorted(FRAMES):
        name, fields, src = FRAMES[fmt]
        w(f'  // Format ${fmt:X}, {name} ({src}): {SIZES[fmt]} bytes.')
        w(f"  localparam logic [3:0] FMT_{fmt:X} = 4'h{fmt:X};")
        w(f'  localparam int FMT_{fmt:X}_BYTES = {SIZES[fmt]};')
        for off, size, field, _ in fields:
            if field in ('SR', 'PC', 'FV') and fmt != 0x0:
                continue
            w(f"  localparam logic [7:0] F{fmt:X}_{field} = 8'h{off:02X};")
        w('')
    w('  // RTE accepts these formats; any other is a format error (vector 14).')
    m040 = sum(1 << f for f in RTE_040)
    mlc = sum(1 << f for f in RTE_LC040)
    w(f"  localparam logic [15:0] RTE_OK_040   = 16'h{m040:04X};")
    w(f"  localparam logic [15:0] RTE_OK_LC040 = 16'h{mlc:04X};")
    w('')
    w('  // The special status word (UM 8.4.6.2).')
    for hi, lo, name, _ in SSW:
        if hi == lo:
            w(f'  localparam int SSW_{name} = {lo};')
        else:
            w(f'  localparam int SSW_{name}_HI = {hi};')
            w(f'  localparam int SSW_{name}_LO = {lo};')
    w('')
    w('  // A write-back status byte (UM 8.4.6.3).')
    for hi, lo, name, _ in WBS:
        if hi == lo:
            w(f'  localparam int WBS_{name} = {lo};')
        else:
            w(f'  localparam int WBS_{name}_HI = {hi};')
            w(f'  localparam int WBS_{name}_LO = {lo};')
    w('')
    w('  // FSAVE state frames (UM 9.8): the first long word\'s version and size')
    w('  // bytes, and the frame\'s length.')
    for name, ver, size, total, _ in FSAVE:
        tag = re.sub(r'\W+', '_', name.split()[0]).upper()
        w(f"  localparam logic [7:0] FS_{tag}_VERSION = 8'h{ver:02X};")
        w(f"  localparam logic [7:0] FS_{tag}_SIZE    = 8'h{size:02X};")
        w(f'  localparam int         FS_{tag}_BYTES   = {total};')
    w('')
    w('  // Exception vector numbers (UM 8.1, PRM Appendix B).')
    for num, tag, what in VECTORS:
        w(f"  localparam logic [7:0] VEC_{tag} = 8'd{num};  // {what}")
    w('')
    w('endpackage')
    return '\n'.join(out) + '\n'


def gen_tables():
    out = []
    w = out.append
    w('<!-- BEGIN GENERATED by tools/ucode/frames.py: edit there, not here -->')
    w('')
    for fmt in sorted(FRAMES):
        name, fields, src = FRAMES[fmt]
        w(f'### Format ${fmt:X}: {name}, {SIZES[fmt]} bytes ({src})')
        w('')
        w('| Offset | Bytes | Field | |')
        w('|---|--:|---|---|')
        for off, size, field, what in fields:
            w(f'| +${off:02X} | {size} | {field} | {what} |')
        w('')
    w('RTE accepts, on the MC68040: ' + ', '.join(f'${f:X}' for f in RTE_040) +
      '; on the MC68LC040: ' + ', '.join(f'${f:X}' for f in RTE_LC040) +
      '. Any other format is a format error, vector 14.')
    w('')
    w('### The special status word (UM 8.4.6.2)')
    w('')
    w('| Bits | Field | |')
    w('|---|---|---|')
    for hi, lo, name, what in SSW:
        w(f'| {hi if hi == lo else f"{hi}–{lo}"} | {name} | {what} |')
    w('')
    w('### A write-back status byte (UM 8.4.6.3)')
    w('')
    w('| Bits | Field | |')
    w('|---|---|---|')
    for hi, lo, name, what in WBS:
        w(f'| {hi if hi == lo else f"{hi}–{lo}"} | {name} | {what} |')
    w('')
    w('### FSAVE state frames (UM 9.8, Figure 9-10)')
    w('')
    w('| Frame | First long word | Bytes | Fields (offset: what) |')
    w('|---|---|--:|---|')
    for name, ver, size, total, fields in FSAVE:
        f = '; '.join(f'+${o:02X}: {n}' for o, _, n in fields) or '—'
        w(f'| {name} | ${ver:02X} ${size:02X} | {total} | {f} |')
    w('')
    w('### Vectors')
    w('')
    w('| Vector | |')
    w('|--:|---|')
    for num, _, what in VECTORS:
        w(f'| {num} | {what} |')
    w('')
    w('<!-- END GENERATED -->')
    return '\n'.join(out)


def splice(doc_text, tables):
    m = re.search(r'<!-- BEGIN GENERATED.*?<!-- END GENERATED -->', doc_text, re.S)
    if not m:
        raise SystemExit('frames.py: doc/checkpoint.md has no generated block')
    return doc_text[:m.start()] + tables + doc_text[m.end():]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true')
    args = ap.parse_args()
    check_layouts()
    pkg = gen_pkg()
    doc = splice(open(DOC).read(), gen_tables())
    if args.check:
        stale = []
        if not os.path.exists(PKG) or open(PKG).read() != pkg:
            stale.append(os.path.relpath(PKG, ROOT))
        if open(DOC).read() != doc:
            stale.append(os.path.relpath(DOC, ROOT))
        if stale:
            print('FAIL: ucode-check -- stale: ' + ', '.join(stale) + ' (make ucode)')
            return 1
        print('PASS: ucode-check')
        return 0
    os.makedirs(os.path.dirname(PKG), exist_ok=True)
    open(PKG, 'w').write(pkg)
    open(DOC, 'w').write(doc)
    print(f'wrote {os.path.relpath(PKG, ROOT)} and the tables in {os.path.relpath(DOC, ROOT)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
