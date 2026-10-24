#!/bin/bash
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041
#
# Regenerate sim/mame/quadra.patch from the edited build copy of MAME
# (build/mame/src), against the pristine Inputs/ref/mame (RD68031's
# mkpatch.sh). Run after editing a file of sim/mame/patched.lst in the build
# copy, before sim/mame/build.sh mame, which re-applies the patch to fresh
# copies of the same files.
set -eu
R=$(cd "$(dirname "$0")/../.." && pwd)
SRC=${1:-$R/build/mame/src}
cd "$R/Inputs/ref/mame"
{
  for f in $(cat "$R/sim/mame/patched.lst"); do
    diff -u --label "a/$f" --label "b/$f" "$f" "$SRC/$f" || true
  done
} > "$R/sim/mame/quadra.patch"
echo "wrote sim/mame/quadra.patch ($(grep -c '^+++' "$R/sim/mame/quadra.patch") files)"
