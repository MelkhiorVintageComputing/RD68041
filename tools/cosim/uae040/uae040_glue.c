/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Copyright 2026 Romain Dolbeau */
/* Source location: https://github.com/MelkhiorVintageComputing/RD68041 */

/*
 * Glue between Hatari's copy of the WinUAE CPU core (src/cpu) and a bare
 * flat-RAM machine, configured as an MC68040 (or MC68LC040). Replaces
 * Hatari's memory.c, hatari-glue.c, custom.c and events.c, and stubs every
 * Atari-side symbol the core references. RD68031's uae030_glue.c, retargeted.
 *
 * Compiled against Hatari's own headers (src/includes, src/debug, src/falcon)
 * so the core's view of every type is unchanged.
 */
#include <setjmp.h>
#include <stdarg.h>

#include "main.h"
#include "sysconfig.h"
#include "sysdeps.h"
#include "options_cpu.h"
#include "memory.h"
#include "newcpu.h"
#include "cpummu.h"
#include "mmu_common.h"
#include "fpp.h"
#include "savestate.h"
#include "hatari-glue.h"
#include "m68000.h"
#include "log.h"

#include "uae040.h"

/* ------------------------------------------------------------------ */
/* Harness state                                                       */

static uint8_t *ram;
static uint32_t ram_size;
static uint32_t alias_window;
static uae040_insn_hook insn_hook;
static uae040_bus_hook bus_hook;
static uae040_op_hook op_hook;
static uae040_exc_hook exc_hook;
static void *hook_user;
static jmp_buf run_exit;
static int run_status;
static uint64_t insn_count;

/* Set by the patched core (build.sh): the function code of the access in
 * progress (1b), around table-search descriptor accesses and what the
 * search is for (1c), around MOVE16's line (1d), while MOVES or a locked
 * read-modify-write runs (1e), and around a data-cache push or line fill
 * (1f). Instruction fetches are told by the routine the core reads them
 * through (memory_get_longi below). */
int uae040_bus_fc = 5;
int uae040_bus_walk = 0;
int uae040_bus_move16 = 0;
int uae040_bus_push = 0;
int uae040_bus_fill = 0;
int uae040_walk_data = 1;
int uae040_walk_super = 1;
int uae040_walk_insn = 0;
int uae040_moves = 0;
int uae040_locked = 0;
static int bus_ifetch = 0;

/* Extra physical regions in front of the RAM (uae040_add_region). */
#define UAE040_NREG 8
static struct {
	uint32_t base, mask, size;
	int berr;
	uint8_t *mem;
} region[UAE040_NREG];
static int nregion;

/* The operand in progress (uae040_op_begin/end, called by the patched access
 * routines), and an operand the core moves as several pieces because it
 * crosses a page (the page-crossing routines are wrapped at link time,
 * -Wl,--wrap: OWRAP040 in the Makefile) -- reported once, as the one operand
 * it is. */
static struct {
	int active, berr, fc, size, write;
	uint32_t la, pa, v;
} op_cur;
static struct {
	int depth, have, berr, fc, size, write;
	uint32_t la, pa, v;
} op_wrap;

static void clear_flags(void)
{
	/* An exception longjmps out of whoever set these. */
	uae040_bus_walk = uae040_bus_move16 = uae040_bus_push = uae040_bus_fill = 0;
	uae040_walk_insn = 0;
	bus_ifetch = 0;
}

/* ------------------------------------------------------------------ */
/* Hatari / UAE globals the core expects                               */

struct uae_prefs currprefs, changed_prefs;
int pendingInterrupts;
uae_u32 extra_cycle;
int CurrentInstrCycles, nCyclesMainCounter, WaitStateCycles;
uint64_t CyclesGlobalClockCounter;
uint64_t CycInt_ActiveInt_Cycles = UINT64_MAX; /* no Hatari timer events, ever */
bool bDspEnabled, MFP_UpdateNeeded, CpuRunFuncNoret, CpuRunCycleExact, CPU_IACK;
bool bQuitProgram, bVdiAesIntercept;
int LastOpcodeFamily, LastInstrCycles, Pairing;
char PairingArray[MAX_OPCODE_FAMILY][MAX_OPCODE_FAMILY];
cpu_instruction_t CpuInstruction;
uint16_t BlitterPhase;
uint32_t VDI_OldPC;
int ExceptionDebugMask;
uae_u32 hsync_counter, vsync_counter;
int savestate_state;
TCHAR savestate_fname[MAX_DPATH];
evt_t currcycle;
uae_u8 ce_banktype[65536], ce_cachable[65536];
addrbank *mem_banks[MEMORY_BANKS];

