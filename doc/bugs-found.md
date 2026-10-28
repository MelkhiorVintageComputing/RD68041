# Every defect found in this design, and what stops it coming back

One entry per defect: what it was, what found it, and the test that now fails if it
returns. Kept because the *way* each one was found is the useful part — a defect
found by one thing would usually have survived all the others.

*Started fresh at M0. RD68041's integer core is new, not a fork; the defects of the
modules it reuses from RD68031 (the shifter, the bit-field unit, the divider, the
synchroniser) are in RD68031's `doc/bugs-found.md`.*

---

## Found by litex-68k: Linux in a LiteX SoC

1. **An instruction fetch went on past an ATC fault, and left an entry not
   resident for the next page.** The fetch unit queued a faulted fetch's words
   marked (`q_atc`) and then fetched on, so a fault near the end of a page went
   on to the next page and searched the tables for it; that page invalid too, its
   ATC entry was made not resident (UM 3.2.2.3). Linux's handler for the first
   fault maps the faulting page and, by fault-around, the next ones, and flushes
   the ATC entry of the faulting page only (a PTEST in `access_error040`): the
   fetch after its RTE hit the stale entry for the next page and faulted again,
   and Linux, whose PTEST now found that page resident, took the fault as a
   protection violation and killed the process. With glibc's busybox as init the
   first call of `fopen64`, at the end of a page, ran into the next one with a
   `MOVE.L 12(SP),-(SP)` across the two: init died of SIGSEGV and the kernel
   panicked. The fetch unit now stops after an ATC fault until the next redirect
   (`xstop` in `rd68041_ifu`): the words after the fault can only be wanted after
   the faulted ones, whose fault comes first. Nothing here reached it: no bench or
   program made a page resident behind a fault on the page before it, and rd-virt
   and rd-qvirt's Linux never happened to. `core_fetchnext_tb`
   (`sim/programs/m14_fetch_next.S`) does: two faults without the fix, one with it.

2. **An instruction whose extension words were on a page not resident hung the
   processor** -- a regression from the fix above. Decode took a faulted fetch's
   access fault only once all of the instruction's words were in the queue (or
   at once if its operation word was one of them). Since the fetch stops at an
   ATC fault (`xstop`), an instruction whose operation word is the last word of a
   resident page, and that has more extension words than the faulted long word
   brings, never had them all: decode waited for words that would never come,
   with nothing to redirect the fetch, and the pipeline behind it empty -- no
   instruction, no interrupt, ever. NetBSD 11.0's install ramdisk on litex-68k
   froze the machine as soon as `gzcat` ran: a `MOVE.L #$3F45,(4,A3)` at `$FBFFE`
   in its zlib, page `$FC000` not yet mapped, the queue holding the operation word
   and the two faulted words of three. litex-68k confirmed it independently with
   the board's ILA (the instruction-side table walk for `$FC000`, its page
   descriptor invalid, then nothing) and a user program that does only that
   (`pagecross.c`: hangs with the next page not resident, passes with it read
   first). Decode now takes the fault as soon as a
   faulted word the instruction needs is in the queue (the words before it are
   all there: the queue is in order), which is the same frame -- the PC the
   instruction's, FA the faulted long word -- as waiting gave whenever the words
   did come. downstream's trace pointed at the write fault taken just before (its
   output was flushed only at a change of mode, so what came after was lost);
   rd-qvirt found the place, with NetBSD/virt68k and the same ramdisk, by the new
   end-of-run capture (`--vcd-from hang`, and the last boundaries). No bench put
   an instruction across into a page not resident with more than one long word
   on the far side: `core_fetchnext_tb`'s ran into a page made resident first.
   `core_fetchext_tb` (`sim/programs/m14_fetch_ext.S`) does, with the instruction
   cache off and on: it hangs without the fix.

---

## M14: found by MAME's Quadra

