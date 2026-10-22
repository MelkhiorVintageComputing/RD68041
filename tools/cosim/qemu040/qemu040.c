/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Copyright 2026 Romain Dolbeau */
/* Source location: https://github.com/MelkhiorVintageComputing/RD68041 */

/*
 * qemu040 -- a TCG plugin that turns QEMU (-cpu m68040) into a third
 * instruction-trace oracle, writing the same positional .trc as UAE040's
 * uae040_trace (tools/cosim/uae040/uae040_trace.c is the reference for the
 * format; doc/oracles.md, "QEMU", for what it is trusted for).
 *
 *   qemu-system-m68k -M virt -cpu m68040 -m 1M -nographic -kernel prog.elf \
 *       -plugin libqemu040.so,trc=out.trc[,ops=out.ops][,limit=N][,reset=on]
 *   qemu-system-m68k ... -plugin libqemu040.so,count=FILE
 *
 *   trc=FILE    the trace
 *   count=FILE  no trace: count the instructions executed (inline, at full
 *               speed) and write "insns <n>" to FILE when QEMU exits
 *   ops=FILE    the operand stream, uae040_trace -O's format (below)
 *   limit=N     at most N instructions (default 4000000), then QEMU exits
 *   reset=on    (default) emulate the MC68040's reset exception before the
 *               first instruction: SSP from physical 0, PC from physical 4.
 *               The virt board starts the CPU at the ELF's entry point with
 *               the reset SR; reset=off traces from there unchanged.
 *
 * The record is uae040_trace's, nfield = 58, in the same order. What QEMU's
 * register interface (its gdbstub's m68k-core and m68k-fp features) does
 * not give is written as a single "x" -- an unknown digit to Verilog's
 * $fscanf("%h"), and "unknown" to tools/cosim/qemu040/compare.py:
 *
 *      0- 7  d0..d7               from QEMU
 *      8-14  a0..a6               from QEMU
 *     15-17  usp isp msp          the active stack pointer (A7) goes into
 *                                 the one SR.S/SR.M select; the other two x
 *     18     sr                   from QEMU
 *     19-30  vbr cacr sfc dfc tc urp srp itt0 itt1 dtt0 dtt1 mmusr   x
 *     31-32  fpcr fpsr            from QEMU
 *     33     fpiar                x (QEMU's gdbstub always reads it as 0)
 *     34-57  fp0..fp7             from QEMU: exponent word, mantissa high
 *                                 and low long words
 *
 * As in uae040_trace, the program stops itself with a branch to itself
 * (BRA.S *, BRA.W *, BRA.L *): the first boundary whose PC repeats at one
 * ends the trace and QEMU (exit status 0).
 *
 * THE OPERAND STREAM (ops=):  I <n> <pc>  at each boundary, and
 *     O <R|W> <la> <pa> <bytes> <data> x
 * for each access the guest's instructions make (TCG loads and stores and
 * those of QEMU's helpers that report to plugins), the function code as x;
 * E x when QEMU reports an exception or interrupt (the vector is not known
 * to a plugin).
 *
 * QEMU is an ORACLE, not a source. Where it and the manual disagree, the
 * manual decides.
 */
#include <glib.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <qemu-plugin.h>

QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

#define NFIELD 58

enum { R_D0 = 0, R_A0 = 8, R_SP = 15, R_SR = 16, R_PC = 17, R_FP0 = 18,
       R_FPCR = 26, R_FPSR = 27, R_N = 28 };
static const char *const rname[R_N] = {
	"d0", "d1", "d2", "d3", "d4", "d5", "d6", "d7",
	"a0", "a1", "a2", "a3", "a4", "a5", "fp", "sp", "ps", "pc",
	"fp0", "fp1", "fp2", "fp3", "fp4", "fp5", "fp6", "fp7",
	"fpcontrol", "fpstatus",
};
static struct qemu_plugin_register *reg[R_N];
static int have[R_N];	/* a handle may be NULL: register 0's is */

struct insn {
	uint64_t pc;
	int selfbra;
};

static FILE *body, *ops;
static char *trcpath;
static unsigned long steps, limit = 4000000;
static uint64_t prev_pc = ~(uint64_t)0;
static int do_reset = 1, done;
static GByteArray *buf;
static char *countpath;
static qemu_plugin_u64 icount;

