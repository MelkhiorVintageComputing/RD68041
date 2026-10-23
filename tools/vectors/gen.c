/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Copyright 2026 Romain Dolbeau */
/* Source location: https://github.com/MelkhiorVintageComputing/RD68041 */

/*
 * RD68041 -- the per-opcode vector generator.
 *
 * RD68031's tools/vectors/gen.c, retargeted to UAE040 (tools/cosim/uae040/):
 * for each instruction it knows, it emits a set of opcodes, gives each one
 * several pseudo-random starting states, runs each through the oracle as an
 * MC68040, one instruction per test, and prints what came out.
 *
 *     build/uae040/vectors_gen [-L] <group>...      # or `all`, or `list`
 *
 * With -L the oracle is an MC68LC040 (no FPU), and `all` takes the lc040
 * group too, which only it has.
 *
 * It links the oracle, which is GPL code, so this file is GPL too.
 *
 * UAE040 is an ORACLE, not a source. Nothing here was written by reading how it
 * implements anything; the manual is the arbiter when the two disagree.
 *
 * WHAT IS AND IS NOT SWEPT HERE
 *
 * The groups are RD68031's integer groups, less the MC68030's own (CALLM/RTM,
 * the MC68030 CACR and CAAR, PMOVE and the 030 MMU) and less the F line, which
 * is the MC68040's FPU, MMU and MOVE16 space; M9-M12 add move16, cinv_cpush,
 * pmmu040 and lc040 (the FPU's sweep is the cputest corpus, M11). MOVEC sweeps the non-MMU control registers. The `ea` group
 * is RD68031's `make ea` (uae030_ea there) folded in: every addressing mode and
 * every shape of extension word, through LEA <ea>,A0 and MOVE.L <ea>,D0, from
 * fixed registers and a data block of recognisable pointers.
 *
 * The other groups do not sweep the addressing modes exhaustively against every
 * opcode -- `ea` does that. What they sweep is the OPERATION: every opcode,
 * every size, every condition, against varied operands, through a handful of
 * modes chosen to reach each data path into and out of the effective address --
 * a register, an aligned memory operand, a MISALIGNED one, and the two that
 * have a side effect on an address register.
 *
 * THE STARTING STATE. Most groups start at SR $27xx (supervisor, M = 0, T = 0,
 * interrupt mask 7) and vary only the CCR; the traps and trace groups also
 * start in user mode and traced. core_vec_tb deposits the whole state (since
 * M8): the SR, the three stack pointers, SFC, DFC, VBR and CACR. Those the
 * groups do not set start at zero, which is what the core's reset leaves and
 * what UM 8.2.10 makes VBR and CACR.
 *
 * THE OUTPUT, read positionally by sim/tb/core_vec_tb.sv with $fscanf:
 *
 *     ntests  ngroups
 *     ngroups names, one per line   the groups, numbered from 0 in that order
 *     per test:
 *       index  group  nwords  w0..w5   the instruction, at PROG_BASE
 *       d0..d7  a0..a6  usp  isp  sr   the state it starts from
 *       msp  sfc  dfc  vbr  cacr
 *       tc itt0 itt1 dtt0 dtt1 mmusr urp srp   (the MMU's, since M10)
 *       npoke  then npoke pairs of     long words put into memory before the
 *         address and value            run, for the few instructions that need
 *                                      something specific there
 *       srmask  fill  exc              which bits of SR are worth comparing;
 *                                      how the data block is filled (0 the
 *                                      hash, 1 the hash as BCD, 2 pointers:
 *                                      $3000 + offset); the first exception
 *                                      vector the oracle took, 0 for none
 *       d0..d7  a0..a6  usp  isp  sr  pc   the state it finished in
 *       msp  vbr  sfc  dfc  cacr
 *       tc itt0 itt1 dtt0 dtt1 mmusr urp srp
 *       nacc                           how many operand accesses it made
 *         per access: addr  rw  bytes  fc  value  mask
 *
 * `rw` is 1 for a read. `fc` is the function code the oracle drove. `value` is
 * what was written, 0 on a read: the reads are covered by the final state, and
 * the writes are how memory is compared without dumping it. `mask` says which
 * bits of a written value to compare -- all of them, except in the status
 * register an exception stacks after an instruction that left some condition
 * codes undefined, where it is srmask.
 *
 * An access is an OPERAND, not a bus cycle: a misaligned long word is one
 * access, as the oracle's operand hook reports it (uae040.h) and as the core's
 * data memory unit is asked for it.
 *
 * `srmask` exists because the manual leaves some condition codes UNDEFINED and
 * an oracle still produces a number for them. PRM 4 says N and V are undefined
 * after ABCD, SBCD and NBCD; N and Z are undefined after a divide that
 * overflowed, and N, Z and V after a divide by zero; CHK leaves Z, V and C
 * undefined (and N, when the operand was in bounds); CMP2 and CHK2 leave N and
 * V undefined. Those bits are masked out (CLAUDE.md: the manual decides).
 *
 * DROPPED TESTS. A test is dropped, and counted, when the oracle made more
 * accesses than there is room to record, when it halted, or when it took a bus
 * error or an address error (an access error, M10's business). Tests that took
 * any other exception are KEPT, frame accesses and all, and core_vec_tb
 * compares the frame (since M8).
 *
 * MEMORY. 64 KB from 0, repeated through the address space (up to 2 GB here;
 * above that the oracle answers a bus error and the test is dropped), as the
 * core harness's slave is. Both sides fill DATA_SIZE bytes at DATA_BASE from
 * the test index with the same two truncating multiplications, so neither has
 * to send the other a copy per test. Everything else is zero, except the
 * vector table -- every vector points somewhere different, $9000 + 4n -- and
 * the reset vectors, and the program area: the instruction at PROG_BASE,
 * then ILLEGAL ($4AFC) to PROG_BASE + PROG_FILL.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>

#include "uae040.h"

#define MEMSIZE    0x00010000      /* the core harness's slave: 64 KB ... */
#define ALIAS      0x80000000u     /* ... repeated through the address space */
#define PROG_BASE  0x00001000
#define DATA_BASE  0x00002000
#define DATA_SIZE  0x00000800
#define STACK      0x00002700

#define MAXACC 24

struct test {
    int          group;
    int          nwords;
    unsigned int w[6];
    int          pcrel;
    int          flow;      /* the instruction may legitimately change the PC */
    unsigned int d[8], a[7], usp, isp, sr;
    unsigned int imsp, isfc, idfc, ivbr, icacr;
    unsigned int immu[8];     /* TC ITT0 ITT1 DTT0 DTT1 MMUSR URP SRP */
    int          npoke;
    unsigned int poke_a[4], poke_v[4];
    unsigned int srmask;      /* which status-register bits to compare */
    int          bcdfill;     /* the data block's fill: 0 hash, 1 BCD, 2 pointers */
};

static int cur_group;
static int lc;              /* -L: the oracle is an MC68LC040 */
#define MAXTESTS 400000
static struct test *tests;
static int          ntests;

/* A deterministic generator, so a failing vector index means the same thing on
 * every run and on every machine. */
static unsigned int rng_state;
static unsigned int rnd(void)
{
    rng_state = rng_state * 1103515245u + 12345u;
    return (rng_state >> 8) ^ (rng_state << 13);
}

/* The data block, filled identically by sim/tb/core_vec_tb.sv. Two truncating
 * 32-bit multiplications and an exclusive or -- nothing that could mean one
 * thing in C and another in SystemVerilog. */
static unsigned int fill_word(int idx, unsigned int off)
{
    return ((unsigned int)idx * 0x9E3779B9u) ^ (off * 0x01000193u);
}

/* Every byte of a long word brought into the range a decimal digit pair can
 * hold. PRM 4 defines ABCD, SBCD and NBCD on binary-coded decimal operands and
 * says nothing about what a digit above nine does, so the sweep does not ask --
 * see doc/divergences.md. */
static unsigned int bcd_word(unsigned int v)
{
    unsigned int out = 0, i, b;
    for (i = 0; i < 4; i++) {
        b = (v >> (i * 8)) & 0xFFu;
        /* Each NIBBLE modulo ten, not the byte: `b % 10` would take $7C to
         * $74 rather than to $72, and the testbench -- which computes the same
         * fill independently -- would disagree about what is in memory. */
        out |= ((((b >> 4) % 10u) << 4) | ((b & 0x0Fu) % 10u)) << (i * 8);
    }
    return out;
}

/* One test. `nw` counts the instruction's words; the caller has put them in w. */
static void emit(int nw, const unsigned int *w, int pcrel, int flow)
{
    struct test *t;
    int i;
    if (ntests >= MAXTESTS) {
        fprintf(stderr, "vectors: more than %d tests\n", MAXTESTS);
        exit(1);
    }
    t = &tests[ntests++];
    t->group  = cur_group;
    t->nwords = nw;
    for (i = 0; i < 6; i++) t->w[i] = w[i];
    t->pcrel = pcrel;
    t->flow  = flow;

    for (i = 0; i < 8; i++) t->d[i] = rnd();
    /* Address registers point into the data block. Half of them land on an odd
     * address on purpose: the MC68040 takes no address error on a data access
     * (UM 8.2.2: only an odd instruction address does), so a misaligned operand
     * is ordinary behaviour that the data memory unit splits, and a sweep that
     * only ever used even addresses would never reach that path. */
    for (i = 0; i < 7; i++)
        t->a[i] = DATA_BASE + 0x100 + (rnd() & 0x3FF);
    /* Zero: the core's reset value, until its deposit can set USP (above). */
    t->usp = 0;
    t->isp = STACK;
    /* Supervisor, M clear, interrupts masked, trace off -- the system byte the
     * core is fixed at until M8 -- and the condition codes varied, because
     * ADDX, SUBX, the rotates through X and every Bcc read them. */
    t->sr  = 0x2700 | (rnd() & 0x1F);
    t->srmask  = 0xFFFF;
    /* Zero, as the core's reset leaves them (above). VBR must be anyway: the
     * vector table is at 0, and moving it would hide which vector a test
     * took. CACR zero is the caches off (UM 4.2), which is what lets one
     * instruction be compared operand by operand. */
    t->imsp  = 0;
    t->isfc  = 0;
    t->idfc  = 0;
    t->ivbr  = 0;
    t->icacr = 0;
    /* The MMU's too, translation off: only pmmu040 sets them. */
    for (i = 0; i < 8; i++) t->immu[i] = 0;
    t->bcdfill = 0;
}

/* Several starting states for one instruction. */
static void emitn(int n, int nw, const unsigned int *w, int pcrel, int flow)
{
    while (n-- > 0) emit(nw, w, pcrel, flow);
}

/* ------------------------------------------------------------------ */
/* Addressing modes                                                    */
/*                                                                     */
/* A handful, not eighteen. `make ea` sweeps all eighteen against every */
/* shape of extension word already; what these have to do is reach each */
/* PATH into and out of an operand -- a register, an aligned memory     */
/* operand, a misaligned one, the two with a side effect on an address  */
/* register, an absolute address and a program-space one.               */
/*                                                                     */
/* The indexed modes are absent: their index register is one of the    */
/* randomised data registers, so the address would leave the block.     */
/* But two modes stand in for everything the extension-word decoder     */
/* reaches -- absolute long, and the full-format (bd,An) with the index */
/* suppressed -- because `make ea` sweeps the modes only as a SOURCE,   */
/* and a destination through them is where the address routines' own   */
/* scratch registers met the operand an instruction was holding. Until  */
/* RD68021's M12 that was every one of them.                           */
/* ------------------------------------------------------------------ */

struct eamode {
    int          mode, reg;
    int          next;          /* how many extension words follow */
    unsigned int ext[2];
    int          pcrel;
};

/* (d16,PC): the PC in the calculation is the address of the extension word,
 * PROG_BASE+2 for a one-word opcode. Displacements are chosen so that every
 * address lands inside the filled block. */
#define D16AN  0x0008
#define ABSW   0x2100
#define FULLBD 0x0160   /* full format: BS=0, IS=1, word bd, no indirection */

static const struct eamode EA_ALL[] = {      /* data source: anything readable */
    { 0, 0, 0, { 0, 0 }, 0 },                /* Dn      */
    { 0, 5, 0, { 0, 0 }, 0 },
    { 2, 1, 0, { 0, 0 }, 0 },                /* (An)    */
    { 2, 4, 0, { 0, 0 }, 0 },
    { 3, 2, 0, { 0, 0 }, 0 },                /* (An)+   */
    { 4, 3, 0, { 0, 0 }, 0 },                /* -(An)   */
    { 5, 6, 1, { D16AN, 0 }, 0 },            /* (d16,An)*/
    { 7, 0, 1, { ABSW, 0 }, 0 },             /* (xxx).W */
    { 7, 1, 2, { 0x0000, ABSW }, 0 },        /* (xxx).L */
    { 6, 6, 2, { FULLBD, D16AN }, 0 },       /* (bd,An), full format */
};
#define N_EA_ALL ((int)(sizeof EA_ALL / sizeof EA_ALL[0]))

static const struct eamode EA_ALT[] = {      /* data alterable: no PC, no imm */
    { 0, 0, 0, { 0, 0 }, 0 },
    { 2, 1, 0, { 0, 0 }, 0 },
    { 3, 2, 0, { 0, 0 }, 0 },
    { 4, 3, 0, { 0, 0 }, 0 },
    { 5, 6, 1, { D16AN, 0 }, 0 },
    { 7, 0, 1, { ABSW, 0 }, 0 },
    { 7, 1, 2, { 0x0000, ABSW }, 0 },        /* (xxx).L */
    { 6, 6, 2, { FULLBD, D16AN }, 0 },       /* (bd,An), full format */
};
#define N_EA_ALT ((int)(sizeof EA_ALT / sizeof EA_ALT[0]))

