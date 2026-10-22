#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041
#
# Build the UAE040 oracle: Hatari's copy of the WinUAE CPU core (src/cpu),
# copied out of Inputs/ (never modified in place), patched in the copy, and
# archived with uae040_glue.c into libuae040.a. The front-ends are linked
# against it by the Makefile, with its UAE040 link flags (OLDFLAGS040).
#
#   tools/cosim/uae040/build.sh [OUT]      (default OUT = build/uae040)
#
# It is RD68031's tools/cosim/uae030/build.sh retargeted at the 68040 MMU
# core (op_smalltbl_31, cpuemu_31.c). Incremental: the copy keeps the
# pristine files' timestamps and a patched file is only replaced when its
# content changed, so a second run recompiles nothing.
#
# Memory note: the generated cpuemu_*.c are huge; they are compiled at -O0
# (only cpuemu_31.c, the core actually used, at -O1) and at most JOBS
# (default 4) at a time -- about 300 MB a compile.
#
# The patches only add bookkeeping -- flags saying what a physical access is
# for, and calls into the glue -- and turn off the host-side page caches.
# None changes what the core computes. Each is checked after it is applied.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../../.." && pwd)
OUT=${1:-$TOP/build/uae040}
JOBS=${JOBS:-4}
H=$TOP/Inputs/ref/hatari/src
CC=${CC:-gcc}

mkdir -p "$OUT/gen" "$OUT/obj" "$OUT/stubinc" "$OUT/cpu"
OUT=$(cd "$OUT" && pwd)

fail() { echo "patch failed: $*" >&2; exit 1; }

# 1. a staged copy of the core, patched, then synced into $OUT/cpu file by file
STAGE=$OUT/stage
rm -rf "$STAGE"
cp -rp "$H/cpu" "$STAGE"
cd "$STAGE"

# 1a. no host-side page caches in front of the ATC: every access goes through
#     the emulated ATC (MMU_ICACHE, the third one, is already off).
sed -i 's/^#define MMU_IPAGECACHE 1$/#define MMU_IPAGECACHE 0/; s/^#define MMU_DPAGECACHE 1$/#define MMU_DPAGECACHE 0/' cpummu.h
grep -q '^#define MMU_IPAGECACHE 0$' cpummu.h && grep -q '^#define MMU_DPAGECACHE 0$' cpummu.h \
  && grep -q '^#define MMU_ICACHE 0$' cpummu.h || fail "page caches"

