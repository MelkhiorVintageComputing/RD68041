/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Copyright 2026 Romain Dolbeau */
/* Source location: https://github.com/MelkhiorVintageComputing/RD68041 */

/*
 * uae040 -- the WinUAE MC68040 CPU core (Hatari's src/cpu copy) as a
 * standalone instruction + MMU + cache + FPU oracle, behind a small library
 * interface. It is RD68031's uae030 (tools/cosim/uae030 there) retargeted.
 *
 * Memory is flat physical RAM from 0. Everything above it answers with a bus
 * error, unless uae040_set_alias() folds a window of the address space onto
 * the RAM, or uae040_add_region() puts another memory in front of it. No
 * chipset; the devices and interrupts of M13's rd-virt come through the
 * calls at the end.
 *
 * One run per process: uae040_run() enters the core once and stays there
 * until the instruction hook asks to stop. A front-end that needs many short
 * runs (one instruction per test) does it from inside the instruction hook,
 * with uae040_set_state(), or with uae040_run_each().
 *
 * The configuration (doc/oracles.md, "UAE040"): cpu_model 68040, mmu_model
 * 68040, fpu_model 68040 (or 0, the MC68LC040), cpu_compatible (prefetch and
 * the instruction cache), the data cache with copyback, unimplemented FP
 * instructions trapping as on the part (fpu_no_unimplemented), softfloat
 * FPU, 32-bit addressing, and the host-side page caches in front of the ATC
 * compiled out.
 *
 * UAE040 is an ORACLE, not a source: where it and the manual disagree, the
 * manual decides.
 */
#ifndef UAE040_H
#define UAE040_H

#include <stdint.h>

/* What a physical bus access is. */
enum uae040_kind {
	UAE040_KIND_CPU = 0,    /* an operand or stack access that reached the bus
				   (cache-inhibited, write-through, or a miss that
				   allocates nothing) */
	UAE040_KIND_WALK = 1,   /* a table search descriptor read or U/M update */
	UAE040_KIND_IFETCH = 2, /* an instruction fetch (prefetch or I-cache fill) */
	UAE040_KIND_PUSH = 3,   /* a dirty data-cache line written back (copyback
				   push: replacement, CPUSH, or a hit on a page
				   that is now cache-inhibited) */
	UAE040_KIND_FILL = 4,   /* a data-cache line fill (one long word of it) */
	UAE040_KIND_MOVE16 = 5, /* one long word of a MOVE16 line transfer */
};

/* One physical access, as the bus hook sees it. */
typedef struct uae040_bus {
	uint32_t pa;      /* physical address */
	uint32_t data;    /* value, right justified (0 on a bus error read) */
	int size;         /* 1, 2 or 4 bytes (lines are reported as 4 longs) */
	int write;
	int kind;         /* enum uae040_kind */
	int tt, tm;       /* the TT1-TT0 / TM2-TM0 the harness derives for it,
			     UM table 5-2/5-3/5-4 (not the oracle's: it has no
			     such notion; see doc/oracles.md) */
	int fc;           /* the function code the access is made for (for a
			     table search: the translated access's) */
	int lock;         /* inside a locked read-modify-write (TAS, CAS, CAS2) */
	int berr;         /* the access answered with a bus error */
} uae040_bus;

typedef struct uae040_fpreg {
	uint16_t exp;     /* sign and exponent, as FMOVEM.X stores them */
	uint64_t mant;    /* the 64-bit mantissa, explicit integer bit */
} uae040_fpreg;

typedef struct uae040_state {
	uint32_t pc;           /* address of the next instruction to execute */
	uint32_t d[8], a[8];   /* a[7] = active stack pointer */
	uint32_t usp, isp, msp;
	uint16_t sr;
	uint32_t vbr, sfc, dfc, cacr;
	uint32_t tc, urp, srp, itt0, itt1, dtt0, dtt1, mmusr;
	uae040_fpreg fp[8];
	uint32_t fpcr, fpsr, fpiar;
	uint64_t insn_count;
	int d_hit, d_miss, i_hit, i_miss; /* cache statistics of the last instruction */
} uae040_state;

/* Called before each instruction is executed (after the previous one and
 * any exception it raised have been processed). Return nonzero to stop. */
typedef int (*uae040_insn_hook)(const uae040_state *s, void *user);

/* Called on every physical bus access. Cache hits do not appear. */
typedef void (*uae040_bus_hook)(const uae040_bus *b, void *user);

/* Called once per OPERAND access made by an instruction or by exception
 * processing, whether or not it reached the bus (a data-cache hit is still
 * an operand): its logical address la, its physical address pa, its size
 * and value. An operand that crosses a page is reported once, at its first
 * byte, with its whole size and value. Instruction fetches, table searches,
 * pushes and fills never appear. A MOVE16 appears as four long words.
 * berr: the operand ended in a bus error. */
typedef void (*uae040_op_hook)(uint32_t la, uint32_t pa, int size, int write,
			       uint32_t data, int fc, int berr, void *user);