void CycInt_CallActiveHandler(uint64_t Clock) { (void)Clock; }
void MFP_UpdateIRQ_All(uint64_t t) { (void)t; }
void MFP_DelayIRQ(void) {}
int MFP_ProcessIACK(int v) { return v; }
int SCC_Process_IACK(void) { return 29; }
int DSP_ProcessIACK(void) { return -1; }
uint8_t DSP_GetHREQ(void) { return 0; }
void DSP_Run(int n) { (void)n; }
void Blitter_HOG_CPU_mem_access_before(int n) { (void)n; }
void Blitter_HOG_CPU_mem_access_after(int n) { (void)n; }
void M68000_ClearIRQ(int n) { (void)n; }
void M68000_Update_intlev(void) {}
void M68000_RestoreDebugger(void) {}
bool M68000_IsVerboseBusError(uint32_t pc, uint32_t addr) { (void)pc; (void)addr; return false; }
int M68000_WaitEClock(void) { return 0; }
void M68000_PatchCpuTables(void)
{
	/* Hatari's private opcodes are plain illegal instructions here. */
	static const int ops[] = { 0x0008, 0x0009, 0x000a, 0x000c, 0x7300, 0x7301 };
	for (unsigned i = 0; i < sizeof(ops) / sizeof(ops[0]); i++) {
		cpufunctbl[ops[i]] = cpufunctbl[0x4afc];
		cpufunctbl_noret[ops[i]] = cpufunctbl_noret[0x4afc];
	}
}
bool XBios(void) { return false; }
bool Bios(void) { return false; }
bool VDI_AES_Entry(void) { return false; }
const char *Symbols_GetByCpuAddress(uint32_t a, int t) { (void)a; (void)t; return NULL; }
bool Profile_CpuAddr_HasData(uint32_t a) { (void)a; return false; }
int Profile_CpuAddr_DataStr(char *b, int m, uint32_t a) { (void)b; (void)m; (void)a; return 0; }
static void op_flush(void);
/* Called by the core when exception processing starts (exception_debug). An
 * operand cut short by the exception is reported first, so that the operand
 * list stays in order ahead of the frame the exception writes. */
void DebugUI_Exceptions(int nr, long pc)
{
	(void)pc;
	op_flush();
	clear_flags();
	if (exc_hook)
		exc_hook(nr, hook_user);
}
void DebugUI(int r) { (void)r; }
void DebugCpu_Check(void) {}
void Dialog_HaltDlg(void)
{
	/* Double fault / CPU stuck: end the run. */
	run_status = 1;
	longjmp(run_exit, 1);
}
void Log_Printf(LOGTYPE t, const char *fmt, ...)
{
	if (t > LOG_WARN)
		return;
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
}

/* savestate: never used */
void save_u64(uae_u64 d) { (void)d; }
void save_u32(uae_u32 d) { (void)d; }
void save_u16(uae_u16 d) { (void)d; }
void save_u8(uae_u8 d) { (void)d; }
void save_s8(uae_s8 d) { (void)d; }
uae_u64 restore_u64(void) { return 0; }
uae_u32 restore_u32(void) { return 0; }
uae_u16 restore_u16(void) { return 0; }
uae_u8 restore_u8(void) { return 0; }
uae_s8 restore_s8(void) { return 0; }
int save_state(const TCHAR *f, const TCHAR *d) { (void)f; (void)d; savestate_state = 0; return 0; }
void restore_state(const TCHAR *f) { (void)f; }
void savestate_restore_final(void) {}
bool savestate_restore_finish(void) { return false; }

