#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041
#
# Build QEMU 11.1.2 (Inputs/ref/qemu) for the m68k system target, with TCG
# plugins, and the qemu040 trace plugin against it (doc/oracles.md, "QEMU").
#
#   tools/cosim/qemu040/build.sh [OUT]     (default OUT = build/qemu)
#
# The tree is exported (git archive, so nothing is written under Inputs/)
# into OUT/src and configured there with an out-of-tree build directory,
# OUT/obj, installed into OUT/inst. Minimal features: m68k-softmmu only, no
# UI, no docs, only the downloads 2b needs. Incremental: a configured tree is not
# configured again, and ninja
# rebuilds only what changed.
#
# A heavy job (CLAUDE.md): run it alone, JOBS (4) at most. About 2,500
# compile steps, 10 minutes at -j4 from clean.
#
# ninja is not installed on this host: the first one found of $NINJA, PATH,
# OUT/tools/ninja, or RD68031's spike copy (../RD68031/build/spikes/virt/
# tools/bin/ninja, copied here, never run in place) is used.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../../.." && pwd)
OUT=${1:-$TOP/build/qemu}
JOBS=${JOBS:-4}
Q=$TOP/Inputs/ref/qemu
mkdir -p "$OUT/tools"
OUT=$(cd "$OUT" && pwd)

# 1. ninja
if [ -z "$NINJA" ]; then
	if command -v ninja > /dev/null 2>&1; then
		NINJA=$(command -v ninja)
	elif [ -x "$OUT/tools/ninja" ]; then
		NINJA=$OUT/tools/ninja
	elif [ -x "$TOP/../RD68031/build/spikes/virt/tools/bin/ninja" ]; then
		cp "$TOP/../RD68031/build/spikes/virt/tools/bin/ninja" "$OUT/tools/ninja"
		NINJA=$OUT/tools/ninja
	else
		echo "build.sh: no ninja (set NINJA=)" >&2
		exit 1
	fi
fi
export PATH="$(dirname "$NINJA"):$PATH"

# 2. the source, exported once
if [ ! -f "$OUT/src/VERSION" ]; then
	rm -rf "$OUT/src"
	mkdir -p "$OUT/src"
	git -C "$Q" archive --format=tar HEAD | tar -x -C "$OUT/src"
fi
echo "qemu: $(cat "$OUT/src/VERSION") from $(git -C "$Q" describe --tags 2>/dev/null)"

# 2b. configure insists on keycodemapdb (a subproject that a git checkout
#     fetches and a release tarball carries). The release's own subprojects
#     are taken from RD68031's unpacked qemu-11.1.2 tarball when it is there
#     (copied, never used in place); otherwise meson downloads them into the
#     copy. Downloads stay enabled all the same: configure's python venv
#     wants `wheel`, which this host's python lacks, and fetches it from PyPI
#     into OUT/obj/pyvenv.
DOWNLOAD=--enable-download
if [ ! -f "$OUT/src/subprojects/keycodemapdb/README" ]; then
	T=$TOP/../RD68031/build/spikes/virt/src/qemu/qemu-$(cat "$OUT/src/VERSION")/subprojects
	if [ -f "$T/keycodemapdb/README" ]; then
		for d in keycodemapdb dtc berkeley-softfloat-3 berkeley-testfloat-3; do
			if [ -d "$T/$d" ] && [ ! -d "$OUT/src/subprojects/$d" ]; then
				cp -a "$T/$d" "$OUT/src/subprojects/$d"
			fi
		done
	fi
fi

# 3. configure, once
if [ ! -f "$OUT/obj/build.ninja" ]; then
	mkdir -p "$OUT/obj"
	cd "$OUT/obj"
	"$OUT/src/configure" --prefix="$OUT/inst" --target-list=m68k-softmmu \
		--enable-plugins $DOWNLOAD --disable-docs --disable-werror \
		--disable-gtk --disable-sdl --disable-opengl --disable-vnc \
		--disable-slirp --disable-curses --disable-spice --disable-libusb \
		--disable-usb-redir --disable-tools --disable-guest-agent \
		> "$OUT/configure.log" 2>&1 || { tail -30 "$OUT/configure.log"; exit 1; }
fi

# 4. build and install
cd "$OUT/obj"
"$NINJA" -j"$JOBS" > "$OUT/ninja.log" 2>&1 || { tail -30 "$OUT/ninja.log"; exit 1; }
"$NINJA" install > "$OUT/install.log" 2>&1 || { tail -30 "$OUT/install.log"; exit 1; }
test -x "$OUT/inst/bin/qemu-system-m68k"
echo "built $OUT/inst/bin/qemu-system-m68k"
