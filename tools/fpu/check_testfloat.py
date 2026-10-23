#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041

"""The FPU's data path against Berkeley TestFloat (doc/fpu.md).

    python3 tools/fpu/check_testfloat.py [--limit N] [--level 1|2] [--only NAME]

testfloat_gen (built into build/testfloat/ by `make testfloat`) makes operands
and SoftFloat's results and flags; this writes them as vectors for
sim/tb/fpu_dp_tb.sv, runs it once, and compares. SoftFloat is an oracle here,
never a source (CLAUDE.md).

Where the MC68040 and SoftFloat legitimately differ, a vector is not compared
but checked for what the MC68040 does instead, and counted, so nothing hides:

  NaN operands or results   PRM 1.6.5's NaNs (the destination's, the default
                            all ones) are not SoftFloat's; the vector sweeps
                            and the cputest corpus judge them.
  denormal operands         an unsupported data type on the MC68040 (UM 9.6.2):
                            not the data path's.
  tiny results              underflow is a trap (UM 9.7.5.2): the data path
                            must say UNFL whenever SoftFloat's result is below
                            the precision's normal range, and only then.
  overflowed results        likewise OVFL (UM 9.7.4.2), whenever SoftFloat
                            overflows.
  extF80 exponents below 2  an extended exponent of 0 with the integer bit set
                            is a normal number on the MC68040 (UM Table 9-5),
                            where extF80 means 2^-16382: such operands and
                            results are skipped.
  integer invalid results   SoftFloat returns the x86 indefinite; the MC68040
                            takes an operand error (UM 9.7.3.2), its FPSP
                            stores the value: the flag is compared, not the
                            value. And the MC68040 calls the largest negative
                            integer an operand error too ("erroneous MC68040
                            condition"), where SoftFloat finds it exact.

Flags: SoftFloat's invalid, infinite, overflow, underflow and inexact against
the data path's OPERR/SNAN, DZ, OVFL, UNFL and INEX2 -- inexact also when it
overflowed, as the MC68040's accrued INEX is (UM 9.2.3.4).
"""

import argparse
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
GEN = os.path.join(ROOT, 'build', 'testfloat', 'testfloat', 'testfloat_gen')
VVP = os.path.join(ROOT, 'build', 'fpu_dp_tb.vvp')
VEC = os.path.join(ROOT, 'build', 'fpu_dp.vec')
OUT = os.path.join(ROOT, 'build', 'fpu_dp.out')

SF_INEXACT, SF_UNDERFLOW, SF_OVERFLOW, SF_INFINITE, SF_INVALID = 1, 2, 4, 8, 16
MODES = {'-rnear_even': 0, '-rminMag': 1, '-rmin': 2, '-rmax': 3}
# rd68041_fpu_pkg's operations and precisions.
D_MOVE, D_ADD, D_SUB, D_MUL, D_DIV, D_SQRT, D_SMUL, D_SDIV, D_INT = range(9)
P_X, P_S, P_D = 0, 1, 2
F_X, F_S, F_D, F_I = 0, 1, 2, 3


def x_nan(v):
    return (v >> 64) & 0x7FFF == 0x7FFF and v & ((1 << 63) - 1) != 0


def x_bad(v):
    """An extended value the data path never sees, or SoftFloat reads otherwise."""
    e = (v >> 64) & 0x7FFF
    m = v & ((1 << 64) - 1)
    if e == 0x7FFF:
        return x_nan(v)
    if e < 2:
        return m != 0
    return (m >> 63) == 0 and m != 0                     # unnormal


def f_parts(v, eb, fb):
    return (v >> fb) & ((1 << eb) - 1), v & ((1 << fb) - 1)


def f_nan(v, eb, fb):
    e, f = f_parts(v, eb, fb)
    return e == (1 << eb) - 1 and f != 0


def f_dnrm(v, eb, fb):
    e, f = f_parts(v, eb, fb)
    return e == 0 and f != 0