static const struct eamode EA_MEM[] = {      /* memory alterable: no Dn */
    { 2, 1, 0, { 0, 0 }, 0 },
    { 3, 2, 0, { 0, 0 }, 0 },
    { 4, 3, 0, { 0, 0 }, 0 },
    { 5, 6, 1, { D16AN, 0 }, 0 },
    { 7, 0, 1, { ABSW, 0 }, 0 },
    { 7, 1, 2, { 0x0000, ABSW }, 0 },        /* (xxx).L */
    { 6, 6, 2, { FULLBD, D16AN }, 0 },       /* (bd,An), full format */
};
#define N_EA_MEM ((int)(sizeof EA_MEM / sizeof EA_MEM[0]))

static const struct eamode EA_CTL[] = {      /* control: an address, not a value */
    { 2, 1, 0, { 0, 0 }, 0 },
    { 5, 6, 1, { D16AN, 0 }, 0 },
    { 7, 0, 1, { ABSW, 0 }, 0 },
    { 7, 1, 2, { 0x0000, ABSW }, 0 },        /* (xxx).L */
    { 6, 6, 2, { FULLBD, D16AN }, 0 },       /* (bd,An), full format */
};
#define N_EA_CTL ((int)(sizeof EA_CTL / sizeof EA_CTL[0]))

/* One opcode through one set of modes, with `nper` starting states each.
 * `pre` is any word that comes between the opcode and the mode's extension
 * words -- an immediate operand, or MOVEM's register mask. */
static void sweep(unsigned int base, const struct eamode *set, int nset,
                  int npre, const unsigned int *pre, int nper, int flow)
{
    unsigned int w[6];
    int i, j, n;
    for (i = 0; i < nset; i++) {
        memset(w, 0, sizeof w);
        n = 0;
        w[n++] = base | (unsigned)(set[i].mode << 3) | (unsigned)set[i].reg;
        for (j = 0; j < npre; j++) w[n++] = pre[j];
        for (j = 0; j < set[i].next; j++) w[n++] = set[i].ext[j];
        emitn(nper, n, w, set[i].pcrel, flow);
    }
}

/* A (d16,PC) source, whose displacement depends on how many words precede it. */
static void sweep_pc(unsigned int base, int npre, const unsigned int *pre,
                     int nper, int flow)
{
    unsigned int w[6];
    int j, n = 0;
    memset(w, 0, sizeof w);
    w[n++] = base | (7 << 3) | 2;
    for (j = 0; j < npre; j++) w[n++] = pre[j];
    /* The value of the PC is the address of the extension word. */
    w[n] = (DATA_BASE + 0x100 - (PROG_BASE + (unsigned)n * 2)) & 0xFFFF;
    n++;
    emitn(nper, n, w, 1, flow);
}

/* No effective address at all. */
static void plain(unsigned int w0, int nper, int flow)
{
    unsigned int w[6];
    memset(w, 0, sizeof w);
    w[0] = w0;
    emitn(nper, 1, w, 0, flow);
}

static void plain2(unsigned int w0, unsigned int w1, int nper, int flow)
{
    unsigned int w[6];
    memset(w, 0, sizeof w);
    w[0] = w0; w[1] = w1;
    emitn(nper, 2, w, 0, flow);
}

/* Put a long word somewhere before the run. RTS and its relatives need a return
 * address on the stack that is a real address, not fill. */
static void poke(unsigned int a, unsigned int v)
{
    struct test *t = &tests[ntests - 1];
    if (t->npoke >= 4) { fprintf(stderr, "vectors: too many pokes\n"); exit(1); }
    t->poke_a[t->npoke] = a;
    t->poke_v[t->npoke] = v;
    t->npoke++;
}

/* The same long word into the last `n` tests, which is what emitn just made. */
static void poke_n(int n, unsigned int a, unsigned int v)
{
    int i;
    for (i = 0; i < n; i++) {
        struct test *t = &tests[ntests - 1 - i];
        if (t->npoke >= 4) { fprintf(stderr, "vectors: too many pokes\n"); exit(1); }
        t->poke_a[t->npoke] = a;
        t->poke_v[t->npoke] = v;
        t->npoke++;
    }
}

/* ------------------------------------------------------------------ */
/* The instruction groups                                              */
/*                                                                     */
/* Encodings are from PRM section 8, the instruction format summary.    */
/* ------------------------------------------------------------------ */

#define NPER 6      /* starting states per opcode */

/* MOVE: 00 ss  rrr mmm  eeeeee -- note the destination is register THEN mode.
 * Sizes are 01 byte, 11 word, 10 long, which is not the order anything else
 * uses (PRM 8). */
static const unsigned int MOVE_SZ[3] = { 0x1000, 0x3000, 0x2000 };

static void g_move(void)
{
    int s, i;
    for (s = 0; s < 3; s++) {
        /* <ea> -> D1, every source mode. Byte size takes no address register. */
        for (i = 0; i < N_EA_ALL; i++) {
            if (s == 0 && EA_ALL[i].mode == 1) continue;
            sweep(MOVE_SZ[s] | (1 << 9) | (0 << 6),
                  &EA_ALL[i], 1, 0, NULL, NPER, 0);
        }
        sweep_pc(MOVE_SZ[s] | (1 << 9) | (0 << 6), 0, NULL, NPER, 0);
        /* D3 -> <ea>, every destination mode. */
        for (i = 0; i < N_EA_ALT; i++) {
            unsigned int dst = (unsigned)(EA_ALT[i].reg << 9)
                             | (unsigned)(EA_ALT[i].mode << 6);
            unsigned int w[6];
            int n = 0, j;
            memset(w, 0, sizeof w);
            w[n++] = MOVE_SZ[s] | dst | 3;          /* source D3 */
            for (j = 0; j < EA_ALT[i].next; j++) w[n++] = EA_ALT[i].ext[j];
            emitn(NPER, n, w, 0, 0);
        }
        /* memory to memory, the shape that has a read and a write in one
         * instruction and no register in between */
        {
            unsigned int w[2];
            w[0] = MOVE_SZ[s] | (2 << 9) | (2 << 6) | (2 << 3) | 1;  /* (A1)->(A2) */
            w[1] = 0;
            emitn(NPER, 1, w, 0, 0);
        }
    }
    /* MOVEA, word and long only, sign extending the word form to 32 bits. */
    for (s = 1; s < 3; s++)
        for (i = 0; i < N_EA_ALL; i++)
            sweep(MOVE_SZ[s] | (4 << 9) | (1 << 6), &EA_ALL[i], 1, 0, NULL, NPER, 0);
}

static void g_moveq(void)
{
    /* Bit 8 must be zero or it is not MOVEQ, so the immediate is masked rather
     * than computed: 0x01 + 3 * 0x55 is 0x100, which is a different instruction
     * and an illegal one. The drop counter caught it. */
    static const unsigned int imm[4] = { 0x00, 0x7F, 0x80, 0xFF };
    int r, k;
    for (r = 0; r < 8; r++)
        for (k = 0; k < 4; k++)
            plain(0x7000 | (unsigned)(r << 9) | imm[k], 2, 0);
}

/* The one-operand group: CLR NEG NEGX NOT TST. */
static void g_unary(void)
{
    static const unsigned int op[5] = { 0x4200, 0x4400, 0x4000, 0x4600, 0x4A00 };
    int o, s;
    for (o = 0; o < 5; o++)
        for (s = 0; s < 3; s++)
            sweep(op[o] | (unsigned)(s << 6), EA_ALT, N_EA_ALT, 0, NULL, NPER, 0);

    /* TST's MC68020-only operands, PRM 4: an address register at word and long
     * size, an immediate, and the program-counter-relative modes. None of them
     * is alterable, so EA_ALT has none of them -- and the MC68020 decoder once
     * sent all three to illegal instruction, found by a Sun-3 PROM that says
     * TST.L A2. */
    {
        static const struct eamode IMMB[] = {
            { 7, 4, 1, { 0x0080, 0 }, 0 } };
        static const struct eamode AN_IMMW[] = {
            { 1, 3, 0, { 0, 0 }, 0 }, { 7, 4, 1, { 0x8000, 0 }, 0 } };
        static const struct eamode AN_IMML[] = {
            { 1, 3, 0, { 0, 0 }, 0 }, { 7, 4, 2, { 0x8000, 0x0001 }, 0 } };
        sweep(0x4A00, IMMB,    1, 0, NULL, NPER, 0);
        sweep(0x4A40, AN_IMMW, 2, 0, NULL, NPER, 0);
        sweep(0x4A80, AN_IMML, 2, 0, NULL, NPER, 0);
        for (s = 0; s < 3; s++)
            sweep_pc(0x4A00 | (unsigned)(s << 6), 0, NULL, NPER, 0);
    }
}

static void g_misc(void)
{
    int r;
    for (r = 0; r < 8; r++) {
        plain(0x4840 | (unsigned)r, NPER, 0);            /* SWAP    */
        plain(0x4880 | (unsigned)r, NPER, 0);            /* EXT.W   */
        plain(0x48C0 | (unsigned)r, NPER, 0);            /* EXT.L   */
        plain(0x49C0 | (unsigned)r, NPER, 0);            /* EXTB.L  */
    }
    /* EXG, all three register-pair forms. */
    for (r = 0; r < 4; r++) {
        plain(0xC140 | (unsigned)(r << 9) | (unsigned)(7 - r), NPER, 0); /* Dx,Dy */
        plain(0xC148 | (unsigned)(r << 9) | (unsigned)(6 - r), NPER, 0); /* Ax,Ay */
        plain(0xC188 | (unsigned)(r << 9) | (unsigned)(5 - r), NPER, 0); /* Dx,Ay */
    }
    plain(0x4E71, 4, 0);                                 /* NOP     */
}

static void g_addr(void)
{
    int i;
    /* LEA <ea>,A4 and PEA <ea> -- control modes only. */
    for (i = 0; i < N_EA_CTL; i++) {
        sweep(0x41C0 | (4 << 9), &EA_CTL[i], 1, 0, NULL, NPER, 0);
        sweep(0x4840, &EA_CTL[i], 1, 0, NULL, NPER, 0);
    }
    sweep_pc(0x41C0 | (4 << 9), 0, NULL, NPER, 0);
    sweep_pc(0x4840, 0, NULL, NPER, 0);
    /* LINK.W, LINK.L and UNLK. The displacement is negative, as a frame's is. */
    plain2(0x4E50 | 5, 0xFFF0, NPER, 0);                 /* LINK.W A5,#-16 */
    {
        unsigned int w[6];
        memset(w, 0, sizeof w);
        w[0] = 0x4808 | 5; w[1] = 0xFFFF; w[2] = 0xFF00; /* LINK.L A5,#-256 */
        emitn(NPER, 3, w, 0, 0);
    }
    plain(0x4E58 | 5, NPER, 0);                          /* UNLK A5 */
}

/* The two-operand arithmetic and logic group. Each has the same shape:
 * an opmode field selecting size and direction, and an <ea>. */
static void g_alu(void)
{
    static const unsigned int op[5]   = { 0xD000, 0x9000, 0xC000, 0x8000, 0xB000 };
    static const int          mem_ok[5] = { 1, 1, 1, 1, 1 };  /* <ea> as destination */
    /*                        ADD     SUB     AND     OR      EOR/CMP          */
    int o, s, i;

    for (o = 0; o < 4; o++) {           /* ADD SUB AND OR: both directions */
        for (s = 0; s < 3; s++) {
            /* Dn = Dn op <ea>. AND and OR take no address register source. */
            for (i = 0; i < N_EA_ALL; i++) {
                if (EA_ALL[i].mode == 1) continue;   /* no An source for any of
                                                        these at byte size, and
                                                        none at all for AND/OR */
                sweep(op[o] | (2 << 9) | (unsigned)(s << 6),
                      &EA_ALL[i], 1, 0, NULL, NPER, 0);
            }
            sweep_pc(op[o] | (2 << 9) | (unsigned)(s << 6), 0, NULL, NPER, 0);
            /* <ea> = <ea> op Dn, memory destinations only. */
            if (mem_ok[o])
                sweep(op[o] | (6 << 9) | (unsigned)((s + 4) << 6),
                      EA_MEM, N_EA_MEM, 0, NULL, NPER, 0);
        }
        /* ADDA and SUBA: word and long, and no condition codes at all. */
        if (o < 2)
            for (s = 1; s < 3; s++)
                sweep(op[o] | (5 << 9) | (unsigned)((s == 1 ? 3 : 7) << 6),
                      EA_ALL, N_EA_ALL, 0, NULL, NPER, 0);
    }

    /* CMP, CMPA and EOR share the 1011 line. */
    for (s = 0; s < 3; s++) {
        for (i = 0; i < N_EA_ALL; i++) {
            if (s == 0 && EA_ALL[i].mode == 1) continue;
            sweep(0xB000 | (2 << 9) | (unsigned)(s << 6),
                  &EA_ALL[i], 1, 0, NULL, NPER, 0);        /* CMP  <ea>,Dn */
        }
        sweep(0xB000 | (6 << 9) | (unsigned)((s + 4) << 6),
              EA_MEM, N_EA_MEM, 0, NULL, NPER, 0);         /* EOR  Dn,<ea> */
        sweep(0xB000 | (6 << 9) | (unsigned)((s + 4) << 6),
              EA_ALT, 1, 0, NULL, NPER, 0);                /* EOR  Dn,Dn   */
    }
    for (s = 1; s < 3; s++)
        sweep(0xB000 | (5 << 9) | (unsigned)((s == 1 ? 3 : 7) << 6),
              EA_ALL, N_EA_ALL, 0, NULL, NPER, 0);         /* CMPA */

    /* CMPM (Ay)+,(Ax)+ -- the only mode it has. */
    for (s = 0; s < 3; s++)
        plain(0xB108 | (unsigned)(s << 6) | (2 << 9) | 3, NPER, 0);
}