/* hatari-glue.c / custom.c / events.c replacements */
void customreset(void) {}
int intlev(void) { return 0; }
void custom_reset(bool h, bool k) { (void)h; (void)k; }
void reset_frame_rate_hack(void) {}
void fpux_restore(int *v) { (void)v; }
void do_cycles_slow(int c) { currcycle += c; }
void do_cycles_ce(int c) { currcycle += c; }
void do_cycles_ce020(int c) { currcycle += c; }
void do_cycles_ce_hatari_blitter(int c) { currcycle += c; }
bool is_cycle_ce(uaecptr a) { (void)a; return false; }
void fixup_cpu(struct uae_prefs *p)
{
	if (p->cpu_cycle_exact)
		p->cpu_compatible = true;
}
TCHAR *buf_out(TCHAR *buffer, int *bufsize, const TCHAR *format, ...)
{
	va_list ap;
	if (!buffer)
		return NULL;
	va_start(ap, format);
	vsnprintf(buffer, (*bufsize) - 1, format, ap);
	va_end(ap);
	*bufsize -= strlen(buffer);
	return buffer + strlen(buffer);
}

/* ------------------------------------------------------------------ */
/* Operands                                                            */

static void op_report(uint32_t la, uint32_t pa, int size, int write, uint32_t v, int fc, int berr)
{
	if (op_hook)
		op_hook(la, pa, size, write, v, fc, berr, hook_user);
}

void uae040_op_begin(uae_u32 la, uae_u32 pa, int size, int write, uae_u32 v)
{
	if (op_wrap.depth) {
		if (!op_wrap.have) {
			op_wrap.have = 1;
			op_wrap.la = la;
			op_wrap.pa = pa;
			op_wrap.fc = uae040_bus_fc;
		}
		return;
	}
	op_cur.active = 1;
	op_cur.berr = 0;
	op_cur.la = la;
	op_cur.pa = pa;
	op_cur.size = size;
	op_cur.write = write;
	op_cur.v = v;
	op_cur.fc = uae040_bus_fc;
}

void uae040_op_end(uae_u32 v)
{
	if (op_wrap.depth || !op_cur.active)
		return;
	op_cur.active = 0;
	op_report(op_cur.la, op_cur.pa, op_cur.size, op_cur.write, v, op_cur.fc, op_cur.berr);
}

static void wrap_begin(int size, int write, uint32_t v)
{
	if (op_wrap.depth++)
		return;
	op_wrap.have = 0;
	op_wrap.berr = 0;
	op_wrap.size = size;
	op_wrap.write = write;
	op_wrap.v = v;
}

static void wrap_end(uint32_t v)
{
	if (--op_wrap.depth)
		return;
	if (op_wrap.have)
		op_report(op_wrap.la, op_wrap.pa, op_wrap.size, op_wrap.write, v, op_wrap.fc, op_wrap.berr);
	op_wrap.have = 0;
}

/* An operand the exception cut short: report what it reached, once. */
static void op_flush(void)
{
	if (op_wrap.depth) {
		op_wrap.depth = 1;
		wrap_end(op_wrap.write ? op_wrap.v : 0);
	}
	op_wrap.depth = 0;
	if (op_cur.active)
		uae040_op_end(op_cur.write ? op_cur.v : 0);
}

extern uae_u16 __real_mmu_get_word_unaligned(uaecptr, bool);
extern uae_u32 __real_mmu_get_long_unaligned(uaecptr, bool);
extern void __real_mmu_put_word_unaligned(uaecptr, uae_u16, bool);
extern void __real_mmu_put_long_unaligned(uaecptr, uae_u32, bool);
extern uae_u32 __real_sfc_get_long(uaecptr);
extern uae_u16 __real_sfc_get_word(uaecptr);
extern void __real_dfc_put_long(uaecptr, uae_u32);
extern void __real_dfc_put_word(uaecptr, uae_u16);
extern uae_u32 __real_uae_mmu_get_lrmw(uaecptr, int, int);
extern void __real_uae_mmu_put_lrmw(uaecptr, uae_u32, int, int);

