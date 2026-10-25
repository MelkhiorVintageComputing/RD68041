#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041
"""NetBSD's sets as one uncompressed tar, to be a raw disk (doc/qvirt.md).

    mksets.py OUT SET.tgz...

The members are copied header and data as they are -- owners, modes, device
nodes, links -- without extracting anything, so no privilege is needed. The
installing guest reads the disk with `tar -xpf /dev/rld1c`. The image is
padded to a whole number of 64 KB.
"""
import sys
import tarfile


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    out = sys.argv[1]
    with tarfile.open(out, "w", format=tarfile.PAX_FORMAT) as t:
        for s in sys.argv[2:]:
            with tarfile.open(s, "r:gz") as i:
                for m in i:
                    t.addfile(m, i.extractfile(m) if m.isreg() else None)
    with open(out, "ab") as f:
        n = f.tell()
        f.write(b"\0" * (-n % 65536))


if __name__ == "__main__":
    main()
