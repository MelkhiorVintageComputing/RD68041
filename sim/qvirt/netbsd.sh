#!/bin/bash
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041
#
# NetBSD/virt68k 11.0 for QEMU's virt machine (M14; doc/qvirt.md).
#
#   sim/qvirt/netbsd.sh fetch   DIR        the media of Inputs/sw/MANIFEST-netbsd
#                                          into DIR/dl, each checked; the kernel
#                                          uncompressed, gftty_cngetc ordered for
#                                          the MC68040 (nbpatch.py): DIR/netbsd-GENERIC
#   sim/qvirt/netbsd.sh disk    DIR QEMU   DIR/sets.img (the sets as one tar,
#                                          sim/qvirt/mksets.py) and the install
#                                          onto DIR/netbsd.img on QEMU's m68040
#                                          (sim/qvirt/netbsd-install.script),
#                                          made read-only
#
# Light jobs (QEMU's TCG): minutes, none of it in `make check`.
set -eu
R=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$R/sim/qvirt
WHAT=${1:-}
DIR=${2:-}
[ -n "$WHAT" ] && [ -n "$DIR" ] || { sed -n '6,16p' "$0" >&2; exit 2; }
mkdir -p "$DIR"

case $WHAT in
fetch)
	mkdir -p "$DIR/dl"
	grep -v '^#' "$R/Inputs/sw/MANIFEST-netbsd" | while read -r sum name url; do
		[ -n "$sum" ] || continue
		f=$DIR/dl/$name
		if [ ! -f "$f" ] || ! echo "$sum  $f" | sha256sum --quiet -c - 2>/dev/null; then
			echo "  netbsd: fetching $name"
			curl -sSfL --retry 3 -o "$f.part" "$url"
			mv "$f.part" "$f"
		fi
		echo "$sum  $f" | sha256sum --quiet -c - || { echo "netbsd: $name does not match its hash" >&2; exit 1; }
	done
	# The kernel, with gftty_cngetc's read ordered after its command
	# (sim/qvirt/nbpatch.py): what both processors run.
	gunzip -c "$DIR/dl/netbsd-GENERIC.gz" > "$DIR/netbsd-GENERIC.orig"
	python3 -I "$HERE/nbpatch.py" "$DIR/netbsd-GENERIC.orig" "$DIR/netbsd-GENERIC.part"
	mv "$DIR/netbsd-GENERIC.part" "$DIR/netbsd-GENERIC"
	;;
disk)
	QEMU=${3:?the QEMU binary}
	python3 -I "$HERE/mksets.py" "$DIR/sets.img" "$DIR/dl/base.tgz" "$DIR/dl/etc.tgz" \
		"$DIR/dl/kern-GENERIC.tgz"
	rm -f "$DIR/netbsd.img" "$DIR/netbsd.img.part"
	truncate -s 1G "$DIR/netbsd.img.part"
	mkdir -p "$DIR/install"
	# The sets first, the target last: QEMU's virtio-mmio slots are filled
	# from the top down, and NetBSD numbers its disks from the bottom up,
	# so the last disk given is ld0.
	python3 "$HERE/qemu-ref.py" --qemu "$QEMU" --dir "$DIR/install" \
		--kernel "$DIR/netbsd-GENERIC" --initrd "$DIR/dl/inst-ramdisk.fs" \
		--disk "$DIR/sets.img" --disk-rw "$DIR/netbsd.img.part" \
		--script "$HERE/netbsd-install.script" --expect INSTALLED \
		--log "$DIR/install/console" --timeout 1800 > "$DIR/install/log" 2>&1 \
		|| { tail -5 "$DIR/install/log"; exit 1; }
	chmod 444 "$DIR/netbsd.img.part"
	mv "$DIR/netbsd.img.part" "$DIR/netbsd.img"
	rm -f "$DIR/sets.img"
	echo "  netbsd: installed $DIR/netbsd.img ($(grep -o 'after [0-9.]* s wall' "$DIR/install/log"))"
	;;
*)
	sed -n '6,16p' "$0" >&2; exit 2
	;;
esac