uae_u16 __wrap_mmu_get_word_unaligned(uaecptr a, bool d)
{
	wrap_begin(2, 0, 0);
	uae_u16 v = __real_mmu_get_word_unaligned(a, d);
	wrap_end(v);
	return v;
}
uae_u32 __wrap_mmu_get_long_unaligned(uaecptr a, bool d)
{
	wrap_begin(4, 0, 0);
	uae_u32 v = __real_mmu_get_long_unaligned(a, d);
	wrap_end(v);
	return v;
}
void __wrap_mmu_put_word_unaligned(uaecptr a, uae_u16 v, bool d)
{
	wrap_begin(2, 1, v);
	__real_mmu_put_word_unaligned(a, v, d);
	wrap_end(v);
}
void __wrap_mmu_put_long_unaligned(uaecptr a, uae_u32 v, bool d)
{
	wrap_begin(4, 1, v);
	__real_mmu_put_long_unaligned(a, v, d);
	wrap_end(v);
}
uae_u32 __wrap_sfc_get_long(uaecptr a)
{
	wrap_begin(4, 0, 0);
	uae_u32 v = __real_sfc_get_long(a);
	wrap_end(v);
	return v;
}
uae_u16 __wrap_sfc_get_word(uaecptr a)
{
	wrap_begin(2, 0, 0);
	uae_u16 v = __real_sfc_get_word(a);
	wrap_end(v);
	return v;
}
void __wrap_dfc_put_long(uaecptr a, uae_u32 v)
{
	wrap_begin(4, 1, v);
	__real_dfc_put_long(a, v);
	wrap_end(v);
}
void __wrap_dfc_put_word(uaecptr a, uae_u16 v)
{
	wrap_begin(2, 1, v);
	__real_dfc_put_word(a, v);
	wrap_end(v);
}
uae_u32 __wrap_uae_mmu_get_lrmw(uaecptr a, int size, int type)
{
	wrap_begin(size == sz_byte ? 1 : size == sz_word ? 2 : 4, 0, 0);
	uae_u32 v = __real_uae_mmu_get_lrmw(a, size, type);
	wrap_end(v);
	return v;
}
void __wrap_uae_mmu_put_lrmw(uaecptr a, uae_u32 v, int size, int type)
{
	wrap_begin(size == sz_byte ? 1 : size == sz_word ? 2 : 4, 1, v);
	__real_uae_mmu_put_lrmw(a, v, size, type);
	wrap_end(v);
}

/* ------------------------------------------------------------------ */
/* Physical memory                                                     */

static void bus_report(uint32_t pa, int size, int write, uint32_t data, int berr)
{
	uae040_bus b;
	int fc = uae040_bus_fc;
	b.pa = pa;
	b.size = size;
	b.write = write;
	b.data = berr ? 0 : data;
	b.berr = berr;
	b.lock = uae040_locked;
	b.tt = 0;
	if (uae040_bus_push) {
		b.kind = UAE040_KIND_PUSH;
		b.tm = 0;
		fc = 5;
	} else if (uae040_bus_fill) {
		b.kind = UAE040_KIND_FILL;
		b.tm = fc;
	} else if (uae040_bus_walk) {
		b.kind = UAE040_KIND_WALK;
		fc = (uae040_walk_super ? 4 : 0) | (uae040_walk_data ? 1 : 2);
		b.tm = uae040_walk_data ? 3 : 4;
	} else if (uae040_bus_move16) {
		b.kind = UAE040_KIND_MOVE16;
		b.tt = 1;
		b.tm = fc;
	} else if (bus_ifetch) {
		b.kind = UAE040_KIND_IFETCH;
		fc = regs.s ? 6 : 2;
		b.tm = fc;
	} else {
		b.kind = UAE040_KIND_CPU;
		b.tm = fc;
		/* UM table 5-4: MOVES with function code 0, 3, 4 or 7 is an
		 * alternate access; with 1, 2, 5 or 6 a normal one. */
		if (uae040_moves && ((fc & 3) == 0 || (fc & 3) == 3))
			b.tt = 2;
	}
	b.fc = fc;
	if (berr) {
		if (op_wrap.depth)
			op_wrap.berr = 1;
		else if (op_cur.active)
			op_cur.berr = 1;
	}
	if (bus_hook)
		bus_hook(&b, hook_user);
}

/* The physical address map: the extra regions first, then RAM from 0, or a
 * window folded onto it. Returns where the access's first byte is, or NULL
 * for a bus error. */
