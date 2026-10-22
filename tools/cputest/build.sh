#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041
#
# Build WinUAE's cputestgen (the 680x0 test-vector generator) on Linux, out of
# tree: Inputs/ref/winuae is copied, gencpu.cpp is patched to CPU_TESTER 1 in the
# copy, the test cores are generated and compiled, and od-win32/unicode.cpp is
# replaced by compat/ua_stub.cpp.  The file list follows
# od-win32/cputester/cputester.vcxproj.
#
#   tools/cputest/build.sh [OUT]     (default OUT = build/cputest/gen)
#
# Incremental: the source copy is made once, gencpu.cpp is patched only if it
# is not already, and only stale objects are recompiled.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../.." && pwd)
OUT=${1:-$TOP/build/cputest/gen}
JOBS=${JOBS:-3}
W=$TOP/Inputs/ref/winuae
mkdir -p "$OUT/obj" "$OUT/compat/machdep"
OUT=$(cd "$OUT" && pwd)
if [ ! -d "$OUT/src" ]; then
	mkdir -p "$OUT/src"
	(cd "$W" && tar cf - --exclude=.git .) | (cd "$OUT/src" && tar xf -)
fi
for f in "$HERE/compat/cputest_compat.h" "$HERE/compat/ua_stub.cpp"; do
	cmp -s "$f" "$OUT/compat/$(basename "$f")" || cp "$f" "$OUT/compat/"
done
# cputest.h declares 'int cctrue(int)': use the Windows machdep header (extern
# cctrue, defined in newcpu_common.cpp) rather than od-unix's static inline one.
cmp -s "$W/od-win32/machdep/m68k.h" "$OUT/compat/machdep/m68k.h" \
  || cp "$W/od-win32/machdep/m68k.h" "$OUT/compat/machdep/m68k.h"

cd "$OUT/src"
grep -q '^#define CPU_TESTER 1$' gencpu.cpp \
  || sed -i 's/^#define CPU_TESTER 0$/#define CPU_TESTER 1/' gencpu.cpp
grep -q '^#define CPU_TESTER 1$' gencpu.cpp
CXX=${CXX:-g++}
INC="-I. -Iinclude -Iod-unix -Iod-unix/include"
if [ ! -f cpustbl_test.cpp ] || [ gencpu.cpp -nt cpustbl_test.cpp ]; then
	$CXX -std=gnu++17 -O1 -w -DUAE_TARGET_UNIX=1 -include ../compat/cputest_compat.h -I../compat $INC \
		-o ../gencpu_test gencpu.cpp readcpu.cpp cpudefs.cpp ../compat/ua_stub.cpp
	../gencpu_test
fi

cd "$OUT"
DEF="-DUAE_TARGET_UNIX=1 -DUAE_NOGUI=1 -DCPU_TESTER -DCPUEMU_90 -DCPUEMU_91 -DCPUEMU_92 -DCPUEMU_93 -DCPUEMU_94 -DCPUEMU_95"
FLAGS="-std=gnu++17 -w $DEF -include compat/cputest_compat.h -Icompat -Isrc/od-unix -Isrc/od-unix/include -Isrc -Isrc/include"
SRCS="src/cpudefs.cpp src/cpustbl_test.cpp src/cputest.cpp src/cputest_support.cpp src/disasm.cpp
      src/fpp.cpp src/fpp_softfloat.cpp src/ini.cpp src/newcpu_common.cpp src/readcpu.cpp
      src/softfloat/softfloat.cpp src/softfloat/softfloat_decimal.cpp src/softfloat/softfloat_fpsp.cpp
      compat/ua_stub.cpp"
# the generated test cores are large: -O0 keeps each compile at ~300 MB
for f in $SRCS; do echo "$f -O1"; done > obj/list
for f in src/cpuemu_9?_test.cpp; do echo "$f -O0"; done >> obj/list
pids=""; n=0; fail=0
while read -r f o; do
	obj=obj/$(basename "$f" .cpp).o
	if [ ! -f "$obj" ] || [ "$f" -nt "$obj" ]; then
		( $CXX $o $FLAGS -c "$f" -o "$obj" || { echo "FAILED $f" >&2; exit 1; } ) &
		pids="$pids $!"; n=$((n+1))
	fi
	if [ $n -ge "$JOBS" ]; then for p in $pids; do wait $p || fail=1; done; pids=""; n=0; fi
done < obj/list
for p in $pids; do wait $p || fail=1; done
[ $fail = 0 ]
$CXX -o cputestgen obj/*.o -lz -lm
echo "built $OUT/cputestgen"