def tiny(v, fmt):
    """SoftFloat's result is below the format's normal range (or flushed to 0)."""
    if fmt == F_X:
        return (v >> 64) & 0x7FFF == 0
    eb, fb = (8, 23) if fmt == F_S else (11, 52)
    return f_parts(v, eb, fb)[0] == 0


# name, operation, input format, output format, precision, monadic
CHECKS = []
for fn, op in (('add', D_ADD), ('sub', D_SUB), ('mul', D_MUL), ('div', D_DIV),
               ('sqrt', D_SQRT)):
    CHECKS.append(('extF80_' + fn, op, F_X, F_X, P_X, fn == 'sqrt'))
    CHECKS.append(('f32_' + fn, op, F_S, F_S, P_S, fn == 'sqrt'))
    CHECKS.append(('f64_' + fn, op, F_D, F_D, P_D, fn == 'sqrt'))
CHECKS += [
    ('extF80_to_f32', D_MOVE, F_X, F_S, P_S, True),
    ('extF80_to_f64', D_MOVE, F_X, F_D, P_D, True),
    ('extF80_to_i32', D_INT, F_X, F_I, P_X, True),
    ('i32_to_extF80', D_MOVE, F_I, F_X, P_X, True),
    ('f32_to_extF80', D_MOVE, F_S, F_X, P_X, True),
    ('f64_to_extF80', D_MOVE, F_D, F_X, P_X, True),
    ('f32_to_f64', D_MOVE, F_S, F_D, P_D, True),
    ('f64_to_f32', D_MOVE, F_D, F_S, P_S, True),
]


def in_bad(v, fmt):
    if fmt == F_X:
        return x_bad(v)
    if fmt == F_I:
        return False
    eb, fb = (8, 23) if fmt == F_S else (11, 52)
    return f_nan(v, eb, fb) or f_dnrm(v, eb, fb)


def out_nan(v, fmt):
    if fmt == F_X:
        return x_nan(v)
    if fmt == F_I:
        return False
    eb, fb = (8, 23) if fmt == F_S else (11, 52)
    return f_nan(v, eb, fb)