/* The immediate group: ADDI SUBI ANDI ORI EORI CMPI. */
static void g_imm(void)
{
    static const unsigned int op[6] = { 0x0600, 0x0400, 0x0200, 0x0000,
                                        0x0A00, 0x0C00 };
    static const unsigned int imm_b[4] = { 0x0001, 0x007F, 0x0080, 0x00FF };
    static const unsigned int imm_w[4] = { 0x0001, 0x7FFF, 0x8000, 0xFFFF };
    int o, k, i;
    for (o = 0; o < 6; o++) {
        for (k = 0; k < 4; k++) {
            unsigned int pre[2];
            /* byte and word take one extension word, long takes two */
            pre[0] = imm_b[k];
            sweep(op[o] | (0 << 6), EA_ALT, N_EA_ALT, 1, pre, 2, 0);
            pre[0] = imm_w[k];
            sweep(op[o] | (1 << 6), EA_ALT, N_EA_ALT, 1, pre, 2, 0);
            pre[0] = imm_w[k]; pre[1] = imm_w[3 - k];
            sweep(op[o] | (2 << 6), EA_ALT, N_EA_ALT, 2, pre, 2, 0);
        }
    }
    /* ADDQ and SUBQ, every data value including the 8 that zero encodes, and
     * the address-register forms, which touch no condition code. */
    for (i = 1; i <= 8; i++) {
        unsigned int q = (unsigned)(i & 7) << 9;
        int s;
        for (s = 0; s < 3; s++) {
            sweep(0x5000 | q | (unsigned)(s << 6), EA_ALT, N_EA_ALT, 0, NULL, 2, 0);
            sweep(0x5100 | q | (unsigned)(s << 6), EA_ALT, N_EA_ALT, 0, NULL, 2, 0);
        }
        plain(0x5048 | q | 3, 2, 0);          /* ADDQ.W #i,A3 */
        plain(0x5088 | q | 3, 2, 0);          /* ADDQ.L #i,A3 */
        plain(0x5148 | q | 3, 2, 0);          /* SUBQ.W #i,A3 */
        plain(0x5188 | q | 3, 2, 0);          /* SUBQ.L #i,A3 */
    }
}

/* ADDX and SUBX, both forms: register to register and -(Ay) to -(Ax). */
static void g_extend(void)
{
    static const unsigned int op[2] = { 0xD100, 0x9100 };
    int o, s;
    for (o = 0; o < 2; o++)
        for (s = 0; s < 3; s++) {
            plain(op[o] | (unsigned)(s << 6) | (2 << 9) | 5, NPER, 0);
            plain(op[o] | (unsigned)(s << 6) | (2 << 9) | 8 | 3, NPER, 0);
        }
}

/* The shifts and rotates: ASL ASR LSL LSR ROL ROR ROXL ROXR, register forms in
 * all three sizes with both a count in the instruction and a count in a
 * register, and the memory forms, which are one bit of a word. */
static void g_shift(void)
{
    int type, dir, s, c;
    for (type = 0; type < 4; type++)
        for (dir = 0; dir < 2; dir++) {
            for (s = 0; s < 3; s++) {
                /* An immediate count of 1..8, 0 meaning 8. */
                for (c = 0; c < 8; c++)
                    plain(0xE000 | (unsigned)(c << 9) | (unsigned)(dir << 8)
                          | (unsigned)(s << 6) | (unsigned)(type << 3) | 4,
                          2, 0);
                /* A count in D2, which is random: the 68030 and 68040 take it modulo 64
                 * for the shifts and modulo the size plus one for the rotates
                 * through X, so the whole range has to be reachable. */
                plain(0xE020 | (2 << 9) | (unsigned)(dir << 8)
                      | (unsigned)(s << 6) | (unsigned)(type << 3) | 4,
                      NPER * 3, 0);
            }
            /* The memory forms shift one bit of a word. */
            sweep(0xE0C0 | (unsigned)(type << 9) | (unsigned)(dir << 8),
                  EA_MEM, N_EA_MEM, 0, NULL, NPER, 0);
        }
}

/* BTST BCHG BCLR BSET, static and dynamic. A byte in memory, a long word in a
 * register -- PRM 4: the bit number is modulo 8 for memory and modulo 32 for a
 * register, and getting that the wrong way round is a real bug this catches. */
static void g_bit(void)
{
    static const unsigned int op[4] = { 0x0000, 0x0040, 0x0080, 0x00C0 };
    int o, b;
    for (o = 0; o < 4; o++) {
        /* Dynamic: the bit number in D1. */
        sweep(0x0100 | (1 << 9) | op[o], EA_ALT, N_EA_ALT, 0, NULL, NPER, 0);
        if (o == 0) {
            /* BTST only: the program-space operands, and BTST Dn,#<data> --
             * the one bit instruction that takes an immediate operand (PRM 4,
             * BTST's addressing-mode table). D1 is random, so the bit number
             * is too, modulo 8. These two were added after the rest; the
             * random stream is put back afterwards so that every other test
             * keeps the starting state it had. */
            unsigned int keep;
            sweep_pc(0x0100 | (1 << 9), 0, NULL, NPER, 0);
            keep = rng_state;
            plain2(0x0100 | (1 << 9) | 0x3C, 0x00A5, NPER, 0);
            plain2(0x0100 | (1 << 9) | 0x3C, 0x005A, NPER, 0);
            rng_state = keep;
        }
        /* Static: the bit number in the word after the opcode. */
        for (b = 0; b < 40; b += 7) {
            unsigned int pre = (unsigned)b;
            sweep(0x0800 | op[o], EA_ALT, N_EA_ALT, 1, &pre, 2, 0);
        }
    }
}

/* Scc, DBcc, Bcc, BRA and BSR over all sixteen conditions. */
static void g_cond(void)
{
    int cc;
    for (cc = 0; cc < 16; cc++) {
        /* Scc: T and F are conditions 0 and 1, and Scc has all sixteen. */
        sweep(0x50C0 | (unsigned)(cc << 8), EA_ALT, N_EA_ALT, 0, NULL, 3, 0);
        /* DBcc Dn,#d -- the count register is random, so both the taken and the
         * exhausted arms are reached. */
        plain2(0x50C8 | (unsigned)(cc << 8) | 6, 0x0004, NPER, 1);
        if (cc >= 2) {
            /* Bcc: the byte, word and long displacements. All three land inside
             * the program area, where a NOP is waiting. */
            plain(0x6000 | (unsigned)(cc << 8) | 0x04, NPER, 1);
            plain2(0x6000 | (unsigned)(cc << 8), 0x0006, NPER, 1);
            {
                unsigned int w[6];
                memset(w, 0, sizeof w);
                w[0] = 0x6000 | (unsigned)(cc << 8) | 0xFF;
                w[1] = 0x0000; w[2] = 0x0008;
                emitn(NPER, 3, w, 0, 1);
            }
        }
    }
    /* BRA and BSR, all three displacement sizes. */
    plain(0x6004, NPER, 1);
    plain2(0x6000, 0x0006, NPER, 1);
    plain(0x6104, NPER, 1);                   /* BSR.B */
    plain2(0x6100, 0x0006, NPER, 1);          /* BSR.W */
    {
        unsigned int w[6];
        memset(w, 0, sizeof w);
        w[0] = 0x61FF; w[1] = 0x0000; w[2] = 0x0008;
        emitn(NPER, 3, w, 0, 1);              /* BSR.L */
    }
}

/* JMP, JSR and the returns. The returns need a real address on the stack, which
 * is what poke_n is for -- fill would send the program counter anywhere. */
static void g_jump(void)
{
    int i;
    for (i = 0; i < N_EA_CTL; i++) {
        sweep(0x4EC0, &EA_CTL[i], 1, 0, NULL, NPER, 1);   /* JMP */
        sweep(0x4E80, &EA_CTL[i], 1, 0, NULL, NPER, 1);   /* JSR */
    }
    sweep_pc(0x4EC0, 0, NULL, NPER, 1);
    sweep_pc(0x4E80, 0, NULL, NPER, 1);

    plain(0x4E75, NPER, 1);                               /* RTS */
    poke_n(NPER, STACK, PROG_BASE + 8);
    /* RTR pops a WORD of condition codes and then a LONG program counter, so
     * the long word at the stack pointer is the codes and the top half of the
     * address, and the next one holds the bottom half. */
    plain(0x4E77, NPER, 1);                               /* RTR */
    poke_n(NPER, STACK,     0x001F0000);
    poke_n(NPER, STACK + 4, ((PROG_BASE + 8) & 0xFFFF) << 16);
    plain2(0x4E74, 0x0010, NPER, 1);                      /* RTD #16 */
    poke_n(NPER, STACK, PROG_BASE + 8);
}

/* MULU MULS DIVU DIVS, the word forms the MC68010 has and the long forms the
 * MC68020 added. A zero divisor traps; the traps group has one on purpose, and
 * a random divisor of zero here traps the same way and is compared like any
 * other exception. */
static void g_muldiv(void)
{
    int i;
    for (i = 0; i < N_EA_ALL; i++) {
        if (EA_ALL[i].mode == 1) continue;
        sweep(0xC0C0 | (3 << 9), &EA_ALL[i], 1, 0, NULL, NPER, 0);   /* MULU.W */
        sweep(0xC1C0 | (3 << 9), &EA_ALL[i], 1, 0, NULL, NPER, 0);   /* MULS.W */
        sweep(0x80C0 | (3 << 9), &EA_ALL[i], 1, 0, NULL, NPER, 0);   /* DIVU.W */
        sweep(0x81C0 | (3 << 9), &EA_ALL[i], 1, 0, NULL, NPER, 0);   /* DIVS.W */
    }
    /* The 32-bit forms, PRM 4: MULU.L <ea>,Dl and the 64-bit MULU.L <ea>,Dh:Dl,
     * and DIVU.L with a 32- and a 64-bit dividend. */
    {
        unsigned int pre;
        pre = (2 << 12);                 /* Dl = D2, unsigned, 32 bits    */
        sweep(0x4C00, EA_ALT, N_EA_ALT, 1, &pre, NPER, 0);           /* MULU.L */
        pre = (2 << 12) | 0x0800;        /* signed                        */
        sweep(0x4C00, EA_ALT, N_EA_ALT, 1, &pre, NPER, 0);           /* MULS.L */
        pre = (2 << 12) | 0x0400 | 5;    /* 64-bit product into D5:D2     */
        sweep(0x4C00, EA_ALT, N_EA_ALT, 1, &pre, NPER, 0);
        pre = (2 << 12);                 /* DIVU.L <ea>,Dq                */
        sweep(0x4C40, EA_ALT, N_EA_ALT, 1, &pre, NPER, 0);
        pre = (2 << 12) | 0x0800;        /* DIVS.L                        */
        sweep(0x4C40, EA_ALT, N_EA_ALT, 1, &pre, NPER, 0);
        pre = (2 << 12) | 0x0400 | 5;    /* 64-bit dividend D5:D2         */
        sweep(0x4C40, EA_ALT, N_EA_ALT, 1, &pre, NPER, 0);
    }
}

/* ABCD SBCD NBCD, both register and memory forms. */
static void bcd_operands(int n)
{
    int i, j;
    for (i = 0; i < n; i++) {
        struct test *t = &tests[ntests - 1 - i];
        t->bcdfill = 1;
        for (j = 0; j < 8; j++) t->d[j] = bcd_word(t->d[j]);
    }
}

/* PACK and UNPK -- PRM 4, new on the MC68020.
 *
 * The adjustment word is the point of the instruction, so it is swept rather
 * than left at zero: $0000 is the identity, and the interesting values are the
 * ones that carry out of a nibble. bcd_operands fills the registers and memory
 * with digits, which is what the instruction is for, but the encoding takes
 * anything and the pack is a bit shuffle, so plain binary is worth running too
 * and is what the registers already hold. */
static void g_packunpk(void)
{
    static const unsigned int ADJ[] = { 0x0000u, 0x0001u, 0x9999u, 0x6666u,
                                        0x0F0Fu, 0xF0F0u, 0x00FFu, 0x8000u };
    int i;
    /* The register forms. The predecrement forms are their own group,
     * packunpk_mem, so that a disagreement about which byte is significant
     * (doc/divergences.md) is reported apart from the arithmetic. */
    for (i = 0; i < (int)(sizeof ADJ / sizeof ADJ[0]); i++) {
        plain2(0x8140u | (2 << 9) | 5, ADJ[i], NPER, 0);   /* PACK D5,D2  */
        bcd_operands(NPER);
        plain2(0x8180u | (2 << 9) | 5, ADJ[i], NPER, 0);   /* UNPK D5,D2  */
        bcd_operands(NPER);
    }
}