static uint32_t be32(const uint8_t *p)
{
	return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static uint32_t rd32(int r)
{
	g_byte_array_set_size(buf, 0);
	if (!have[r] || !qemu_plugin_read_register(reg[r], buf) || buf->len < 4)
		return 0;
	return be32(buf->data);
}

/* Write the header and the body: the trace is complete. Once. */
static void finish(void)
{
	if (done)
		return;
	done = 1;
	FILE *f = fopen(trcpath, "w");
	if (!f) {
		perror(trcpath);
		return;
	}
	fprintf(f, "%lx %x\n", steps, NFIELD);
	rewind(body);
	char b[1 << 16];
	size_t n;
	while ((n = fread(b, 1, sizeof b, body)) > 0)
		fwrite(b, 1, n, f);
	fclose(f);
	if (ops)
		fflush(ops);
	fprintf(stderr, "qemu040: %lu instructions\n", steps);
}

static void reset_exception(void)
{
	GByteArray *m = g_byte_array_new();
	uint32_t pc;
	if (!qemu_plugin_read_memory_vaddr(0, m, 8) || m->len < 8) {
		fprintf(stderr, "qemu040: cannot read the reset vectors\n");
		exit(1);
	}
	pc = be32(m->data + 4);
	g_byte_array_set_size(m, 4);	/* the SSP, in target byte order */
	qemu_plugin_write_register(reg[R_SP], m);
	g_byte_array_free(m, TRUE);
	if (rd32(R_PC) != pc)
		qemu_plugin_set_pc(pc);		/* does not return */
}

static void on_insn(unsigned int vcpu, void *u)
{
	const struct insn *in = u;
	(void)vcpu;
	if (done)
		return;
	if (do_reset) {
		do_reset = 0;
		reset_exception();
	}
	if (steps >= limit || (in->pc == prev_pc && in->selfbra)) {
		finish();
		exit(0);
	}
	prev_pc = in->pc;
	if (ops)
		fprintf(ops, "I %lu %" PRIx64 "\n", steps, in->pc);

	uint32_t sr = rd32(R_SR), sp = rd32(R_SP);
	/* the PC is the instruction's own address: QEMU's pc register is only
	   brought up to date at the end of a translation block */
	fprintf(body, "%" PRIx64, in->pc);
	for (int i = 0; i < 8; i++)
		fprintf(body, " %x", rd32(R_D0 + i));
	for (int i = 0; i < 7; i++)
		fprintf(body, " %x", rd32(R_A0 + i));
	/* usp isp msp */
	if (!(sr & 0x2000))
		fprintf(body, " %x x x", sp);
	else if (!(sr & 0x1000))
		fprintf(body, " x %x x", sp);
	else
		fprintf(body, " x x %x", sp);
	fprintf(body, " %x", sr);
	/* vbr cacr sfc dfc tc urp srp itt0 itt1 dtt0 dtt1 mmusr */
	fputs(" x x x x x x x x x x x x", body);
	fprintf(body, " %x %x x", rd32(R_FPCR), rd32(R_FPSR));
	for (int i = 0; i < 8; i++) {
		g_byte_array_set_size(buf, 0);
		if (have[R_FP0 + i] && qemu_plugin_read_register(reg[R_FP0 + i], buf)
		    && buf->len >= 12)
			fprintf(body, " %x %x %x", (uint32_t)buf->data[0] << 8 | buf->data[1],
				be32(buf->data + 4), be32(buf->data + 8));
		else
			fputs(" x x x", body);
	}
	fputc('\n', body);
	steps++;
}

static void on_mem(unsigned int vcpu, qemu_plugin_meminfo_t info, uint64_t va, void *u)
{
	(void)vcpu;
	(void)u;
	if (!ops || done)
		return;
	qemu_plugin_mem_value v = qemu_plugin_mem_get_value(info);
	struct qemu_plugin_hwaddr *h = qemu_plugin_get_hwaddr(info, va);
	uint64_t pa = h ? qemu_plugin_hwaddr_phys_addr(h) : va;
	unsigned bytes = 1u << qemu_plugin_mem_size_shift(info);
	uint64_t d;
	switch (v.type) {
	case QEMU_PLUGIN_MEM_VALUE_U8: d = v.data.u8; break;
	case QEMU_PLUGIN_MEM_VALUE_U16: d = v.data.u16; break;
	case QEMU_PLUGIN_MEM_VALUE_U32: d = v.data.u32; break;
	case QEMU_PLUGIN_MEM_VALUE_U64: d = v.data.u64; break;
	default: d = v.data.u128.low; break;
	}
	fprintf(ops, "O %c %" PRIx64 " %" PRIx64 " %u %" PRIx64 " x\n",
		qemu_plugin_mem_is_store(info) ? 'W' : 'R', va, pa, bytes, d);
}

static void on_discon(unsigned int vcpu, enum qemu_plugin_discon_type t,
		      uint64_t from, uint64_t to, void *u)
{
	(void)vcpu;
	(void)t;
	(void)from;
	(void)to;
	(void)u;
	if (ops && !done)
		fputs("E x\n", ops);
}

static void on_tb(struct qemu_plugin_tb *tb, void *u)
{
	(void)u;
	size_t n = qemu_plugin_tb_n_insns(tb);
	if (countpath) {
		qemu_plugin_register_vcpu_tb_exec_inline_per_vcpu(tb, QEMU_PLUGIN_INLINE_ADD_U64,
								  icount, n);
		return;
	}
	for (size_t i = 0; i < n; i++) {
		struct qemu_plugin_insn *q = qemu_plugin_tb_get_insn(tb, i);
		struct insn *in = g_new0(struct insn, 1);
		uint8_t b[4] = { 0, 0, 0, 0 };
		size_t len = qemu_plugin_insn_data(q, b, sizeof b);
		in->pc = qemu_plugin_insn_vaddr(q);
		in->selfbra = (len >= 2 && b[0] == 0x60 && b[1] == 0xFE)
			|| (len >= 4 && b[0] == 0x60 && b[1] == 0x00 && b[2] == 0xFF && b[3] == 0xFE)
			|| (len >= 4 && b[0] == 0x60 && b[1] == 0xFF && b[2] == 0xFF && b[3] == 0xFF);
		/* The leak is deliberate: a TB lives as long as the run. */
		qemu_plugin_register_vcpu_insn_exec_cb(q, on_insn,
			do_reset ? QEMU_PLUGIN_CB_RW_REGS_PC : QEMU_PLUGIN_CB_R_REGS, in);
		if (ops)
			qemu_plugin_register_vcpu_mem_cb(q, on_mem, QEMU_PLUGIN_CB_NO_REGS,
							 QEMU_PLUGIN_MEM_RW, NULL);
	}
}

static void on_vcpu_init(unsigned int vcpu, void *u)
{
	(void)u;
	(void)vcpu;
	GArray *l = qemu_plugin_get_registers();
	for (guint i = 0; i < l->len; i++) {
		qemu_plugin_reg_descriptor *d = &g_array_index(l, qemu_plugin_reg_descriptor, i);
		if (getenv("QEMU040_REGS"))
			fprintf(stderr, "qemu040: register %s (%s)\n", d->name, d->feature ? d->feature : "-");
		for (int r = 0; r < R_N; r++)
			if (!strcmp(d->name, rname[r])) {
				reg[r] = d->handle;
				have[r] = 1;
			}
	}
	g_array_free(l, TRUE);
	for (int r = 0; r < R_N; r++)
		if (!have[r] && r < R_FP0)
			fprintf(stderr, "qemu040: QEMU has no register %s\n", rname[r]);
}

static void on_exit_cb(void *u)
{
	(void)u;
	if (countpath) {
		FILE *f = fopen(countpath, "w");
		if (f) {
			fprintf(f, "insns %" PRIu64 "\n", qemu_plugin_u64_sum(icount));
			fclose(f);
		}
		return;
	}
	finish();
}

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id, const qemu_info_t *info,
					   int argc, char **argv)
{
	if (!info->system_emulation || strcmp(info->target_name, "m68k")) {
		fprintf(stderr, "qemu040: needs qemu-system-m68k\n");
		return -1;
	}
	for (int i = 0; i < argc; i++) {
		char *eq = strchr(argv[i], '=');
		if (!eq) {
			fprintf(stderr, "qemu040: bad option %s\n", argv[i]);
			return -1;
		}
		*eq = 0;
		const char *k = argv[i], *v = eq + 1;
		if (!strcmp(k, "trc"))
			trcpath = g_strdup(v);
		else if (!strcmp(k, "count"))
			countpath = g_strdup(v);
		else if (!strcmp(k, "ops")) {
			ops = fopen(v, "w");
			if (!ops) {
				perror(v);
				return -1;
			}
			setvbuf(ops, NULL, _IOFBF, 1 << 16);
		} else if (!strcmp(k, "limit"))
			limit = strtoul(v, NULL, 0);
		else if (!strcmp(k, "reset")) {
			bool b;
			if (!qemu_plugin_bool_parse(k, v, &b))
				return -1;
			do_reset = b;
		} else {
			fprintf(stderr, "qemu040: unknown option %s\n", k);
			return -1;
		}
	}
	if (countpath) {
		icount = qemu_plugin_scoreboard_u64(qemu_plugin_scoreboard_new(sizeof(uint64_t)));
		qemu_plugin_register_vcpu_tb_trans_cb(id, on_tb, NULL);
		qemu_plugin_register_atexit_cb(id, on_exit_cb, NULL);
		return 0;
	}
	if (!trcpath) {
		fprintf(stderr, "qemu040: trc=FILE or count=FILE is required\n");
		return -1;
	}
	body = tmpfile();
	if (!body) {
		perror("tmpfile");
		return -1;
	}
	setvbuf(body, NULL, _IOFBF, 1 << 16);
	buf = g_byte_array_new();
	qemu_plugin_register_vcpu_init_cb(id, on_vcpu_init, NULL);
	qemu_plugin_register_vcpu_tb_trans_cb(id, on_tb, NULL);
	qemu_plugin_register_vcpu_discon_cb(id, QEMU_PLUGIN_DISCON_ALL, on_discon, NULL);
	qemu_plugin_register_atexit_cb(id, on_exit_cb, NULL);
	return 0;
}
