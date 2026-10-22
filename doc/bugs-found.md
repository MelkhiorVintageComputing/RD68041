# Every defect found in this design, and what stops it coming back

One entry per defect: what it was, what found it, and the test that now fails if it
returns. Kept because the *way* each one was found is the useful part — a defect
found by one thing would usually have survived all the others.

*Started fresh at M0. RD68041's integer core is new, not a fork; the defects of the
modules it reuses from RD68031 (the shifter, the bit-field unit, the divider, the
synchroniser) are in RD68031's `doc/bugs-found.md`.*

---

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