/* CMP2 and CHK2 are the cmp2 group, below. */

/* MOVES -- PRM 6. The point of the instruction is the function code it uses, so
 * what this really tests is the SPACE each access goes to: the sweep compares
 * the access list, and the space is part of it. SFC and DFC are part of the
 * initial state the generator randomises, so every test names a different one.
 *
 * Memory alterable modes only. */
static void g_moves(void)
{
    static const unsigned int SZ[] = { 0x0E00u, 0x0E40u, 0x0E80u };
    static const unsigned int XW[] = {
        0x1000u,        /* <ea> -> D1 */
        0x9000u,        /* <ea> -> A1 */
        0x1800u,        /* D1 -> <ea> */
        0x9800u,        /* A1 -> <ea> */
    };
    int i, j;
    for (i = 0; i < 3; i++)
        for (j = 0; j < (int)(sizeof XW / sizeof XW[0]); j++)
            sweep(SZ[i], EA_MEM, N_EA_MEM, 1, &XW[j], NPER, 0);
}

/* The eight bit-field instructions -- PRM 4.
 *
 * The extension word is the instruction: offset and width, each either an
 * immediate or a data register. The immediates are swept over the values that
 * matter -- a field inside one byte, one that straddles a byte, one that fills
 * a long word, and the encoded zero that means thirty-two -- and the register
 * forms let the operand generator's random registers supply offsets that are
 * large, negative, and not multiples of eight, which is where the byte count
 * and the base address are earned.
 *
 * Both the register-direct and the memory forms are run, because they share
 * nothing but the extension word: one wraps inside thirty-two bits and the
 * other walks up to five bytes of memory. */
static void g_bitfield(void)
{
    static const unsigned int OPS[] = {
        0xE8C0u,  /* BFTST  */ 0xE9C0u,  /* BFEXTU */
        0xEAC0u,  /* BFCHG  */ 0xEBC0u,  /* BFEXTS */
        0xECC0u,  /* BFCLR  */ 0xEDC0u,  /* BFFFO  */
        0xEEC0u,  /* BFSET  */ 0xEFC0u,  /* BFINS  */
    };
    /* {Do,offset,Dw,width} as the extension word packs them, plus a data
     * register in bits 14-12 for the four that name one. */
    static const unsigned int XW[] = {
        0x0000u,          /* offset 0,  width 32 (the encoded zero) */
        0x0001u,          /* offset 0,  width 1                     */
        0x0008u,          /* offset 0,  width 8                     */
        0x01C7u,          /* offset 7,  width 7  -- inside one byte  */
        0x0148u,          /* offset 5,  width 8  -- straddles one    */
        0x07C0u,          /* offset 31, width 32 -- five bytes       */
        0x0820u,          /* offset in D0, width 32                  */
        0x0925u,          /* offset in D4, width in D5               */
        0x08A0u,          /* offset in D2, width 32                  */
    };
    int i, j;
    /* The register-direct forms. The memory forms are their own group,
     * bitfield_mem, because PRM 4's NOTE ("accesses only those bytes in memory
     * that contain some portion of the bit field") makes their access list a
     * question of its own, apart from the field arithmetic this one checks. */
    for (i = 0; i < 8; i++)
        for (j = 0; j < (int)(sizeof XW / sizeof XW[0]); j++) {
            unsigned int xw = XW[j] | 0x3000u;   /* D3 for the four that use one */
            plain2(OPS[i] | 0x0003u, xw, NPER, 0);        /* ... on D3 */
        }
}

static void g_bcd(void)
{
    plain(0xC100 | (2 << 9) | 5, NPER * 2, 0);
    bcd_operands(NPER * 2);        /* ABCD D5,D2      */
    plain(0xC108 | (2 << 9) | 3, NPER * 2, 0);
    bcd_operands(NPER * 2);        /* ABCD -(A3),-(A2)*/
    plain(0x8100 | (2 << 9) | 5, NPER * 2, 0);
    bcd_operands(NPER * 2);        /* SBCD D5,D2      */
    plain(0x8108 | (2 << 9) | 3, NPER * 2, 0);
    bcd_operands(NPER * 2);        /* SBCD -(A3),-(A2)*/
    sweep(0x4800, EA_ALT, N_EA_ALT, 0, NULL, NPER, 0);/* NBCD <ea>       */
    bcd_operands(NPER * N_EA_ALT);
}

/* TAS: a read-modify-write, and the only instruction in the MC68010 set that
 * holds RMC across two accesses. */
static void g_tas(void)
{
    sweep(0x4AC0, EA_ALT, N_EA_ALT, 0, NULL, NPER, 0);
}

/* MOVEM, both directions, both sizes, and the masks that matter: none, one at
 * each end, alternating, and all of them. The predecrement form's mask is
 * reversed, which is the part worth sweeping. */
static void g_movem(void)
{
    static const unsigned int mask[6] = { 0x0000, 0x0001, 0x8000, 0xFFFF,
                                          0xAAAA, 0x0F0F };
    int m, s;
    for (m = 0; m < 6; m++)
        for (s = 0; s < 2; s++) {
            unsigned int sz = (unsigned)(s << 6);       /* 0 word, 1 long */
            unsigned int pre = mask[m];
            /* registers to memory, and the predecrement form */
            sweep(0x4880 | sz, EA_CTL, N_EA_CTL, 1, &pre, 2, 0);
            plain2(0x4880 | sz | (4 << 3) | 3, mask[m], 2, 0);
            /* memory to registers, and the postincrement form */
            sweep(0x4C80 | sz, EA_CTL, N_EA_CTL, 1, &pre, 2, 0);
            plain2(0x4C80 | sz | (3 << 3) | 2, mask[m], 2, 0);
        }
}

/* MOVEP: a word or a long word through every other byte of memory. */
static void g_movep(void)
{
    int op;
    for (op = 4; op < 8; op++)
        plain2(0x0008 | (1 << 9) | (unsigned)(op << 6) | 3, 0x0010, NPER, 0);
}

/* The condition codes as an operand: MOVE to and from CCR, and the three
 * immediate forms. MOVE from CCR is an MC68010 addition. */
static void g_ccr(void)
{
    sweep(0x42C0, EA_ALT, N_EA_ALT, 0, NULL, NPER, 0);        /* MOVE  CCR,<ea> */
    sweep(0x44C0, EA_ALL, N_EA_ALL, 0, NULL, NPER, 0);        /* MOVE  <ea>,CCR */
    {
        int k;
        static const unsigned int v[4] = { 0x0000, 0x001F, 0x000A, 0x0015 };
        for (k = 0; k < 4; k++) {
            plain2(0x023C, v[k], 2, 0);                       /* ANDI  #x,CCR   */
            plain2(0x003C, v[k], 2, 0);                       /* ORI   #x,CCR   */
            plain2(0x0A3C, v[k], 2, 0);                       /* EORI  #x,CCR   */
        }
    }
}

/* The exceptions that no other group reaches: the traps, the illegal and
 * unimplemented instruction lines, the privilege violation and the return.
 *
 * These are compared like any other instruction. What makes them a test of
 * exception processing is that the frame they build is in the access list --
 * four or six words, each with its address and its value -- and that the
 * program counter afterwards says which vector was taken, because every vector
 * in the table points somewhere different. */
/* One privileged instruction, run in USER mode, where it must trap.
 *
 * The user stack has to be somewhere real: the frame goes on the SUPERVISOR
 * stack -- UM30 6.1 step three builds it on the active supervisor stack, and the
 * first step has already set S -- but the instruction runs with A7 meaning the
 * user one, and an instruction that touches it before trapping would go
 * somewhere undefined otherwise. */
static void user_mode(unsigned int w0, unsigned int w1, int words)
{
    int i;
    if (words) plain2(w0, w1, 2, 1);
    else       plain(w0, 2, 1);
    for (i = 0; i < 2; i++) {
        struct test *t = &tests[ntests - 1 - i];
        t->sr  = (t->sr & ~0x2000u);      /* S clear: the user level */
        t->usp = STACK - 0x100;
    }
}


/* One RTE, with a frame poked under the stack pointer. */
static void rte_frame(unsigned int sr, unsigned int pc, unsigned int fmtvec)
{
    plain(0x4E73, 2, 1);
    poke_n(2, STACK,     (sr << 16) | (pc >> 16));
    poke_n(2, STACK + 4, ((pc & 0xFFFFu) << 16) | fmtvec);
}


static void g_traps(void)
{
    int i;

    /* TRAP #0 to #15. */
    for (i = 0; i < 16; i++)
        plain(0x4E40 | (unsigned)i, 2, 1);

    /* TRAPV, both ways: the condition codes are random, so about half of these
     * trap and about half do nothing. */
    plain(0x4E76, NPER * 2, 1);

    /* TRAPcc over every condition, and all three operand forms. */
    for (i = 0; i < 16; i++) {
        plain(0x50FC | (unsigned)(i << 8), 3, 1);              /* no operand */
        plain2(0x50FA | (unsigned)(i << 8), 0x1234, 3, 1);     /* a word     */
        {
            unsigned int w[6];
            memset(w, 0, sizeof w);
            w[0] = 0x50FB | (unsigned)(i << 8);
            w[1] = 0x1234; w[2] = 0x5678;
            emitn(3, 3, w, 0, 1);                              /* a long word */
        }
    }

    /* ILLEGAL, and the unimplemented A line (UM 8.2.4). The F line is left
     * out here: on the MC68040 it is the FPU's, the MMU's ($F5xx: PFLUSH,
     * PTEST) and MOVE16's ($F6xx), and an F-line trap is something the FPU
     * groups (M11) have to sweep with the FPU's own encodings in view. */
    plain(0x4AFC, 2, 1);                                       /* ILLEGAL */
    plain(0xA000, 2, 1);                                       /* A-line  */
    plain(0xA5A5, 2, 1);

    /* The privileged instructions, run at the supervisor level, where they are
     * legal: this half is the test that each one does what it says. The other
     * half -- that each one TRAPS in user mode -- is user_mode() below, which
     * clears S in the starting state and expects vector 8 every time. */
    /* RTE, over the frames UM30 6.1.12 says it understands and one it does not.
     *
     * A frame is a WORD of status register at +$00, a LONG program counter at
     * +$02 and a WORD of format and vector at +$06, so a long-word poke at the
     * base carries the status register and the TOP HALF of the program
     * counter. Writing the obvious thing there instead put $1010 in the format
     * word, which is a throwaway frame, and the test then measured something
     * nobody meant to ask about. */
    rte_frame(0x0000, 0x00001010u, 0x0000);   /* $0, returning to user mode */
    rte_frame(0x2700, 0x00001010u, 0x0000);   /* $0, staying supervisor     */
    rte_frame(0x2000, 0x00001010u, 0x2000);   /* $2, a six-word frame       */
    rte_frame(0x2700, 0x00001010u, 0xA000);   /* and a format error: $A is
                                                 an MC68020/30 frame, not an
                                                 MC68040 one (UM 8.4)        */
    /* $4, the MC68LC040's (UM A.5.2), its EA and faulted PC zero. On the
     * MC68040 it is a format error (UM 8.4, A.5.2: "the MC68040 cannot
     * accept the eight-word unimplemented stack frame"), and UAE040 takes it
     * there as well (doc/oracles.md): core_lc040_tb checks that one. */
    if (lc) rte_frame(0x2700, 0x00001010u, 0x402C);
    plain2(0x46FC, 0x2700, 2, 0);                              /* MOVE #imm,SR */
    plain(0x40C0 | 3, 2, 0);                                   /* MOVE SR,D3   */
    plain2(0x027C, 0xF8FF, 2, 0);                              /* ANDI #x,SR   */
    plain2(0x007C, 0x0700, 2, 0);                              /* ORI  #x,SR   */
    plain2(0x0A7C, 0x1000, 2, 0);                              /* EORI #x,SR   */
    plain(0x4E60 | 3, 2, 0);                                   /* MOVE A3,USP  */
    plain(0x4E68 | 3, 2, 0);                                   /* MOVE USP,A3  */

    /* And a divide by zero, which no other group produces on purpose. */
    /* RD68021 had $82BC here, which is OR.L #imm,D1 and divides nothing. */
    plain2(0x82FC, 0x0000, 2, 1);                              /* DIVU.W #0,D1 */
    poke_n(2, DATA_BASE, 0);

    /* UM30 6.1.6: "if a user program attempts to execute a privileged
     * instruction, a privilege violation exception occurs". Every one of these
     * is the same instruction as above with the S bit clear, and every one of
     * them must end at vector 8 with a four-word frame carrying the address of
     * the instruction that tried. */
    user_mode(0x4E73, 0, 0);                                   /* RTE          */
    user_mode(0x46FC, 0x2700, 1);                              /* MOVE #imm,SR */
    user_mode(0x40C0 | 3, 0, 0);                               /* MOVE SR,D3   */
    user_mode(0x027C, 0xF8FF, 1);                              /* ANDI #x,SR   */
    user_mode(0x007C, 0x0700, 1);                              /* ORI  #x,SR   */
    user_mode(0x0A7C, 0x1000, 1);                              /* EORI #x,SR   */
    user_mode(0x4E60 | 3, 0, 0);                               /* MOVE A3,USP  */
    user_mode(0x4E68 | 3, 0, 0);                               /* MOVE USP,A3  */
    user_mode(0x4E7A, 0x0000, 1);                              /* MOVEC SFC,D0 */
    user_mode(0x4E7B, 0x0000, 1);                              /* MOVEC D0,SFC */
}