static inline uint8_t *map_ptr(uint32_t a, int size)
{
	for (int i = 0; i < nregion; i++) {
		if ((a & region[i].mask) != region[i].base)
			continue;
		if (region[i].berr)
			return NULL;
		uint32_t o = a % region[i].size;
		if ((uint64_t)o + size > region[i].size)
			return NULL;
		return region[i].mem + o;
	}
	if (alias_window && a < alias_window)
		a %= ram_size;
	if (a < ram_size && (uint64_t)a + size <= ram_size)
		return ram + a;
	return NULL;
}

static uint32_t phys_read(uint32_t a, int size)
{
	uint8_t *p = map_ptr(a, size);
	if (!p) {
		bool ins = bus_ifetch != 0;
		bus_report(a, size, 0, 0, 1);
		clear_flags();
		hardware_exception2(a, 0, true, ins, size == 1 ? sz_byte : size == 2 ? sz_word : sz_long);
		return 0xffffffff;
	}
	uint32_t v = 0;
	for (int i = 0; i < size; i++)
		v = (v << 8) | p[i];
	bus_report(a, size, 0, v, 0);
	return v;
}

static void phys_write(uint32_t a, int size, uint32_t v)
{
	uint8_t *p = map_ptr(a, size);
	if (!p) {
		bus_report(a, size, 1, v, 1);
		clear_flags();
		hardware_exception2(a, v, false, false, size == 1 ? sz_byte : size == 2 ? sz_word : sz_long);
		return;
	}
	bus_report(a, size, 1, v, 0);
	for (int i = size - 1; i >= 0; i--) {
		p[i] = (uint8_t)v;
		v >>= 8;
	}
}

uae_u32 memory_get_long(uaecptr a) { return phys_read(a, 4); }
uae_u32 memory_get_word(uaecptr a) { return phys_read(a, 2); }
uae_u32 memory_get_byte(uaecptr a) { return phys_read(a, 1); }
/* The 68040 core reads the instruction stream through these (its
 * instruction-cache fill and its uncached prefetch both do), so they are
 * instruction fetches whatever the last function code was. */
static uint32_t ifetch_read(uint32_t a, int size)
{
	int f = bus_ifetch;
	bus_ifetch = 1;
	uint32_t v = phys_read(a, size);
	bus_ifetch = f;
	return v;
}
uae_u32 memory_get_longi(uaecptr a) { return ifetch_read(a, 4); }
uae_u32 memory_get_wordi(uaecptr a) { return ifetch_read(a, 2); }
void memory_put_long(uaecptr a, uae_u32 v) { phys_write(a, 4, v); }
void memory_put_word(uaecptr a, uae_u32 v) { phys_write(a, 2, v & 0xffff); }
void memory_put_byte(uaecptr a, uae_u32 v) { phys_write(a, 1, v & 0xff); }

/* cycle-exact access paths (not selected by this harness, but linked) */
uae_u32 wait_cpu_cycle_read(uaecptr a, int mode)
{
	return mode < 0 ? phys_read(a, 4) : mode > 0 ? phys_read(a, 2) : phys_read(a, 1);
}
void wait_cpu_cycle_write(uaecptr a, int mode, uae_u32 v)
{
	if (mode < 0) phys_write(a, 4, v); else if (mode > 0) phys_write(a, 2, v & 0xffff); else phys_write(a, 1, v & 0xff);
}
uae_u32 wait_cpu_cycle_read_ce020(uaecptr a, int mode) { return wait_cpu_cycle_read(a, mode); }
void wait_cpu_cycle_write_ce020(uaecptr a, int mode, uae_u32 v) { wait_cpu_cycle_write(a, mode, v); }

uae_u8 *memory_get_real_address(uaecptr a) { return map_ptr(a, 1); }
int memory_valid_address(uaecptr a, uae_u32 s) { return map_ptr(a, s) != NULL; }
void memory_clear(void) { /* keep the loaded image across the reset */ }

/* debugger / logging peeks: no bus activity */
static uint8_t peek8(uint32_t a) { uint8_t *p = map_ptr(a, 1); return p ? *p : 0; }
uint32_t STMemory_ReadLong(uint32_t a) { return (peek8(a) << 24) | (peek8(a + 1) << 16) | (peek8(a + 2) << 8) | peek8(a + 3); }
uint16_t STMemory_ReadWord(uint32_t a) { return (peek8(a) << 8) | peek8(a + 1); }
uint8_t STMemory_ReadByte(uint32_t a) { return peek8(a); }

