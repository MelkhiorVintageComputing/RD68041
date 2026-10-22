| SPDX-License-Identifier: GPL-2.0-or-later
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68041
|
| M0 spike smoke test for the UAE040 oracle harness (RD68031's mmu_smoke.S,
| for an MC68040). Linked at 0, loaded at physical 0, run from reset (SSP and
| PC from vectors 0 and 1), supervisor mode throughout.
|
| Each L_<name> label is a landmark: tests/smoke040_check.py looks up the
| trace record at that PC (the state before the instruction there runs) and
| the bus and operand streams between landmarks, and compares them with what
| the MC68040 user's manual says (the expected values, with the UM section
| each comes from, are in the checker).
|
| Exercises: integer ops; MOVEC to and from the 040 control registers; the
| MMU on, with a 3-level table (4K pages) remapping one page, one invalid
| page faulted on (access error, vector 2, format $7) and fixed by the
| handler, then RTE; PTEST, PFLUSH, a DTTR; the data cache in copyback mode
| with CPUSHA and CINVA; MOVE16; FP arithmetic in double, FMOVEM, FSAVE and
| FRESTORE; and FSIN, unimplemented on the 040 (vector 11, format $2).
|
| Run with -L (an MC68LC040), every FP instruction takes vector 11 with a
| format $4 frame instead; the vector 11 handler tells the cases apart.
|
| Build: m68k-linux-gnu-gcc -mcpu=68040 -nostdlib -Wl,-Ttext=0 -o s.elf smoke040.S
|        m68k-linux-gnu-objcopy -O binary s.elf s.bin

	.text
	.globl	_start
vectors:
	.long	0x00008000		| 0: reset SSP
	.long	_start			| 1: reset PC
	.long	aerr			| 2: access error
	.rept	8
	.long	other			| 3..10
	.endr
	.long	fline			| 11: line F / unimplemented FP
	.rept	244
	.long	other			| 12..255
	.endr

	.org	0x400