/* Tracing -- UM30 6.1.7 and UM30 table 6-2.
 *
 * The same instructions run three times: with tracing off, with T1 set (every
 * instruction is traced) and with T0 set (only those that change the flow). The
 * mix is chosen so that the second and third disagree -- a MOVEQ is traced by
 * one and not the other, a BRA by both -- because a test where they agree
 * cannot tell the two modes apart.
 *
 * T1 T0 = 11 is "undefined, reserved" in UM30 table 6-2 and is not swept.
 */
static void trace_at(unsigned int w0, unsigned int w1, int words, int flow)
{
    int i, k;
    static const unsigned int mode[3] = { 0x0000u, 0x8000u, 0x4000u };
    for (k = 0; k < 3; k++) {
        if (words) plain2(w0, w1, 2, flow);
        else       plain(w0, 2, flow);
        for (i = 0; i < 2; i++) {
            struct test *t = &tests[ntests - 1 - i];
            t->sr = (t->sr & 0x3FFFu) | mode[k];
        }
    }
}

static void g_trace(void)
{
    /* Instructions that do NOT change the flow. */
    trace_at(0x7042, 0, 0, 0);                  /* MOVEQ #$42,D0   */
    trace_at(0x2200, 0, 0, 0);                  /* MOVE.L D0,D1    */
    trace_at(0xD282, 0, 0, 0);                  /* ADD.L  D2,D1    */
    trace_at(0x4E71, 0, 0, 0);                  /* NOP             */

    /* ... and instructions that do. */
    trace_at(0x6004, 0, 0, 1);                  /* BRA.B  *+6      */
    trace_at(0x6000, 0x0006, 1, 1);             /* BRA.W           */
    trace_at(0x4EF8, 0x1010, 1, 1);             /* JMP $1010.W     */
    trace_at(0x4E40, 0, 0, 1);                  /* TRAP #0         */
    trace_at(0x4E76, 0, 0, 1);                  /* TRAPV           */

    /* A status register write counts as a change of flow -- UM30 6.1.7, because
     * a real part re-prefetches after one. */
    trace_at(0x46FC, 0x2700, 1, 1);             /* MOVE #imm,SR    */
    trace_at(0x007C, 0x0000, 1, 1);             /* ORI  #0,SR      */

    /* And an instruction that is never executed, which UM30 6.1.7 says is NOT
     * traced however the bits are set. */
    trace_at(0x4AFC, 0, 0, 1);                  /* ILLEGAL         */
    trace_at(0xA000, 0, 0, 1);                  /* A-line          */
}

/* MOVEC, both directions, over the MC68040's control registers that are not
 * the MMU's (PRM 6, UM 2.2 and 3.1): SFC, DFC, CACR, USP, VBR, MSP and ISP.
 * TC, ITT0-1, DTT0-1, MMUSR, URP and SRP are M10's (the pmmu040 group), and
 * the MC68020/30's CAAR ($802) does not exist here -- an illegal instruction,
 * kept as one case. CACR keeps only DE and IE (UM 4.2): the oracle masks it
 * the same way, so any value is a fair test of the read-back. */
static void g_movec(void)
{
    static const unsigned int rc[8] = { 0x000, 0x001, 0x002, 0x800, 0x801,
                                        0x803, 0x804, 0x802 };
    int i, ad, n;
    for (i = 0; i < 8; i++)
        for (ad = 0; ad < 2; ad++)
            for (n = 1; n < 4; n++) {
                unsigned int ext = (unsigned)(ad << 15)
                                 | (unsigned)(n << 12) | rc[i];
                plain2(0x4E7A, ext, 2, 0);      /* MOVEC Rc,Rn */
                plain2(0x4E7B, ext, 2, 0);      /* MOVEC Rn,Rc */
            }
}

/* CHK, word and long. About half of them trap, and the frame is compared. */
static void g_chk(void)
{
    sweep(0x4180 | (2 << 9), EA_ALL, N_EA_ALL, 0, NULL, NPER, 0);   /* CHK.W */
    sweep(0x4100 | (2 << 9), EA_ALL, N_EA_ALL, 0, NULL, NPER, 0);   /* CHK.L */
}

/* CMP2 and CHK2 -- PRM 4. The bounds are a pair in memory, lower then upper,
 * at the operand's size; for an address register they are sign-extended to
 * thirty-two bits and compared as such, and either way the comparison works
 * for both signed and unsigned ranges (the upper bound below the lower one is
 * what distinguishes them).
 *
 * Random bounds against a random register are nearly always out of range, so
 * half the tests poke a pair that brackets the register -- and one in three of
 * those an inverted pair, the "unsigned" reading of the same two numbers. */
static void cmp2_bounds(int size, unsigned int lo, unsigned int hi)
{
    struct test *t = &tests[ntests - 1];
    unsigned int a = DATA_BASE + 0x100;     /* (xxx).W ABSW */
    if (t->npoke + 2 > 4) return;
    if (size == 0) {
        poke(a, ((lo & 0xFF) << 24) | ((hi & 0xFF) << 16) | 0x0000);
    } else if (size == 1) {
        poke(a, ((lo & 0xFFFF) << 16) | (hi & 0xFFFF));
    } else {
        poke(a, lo);
        poke(a + 4, hi);
    }
}

static void g_cmp2(void)
{
    int sz, chk, rn, k;
    for (sz = 0; sz < 3; sz++)
        for (chk = 0; chk < 2; chk++)
            for (rn = 0; rn < 2; rn++) {
                unsigned int base = (unsigned)(sz << 9) | 0x00C0u;
                unsigned int xw = (rn ? 0xA000u : 0x2000u) | (chk ? 0x0800u : 0);
                /* through every control mode, random bounds */
                sweep(base, EA_CTL, N_EA_CTL, 1, &xw, 2, chk);
                sweep_pc(base, 1, &xw, 2, chk);
                /* (xxx).W with bounds around the register */
                for (k = 0; k < NPER; k++) {
                    unsigned int w[6], v, lo, hi, span;
                    memset(w, 0, sizeof w);
                    w[0] = base | (7 << 3) | 0; w[1] = xw; w[2] = ABSW;
                    emit(3, w, 0, chk);
                    v = rn ? tests[ntests - 1].a[2] : tests[ntests - 1].d[2];
                    span = (unsigned)(k + 1) * 3u;
                    if (sz == 0) v = rn ? v : (v & 0xFF);
                    if (sz == 1) v = rn ? v : (v & 0xFFFF);
                    lo = v - span + (unsigned)(k & 1) * span;   /* on the bound, half the time */
                    hi = v + span;
                    if (k == 4) { unsigned int x = lo; lo = hi; hi = x; }
                    cmp2_bounds(sz, lo, hi);
                }
            }
}

/* CAS and CAS2 -- PRM 4. A compare and a conditional write, as one
 * indivisible read-modify-write cycle (UM 7.6.1). Both outcomes are reached:
 * a random compare operand almost never matches, so for the absolute modes,
 * whose operand the generator can compute from the fill, half the tests are
 * given the operand in Dc. */
static void g_cas(void)
{
    static const unsigned int SZ[3] = { 0x0A00u, 0x0C00u, 0x0E00u };
    int s, k, i;
    for (s = 0; s < 3; s++) {
        unsigned int xw = (5u << 6) | 2u;       /* Du = D5, Dc = D2 */
        sweep(SZ[s] | 0x00C0u, EA_MEM, N_EA_MEM, 1, &xw, NPER, 0);
        for (k = 0; k < NPER; k++) {
            unsigned int w[6], v, off = 0x100;
            memset(w, 0, sizeof w);
            w[0] = SZ[s] | 0x00C0u | (7 << 3) | 0; w[1] = xw; w[2] = ABSW;
            emit(3, w, 0, 0);
            if (k & 1) continue;
            v = fill_word(ntests - 1, off);
            if (s == 0) v >>= 24;
            if (s == 1) v >>= 16;
            tests[ntests - 1].d[2] = (tests[ntests - 1].d[2] & ~(s == 0 ? 0xFFu : s == 1 ? 0xFFFFu : 0xFFFFFFFFu)) | v;
        }
    }
    /* CAS2.W and CAS2.L, (A1) and (A2), Dc1:Dc2 = D2:D3, Du1:Du2 = D4:D5. Both
     * addresses are made even here: CAS2 on a misaligned operand is the
     * subject of no sentence in the manual worth testing against. */
    for (s = 1; s < 3; s++)
        for (i = 0; i < 2; i++)
            for (k = 0; k < NPER; k++) {
                unsigned int w[6];
                struct test *t;
                memset(w, 0, sizeof w);
                w[0] = SZ[s] | 0x00FCu;
                w[1] = 0x9000u | (4u << 6) | 2u;      /* (A1), Du D4, Dc D2 */
                w[2] = 0xA000u | (5u << 6) | 3u;      /* (A2), Du D5, Dc D3 */
                emit(3, w, 0, 0);
                t = &tests[ntests - 1];
                t->a[1] &= ~3u;
                t->a[2] = (t->a[1] + 0x40u) & 0x23FCu;
                if (i) {
                    /* make the first comparison succeed */
                    unsigned int v = fill_word(ntests - 1, t->a[1] - DATA_BASE);
                    t->d[2] = s == 1 ? (t->d[2] & 0xFFFF0000u) | (v >> 16) : v;
                    if (k & 1) {
                        unsigned int v2 = fill_word(ntests - 1, t->a[2] - DATA_BASE);
                        t->d[3] = s == 1 ? (t->d[3] & 0xFFFF0000u) | (v2 >> 16) : v2;
                    }
                }
            }
}

/* The bit-field instructions on MEMORY -- PRM 4. The field arithmetic is the
 * bitfield group's; what this adds is the base address, the byte count, and
 * the NOTE that a bit-field instruction "accesses only those bytes in memory
 * that contain some portion of the bit field". Offsets in a register are
 * signed and reach anywhere in the address space, so the registers that hold
 * one are given small values, positive and negative, that keep the field in
 * the data block. */
static void g_bitfield_mem(void)
{
    static const unsigned int OPS[] = {
        0xE8C0u, 0xE9C0u, 0xEAC0u, 0xEBC0u, 0xECC0u, 0xEDC0u, 0xEEC0u, 0xEFC0u,
    };
    static const unsigned int XW[] = {
        0x0000u, 0x0001u, 0x0008u, 0x01C7u, 0x0148u, 0x07C0u,
        0x0820u, 0x0925u, 0x08A0u,
    };
    static const struct eamode M[] = {
        { 2, 1, 0, { 0, 0 }, 0 },
        { 5, 6, 1, { D16AN, 0 }, 0 },
        { 7, 0, 1, { ABSW, 0 }, 0 },
    };
    int i, j, m, k;
    for (i = 0; i < 8; i++)
        for (j = 0; j < (int)(sizeof XW / sizeof XW[0]); j++)
            for (m = 0; m < 3; m++) {
                unsigned int xw = XW[j] | 0x3000u;
                sweep(OPS[i], &M[m], 1, 1, &xw, 2, 0);
                for (k = 0; k < 2; k++) {
                    struct test *t = &tests[ntests - 1 - k];
                    t->d[0] = (t->d[0] & 0x7Fu) - 0x40u;     /* -64 .. 63 */
                    t->d[2] = (t->d[2] & 0x1FFu) - 0x100u;   /* -256 .. 255 */
                    t->d[4] = (t->d[4] & 0x3Fu) - 0x20u;
                }
            }
}

/* PACK and UNPK on memory, -(Ay),-(Ax),#adj -- PRM 4. PACK reads two bytes and
 * writes one; UNPK reads one and writes two. Which of the two bytes is the
 * significant one is the question (doc/divergences.md). */
static void g_packunpk_mem(void)
{
    static const unsigned int ADJ[] = { 0x0000u, 0x0001u, 0x9999u, 0x6666u,
                                        0x0F0Fu, 0xF0F0u, 0x00FFu, 0x8000u };
    int i;
    for (i = 0; i < (int)(sizeof ADJ / sizeof ADJ[0]); i++) {
        plain2(0x8148u | (2 << 9) | 3, ADJ[i], NPER, 0);    /* PACK -(A3),-(A2) */
        bcd_operands(NPER);
        plain2(0x8188u | (2 << 9) | 3, ADJ[i], NPER, 0);    /* UNPK -(A3),-(A2) */
        bcd_operands(NPER);
    }
}

/* ------------------------------------------------------------------ */
/* Every addressing mode -- RD68031's `make ea` (uae030_ea.c there)     */
/*                                                                     */
/* Two instruments. LEA <ea>,A0 computes an address and does nothing    */
/* else with it, so A0 afterwards is the address; but LEA takes only    */
/* the control modes, so (An)+, -(An) and the operand fetch an          */
/* effective address exists to make are measured with MOVE.L <ea>,D0,   */
/* in the final registers and the access list.                          */
/*                                                                     */
/* The registers are fixed and distinctive, and the data block holds    */
/* pointers ($3000 + offset: fill 2), so that a memory-indirect address */
/* reads something recognisable and lands back in memory the core and   */
/* the oracle both have.                                                */
/* ------------------------------------------------------------------ */

