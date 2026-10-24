#!/bin/bash
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041
#
# Build MAME's second-generation Quadras (macquadra800.cpp: the Quadra 800,
# 650 and 610, the Centris 650 and 610) with MAME's own m68040 and, from M14,
# the core in two more machines (doc/oracles.md, "MAME's Quadra").
#
#   sim/mame/build.sh mame [OUT]   MAME with only that driver, from a copy of
#                                  Inputs/ref/mame in OUT/src (Inputs/ is
#                                  immutable and MAME builds in its own
#                                  tree), with sim/mame/quadra.patch and the
#                                  rd68041_device added: OUT/src/quadra
#   sim/mame/build.sh vlt OUT      the core under Verilator with its bus
#                                  agent, the shared object that device loads:
#                                  OUT/rd68041_vlt.so (FPU=0: the MC68LC040)
#
# OUT defaults to build/mame. Both are heavy jobs: run each alone (CLAUDE.md).
# MAME: -j2 (a compile unit can take 1-2 GB), the build stopped if available
# memory falls under 3 GB; about 25 minutes from clean. Verilator: -j4.
#
# SDL2 and GL development headers are needed and are not installed
# system-wide here: SDLPREFIX (OUT/sdlprefix) is a tree of libsdl2-dev,
# libsdl2-ttf-dev, libgl-dev, libegl-dev, libglx-dev and mesa-common-dev
# unpacked without root (apt-get download + dpkg -x), RD68031's recipe. It is
# copied from RD68031's build/mame/sdlprefix when that exists, made otherwise.
#
# The patch (sim/mame/patched.lst lists its files; sim/mame/mkpatch.sh makes
# it from an edited build copy) adds the machines macqd650rd and macct650rd
# and lets the IOSB take a CPU that is not MAME's 68000 family. Knobs: JOBS,
# FPU (vlt: 1), RTLFILES (vlt: the Makefile's RTL).
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$R/sim/mame
WHAT=${1:-}
OUT=${2:-$R/build/mame}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

# Copy $1 to $2 only if it differs, so that make sees no change otherwise.
install_if_changed() {
  cmp -s "$1" "$2" || cp "$1" "$2"
}

case $WHAT in
mame)
  JOBS=${JOBS:-2}
  SDLPREFIX=${SDLPREFIX:-$OUT/sdlprefix}
  if [ ! -d "$SDLPREFIX/usr/include/SDL2" ]; then
    if [ -d "$R/../RD68031/build/mame/sdlprefix/usr/include/SDL2" ]; then
      cp -a "$R/../RD68031/build/mame/sdlprefix" "$SDLPREFIX"
    else
      mkdir -p "$OUT/debs" "$SDLPREFIX"
      (cd "$OUT/debs" && apt-get download libsdl2-dev libsdl2-ttf-dev libgl-dev libegl-dev \
         libglx-dev mesa-common-dev > /dev/null) || { echo "build.sh: apt-get download failed" >&2; exit 1; }
      for d in "$OUT"/debs/*.deb; do dpkg -x "$d" "$SDLPREFIX"; done
    fi
  fi
  [ -d "$OUT/src" ] || rsync -a --exclude .git "$R/Inputs/ref/mame/" "$OUT/src/"
  # The patched files, from the pristine sources.
  T=$(mktemp -d)
  for f in $(cat "$HERE/patched.lst"); do
    mkdir -p "$T/$(dirname "$f")"; cp "$R/Inputs/ref/mame/$f" "$T/$f"
  done
  (cd "$T" && patch -s -p1 < "$HERE/quadra.patch") || { rm -rf "$T"; exit 1; }
  for f in $(cat "$HERE/patched.lst"); do
    install_if_changed "$T/$f" "$OUT/src/$f"
  done
  rm -rf "$T"
  # The device, beside the driver: MAME's makedep picks rd68041.cpp up from
  # the driver's #include. rd68041_vlt.cpp is the shared object's, never
  # compiled into MAME.
  for f in rd68041.h rd68041.cpp rd68041_vlt.h; do
    install_if_changed "$HERE/$f" "$OUT/src/src/mame/apple/$f"
  done
  cd "$OUT/src" || exit 1
  export PKG_CONFIG_PATH=$SDLPREFIX/usr/lib/x86_64-linux-gnu/pkgconfig
  export PATH=$SDLPREFIX/usr/bin:$PATH
  make REGENIE=1 SUBTARGET=quadra SOURCES=src/mame/apple/macquadra800.cpp NOWERROR=1 NO_OPENGL=1 \
    NO_USE_MIDI=1 NO_USE_PORTAUDIO=1 NO_USE_PULSEAUDIO=1 NO_USE_PIPEWIRE=1 USE_QTDEBUG=0 TOOLS=0 \
    SDL_INSTALL_ROOT=$SDLPREFIX/usr ARCHOPTS="-I$SDLPREFIX/usr/include -I$SDLPREFIX/usr/include/x86_64-linux-gnu" \
    LDOPTS="-L$SDLPREFIX/usr/lib/x86_64-linux-gnu -ldl" -j"$JOBS" > "$OUT/build.log" 2>&1 &
  MK=$!
  while kill -0 $MK 2>/dev/null; do
    a=$(free -m | awk '/Mem:/{print $7}')
    if [ "$a" -lt 3000 ]; then
      echo "build.sh: only ${a} MB available, stopping the MAME build" >&2
      kill -TERM -- $MK 2>/dev/null; pkill -TERM -P $MK
    fi
    sleep 5
  done
  wait $MK; rc=$?
  [ $rc -eq 0 ] || { grep -E "error|Error" "$OUT/build.log" | head -20; exit $rc; }
  echo "built $OUT/src/quadra"
  ;;
vlt)
  JOBS=${JOBS:-4}
  FPU=${FPU:-1}
  [ -n "${RTLFILES:-}" ] || { echo "$0: RTLFILES (the Makefile's RTL) is not set" >&2; exit 2; }
  RTL=""
  for f in $RTLFILES; do RTL="$RTL $R/$f"; done
  rm -f "$OUT/rd68041_vlt.so"
  # public.vlt is rd-virt's: the registers and the boundary signals.
  verilator --cc --exe --build --build-jobs "$JOBS" --threads 1 -O3 \
    -Wno-fatal -Wno-lint -Wno-style --top-module rd68041_top -GFPU="$FPU" \
    --output-split 20000 --output-split-cfuncs 500 --Mdir "$OUT/obj" -o ../rd68041_vlt.so \
    -CFLAGS "-O2 -fPIC -std=c++17 -DRDVIRT_FPU=$FPU -I$HERE" -LDFLAGS "-shared -fPIC" \
    "$R/rtl/rd68041.vlt" "$R/sim/virt/public.vlt" $RTL "$HERE/rd68041_vlt.cpp" \
    > "$OUT/vlt.log" 2>&1 \
    || { grep -E "%Error|error:" "$OUT/vlt.log" | head -20; exit 1; }
  echo "built $OUT/rd68041_vlt.so"
  ;;
*)
  echo "usage: $0 mame|vlt [OUT]" >&2; exit 2
  ;;
esac