_start:
	| --- integer -----------------------------------------------------
	moveq	#5,%d0
	moveq	#7,%d1
	add.l	%d0,%d1			| 12
	mulu.w	#3,%d1			| 36
	move.l	#0x12345678,%d2
	swap	%d2			| 0x56781234
	divu.w	#7,%d1			| 36 / 7: q 5 r 1 -> 0x00010005
	bfextu	%d2{#4:#8},%d3		| 0x67
	moveq	#0,%d7			| access error count
	sub.l	%a6,%a6			| format $4 (LC040) count
L_int:
	| --- MOVEC, the 040 control registers ----------------------------
	move.l	#0xffffffff,%d0
	movec	%d0,%cacr
	movec	%cacr,%d4		| implemented bits: DE (31), IE (15)
	moveq	#0,%d0
	movec	%d0,%cacr
	move.l	#0xffffffff,%d0
	movec	%d0,%itt0
	movec	%itt0,%d5		| bits 12-10, 7, 4, 3, 1, 0 read as zero
	moveq	#0,%d0
	movec	%d0,%itt0
	move.l	#0x00007fff,%d0		| E clear, P set: no translation
	movec	%d0,%tc
	movec	%tc,%d6			| bits 13-0 read as zero
	moveq	#0,%d0
	movec	%d0,%tc
	move.l	#0x00007000,%d0
	movec	%d0,%msp
	movec	%msp,%a1
	movec	%isp,%a2		| ISP is the active stack (M clear)
	moveq	#5,%d0
	movec	%d0,%sfc
	movec	%d0,%dfc
	moveq	#0,%d0
	movec	%d0,%vbr
L_movec:
	| --- the MMU on ---------------------------------------------------
	lea	tblroot,%a0
	movec	%a0,%urp
	movec	%a0,%srp
	pflusha
	move.l	#0x00008000,%d0		| E, 4K pages
	movec	%d0,%tc
L_mmu_on:
	move.l	0x20000,%d0		| LA $20000 -> PA $30000
L_remap:
	move.l	0x20000,%d1		| ATC hit, no table search
L_atc:
	| --- a page fault: LA $21000 is invalid; the handler maps it --------
	move.l	0x21000,%d1		| access error, fixed, RTE restarts
L_fault:
	| --- PTEST ---------------------------------------------------------
	lea	0x20000,%a0
	ptestr	(%a0)
	movec	%mmusr,%d2		| resident, PA $30000
	lea	0x25000,%a0
	ptestr	(%a0)
	movec	%mmusr,%d3		| invalid page: R clear
	lea	0x20000,%a0
	ptestw	(%a0)
	movec	%mmusr,%d4		| a write search sets M
L_ptest:
	| --- PFLUSH --------------------------------------------------------
	move.l	0x20000,%d0		| ATC hit (PTESTW left the entry)
	lea	0x20000,%a0
	pflush	(%a0)
	move.l	0x20000,%d0		| searched again
L_pflush:
	| --- a data TTR over $00xxxxxx: no translation, cache inhibited ---
	move.l	#0x0000c040,%d0		| base $00 mask $00, E, S ignored, CM 10
	movec	%d0,%dtt0
	move.l	0x20000,%d4		| PA $20000 now, not $30000
	lea	0x20000,%a0
	ptestr	(%a0)
	movec	%mmusr,%d5		| T and R
	moveq	#0,%d0
	movec	%d0,%dtt0
L_ttr:
	| --- the data cache, copyback ---------------------------------------
	move.l	#0x80008000,%d0		| DE, IE
	movec	%d0,%cacr
	cinva	%bc
	lea	0x22000,%a0		| a copyback page
	move.l	#0xcafef00d,(%a0)	| miss: line allocated, no write on the bus
	move.l	(%a0),%d1		| hit
L_cb1:
	cpusha	%dc			| the dirty line is pushed
L_cb2:
	move.l	#0x11112222,(%a0)	| dirty again
	cinva	%dc			| invalidated without a push: the write is lost
	move.l	(%a0),%d2		| $cafef00d from memory
L_cb3:
	lea	0x23000,%a1		| a write-through page
	move.l	#0x33334444,(%a1)	| written on the bus
L_wt:
	cpusha	%bc
	moveq	#0,%d0
	movec	%d0,%cacr
	| --- MOVE16 --------------------------------------------------------
	lea	0x24000,%a0
	lea	0x24100,%a1
	move16	(%a0)+,(%a1)+
	move.l	0x24100,%d3
	move.l	0x2410c,%d4
L_move16:
	| --- FP --------------------------------------------------------------
	fmove.d	#0r1.5,%fp0
	fadd.d	#0r2.25,%fp0		| 3.75
	fmove.x	%fp0,%fp1
	fmul.d	#0r2.0,%fp1		| 7.5
	fmove.x	%fp1,%fp2
	fdiv.d	#0r3.0,%fp2		| 2.5
L_fsqrt_insn:
	fsqrt.d	#0r6.25,%fp3		| 2.5
L_fp:
	fmovem.x %fp0-%fp3,-(%sp)
	fmove.l	#0,%fp0
	fmove.l	#0,%fp1
	fmove.l	#0,%fp2
	fmove.l	#0,%fp3
	fmovem.x (%sp)+,%fp0-%fp3
L_fpm:
	fsave	-(%sp)
	move.l	(%sp),%d5		| an idle frame: version $41, size $00
	frestore (%sp)+
L_fsave:
	moveq	#0,%d6
	sub.l	%a2,%a2
	sub.l	%a3,%a3
L_fsin_insn:
	fsin.x	%fp0,%fp4		| unimplemented: vector 11, format $2
L_fsin:
	| --- MMU off -----------------------------------------------------
	moveq	#0,%d0
	movec	%d0,%tc
	pflusha
L_end:
done:
	bra.s	done

| Access error (vector 2): a format $7 frame. Record it, map the page, RTE.
aerr:
	move.w	6(%sp),%d5		| format / vector offset
	move.w	12(%sp),%d6		| SSW
	move.l	20(%sp),%a4		| FA
	move.l	8(%sp),%a3		| EA
	addq.l	#1,%d7
	move.l	#0x00031001,pg21	| resident, PA $31000
	pflush	(%a4)			| DFC = 5: the supervisor data entry
	rte

| Vector 11. Format $2: an unimplemented FP instruction (the PC is the next
| instruction's); record the frame and the FPU state frame, and go on.
| Format $4 (MC68LC040): any FP instruction; count it and go on. Format $0:
| an F-line illegal instruction, which this program does not contain.
fline:
	move.w	6(%sp),%d0
	and.w	#0xf000,%d0
	cmp.w	#0x4000,%d0
	beq.s	1f
	cmp.w	#0x2000,%d0
	bne.s	other
	move.w	6(%sp),%d6		| format / vector offset
	move.l	2(%sp),%a2		| PC
	move.l	8(%sp),%a3		| address
	fsave	-(%sp)
	move.l	(%sp),%d4		| an unimplemented-instruction frame
	frestore (%sp)+
	rte
1:	addq.l	#1,%a6
	rte

other:
	move.w	6(%sp),%d0
other_end:
	bra.s	other_end

	.align	4
	| --- the translation tables (UM 3.2.1) ------------------------------
	.org	0x10000
tblroot:				| 128 root descriptors, 32 MB each
	.long	tblptr + 2		| resident (UDT 10)
	.rept	127
	.long	0
	.endr
	.org	0x10200
tblptr:					| 128 pointer descriptors, 256 KB each
	.long	tblpg + 2
	.rept	127
	.long	0
	.endr
	.org	0x10400
tblpg:					| 64 page descriptors, 4 KB each
	.set	pg,0
	.rept	64
	.if	pg == 0x20
	.long	0x00030000 + 1		| LA $20000 -> PA $30000
	.elseif	pg == 0x21
pg21:	.long	0			| invalid until the handler maps it
	.elseif	pg == 0x22
	.long	0x00022000 + 0x20 + 1	| identity, CM 01 copyback
	.elseif	pg == 0x25
	.long	0			| invalid
	.else
	.long	(pg << 12) + 1		| identity, CM 00 write-through
	.endif
	.set	pg,pg+1
	.endr

	| --- data ----------------------------------------------------------
	.org	0x20000
	.long	0xa5a5a5a5		| seen through the DTTR only
	.org	0x24000
	.long	0x01234567, 0x89abcdef, 0xfedcba98, 0x76543210
	.org	0x30000
	.long	0x13579bdf		| LA $20000's page
	.org	0x31000
	.long	0x2468ace0		| LA $21000's page, once mapped
	.long	0