static void ea_add6(int nwords, const unsigned int *w)
{
    struct test *t;
    int i;
    /* Mode 111 register 010 or 011 -- the two program-counter-relative modes. */
    int pcrel = (((w[0] >> 3) & 7) == 7) && ((w[0] & 7) == 2 || (w[0] & 7) == 3);
    emit(nwords, w, pcrel, 0);
    t = &tests[ntests - 1];
    for (i = 0; i < 8; i++) t->d[i] = 0x00000010u + (unsigned)i * 4u;
    for (i = 0; i < 7; i++) t->a[i] = DATA_BASE + 0x100u + (unsigned)i * 0x40u;
    t->bcdfill = 2;
}

static void ea_add(int nwords, unsigned int w0, unsigned int w1,
                   unsigned int w2, unsigned int w3)
{
    unsigned int w[6];
    w[0] = w0; w[1] = w1; w[2] = w2; w[3] = w3; w[4] = 0; w[5] = 0;
    ea_add6(nwords, w);
}

#define LEA(mode, reg)    (0x41C0u | ((mode) << 3) | (reg))
#define MOVEL(mode, reg)  (0x2000u | ((mode) << 3) | (reg))

/* One full-extension-word case. `nbd` is how many words of base displacement
 * follow (0, 1 or 2); the outer displacement's size comes from I/IS. */
static void ea_full(unsigned int opcode, unsigned int ext, int nbd, int iis)
{
    unsigned int w[6];
    int n = 2, nod = 0;
    if ((iis & 3) != 0)
        nod = ((iis & 3) == 2) ? 1 : (((iis & 3) == 3) ? 2 : 0);
    w[0] = opcode;
    w[1] = ext;
    w[2] = w[3] = w[4] = w[5] = 0;
    /* Displacements that keep every address inside the filled block. */
    if (nbd == 1)      { w[n++] = 0x0040; }
    else if (nbd == 2) { w[n++] = 0x0000; w[n++] = 0x2040; }
    if (nod == 1)      { w[n++] = 0x0004; }
    else if (nod == 2) { w[n++] = 0x0000; w[n++] = 0x0008; }
    ea_add6(n, w);
}

static void g_ea(void)
{
    unsigned int reg, da, ix, wl, sc;

    /* (An) */
    for (reg = 0; reg < 7; reg++) ea_add(1, LEA(2, reg), 0, 0, 0);
    /* (d16,An), both signs */
    for (reg = 0; reg < 7; reg++) {
        ea_add(2, LEA(5, reg), 0x0020, 0, 0);
        ea_add(2, LEA(5, reg), 0xFFE0, 0, 0);
    }
    /* (xxx).W, both signs; (xxx).L */
    ea_add(2, LEA(7, 0), 0x2000, 0, 0);
    ea_add(2, LEA(7, 0), 0x8000, 0, 0);
    ea_add(3, LEA(7, 1), 0x0000, 0x2040, 0);
    /* (d16,PC) */
    ea_add(2, LEA(7, 2), 0x0010, 0, 0);
    ea_add(2, LEA(7, 2), 0xFFF0, 0, 0);
    /* (d8,An,Xn) brief, every index register, both sizes, every scale */
    for (reg = 0; reg < 3; reg++)
        for (da = 0; da < 2; da++)
            for (ix = 0; ix < 8; ix++)
                for (wl = 0; wl < 2; wl++)
                    for (sc = 0; sc < 4; sc++)
                        ea_add(2, LEA(6, reg),
                               (da << 15) | (ix << 12) | (wl << 11) | (sc << 9) | 0x08,
                               0, 0);
    /* (d8,PC,Xn) brief */
    for (da = 0; da < 2; da++)
        for (ix = 0; ix < 8; ix++)
            for (wl = 0; wl < 2; wl++)
                for (sc = 0; sc < 4; sc++)
                    ea_add(2, LEA(7, 3),
                           (da << 15) | (ix << 12) | (wl << 11) | (sc << 9) | 0xF8,
                           0, 0);

    /* The full extension word -- PRM 2 and its tables 2-1 and 2-2: every
     * combination of base suppress, index suppress, base displacement size,
     * memory indirect action and outer displacement size, with the base both
     * an address register and the program counter. */
    {
        unsigned int bs, is, bd, iis, base, ext;
        int d;
        for (base = 0; base < 2; base++)
            for (bs = 0; bs < 2; bs++)
                for (is = 0; is < 2; is++)
                    for (bd = 1; bd < 4; bd++)
                        for (iis = 0; iis < 8; iis++) {
                            /* PRM table 2-2 leaves these reserved. */
                            if (is == 0 && iis == 4) continue;
                            if (is == 1 && iis >= 4) continue;
                            ext = 0x0100u               /* full format */
                                | (1u << 15)            /* D/A: A0 */
                                | (0u << 12)            /* Xn = A0 */
                                | (1u << 11)            /* long index */
                                | (bs << 7) | (is << 6)
                                | (bd << 4) | iis;
                            d = (bd == 1) ? 0 : (bd == 2) ? 1 : 2;
                            ea_full(base ? LEA(7, 3) : LEA(6, 2), ext, d, (int)iis);
                        }
    }

    /* MOVE.L <ea>,D0 -- the modes LEA cannot take, and the operand fetch. */
    for (reg = 0; reg < 7; reg++) ea_add(1, MOVEL(3, reg), 0, 0, 0);   /* (An)+ */
    for (reg = 0; reg < 7; reg++) ea_add(1, MOVEL(4, reg), 0, 0, 0);   /* -(An) */

    /* One of each mode LEA also takes, so that the operand read appears in the
     * access list next to whatever the address calculation itself read. */
    ea_add(1, MOVEL(2, 1), 0, 0, 0);                    /* (An)          */
    ea_add(2, MOVEL(5, 1), 0x0020, 0, 0);               /* (d16,An)      */
    ea_add(2, MOVEL(6, 1), 0x1a08, 0, 0);               /* (d8,An,Xn*4)  */
    ea_add(2, MOVEL(7, 0), 0x2000, 0, 0);               /* (xxx).W       */
    ea_add(3, MOVEL(7, 1), 0x0000, 0x2040, 0);          /* (xxx).L       */
    ea_add(2, MOVEL(7, 2), 0x1000, 0, 0);               /* (d16,PC)      */
    ea_add(2, MOVEL(7, 3), 0x1af8, 0, 0);               /* (d8,PC,Xn*4)  */

    /* And the memory-indirect shapes through MOVE.L, where the access list has
     * both the indirection and the fetch in it and their order matters. */
    {
        unsigned int iis, base, ext;
        for (base = 0; base < 2; base++)
            for (iis = 1; iis < 8; iis++) {
                if (iis == 4) continue;             /* reserved -- PRM 2-2 */
                ext = 0x0100u | (1u << 15) | (1u << 11) | (2u << 4) | iis;
                ea_full(base ? MOVEL(7, 3) : MOVEL(6, 2), ext, 1, (int)iis);
            }
    }
}

/* CINV and CPUSH ($F4xx, PRM 6): every encoding, in supervisor mode with the
 * caches off as every test starts -- each one an instruction that does
 * nothing visible but end, except a scope of 00, which is not CINV or CPUSH
 * and takes the F-line exception (UM 9.4) -- and in user mode, where every
 * one of them is a privilege violation (UM 8.2.5). The address register is
 * whatever the test gives it: with the caches off no line can match. What
 * the caches do with them is make cosim's (m9_icache, m9_dcache) and
 * core_cache_tb's. */
static void g_cinv_cpush(void)
{
    unsigned int op;
    for (op = 0xF400u; op <= 0xF4FFu; op++)
        plain(op, 1, 1);
    for (op = 0xF408u; op <= 0xF4FFu; op += 0x11u)
        user_mode(op, 0, 0);
}

/* The MMU's instructions and registers (UM 3.1, 3.7; PRM 6), translation
 * off -- the translated behaviour, table searches and access faults, is
 * make cosim's (m10_mmu) and core_mmu_tb's, which build tables.
 *
 * MOVEC to and from TC, ITT0-1, DTT0-1, MMUSR, URP and SRP: the registers
 * start random (TC with E clear) and the bits that read as zero are the
 * test (UM 3.1); a value written to TC has E cleared too, so that the
 * ILLEGAL after it is fetched untranslated. PFLUSH, every encoding, in
 * supervisor and user mode. PTEST, both kinds, of an address a TTR of the
 * space DFC names matches -- the one PTEST result the manual defines with
 * translation off (T and R, UM 3.1.4) -- for each of the four spaces that
 * are data or program; and in user mode. URP and SRP keep bits 8-0 as
 * written (UM 3.1.1 only says they must be zero). */
static const unsigned int MMU_RC[8] = { 0x003, 0x004, 0x005, 0x006, 0x007,
                                        0x805, 0x806, 0x807 };
static void mmu_random(struct test *t)
{
    int i;
    for (i = 0; i < 8; i++) t->immu[i] = rnd();
    t->immu[0] &= 0x7FFFu;                       /* TC: E clear */
    t->immu[1] &= ~0x8000u;                      /* the TTRs disabled, so that */
    t->immu[2] &= ~0x8000u;                      /* the fetch after is plain */
    t->immu[3] &= ~0x8000u;
    t->immu[4] &= ~0x8000u;
}
static void g_pmmu040(void)
{
    static const unsigned int dfcs[4] = { 1, 2, 5, 6 };
    int i, ad, n, k, j, d;
    unsigned int op;
    for (i = 0; i < 8; i++)
        for (ad = 0; ad < 2; ad++)
            for (n = 1; n < 4; n++) {
                unsigned int ext = (unsigned)(ad << 15) | (unsigned)(n << 12) | MMU_RC[i];
                plain2(0x4E7A, ext, 2, 0);       /* MOVEC Rc,Rn */
                for (k = 0; k < 2; k++) mmu_random(&tests[ntests - 1 - k]);
                plain2(0x4E7B, ext, 2, 0);       /* MOVEC Rn,Rc */
                for (k = 0; k < 2; k++) {
                    struct test *t = &tests[ntests - 1 - k];
                    mmu_random(t);
                    /* TC E, and a TTR's E: off, so the fetch after is plain. */
                    if (i <= 4) {
                        if (ad) t->a[n] &= ~0x8000u; else t->d[n] &= ~0x8000u;
                    }
                }
            }
    for (op = 0xF500u; op <= 0xF51Fu; op++) {    /* PFLUSHN, PFLUSH, PFLUSHAN, PFLUSHA */
        plain(op, 2, 1);
        for (k = 0; k < 2; k++) mmu_random(&tests[ntests - 1 - k]);
    }
    for (op = 0xF500u; op <= 0xF51Fu; op += 9u) user_mode(op, 0, 0);
    for (j = 0; j < 2; j++)                      /* PTESTW, PTESTR */
        for (n = 0; n < 8; n++)
            for (d = 0; d < 4; d++) {
                plain((j ? 0xF568u : 0xF548u) | (unsigned)n, 1, 1);
                {
                    struct test *t = &tests[ntests - 1];
                    /* A7 is the stack: the TTR then matches it, which is
                     * fine -- PTEST does not move it. */
                    unsigned int an = (n == 7) ? t->isp : t->a[n];
                    /* Not write protected for PTESTW: UAE040 answers B
                     * there, where UM 3.1.4 says T and R (doc/oracles.md). */
                    unsigned int ttr = (an & 0xFF000000u) | 0x0000C000u |
                                       (rnd() & (j ? 0x0364u : 0x0360u));
                    mmu_random(t);
                    t->idfc = dfcs[d];
                    if (dfcs[d] & 2u) t->immu[1] = ttr; else t->immu[3] = ttr;
                }
            }
    user_mode(0xF548u, 0, 0);
    user_mode(0xF56Fu, 0, 0);
}

/* The MC68LC040 (UM A.5; run with -L): every FP instruction is vector 11
 * with an eight-word format $4 frame -- the next instruction's PC, the
 * calculated <ea>, the FP instruction's own PC -- and changes nothing else,
 * An of (An)+ and -(An) included. Every class, through the modes that reach
 * the address calculation: the general operations (built on the MC68040 or
 * not) from every format, FMOVECR, FMOVE out, the control registers, FMOVEM,
 * FScc, FTRAPcc, FBcc, FSAVE and FRESTORE, at the supervisor level and in
 * user mode (onto the supervisor stack; FSAVE and FRESTORE a privilege
 * violation). Left out, and core_lc040_tb's: the encodings PRM 5 has no
 * instruction for, FDBcc, and FMOVE.P with a dynamic k factor, where UAE040
 * stacks what the manual does not (doc/oracles.md). */
static const struct eamode EA_LC[] = {       /* what the address calculation reaches */
    { 2, 1, 0, { 0, 0 }, 0 },                /* (An)    */
    { 3, 2, 0, { 0, 0 }, 0 },                /* (An)+   */
    { 4, 3, 0, { 0, 0 }, 0 },                /* -(An)   */
    { 3, 7, 0, { 0, 0 }, 0 },                /* (A7)+   */
    { 4, 7, 0, { 0, 0 }, 0 },                /* -(A7): a byte steps two */
    { 5, 6, 1, { D16AN, 0 }, 0 },            /* (d16,An)*/
    { 7, 0, 1, { ABSW, 0 }, 0 },             /* (xxx).W */
    { 7, 1, 2, { 0x0000, ABSW }, 0 },        /* (xxx).L */
    { 6, 6, 2, { FULLBD, D16AN }, 0 },       /* (bd,An), full format */
    { 6, 6, 2, { FULLBD | 1, D16AN }, 0 },   /* ([bd,An]): the pointer read */
};
#define N_EA_LC ((int)(sizeof EA_LC / sizeof EA_LC[0]))
#define LC_N 3      /* starting states per encoding */

