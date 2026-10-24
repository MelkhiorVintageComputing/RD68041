# The floating-point unit (M11)

The MC68040's FPU (UM 9) as this design builds it: what is in hardware, where it sits in
the pipeline, how its state commits, and the contract with the M68040FPSP -- the
exception model and the FSAVE/FRESTORE frames -- which is what most of its complexity is
for. `FPU = 0` (the MC68LC040) builds none of it: every FP instruction is vector 11 with
a format $4 frame (UM A.5, M12; below, "The MC68LC040").

## What is in hardware

Following UM 9.6.1, Table 9-10, and the FPSP's own dispatch table (`tbldo.S`, which
emulates every opmode the hardware does not):

| Built | Opmodes |
|---|---|
| arithmetic | FADD, FSUB, FMUL, FDIV, FSQRT, FABS, FNEG, FMOVE (in and out), FCMP, FTST, FSGLMUL, FSGLDIV, and the FSxxx/FDxxx forms of FADD, FSUB, FMUL, FDIV, FSQRT, FABS, FNEG, FMOVE |
| control | FMOVE and FMOVEM of FPCR, FPSR, FPIAR; FMOVEM of FP0-FP7, static and dynamic lists |
| conditional | FBcc, FDBcc, FScc, FTRAPcc, FNOP (UM 9.5.2, Table 9-8) |
| state | FSAVE, FRESTORE (UM 9.8) |

FSGLMUL and FSGLDIV are not in Table 9-10 and the FPSP has no emulation for them
($24, $27 are "illegal extension" in `tbldo.S`), so they are hardware, whatever the PRM's
processor table says (`doc/manual-contradictions.md`). FLOG2 is missing from Table 9-10
but the FPSP emulates it ($16): it is unimplemented, like the rest of the table.

PRM 5 says both that FSGLMUL's and FSGLDIV's operands are truncated to 24 bits and that
they "just change to extended precision". FSGLMUL truncates them and FSGLDIV divides them
whole, as UAE040 does. Both round the result to a single's mantissa with the extended
exponent range.

FPCR's PREC = 11 is "Undefined" (UM Table 9-1); it rounds to double, as UAE040 does.
FPCR's bits 3-0 read as zeros (UM Figure 9-2).

FMOVE and FMOVEM of FPCR, FPSR and FPIAR take (An)+ and -(An) in both directions, as PRM
5's addressing-mode tables have it (its text says otherwise, `doc/manual-contradictions.md`).

An encoding PRM 5 has no instruction for is an F-line illegal instruction (UM 9.6.1:
vector 11, format $0): An as an operand, Dn as an extended, packed or double operand, and
an FMOVEM of FP0-FP7 whose mode field does not match its effective address.

**Unimplemented** (vector 11, format $2, UM 9.6.1): every other opmode of the general
format -- FINT, FINTRZ, FSINH, FLOGNP1, FETOXM1, FTANH, FATAN, FASIN, FATANH, FSIN, FTAN,
FETOX, FTWOTOX, FTENTOX, FLOGN, FLOG10, FLOG2, FCOSH, FACOS, FCOS, FGETEXP, FGETMAN, FMOD,
FREM, FSCALE, FSINCOS -- and FMOVECR. The source operand is fetched and converted first;
the frame is the unimplemented-instruction state frame.

**Unsupported data types** (vector 55, UM 9.6.2): a denormalised single, double or
extended operand, an unnormalised extended one, a packed decimal source or destination
format. The hardware never makes a denormalised result: a result too small for the
rounding precision is an underflow, which on the MC68040 always traps (UM 9.7.5.2), and
the FPSP denormalises it.

## Where it is in the pipeline

The FPU is a multi-cycle unit beside the integer unit's execute stage, as the divider is:
an FP micro-operation in EX starts it, and EX waits until it answers. FP instructions run
one at a time, in order; integer instructions behind one wait too. The part overlaps
integer and FP instructions and can have two FP instructions in its pipeline; here they
do not overlap (`doc/timing-divergences.md`).

