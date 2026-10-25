#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041
"""The harness's copy of NetBSD/virt68k 11.0's GENERIC (doc/qvirt.md, "A
guest that relies on QEMU's MMIO").

    nbpatch.py IN OUT

gftty_cngetc, the console's polled input (the kernel's root-device, dump,
file-system and init-path questions), starts goldfish-tty's READ_BUFFER --
the device writes the byte into the caller's stack slot by DMA -- and reads
the slot two instructions later:

    moveq   #3,%d0
    movel   %d0,%a0@        | CMD = READ_BUFFER
    clrl    %d0
    moveb   %sp@(3),%d0     | the byte

On an MC68040 the write may still be pending when the read is made (UM 7.7:
"write cycles can be deferred indefinitely ... the NOP instruction can be
used"), and the read finds the slot's old value; on QEMU's m68040 a write is
done when its instruction is. The clr.l is redundant (D0 is 3 after the
moveq), so it becomes a NOP, which waits for the pending write: the same
program, ordered as the MC68040 needs. The sequence must be found exactly
once, or nothing is written.
"""
import sys

OLD = bytes.fromhex("7003 2080 4280 102f 0003".replace(" ", ""))
NEW = bytes.fromhex("7003 2080 4e71 102f 0003".replace(" ", ""))


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    b = open(sys.argv[1], "rb").read()
    n = b.count(OLD)
    if n != 1:
        sys.exit(f"nbpatch.py: the sequence is in {sys.argv[1]} {n} times, not once")
    open(sys.argv[2], "wb").write(b.replace(OLD, NEW))


if __name__ == "__main__":
    main()