/* The general operation cmd from op[5:0]'s <ea>: memory, (d16,PC), Dn for the
 * formats that have it, an immediate where it fits in the test's six words. */
static void lc_gen(unsigned int cmd, int fm, int out)
{
    static const int imm_words[8] = { 2, 2, 6, 6, 1, 4, 1, 6 };
    unsigned int w[6];
    int j, n;
    int dn_ok = (fm == 0 || fm == 1 || fm == 4 || fm == 6);
    sweep(0xF200u, EA_LC, N_EA_LC, 1, &cmd, LC_N, 1);
    if (dn_ok) sweep(0xF200u, EA_ALL, 2, 1, &cmd, LC_N, 1);            /* Dn */
    if (out) return;
    sweep_pc(0xF200u, 1, &cmd, LC_N, 1);
    if (2 + imm_words[fm] <= 6) {                                       /* #imm */
        memset(w, 0, sizeof w);
        n = 0;
        w[n++] = 0xF23Cu;
        w[n++] = cmd;
        for (j = 0; j < imm_words[fm]; j++) w[n++] = rnd() & 0xFFFFu;
        if (fm == 6) w[2] &= 0x00FFu;
        emitn(LC_N, n, w, 0, 1);
    }
}

static void g_lc040(void)
{
    static const unsigned int opm[4] = { 0x22, 0x00, 0x0E, 0x38 };  /* FADD FMOVE FSIN FCMP */
    unsigned int pre[1], w[6];
    int fm, i, c, l;

    /* Register to register, an unimplemented one among them, and FMOVECR. */
    for (i = 0; i < 4; i++) plain2(0xF200u, 0x0080u | (2u << 10) | opm[i], LC_N, 1);
    plain2(0xF200u, 0x5C00u | 0x32u, LC_N, 1);
    /* <ea>,FPn in every format; FMOVE FPn,<ea> in every one but packed with
     * a dynamic k factor. */
    for (fm = 0; fm < 7; fm++)
        for (i = 0; i < 4; i += (fm == 3) ? 1 : 2)
            lc_gen(0x4000u | (unsigned)(fm << 10) | (3u << 7) | opm[i], fm, 0);
    for (fm = 0; fm < 7; fm++)
        lc_gen(0x6000u | (unsigned)(fm << 10) | (1u << 7) | ((fm == 3) ? 0x7Eu : 0u), fm, 1);
    /* The control registers: one (Dn; An for FPIAR alone), or several. */
    for (l = 1; l < 8; l++)
        for (i = 0; i < 2; i++) {
            pre[0] = (i ? 0xA000u : 0x8000u) | (unsigned)(l << 10);
            sweep(0xF200u, EA_LC, 8, 1, pre, LC_N, 1);
            if (l == 1 || l == 2 || l == 4) sweep(0xF200u, EA_ALL, 1, 1, pre, LC_N, 1);
            if (l == 1) sweep(0xF208u, EA_ALL, 1, 1, pre, LC_N, 1);     /* An */
            if (!i && (l & 1) + ((l >> 1) & 1) + ((l >> 2) & 1) <= 2) {  /* six words */
                memset(w, 0, sizeof w);
                w[0] = 0xF23Cu; w[1] = pre[0];
                for (c = 0; c < 2 * ((l & 1) + ((l >> 1) & 1) + ((l >> 2) & 1)); c++)
                    w[2 + c] = rnd() & 0xFFFFu;
                emitn(LC_N, 2 + c, w, 0, 1);
            }
        }
    /* FMOVEM of FP0-FP7, static and dynamic: to -(An) or a control mode,
     * from (An)+ or one. */
    for (i = 0; i < 2; i++) {
        pre[0] = 0xE000u | (unsigned)(i << 11) | (i ? 0x0010u : 0x00F1u);   /* -(An) */
        sweep(0xF200u, &EA_LC[2], 1, 1, pre, LC_N, 1);
        sweep(0xF200u, &EA_LC[4], 1, 1, pre, LC_N, 1);
        pre[0] = 0xF000u | (unsigned)(i << 11) | (i ? 0x0020u : 0x0F0Fu);   /* control */
        sweep(0xF200u, EA_CTL, N_EA_CTL, 1, pre, LC_N, 1);
        pre[0] = 0xD000u | (unsigned)(i << 11) | (i ? 0x0030u : 0x8001u);   /* (An)+, control */
        sweep(0xF200u, &EA_LC[1], 1, 1, pre, LC_N, 1);
        sweep(0xF200u, EA_CTL, N_EA_CTL, 1, pre, LC_N, 1);
    }
    /* FScc, FTRAPcc (no operand, a word, a long word), FBcc (a word, a long
     * word displacement): the predicate does not matter, nothing evaluates it. */
    for (c = 0; c < 32; c += 7) {
        pre[0] = (unsigned)c;
        sweep(0xF240u, EA_LC, N_EA_LC, 1, pre, LC_N, 1);
        sweep(0xF240u, EA_ALL, 1, 1, pre, LC_N, 1);
        plain2(0xF27Cu, (unsigned)c, LC_N, 1);
        memset(w, 0, sizeof w);
        w[0] = 0xF27Au; w[1] = (unsigned)c; w[2] = 0x1234u;
        emitn(LC_N, 3, w, 0, 1);
        w[0] = 0xF27Bu; w[3] = 0x5678u;
        emitn(LC_N, 4, w, 0, 1);
        plain2(0xF280u | (unsigned)c, 0x0010u, LC_N, 1);
        memset(w, 0, sizeof w);
        w[0] = 0xF2C0u | (unsigned)c; w[1] = 0x0000u; w[2] = 0x0020u;
        emitn(LC_N, 3, w, 0, 1);
    }
    plain2(0xF280u, 0x0000u, LC_N, 1);                                  /* FNOP */
    /* FSAVE to -(An) or a control mode, FRESTORE from (An)+ or one;
     * privileged. */
    sweep(0xF300u, &EA_LC[2], 1, 0, NULL, LC_N, 1);
    sweep(0xF300u, &EA_LC[4], 1, 0, NULL, LC_N, 1);
    sweep(0xF300u, EA_CTL, N_EA_CTL, 0, NULL, LC_N, 1);
    sweep(0xF340u, &EA_LC[1], 1, 0, NULL, LC_N, 1);
    sweep(0xF340u, &EA_LC[3], 1, 0, NULL, LC_N, 1);
    sweep(0xF340u, EA_CTL, N_EA_CTL, 0, NULL, LC_N, 1);
    /* In user mode: onto the supervisor stack -- and the privilege
     * violation for FSAVE and FRESTORE, which comes first. */
    user_mode(0xF200u, 0x0880u | 0x22u, 1);
    user_mode(0xF210u, 0x4800u | 0x22u, 1);
    user_mode(0xF21Au, 0x4400u, 1);
    user_mode(0xF240u, 0x0001u, 1);
    user_mode(0xF280u, 0x0000u, 1);
    user_mode(0xF310u, 0, 0);
    user_mode(0xF358u, 0, 0);
}

/* ------------------------------------------------------------------ */
/* The catalogue                                                       */
/* ------------------------------------------------------------------ */

struct group { const char *name; void (*build)(void); };

static const struct group GROUPS[] = {
    { "move",    g_move    },
    { "moveq",   g_moveq   },
    { "unary",   g_unary   },
    { "misc",    g_misc    },
    { "addr",    g_addr    },
    { "alu",     g_alu     },
    { "imm",     g_imm     },
    { "extend",  g_extend  },
    { "shift",   g_shift   },
    { "bit",     g_bit     },
    { "cond",    g_cond    },
    { "jump",    g_jump    },
    { "muldiv",  g_muldiv  },
    { "bcd",     g_bcd     },
    { "packunpk",g_packunpk},
    { "packunpk_mem", g_packunpk_mem },
    { "bitfield",g_bitfield},
    { "bitfield_mem", g_bitfield_mem },
    { "moves",   g_moves   },
    { "tas",     g_tas     },
    { "cas",     g_cas     },
    { "cmp2",    g_cmp2    },
    { "movem",   g_movem   },
    { "movep",   g_movep   },
    { "ccr",     g_ccr     },
    { "chk",     g_chk     },
    { "movec",   g_movec   },
    { "traps",   g_traps   },
    { "trace",   g_trace   },
    { "ea",      g_ea      },
    { "cinv_cpush", g_cinv_cpush },
    { "pmmu040", g_pmmu040 },
    { "lc040",   g_lc040   },     /* -L only */
};
#define NGROUPS ((int)(sizeof GROUPS / sizeof GROUPS[0]))

/* The program area after the instruction: ILLEGAL, on both sides, so that a
 * memory-indirect mode or a PC-relative read of the instruction stream reads
 * the same thing in the core's memory as in the oracle's, and so that a core
 * that ran on past the instruction would stop. */
#define PROG_FILL  0x40
#define PROG_PAD   0x4AFC

struct acc {
    unsigned int addr, rw, bytes, fc, value, mask;
};

enum { KEEP = 0, DROP_ROOM, DROP_HALT, DROP_BUSERR, NDROP };
static const char *const DROP_WHY[NDROP] = {
    "", "more accesses than there is room to record", "the oracle halted",
    "a bus or address error (an access error frame, M10)",
};

struct result {
    int          why;
    int          exc;          /* the first exception vector taken, or -1 */
    unsigned int d[8], a[7], usp, isp, sr, pc;
    unsigned int msp, vbr, sfc, dfc, cacr;
    unsigned int mmu[8];
    unsigned int srmask;
    int          nacc;
    struct acc   acc[MAXACC];
};

static struct result *res;      /* shared with the child that runs the oracle */
static volatile int  *progress; /* the test the child is on */

/* ------------------------------------------------------------------ */
/* Running the oracle                                                  */
/* ------------------------------------------------------------------ */

static int          base_idx;   /* the child's first test */
static int          cur;        /* the test being run */
static int          recording;
static int          overflowed;
static int          berr_seen;
static int          nexc;           /* exceptions this test, and where each began */
static int          exc_vec[4], exc_at[4];

static void wr8(unsigned int a, unsigned int v)  { uae040_ram()[a & (MEMSIZE - 1)] = (uint8_t)v; }
static void wr16(unsigned int a, unsigned int v) { wr8(a, v >> 8); wr8(a + 1, v); }
static void wr32(unsigned int a, unsigned int v) { wr16(a, v >> 16); wr16(a + 2, v & 0xFFFF); }

static void on_op(uint32_t la, uint32_t pa, int size, int write, uint32_t data, int fc,
                  int berr, void *u)
{
    struct result *r = &res[cur];
    struct acc *a;
    (void)la; (void)u;
    if (!recording) return;
    if (berr) berr_seen = 1;
    if (r->nacc >= MAXACC) { overflowed = 1; return; }
    a = &r->acc[r->nacc++];
    a->addr  = pa;
    a->rw    = !write;
    a->bytes = (unsigned)size;
    a->fc    = (unsigned)fc;
    a->value = write ? data : 0;
    a->mask  = 0xFFFFFFFFu;
}

/* VEC_DEBUG=<index> prints every bus access the oracle makes for that test,
 * instruction fetches included, on stderr -- for triage. */
static int debug_idx = -1;

static void on_bus(const uae040_bus *b, void *u)
{
    (void)u;
    if (cur != debug_idx || !recording) return;
    fprintf(stderr, "  bus %c %08x %d %0*x fc=%d kind=%d%s\n", b->write ? 'W' : 'R', b->pa,
            b->size, b->size * 2, b->data, b->fc, b->kind, b->berr ? " BERR" : "");
}

static void on_exc(int vector, void *u)
{
    (void)u;
    if (cur == debug_idx && recording) fprintf(stderr, "  exception %d\n", vector);
    if (recording && res[cur].exc < 0) res[cur].exc = vector;
    if (recording && nexc < 4) {
        exc_vec[nexc] = vector;
        exc_at[nexc]  = res[cur].nacc;
        nexc++;
    }
}

static void setup(int i, uae040_state *st, void *u)
{
    struct test *t;
    int j;
    (void)u;
    cur = base_idx + i;
    *progress = cur;
    t = &tests[cur];

    memset(uae040_ram(), 0, MEMSIZE);
    /* Each exception vector points somewhere DIFFERENT, so that an
     * instruction which trapped through the wrong one shows as a wrong
     * program counter rather than as nothing at all. */
    for (j = 0; j < 256; j++)
        wr32((unsigned)j * 4, 0x00009000u + (unsigned)j * 4);
    wr32(0, STACK);
    wr32(4, PROG_BASE);
    for (j = 0; j < DATA_SIZE; j += 4) {
        unsigned int fw = fill_word(cur, (unsigned)j);
        wr32(DATA_BASE + (unsigned)j, t->bcdfill == 1 ? bcd_word(fw)
                                    : t->bcdfill == 2 ? 0x00003000u + (unsigned)j : fw);
    }
    for (j = 0; j < PROG_FILL; j += 2)
        wr16(PROG_BASE + (unsigned)j, PROG_PAD);
    for (j = 0; j < t->nwords; j++)
        wr16(PROG_BASE + (unsigned)j * 2, t->w[j]);
    for (j = 0; j < t->npoke; j++)
        wr32(t->poke_a[j], t->poke_v[j]);

    for (j = 0; j < 8; j++) st->d[j] = t->d[j];
    for (j = 0; j < 7; j++) st->a[j] = t->a[j];
    st->usp  = t->usp;
    st->isp  = t->isp;
    st->msp  = t->imsp;
    st->sr   = (uint16_t)t->sr;
    st->sfc  = t->isfc;
    st->dfc  = t->idfc;
    st->vbr  = t->ivbr;
    st->cacr = t->icacr;
    st->tc   = t->immu[0];
    st->itt0 = t->immu[1];
    st->itt1 = t->immu[2];
    st->dtt0 = t->immu[3];
    st->dtt1 = t->immu[4];
    st->mmusr = t->immu[5];
    st->urp  = t->immu[6];
    st->srp  = t->immu[7];
    st->pc   = PROG_BASE;
    uae040_set_mmu(st);           /* (uae040_set_state leaves them alone) */

    res[cur].nacc = 0;
    res[cur].exc  = -1;
    overflowed = 0;
    berr_seen  = 0;
    nexc       = 0;
    recording  = 1;
}

