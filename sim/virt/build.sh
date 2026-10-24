#!/bin/sh
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041
#
# Build rd-virt (doc/virt.md), RD68031's sim/virt/build.sh for the MC68040:
#
#   sim/virt/build.sh uae  OUT     the UAE040-only machine (OUT/rdvirt-uae)
#   sim/virt/build.sh rtl  OUT     the RTL under Verilator, with UAE040 for the
#                                  lockstep (OUT/obj/rdvirt)
#
# The Verilator build is a heavy job (CLAUDE.md): run it alone. It is
# incremental, and single-threaded (--threads 1): the design is one clock
# domain small enough that thread hand-offs cost more than they give.
# Knobs from the environment: RTLFILES (the Makefile passes its RTL), FPU (1;
# 0 builds the MC68LC040), TRACE (1: with VCD dumps, --vcd), JOBS (4).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../.." && pwd)
WHAT=$1
OUT=$2
[ -n "$WHAT" ] && [ -n "$OUT" ] || { echo "usage: $0 uae|rtl OUT" >&2; exit 2; }
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
LIB=$TOP/build/uae040/libuae040.a
WRAP=""
for f in mmu_get_word_unaligned mmu_get_long_unaligned mmu_put_word_unaligned mmu_put_long_unaligned \
         sfc_get_long sfc_get_word dfc_put_long dfc_put_word uae_mmu_get_lrmw uae_mmu_put_lrmw; do
	WRAP="$WRAP -Wl,--wrap=$f"
done
SRCS="$HERE/rdvirt.cpp $HERE/machine.cpp $HERE/cpu_uae.cpp"
JOBS=${JOBS:-4}
FPU=${FPU:-1}

case $WHAT in
uae)
	${CXX:-g++} -O2 -g -std=c++17 -Wall -I"$HERE" -I"$TOP/tools/cosim/uae040" \
		-o "$OUT/rdvirt-uae" $SRCS "$LIB" $WRAP -lm
	echo "built $OUT/rdvirt-uae"
	;;
rtl)
	# the RTL's files, in the Makefile's order (its RTL variable)
	[ -n "$RTLFILES" ] || { echo "$0: RTLFILES (the Makefile's RTL) is not set" >&2; exit 2; }
	RTL=""
	for f in $RTLFILES; do RTL="$RTL $TOP/$f"; done
	# the archive is not a dependency Verilator's makefile knows: relink always
	rm -f "$OUT/obj/rdvirt"
	TRACEOPT=""
	[ "${TRACE:-0}" = 1 ] && TRACEOPT="--trace"
	verilator --cc --exe --build --build-jobs "$JOBS" --threads 1 -O3 $TRACEOPT \
		-Wno-fatal -Wno-lint -Wno-style --top-module rd68041_top -GFPU="$FPU" \
		--output-split 20000 --output-split-cfuncs 500 --Mdir "$OUT/obj" -o rdvirt \
		-CFLAGS "-O2 -std=c++17 -DRDVIRT_RTL -DRDVIRT_FPU=$FPU -I$HERE -I$TOP/tools/cosim/uae040" \
		-LDFLAGS "$LIB $WRAP -lm" \
		"$TOP/rtl/rd68041.vlt" "$HERE/public.vlt" $RTL $SRCS "$HERE/cpu_rtl.cpp" \
		> "$OUT/verilator.log" 2>&1 \
		|| { grep -E "%Error|error:" "$OUT/verilator.log" | head -20; exit 1; }
	echo "built $OUT/obj/rdvirt"
	;;
*)
	echo "usage: $0 uae|rtl OUT" >&2; exit 2
	;;
esac