static uae_u32 REGPARAM2 flat_lget(uaecptr a) { return phys_read(a, 4); }
static uae_u32 REGPARAM2 flat_wget(uaecptr a) { return phys_read(a, 2); }
static uae_u32 REGPARAM2 flat_bget(uaecptr a) { return phys_read(a, 1); }
static uae_u32 REGPARAM2 flat_lgeti(uaecptr a) { return ifetch_read(a, 4); }
static uae_u32 REGPARAM2 flat_wgeti(uaecptr a) { return ifetch_read(a, 2); }
static void REGPARAM2 flat_lput(uaecptr a, uae_u32 v) { phys_write(a, 4, v); }
static void REGPARAM2 flat_wput(uaecptr a, uae_u32 v) { phys_write(a, 2, v & 0xffff); }
static void REGPARAM2 flat_bput(uaecptr a, uae_u32 v) { phys_write(a, 1, v & 0xff); }
static int REGPARAM2 flat_check(uaecptr a, uae_u32 s) { return map_ptr(a, s) != NULL; }
static uae_u8 *REGPARAM2 flat_xlate(uaecptr a) { uint8_t *p = map_ptr(a, 1); return p ? p : ram; }

static addrbank flat_bank = {
	flat_lget, flat_wget, flat_bget, flat_lput, flat_wput, flat_bput,
	flat_xlate, flat_check, NULL, _T("flat"), _T("flat RAM"),
	flat_lgeti, flat_wgeti, ABFLAG_RAM
};
/* newcpu.c refuses to start from a PC in dummy_bank: keep it distinct */
addrbank dummy_bank;

/* ------------------------------------------------------------------ */
/* Harness API                                                         */

/* Hook point patched into m68k_run_mmu040() at the top of each instruction. */
void uae040_insn_boundary(void)
{
	static int last_dh, last_dm, last_ih, last_im;
	uae040_state s;
	op_flush();
	clear_flags();
	uae040_get_state(&s);
	s.d_hit = CpuInstruction.D_Cache_hit - last_dh;
	s.d_miss = CpuInstruction.D_Cache_miss - last_dm;
	s.i_hit = CpuInstruction.I_Cache_hit - last_ih;
	s.i_miss = CpuInstruction.I_Cache_miss - last_im;
	last_dh = CpuInstruction.D_Cache_hit;
	last_dm = CpuInstruction.D_Cache_miss;
	last_ih = CpuInstruction.I_Cache_hit;
	last_im = CpuInstruction.I_Cache_miss;
	if (insn_hook && insn_hook(&s, hook_user)) {
		run_status = 0;
		longjmp(run_exit, 1);
	}
	insn_count++;
}

void uae040_init(uint32_t ram_bytes, int data_cache, int fpu)
{
	ram_size = ram_bytes;
	ram = calloc(1, ram_bytes);
	for (int i = 0; i < MEMORY_BANKS; i++)
		mem_banks[i] = &flat_bank;
	for (int i = 0; i < 65536; i++) {
		ce_banktype[i] = CE_MEMBANK_FAST32;
		ce_cachable[i] = CACHE_ENABLE_ALL;
	}

	memset(&changed_prefs, 0, sizeof(changed_prefs));
	changed_prefs.cpu_model = 68040;
	changed_prefs.mmu_model = 68040;
	changed_prefs.mmu_ec = false;
	changed_prefs.fpu_model = fpu ? 68040 : 0;
	changed_prefs.cpu_compatible = true;     /* the 68040 MMU core, op_smalltbl_31 */
	changed_prefs.cpu_cycle_exact = false;
	changed_prefs.cpu_memory_cycle_exact = false;
	changed_prefs.cpu_data_cache = data_cache != 0;
	changed_prefs.address_space_24 = false;
	changed_prefs.int_no_unimplemented = true;
	/* trap the FP instructions and data types the 68040 does not implement
	 * (vector 11 format $2, vector 55), as the part does */
	changed_prefs.fpu_no_unimplemented = true;
	changed_prefs.m68k_speed = 0;
	changed_prefs.cpu_clock_multiplier = 2 << 8;
	changed_prefs.cachesize = 0;
	changed_prefs.fpu_mode = 1;              /* softfloat: 80-bit extended */
	currprefs = changed_prefs;

	init_m68k();
}