**Commit at write-back.** Everything architectural the FPU changes -- FP0-FP7, FPCR,
FPSR, FPIAR, and its exception state -- changes when the micro-operation that computed it
leaves write-back, as the integer registers do. EX computes into a commit record; W
applies it; a micro-operation flushed between the two (an older one faulted) leaves the
FPU as it was, so the instruction runs again from the same state. An FP micro-operation
waits in EX while the one before it has not committed, so the FPU's inputs are always
committed state. Operand staging (the long words of a memory operand, the long words of
a result on its way to memory) is not architectural and is written in EX.

**Micro-operations.** An FP instruction is a sequence:

- the operand's long words, each a load (or an integer register, or an immediate) into
  the FPU's input staging; a byte, word, long or single is one, a double two, an
  extended or packed three;
- the operation: the FPU computes from the staging and the registers, EX waits;
- for a result to memory or an integer register, its long words out of the output
  staging, each a store (or a register write);
- FMOVEM: a long word a micro-operation, three per data register.

## The data path

Internally an operand is a sign, a signed exponent wide enough for any intermediate
result (18 bits, biased by 16383), a 64-bit mantissa with its explicit integer bit, and a
class: zero, infinity, NaN (signalling or not), normal. Unpacking classifies; a
denormalised or unnormalised input stops there (vector 55).

