# M13: what rd-virt found

The lockstep of `doc/virt.md` runs the RTL and UAE040 on two copies of the `virt` machine
and compares them at every instruction boundary. Every disagreement it met is here, in
RD68031's classes:

- **(a)** an RTL bug -- the manual says what the core should do, and it did not;
- **(b)** a harness issue -- handled in the harness, and listed so that nobody changes
  the RTL for it;
- **(c)** a known, decided difference -- with the lockstep option that accepts it.

Everything is phrased architecturally: the instruction, its operands, the registers on
each side, the manual section that decides. UM is `MC68040UM_split`, PRM
`M68000PRM_split`. Step numbers are boundaries since the reset of the Linux boot
(`--trace-from N` and `--dump-at N` reproduce any of them), with the RTL as it was when
each was found.

## Class (a): RTL bugs

Each is in `doc/bugs-found.md` (M13), with the test that now fails if it returns.

| | Step | Observed | Manual |
|---|---|---|---|
| m13-a1 | 278 | `MOVEM.L D0-D1/A0-A1,-(SP)` then `MOVEM.L (SP)+,...` in the early console: A1 came back as D0's value. The data unit took the A1 write (`$00000000` to `$FF0`) correctly, and the bus carried `$00000020`, the data of the write behind it in the queue | -- (a Verilator 5.032 miscompile of the queue's update; `doc/coding-standard.md`) |
| m13-a2 | 287,455 | `MOVE.L 4(A3),0(A0,D0.L*8)` then `MOVE.L 8(A3),4(A0,D0.L*8)` in `setup_arch`: the core retired the first and then `ADDQ.L #1,D0` after the second; the second never wrote | PRM 4, MOVE |
| m13-a3 | 5,313,808 | `ADDA.L (SP)+,SP` (`RESTORE_ALL`): SP $209FC8 on the core, $209FCC on the oracle, which is SP + 4 + the long word popped (0) | PRM 2.2.4: "After the operand address is used, it is incremented" |
| m13-a4 | 69,788,038 | `FSAVE` in `copy_thread`, after BusyBox's `setjmp` had run `FMOVEM.X FP0-FP7,60(A0)` in user mode: a null frame ($00000000) on the core, an idle one ($41000000) on the oracle | UM 9.8: null "until the first nonconditional floating-point instruction is executed" |
| m13-a5 | 77,647,625 | awk's `atan2` emulated by the FPSP: `BTST #2,-220(A6)` (`get_op`'s test of E1 in the saved unimplemented-instruction frame) Z clear on the core, set on the oracle; the core's path then unpacked FATAN's operand as a packed decimal | UM 9.8, E1: "For the unimplemented instruction state frame, the source operand's unsupported data type is packed if the E1 bit is set" -- against Table 9-16's "Always 1" (`doc/manual-contradictions.md` 9) |
| m13-a7 | 69,713,638 (MC68LC040) | the kernel's FPU emulation, for BusyBox's `setjmp` FMOVEM: `MOVES.W ([$32,SP],0),A1` took an access error on the core -- its pointer, on the kernel stack, read in SFC's (user) space; and, that fixed, the pointer sign-extended from its low word as the word operand to A1 is -- and read the user word on the oracle | PRM 6, MOVES: the operand is in SFC's space; the pointer of a memory indirect mode is an ordinary data access |
| m13-a6 | `virt_mmu` | a write through `$40000010` read back at once through `$300010`, the same physical long word: the old value on the core | UM 7.7 lets reads pass writes, not to the same location |

## Class (b): harness issues

| | Observed | Handling |
|---|---|---|
| m13-b1 | The first step: the RTL socket's step 0 was the end of the kernel's first instruction, the oracle's the end of the reset | the RTL socket's reset runs to the clock the core has its PC from the vector (`rs` = R_RUN), and that is step 0 |
| m13-b2 | Step 5,311,621, the first interrupt: the RTL ran `RTS` and took the interrupt, the oracle took it before the `RTS` -- the oracle was told at the RTL's next boundary, and the core counts an instruction an interrupt follows and the interrupt's processing as one boundary (`retire` excludes `w_int`; that is how its cosim traces count them) | the RTL socket makes the instruction's boundary itself (`w_end && w_int`), and the interrupt's is the next |
| m13-b3 | STOP: the core makes no boundary for it until the interrupt that ends it; the oracle has one, after the STOP | the socket makes one when the core enters `XS_STOP` (`x_npc` the PC) |
| m13-b4 | `make virt-bare`'s `virt_hello` ends one step earlier with `--tbi --ram-waits 1` | the power-off is a posted write: it reaches the bus, and virt-ctrl, a few clocks after its instruction, while the core goes on with the `BRA` after it. Not a divergence; the step count is reported |

## Class (c): known, decided differences, and how the lockstep accepts them