void uae040_set_alias(uint32_t window) { alias_window = window; }

int uae040_add_region(uint32_t base, uint32_t mask, uint32_t size, int berr)
{
	if (nregion >= UAE040_NREG)
		return -1;
	region[nregion].base = base & mask;
	region[nregion].mask = mask;
	region[nregion].size = berr ? 0 : size;
	region[nregion].berr = berr;
	region[nregion].mem = berr ? NULL : calloc(1, size);
	return nregion++;
}

uint8_t *uae040_region_mem(int i) { return (i >= 0 && i < nregion) ? region[i].mem : NULL; }
uint32_t uae040_cacr(void) { return regs.cacr; }
uint8_t *uae040_ram(void) { return ram; }
uint32_t uae040_ram_size(void) { return ram_size; }

int uae040_load(const char *path, uint32_t phys)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return -1;
	if (phys >= ram_size) {
		fclose(f);
		return -1;
	}
	size_t n = fread(ram + phys, 1, ram_size - phys, f);
	fclose(f);
	return (int)n;
}

static int hexv(const char *s, int n, uint32_t *v)
{
	*v = 0;
	for (int i = 0; i < n; i++) {
		int c = s[i], d;
		if (c >= '0' && c <= '9') d = c - '0';
		else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
		else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
		else return -1;
		*v = (*v << 4) | d;
	}
	return 0;
}

int uae040_load_srec(const char *path, uint32_t *entry)
{
	FILE *f = fopen(path, "r");
	char line[1024];
	int total = 0;
	if (!f)
		return -1;
	while (fgets(line, sizeof line, f)) {
		uint32_t cnt, addr, b;
		int al;
		if (line[0] != 'S')
			continue;
		switch (line[1]) {
		case '1': case '9': al = 2; break;
		case '2': case '8': al = 3; break;
		case '3': case '7': al = 4; break;
		default: continue;
		}
		if (hexv(line + 2, 2, &cnt) || hexv(line + 4, al * 2, &addr))
			goto bad;
		if (line[1] >= '7') {
			if (entry)
				*entry = addr;
			continue;
		}
		for (uint32_t i = 0; i + al + 1 < cnt; i++) {
			if (hexv(line + 4 + al * 2 + i * 2, 2, &b) || addr + i >= ram_size)
				goto bad;
			ram[addr + i] = (uint8_t)b;
			total++;
		}
	}
	fclose(f);
	return total;
bad:
	fclose(f);
	return -1;
}

void uae040_set_hooks(uae040_insn_hook ih, uae040_bus_hook bh, void *user)
{
	insn_hook = ih;
	bus_hook = bh;
	hook_user = user;
}

void uae040_set_op_hook(uae040_op_hook oh) { op_hook = oh; }
void uae040_set_exc_hook(uae040_exc_hook eh) { exc_hook = eh; }

void uae040_get_state(uae040_state *s)
{
	MakeSR();
	s->pc = m68k_getpc();
	for (int i = 0; i < 8; i++) {
		s->d[i] = m68k_dreg(regs, i);
		s->a[i] = m68k_areg(regs, i);
	}
	s->sr = regs.sr;
	s->usp = regs.s ? regs.usp : s->a[7];
	s->isp = (regs.s && !regs.m) ? s->a[7] : regs.isp;
	s->msp = (regs.s && regs.m) ? s->a[7] : regs.msp;
	s->vbr = regs.vbr;
	s->sfc = regs.sfc;
	s->dfc = regs.dfc;
	s->cacr = regs.cacr;
	s->tc = regs.tcr;
	s->urp = regs.urp;
	s->srp = regs.srp;
	s->itt0 = regs.itt0;
	s->itt1 = regs.itt1;
	s->dtt0 = regs.dtt0;
	s->dtt1 = regs.dtt1;
	s->mmusr = regs.mmusr;
	for (int i = 0; i < 8; i++) {
		uae_u32 w1 = 0, w2 = 0, w3 = 0;
		if (currprefs.fpu_model)
			fpp_from_exten_fmovem(&regs.fp[i], &w1, &w2, &w3);
		s->fp[i].exp = w1 >> 16;
		s->fp[i].mant = ((uint64_t)w2 << 32) | w3;
	}
	s->fpcr = currprefs.fpu_model ? regs.fpcr : 0;
	s->fpsr = currprefs.fpu_model ? fpp_get_fpsr() : 0;
	s->fpiar = currprefs.fpu_model ? regs.fpiar : 0;
	s->insn_count = insn_count;
}