def gen(name, mopt, level, limit):
    args = [GEN, '-level', str(level), mopt, '-tininessbefore']
    if name.endswith('_to_i32'):
        args.append('-exact')
    args.append(name)
    p = subprocess.Popen(args, stdout=subprocess.PIPE, text=True)
    n = 0
    for line in p.stdout:
        f = line.split()
        if not f:
            continue
        yield [int(t, 16) for t in f]
        n += 1
        if limit and n >= limit:
            break
    p.stdout.close()
    p.kill()
    p.wait()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--level', type=int, default=1)
    ap.add_argument('--only', default=None)
    ap.add_argument('--limit', type=int, default=0,
                    help='at most this many vectors per function and mode')
    a = ap.parse_args()
    if not os.path.exists(GEN):
        sys.exit(f'no {GEN}: run `make testfloat`')

    vecs = []           # (check, mode, inputs, sf result, sf flags)
    skipped = {}
    for chk in CHECKS:
        name, op, fin, fout, prec, mono = chk
        if a.only and a.only not in name:
            continue
        for mopt, mode in MODES.items():
            key = (name, mopt)
            skipped[key] = 0
            for t in gen(name, mopt, a.level, a.limit):
                ins, res, flags = t[:-2], t[-2], t[-1]
                if any(in_bad(v, fin) for v in ins) or out_nan(res, fout) or \
                   (fout == F_X and x_bad(res)):
                    skipped[key] += 1
                    continue
                vecs.append((chk, mopt, mode, ins, res, flags))

    with open(VEC, 'w') as f:
        for i, (chk, mopt, mode, ins, res, flags) in enumerate(vecs):
            name, op, fin, fout, prec, mono = chk
            va = ins[0] if not mono else 0
            vb = ins[-1]
            f.write(f'{i:x} {op:x} {prec:x} {mode:x} 2 {fin:x} {fout:x} {va:x} {vb:x}\n')
    r = subprocess.run(['vvp', '-n', VVP, f'+vec={VEC}', f'+out={OUT}'],
                       capture_output=True, text=True)
    if r.returncode != 0 or 'vectors' not in r.stdout:
        print(r.stdout, r.stderr)
        sys.exit('FAIL: fpu_dp_tb did not run')
    got = {}
    with open(OUT) as f:
        for line in f:
            i, v, fl = (int(t, 16) for t in line.split())
            got[i] = (v, fl)

    bad = {}
    traps = {}
    shown = 0
    for i, (chk, mopt, mode, ins, res, flags) in enumerate(vecs):
        name, op, fin, fout, prec, mono = chk
        key = (name, mopt)
        v, fl = got[i]
        snan, operr, ovfl, unfl, dz, inex = ((fl >> k) & 1 for k in (5, 4, 3, 2, 1, 0))
        why = None
        sign_bit = {F_X: 79, F_S: 31, F_D: 63, F_I: 31}[fout]
        sf_tiny = fout != F_I and ((flags & SF_UNDERFLOW) or
                                   (tiny(res, fout) and (res & ~(1 << sign_bit)) != 0))
        if fout != F_I and (unfl or sf_tiny):
            if not (unfl and sf_tiny):
                why = f'underflow: UNFL {unfl}, SoftFloat tiny {bool(sf_tiny)}'
            else:
                traps[key] = traps.get(key, 0) + 1
                continue
        elif fout != F_I and (ovfl or (flags & SF_OVERFLOW)):
            if not (ovfl and (flags & SF_OVERFLOW)):
                why = f'overflow: OVFL {ovfl}, SoftFloat {bool(flags & SF_OVERFLOW)}'
            else:
                traps[key] = traps.get(key, 0) + 1
                continue
        else:
            gf = ((SF_INVALID if (operr or snan) else 0) | (SF_INFINITE if dz else 0) |
                  (SF_OVERFLOW if ovfl else 0) | (SF_UNDERFLOW if unfl else 0) |
                  (SF_INEXACT if (inex or ovfl) else 0))
            want = res
            if fout == F_I:
                neg_max = (res & 0xFFFFFFFF) == 0x80000000 and not (flags & SF_INVALID)
                if neg_max and operr:
                    # UM 9.7.3.2's "erroneous MC68040 condition".
                    traps[key] = traps.get(key, 0) + 1
                    continue
                if flags & SF_INVALID:
                    want = v
            if fout == F_X:
                # An infinity's integer bit is a don't-care (UM Table 9-5).
                if (want >> 64) & 0x7FFF == 0x7FFF:
                    want &= ~(1 << 63)
                    v &= ~(1 << 63)
            if v != want or gf != flags:
                why = f'want {want:x} {flags:02x} got {v:x} {gf:02x}'
        if why:
            bad[key] = bad.get(key, 0) + 1
            if shown < 20:
                shown += 1
                print(f'    MISMATCH {name} {mopt}: in {" ".join(f"{x:x}" for x in ins)}: {why}')

    total = 0
    for chk in CHECKS:
        name = chk[0]
        if a.only and a.only not in name:
            continue
        for mopt in MODES:
            key = (name, mopt)
            n = sum(1 for x in vecs if x[0][0] == name and x[1] == mopt)
            b = bad.get(key, 0)
            total += b
            st = 'ok' if b == 0 else f'{b} MISMATCHES'
            print(f'  {name:16s} {mopt:12s} {n:7d} compared, {traps.get(key, 0):6d} traps, '
                  f'{skipped[key]:6d} skipped: {st}')
    if total:
        print(f'FAIL: testfloat, {total} mismatches')
        return 1
    print('PASS: testfloat')
    return 0


if __name__ == '__main__':
    sys.exit(main())