| | What | Decision | Lockstep |
|---|---|---|---|
| m13-c1 | A write's access fault. Step 69,465,241, `MOVES.L D0,(A0)+` to a user page not yet present: the core stacks the instruction's PC ($196DB4) with no write-back pending and A0 as it was; the oracle completes the instruction -- A0 + 4, the condition codes set -- and stacks the next PC ($196DB8) with the write in WB3 (WB3S $81). Linux's handler then completes the write-back on one side and returns to a restart on the other | `doc/divergences.md`, "A write's access fault is taken before the write" (M10) | the oracle's frame is replaced by the core's through its own write path, and its address registers within 16 of the core's and its condition codes by the core's; its RTE (which reads only the SSW's CT and CM, `m68k_do_rte_mmu040`) then restarts the instruction. On by default; `--strict-wfault`. 159 by step 77.6 M |
| m13-c2 | An instruction fetch fault. Step 69,481,876, the kernel's handler reads the SSW: $0502 on the core (SIZE long), $0542 on the oracle (word); step 69,547,169, FA: $800838E0 on the core (the long word fetched), $800838E2 on the oracle (the instruction word) | `doc/oracles.md`, M10: UM 8.4.6.2 "the original access size", and the MC68040 fetches long words | when the two SSWs differ in SIZE alone, for a fetch (TM 010 or 110), and FA within the same long word, the oracle's frame gets the core's SSW and FA. On by default; `--strict-fsize`. 192 by step 77.6 M |
| m13-c3 | An access error frame's EA field (+$08) with no continuation bit: 0 on the core, the calculated address on the oracle (step 69,575,255, `MOVES.L (d8,A1,Xn),D0`) | UM 8.4.6.1: the field "contains address information when one of the continuation flags CM, CT, CU, or CP in the SSW is set" | not compared then (`doc/virt.md`, the lockstep's step 5) |
| m13-c4 | The interrupt a lowered mask makes pending, after `MOVE #$2000,SR` and a `NOP`: taken at the end of the instruction after the NOP on the core, after the NOP on UAE040 alone. RD68031's `virt_timer` read its tick count right after the NOP | `doc/timing-divergences.md`: the core takes no interrupt at the end of a serialising instruction -- latency, not a lost interrupt (UM 7.5.1) | the program waits in a DBRA loop; the lockstep needs nothing, since the oracle takes the interrupt where the RTL does |
| m13-c6 | An unimplemented FP instruction's trap. `make fpsp`, step 80,952,276, FATAN (vector 11, format $2): FPSR $08000208 on the core -- INEX2 still in EXC from the instruction before --, $08000008 on the oracle, which has cleared EXC | UM 9.2.3.3: "the start of most operations clears this byte"; the hardware never starts this one, and the FPSP clears the condition codes and EXC itself first thing (`x_unimp.S`: "Temporary D25B Fix ... ensure FPSR exception byte and condition codes are clear before proceeding"), so the part did leave them. The core is kept | when both take vector 11 with a format $2 frame and the FPSRs differ in the condition codes and EXC alone, the oracle gets the core's FPSR. On by default; `--strict-fpsr` |
| m13-c5 | `FMOVE.L FP0,D3` of the NaN a null FRESTORE leaves: both take the operand error (UM 9.7.3.2, nonmaskable), D3 is $00000000 on the core and $FFFFFFFF on the oracle until the handler writes it | UM 9.7.3.2: the FPSP writes the NaN's top 32 bits; what the processor leaves before it is not defined | found writing `m13_fsave_null`, not met in a run; nothing to accept yet |

## The runs

The guest is `sim/virt/linux/` built by its `build.sh` (Linux 7.2.9, BusyBox 1.38.0),
with `console=ttyGF0 lpj=250000 rdvirt.shell`. RAM 64 MB, 20 ns a step, RAM with no
wait state and one on the devices unless said. Wall times on the build machine.

The MC68040 (`FPU=1`, `rd-virt.config`, `commands.script`) and the MC68LC040 (`FPU=0`,
`rd-virt-lc.config` -- the FPU emulation -- `commands-lc.script`, UAE040 `-L`), on the
RTL of the M13 commit. Four runs at a time on the build machine, so the lockstep rates
are about 15 % under what a run alone gets.

| Run | Result | Steps | Clocks | Wall | Steps/s |
|---|---|---|---|---|---|
| `make virt-uae` (UAE040 alone) | PASS: shell, command set, power off | 88,427,033 | | 91 s | 0.97 M |
| `make virt-linux-solo` (RTL alone) | PASS: the same console | 88,411,645 | | 656 s | 135 k |
| `make virt-linux` (lockstep, caches on) | **PASS: 0 divergences** | 88,411,645 | 288.5 M | 792 s | 112 k |
| `make virt-linux VIRT_CACHES=off` (TCI on every line, the oracle without its data cache) | **PASS: 0 divergences** | 88,411,645 | 750.1 M | 1,646 s | 54 k |
| `make fpsp` (lockstep, `commands-fpsp.script`) | **PASS: 0 divergences**, the FPSP's sin, cos, atan2, exp, log, int and remainder to the host's ten decimals | 84,619,975 | 272.3 M | 753 s | 112 k |
| `make virt-uae FPU=0` | PASS | 89,075,482 | | 84 s | 1.05 M |
| `make virt-linux-solo FPU=0` | PASS | 89,057,253 | | 523 s | 170 k |
| `make virt-linux FPU=0` | **PASS: 0 divergences** | 89,057,253 | 292.9 M | 653 s | 136 k |
| `make virt-linux FPU=0 VIRT_CACHES=off` | **PASS: 0 divergences** | 89,048,047 | 756.2 M | 1,408 s | 63 k |
| `make virt-bare`, both builds | PASS: `virt_hello` 274, `virt_timer` 17,023, `virt_mmu` 140,919 steps, each with the default bus, with `--tbi --ram-waits 1`, and with the caches off | | | seconds | |

The step counts of a configuration are the same from one run to the next; between two
they differ where the console's input arrives at another step (it is typed when the
console shows what the script waits for, which depends on the clocks).

What the lockstep accepted on the way, `make virt-linux`: 399 write faults aligned
(c1), 436 fetch faults' SIZE and FA (c2); 1,061 access error frames and 10 FSAVE frames
compared in part (`doc/virt.md`); 54.6 M bytes of operand writes compared. `make fpsp`:
261, 312, and one FPSR at an unimplemented instruction (c6).