| Operation | How |
|---|---|
| add, subtract | align by the exponent difference with a sticky shift, a 67-bit add, normalise by a leading-zero count |
| multiply | 64 x 64 by 64 x 16 partial products, four clocks, the low bits folded into sticky |
| divide | restoring, a quotient bit a clock, 67 bits and the remainder's sticky |
| square root | restoring, a root bit a clock |
| round | to 24, 53 or 64 bits (FPCR's PREC, the instruction's FS/FD, FSGLxxx's single mantissa, or the destination format), RN RZ RM RP (UM 9.4.2, Figure 9-8); then the range of that precision |
| to integer | round to an integer in FPCR's mode, then the byte, word or long range |

**Range** (UM 9.5.1, 9.7.4, 9.7.5): the intermediate result is checked for underflow
before it is rounded -- an exponent below the precision's smallest normal, except that an
extended result may have the minimum exponent with its integer bit set -- then rounded,
then checked for overflow. Either one is nonmaskable on the MC68040: the destination
register is not written, and the exception is reported for the FPSP to make the IEEE
result.

**NaNs** (PRM 1.6.5): an operation on a NaN returns it with its signalling bit set,
the destination's when both are NaNs; an operand error makes the default NaN, all ones
in the mantissa, $7FFF exponent.

## Exceptions: the model the FPSP needs

The MC68040 reports an FP exception in one of three ways (UM 9.6, 9.7):

- **pre-instruction, posted**: an exception an operation with an FP register destination
  causes -- SNAN, OPERR, DZ or INEX2 when enabled -- is held (*pending*), the
  destination not written (except for inexact, whose rounded result is written, Table
  9-15), and taken when the next FP instruction starts: format $0, the vector of the
  highest-priority exception, the PC that next instruction's, FPIAR the excepting
  instruction's;
- **post-instruction, immediate, to a register**: an overflow or an underflow, always
  (UM 9.7.4.2 and 9.7.5.2 allow "either a pre-instruction or a post-instruction
  exception"; UAE040 takes it at once): format $3, the PC the next instruction's, the
  destination not written, the frame's T bit clear. The FPU stays pending until the
  handler's FSAVE. The condition codes are those of the result the FPSP will store, as
  UAE040 sets them: Table 9-12's for an overflow; for an underflow the denormalised
  result, a zero (Table 9-13) only when nothing of it is left;
- **pre-instruction, immediate**: an unsupported data type in opclass 000 or 010
  (vector 55, format $0, the PC the instruction after it -- the FPSP completes the
  instruction and returns there) and BSUN on a conditional when enabled (vector 48,
  format $0, the PC the conditional's own);
- **post-instruction, immediate**: anything an FMOVE to memory or to an integer
  register causes (opclass 011), taken when it has completed: format $3, EA its effective
  address, the PC the next instruction's; and an unsupported data type there (vector 55),
  taken before anything is stored. "An undefined result is stored" on an overflow or an
  operand error (UM 9.7.3.2, 9.7.4.2): Table 9-12's value for an overflow to a single or a
  double, and an integer saturated, as UAE040 stores them. A packed destination always
  takes vector 55, with (An)+ and -(An) stepped over its twelve bytes first, as UAE040
  does; the frame's EA is the destination's (-(An)'s new An).

An unimplemented instruction is vector 11 with format $2 (EA its calculated effective
address), after any pending exception has been taken.

**Which vector** (UM 9.7): the first, in BSUN, SNAN, OPERR, OVFL, UNFL, DZ, INEX2/INEX1
order, of the exceptions the FPSR's EXC byte has and the FPCR enables, together with the
nonmaskable ones the frame's NMCEXC bits record (SNAN, OPERR, OVFL, UNFL, and the
unsupported type); an overflow with OVFL disabled and INEX2 enabled is the inexact one
(UM 9.7.7's note). The same rule chooses the vector when an FRESTOREd frame left an
exception pending -- which is how the FPSP reports an exception from an emulated
instruction (`gen_except.S`): it FRESTOREs a frame with E1 or E3 set, and the next FP
instruction takes it.

**E1 and E3** (UM 9.8, Table 9-16): an exception of FADD, FSUB, FMUL, FDIV or FSQRT (and
their FS/FD forms, FSGLMUL, FSGLDIV) in opclass 000 or 010 that is an overflow, an
underflow or an inexact result is an E3 one -- the intermediate result in WBTEMP, the
command word in CMDREG3B (Figure 9-11). Every other exception is an E1 one -- the
operands in ETEMP and FPTEMP, the command word in CMDREG1B.

## The state frames

The FPU's exception state is a busy frame's image: 25 long words (UM Figure 9-10, the
FPSP's `fpsp.h` for the fields' bits), kept as registers so that a frame FRESTOREd
comes back from the next FSAVE exactly, the fields the FPSP writes and this design does
not interpret (the S and X flags, FPSR_SHADOW, CMDREG2B, the dirty bits) included. The
unimplemented-instruction frame is the busy frame's last twelve long words behind its own
format word (the FPSP's "the last 10 words of a busy frame are the same").

| State | FSAVE writes | When |
|---|---|---|
| null | $00000000 | after reset, or FRESTORE of a null frame, until the first FP instruction that is not a conditional (UM 9.8) |
| idle | $41000000 | nothing pending |
| unimplemented | $4130 and 12 long words | after an unimplemented instruction (U set; E1 for a packed source only, `doc/manual-contradictions.md` 9 -- M13), or an E1 arithmetic exception (E1, U clear; the FPSP's `x_snan.S` expands it to a busy frame) |
| busy | $4160 and 24 long words | after an unsupported data type, an E3 arithmetic exception or an FMOVE out's, or FRESTORE of one |

FSAVE waits for the FPU, writes the frame and leaves the FPU idle (the pending exception
gone with it, UM 9.7.1.1: "FSAVE allows other floating-point instructions to execute").
FRESTORE of a null frame resets the FPU (FP0-FP7 NaN, FPCR, FPSR, FPIAR zero); of an idle
one makes it idle; of an unimplemented or busy one loads the image: E1 or E3 set leaves
the exception pending; neither set, with CU_SAVEPC $FE, runs the instruction in CMDREG1B
on ETEMP and FPTEMP -- 16-bit exponents, ETE15 and FPTE15 their top bits -- as the FPSP's
unsupported data type handler expects ("the function is then restored back into the
machine and the 040 completes the operation", `res_func.S`), committing its result and
any exception it makes; otherwise nothing.

The fields the hardware writes, per exception (UM Table 9-16):

| Exception | Fields |
|---|---|
| unimplemented instruction | CMDREG1B; ETEMP the source, converted (a packed one's 96 bits as they are, FPTEMP 31-0 and ETEMP); STAG; FPTEMP the destination register; DTAG; E1 if the source is packed; U |
| unsupported type, opclass 000/010 | CMDREG1B; ETEMP the source (a denormalised one as stored, a single or double in Figure 9-9's form); STAG 100 or 101; FPTEMP, DTAG; E1 |
| unsupported type, opclass 011 | CMDREG1B; ETEMP the source register; STAG; E1; T |
| SNAN, OPERR, DZ, opclass 000/010 | CMDREG1B; ETEMP, STAG; FPTEMP, DTAG; E1 |
| SNAN, OPERR, opclass 011 | CMDREG1B; ETEMP the source register (an SNAN with its bit set); STAG; WBTEMP the rounded integer (OPERR); E1; T |
| OVFL, UNFL, INEX, FMOVE in, FABS, FNEG | CMDREG1B; FPTEMP the intermediate result (OVFL: rounded; UNFL, INEX: not); STAG normal; E1 |
| OVFL, UNFL, INEX, the E3 operations | CMDREG3B; WBTEMP the intermediate result (OVFL: rounded; UNFL, INEX: not, with guard, round and sticky), WBTE15; E3 |
| OVFL, UNFL, INEX, FMOVE out | CMDREG1B; FPTEMP the intermediate result; STAG normal; E1; T |

WBTEMP's 15-bit exponent is the low bits of the 16-bit biased intermediate exponent, which
the FPSP sign-extends from bit 14 (`round.S`, `denorm`); WBTE15 is its bit 15. CU_SAVEPC
is written as zero, FPIARCU as FPIAR. The NMCEXC bits record the nonmaskable exceptions,
as the FPSP's own frames do (`gen_except.S`, `do_build`).

## Checked by

- `make testfloat`: the data path alone (`sim/tb/fpu_dp_tb.sv`) against Berkeley TestFloat,
  extF80 in the three rounding precisions, f32 and f64, every rounding mode; underflow and
  overflow checked as the trap they are here, NaNs left to the oracles below;
- `make cputest`: the FPU corpus (every FP instruction cputestgen knows, the unimplemented
  ones included, each with the FNOP the generator puts after it, so that what it posts is
  taken in the test) against UAE040. The disagreements are counted, not hidden
  (`tools/cputest/convert.py`, `doc/oracles.md`): the F-line illegal encodings above,
  which UAE040 runs; an unsupported data type in opclass 000/010, which UAE040 stacks as
  format $3 and which is compared as format $0; FPCR's bits 3-0, compared as zeros; a
  NaN's or an infinity's integer bit, a don't care (UM Table 9-5);
- `make cosim`: `m11_fpu_a` and `m11_fpu_b`, FP code and its exceptions, register for
  register against UAE040;
- `core_fpu_tb` (`m11_fpu_c`): what UAE040 does otherwise, against the manual and the
  FPSP's frame contract -- the null, idle, unimplemented and busy frames, the formats of
  the unimplemented and unsupported traps, a posted exception's frame, a busy frame's
  round trip, FRESTORE that resumes an operation;
- from M13, `make fpsp`: the M68040FPSP on the core, as Linux's own in rd-virt
  (`doc/plan.md`, M11's gate).

## The MC68LC040 (M12)

With `FPU = 0` the core has no `rd68041_fpu` (`g_nofpu` in `rd68041_core.sv`: its outputs
are constants, and nothing of the register file, the data path or the frames is built).
The decoder still decodes every FP instruction as far as it does for the MC68040 -- its
length, its \<ea\>, whether PRM 5 has it at all (`rd68041_fpu_pkg::legal_op`, the same
opmode set the FPU's F-line uses) -- and then makes it one micro-operation that calculates
the address without accessing it or stepping An, and is vector 11 once it is done
(`xnext`): write-back stacks the eight-word format $4 frame (UM A.5.2), its address field
the calculated one, its last long word the instruction's PC. A memory indirect mode's
pointer is read by the usual prelude first. An encoding PRM 5 has no instruction for is
F-line illegal, format $0, as on the MC68040; FSAVE and FRESTORE in user mode are a
privilege violation; RTE takes the format $4 frame (and the MC68040's RTE refuses it, a
format error). What the address field is for each mode is in `doc/checkpoint.md` and
`doc/divergences.md`.

Checked by `make cosim-lc` (`m12_lc040` and the integer programs against UAE040 `-L`),
`make vectors OP=lc040 FPU=0`, and `core_lc040_tb` (`m12_lc040_b`) where UAE040 `-L`
stacks what the manual does not (`doc/oracles.md`).
