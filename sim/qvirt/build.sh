#!/bin/sh
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041
#
# Build rd-qvirt (doc/qvirt.md): the core under Verilator, behind rd-virt's
# RTL socket, as the processor of QEMU's virt machine.
#
#   sim/qvirt/build.sh OUT        OUT/obj/qvirt
#
# The Verilator build is a heavy job (CLAUDE.md): run it alone. Nothing here
# links QEMU, which runs as a separate process. Knobs from the environment:
# RTLFILES (the Makefile passes its RTL), FPU (1; 0 builds the MC68LC040),
# TRACE (1: with VCD dumps, --vcd), JOBS (4).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../.." && pwd)
VIRT=$TOP/sim/virt
OUT=$1
[ -n "$OUT" ] || { echo "usage: $0 OUT" >&2; exit 2; }
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
JOBS=${JOBS:-4}
FPU=${FPU:-1}
[ -n "$RTLFILES" ] || { echo "$0: RTLFILES (the Makefile's RTL) is not set" >&2; exit 2; }
RTL=""
for f in $RTLFILES; do RTL="$RTL $TOP/$f"; done
rm -f "$OUT/obj/qvirt"
TRACEOPT=""
[ "${TRACE:-0}" = 1 ] && TRACEOPT="--trace"
verilator --cc --exe --build --build-jobs "$JOBS" --threads 1 -O3 $TRACEOPT \
	-Wno-fatal -Wno-lint -Wno-style --top-module rd68041_top -GFPU="$FPU" \
	--output-split 20000 --output-split-cfuncs 500 --Mdir "$OUT/obj" -o qvirt \
	-CFLAGS "-O2 -std=c++17 -DRDVIRT_RTL -DRDVIRT_FPU=$FPU -I$HERE -I$VIRT" \
	"$TOP/rtl/rd68041.vlt" "$VIRT/public.vlt" $RTL \
	"$HERE/qvirt.cpp" "$HERE/qemu_machine.cpp" "$VIRT/cpu_rtl.cpp" \
	> "$OUT/verilator.log" 2>&1 \
	|| { grep -E "%Error|error:" "$OUT/verilator.log" | head -20; exit 1; }
echo "built $OUT/obj/qvirt"