/* Called when exception processing starts, with the vector number. */
typedef void (*uae040_exc_hook)(int vector, void *user);

/* ram_bytes of flat RAM; data_cache 0 turns the data-cache emulation off;
 * fpu 0 makes the processor an MC68LC040 (no FPU). */
void uae040_init(uint32_t ram_bytes, int data_cache, int fpu);
/* Physical addresses below `window` (a power of two, at least the RAM size)
 * address the RAM modulo its size; 0 turns aliasing off (the default). */
void uae040_set_alias(uint32_t window);
/* One more physical region, consulted before the RAM: addresses with
 * (a & mask) == base reach a zeroed store of `size` bytes (a power of two)
 * repeated through the window, or, with berr set, answer with a bus error.
 * Returns the region's number, or -1 when there is no room (eight at most). */
int uae040_add_region(uint32_t base, uint32_t mask, uint32_t size, int berr);
uint8_t *uae040_region_mem(int i);
uint8_t *uae040_ram(void);
uint32_t uae040_ram_size(void);
/* A raw binary at physical `phys`; returns the bytes read, or -1. */
int uae040_load(const char *path, uint32_t phys);
/* A Motorola S-record file (S1/S2/S3 data, addresses physical); returns the
 * bytes loaded or -1. *entry gets the S7/S8/S9 address when there is one. */
int uae040_load_srec(const char *path, uint32_t *entry);
void uae040_set_hooks(uae040_insn_hook ih, uae040_bus_hook bh, void *user);
void uae040_set_op_hook(uae040_op_hook oh);
void uae040_set_exc_hook(uae040_exc_hook eh);
void uae040_get_state(uae040_state *s);
/* From inside the instruction hook only: replace the integer programmer's
 * model (PC, D0-D7, A0-A6, USP, ISP, MSP, SR, VBR, SFC, DFC, CACR; a[7] is
 * derived from SR), invalidate both caches without pushing them, and
 * refetch at the new PC. The MMU and FPU registers are left alone. */
void uae040_set_state(const uae040_state *s);
/* Install TC, URP, SRP, ITT0/1, DTT0/1 and MMUSR from *s as MOVEC would,
 * and flush the ATCs. */
void uae040_set_mmu(const uae040_state *s);
/* Install FP0-FP7, FPCR, FPSR and FPIAR from *s. */
void uae040_set_fpu(const uae040_state *s);
/* The cache control register, cheaply, from inside a hook. */
uint32_t uae040_cacr(void);
/* One instruction per test, many tests per run (uae030_run_each's contract:
 * result() for the test just run, then setup() for the next, which fills
 * *st and the memory; uae040_set_state() then installs it). Returns 0 when
 * every test ran, 1 if the oracle halted part way; *done = tests completed. */
typedef void (*uae040_setup_fn)(int i, uae040_state *st, void *user);
typedef void (*uae040_result_fn)(int i, const uae040_state *st, void *user);
int uae040_run_each(int ntests, uae040_setup_fn setup, uae040_result_fn result,
		    void *user, int *done);
/* M13 (sim/virt): a machine with devices.
 *
 * uae040_set_ext_bus: every physical access that no region and no RAM
 * claims goes to these instead of answering with a bus error; read returns
 * nonzero for a bus error (and fills *v otherwise), write likewise. size is
 * 1, 2 or 4, the address the access's own. (Cachability is the MMU's on the
 * 68040 -- TTRs, page descriptors, the defaults -- so there is no CIIN.)
 * uae040_interrupt: from inside the instruction hook only -- take the
 * interrupt exception for `level` (autovectored) now, at this boundary, as
 * the processor would between two instructions; the next boundary is the
 * handler's first instruction.
 * uae040_stopped: nonzero while STOP holds the processor.
 * uae040_last_opcode: the operation word of the instruction that ran last,
 * from inside the instruction hook (after a fault, the faulted one's).
 * uae040_poke: from inside the instruction hook, a write (size 1, 2 or 4) at
 * a supervisor data address through the core's own path -- translation,
 * data cache and bus hook included. */
typedef int (*uae040_ext_read)(uint32_t pa, int size, uint32_t *v, void *user);
typedef int (*uae040_ext_write)(uint32_t pa, int size, uint32_t v, void *user);
void uae040_set_ext_bus(uae040_ext_read rd, uae040_ext_write wr, void *user);
void uae040_interrupt(int level);
int uae040_stopped(void);
uint16_t uae040_last_opcode(void);
void uae040_poke(uint32_t addr, int size, uint32_t v);
/* From inside the instruction hook: D0-D7, A0-A6, the three stack pointers
 * and the condition codes (SR's low byte) from *s, and nothing else -- the
 * caches, the PC, the prefetch and the system byte are left as they are
 * (uae040_set_state invalidates the caches). */
void uae040_set_regs(const uae040_state *s);

/* Reset (SSP and PC from physical 0 and 4) and run until the instruction
 * hook asks to stop or the processor halts (double fault). Returns 0 on a
 * hook stop, 1 on a halt. */
int uae040_run(void);

#endif
