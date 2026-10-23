# Every defect found in this design, and what stops it coming back

One entry per defect: what it was, what found it, and the test that now fails if it
returns. Kept because the *way* each one was found is the useful part — a defect
found by one thing would usually have survived all the others.

*Started fresh at M0. RD68041's integer core is new, not a fork; the defects of the
modules it reuses from RD68031 (the shifter, the bit-field unit, the divider, the
synchroniser) are in RD68031's `doc/bugs-found.md`.*

---

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