1. **A serialised page's read could be made twice.** The core makes an instruction's
   operand read in \<ea\> fetch while older instructions are still in EX and W; an
   interrupt taken at an older one's boundary -- or a branch resolved against the
   prediction -- discarded the younger instruction after its read, and ran it again.
   UM 4.3.2 forbids exactly that on a serialised page: "Serialization forces operand
   read accesses for an instruction to occur only once by preventing the instruction
   from being interrupted after the operand fetch stage". The Quadra ROM reads its
   SCSI controller's FIFO with four `MOVE.L (A1),(A2)+`, the I/O space serialised by
   DTT1; an interrupt between two of them made the core read five long words, the
   FIFO ran dry on the fifth and the boot from the disk stopped for good (MAME's
   pseudo-DMA asking for the access again, 7.8 M bus retries). A read of a serialised
   page, or a locked one, now does not start until nothing older is left in EX or W
   (`rd68041_dmu`'s `ld_ser_wait`, the core's `of_oldest`). Nothing before reached it:
   no bench, oracle or program interrupted a run of reads of a side-effect register,
   and rd-virt's devices have none on read. Once Mac OS had its MMU on, the boot stopped
   the same way again, past the happy Mac: Mac OS maps the pseudo-DMA register's page
   noncachable but *not* serialised (CM 11), for which the manual makes no such
   promise, and an interrupt taken at the boundary of the `MOVE` before -- arriving
   while MAME held a transfer with a retry -- discarded a read already made. Found with
   the agent's trace (`RD68041_TRACE`, the pipeline's state each clock) and a walk of
   Mac OS's page tables; every cache-inhibited read is held the same way now
   (`doc/divergences.md`). `core_ser_tb` (`m14_serial`): four reads a pass of a page
   serialised, then CM 11, with interrupts every 17-23 clocks and a bus retry every 37
   -- 944 reads for 800 executed without the fix.

## M13: found by rd-virt, Linux in lockstep with UAE040

Every one of these passed the cosim programs, the vector sweeps and the cputest corpus;
Linux's boot reached each. `doc/m13-mismatches.md` has the step each appeared at.

1. **A write left the data unit's queue with the data of the write behind it.** When
   the queue's oldest write finished in the clock a new one joined, with one write in
   the queue, the new write's address went into the slot and the old second slot's data
   stayed: `rd68041_dmu` moved the queue up with constant-index nonblocking assignments
   and added the new write with a variable-index one, and Verilator 5.032 let the
   constant-index one win for the data (not the address) -- against the language, which
   iverilog follows. `MOVEM.L D0-D1/A0-A1,-(SP)` in the kernel's early console pushed
   D0's value where A1's belonged (step 278). Each slot is assigned once a clock now;
   the trap is in `doc/coding-standard.md`. Caught by the lockstep's first run; every
   iverilog bench had passed it.
2. **A memory-to-memory MOVE with an indexed destination took the next instruction's
   words.** Its second micro-operation read the destination's extension word at w[0],
   as it should, but computed how many words to pop from the word after the source's,
   which by then was past the destination's: when the next instruction's first word
   had bit 8 set (a full-format extension word, to `ea_len`) and was already in the
   queue, the move popped it and the next two, and the instruction after the move never
   ran. `MOVE.L 8(A3),4(A0,D0.L*8)` in `setup_arch` (step 287,455). `m13_move_mm`, in
   `make cosim`; the cputest corpus runs one instruction at a time, with nothing after
   it in the queue.
3. **`ADDA.L (A7)+,A7` added to A7 as it was before the increment.** An instruction
   whose source is (An)+ or -(An) and whose other operand is that An used the register
   file's value, not the one its own update leaves (PRM 2.2.4-2.2.5: the address is
   used, then moved). Linux's `RESTORE_ALL` pops its stack adjustment this way (step
   5,313,808). EX now reads a register its own micro-operation updates as updated
   unless it stores it (MOVE An,(An)+ stores An as it was). `m13_an_upd`, in `make
   cosim`; the cputest corpus has no such pairs.
4. **FMOVEM, FMOVE and the control registers read out left the FPU in its null state.**
   Only an operation or a write into the FPU moved it to idle, so FSAVE stacked a null
   frame after BusyBox's `setjmp` (`FMOVEM.X FP0-FP7,60(A0)`) where UM 9.8 says idle:
   "until the first nonconditional floating-point instruction is executed" (step
   69,788,038, the first `copy_thread` after it). `m13_fsave_null`, in `make cosim`.