/* PRM 4's undefined condition codes, decided after the run because two of
 * them depend on what happened: a divide only leaves N and Z undefined when
 * it overflowed, and N, Z and V when the divisor was zero. */
static unsigned int undefined_ccr(const struct test *t, unsigned int sr_after, int exc)
{
    unsigned int op = t->w[0], m = 0xFFFFu;
    int is_abcd = ((op & 0xF1F0u) == 0xC100u)     /* ABCD */
               || ((op & 0xF1F0u) == 0x8100u)     /* SBCD */
               || ((op & 0xFFC0u) == 0x4800u);    /* NBCD */
    int is_divw = ((op & 0xF0C0u) == 0x80C0u)     /* DIVU.W, DIVS.W */
               && ((op & 0x01C0u) == 0x00C0u || (op & 0x01C0u) == 0x01C0u);
    int is_divl = ((op & 0xFFC0u) == 0x4C40u);    /* DIVU.L, DIVS.L */
    int is_chk  = ((op & 0xF040u) == 0x4000u)
               && (((op >> 6) & 7) == 6 || ((op >> 6) & 7) == 4)
               && ((op & 0xF000u) == 0x4000u) && ((op & 0x0100u) != 0);
    if (is_abcd)                                  m &= ~0x000Au;  /* N and V   */
    if ((is_divw || is_divl) && exc == 5)         m &= ~0x000Eu;  /* N, Z, V   */
    else if ((is_divw || is_divl) && (sr_after & 2)) m &= ~0x000Cu; /* N and Z */
    if (is_chk)                                   m &= ~0x000Fu;  /* N Z V C   */
    /* CMP2 and CHK2: "N -- undefined. V -- undefined." */
    if ((op & 0xF9C0u) == 0x00C0u && (op & 0x0600u) != 0x0600u
        && ((t->w[1] & 0x07FFu) == 0))           m &= ~0x000Au;
    return m;
}

/* Where the oracle's order of accesses differs from the order the manual
 * gives, the manual's is recorded (doc/oracles.md, "Quirks"). Each case is
 * narrow, and each moves accesses the oracle made; none invents one. */
static void move_acc(struct result *r, int from, int to)
{
    struct acc a = r->acc[from];
    int j;
    if (from < to) for (j = from; j < to; j++) r->acc[j] = r->acc[j + 1];
    else           for (j = from; j > to; j--) r->acc[j] = r->acc[j - 1];
    r->acc[to] = a;
}

/* RD68031's normalisations of UAE030 were each checked against the MC68030's
 * manual; those doc/oracles.md has confirmed for UAE040 against the MC68040's
 * are carried over: the vector read's place (UM 8.1), and, since M8, the
 * format $2 frame's instruction address (UM 8.4.3). The rest (RTE's
 * frame-format check order, the bit-field and PACK/UNPK access shapes, the
 * divide's C on overflow) are decided by the sweeps' own findings. */
static void normalise(const struct test *t, struct result *r, const uae040_state *s)
{
    int e, j, end, vbr;
    /* UM 8.1: the third step of exception processing builds the stack frame,
     * the last fetches the vector. The oracle fetches the vector first. Within
     * each exception's run of accesses, the vector read goes after the frame. */
    for (e = 0; e < nexc; e++) {
        int at = exc_at[e];
        end = (e + 1 < nexc) ? exc_at[e + 1] : r->nacc;
        for (vbr = 0; vbr < 2; vbr++) {
            unsigned int va = (vbr ? s->vbr : t->ivbr) + 4u * (unsigned)exc_vec[e];
            if (at < end && r->acc[at].rw && r->acc[at].bytes == 4 && r->acc[at].addr == va) {
                for (j = at + 1; j < end && !r->acc[j].rw; j++) ;
                move_acc(r, at, j - 1);
                break;
            }
        }
    }
    /* UM 8.4.3: the six-word frame of CHK, CHK2, TRAPcc, TRAPV, trace and the
     * zero divide holds "the address of the instruction that caused the
     * exception" at +$08. UAE040 stacks the next instruction's there, the
     * same as the PC; the cputest corpus (WinUAE's copy of the core, checked
     * against real processors) stacks the instruction's, as the manual says
     * (doc/oracles.md). Every test's instruction is at PROG_BASE. */
    if (nexc == 1 && (exc_vec[0] == 5 || exc_vec[0] == 6 || exc_vec[0] == 7 || exc_vec[0] == 9)) {
        unsigned int sp = (s->sr & 0x1000u) ? s->msp : s->isp;
        for (j = 0; j < r->nacc; j++)
            if (!r->acc[j].rw && r->acc[j].bytes == 4 && r->acc[j].addr == sp + 8u)
                r->acc[j].value = PROG_BASE;
    }
}

static void result(int i, const uae040_state *s, void *u)
{
    struct test *t = &tests[base_idx + i];
    struct result *r = &res[base_idx + i];
    int j;
    (void)u;
    recording = 0;
    /* An odd PC after the instruction: the address error (UM 8.2.2) is taken
     * at the next instruction's fetch; either way an access-error-class frame. */
    r->why = overflowed ? DROP_ROOM
           : (berr_seen || r->exc == 2 || r->exc == 3 || (s->pc & 1u)) ? DROP_BUSERR : KEEP;
    for (j = 0; j < 8; j++) r->d[j] = s->d[j];
    for (j = 0; j < 7; j++) r->a[j] = s->a[j];
    r->usp  = s->usp;
    r->isp  = s->isp;
    r->sr   = s->sr;
    r->pc   = s->pc;
    r->msp  = s->msp;
    r->vbr  = s->vbr;
    r->sfc  = s->sfc;
    r->dfc  = s->dfc;
    r->cacr = s->cacr;
    r->mmu[0] = s->tc;   r->mmu[1] = s->itt0;  r->mmu[2] = s->itt1; r->mmu[3] = s->dtt0;
    r->mmu[4] = s->dtt1; r->mmu[5] = s->mmusr; r->mmu[6] = s->urp;  r->mmu[7] = s->srp;
    r->srmask = undefined_ccr(t, s->sr, r->exc);
    normalise(t, r, s);
    /* The status register an exception stacked, at the bottom of the frame
     * (UM 8.4: SR, then the PC, then the format word), carries the same
     * undefined codes the instruction left. */
    if (r->exc >= 0 && r->srmask != 0xFFFFu) {
        unsigned int sp = (s->sr & 0x1000u) ? s->msp : s->isp;
        for (j = 0; j < r->nacc; j++)
            if (!r->acc[j].rw && r->acc[j].bytes == 2 && r->acc[j].addr == sp)
                r->acc[j].mask = r->srmask;
    }
}

/* Run tests [first, ntests) in a child process, so that a test which halts the
 * oracle costs that test and not the run. Returns the index the child stopped
 * at, or ntests when it finished. */
static int run_child(int first)
{
    pid_t pid;
    int status;
    fflush(stdout);
    fflush(stderr);
    pid = fork();
    if (pid < 0) { perror("fork"); exit(1); }
    if (pid == 0) {
        int done, j;
        /* The data cache off: CACR is zero in every test anyway (UM 4.2). */
        uae040_init(MEMSIZE, 0, !lc);
        uae040_set_alias(ALIAS);
        wr32(0, STACK);
        wr32(4, PROG_BASE);
        for (j = 0; j < PROG_FILL; j += 2) wr16(PROG_BASE + (unsigned)j, PROG_PAD);
        uae040_set_op_hook(on_op);
        uae040_set_exc_hook(on_exc);
        base_idx = first;
        if (getenv("VEC_DEBUG")) {
            debug_idx = (int)strtol(getenv("VEC_DEBUG"), NULL, 0);
            uae040_set_hooks(NULL, on_bus, NULL);
        }
        if (uae040_run_each(ntests - first, setup, result, NULL, &done))
            _exit(3);
        _exit(0);
    }
    if (waitpid(pid, &status, 0) < 0) { perror("waitpid"); exit(1); }
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return ntests;
    if (WIFEXITED(status) && WEXITSTATUS(status) == 3) return *progress;
    fprintf(stderr, "vectors: the oracle process died at test %d (status %x)\n",
            *progress, status);
    return *progress;
}

int main(int argc, char **argv)
{
    int i, j, first;
    long kept = 0, dropped[NDROP] = { 0 };
    struct test *t;
    struct result *r;

    tests = calloc(MAXTESTS, sizeof *tests);
    if (!tests) { fprintf(stderr, "vectors: out of memory\n"); return 1; }

    if (argc >= 2 && !strcmp(argv[1], "list")) {
        for (i = 0; i < NGROUPS; i++) printf("%s\n", GROUPS[i].name);
        return 0;
    }
    if (argc >= 2 && !strcmp(argv[1], "-L")) {
        lc = 1;
        argv++;
        argc--;
    }
    rng_state = 0x13572468u;
    if (argc < 2 || !strcmp(argv[1], "all")) {
        for (i = 0; i < NGROUPS; i++)
            if (lc || GROUPS[i].build != g_lc040) { cur_group = i; GROUPS[i].build(); }
    } else {
        for (j = 1; j < argc; j++) {
            for (i = 0; i < NGROUPS; i++)
                if (!strcmp(argv[j], GROUPS[i].name)) {
                    if (GROUPS[i].build == g_lc040 && !lc) {
                        fprintf(stderr, "vectors: lc040 is an MC68LC040's group: -L\n");
                        return 1;
                    }
                    cur_group = i; GROUPS[i].build(); break;
                }
            if (i == NGROUPS) {
                fprintf(stderr, "vectors: no group %s. There is:", argv[j]);
                for (i = 0; i < NGROUPS; i++) fprintf(stderr, " %s", GROUPS[i].name);
                fprintf(stderr, "\n");
                return 1;
            }
        }
    }

    res = mmap(NULL, (size_t)ntests * sizeof *res + 64, PROT_READ | PROT_WRITE,
               MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (res == MAP_FAILED) { perror("mmap"); return 1; }
    progress = (volatile int *)(res + ntests);

    for (first = 0; first < ntests; ) {
        int stop = run_child(first);
        if (stop >= ntests) break;
        res[stop].why = DROP_HALT;
        first = stop + 1;
    }

    for (i = 0; i < ntests; i++) {
        if (res[i].why == KEEP) kept++;
        else dropped[res[i].why]++;
    }
    fprintf(stderr, "vectors: %ld tests", kept);
    for (i = 1; i < NDROP; i++)
        if (dropped[i]) fprintf(stderr, "; %ld dropped for %s", dropped[i], DROP_WHY[i]);
    fprintf(stderr, "\n");
    if (kept == 0) { fprintf(stderr, "vectors: nothing to test\n"); return 1; }

    printf("%lx %x\n", kept, NGROUPS);
    for (i = 0; i < NGROUPS; i++) printf("%s\n", GROUPS[i].name);
    for (i = 0; i < ntests; i++) {
        t = &tests[i];
        r = &res[i];
        if (r->why != KEEP) continue;
        printf("%x %x %x", i, t->group, t->nwords);
        for (j = 0; j < 6; j++) printf(" %x", t->w[j]);
        printf("\n");
        for (j = 0; j < 8; j++) printf("%x ", t->d[j]);
        for (j = 0; j < 7; j++) printf("%x ", t->a[j]);
        printf("%x %x %x %x %x %x %x %x\n", t->usp, t->isp, t->sr,
               t->imsp, t->isfc, t->idfc, t->ivbr, t->icacr);
        for (j = 0; j < 8; j++) printf("%x%s", t->immu[j], j == 7 ? "\n" : " ");
        printf("%x", t->npoke);
        for (j = 0; j < t->npoke; j++) printf(" %x %x", t->poke_a[j], t->poke_v[j]);
        printf(" %x %x %x\n", r->srmask & t->srmask, (unsigned)t->bcdfill,
               r->exc < 0 ? 0u : (unsigned)r->exc);
        for (j = 0; j < 8; j++) printf("%x ", r->d[j]);
        for (j = 0; j < 7; j++) printf("%x ", r->a[j]);
        printf("%x %x %x %x %x %x %x %x %x\n", r->usp, r->isp, r->sr, r->pc,
               r->msp, r->vbr, r->sfc, r->dfc, r->cacr);
        for (j = 0; j < 8; j++) printf("%x%s", r->mmu[j], j == 7 ? "\n" : " ");
        printf("%x", r->nacc);
        for (j = 0; j < r->nacc; j++)
            printf(" %x %x %x %x %x %x", r->acc[j].addr, r->acc[j].rw,
                   r->acc[j].bytes, r->acc[j].fc, r->acc[j].value, r->acc[j].mask);
        printf("\n");
    }
    return 0;
}
