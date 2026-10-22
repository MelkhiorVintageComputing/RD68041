#!/bin/bash
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041
#
# Build MAME's second-generation Quadras (macquadra800.cpp: the Quadra 800,
# 650 and 610, the Centris 650 and 610) with MAME's own m68040, for the M0
# spike and, from M14, the core (doc/oracles.md, "MAME's Quadra").
#
#   sim/mame/build.sh [OUT]        MAME with only that driver, from a copy of
#                                  Inputs/ref/mame in OUT/src (Inputs/ is
#                                  immutable and MAME builds in its own
#                                  tree): OUT/src/quadra
#
# OUT defaults to build/mame. A heavy job: run it alone (CLAUDE.md), -j2 (a
# MAME compile unit can take 1-2 GB); the build is stopped if available
# memory falls under 3 GB. About 25 minutes from clean.
#
# SDL2 and GL development headers are needed and are not installed
# system-wide here: SDLPREFIX (OUT/sdlprefix) is a tree of libsdl2-dev,
# libsdl2-ttf-dev, libgl-dev, libegl-dev, libglx-dev and mesa-common-dev
# unpacked without root (apt-get download + dpkg -x), RD68031's recipe. It is
# copied from RD68031's build/mame/sdlprefix when that exists, made otherwise.
# MAME is not patched: the spike found nothing in it to fix.
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$R/build/mame}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
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
cd "$OUT/src" || exit 1
export PKG_CONFIG_PATH=$SDLPREFIX/usr/lib/x86_64-linux-gnu/pkgconfig
export PATH=$SDLPREFIX/usr/bin:$PATH
make REGENIE=1 SUBTARGET=quadra SOURCES=src/mame/apple/macquadra800.cpp NOWERROR=1 NO_OPENGL=1 \
  NO_USE_MIDI=1 NO_USE_PORTAUDIO=1 NO_USE_PULSEAUDIO=1 NO_USE_PIPEWIRE=1 USE_QTDEBUG=0 TOOLS=0 \
  SDL_INSTALL_ROOT=$SDLPREFIX/usr ARCHOPTS="-I$SDLPREFIX/usr/include -I$SDLPREFIX/usr/include/x86_64-linux-gnu" \
  LDOPTS="-L$SDLPREFIX/usr/lib/x86_64-linux-gnu" -j"$JOBS" > "$OUT/build.log" 2>&1 &
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