void uae040_set_state(const uae040_state *s)
{
	int sb = (s->sr >> 13) & 1, mb = (s->sr >> 12) & 1;

	op_flush();
	regs.stopped = 0;
	regs.t0 = regs.t1 = 0;
	unset_special(SPCFLAG_TRACE | SPCFLAG_DOTRACE | SPCFLAG_STOP);
	for (int i = 0; i < 8; i++)
		m68k_dreg(regs, i) = s->d[i];
	for (int i = 0; i < 7; i++)
		m68k_areg(regs, i) = s->a[i];
	regs.usp = s->usp;
	regs.isp = s->isp;
	regs.msp = s->msp;
	regs.s = sb;
	regs.m = mb;
	m68k_areg(regs, 7) = sb ? (mb ? s->msp : s->isp) : s->usp;
	regs.vbr = s->vbr;
	regs.sfc = s->sfc & 7;
	regs.dfc = s->dfc & 7;
	regs.cacr = s->cacr & 0x80008000;
	set_cpu_caches(true);
	invalidate_cpu_data_caches();
	regs.prefetch020addr = 0xffffffff;
	m68k_setpc_normal(s->pc);
	regs.intmask = (s->sr >> 8) & 7;
	regs.sr = s->sr;
	MakeFromSR();
	if (regs.t1 || regs.t0) {
		regs.trace_pc = s->pc;
		if (regs.t1) {
			unset_special(SPCFLAG_TRACE);
			set_special(SPCFLAG_DOTRACE);
		}
	}
}

void uae040_set_mmu(const uae040_state *s)
{
	regs.tcr = mmu_set_tc(s->tc & 0xc000);
	regs.urp = s->urp;
	regs.srp = s->srp;
	regs.itt0 = s->itt0 & 0xffffe364;
	regs.itt1 = s->itt1 & 0xffffe364;
	regs.dtt0 = s->dtt0 & 0xffffe364;
	regs.dtt1 = s->dtt1 & 0xffffe364;
	mmu_tt_modified();
	regs.mmusr = s->mmusr;
	mmu_flush_atc_all(true);
}

void uae040_set_fpu(const uae040_state *s)
{
	if (!currprefs.fpu_model)
		return;
	for (int i = 0; i < 8; i++)
		fpp_to_exten_fmovem(&regs.fp[i], (uae_u32)s->fp[i].exp << 16,
				    (uae_u32)(s->fp[i].mant >> 32), (uae_u32)s->fp[i].mant);
	fpp_set_fpcr(s->fpcr);
	fpp_set_fpsr(s->fpsr);
	regs.fpiar = s->fpiar;
}

static struct {
	int n, i, started;
	uae040_setup_fn setup;
	uae040_result_fn result;
	void *user;
} each;

static int each_hook(const uae040_state *s, void *u)
{
	(void)u;
	if (each.started) {
		each.result(each.i, s, each.user);
		each.i++;
	}
	if (each.i >= each.n)
		return 1;
	uae040_state st;
	memset(&st, 0, sizeof st);
	each.setup(each.i, &st, each.user);
	each.started = 1;
	uae040_set_state(&st);
	return 0;
}

int uae040_run_each(int ntests, uae040_setup_fn setup, uae040_result_fn result,
		    void *user, int *done)
{
	each.n = ntests;
	each.i = 0;
	each.started = 0;
	each.setup = setup;
	each.result = result;
	each.user = user;
	insn_hook = each_hook;
	hook_user = user;
	int r = uae040_run();
	if (done)
		*done = each.i;
	return r;
}

int uae040_run(void)
{
	if (setjmp(run_exit))
		return run_status;
	quit_program = UAE_RESET_HARD;
	m68k_go(true);
	return 1;
}
