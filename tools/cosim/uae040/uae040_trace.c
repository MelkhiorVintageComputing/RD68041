/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Copyright 2026 Romain Dolbeau */
/* Source location: https://github.com/MelkhiorVintageComputing/RD68041 */

/*
 * uae040_trace -- the instruction-by-instruction UAE040 oracle: RD68031's
 * uae030_trace (make cosim there) retargeted at the MC68040.
 *
 * Loads an image at physical 0 (the vectors at 0, the program where the
 * reset vector points), runs it under UAE040 from a hard reset, and prints
 * the architectural state at EVERY instruction boundary.
 *
 *     uae040_trace [-m KB] [-a WINDOW] [-D] [-L] [-r BASE:MASK:SIZE]...
 *                  [-e BASE:MASK]... [-B busfile] [-O opfile] [-X excfile]
 *                  <image> [limit]
 *
 *   image      a flat binary (objcopy -O binary of an ELF linked at 0), or a
 *              Motorola S-record file (objcopy -O srec), told apart by its
 *              first byte ('S' and a record type digit)
 *   limit      at most this many instructions (default 4000000)
 *   -m KB      RAM size in KiB (default 64)
 *   -a WINDOW  fold physical addresses below WINDOW (hex) onto the RAM, as a
 *              partially decoded port does (default 10000000; 0 = off)
 *   -D         no data-cache emulation
 *   -L         an MC68LC040: no FPU
 *   -r B:M:S   one more memory (hex): addresses with (a & M) == B reach a
 *              zeroed store of S bytes repeated through the window
 *   -e B:M     a window (hex) that answers every access with a bus error
 *   -B FILE    write the physical access stream to FILE (below)
 *   -O FILE    write the operand stream to FILE (below)
 *
 * UAE040 is an ORACLE, not a source. Where the two disagree the manual decides.
 *
 * THE FORMAT (.trc), RD68031's positional hex format: read with
 * $fscanf("%h"), whitespace separated, no 0x:
 *
 *     nstep  nfield
 *     per instruction:  pc  then nfield values
 *
 * The values, in this order (nfield = 58 = 0x3a):
 *
 *      0- 7  d0..d7
 *      8-14  a0..a6
 *     15-17  usp  isp  msp
 *     18     sr
 *     19     vbr
 *     20     cacr
 *     21-22  sfc  dfc
 *     23     tc
 *     24-25  urp  srp
 *     26-29  itt0  itt1  dtt0  dtt1
 *     30     mmusr
 *     31-33  fpcr  fpsr  fpiar          (0 on an MC68LC040)
 *     34-57  fp0..fp7, three values each: the sign/exponent word, the high
 *            and the low long word of the mantissa -- FMOVEM.X's memory
 *            layout without its zero word (0 on an MC68LC040)
 *
 * It is RD68031's layout without the registers an MC68040 does not have
 * (CAAR, CRP; TT0/TT1 become the four TTRs, CRP/SRP's 64 bits URP/SRP's
 * 32), with the 040's MMU and FPU registers after the integer ones. As in
 * RD68031, registers are only ever appended, and a reader takes nfield from
 * the header and skips what it does not know.
 *
 * THE BUS STREAM (-B), one line each:
 *
 *     I <n> <pc>                    instruction boundary n, before pc runs
 *     E <vector>                    exception processing starts
 *     <R|W> <pa> <bytes> <data> <tt> <tm> <kind> <c> [L] [B]
 *         one physical access: its address, how many bytes and their value
 *         (right justified, hex), the TT1-TT0 and TM2-TM0 the harness derives
 *         for it (UM tables 5-2 to 5-4), its kind:
 *           D  an operand or stack access that reached the bus
 *           T  a table search access for a data access or for PTEST
 *           F  a table search access for an instruction fetch's translation
 *           P  a data-cache push (a dirty line written back)
 *           C  one long word of a data-cache line fill
 *           M  one long word of a MOVE16 line
 *         (instruction fetches are left out, as in RD68031), c = 1 while
 *         CACR.DE is set, L inside a locked read-modify-write, B a bus error.
 *
 * THE OPERAND STREAM (-O), one line each, also with the I and E lines:
 *
 *     O <R|W> <la> <pa> <bytes> <data> <fc> [B]
 *         one operand, whether the data cache satisfied it or the bus did:
 *         logical and physical address, size, value, function code.
 *
 * The program stops itself with a branch to itself, as in RD68031: the first
 * boundary whose PC repeats at a BRA to itself ends the trace.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "uae040.h"

#define NFIELD 58

static unsigned long limit = 4000000;
static unsigned long steps;
static uint32_t prev_pc = 0xFFFFFFFFu;
static FILE *body;
static FILE *bus;
static FILE *ops;

static void on_bus(const uae040_bus *b, void *u)
{
	(void)u;
	static const char kc[] = "DTxPCM";
	if (!bus || b->kind == UAE040_KIND_IFETCH)
		return;
	char k = kc[b->kind];
	if (b->kind == UAE040_KIND_WALK && b->tm == 4)
		k = 'F';
	fprintf(bus, "%c %x %d %x %d %d %c %d%s%s\n", b->write ? 'W' : 'R', b->pa, b->size,
		b->data, b->tt, b->tm, k, (uae040_cacr() >> 31) & 1,
		b->lock ? " L" : "", b->berr ? " B" : "");
}

static void on_op(uint32_t la, uint32_t pa, int size, int write, uint32_t data, int fc,
		  int berr, void *u)
{
	(void)u;
	if (ops)
		fprintf(ops, "O %c %x %x %d %x %d%s\n", write ? 'W' : 'R', la, pa, size, data, fc,
			berr ? " B" : "");
}

static void on_exc(int vector, void *u)
{
	(void)u;
	if (bus)
		fprintf(bus, "E %d\n", vector);
	if (ops)
		fprintf(ops, "E %d\n", vector);
}

static int on_insn(const uae040_state *s, void *u)
{
	(void)u;
	if (steps >= limit)
		return 1;
	if (s->pc == prev_pc && s->pc + 3 < uae040_ram_size()) {
		const uint8_t *r = uae040_ram() + s->pc;
		if ((r[0] == 0x60 && r[1] == 0xFE)
		    || (r[0] == 0x60 && r[1] == 0x00 && r[2] == 0xFF && r[3] == 0xFE)
		    || (r[0] == 0x60 && r[1] == 0xFF && r[2] == 0xFF && r[3] == 0xFF))
			return 1;
	}
	prev_pc = s->pc;
	if (bus)
		fprintf(bus, "I %lu %x\n", steps, s->pc);
	if (ops)
		fprintf(ops, "I %lu %x\n", steps, s->pc);
	fprintf(body, "%x", s->pc);
	for (int i = 0; i < 8; i++)
		fprintf(body, " %x", s->d[i]);
	for (int i = 0; i < 7; i++)
		fprintf(body, " %x", s->a[i]);
	fprintf(body, " %x %x %x %x %x %x %x %x", s->usp, s->isp, s->msp, s->sr, s->vbr,
		s->cacr, s->sfc, s->dfc);
	fprintf(body, " %x %x %x %x %x %x %x %x", s->tc, s->urp, s->srp, s->itt0, s->itt1,
		s->dtt0, s->dtt1, s->mmusr);
	fprintf(body, " %x %x %x", s->fpcr, s->fpsr, s->fpiar);
	for (int i = 0; i < 8; i++)
		fprintf(body, " %x %x %x", s->fp[i].exp, (uint32_t)(s->fp[i].mant >> 32),
			(uint32_t)s->fp[i].mant);
	fputc('\n', body);
	steps++;
	return 0;
}

static FILE *open_out(const char *p)
{
	FILE *f = fopen(p, "w");
	if (!f) {
		perror(p);
		exit(1);
	}
	setvbuf(f, NULL, _IOFBF, 1 << 16);
	return f;
}

int main(int argc, char **argv)
{
	uint32_t kb = 64, window = 0x10000000u;
	int dcache = 1, fpu = 1, c, nr = 0;
	uint32_t rb[8], rm[8], rs[8];
	int re[8];
	const char *busfile = NULL, *opfile = NULL;
	const char *usage = "usage: %s [-m KB] [-a WINDOW] [-D] [-L] [-r B:M:S]... [-e B:M]... "
			    "[-B busfile] [-O opfile] image [limit]\n";
	while ((c = getopt(argc, argv, "m:a:DLr:e:B:O:")) != -1) {
		switch (c) {
		case 'm': kb = strtoul(optarg, NULL, 0); break;
		case 'a': window = strtoul(optarg, NULL, 16); break;
		case 'D': dcache = 0; break;
		case 'L': fpu = 0; break;
		case 'r':
		case 'e':
			rs[nr] = 0;
			if (nr >= 8 || sscanf(optarg, "%x:%x:%x", &rb[nr], &rm[nr], &rs[nr]) < (c == 'r' ? 3 : 2)) {
				fprintf(stderr, usage, argv[0]);
				return 2;
			}
			re[nr++] = (c == 'e');
			break;
		case 'B': busfile = optarg; break;
		case 'O': opfile = optarg; break;
		default:
			fprintf(stderr, usage, argv[0]);
			return 2;
		}
	}
	if (optind >= argc) {
		fprintf(stderr, usage, argv[0]);
		return 2;
	}
	if (optind + 1 < argc)
		limit = strtoul(argv[optind + 1], NULL, 0);

	uae040_init(kb << 10, dcache, fpu);
	uae040_set_alias(window);
	for (int i = 0; i < nr; i++)
		uae040_add_region(rb[i], rm[i], re[i] ? 0 : rs[i], re[i]);
	if (busfile)
		bus = open_out(busfile);
	if (opfile)
		ops = open_out(opfile);

	const char *img = argv[optind];
	int n;
	FILE *probe = fopen(img, "rb");
	char hd[2] = { 0, 0 };
	if (!probe) {
		perror(img);
		return 1;
	}
	if (fread(hd, 1, 2, probe) != 2)
		hd[0] = 0;
	fclose(probe);
	if (hd[0] == 'S' && hd[1] >= '0' && hd[1] <= '9')
		n = uae040_load_srec(img, NULL);
	else
		n = uae040_load(img, 0);
	if (n < 0) {
		fprintf(stderr, "uae040_trace: cannot load %s\n", img);
		return 1;
	}
	if (n <= 8) {
		fprintf(stderr, "uae040_trace: %s is %d bytes\n", img, n);
		return 1;
	}
	body = tmpfile();
	if (!body) {
		perror("tmpfile");
		return 1;
	}
	uae040_set_hooks(on_insn, on_bus, NULL);
	uae040_set_op_hook(on_op);
	uae040_set_exc_hook(on_exc);
	int halted = uae040_run();
	if (bus)
		fclose(bus);
	if (ops)
		fclose(ops);
	if (halted) {
		fprintf(stderr, "uae040_trace: the oracle halted (double fault) after %lu instructions\n",
			steps);
		return 1;
	}

	fprintf(stderr, "trace: %lu instructions\n", steps);
	printf("%lx %x\n", steps, NFIELD);
	rewind(body);
	char buf[1 << 16];
	size_t r;
	fflush(stdout);
	while ((r = fread(buf, 1, sizeof buf, body)) > 0)
		fwrite(buf, 1, r, stdout);
	return 0;
}
