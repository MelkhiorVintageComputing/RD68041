# rd-qvirt: the core as the processor of QEMU's `virt` machine

M14's last part (doc/plan.md, section 7). NetBSD/virt68k and Linux run on QEMU 11.1.2's
m68k `virt` board with the core as its processor, and each guest's console is compared
with the console of the same guest on the same board run by QEMU's own m68040. It
replaces the plan's NetBSD/mac68k and Linux/mac on MAME's Quadra, which need a Mac OS
booter, its media, and the Quadra's SCSI and serial ports. Here both systems boot from
`-kernel`, and NetBSD has a port for the board.

QEMU is not modified, and its CPU is not used: it runs under its **qtest** accelerator,
so it is a box of devices that something else drives. That something is the core, under
Verilator, behind rd-virt's RTL socket. Nothing links QEMU; it is a separate process,
and the harness is written against its documented interfaces:
- the qtest protocol (`system/qtest.c`'s commands);
- the board's map and wiring (`hw/m68k/virt.c`);
- the device registers the guests program.

`target/m68k/` is not read (CLAUDE.md).

| File | What |
|---|---|
| `sim/qvirt/qemu_machine.{h,cpp}` | the machine: QEMU started, its RAM shared, its devices over qtest, the clock, the settle rules |
| `sim/qvirt/qvirt.cpp` | the run: reset, the boundaries, STOP, the console script, the report |
| `sim/virt/cpu_rtl.{h,cpp}`, `sim/virt/bus_if.h`, `sim/virt/script.h` | rd-virt's RTL socket and pin agent, the interface it now asks of a machine, the console script (shared with rd-virt) |
| `sim/qvirt/qemu-ref.py` | the reference: the same guest on the same board with QEMU's m68040 |
| `sim/qvirt/console-diff.py`, `linux.mask`, `linux-lc.mask`, `netbsd.mask` | the comparison, and what it leaves out |
| `sim/qvirt/netbsd.sh`, `mksets.py`, `nbpatch.py`, `netbsd-install.script`, `netbsd-boot.script` | NetBSD: the media, the kernel's one change, the install, the boot and its command set |
| `sim/qvirt/build.sh` | the Verilator build (`FPU=0`: the MC68LC040) |

## The machine

QEMU's command line for a core run is in each run's `qemu.cmdline`:

```
qemu-system-m68k -M virt -accel qtest -qtest unix:DIR/qtest.sock -qtest-log /dev/null -m 128M
  -object memory-backend-file,id=ram,size=128M,mem-path=/dev/shm/rdqvirt-PID.ram,share=on
  -machine memory-backend=ram -kernel K [-initrd I] [-append S]
  -rtc base=2026-10-01T00:00:00,clock=vm -chardev socket,id=con,path=DIR/con.sock -serial chardev:con
  [-drive if=none,id=hd0,format=raw,snapshot=on,file=D -device virtio-blk-device,drive=hd0]
  -nic none -display none -monitor none
```

- **The RAM is shared.** QEMU's RAM is a file in `/dev/shm` that the harness maps as
  well, then unlinks. The core's RAM transfers go straight to it, and QEMU's DMA (the
  goldfish tty's buffers, virtio-blk) lands in the same memory. QEMU gets
  `PR_SET_PDEATHSIG`, so it never outlives the harness.
- **A device transfer is a qtest command**, `readb/w/l` or `writeb/w/l`, at the address
  the core put on the bus. qtest takes and gives values in the target's order, which is
  the bus's. The agent's rules are rd-virt's: a device read is made once per transfer,
  when it is answered, and anything outside RAM and `$FF000000-$FF01FFFF` is a hole
  answered with TEA.
- **Interrupts:** `irq_intercept_in` on the `m68k-irq-controller`. That is
  `/machine/unattached/device[1]`, the second device the board creates (checked by QMP's
  `qom-get` at M14). Its seven inputs are levels 1-7; the agent drives IPL from the
  highest one raised and answers IACK with AVEC, since the controller autovectors.
- **The start:** QEMU's reset leaves the kernel and the bootinfo in RAM and starts its
  own CPU at the ELF's entry with SSP 0 (`main_cpu_reset`). The agent answers the core's
  two reset-vector reads with those values (`RtlOptions::reset_pc/reset_ssp`; for a
  bare program linked at 0, its own SSP) and writes no RAM.
- **The bootinfo:** QEMU draws its RNG seed again at every reset. The harness gives it
  rd-virt's fixed seed in the shared RAM, and with `--no-fpu` (the MC68LC040) it clears
  the FPU record. `qemu-ref.py` does the same for the reference while QEMU is held at
  `-S`, then sends QMP's `cont`.

## DMA: the devices as a snooping bus master

QEMU's devices read and write the guest's memory themselves: the goldfish tty's
`WRITE_BUFFER` and `READ_BUFFER`, and virtio's rings and buffers. QEMU's own m68040 has
no caches, so to it that memory is always coherent. The core has copyback caches, and an
MC68040 board keeps DMA coherent the way the part provides for (UM 4.4, 7.9): the DMA
controller is an alternate bus master whose transfers the processor snoops. rd-qvirt
does the same (`sim/virt/bus_if.h`, `cpu_rtl.cpp`'s DMA master, `qemu_machine.cpp`'s
`dma_*`):
1. **The hold-off.** A write that starts DMA is answered with a retry (TA with TEA,
   UM 7.4.6), and BG is withdrawn. These are `CMD` 2 or 3 to the tty, and a
   `QueueNotify`.
2. **Snooped reads (SC 01)** of what the device will read: for virtio the rings, then
   the indirect tables, then the buffers the driver made available. The core sources
   each line it holds dirty, and memory takes the data, as UM 4.5 has a memory
   controller do.
3. **The command** goes to QEMU; a virtio request settles (above).
4. **Snooped writes** of what the device wrote, with the data now in RAM: whole lines
   with SC 10, which the core invalidates; the rest as long words and bytes with SC 01,
   which the core sinks into a dirty line or invalidates (UM 4.4.4, Table 4-4;
   `core_snoop_tb`'s rules).
5. **The bus is given back** (BB negated for a clock), and the core's retried write is
   answered without being made again.

The master follows `sim/models/rd68041_altmaster.sv`'s protocol: TS for a clock, memory
answering once the snooper negates MI, or the core answering when it intervenes. The
run's report counts the commands, the snooped transfers and the lines sourced. rd-virt's
own devices make no DMA, so none of this happens there, and its runs are unchanged.

No run so far has sourced a line. Both kernels push the data cache over a buffer
before they hand it to a device (their DMA-sync calls), so a snooped read never finds
it dirty; the harness does not count how many snooped writes hit a line. Intervention is exercised by `core_snoop_tb` and the random alternate-master bench, not
by these guests.

## A guest that relies on QEMU's MMIO

NetBSD/virt68k's `gftty_cngetc`, the console's polled input (the kernel's root-device,
dump, file-system and init-path questions), starts `READ_BUFFER` into a stack slot and
reads the slot two instructions later:

```
moveq   #3,%d0
movel   %d0,%a0@        | CMD = READ_BUFFER
clrl    %d0
moveb   %sp@(3),%d0     | the byte
```

On an MC68040 the command's write may still be in the write buffer when the read is
made: UM 7.7, *"write cycles can be deferred indefinitely ... When this action is not
desired ... the NOP instruction can be used"*. The core does exactly that. Its read hit
the slot's line in the data cache before the write reached the bus, it found the slot's
old byte, and the kernel answered every key with a bell. On QEMU's m68040 an MMIO write
is complete when its instruction is.

So the harness's copy of the kernel (`sim/qvirt/nbpatch.py`, applied by `netbsd.sh
fetch` into `build/`) has the redundant `clrl %d0` replaced by `NOP` (D0 is 3 after the
`moveq`). The core's NOP waits for the pending writes (UM 2.1), which is the ordering
the MC68040 needs. Both processors run the patched kernel. The interrupt-driven path
(`gftty_intr`) syncs its DMA map around the command and leaves the data to a soft
interrupt. This is a class (b) harness issue: nothing in the RTL changes for it.

## Time, and what is made to settle

QEMU's virtual clock moves only when qtest says so, so the harness decides it:
- **The core's time** is its clocks × `--ns` (40: 25 MHz), plus what STOP skipped.
  `--step-ns N` makes it boundaries × N instead, rd-virt's time base.
- **QEMU's clock is brought up to it** (`clock_set`) before every device access, and at
  a boundary when it trails by `--quantum` (50 µs) or more.
- **In STOP**, a bare `clock_step` moves QEMU to its next timer deadline, and the skip
  is added to the core's time.

Two things QEMU does on its own time are made to happen at a time of the harness's:
- **virtio-blk:** QEMU completes block requests on its threads. When the guest writes a
  queue's `QueueNotify`, the harness holds the clock and waits until the device's used
  index has caught up with the driver's available index. It finds the rings from the
  transport writes it has passed through (version 2: `QueueDesc/Driver/Device`, little
  endian; version 1: `QueuePFN`, the guest's order). Then one more round trip, so that
  the completion's interrupt is reported before the guest runs on.
- **Console input:** typed only while goldfish-tty's 128-byte FIFO has room, then the
  harness waits until `BYTES_READY` counts it. The script's input is released once the
  console has been quiet for `--quiet-ns` (250 ms) of virtual time after the text it
  waited for, so that the prompt is out before the echo of what is typed, as a person
  would type. The console is looked at every 256 boundaries.

What is left is deterministic: two runs give the same console, byte for byte, and the
same step and clock counts (checked at M14 for Linux on both builds). The count of qtest
round trips can differ by one or two, because it includes the polls of a settle, which
wait on QEMU's threads in wall time. The guest never sees them.

## The comparison

`qemu-ref.py` runs the same guest on the same board with `-cpu m68040 -accel tcg
-icount shift=0,sleep=off`, the same RAM file arrangement, RTC base, disk and bootinfo
fixes, and `-serial stdio` driven by the same script. `console-diff.py` then compares
the two consoles line for line:
- carriage returns are dropped;
- the kernels' time stamps (`[    1.0400030] `) are removed: they are virtual time, which
  the two processors spend differently;
- each line matching the guest's mask file is left out;
- with `--until`, the comparison ends at the typed `shutdown -p now`.

The masks list only what depends on elapsed time or on another process's pace:
- `linux.mask`: the initramfs unpacking's line, printed by a kernel thread beside the
  boot's own; the timer's count in `/proc/interrupts`;
- `netbsd.mask`: `/etc/rc`'s `date` lines; syslogd's stamped messages on the console;
- `linux-lc.mask` (`FPU=0`): `linux.mask`, and the one line the reference cannot give.
  QEMU's m68040 has no MC68LC040 mode. With the bootinfo's FPU record cleared, Linux
  believes there is no FPU, but QEMU still executes the FP instructions. On the core
  they take the F-line trap into the kernel's FPU emulation, which has no FATAN, so
  `/init`'s `awk float:` line (atan2) gets the emulation's warning and its value.
  Those lines are the same as on rd-virt's no-FPU UAE040 (M13's lockstep console), and
  the mask drops them. The command set's own FP line (`commands-lc.script`) is
  arithmetic the emulation does implement, so it is compared.

Two reference runs agree under the mask.

A run that hangs ends at the core's watchdog (no boundary in 2,000,000 clocks) and
prints the last 256 boundaries, PC, SR and registers. A model built with
`TRACE=1 sim/qvirt/build.sh DIR` takes `--vcd F --vcd-from N`. With `--vcd-from hang`, it
dumps the 2,000 clocks before the watchdog fires instead, which is the hung core's state
from one run, without knowing the step it hangs at (`doc/bugs-found.md`: `gzcat`).

## The guests

- **The bare-metal programs** (`make qvirt-bare`): `sim/programs/virt_*.S`, rd-virt's,
  on QEMU's devices with `--step-ns 20` (they time themselves in instructions).
- **Linux** (`make qvirt-linux`, `make qvirt-linux-qemu`): rd-virt's guest and command
  set unchanged (`sim/virt/linux/`), for both builds. Apart from the RAM size (128 MB
  here, 64 MB in rd-virt) and the echo of typed lines, the console is the same as
  rd-virt's.
- **NetBSD/virt68k 11.0** (`make netbsd-disk netbsd-qemu netbsd-qvirt`), the first
  release with the port, pinned in `Inputs/sw/MANIFEST-netbsd`:
  - **The media:** `netbsd-GENERIC`, the install ramdisk `inst-ramdisk.fs` (booted as
    the initrd), `base`, `etc` and `kern-GENERIC`.
  - **The install** (`netbsd-install.script`, on QEMU's m68040, 30 s):
    - sysinst is left for its shell;
    - `newfs` on the target `ld0`'s default label;
    - the sets untarred from a second disk, the sets as one uncompressed tar that
      `mksets.py` makes by copying members without extracting them;
    - `fstab`, and `rc.conf` with no network services, mail or cron;
    - root has no password.

    QEMU fills the virtio-mmio slots from the top and NetBSD numbers its disks from the
    bottom, so the last `-device` is `ld0`. The disk is made read-only and every boot
    takes it `snapshot=on`.
  - **The boot** (`netbsd-boot.script`):
    - GENERIC asks for its root: `ld0a`, no dump device;
    - multi-user, then root logs in;
    - shell arithmetic, `uname`, `sysctl hw.model`, `dmesg`, awk floating point, the md5
      of a generated file, a file written, synced and compared (virtio both ways), `ls`;
    - `shutdown -p now`, through virt-ctrl.
  - **The MC68LC040 does not run it:** virt68k's GENERIC has the FPSP but not
    `FPU_EMULATE`, so a kernel without an FPU has nothing to take its userland's FP
    instructions (`doc/oracles.md`).