# 1b. the access routines of the 68040 MMU (cpummu.h): publish the function
#     code of each access (uae040_bus_fc), and bracket the physical access of
#     each operand with uae040_op_begin/uae040_op_end, with its logical address,
#     so that the glue sees every operand whether or not the data cache
#     satisfies it. MOVES (sfc_/dfc_ routines) is told apart by uae040_moves
#     (1e), the locked read-modify-write routines by uae040_locked (1e).
awk '
BEGIN { m = "" }
/^static ALWAYS_INLINE uae_u32 mmu_get_ilong\(/ && !decl {
	print "extern int uae040_bus_fc, uae040_moves;"
	print "extern void uae040_op_begin(uae_u32 la, uae_u32 pa, int size, int write, uae_u32 v);"
	print "extern void uae040_op_end(uae_u32 v);"
	decl = 1
}
/^static ALWAYS_INLINE / {
	m = ""
	if ($0 ~ / mmu_get_i(long|word)\(/) m = "i"
	else if ($0 ~ / mmu_get_(long|word|byte)\(/ || $0 ~ / mmu_put_(long|word|byte)\(/) m = "d"
	else if ($0 ~ / mmu_get_user_(long|word|byte)\(/) m = "u"
	else if ($0 ~ / mmu_put_user_(long|word|byte)\(/) m = "U"
}
m == "i" && /^\tmmu_cache_state = cache_default_ins;$/ {
	print; print "\tuae040_bus_fc = regs.s ? 6 : 2;"; ni++; next
}
m != "" && m != "i" && /^\tmmu_cache_state = cache_default_data;$/ {
	print
	if (m == "d") fc = "(regs.s ? 4 : 0) | (data ? 1 : 2)"
	else if (m == "u") fc = "uae040_moves ? (int)regs.sfc : ((super ? 4 : 0) | 1)"
	else fc = "uae040_moves ? (int)regs.dfc : ((super ? 4 : 0) | 1)"
	print "\tuaecptr uae040_la = addr; uae040_bus_fc = " fc ";"
	nd++; next
}
m != "" && m != "i" && match($0, /^\treturn x_phys_get_(long|word|byte)\(addr\);$/) {
	s = $0; sub(/^\treturn /, "", s); sub(/;$/, "", s)
	n = (s ~ /long/) ? 4 : (s ~ /word/) ? 2 : 1
	print "\t{ uae040_op_begin(uae040_la, addr, " n ", 0, 0); uae_u32 uae040_v = " s "; uae040_op_end(uae040_v); return uae040_v; }"
	nr++; next
}
m != "" && m != "i" && match($0, /^\tx_phys_put_(long|word|byte)\(addr, val\);$/) {
	s = $0; sub(/^\t/, "", s); sub(/;$/, "", s)
	n = (s ~ /long/) ? 4 : (s ~ /word/) ? 2 : 1
	print "\tuae040_op_begin(uae040_la, addr, " n ", 1, val); " s "; uae040_op_end(val);"
	nw++; next
}
{ print }
END { if (ni != 2 || nd != 12 || nr != 6 || nw != 6 || !decl) { printf "cpummu.h: %d %d %d %d\n", ni, nd, nr, nw > "/dev/stderr"; exit 1 } }
' cpummu.h > cpummu.h.new || fail "cpummu.h access routines"
mv cpummu.h.new cpummu.h

# 1c. table searches (cpummu.c): flag descriptor accesses (uae040_bus_walk),
#     and say what each search translates for -- program or data
#     (uae040_walk_data), and whether PTEST started it (uae040_walk_insn).
sed -i '/^static uae_u32 desc_get_long(uaecptr addr)$/,/^}$/s/^\treturn x_phys_get_long(addr);$/\tuae040_bus_walk = 1; uae_u32 v = x_phys_get_long(addr); uae040_bus_walk = 0; return v;/' cpummu.c
sed -i '/^static void desc_put_long(uaecptr addr, uae_u32 v)$/,/^}$/s/^\tx_phys_put_long(addr, v);$/\tuae040_bus_walk = 1; x_phys_put_long(addr, v); uae040_bus_walk = 0;/' cpummu.c
sed -i '/^uaecptr mmu_translate(uaecptr addr, uae_u32 val, bool super, bool data, bool write, int size)$/,/^}$/s/^\tuae_u32 status060 = 0;$/&\n\tuae040_walk_data = data; uae040_walk_super = super;/' cpummu.c
sed -i 's/^\t\t\tregs.mmusr = mmu_fill_atc(addr, super, tag, write, &mmu_atc_array\[data\]\[index\]\[way\], &status060);$/\t\t\tuae040_walk_data = data; uae040_walk_super = super; uae040_walk_insn = 1;\n&\n\t\t\tuae040_walk_insn = 0;/' cpummu.c
# 1d. MOVE16 (cpummu.c): flag its line transfer, and report its four long
#     words as operands.
sed -i '/^void mmu_get_move16(uaecptr addr, uae_u32 \*v, bool data, int size)$/,/^}$/{
s/^\taddr &= ~15;$/&\n\tuaecptr uae040_la = addr; uae040_bus_fc = super ? 5 : 1;/
s/^\t\tv\[i\] = x_phys_get_long(addr + i \* 4);$/\t\tuae040_bus_move16 = 1; uae040_op_begin(uae040_la + i * 4, addr + i * 4, 4, 0, 0); v[i] = x_phys_get_long(addr + i * 4); uae040_op_end(v[i]); uae040_bus_move16 = 0;/
}' cpummu.c
sed -i '/^void mmu_put_move16(uaecptr addr, uae_u32 \*val, bool data, int size)$/,/^}$/{
s/^\taddr &= ~15;$/&\n\tuaecptr uae040_la = addr; uae040_bus_fc = super ? 5 : 1;/
s/^\t\tx_phys_put_long(addr + i \* 4, val\[i\]);$/\t\tuae040_bus_move16 = 1; uae040_op_begin(uae040_la + i * 4, addr + i * 4, 4, 1, val[i]); x_phys_put_long(addr + i * 4, val[i]); uae040_op_end(val[i]); uae040_bus_move16 = 0;/
}' cpummu.c
# 1e. MOVES and the locked read-modify-write cycles, made visible.
sed -i 's/^\(\t*\)ismoves = true;$/\1ismoves = true; uae040_moves = 1;/; s/^\(\t*\)ismoves = false;$/\1ismoves = false; uae040_moves = 0;/' cpummu.c
sed -i 's/^\(\t*\)locked_rmw_cycle = true;$/\1locked_rmw_cycle = true; uae040_locked = 1;/; s/^\(\t*\)locked_rmw_cycle = false;$/\1locked_rmw_cycle = false; uae040_locked = 0;/' cpummu.c
sed -i '0,/^#include "cpummu.h"$/s//#include "cpummu.h"\nextern int uae040_bus_walk, uae040_bus_move16, uae040_walk_data, uae040_walk_super, uae040_walk_insn, uae040_locked;/' cpummu.c
grep -q 'uae040_bus_walk = 1; uae_u32 v = x_phys_get_long' cpummu.c \
  && grep -q 'uae040_bus_walk = 1; x_phys_put_long(addr, v)' cpummu.c \
  && [ "$(grep -c 'uae040_walk_data = data; uae040_walk_super = super;' cpummu.c)" = 2 ] \
  && grep -q '^			uae040_walk_insn = 0;$' cpummu.c \
  && [ "$(grep -c 'uae040_bus_move16 = 1; uae040_op_begin' cpummu.c)" = 2 ] \
  && [ "$(grep -c 'uaecptr uae040_la = addr; uae040_bus_fc = super ? 5 : 1;' cpummu.c)" = 2 ] \
  && [ "$(grep -c 'ismoves = true; uae040_moves = 1;' cpummu.c)" -ge 6 ] \
  && [ "$(grep -c 'locked_rmw_cycle = true; uae040_locked = 1;' cpummu.c)" -ge 2 ] \
  && grep -q '^extern int uae040_bus_walk' cpummu.c || fail "cpummu.c"

# 1f. the 68040 data cache (newcpu.c): flag a dirty line's write-back
#     (uae040_bus_push) and a line fill (uae040_bus_fill).
sed -i '/^static void dcache040_push_line(int index, int line, bool writethrough, bool invalidate)$/,/^}$/s/^\t\t\t\tdcache_lput(addr + i \* 4, c->data\[line\]\[i\]);$/\t\t\t\tuae040_bus_push++; dcache_lput(addr + i * 4, c->data[line][i]); uae040_bus_push--;/' newcpu.c
sed -i '/^static int dcache040_fill_line(int index, uae_u32 tag, uaecptr addr)$/,/^}$/{
s/^\tc->data\[line\]\[0\] = dcache_lget(addr + 0);$/\tuae040_bus_fill = 1;\n&/
s/^\tc->data\[line\]\[3\] = dcache_lget(addr + 12);$/&\n\tuae040_bus_fill = 0;/
}' newcpu.c
# 1g. the per-instruction hook, at the top of the 68040 MMU run loop, and
#     (as in RD68031's 1d) the flags the loop keeps across a longjmp made
#     volatile: assigned after the setjmp, a non-volatile local is
#     indeterminate after the longjmp (C11 7.13.2.1).
sed -i '/^static void m68k_run_mmu040 (void)$/,/^}$/{
s/^\tstruct flag_struct f;$/\tvolatile struct flag_struct f;/
s/^\t\t\t\tf.cznv = regflags.cznv;$/\t\t\t\tuae040_insn_boundary();\n&/
}' newcpu.c
sed -i '0,/^#include "cpummu030.h"$/s//#include "cpummu030.h"\nextern void uae040_insn_boundary(void);\nextern int uae040_bus_push, uae040_bus_fill;/' newcpu.c
grep -q 'uae040_bus_push++; dcache_lput' newcpu.c && grep -q '^	uae040_bus_fill = 1;$' newcpu.c \
  && grep -q '^	uae040_bus_fill = 0;$' newcpu.c \
  && [ "$(grep -c '^				uae040_insn_boundary();$' newcpu.c)" = 1 ] \
  && grep -q '^extern void uae040_insn_boundary' newcpu.c || fail "newcpu.c"

cd "$OUT"
( cd "$STAGE" && find . -type f ) | while read -r f; do
	if ! cmp -s "$STAGE/$f" "$OUT/cpu/$f"; then
		mkdir -p "$(dirname "$OUT/cpu/$f")"
		cp -p "$STAGE/$f" "$OUT/cpu/$f"
	fi
done
rm -rf "$STAGE"

# 2. minimal config.h for Hatari's headers
cat > "$OUT/stubinc/config.h.new" <<'EOF'
#define HAVE_STRINGS_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_UTIME_H 1
#define HAVE_BYTESWAP_H 1
#define HAVE_BSWAP_16 1
#define HAVE_BSWAP_32 1
#define HAVE_GETTIMEOFDAY 1
#define HAVE_NANOSLEEP 1
#define BIN2DATADIR "."
EOF
cmp -s "$OUT/stubinc/config.h.new" "$OUT/stubinc/config.h" \
  || mv "$OUT/stubinc/config.h.new" "$OUT/stubinc/config.h"
rm -f "$OUT/stubinc/config.h.new"

# 3. generators -> cpudefs.c, cpuemu_*.c, cpustbl.c, cputbl.h
cd "$OUT/gen"
if [ ! -f cpustbl.c ] || [ "$OUT/cpu/gencpu.c" -nt cpustbl.c ] || [ "$OUT/cpu/table68k" -nt cpustbl.c ]; then
	$CC -O1 -I"$OUT/cpu" -I"$H/includes" -o build68k "$OUT/cpu/build68k.c" "$OUT/cpu/writelog.c"
	./build68k < "$OUT/cpu/table68k" > cpudefs.c
	$CC -O1 -I"$OUT/cpu" -I. -I"$H/includes" -o gencpu "$OUT/cpu/gencpu.c" "$OUT/cpu/readcpu.c" cpudefs.c
	./gencpu
fi

# 4. compile. Every object depends on the patched headers too: cpummu.h is
#    included by the generated cores.
cd "$OUT"
INC="-Istubinc -Icpu -Igen -I$H/includes -I$H/debug -I$H/falcon -I$H -Icpu/softfloat -I$HERE"
CF="-g -fwrapv -w -std=gnu99"
CORE="cpu/cpummu.c cpu/cpummu030.c cpu/debug.c cpu/disasm.c cpu/newcpu_common.c cpu/newcpu.c
      cpu/readcpu.c cpu/writelog.c cpu/fpp.c cpu/fpp_native.c cpu/fpp_softfloat.c
      cpu/softfloat/softfloat.c cpu/softfloat/softfloat_decimal.c cpu/softfloat/softfloat_fpsp.c
      cpu/machdep/m68k.c gen/cpudefs.c gen/cpustbl.c $HERE/uae040_glue.c"
compile() { # src opt
	o=obj/$(basename "$1" .c).o
	if [ ! -f "$o" ] || [ "$1" -nt "$o" ] || [ "$HERE/uae040.h" -nt "$o" ] || [ cpu/cpummu.h -nt "$o" ]; then
		$CC $2 $CF $INC -c "$1" -o "$o" || { echo "FAILED $1" >&2; return 1; }
	fi
}
for f in $CORE; do echo "$f -O2"; done > obj/list
for f in gen/cpuemu_*.c; do
	case $f in *cpuemu_31.c) echo "$f -O1";; *) echo "$f -O0";; esac
done >> obj/list
# simple job pool
pids=""; n=0; fail=0
while read -r f o; do
	compile "$f" "$o" & pids="$pids $!"; n=$((n+1))
	if [ $n -ge "$JOBS" ]; then for p in $pids; do wait $p || fail=1; done; pids=""; n=0; fi
done < obj/list
for p in $pids; do wait $p || fail=1; done
[ $fail = 0 ] || exit 1
rm -f libuae040.a.new
ar rcs libuae040.a.new obj/*.o
mv libuae040.a.new libuae040.a
echo "built $OUT/libuae040.a"
