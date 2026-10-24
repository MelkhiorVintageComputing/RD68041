#!/bin/bash
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041
#
# Boot a Quadra in MAME, headless, with no disk, for SECONDS of emulated time
# (M0 spike 4, `make quadra-m68040`; doc/oracles.md, "MAME's Quadra").
#
#   sim/mame/quadra.sh MACHINE DIR SECONDS
#
# MACHINE is macqd650 (the Quadra 650, MAME's m68040) or macct650 (the
# Centris 650, its 68LC040), both of macquadra800.cpp, both from the one ROM
# the user supplied. DIR is made afresh -- no PRAM survives from an earlier
# run. sim/mame/quadra.lua saves the screen every QUADRA_STEP (1) emulated
# seconds as DIR/snap/NNNN.png and logs the PC; the sound goes to
# DIR/sound.wav. Then:
#   DIR/samples.txt   per sample: emulated time, PC, SR, the sha256 of the
#                     screen's pixels (RGB)
#   DIR/mame.out      MAME's output
# Environment: MAMEDIR (build/mame), MAMEARGS (more of MAME's options).
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
M=$1; D=$2; S=$3
MAMEDIR=${MAMEDIR:-$R/build/mame}
rm -rf "$D"; mkdir -p "$D"; cd "$D" || exit 1
t0=$(date +%s.%N)
QUADRA_SECONDS=$S QUADRA_STEP=${QUADRA_STEP:-1} \
  "$MAMEDIR/src/quadra" "$M" -rompath "$MAMEDIR/roms" \
  -video none -sound none -wavwrite sound.wav -nothrottle -skip_gameinfo \
  -snapshot_directory "$D/snap" -nvram_directory "$D/nvram" -cfg_directory "$D/cfg" \
  -state_directory "$D/sta" -diff_directory "$D/diff" -homepath "$D" \
  -autoboot_script "$R/sim/mame/quadra.lua" -autoboot_delay 0 ${MAMEARGS:-} \
  > mame.out 2>&1
rc=$?
t1=$(date +%s.%N)
# The screen's hash is of its pixels, not of the PNG: MAME writes the
# machine's name into the file, and the core's machines are not MAME's own.
grep '^sample ' mame.out | while read -r _ n _ t _ pc _ sr; do
  f=$(printf 'snap/%04d.png' "$n")
  h=$( [ -f "$f" ] && python3 -I -c 'import sys, hashlib; from PIL import Image
print(hashlib.sha256(Image.open(sys.argv[1]).convert("RGB").tobytes()).hexdigest()[:16])' "$f" || echo none)
  echo "$t $pc $sr $h"
done > samples.txt
echo "wall $(echo "$t1 - $t0" | bc) s, MAME exit $rc" >> mame.out
exit $rc
