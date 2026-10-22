#!/bin/sh
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041
#
# Build the guest for QEMU's m68k `virt` board (M0 spike 5; doc/oracles.md,
# "Linux on QEMU's virt"), RD68031's sim/virt/linux/build.sh for the MC68040:
# Linux 7.2.9 with rd-virt.config applied over allnoconfig, a static BusyBox
# 1.38.0 built for the MC68040, and the initramfs that cpio.list describes, packed by the
# kernel's own gen_init_cpio with every timestamp at 0 so that the image is
# the same byte for byte from one build to the next.
#
#   sim/virt/linux/build.sh [OUT]          (default build/virt/guest)
#
# The sources are the ones Inputs/sw/MANIFEST pins, fetched into OUT/dl (or
# copied from RD68031's download directories when they are there) and checked
# against their sha256. Incremental: a step whose output exists is skipped.
# The kernel build is a heavy job (CLAUDE.md): run it alone, JOBS (4) at most.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../../.." && pwd)
OUT=${1:-$TOP/build/virt/guest}
mkdir -p "$OUT/dl" "$OUT/src"
OUT=$(cd "$OUT" && pwd)
JOBS=${JOBS:-4}
CROSS=m68k-linux-gnu-

# 1. sources
grep -v '^#' "$TOP/Inputs/sw/MANIFEST" | while read -r sum file url; do
	[ -n "$file" ] || continue
	if [ ! -f "$OUT/dl/$file" ]; then
		if [ -f "$TOP/../RD68031/build/spikes/virt/dl/$file" ]; then
			cp "$TOP/../RD68031/build/spikes/virt/dl/$file" "$OUT/dl/$file"
		elif [ -f "$TOP/../RD68031/build/virt/guest/dl/$file" ]; then
			cp "$TOP/../RD68031/build/virt/guest/dl/$file" "$OUT/dl/$file"
		else
			curl -fsSL -o "$OUT/dl/$file.part" "$url" && mv "$OUT/dl/$file.part" "$OUT/dl/$file"
		fi
	fi
	echo "$sum  $OUT/dl/$file" | sha256sum -c --quiet - || { echo "bad checksum: $file" >&2; exit 1; }
done
[ -d "$OUT/src/linux-7.2.9" ] || tar -C "$OUT/src" -xf "$OUT/dl/linux-7.2.9.tar.xz"
[ -d "$OUT/src/busybox-1.38.0" ] || tar -C "$OUT/src" -xf "$OUT/dl/busybox-1.38.0.tar.bz2"

# 2. the kernel, with the build's identity fixed so that it is reproducible
export KBUILD_BUILD_TIMESTAMP="2026-01-01 00:00:00 UTC" KBUILD_BUILD_USER=rd68041 \
	KBUILD_BUILD_HOST=rd-virt KBUILD_BUILD_VERSION=1
K="make -s -C $OUT/src/linux-7.2.9 O=$OUT/linux-build ARCH=m68k CROSS_COMPILE=$CROSS"
if [ ! -f "$OUT/linux-build/vmlinux" ] || [ "$HERE/rd-virt.config" -nt "$OUT/linux-build/vmlinux" ]; then
	mkdir -p "$OUT/linux-build"
	KCONFIG_ALLCONFIG="$HERE/rd-virt.config" $K allnoconfig > "$OUT/kernel-config.log" 2>&1
	grep -q '^CONFIG_M68040=y' "$OUT/linux-build/.config" \
		&& ! grep -q '^CONFIG_M68030=y' "$OUT/linux-build/.config" \
		|| { echo "build.sh: rd-virt.config was not applied" >&2; exit 1; }
	$K -j"$JOBS" vmlinux > "$OUT/kernel-build.log" 2>&1 \
		|| { tail -20 "$OUT/kernel-build.log"; exit 1; }
fi
cp "$OUT/linux-build/vmlinux" "$OUT/vmlinux"

# 3. BusyBox, defconfig, static, for the MC68040 -- without tc, which does not
#    build against the host's current kernel headers (as at M0)
B="make -s -C $OUT/src/busybox-1.38.0 O=$OUT/busybox-build"
if [ ! -f "$OUT/busybox-build/busybox" ]; then
	mkdir -p "$OUT/busybox-build"
	$B defconfig > "$OUT/busybox-build.log" 2>&1
	sed -i -e 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' \
	    -e 's/^CONFIG_CROSS_COMPILER_PREFIX=.*/CONFIG_CROSS_COMPILER_PREFIX="'$CROSS'"/' \
	    -e 's/^CONFIG_EXTRA_CFLAGS=.*/CONFIG_EXTRA_CFLAGS="-mcpu=68040"/' \
	    -e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' \
	    -e 's/^CONFIG_FEATURE_TC_INGRESS=y/# CONFIG_FEATURE_TC_INGRESS is not set/' \
	    "$OUT/busybox-build/.config"
	yes "" | $B oldconfig >> "$OUT/busybox-build.log" 2>&1
	$B -j"$JOBS" >> "$OUT/busybox-build.log" 2>&1 || { tail -20 "$OUT/busybox-build.log"; exit 1; }
fi

# 4. the initramfs
sed -e "s|@BUSYBOX@|$OUT/busybox-build/busybox|" -e "s|@INIT@|$HERE/init|" \
	"$HERE/cpio.list" > "$OUT/cpio.list"
"$OUT/linux-build/usr/gen_init_cpio" -t 0 "$OUT/cpio.list" | gzip -9n > "$OUT/initramfs.cpio.gz"
echo "built $OUT/vmlinux and $OUT/initramfs.cpio.gz"