5. **The unimplemented-instruction frame always had E1 set.** M11 followed UM Table
   9-16 ("E1 -- Always 1"); the field's definition says E1 there means a packed source,
   and the FPSP reads it so (`get_op.S`) -- with E1 set every FSIN, FATAN and FETOX was
   emulated on its operand unpacked as decimal (step 77,647,625, awk's `atan2`). E1 is
   the packed flag now; `doc/manual-contradictions.md` 9; `core_fpu_tb` checks it.
6. **A read through one mapping of a page passed a queued write through another.** A
   read waits for a queued write it overlaps, and the test compared logical addresses:
   two mappings of one physical page did not match, and the read returned memory's
   value under the write. `virt_mmu`, a write through `$40000010` read back at
   `$300010`, the same physical long word. The test is on the page offset now, which
   every mapping of a byte shares, in the data unit and for the writes still in EX or
   W; `make virt-bare`.
7. **A memory indirect operand's pointer was read in MOVES's space, and sign-extended
   as MOVES's operand.** M12's fix (1 below) cleared the prelude's FP kind and
   exception; it still kept the instruction's other modifiers -- MOVES's alternate
   space and its sign extension of a word going to An, a lock, a bit field's sizing,
   an SR write. The MC68LC040 guest's FPU emulation reads a user instruction's word
   with `MOVES.W ([$32,SP],0),A1`, its pointer on the kernel stack: the core read the
   pointer in user data space and took an access error; with that fixed, it
   sign-extended the pointer's low word, `$80001AA8` becoming `$00001AA8`, and took
   another (step 69,713,638 of the MC68LC040's boot; UAE040 read the user word). The
   prelude is a plain long-word read now. `virt_mmu` has both, the pointer on a
   supervisor-only page and its bit 15 set (`make virt-bare`); `m13_ind_moves` (`make
   cosim`) the values of MOVES, TAS, CAS and the bit fields with memory indirect
   operands.

## M12: found while building the MC68LC040

1. **A memory indirect mode's prelude carried the instruction's first micro-operation.**
   The prelude that reads the pointer into T3 was built over whatever the instruction's
   first micro-operation had been decoded as, and kept its FP kind and its exception:
   on the MC68040, `FMOVE.L ([bd]),FP1` ran the FPU's operation on the pointer, then
   again on the operand (an M11 bug no oracle stream had reached: the cputest corpus
   and the cosim programs use no memory indirect FP operand); on the MC68LC040 the
   format $4 exception was taken on the prelude, its address the pointer's. The prelude
   is now only the read. Caught by `m12_lc040` against UAE040 `-L`; `m12_fpu_ind` is the
   MC68040's case, now in `make cosim`.
2. **`make cosim` left out `m11_fpu_a` and `m11_fpu_b`**, which M11 reports it as
   running: they were run by hand. They are in `PROGS` now.
3. **`make sim` with a `BUILD` other than `build`** asked for its programs under
   `$(BUILD)/programs`, where nothing builds them -- the first time `make check FPU=0`
   ran in its own build directory.

## M11: found while building the FPU

1. **An FP instruction's last micro-operation applied the next instruction's commit
   record.** The FPU's results commit at write-back from a record EX fills; an FMOVEM's
   last micro-operation reaching W committed the record the next FP instruction had
   just made in EX. The record now says whether its own micro-operation has gone on to
   W (`rec_w`). Caught by `m11_fpu_a`, the first cosim run.
2. **Decode issued an FP instruction before its command word was in the queue**, and
   opclass 001's garbage made it an F-line exception. Every FP encoding now needs at
   least its command word. Caught by `m11_fpu_a`.
3. **A post-instruction exception on a micro-operation with a store hung the core.**
   An exception waits in W for the queued writes, but its own store was offered to the
   store queue the whole time, taken every clock, so the queue was never empty: FMOVE.D
   to memory with an overflow, its last long word carrying the format $3 exception. The
   store is offered only once the queue is empty (`w_drain`). Caught by the cputest FPU
   corpus.
4. **FMOVE out's unsupported data type stacked 0 for its EA.** The exception is taken
   by the first micro-operation, which computed no address; it now computes the
   destination's, without an access, and steps (An)+ and -(An) over a packed
   destination's twelve bytes, which always takes the exception. Caught by cputest.
5. **FMOVE and FMOVEM of the control registers refused (An)+ to memory and -(An) from
   it** (PRM 5's text against its tables, `doc/manual-contradictions.md` 8). Caught by
   cputest: FMOVE.L FPSR,(A7)+.
6. **FSGLDIV truncated its operands to 24 bits**, as one paragraph of PRM 5 says and
   UAE040 does not (`doc/manual-contradictions.md` 7). Caught by cputest.
7. **The condition codes of a trapped underflow were Table 9-13's zero** where the
   denormalised result the FPSP stores is not zero -- FSGLDIV's extended exponent range
   leaves extended denormals. Caught by cputest.
8. **An overflowing FMOVE to a single or a double stored the rounded value with its
   exponent wrapped**; it stores Table 9-12's infinity or largest number now, as UAE040
   does ("an undefined result is stored", UM 9.7.4.2). Caught by cputest.

## M10: found while building the MMU

1. **An instruction that faulted after some of its micro-operations had written
   registers left them written.** CMPM's first postincrement, MOVEM's loaded registers
   and its address register stood when a later access of the same instruction faulted,
   so RTE restarted the instruction from changed registers -- harmless before M10 only
   because a bus error is rarely returned from. Found by review, designing the MMU's
   restart model (`doc/checkpoint.md`): the core now logs each register's old value the
   first time an instruction's micro-operation writes it, and puts them back before the
   frame (`XS_UNDO`). `core_fault_tb` (f) and (g) fail without it.
2. **MOVEC to URP or SRP cleared bits 8-0.** UM 3.1.1 says only that they must be zero;
   UAE040 keeps them, and so now does the core (a search uses bits 31-9). Caught by the
   `pmmu040` vector group, its first run.

The MMU itself passed `core_mmu_tb` and `make cosim` (`m10_mmu`) at their first run;
`core_mmu_tb` fails when a table descriptor's U write is suppressed (checked by hand).

## M9: found while building the caches

1. **Words queued at entries 8-11 of the instruction queue were lost**: a size cast of
   an `int` is signed in iverilog, and the index 8 became -8 (`doc/coding-standard.md`).
   Caught by every cosim program, at their first instruction past the queue's eighth
   word.
2. **A write could be made twice.** The write queue's head was taken off a clock after
   its last piece was done, and on that clock the data memory unit, idle again, started
   it a second time. Caught by `make cosim` (`m7_a`, a byte of a long word written
   twice over another write).
3. **A locked or serialised read could wait forever**: it waits for the write queue to
   empty, and the writes started only while no read was asking. Found reviewing the
   same code.
4. **The push buffer held its line backwards**, long word 0 where the bus unit takes long
   word 3. Caught by `m9_dcache` against UAE040: a replaced dirty line came back wrong.
5. **A MOVE16 read of a line in the cache took the fast read path**, which answers one
   long word and leaves the MOVE16 buffer as it was. Caught by `m9_move16`.
6. **MOVE16 (An)+,(An)+ incremented An twice.** Caught by cputest.
7. **The access after MOVEC to DTTn used the old cache mode**, read in \<ea\> fetch before
   the MOVEC reached write-back. MOVEC to a control register is serialising now. Caught
   by `core_cache_tb`.
8. **A copyback write could land in a line a snoop was invalidating.** A write that hits
   is decided and done in one clock; the state machine gave way to the snooper's use of
   the data port and the dirty bits but not to its invalidation of the tags, so in the
   clock a snooped transfer invalidated the line the write went into an invalid line
   and was lost. Found reviewing the write path while `core_snoop_tb` was failing --
   which turned out to be the bench's own use of the snoop codes against UM 4.4.3 and
   4.4.4 (mark invalid on a word read, or on a word write to a copyback page, drops the
   rest of a dirty line, as the manual says it does).

## M8: found while building exception processing

1. **Two always_comb blocks calling the same function hung iverilog 12** at time zero
   (the M7 decoder refactor, `5e848e8`): no output, a vector run that never ended. The
   values are continuous assignments now; `doc/coding-standard.md` has the quirk.
2. **Reserved bits of extension words made an instruction illegal.** The decoder
   refused BFCHG, BFCLR, BFSET and BFTST with bit 15 of the extension word set, and
   MOVES with bits 10-0 set; the cputest corpus expects the part to ignore them. Until
   M8 such an instruction halted and the corpus counted it as not built, which hid it;
   once "illegal" was an exception, they failed. Caught by cputest.
3. **A locked read that faulted left the sequence open**: LOCK stayed asserted and
   the data memory unit started nothing unlocked again, so the access fault's frame
   could never be written. The fault now ends the sequence (`rd68041_dmu.sv`). Found
   writing `core_fault_tb`'s TAS case, which covers it.
4. **RTE of a throwaway frame counted as two instructions**, its first pass (which
   runs RTE again) as well as its second; the trace of instructions saw one. The first
   pass is neither retired nor traced now. Caught by `make cosim` (`m8_exc`).
5. **The one-instruction harness compared before an SR write landed**, since the
   pipeline is empty while `XS_SR` waits for the writes; it waits for the exception
   state machine to be idle now. Found while converting the benches, before it could
   cost a false result.
6. **The vector was read before the frame was written.** The data memory unit lets a
   read pass queued writes it does not touch, so the vector fetch went to the bus ahead
   of the frame's stores; on a double bus fault the processor halted with the frame
   still queued. UM 8.1 fetches the vector last, and after a double bus fault "the
   processor does not attempt to alter the current state of memory": exception
   processing's reads now wait for every write before them. Caught by cputest, whose
   vectors (wherever the test's memory puts them) are often odd.
7. **All of $F5xx was taken for PFLUSH and PTEST**, so an undefined $F5xx in user mode
   was a privilege violation; only $F500-$F51F and $F548, $F568 are, and the rest is
   the F-line. Caught by cputest (ILLEGAL, $F597).

## M7: five found by the first vector and cputest sweeps

Found by `make vectors-all` (UAE040) and `make cputest` (WinUAE's corpus), the first
time either ran on the core. None was reached by the cosim programs, which test each
instruction in one or two forms where the vectors test every form.

1. **SWAP set N from bit 7.** The decoder left `u.sz` at its all-zeros default, byte,
   for every instruction whose case did not set it, so SWAP's N came from the wrong
   bit. The default is now a long word (`rd68041_decode.sv`, the defaults block). Caught
   by the `swap` vectors.
2. **CMPA.W from memory read a long word.** The case widened `u.sz` to a long word to
   get a 32-bit compare, but the same field sizes the load. The load is now a word,
   and EX works at 32 bits whenever the source is sign-extended (`alu_sz` in
   `rd68041_core.sv`). Caught by the `cmpa` vectors with memory sources.
3. **DIVS.L reported no overflow for quotients between $80000000 and $FFFFFFFF.**
   The divider reused from RD68031 only flags a quotient that does not fit in 32
   unsigned bits; the signed long forms now also check the magnitude against
   $7FFFFFFF, or $80000000 when the quotient is negative (`div_fits`). Caught by cputest.
4. **LINK A7 pushed the stack pointer from before the decrement.** PRM 4 decrements
   SP first and then pushes An, so with An = A7 the value pushed is the new SP;
   UAE040 and the cputest corpus agree. Caught by the `link` vectors.
5. **MOVEM with an empty mask and a full-format <ea>** had the wrong length. This
   was already fixed by latching the length in decode (M7 part 2) and is now covered
   by the vector sweep.
6. **A bit field in memory was always read as five bytes**, a long word and a byte,
   whatever its offset and width, and written back the same way. Bytes outside the
   field could be in another page or in a device. EA now sizes the accesses from the
   parameters in T3 (`bf_bytes`, the micro-op's `bfa`): a byte, a word, a word and a
   byte, a long word, or a long word and a byte, with no second access when there is
   no last byte. Caught by the `bitfield_mem` vectors, which now match UAE040 access
   for access.
7. **NBCD and SBCD lost the borrow on an operand with a digit above 9.** The low
   digit's correction (-6) can take the difference back over zero: $00 - $FB is $105
   in nine bits, $0FF after the correction, and the borrow was read after it. It is
   now the binary difference's or the correction's. Valid BCD never reaches this,
   which is why only the cputest corpus (random operands) found it; every one of its
   1194 ABCD, SBCD and NBCD tests now passes.
