# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041

# RD68041 -- SystemVerilog MC68040 / MC68LC040
#
# Targets arrive as the milestones that need them do. `make help` lists what exists.
#
# The three always-available front-ends -- iverilog, Verilator, yosys -- are what
# `make lint` runs and what the RTL is written against day to day. Vivado, Quartus
# and Questa each have their own target and none of them is in `make check`, which
# has to work on a machine with no vendor tools installed.

SHELL := /bin/bash

TOP   ?= rd68041_top
BUILD ?= build

# Overridable build knobs, all documented where they are used.
# FPU=1 is the MC68040, FPU=0 the MC68LC040 (rtl/rd68041_top.sv).
FPU ?= 1

# Vendor tool locations. Neither is on PATH; the launchers in scripts/ set it up.
VIVADO_SETTINGS ?= /opt/Xilinx/2025.2/Vivado/settings64.sh
QUARTUS_ROOTDIR ?= /opt/Altera/quartus
QUESTA_ROOTDIR  ?= /opt/Altera/questa_fse
XPART           ?= xc7a100tcsg324-1
AFAMILY         ?= "Cyclone V"
APART           ?= 5CSEMA5F31C6

CROSS ?= m68k-linux-gnu-

# ---------------------------------------------------------------------------
# The file list. Packages first -- Vivado, Questa and iverilog need one read
# before its users. The generated files (from M5) are split the same way.
# ---------------------------------------------------------------------------
PKGS    := rtl/rd68041_pkg.sv rtl/rd68041_fpu_pkg.sv
GENPKG  := $(wildcard rtl/gen/*_pkg.sv)
GENSRC  := $(filter-out $(GENPKG),$(wildcard rtl/gen/*.sv))
SRCS := rtl/rd68041_sync.sv \
        rtl/rd68041_late_release.sv \
        rtl/rd68041_rstctl.sv \
        rtl/rd68041_snoop.sv \
        rtl/rd68041_biu.sv \
        rtl/rd68041_bram.sv \
        rtl/rd68041_atc.sv \
        rtl/rd68041_cache_arr.sv \
        rtl/rd68041_regfile.sv \
        rtl/rd68041_attr.sv \
        rtl/rd68041_agu.sv \
        rtl/rd68041_decode.sv \
        rtl/rd68041_ifu.sv \
        rtl/rd68041_dmu.sv \
        rtl/rd68041_exc.sv \
        rtl/rd68041_core.sv \
        rtl/rd68041_shifter.sv \
        rtl/rd68041_divider.sv \
        rtl/rd68041_bitfield.sv \
        rtl/rd68041_fpu_dp.sv \
        rtl/rd68041_fpu.sv \
        rtl/rd68041_top.sv

RTL  := $(PKGS) $(GENPKG) $(GENSRC) $(SRCS)
VLT  := rtl/rd68041.vlt

# TB_NOFPU: the benches leave out what reaches into the FPU, which FPU=0 does not build.
IVFLAGS := -g2012 -Wall -Wno-timescale -DTB_FPU=$(FPU) $(if $(filter 0,$(FPU)),-DTB_NOFPU)

.PHONY: all help dirs lint lint-source lint-iverilog lint-verilator lint-yosys \
        lint-quartus lint-questa quartus synth impl audit sim sim-bus check \
        check-lc cosim spike ucode ucode-check print-rtl clean uae040 uae040-smoke cputest-gen \
        qemu040 cosim-qemu-smoke virt-qemu mame-quadra quadra-m68040 \
        qvirt qvirt-bare qvirt-linux qvirt-linux-qemu netbsd-disk netbsd-qemu netbsd-qvirt \
        virt-bare virt-uae virt-linux virt-linux-solo fpsp quadra quadra-lc

all: lint

help:
	@echo "RD68041 -- SystemVerilog MC68040 / MC68LC040"
	@echo
	@echo "The gate:"
	@echo "  make check       lint, audit, sim and timing, then lint and audit again with FPU=0"
	@echo "  make ucode       regenerate rtl/gen/ and doc/checkpoint.md's tables (tools/ucode/)"
	@echo "  make ucode-check ... or check they are up to date"
	@echo "  make lint        elaborate every rtl module under iverilog, Verilator and yosys"
	@echo "  make audit       prove no register initialises outside reset"
	@echo "  make sim         the directed testbenches"
	@echo "  make sim-bus     ... just the bus-level ones"
	@echo "  make timing      AC feasibility: MC68040 25/33/40 MHz (large, small buffers),"
	@echo "                   MC68LC040 20/25/33/40 MHz (doc/ac-timing.md)"
	@echo "  make timing-verbose  ... and every column in detail; PADSKEW=, TIMOPTS=--tie-edges"
	@echo
	@echo "Vendor tools, tens of minutes each:"
	@echo "  make impl         Vivado place and route ($(XPART)), out of context"
	@echo "  make synth        Vivado synthesis only"
	@echo "  make spike        the M4 frequency spike, placed and routed (sim/spike/)"
	@echo "  make quartus      Quartus fit and timing ($(AFAMILY) $(APART))"
	@echo "  make lint-quartus Quartus analysis and synthesis"
	@echo "  make lint-questa  Questa vlog + vopt"
	@echo
	@echo "The oracles (doc/oracles.md), minutes each, not in check:"
	@echo "  make uae040       build the UAE040 oracle and uae040_trace (build/uae040/)"
	@echo "  make uae040-smoke run tools/cosim/uae040/tests/smoke040.S on it, as an MC68040 and"
	@echo "                    an MC68LC040, and check it against the manual"
	@echo "  make cputest-gen  WinUAE's cputest corpus for the MC68040, integer and FPU"
	@echo "                    (build/cputest/), decoded and counted"
	@echo "  make vectors      the per-opcode sweep on the core against UAE040 (OP=alu,shift ...;"
	@echo "                    default OP=$(VECGROUPS)); passed / failed / not built / pending"
	@echo "  make vectors-all  ... every group"
	@echo "  make ea           ... the addressing-mode sweep (OP=ea)"
	@echo "  make smp          two processors behind UM 7.8.2.1's arbiter, corrected: core_smp_tb's"
	@echo "                    variants, and its checks shown to catch a broken board (doc/smp.md)"
	@echo "  make cycles       integer instruction timings (BCLK) against UM section 10, the"
	@echo "                    table in doc/timing-divergences.md (build/cycles/cycles.md)"
	@echo "  make cache        the caches against the oracles: their cosims, vectors-all and"
	@echo "                    cputest with the caches on (CACHE=1 write-through, 2 copyback),"
	@echo "                    and core_mmu_tb with them on"
	@echo "  make cosim-mmu    the MMU against UAE040: m10_mmu, and the pmmu040 vectors"
	@echo "  make cosim-lc     the MC68LC040 (FPU=0) against UAE040 -L: the integer programs and"
	@echo "                    m12_lc040; make vectors OP=lc040 FPU=0 its format \$$4 vectors"
	@echo "  make cputest      the integer cputest corpus on the core (CPUTEST_SEL=ADD,MOVE.L"
	@echo "                    CPUTEST_MAX=$(CPUTEST_MAX))"
	@echo "  make qemu040      build QEMU (m68k-softmmu, build/qemu/) and the qemu040 trace plugin"
	@echo "  make cosim-qemu-smoke  smoke040.S on QEMU's m68040, its trace compared with"
	@echo "                    UAE040's; every known difference confirmed"
	@echo "  make virt-qemu    Linux 7.2.9 (CONFIG_M68040) to a shell on QEMU's virt board,"
	@echo "                    a command set typed, powered off (guest build: heavy, alone)"
	@echo "rd-virt, the deterministic m68k virt machine (M13; heavy builds, run alone):"
	@echo "  make virt-uae       Linux to the shell and a command set on UAE040 alone"
	@echo "  make virt-bare      bare-metal programs (console, timer, MMU and caches), in lockstep"
	@echo "  make virt-linux-solo  Linux on the RTL alone"
	@echo "  make virt-linux     Linux in lockstep with UAE040 (VIRT_CACHES=off, VIRT_OPTS=...)"
	@echo "  make fpsp           Linux in lockstep, the M68040FPSP's emulated instructions"
	@echo "                    (each with FPU=0: the MC68LC040, its FPU emulation; not fpsp)"
	@echo "  make mame-quadra  build MAME's macquadra800.cpp driver (build/mame/; heavy, -j2, alone)"
	@echo "  make quadra        the core as the Quadra 650's MC68040 in MAME, booted from the"
	@echo "                    disk to MAME's m68040's last screen, the Finder (M14; over an"
	@echo "                    hour, alone); quadra-lc: the Centris 650, the MC68LC040"
	@echo "  make quadra-m68040  the user's Quadra 650 ROM and disk (QUADRA_DISK=) on MAME's"
	@echo "                    m68040 to the Finder (QUADRA_SECONDS=, QUADRA_MACHINE=)"
	@echo
	@echo "  make clean        remove build/"
	@echo
	@echo "Knobs: FPU=$(FPU) (1: MC68040, 0: MC68LC040)" \
	      "AFAMILY=$(AFAMILY) APART=$(APART)"

dirs:
	@mkdir -p $(BUILD)

# ---------------------------------------------------------------------------
# Lint -- the three that need no vendor installation
# ---------------------------------------------------------------------------
lint: lint-source lint-iverilog lint-verilator lint-yosys

# The two portability rules the three free front-ends do not enforce and the
# three vendor ones do -- declaration before use, and no package-scoped name in a
# port connection (doc/coding-standard.md).
lint-source:
	@python3 tools/src_lint.py $(filter-out $(PKGS) $(GENPKG),$(RTL))
	@echo "PASS: lint"

# Both of these run the tool into a log and decide from its exit status, rather
# than piping it through a filter: with pipefail, `tool | grep -v ... || test $$?
# -eq 1` reports "ok" for a failing tool (measured in RD68031, twice).
#
# iverilog prints a "sorry: ..." note for every unique case and for every variable
# part-select in an always_ block, and nothing can turn them off. They are notes,
# not diagnostics, so they are filtered out of what gets shown on a failure.
NOTES := ': sorry: .*\(ignored\|all bits will be included\)\.$$'

lint-iverilog: dirs
	@iverilog $(IVFLAGS) -P$(TOP).FPU=$(FPU) \
	    -o $(BUILD)/$(TOP).vvp -s $(TOP) $(RTL) \
	    > $(BUILD)/iverilog.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/iverilog.log; exit 1; }
	@echo "  iverilog: ok"

lint-verilator: dirs
	@verilator --lint-only -Wall --top-module $(TOP) -GFPU=$(FPU) \
	    $(VLT) $(RTL) \
	    > $(BUILD)/verilator.log 2>&1 \
	  || { grep -v '^- V e r i l a t i o n\|^- Verilator:' $(BUILD)/verilator.log; exit 1; }
	@echo "  verilator: ok"

# Run the full synth pass, not just read_verilog, so that anything unsynthesisable
# is caught here rather than in Vivado.
#
# yosys returns 0 on a warning, and two of its warnings are defects rather than
# noise: a register driven from two processes ("multiple conflicting drivers")
# and an inferred latch. Both are gates here, not the exit code.
lint-yosys: dirs
	@set -o pipefail; yosys -p "read_verilog -sv $(RTL); \
	    chparam -set FPU $(FPU) $(TOP); synth -top $(TOP); \
	    write_verilog $(BUILD)/$(TOP)_yosys.v" > $(BUILD)/yosys.log 2>&1 \
	  || { tail -40 $(BUILD)/yosys.log; exit 1; }
	@if grep -q 'multiple conflicting drivers\|Warning: Identifier .* is implicitly declared\|inferring latch' $(BUILD)/yosys.log; then \
	    echo "FAIL: yosys"; \
	    grep -n 'multiple conflicting drivers\|implicitly declared\|inferring latch' $(BUILD)/yosys.log | head -20; \
	    exit 1; fi
	@echo "  yosys: ok"

# ---------------------------------------------------------------------------
# The reset rule
# ---------------------------------------------------------------------------
audit: dirs
	@python3 tools/reset_audit.py --top $(TOP) --build $(BUILD) \
	    --param FPU=$(FPU) $(RTL)

# ---------------------------------------------------------------------------
# Generated files -- M5
# ---------------------------------------------------------------------------
# The generated files are committed, so a build needs no Python. ucode-check is
# the first thing `make check` runs, so they cannot drift from their source.
ucode: dirs
	@python3 tools/ucode/frames.py

ucode-check: dirs
	@python3 tools/ucode/frames.py --check

# ---------------------------------------------------------------------------
# Directed testbenches
#
# Each one runs to completion and prints PASS or FAIL. The loop fails on a FAIL
# and ALSO on a missing PASS: a testbench that stopped early without saying so is
# not a testbench that passed.
#
# They run SIMJOBS at a time (CLAUDE.md: light simulations, up to four in
# parallel). Each writes its one-line verdict to $(BUILD)/<tb>.simres; the
# verdicts are printed in TBS order once all have finished. A testbench that
# leaves no verdict -- killed, or crashed before writing one -- is a failure.
# ---------------------------------------------------------------------------
# The oracle sweeps' benches need a stream and have their own targets.
TBS := $(filter-out core_cosim_tb core_vec_tb core_cputest_tb core_cycles_tb fpu_dp_tb,$(patsubst sim/tb/%.sv,%,$(wildcard sim/tb/*_tb.sv)))
# core_fpu_tb is the FPU's state frames: not the MC68LC040's, which has none.
ifeq ($(FPU),0)
TBS := $(filter-out core_fpu_tb,$(TBS))
endif
MODELS := $(wildcard sim/models/*.sv)
SIMJOBS ?= 4
# The sweeps (vectors, cputest) with the caches on: 1 write-through, 2 copyback.
CACHE ?= 0

# The directed benches that run a program (core_exc_tb, core_fault_tb) take it
# from build/programs/.
SIMPROGS := m8_int m8_fault m9_cache m9_snoop m10_mmu m11_fpu_c m12_lc040_b m14_serial m14_fetch_next m14_fetch_ext m14_smp

sim: dirs $(patsubst %,build/programs/%.hex,$(SIMPROGS))
	@rm -f $(addprefix $(BUILD)/,$(addsuffix .simres,$(TBS))); \
	run_tb() { \
	  tb=$$1; r=$(BUILD)/$$tb.simres; \
	  if ! iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/$$tb.vvp -s $$tb \
	      $(RTL) $(MODELS) sim/tb/$$tb.sv > $(BUILD)/$$tb.build.log 2>&1; then \
	    { echo "FAIL: $$tb did not elaborate"; \
	      grep -v $(NOTES) $(BUILD)/$$tb.build.log; } > $$r; return; \
	  fi; \
	  vvp $(BUILD)/$$tb.vvp > $(BUILD)/$$tb.log 2>&1; \
	  if grep -q '^FAIL' $(BUILD)/$$tb.log; then \
	    { echo "FAIL: $$tb"; grep -E '^  FAIL|^FAIL' $(BUILD)/$$tb.log | head -30; } > $$r; \
	  elif ! grep -q '^PASS' $(BUILD)/$$tb.log; then \
	    { echo "FAIL: $$tb reported no PASS"; tail -20 $(BUILD)/$$tb.log; } > $$r; \
	  else \
	    echo "  $$(grep -E '^PASS' $(BUILD)/$$tb.log | head -1)" > $$r; \
	  fi; \
	}; \
	export -f run_tb; \
	printf '%s\n' $(TBS) | xargs -P $(SIMJOBS) -I{} bash -c 'run_tb {}'; \
	ok=1; for tb in $(TBS); do \
	  r=$(BUILD)/$$tb.simres; \
	  if [ ! -s $$r ]; then echo "FAIL: $$tb left no verdict"; ok=0; continue; fi; \
	  cat $$r; grep -q '^FAIL' $$r && ok=0; \
	done; test $$ok -eq 1

# ---------------------------------------------------------------------------
# Programs, and the core against UAE040 -- M6 on
#
# Each program in sim/programs/ is built with the cross toolchain and linked at
# 0 (sim/programs/flat.ld); uae040_trace writes its trace, and core_cosim_tb
# runs it on the core and compares every register at every instruction
# boundary (UAE040: doc/oracles.md). PROGS defaults to every program but the
# directed benches' (SIMPROGS), which no oracle runs.
# ---------------------------------------------------------------------------
PROGS   ?= m6_basic m7_a m7_b m7_c m8_exc m9_icache m9_dcache m9_move16 \
           m11_fpu_a m11_fpu_b m12_fpu_ind m13_move_mm m13_an_upd m13_fsave_null m13_ind_moves m14_duff \
           m15_fwd m15_ldrel

# Keep the intermediate files: the ELF is what objdump reads when a run fails.
.SECONDARY:
PSTEPS  ?= 4000
PBUILD  := build/programs

$(PBUILD)/%.elf: sim/programs/%.S sim/programs/flat.ld
	@mkdir -p $(PBUILD)
	@$(CROSS)gcc -mcpu=68040 -c -o $(PBUILD)/$*.o $<
	@$(CROSS)gcc -mcpu=68040 -nostdlib -nostartfiles -T sim/programs/flat.ld \
	    -Wl,--no-warn-rwx-segments -o $@ $(PBUILD)/$*.o 2> $(PBUILD)/$*.link.log \
	  || { cat $(PBUILD)/$*.link.log; exit 1; }

$(PBUILD)/%.hex: $(PBUILD)/%.elf
	@$(CROSS)objcopy -O verilog --verilog-data-width=1 $< $@

$(PBUILD)/%.bin: $(PBUILD)/%.elf
	@$(CROSS)objcopy -O binary $< $@

# (O40BUILD is defined with the UAE040 targets below, after this rule is read.)
# With FPU=0 the oracle is an MC68LC040 (-L), and its traces are kept apart.
# The oracle is always build/uae040's, whatever BUILD is.
O40TRACE := build/uae040/uae040_trace
PTRC     := $(PBUILD)$(if $(filter 0,$(FPU)),/lc040)
$(PBUILD)/%.trc: $(PBUILD)/%.bin $(O40TRACE)
	@$(O40TRACE) -m 64 $< $(PSTEPS) > $@ 2> $(PBUILD)/$*.trace.log \
	  || { cat $(PBUILD)/$*.trace.log; exit 1; }
$(PBUILD)/lc040/%.trc: $(PBUILD)/%.bin $(O40TRACE)
	@mkdir -p $(PBUILD)/lc040
	@$(O40TRACE) -L -m 64 $< $(PSTEPS) > $@ 2> $(PBUILD)/lc040/$*.trace.log \
	  || { cat $(PBUILD)/lc040/$*.trace.log; exit 1; }

cosim: dirs $(patsubst %,$(PBUILD)/%.hex,$(PROGS)) $(patsubst %,$(PTRC)/%.trc,$(PROGS))
	@iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/core_cosim_tb.vvp -s core_cosim_tb \
	    $(RTL) $(MODELS) sim/tb/core_cosim_tb.sv > $(BUILD)/core_cosim_tb.build.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/core_cosim_tb.build.log; exit 1; }
	@ok=1; for p in $(PROGS); do \
	  vvp $(BUILD)/core_cosim_tb.vvp +image=$(PBUILD)/$$p.hex +trace=$(PTRC)/$$p.trc \
	      > $(BUILD)/cosim-$$p.log 2>&1; \
	  grep -E '^  FAIL' $(BUILD)/cosim-$$p.log | head -8; \
	  if grep -q '^PASS' $(BUILD)/cosim-$$p.log; then \
	    echo "  $$p: $$(grep '^PASS' $(BUILD)/cosim-$$p.log | sed 's/^PASS: core_cosim_tb: //')"; \
	  else \
	    echo "  FAIL: $$p"; tail -2 $(BUILD)/cosim-$$p.log; ok=0; \
	  fi; \
	done; \
	test $$ok -eq 1 && echo "PASS: cosim"

sim-bus: dirs
	@$(MAKE) --no-print-directory sim TBS="$(filter bus_%,$(TBS))"

# ---------------------------------------------------------------------------
# AC timing, against UM section 11 (MC68040, large and small buffers) and
# Appendix A (MC68LC040): tools/timing/, doc/ac-timing.md.
#
# One recording per speed grade, at that grade's minimum BCLK period
# (specification 5), because separations are measured in clock edges and a
# recording at one frequency is evidence about that frequency only. Each grade
# is recorded twice, with BCLK high for 40 % and for 60 % of the period -- the
# two ends of specification 8 -- and both logs go into one system, because the
# release of BB, TA and TIP is on the falling edge and a board's pads do not
# change with the clock's duty cycle. Every column of the grade is then judged
# against that pair: the MC68040's large and small buffers and the MC68LC040.
# ---------------------------------------------------------------------------
TIMGRADES := 50:20 40:25 30:33 25:40
PADSKEW   ?= 0
TIMOPTS   ?=

.PHONY: timing timing-build timing-verbose

timing-build: dirs
	@iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/rd68041_timing_tb.vvp \
	    -s rd68041_timing_tb $(RTL) $(MODELS) sim/tb/rd68041_timing_tb.sv \
	    > $(BUILD)/timing.build.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/timing.build.log; exit 1; }
	@python3 tools/timing/feasible.py > $(BUILD)/timing-selftest.log \
	  || { cat $(BUILD)/timing-selftest.log; exit 1; }
	@python3 tools/timing/anchors.py > $(BUILD)/timing-anchors.log \
	  || { tail -3 $(BUILD)/timing-anchors.log; exit 1; }

timing: timing-build
	@ok=1; for g in $(TIMGRADES); do \
	  p=$${g%%:*}; f=$${g##*:}; logs=; \
	  for d in 40 60; do \
	    h=$$(awk "BEGIN { print $$p * $$d / 100 }"); \
	    vvp $(BUILD)/rd68041_timing_tb.vvp +period=$$p +high=$$h \
	        +log=$(BUILD)/timing-$$f-$$d.log > $(BUILD)/timing-run-$$f-$$d.log 2>&1; \
	    grep -q '^PASS' $(BUILD)/timing-run-$$f-$$d.log \
	      || { echo "FAIL: the timing testbench did not complete at $$p ns, $$h high"; \
	           grep '^ *FAIL' $(BUILD)/timing-run-$$f-$$d.log | head -5; ok=0; }; \
	    logs="$$logs $(BUILD)/timing-$$f-$$d.log"; \
	  done; \
	  python3 tools/timing/analyse.py --grade $$f --pad-skew $(PADSKEW) $(TIMOPTS) \
	      $$logs || ok=0; \
	done; \
	if [ $$ok -eq 1 ]; then echo "PASS: timing"; else echo "FAIL: timing"; exit 1; fi

# The same, and then every column again with its separations, pad windows, a
# pad assignment that meets every limit, and the input sampling windows.
timing-verbose: timing-build
	@$(MAKE) --no-print-directory timing || true
	@for g in $(TIMGRADES); do f=$${g##*:}; \
	  python3 tools/timing/analyse.py --grade $$f --pad-skew $(PADSKEW) $(TIMOPTS) \
	      --verbose $(BUILD)/timing-$$f-40.log $(BUILD)/timing-$$f-60.log; done; true

# ---------------------------------------------------------------------------
# The gate. The MC68LC040 build is elaborated and audited too, in its own
# build directory, so that FPU=0 cannot rot unseen.
# ---------------------------------------------------------------------------
check: ucode-check lint audit sim timing check-lc
	@echo "PASS: check"

check-lc:
	@echo "FPU=0 (MC68LC040):"
	@$(MAKE) --no-print-directory lint audit FPU=0 BUILD=$(BUILD)/lc040

# ---------------------------------------------------------------------------
# Vendor front-ends. Each has its own target and none is in `check`.
# ---------------------------------------------------------------------------
synth: dirs
	@printf '%s\n' $(RTL) > $(BUILD)/rtl.f
	@scripts/vivado.sh -mode batch -nojournal -nolog -source scripts/synth.tcl \
	    -tclargs $(BUILD) $(TOP) $(XPART) $(FPU)

# Place and route, for the frequency that means something. Out of context, with
# hierarchy kept. Reports land in $(BUILD)/impl_*.rpt and the checkpoint beside
# them.
impl: dirs
	@printf '%s\n' $(addprefix $(CURDIR)/,$(RTL)) > $(BUILD)/rtl.f
	@cd $(BUILD) && $(CURDIR)/scripts/vivado.sh -mode batch -nojournal -nolog \
	    -source $(CURDIR)/scripts/impl.tcl \
	    -tclargs $(XPART) $(TOP) $(CURDIR) $(FPU) \
	    > impl.log 2>&1; rc=$$?; \
	  grep -E '^(RD68041|ERROR|CRITICAL WARNING)' impl.log; exit $$rc

# The M4 frequency spike (doc/microarch.md): the design's storage and adders in
# the pipeline's arrangement, through a harness that is not part of the design,
# placed and routed like `make impl`. Its own build directory.
SPIKE_SRCS := rtl/rd68041_pkg.sv rtl/rd68041_late_release.sv rtl/rd68041_rstctl.sv \
              rtl/rd68041_snoop.sv rtl/rd68041_biu.sv rtl/rd68041_bram.sv \
              rtl/rd68041_atc.sv rtl/rd68041_cache_arr.sv rtl/rd68041_regfile.sv \
              rtl/rd68041_agu.sv rtl/rd68041_shifter.sv sim/spike/rd68041_spike.sv

spike: dirs
	@mkdir -p $(BUILD)/spike
	@printf '%s\n' $(addprefix $(CURDIR)/,$(SPIKE_SRCS)) > $(BUILD)/spike/rtl.f
	@cd $(BUILD)/spike && $(CURDIR)/scripts/vivado.sh -mode batch -nojournal -nolog \
	    -source $(CURDIR)/scripts/impl.tcl \
	    -tclargs $(XPART) rd68041_spike $(CURDIR) - \
	    > impl.log 2>&1; rc=$$?; \
	  grep -E '^(RD68041|ERROR|CRITICAL WARNING)' impl.log; exit $$rc

# quartus_map returns 0 on the one thing that matters most here, so the grep is the
# gate and not the exit code: a package-scoped constant inside an instantiation's
# port expression becomes an implicit one-bit net and a Warning (10236). pipefail
# is not optional: without it a Tcl error inside quartus_sh reports "quartus: ok".
lint-quartus: dirs
	@printf '%s\n' $(RTL) > $(BUILD)/rtl.f
	@set -o pipefail; scripts/altera.sh quartus_sh -t scripts/quartus.tcl map \
	    $(BUILD) $(TOP) $(AFAMILY) $(APART) $(FPU) \
	    | tee $(BUILD)/quartus_map.log
	@if grep -q 'Implicit Net warning\|Warning (10236)' $(BUILD)/quartus_map.log; then \
	    echo "FAIL: quartus found an implicit net -- the netlist does not match the source"; \
	    grep 'Warning (10236)' $(BUILD)/quartus_map.log; exit 1; fi
	@echo "  quartus: ok"

QBUILD := $(BUILD)/quartus

quartus: dirs
	@mkdir -p $(QBUILD)
	@printf '%s\n' $(RTL) > $(QBUILD)/rtl.f
	@set -o pipefail; scripts/altera.sh quartus_sh -t scripts/quartus.tcl fit \
	    $(QBUILD) $(TOP) $(AFAMILY) $(APART) $(FPU) \
	    > $(QBUILD)/fit.log 2>&1 || { grep -E '^QUARTUS|Error' $(QBUILD)/fit.log | head; exit 1; }
	@if grep -q 'Warning (10236)' $(QBUILD)/fit.log; then \
	    echo "FAIL: quartus found an implicit net"; exit 1; fi
	@grep -E '^QUARTUS' $(QBUILD)/fit.log
	@grep -A12 -E 'Slow 1[12]00mV 85C Model Fmax Summary' $(QBUILD)/quartus_out/$(TOP).sta.rpt \
	    | grep -E 'MHz' | head -3
	@grep -E 'Logic utilization|Total logic elements|Total registers|Total (block )?memory bits|Total DSP|Total RAM Blocks|Embedded Multiplier' \
	    $(QBUILD)/quartus_out/$(TOP).fit.summary

lint-questa: dirs
	@scripts/questa.sh $(BUILD) $(TOP) $(RTL)
	@echo "  questa: ok"

# ---------------------------------------------------------------------------
# The instruction-level oracle: UAE040
#
# The WinUAE MC68040 core as Hatari carries it (Inputs/ref/hatari/src/cpu),
# built out of tree into build/uae040/ (Inputs/ is immutable) by
# tools/cosim/uae040/build.sh as one library, libuae040.a, and linked into
# its front-ends: uae040_trace for now. RD68031's uae030 flow, retargeted;
# doc/oracles.md has what it is trusted for.
#
# The library is built once and reused: build.sh is incremental, and only runs
# again when the harness's own glue changes. The generated cores are compiled
# at -O0/-O1, four at a time, which keeps each compile near 300 MB.
#
# The --wrap options let the glue see an operand the core moves in pieces (it
# crosses a page, or it is MOVES or a locked read-modify-write) as the one
# operand it is.
# ---------------------------------------------------------------------------
O40BUILD  := $(BUILD)/uae040
O40SRC    := tools/cosim/uae040
comma     := ,
O40WRAP   := mmu_get_word_unaligned mmu_get_long_unaligned \
             mmu_put_word_unaligned mmu_put_long_unaligned \
             sfc_get_long sfc_get_word dfc_put_long dfc_put_word \
             uae_mmu_get_lrmw uae_mmu_put_lrmw
O40LDFLAGS := $(addprefix -Wl$(comma)--wrap=,$(O40WRAP)) -lm
O40CFLAGS  := -O2 -g -Wall -Wextra -I$(O40SRC)

uae040: $(O40BUILD)/uae040_trace $(O40BUILD)/vectors_gen

$(O40BUILD)/libuae040.a: $(O40SRC)/build.sh $(O40SRC)/uae040_glue.c $(O40SRC)/uae040.h
	@mkdir -p $(O40BUILD)
	@echo "  uae040: building the oracle core into $(O40BUILD)"
	@JOBS=4 sh $(O40SRC)/build.sh $(O40BUILD) > $(O40BUILD)/build.log 2>&1 \
	  || { tail -30 $(O40BUILD)/build.log; exit 1; }

$(O40BUILD)/uae040_trace: $(O40SRC)/uae040_trace.c $(O40SRC)/uae040.h $(O40BUILD)/libuae040.a
	@$(CC) $(O40CFLAGS) -o $@ $< $(O40BUILD)/libuae040.a $(O40LDFLAGS)

# The M0 smoke program, run as an MC68040 and as an MC68LC040 (-L), each
# checked by tests/smoke040_check.py against the values and accesses the
# manual fixes. The trace, bus and operand streams stay in build/uae040/smoke/.
O40SMOKE := $(O40BUILD)/smoke

$(O40SMOKE)/smoke040.elf: $(O40SRC)/tests/smoke040.S
	@mkdir -p $(O40SMOKE)
	@$(CROSS)gcc -mcpu=68040 -nostdlib -Wl,-Ttext=0 -Wl,--build-id=none -o $@ $<

$(O40SMOKE)/smoke040.bin: $(O40SMOKE)/smoke040.elf
	@$(CROSS)objcopy -O binary $< $@

uae040-smoke: $(O40BUILD)/uae040_trace $(O40SMOKE)/smoke040.bin
	@ok=1; for v in 040 lc040; do \
	  f=; c=; [ $$v = lc040 ] && { f=-L; c=--lc; }; \
	  $(O40BUILD)/uae040_trace $$f -m 256 -B $(O40SMOKE)/$$v.bus -O $(O40SMOKE)/$$v.ops \
	      $(O40SMOKE)/smoke040.bin 4000 > $(O40SMOKE)/$$v.trc 2> $(O40SMOKE)/$$v.trace.log \
	    || { echo "FAIL: uae040_trace ($$v)"; cat $(O40SMOKE)/$$v.trace.log; ok=0; continue; }; \
	  python3 $(O40SRC)/tests/smoke040_check.py $$c $(O40SMOKE)/smoke040.elf $(O40SMOKE)/$$v.trc \
	      $(O40SMOKE)/$$v.bus $(O40SMOKE)/$$v.ops > $(O40SMOKE)/$$v.check 2>&1; \
	  grep -E '^  (FAIL|quirk)' $(O40SMOKE)/$$v.check | sort -u; \
	  tail -1 $(O40SMOKE)/$$v.check | sed 's/^/  /'; \
	  grep -q '^PASS' $(O40SMOKE)/$$v.check || ok=0; \
	done; \
	if [ $$ok -eq 1 ]; then echo "PASS: uae040-smoke"; else echo "FAIL: uae040-smoke"; exit 1; fi

# ---------------------------------------------------------------------------
# The per-opcode sweep, against UAE040 (M7)
#
# tools/vectors/gen.c (RD68031's, retargeted) runs each group's tests through
# UAE040 and writes the stream sim/tb/core_vec_tb.sv replays on the core: the
# registers, SR, the next PC and the operand accesses are compared, and every
# test is counted as passed, failed, not built (the core halted on it) or
# pending (it needs what the core does not have yet; none since M8). It passes
# when nothing fails. `ea` is the addressing-mode group.
#
#   make vectors OP=alu        one group (or several: OP="alu shift")
#   make vectors               OP=$(VECGROUPS)
#   make vectors-all           every group
#   make ea                    every addressing mode, through LEA and MOVE.L
#   make vectors OP=lc040 FPU=0   the MC68LC040's format $4 frames (M12): the
#                              oracle run as one (-L), the core built as one;
#                              FPU=0 vectors-all is every group that way
#
# Not in `make check`.
# ---------------------------------------------------------------------------
VECGROUPS ?= all
OP        ?= $(VECGROUPS)
VECSHOW   ?= 15

$(O40BUILD)/vectors_gen: tools/vectors/gen.c $(O40SRC)/uae040.h $(O40BUILD)/libuae040.a
	@$(CC) $(O40CFLAGS) -o $@ $< $(O40BUILD)/libuae040.a $(O40LDFLAGS)

.PHONY: vectors vectors-all ea
vectors: dirs $(O40BUILD)/vectors_gen
	@$(O40BUILD)/vectors_gen $(if $(filter 0,$(FPU)),-L) $(OP) > $(BUILD)/vectors.hex 2> $(BUILD)/vectors-gen.log \
	  || { cat $(BUILD)/vectors-gen.log; exit 1; }
	@sed 's/^/  /' $(BUILD)/vectors-gen.log
	@iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/core_vec_tb.vvp -s core_vec_tb \
	    $(RTL) $(MODELS) sim/tb/core_vec_tb.sv > $(BUILD)/core_vec_tb.build.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/core_vec_tb.build.log; exit 1; }
	@vvp $(BUILD)/core_vec_tb.vvp +vec=$(BUILD)/vectors.hex +faillog=$(BUILD)/vectors.fail +cache=$(CACHE) \
	    +show=$(VECSHOW) > $(BUILD)/core_vec_tb.log 2>&1; \
	 grep -E '^  (FAIL|      )' $(BUILD)/core_vec_tb.log | head -$$(( $(VECSHOW) * 4 )); \
	 grep -E '^core_vec_tb: ' $(BUILD)/core_vec_tb.log | sed 's/^core_vec_tb: /  /'; \
	 grep -q '^PASS' $(BUILD)/core_vec_tb.log || { grep -E '^FAIL' $(BUILD)/core_vec_tb.log; \
	   echo "  (every failure: $(BUILD)/vectors.fail)"; exit 1; }
	@grep -E '^PASS' $(BUILD)/core_vec_tb.log

vectors-all:
	@$(MAKE) --no-print-directory vectors OP=all

ea:
	@$(MAKE) --no-print-directory vectors OP=ea

# ---------------------------------------------------------------------------
# WinUAE's cputest corpus for the MC68040
#
# cputestgen (built out of tree into build/cputest/gen/ by
# tools/cputest/build.sh) writes the integer corpus from CPUTEST_INI into
# build/cputest/run/data/ and the FPU corpus from CPUTEST_FPU_INI into
# build/cputest/fpu/data/, one instruction per generator run
# (tools/cputest/generate.sh). tools/cputest/convert.py summary then decodes
# every test and counts them (build/cputest/summary.txt). `make cputest`
# runs the integer corpus on the core (sim/tb/core_cputest_tb.sv, M7).
#
#   CPUTEST_TIMEOUT=s    the generator's time limit per instruction (default 120);
#                        one that runs out twice is listed and left out
#
# Each corpus is regenerated only when its ini or the generator changes.
# ---------------------------------------------------------------------------
CTBUILD         := $(BUILD)/cputest
CPUTEST_INI     ?= tools/cputest/cputestgen.ini
CPUTEST_FPU_INI ?= tools/cputest/cputestgen-fpu.ini

$(CTBUILD)/gen/cputestgen: tools/cputest/build.sh tools/cputest/compat/cputest_compat.h \
                           tools/cputest/compat/ua_stub.cpp
	@mkdir -p $(CTBUILD)/gen
	@echo "  cputest: building cputestgen into $(CTBUILD)/gen"
	@JOBS=4 sh tools/cputest/build.sh $(CTBUILD)/gen > $(CTBUILD)/gen.log 2>&1 \
	  || { tail -30 $(CTBUILD)/gen.log; exit 1; }

$(CTBUILD)/run/stamp: $(CTBUILD)/gen/cputestgen $(CPUTEST_INI) tools/cputest/generate.sh
	@rm -rf $(CTBUILD)/run
	@mkdir -p $(CTBUILD)/run/data
	@cp $(CPUTEST_INI) $(CTBUILD)/run/cputestgen.ini
	@echo "  cputest: generating the integer corpus from $(CPUTEST_INI), one instruction at a time"
	@set -o pipefail; sh tools/cputest/generate.sh $(CTBUILD)/gen/cputestgen $(CPUTEST_INI) $(CTBUILD)/run int \
	  | sed 's/^/  /'
	@touch $@

$(CTBUILD)/fpu/stamp: $(CTBUILD)/gen/cputestgen $(CPUTEST_FPU_INI) tools/cputest/generate.sh
	@rm -rf $(CTBUILD)/fpu
	@mkdir -p $(CTBUILD)/fpu/data
	@cp $(CPUTEST_FPU_INI) $(CTBUILD)/fpu/cputestgen.ini
	@echo "  cputest: generating the FPU corpus from $(CPUTEST_FPU_INI), one instruction at a time"
	@set -o pipefail; sh tools/cputest/generate.sh $(CTBUILD)/gen/cputestgen $(CPUTEST_FPU_INI) $(CTBUILD)/fpu fpu \
	  | sed 's/^/  /'
	@touch $@

cputest-gen: dirs $(CTBUILD)/run/stamp $(CTBUILD)/fpu/stamp
	@python3 tools/cputest/convert.py summary $(CTBUILD)/run/data/*/ $(CTBUILD)/fpu/data/*/ \
	    > $(CTBUILD)/summary.txt 2>&1; rc=$$?; \
	 grep -E '^(total|instructions|exceptions|frames|DECODE)|DECODE ERROR' $(CTBUILD)/summary.txt | sed 's/^/  /'; \
	 if [ $$rc -eq 0 ]; then echo "PASS: cputest-gen (per instruction: $(CTBUILD)/summary.txt)"; \
	 else echo "FAIL: cputest-gen"; exit 1; fi

# The integer corpus on the core: convert.py bench samples it into
# build/cputest/cputest.vec and core_cputest_tb replays it; every test is
# passed, failed, not built or pending (sim/tb/core_cputest_tb.sv), each run in
# its own mode, the FPU corpus with it (M11; left out and counted with FPU=0).
# Not in `make check`.
#
#   CPUTEST_SEL=ADD,MOVE.L   only these instructions (a bare name takes every size)
#   CPUTEST_MAX=N            at most N tests per instruction, sampled evenly; 0 all
CPUTEST_SEL  ?=
CPUTEST_MAX  ?= 40

# The caches against the oracles (M9): the programs that run with them on, and
# the two sweeps with them on, write-through (CACHE=1) and copyback (CACHE=2).
# What is on the bus is core_cache_tb's and core_snoop_tb's, in `make sim`.
.PHONY: cache
cache:
	@$(MAKE) --no-print-directory cosim PROGS="m9_icache m9_dcache m9_move16 m15_fwd m15_ldrel"
	@$(MAKE) --no-print-directory mmu-cache
	@for c in 1 2; do echo "== vectors-all CACHE=$$c"; \
	  $(MAKE) --no-print-directory vectors-all CACHE=$$c || exit 1; done
	@for c in 1 2; do echo "== cputest CACHE=$$c"; \
	  $(MAKE) --no-print-directory cputest CACHE=$$c || exit 1; done

# Two processors on one bus (doc/smp.md): core_smp_tb, which `make sim` runs
# with a few iterations, in its variants -- at length, with wait states and
# retries (the arbiter then ignoring LOCKE, which retries make unsafe), and
# CPU 1 let out of reset late, and the board without the SC gate or the memory
# update, its shared pages all write-through -- and the checks shown to work: the printed
# arbiter's handover must be caught (+gapless), and the board's MI gate, its
# SC gate, its memory update from sourced data and the pages' U bits must each
# be missed when taken away (the run must FAIL). Light simulations, four at a time.
SMPDIR   = $(BUILD)/smp
SMP_PASS = long:+iters=32 retry:+iters=12+waits=1+retry=40+nolocke late:+iters=8+rsti1=30000 \
           straight:+iters=12+wtshared+rawsc+nosnarf gapless:+iters=4+gapless
SMP_FAIL = nomigate:+iters=4+nomigate+timeout=60000 nosnarf:+iters=12+nosnarf \
           nosnoop:+iters=6+umask=FFFFFCFF+timeout=200000 rawsc:+iters=12+rawsc
.PHONY: smp
smp: dirs build/programs/m14_smp.hex
	@mkdir -p $(SMPDIR)
	@iverilog $(IVFLAGS) -I sim/tb -o $(SMPDIR)/core_smp_tb.vvp -s core_smp_tb \
	    $(RTL) $(MODELS) sim/tb/core_smp_tb.sv > $(SMPDIR)/build.log 2>&1 \
	  || { grep -v $(NOTES) $(SMPDIR)/build.log; exit 1; }
	@run() { n=$${1%%:*}; a=$$(echo $${1#*:} | tr '+' ' ' | sed 's/ / +/g'); \
	  timeout 3600 vvp $(SMPDIR)/core_smp_tb.vvp $$a > $(SMPDIR)/$$n.log 2>&1; \
	  echo "$$2 $$n: $$(grep -E '^(PASS|FAIL)' $(SMPDIR)/$$n.log | head -1)" > $(SMPDIR)/$$n.res; }; \
	 export -f run; \
	 { for v in $(SMP_PASS); do echo "$$v pass"; done; for v in $(SMP_FAIL); do echo "$$v fail"; done; } \
	   | xargs -P $(SIMJOBS) -L 1 bash -c 'run $$0 $$1'; \
	 ok=1; for v in $(SMP_PASS) $(SMP_FAIL); do n=$${v%%:*}; r=$$(cat $(SMPDIR)/$$n.res); \
	   case "$$r" in \
	     "pass $$n: PASS"*) echo "  $$n: $${r#* $$n: }";; \
	     "fail $$n: FAIL"*) echo "  $$n: failed, as it must: $$(grep -m1 '  FAIL' $(SMPDIR)/$$n.log | sed 's/^ *//')";; \
	     *) echo "  $$n: WRONG -- $$r ($(SMPDIR)/$$n.log)"; ok=0;; \
	   esac; done; \
	 test $$ok -eq 1 && echo "PASS: smp (FPU=$(FPU))"

# Integer instruction timings (M15): tools/cycles/cycles.py's program, each
# case's copies run until the caches are warm, core_cycles_tb's clocks between
# the first and the last, and the table against UM section 10 that
# doc/timing-divergences.md carries. A light simulation.
CYCDIR = $(BUILD)/cycles$(if $(filter 0,$(FPU)),/lc)
.PHONY: cycles
cycles: dirs
	@mkdir -p $(CYCDIR)
	@python3 tools/cycles/cycles.py gen $(CYCDIR)/m15_cycles.S
	@$(CROSS)gcc -mcpu=68040 -c -o $(CYCDIR)/m15_cycles.o $(CYCDIR)/m15_cycles.S
	@$(CROSS)gcc -mcpu=68040 -nostdlib -nostartfiles -T sim/programs/flat.ld \
	    -Wl,--no-warn-rwx-segments -o $(CYCDIR)/m15_cycles.elf $(CYCDIR)/m15_cycles.o 2> /dev/null
	@$(CROSS)objcopy -O verilog --verilog-data-width=1 $(CYCDIR)/m15_cycles.elf $(CYCDIR)/m15_cycles.hex
	@iverilog $(IVFLAGS) -I sim/tb -o $(CYCDIR)/core_cycles_tb.vvp -s core_cycles_tb \
	    $(RTL) $(MODELS) sim/tb/core_cycles_tb.sv > $(CYCDIR)/build.log 2>&1 \
	  || { grep -v $(NOTES) $(CYCDIR)/build.log; exit 1; }
	@vvp $(CYCDIR)/core_cycles_tb.vvp +image=$(CYCDIR)/m15_cycles.hex > $(CYCDIR)/cycles.log 2>&1
	@grep -q '^PASS' $(CYCDIR)/cycles.log || { tail -3 $(CYCDIR)/cycles.log; exit 1; }
	@python3 tools/cycles/cycles.py report $(CYCDIR)/cycles.log > $(CYCDIR)/cycles.md
	@tail -1 $(CYCDIR)/cycles.md
	@echo "PASS: cycles (FPU=$(FPU), the table in $(CYCDIR)/cycles.md)"

# The MC68LC040 against UAE040 -L (M12): the core built with FPU=0, the
# integer programs and m12_lc040, every FP instruction a format $4 frame.
LCPROGS ?= m6_basic m7_a m7_b m7_c m8_exc m9_icache m9_dcache m9_move16 m10_mmu m12_lc040 m13_move_mm m13_an_upd m13_ind_moves m14_duff m15_fwd m15_ldrel
.PHONY: cosim-lc
cosim-lc:
	@$(MAKE) --no-print-directory cosim FPU=0 BUILD=$(BUILD)/lc040 PROGS="$(LCPROGS)"

# The MMU against UAE040: m10_mmu register for register (the program core_mmu_tb
# runs), and the pmmu040 vector group.
cosim-mmu:
	@$(MAKE) --no-print-directory cosim PROGS=m10_mmu
	@$(MAKE) --no-print-directory vectors OP=pmmu040

# ---------------------------------------------------------------------------
# The FPU's data path against Berkeley TestFloat (doc/fpu.md, "Checked by")
#
# SoftFloat and TestFloat are built out of tree into build/testfloat/ from
# Inputs/third_party/; tools/fpu/check_testfloat.py runs testfloat_gen, the
# vectors through sim/tb/fpu_dp_tb.sv, and compares.
#   TFLIMIT=n   vectors per function and rounding mode (default 3000; 0 all)
# ---------------------------------------------------------------------------
TFBUILD := $(BUILD)/testfloat
TFLIMIT ?= 3000
SF_DIR  := $(CURDIR)/Inputs/third_party/berkeley-softfloat-3
TF_DIR  := $(CURDIR)/Inputs/third_party/berkeley-testfloat-3

$(TFBUILD)/testfloat/testfloat_gen:
	@mkdir -p $(TFBUILD)
	@rm -rf $(TFBUILD)/softfloat $(TFBUILD)/testfloat
	@cp -r $(SF_DIR)/build/Linux-x86_64-GCC $(TFBUILD)/softfloat
	@cp -r $(TF_DIR)/build/Linux-x86_64-GCC $(TFBUILD)/testfloat
	@$(MAKE) -s -C $(TFBUILD)/softfloat SOURCE_DIR=$(SF_DIR)/source > $(TFBUILD)/softfloat.log 2>&1
	@$(MAKE) -s -C $(TFBUILD)/testfloat SOURCE_DIR=$(TF_DIR)/source SOFTFLOAT_DIR=$(SF_DIR) \
	    SOFTFLOAT_LIB=$(CURDIR)/$(TFBUILD)/softfloat/softfloat.a testfloat_gen \
	    > $(TFBUILD)/testfloat.log 2>&1
	@echo "  testfloat: SoftFloat and testfloat_gen built"

testfloat: dirs $(TFBUILD)/testfloat/testfloat_gen
	@iverilog $(IVFLAGS) -o $(BUILD)/fpu_dp_tb.vvp -s fpu_dp_tb \
	    $(PKGS) rtl/rd68041_fpu_dp.sv sim/tb/fpu_dp_tb.sv > $(BUILD)/fpu_dp_tb.build.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/fpu_dp_tb.build.log; exit 1; }
	@python3 tools/fpu/check_testfloat.py --limit $(TFLIMIT)

# core_mmu_tb with the caches on: the tables write-through, then copyback.
mmu-cache: dirs $(BUILD)/programs/m10_mmu.hex
	@iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/core_mmu_tb.vvp -s core_mmu_tb \
	    $(RTL) $(MODELS) sim/tb/core_mmu_tb.sv > $(BUILD)/core_mmu_tb.build.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/core_mmu_tb.build.log; exit 1; }
	@ok=1; for cm in 0 20; do \
	  vvp $(BUILD)/core_mmu_tb.vvp +cacr=80008000 +cm=$$cm > $(BUILD)/core_mmu_tb-cm$$cm.log 2>&1; \
	  grep -E '^  FAIL|^FAIL|^PASS' $(BUILD)/core_mmu_tb-cm$$cm.log | head -20; \
	  grep -q '^PASS' $(BUILD)/core_mmu_tb-cm$$cm.log || ok=0; \
	done; test $$ok -eq 1

.PHONY: cputest
cputest: dirs $(CTBUILD)/run/stamp
	@python3 tools/cputest/convert.py bench $(CTBUILD) $(CTBUILD)/run/data/*/ \
	    $(wildcard $(CTBUILD)/fpu/data/*/) --summary $(CTBUILD)/summary.txt \
	    --select "$(CPUTEST_SEL)" --max $(CPUTEST_MAX) $(if $(filter 0,$(FPU)),--no-fpu) \
	  | sed 's/^/  /'
	@iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/core_cputest_tb.vvp -s core_cputest_tb \
	    $(RTL) $(MODELS) sim/tb/core_cputest_tb.sv > $(BUILD)/core_cputest_tb.build.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/core_cputest_tb.build.log; exit 1; }
	@vvp $(BUILD)/core_cputest_tb.vvp +vec=$(CTBUILD)/cputest.vec +mem=$(CTBUILD) +cache=$(CACHE) \
	    +faillog=$(CTBUILD)/cputest.fail \
	    > $(BUILD)/core_cputest_tb.log 2>&1; \
	 grep -E '^  (FAIL|      )' $(BUILD)/core_cputest_tb.log | head -75; \
	 grep -E '^core_cputest_tb: ' $(BUILD)/core_cputest_tb.log | sed 's/^core_cputest_tb: /  /'; \
	 grep -q '^PASS' $(BUILD)/core_cputest_tb.log || { grep -E '^FAIL' $(BUILD)/core_cputest_tb.log; \
	   echo "  (every failure: $(CTBUILD)/cputest.fail)"; exit 1; }
	@grep -E '^PASS' $(BUILD)/core_cputest_tb.log

# ---------------------------------------------------------------------------
# QEMU's m68040, a third instruction-trace oracle (doc/oracles.md, "QEMU")
#
# QEMU 11.1.2 (Inputs/ref/qemu) is exported into build/qemu/src and built
# there for m68k-softmmu with TCG plugins by tools/cosim/qemu040/build.sh
# (once; a heavy job, -j4, alone). The plugin, libqemu040.so, writes
# uae040_trace's .trc, with "x" for the registers QEMU does not expose.
# QEMU is run with one instruction per translation block: otherwise the
# condition codes a plugin reads in the middle of a block are stale.
#
#   make cosim-qemu-smoke  smoke040.S from reset on both oracles, the traces
#                          compared; tools/cosim/qemu040/smoke040.quirks lists
#                          the differences expected, each must recur
# ---------------------------------------------------------------------------
QBUILD040 := $(BUILD)/qemu
QEMU      := $(QBUILD040)/inst/bin/qemu-system-m68k
Q040      := $(BUILD)/qemu040
Q040SRC   := tools/cosim/qemu040
Q040PLUG  := $(Q040)/libqemu040.so
QEMU040   = $(QEMU) -M virt -cpu m68040 -accel tcg,one-insn-per-tb=on -display none \
            -monitor none -serial none

$(QEMU): $(Q040SRC)/build.sh
	@mkdir -p $(QBUILD040)
	@echo "  qemu040: building QEMU into $(QBUILD040) (-j4, alone)"
	@JOBS=4 sh $(Q040SRC)/build.sh $(QBUILD040) | sed 's/^/  /'

$(Q040PLUG): $(Q040SRC)/qemu040.c $(QEMU)
	@mkdir -p $(Q040)
	@$(CC) -O2 -g -Wall -Wextra -shared -fPIC -I$(QBUILD040)/inst/include \
	    $$(pkg-config --cflags glib-2.0) -o $@ $<

qemu040: $(QEMU) $(Q040PLUG)

cosim-qemu-smoke: $(Q040PLUG) $(O40SMOKE)/smoke040.elf uae040-smoke
	@mkdir -p $(Q040)/smoke
	@$(QEMU040) -m 1M -kernel $(O40SMOKE)/smoke040.elf \
	    -plugin $(Q040PLUG),trc=$(Q040)/smoke/040.trc,ops=$(Q040)/smoke/040.ops,limit=4000 \
	    2> $(Q040)/smoke/040.trace.log || { cat $(Q040)/smoke/040.trace.log; exit 1; }
	@python3 $(Q040SRC)/compare.py --elf $(O40SMOKE)/smoke040.elf --expect $(Q040SRC)/smoke040.quirks \
	    $(O40SMOKE)/040.trc $(Q040)/smoke/040.trc > $(Q040)/smoke/compare.txt; rc=$$?; \
	 grep -v ' _start fp' $(Q040)/smoke/compare.txt | sed 's/^  //; s/^/  /'; \
	 if [ $$rc -eq 0 ]; then echo "PASS: cosim-qemu-smoke"; else echo "FAIL: cosim-qemu-smoke"; exit 1; fi

# ---------------------------------------------------------------------------
# Linux on QEMU's virt board (doc/oracles.md, "Linux on QEMU's virt")
#
# The guest -- Linux 7.2.9 with sim/virt/linux/rd-virt.config (MC68040 only,
# the FPSP, no FPU emulation) and a static BusyBox, both pinned by
# Inputs/sw/MANIFEST -- is built by sim/virt/linux/build.sh (heavy, -j4,
# alone; reused) and booted with sim/virt/linux/commands.script typed at its
# shell by qemu-run.py. The instruction count is the plugin's (count=).
# ---------------------------------------------------------------------------
VGUEST040 := $(BUILD)/virt/guest

$(VGUEST040)/vmlinux $(VGUEST040)/initramfs.cpio.gz: sim/virt/linux/build.sh sim/virt/linux/rd-virt.config \
            sim/virt/linux/init sim/virt/linux/cpio.list
	@echo "  virt: building the guest into $(VGUEST040) (Linux and BusyBox, -j4, alone)"
	@JOBS=4 sh sim/virt/linux/build.sh $(VGUEST040) | sed 's/^/  /'

virt-qemu: $(Q040PLUG) $(VGUEST040)/vmlinux $(VGUEST040)/initramfs.cpio.gz
	@python3 sim/virt/linux/qemu-run.py --qemu $(QEMU) --log $(VGUEST040)/qemu.console \
	    --script sim/virt/linux/commands.script --timeout 300 --expect "reboot: Power down" -- \
	    -M virt -cpu m68040 -m 128M -display none -monitor none -serial stdio \
	    -kernel $(VGUEST040)/vmlinux -initrd $(VGUEST040)/initramfs.cpio.gz \
	    -append "console=ttyGF0 lpj=250000 rdvirt.shell" \
	    -plugin $(Q040PLUG),count=$(VGUEST040)/qemu.insns | sed 's/^/  /'; \
	 rc=$${PIPESTATUS[0]}; sed 's/^/  /' $(VGUEST040)/qemu.insns; \
	 if [ $$rc -eq 0 ]; then echo "PASS: virt-qemu (console in $(VGUEST040)/qemu.console)"; \
	 else echo "FAIL: virt-qemu (console in $(VGUEST040)/qemu.console)"; exit 1; fi

# ---------------------------------------------------------------------------
# rd-virt (M13): the deterministic m68k `virt` machine, with the RTL, UAE040,
# or both in lockstep. doc/virt.md has the machine, the lockstep and its
# options; doc/m13-mismatches.md what it found. RD68031's rd-virt, for the
# MC68040 and, with FPU=0, the MC68LC040 (its own RTL build, guest kernel --
# the FPU emulation -- and command set; UAE040 -L).
#
#   make virt-uae          Linux to the shell and the command set on UAE040
#                          alone -- validates the machine, fast
#   make virt-bare         the bare-metal programs, in lockstep, with three
#                          bus and cache set-ups each
#   make virt-linux-solo   Linux on the RTL alone
#   make virt-linux        Linux in lockstep: no divergence and the expected
#                          console is the pass (VIRT_CACHES=off: TCI on every
#                          line the RTL reads, so its caches stay empty, and
#                          no data cache in the oracle)
#   make fpsp              Linux in lockstep running the M68040FPSP's
#                          emulated instructions (commands-fpsp.script; FPU=1)
#
#   VIRT_OPTS=...          more rdvirt options (--tbi, --ram-waits 2, ...)
#
# The RTL build (Verilator) and the guest builds (Linux, BusyBox) are heavy
# jobs: each runs once, alone, at JOBS=4 at most, and is reused (CLAUDE.md).
# None of these is in `make check`.
# ---------------------------------------------------------------------------
VIRTTOP     := build/virt
VIRT        := $(VIRTTOP)$(if $(filter 0,$(FPU)),/lc)
VIRTBIN     := $(VIRT)/obj/rdvirt
VIRTUAE     := $(VIRTTOP)/rdvirt-uae
VGUEST      := $(if $(filter 0,$(FPU)),$(VIRTTOP)/guest-lc,$(VGUEST040))
VIRT_CMDLINE ?= console=ttyGF0 lpj=250000 rdvirt.shell
VIRT_SCRIPT ?= sim/virt/linux/commands$(if $(filter 0,$(FPU)),-lc).script
VIRT_OPTS   ?=
VIRT_CACHES ?= on
VIRT_MAXSTEPS ?= 400000000
VIRTNOFPU   := $(if $(filter 0,$(FPU)),--no-fpu)
VIRTPROGS   := virt_hello virt_timer virt_mmu
VIRTSRC     := $(wildcard sim/virt/*.cpp sim/virt/*.h) sim/virt/build.sh
VIRTLINUX    = --kernel $(VGUEST)/vmlinux --initrd $(VGUEST)/initramfs.cpio.gz \
               --cmdline "$(VIRT_CMDLINE)" --expect done $(VIRTNOFPU) \
               --progress 10000000 --max-steps $(VIRT_MAXSTEPS)
ifeq ($(VIRT_CACHES),off)
VIRTCACHE   := --tci --no-dcache
endif

$(VIRTUAE): $(VIRTSRC) $(O40BUILD)/libuae040.a
	@sh sim/virt/build.sh uae $(VIRTTOP) > /dev/null

$(VIRTBIN): $(VIRTSRC) sim/virt/public.vlt $(O40BUILD)/libuae040.a $(RTL)
	@echo "  virt: building the RTL machine into $(VIRT)/obj (Verilator, FPU=$(FPU), alone)"
	@RTLFILES="$(RTL)" FPU=$(FPU) sh sim/virt/build.sh rtl $(VIRT) > /dev/null

$(VIRTTOP)/guest-lc/vmlinux $(VIRTTOP)/guest-lc/initramfs.cpio.gz: sim/virt/linux/build.sh \
            sim/virt/linux/rd-virt-lc.config sim/virt/linux/init sim/virt/linux/cpio.list
	@echo "  virt: building the MC68LC040 guest into $(VIRTTOP)/guest-lc (Linux and BusyBox, -j4, alone)"
	@CONFIG=rd-virt-lc.config JOBS=4 sh sim/virt/linux/build.sh $(VIRTTOP)/guest-lc | sed 's/^/  /'

build/programs/virt_%.elf: sim/programs/virt_%.S sim/programs/virt.inc sim/programs/virt.ld
	@mkdir -p build/programs
	@$(CROSS)gcc -mcpu=68040 -Isim/programs -c -o build/programs/virt_$*.o $<
	@$(CROSS)gcc -nostdlib -nostartfiles -Wl,--build-id=none -T sim/programs/virt.ld \
	    -o $@ build/programs/virt_$*.o

virt-bare: $(VIRTBIN) $(patsubst %,build/programs/%.elf,$(VIRTPROGS))
	@ok=1; for p in $(VIRTPROGS); do for m in "" "--tbi --ram-waits 1" "--tci --no-dcache"; do \
	  $(VIRTBIN) --cpu lockstep --bare build/programs/$$p.elf --quiet --progress 0 $(VIRTNOFPU) \
	      --expect "PASS: $$p" --dump $(VIRT)/$$p.div $$m $(VIRT_OPTS) \
	      > $(VIRT)/$$p.log 2>&1; \
	  if grep -q '^PASS' $(VIRT)/$$p.log; then echo "  PASS: $$p $$m -- $$(grep -o '[0-9]* steps' $(VIRT)/$$p.log | tail -1)"; \
	  else echo "  FAIL: $$p $$m"; tail -5 $(VIRT)/$$p.log; ok=0; fi; done; done; \
	test $$ok -eq 1 && echo "PASS: virt-bare"

virt-uae: $(VIRTUAE) $(VGUEST)/vmlinux $(VGUEST)/initramfs.cpio.gz
	@$(VIRTUAE) --cpu uae $(VIRTLINUX) --script $(VIRT_SCRIPT) --quiet --console-log $(VIRT)/uae.console \
	    $(VIRT_OPTS) > $(VIRT)/uae.log 2>&1; \
	 grep -E '^\[uae040\] end' $(VIRT)/uae.log | sed 's/^/  /'; \
	 grep -q '^PASS' $(VIRT)/uae.log || { tail -12 $(VIRT)/uae.log; exit 1; }
	@echo "PASS: virt-uae (console in $(VIRT)/uae.console)"

virt-linux-solo: $(VIRTBIN) $(VGUEST)/vmlinux $(VGUEST)/initramfs.cpio.gz
	@$(VIRTBIN) --cpu rtl $(VIRTLINUX) --script $(VIRT_SCRIPT) $(VIRTCACHE) --quiet \
	    --console-log $(VIRT)/solo.console $(VIRT_OPTS) > $(VIRT)/solo.log 2>&1; \
	 grep -E '^\[rtl\] end' $(VIRT)/solo.log | sed 's/^/  /'; \
	 grep -q '^PASS' $(VIRT)/solo.log || { tail -12 $(VIRT)/solo.log; exit 1; }
	@echo "PASS: virt-linux-solo (console in $(VIRT)/solo.console)"

virt-linux: $(VIRTBIN) $(VGUEST)/vmlinux $(VGUEST)/initramfs.cpio.gz
	@$(VIRTBIN) --cpu lockstep $(VIRTLINUX) --script $(VIRT_SCRIPT) $(VIRTCACHE) --quiet \
	    --console-log $(VIRT)/lockstep-$(VIRT_CACHES).console --dump $(VIRT)/lockstep-$(VIRT_CACHES).div \
	    $(VIRT_OPTS) > $(VIRT)/lockstep-$(VIRT_CACHES).log 2>&1; \
	 grep -E '^\[lockstep\] end' $(VIRT)/lockstep-$(VIRT_CACHES).log | sed 's/^/  /'; \
	 grep -q '^PASS' $(VIRT)/lockstep-$(VIRT_CACHES).log || { grep -A12 '^DIVERGENCE' $(VIRT)/lockstep-$(VIRT_CACHES).log | head -30; tail -3 $(VIRT)/lockstep-$(VIRT_CACHES).log; exit 1; }
	@echo "PASS: virt-linux (console in $(VIRT)/lockstep-$(VIRT_CACHES).console)"

fpsp: $(VIRTBIN) $(VGUEST)/vmlinux $(VGUEST)/initramfs.cpio.gz
	@test "$(FPU)" != 0 || { echo "fpsp: the MC68040's (FPU=1); the MC68LC040 has no FPU to emulate for"; exit 1; }
	@$(VIRTBIN) --cpu lockstep $(VIRTLINUX) --script sim/virt/linux/commands-fpsp.script --quiet \
	    --console-log $(VIRT)/fpsp.console --dump $(VIRT)/fpsp.div $(VIRT_OPTS) > $(VIRT)/fpsp.log 2>&1; \
	 grep -E '^\[lockstep\] end' $(VIRT)/fpsp.log | sed 's/^/  /'; \
	 grep '^t[1-5] ' $(VIRT)/fpsp.console | sed 's/^/  /'; \
	 grep -q '^PASS' $(VIRT)/fpsp.log || { grep -A12 '^DIVERGENCE' $(VIRT)/fpsp.log | head -30; tail -3 $(VIRT)/fpsp.log; exit 1; }
	@echo "PASS: fpsp (console in $(VIRT)/fpsp.console)"

# ---------------------------------------------------------------------------
# rd-qvirt: the core as the processor of QEMU's virt machine (doc/qvirt.md;
# doc/plan.md section 7, M14). QEMU 11.1.2 ($(QEMU)) runs unmodified under
# qtest; sim/qvirt/qvirt drives its devices with the core, and the console is
# compared with QEMU's own m68040's on the same machine.
#
#   make qvirt             the harness and the core (Verilator: heavy, alone)
#   make qvirt-bare        the bare-metal programs on QEMU's devices
#   make qvirt-linux       rd-virt's Linux guest and command set on the core
#   make qvirt-linux-qemu  ... on QEMU's m68040, the reference; then
#                          qvirt-linux's console is compared with it
#
# FPU=0 is the MC68LC040: its own build, the FPU-emulating guest, the
# bootinfo's FPU record cleared on both sides. QVIRT_OPTS adds qvirt options.
# ---------------------------------------------------------------------------
QVIRTTOP    := build/qvirt
QVIRT       := $(QVIRTTOP)$(if $(filter 0,$(FPU)),/lc)
QVIRTBIN    := $(QVIRT)/obj/qvirt
QVIRTSRC    := $(wildcard sim/qvirt/*.cpp sim/qvirt/*.h) sim/qvirt/build.sh \
               sim/virt/cpu_rtl.cpp sim/virt/cpu_rtl.h sim/virt/bus_if.h sim/virt/script.h \
               sim/virt/cpu_if.h sim/virt/public.vlt
QVIRT_OPTS  ?=
QVIRTNOFPU  := $(if $(filter 0,$(FPU)),--no-fpu)
QVIRTRUN     = $(QVIRTBIN) --qemu $(CURDIR)/$(QEMU) $(QVIRTNOFPU) --quiet $(QVIRT_OPTS)
QVIRTREF     = python3 sim/qvirt/qemu-ref.py --qemu $(QEMU) $(QVIRTNOFPU)

$(QVIRTBIN): $(QVIRTSRC) $(RTL)
	@echo "  qvirt: building the core for QEMU's virt into $(QVIRT)/obj (Verilator, FPU=$(FPU), alone)"
	@RTLFILES="$(RTL)" FPU=$(FPU) sh sim/qvirt/build.sh $(QVIRT) > /dev/null

qvirt: $(QVIRTBIN)

qvirt-bare: $(QVIRTBIN) $(QEMU) $(patsubst %,build/programs/%.elf,$(VIRTPROGS))
	@ok=1; for p in $(VIRTPROGS); do D=$(QVIRT)/bare-$$p; mkdir -p $$D; \
	  $(QVIRTRUN) --dir $$D --kernel build/programs/$$p.elf --step-ns 20 --progress 0 --expect "PASS: $$p" \
	      --console-log $$D/console > $$D/log 2>&1; \
	  if grep -q '^PASS' $$D/log; then echo "  PASS: $$p -- $$(grep -o '[0-9]* steps, [0-9]* clocks' $$D/log)"; \
	  else echo "  FAIL: $$p"; tail -8 $$D/log; ok=0; fi; done; \
	test $$ok -eq 1 && echo "PASS: qvirt-bare"

qvirt-linux: $(QVIRTBIN) $(QEMU) $(VGUEST)/vmlinux $(VGUEST)/initramfs.cpio.gz
	@D=$(QVIRT)/linux; mkdir -p $$D; \
	 $(QVIRTRUN) --dir $$D --kernel $(VGUEST)/vmlinux --initrd $(VGUEST)/initramfs.cpio.gz \
	    --cmdline "$(VIRT_CMDLINE)" --script $(VIRT_SCRIPT) --expect done \
	    --console-log $$D/console > $$D/log 2>&1; \
	 grep -E '^\[qvirt\] end' $$D/log | sed 's/^/  /'; \
	 grep -q '^PASS' $$D/log || { tail -12 $$D/log; exit 1; }; \
	 if [ -f $(QVIRT)/linux-qemu/console ]; then \
	   python3 sim/qvirt/console-diff.py $(QVIRT)/linux-qemu/console $$D/console \
	       --mask sim/qvirt/linux$(if $(filter 0,$(FPU)),-lc).mask || exit 1; \
	 else echo "  (no reference console yet: make qvirt-linux-qemu)"; fi
	@echo "PASS: qvirt-linux (console in $(QVIRT)/linux/console)"

qvirt-linux-qemu: $(QEMU) $(VGUEST)/vmlinux $(VGUEST)/initramfs.cpio.gz
	@D=$(QVIRT)/linux-qemu; mkdir -p $$D; \
	 $(QVIRTREF) --dir $$D --kernel $(VGUEST)/vmlinux --initrd $(VGUEST)/initramfs.cpio.gz \
	    --cmdline "$(VIRT_CMDLINE)" --script $(VIRT_SCRIPT) --expect done --log $$D/console \
	    > $$D/log 2>&1 || { tail -8 $$D/log; exit 1; }
	@echo "PASS: qvirt-linux-qemu (console in $(QVIRT)/linux-qemu/console)"

# NetBSD/virt68k 11.0 (doc/qvirt.md), the media of Inputs/sw/MANIFEST-netbsd:
#
#   make netbsd-disk       fetched and installed on QEMU's m68040 onto
#                          build/netbsd/netbsd.img (a minute; once)
#   make netbsd-qemu       booted on QEMU's m68040 to multi-user, root logged
#                          in, sim/qvirt/netbsd-boot.script typed, powered off:
#                          the reference
#   make netbsd-qvirt      ... on the core, its console compared with the
#                          reference's (sim/qvirt/netbsd.mask) to the typed
#                          shutdown (FPU=1 only: GENERIC has no FPU emulation)
NETBSD      := build/netbsd
NBKERNEL    := $(NETBSD)/netbsd-GENERIC
NBDISK      := $(NETBSD)/netbsd.img

$(NBKERNEL): Inputs/sw/MANIFEST-netbsd sim/qvirt/netbsd.sh sim/qvirt/nbpatch.py
	@bash sim/qvirt/netbsd.sh fetch $(NETBSD)

$(NBDISK): $(NBKERNEL) $(QEMU) sim/qvirt/netbsd-install.script sim/qvirt/mksets.py sim/qvirt/qemu-ref.py
	@bash sim/qvirt/netbsd.sh disk $(NETBSD) $(QEMU)

netbsd-disk: $(NBDISK)

netbsd-qemu: $(NBDISK) $(QEMU)
	@D=$(QVIRTTOP)/netbsd-qemu; mkdir -p $$D; \
	 $(QVIRTREF) --dir $$D --kernel $(NBKERNEL) --disk $(NBDISK) --script sim/qvirt/netbsd-boot.script \
	    --expect done --log $$D/console > $$D/log 2>&1 || { tail -8 $$D/log; exit 1; }
	@echo "PASS: netbsd-qemu (console in $(QVIRTTOP)/netbsd-qemu/console)"

netbsd-qvirt: $(QVIRTBIN) $(QEMU) $(NBDISK)
	@test "$(FPU)" != 0 || { echo "netbsd-qvirt: the MC68040's (FPU=1); NetBSD/virt68k's GENERIC has no FPU emulation"; exit 1; }
	@D=$(QVIRT)/netbsd; mkdir -p $$D; \
	 $(QVIRTRUN) --dir $$D --kernel $(NBKERNEL) --disk $(NBDISK) --script sim/qvirt/netbsd-boot.script \
	    --expect done --expect halted --console-log $$D/console > $$D/log 2>&1; \
	 grep -E '^\[qvirt\] end' $$D/log | sed 's/^/  /'; \
	 grep -q '^PASS' $$D/log || { tail -12 $$D/log; exit 1; }; \
	 if [ -f $(QVIRTTOP)/netbsd-qemu/console ]; then \
	   python3 sim/qvirt/console-diff.py $(QVIRTTOP)/netbsd-qemu/console $$D/console \
	       --mask sim/qvirt/netbsd.mask --until "shutdown -p now" || exit 1; \
	 else echo "  (no reference console yet: make netbsd-qemu)"; fi
	@echo "PASS: netbsd-qvirt (console in $(QVIRT)/netbsd/console)"

# ---------------------------------------------------------------------------
# MAME's Quadra (doc/oracles.md, "MAME's Quadra"; the core goes in at M14)
#
# MAME with only macquadra800.cpp (Quadra 650/610/800, Centris 650/610),
# built from a copy of Inputs/ref/mame by sim/mame/build.sh (once; heavy,
# -j2, alone, about 25 minutes). The ROM path is made in build/mame/roms:
#   macqd800/f1acad13.rom   the user's Inputs/ref/ROMs/Quadra-650.ROM, checked
#                           against Inputs/sw/ROMS.sha256 (MAME's 23F2 BIOS)
#   macqd800/342s0440-b.bin the ADB modem's PIC firmware: Inputs/ref/ROMs/
#                           342s0440-b.bin if the user supplies it, else a
#                           zero-filled stand-in (MAME warns, and runs)
# Apple firmware: nothing here is committed or copied outside build/.
#
#   QUADRA_DISK            a SCSI disk image of the user's, by its name in
#                          Inputs/ref/ROMs/ (default mac761, System 7.6.1, when
#                          it is there): checked against Inputs/sw/ROMS-m14.sha256,
#                          copied read-only into build/mame/disks; MAME's
#                          writes go to a diff file in each run's directory,
#                          so every run boots the same disk
#   make quadra-m68040     QUADRA_MACHINE (macqd650: the Quadra 650, MAME's
#                          m68040; macct650: the Centris 650, its 68LC040) run
#                          headless from the disk, until the screen is one
#                          sim/mame/quadra-m68040.expect lists for it -- the
#                          Finder -- for three samples, or QUADRA_SECONDS
#   make quadra            the core (sim/mame/rd68041.*) as the Quadra 650's
#                          MC68040 (macqd650rd), the same run; passes when it
#                          ends on the very screen MAME's m68040 ends on
#   make quadra-lc         ... as the Centris 650's MC68LC040 (macct650rd,
#                          the FPU=0 build), against macct650
#                          (QUADRA_RD_SECONDS: 400; the core runs about 400 k
#                          clocks a second, an hour and more to the Finder)
# The screens are hashed with the menu bar's clock masked (sim/mame/quadra.lua):
# MAME's RTC starts from the host's time.
# ---------------------------------------------------------------------------
MAMEB          := build/mame
MAMEQ          := $(MAMEB)/src/quadra
MAMEQROMS      := $(MAMEB)/roms/macqd800
QUADRA_MACHINE ?= macqd650
QUADRA_SECONDS ?= 200
QUADRA_DISK    ?= $(if $(wildcard Inputs/ref/ROMs/mac761.chd),mac761)
QUADRA_STEP    ?= 10
MAMEDISK       := $(if $(QUADRA_DISK),$(MAMEB)/disks/$(QUADRA_DISK).chd)
QUADRA_MEDIA    = $(if $(QUADRA_DISK),-hard $(CURDIR)/$(MAMEDISK))
# The hashes the expect file gives a machine, for quadra.lua's QUADRA_UNTIL.
quadra-until    = $(shell awk -v m=$(1) -v d=$(or $(QUADRA_DISK),none) '$$1 == m && $$2 == d { printf "%s%s", c, $$3; c = "," }' sim/mame/quadra-m68040.expect)

$(MAMEB)/disks/%.chd: Inputs/ref/ROMs/%.chd Inputs/sw/ROMS-m14.sha256
	@grep -q " $<$$" Inputs/sw/ROMS-m14.sha256 || { echo "quadra: $< has no hash in Inputs/sw/ROMS-m14.sha256"; exit 1; }
	@sha256sum --quiet --ignore-missing -c Inputs/sw/ROMS-m14.sha256
	@mkdir -p $(MAMEB)/disks
	@rm -f $@; cp $< $@; chmod 444 $@

$(MAMEQ): sim/mame/build.sh sim/mame/quadra.patch sim/mame/patched.lst sim/mame/rd68041.h \
          sim/mame/rd68041.cpp sim/mame/rd68041_vlt.h
	@echo "  mame-quadra: building MAME's macquadra800 driver into $(MAMEB)/src (-j2, alone; 25 min from clean)"
	@JOBS=2 bash sim/mame/build.sh mame $(MAMEB) | sed 's/^/  /'

# The core as the shared object MAME's rd68041_device loads (M14): the
# MC68040's build, and the MC68LC040's.
MAMEVLT        := $(MAMEB)/vlt$(if $(filter 0,$(FPU)),-lc)/rd68041_vlt.so
$(MAMEB)/vlt/rd68041_vlt.so $(MAMEB)/vlt-lc/rd68041_vlt.so: sim/mame/build.sh sim/mame/rd68041_vlt.cpp \
          sim/mame/rd68041_vlt.h sim/virt/public.vlt $(RTL)
	@echo "  quadra: building the core for MAME into $(dir $@) (Verilator, FPU=$(FPU), alone)"
	@RTLFILES="$(RTL)" FPU=$(FPU) bash sim/mame/build.sh vlt $(dir $@) | sed 's/^/  /'

$(MAMEQROMS)/f1acad13.rom: Inputs/ref/ROMs/Quadra-650.ROM Inputs/sw/ROMS.sha256
	@sha256sum --quiet -c Inputs/sw/ROMS.sha256
	@mkdir -p $(MAMEQROMS)
	@cp $< $@

$(MAMEQROMS)/342s0440-b.bin: $(wildcard Inputs/ref/ROMs/342s0440-b.bin)
	@mkdir -p $(MAMEQROMS)
	@if [ -f Inputs/ref/ROMs/342s0440-b.bin ]; then sha256sum --quiet --ignore-missing -c Inputs/sw/ROMS-m14.sha256 \
	      && cp Inputs/ref/ROMs/342s0440-b.bin $@; \
	 else echo "  quadra: no 342s0440-b.bin (the ADB modem's firmware): a zero-filled stand-in"; \
	      head -c 1024 /dev/zero > $@; fi

mame-quadra: $(MAMEQ)

quadra-m68040: $(MAMEQ) $(MAMEQROMS)/f1acad13.rom $(MAMEQROMS)/342s0440-b.bin $(MAMEDISK)
	$(call quadra-run,$(QUADRA_MACHINE),$(QUADRA_MACHINE),,$(QUADRA_SECONDS))

# quadra-run MACHINE REFERENCE VLT SECONDS: MACHINE booted from the disk until
# it holds one of the screens the expect file gives REFERENCE (or SECONDS),
# with the core's shared object VLT when it is one of the core's machines.
QUADRA_RD_SECONDS ?= 400
define quadra-run
	@$(if $(3),RD68041_VLT=$(CURDIR)/$(3)) QUADRA_STEP=$(QUADRA_STEP) QUADRA_UNTIL=$(call quadra-until,$(2)) \
	    MAMEARGS="$(QUADRA_MEDIA)" MAMEDIR=$(CURDIR)/$(MAMEB) bash sim/mame/quadra.sh $(1) \
	    $(CURDIR)/$(MAMEB)/run/$(1) $(4) || { tail -5 $(MAMEB)/run/$(1)/mame.out; exit 1; }
	@D=$(MAMEB)/run/$(1); grep -h '^rd68041:\|^emulated time\|^wall' $$D/mame.out | sed 's/^/  /'; \
	 awk '{print "t " $$1 " pc " $$2 " sr " $$3 " screen " $$4}' $$D/samples.txt | uniq -f7 -c \
	   | awk '{c = $$1; $$1 = ""; print "  " c " samples from" $$0}'; \
	 last=$$(tail -1 $$D/samples.txt | cut -d' ' -f4); \
	 n=$$(tail -3 $$D/samples.txt | cut -d' ' -f4 | sort -u | wc -l); \
	 what=$$(awk -v m=$(2) -v d=$(or $(QUADRA_DISK),none) -v h=$$last '$$1 == m && $$2 == d && $$3 == h { $$1 = $$2 = $$3 = ""; print substr($$0, 4) }' \
	        sim/mame/quadra-m68040.expect); \
	 if [ $$n -eq 1 ] && [ -n "$$what" ]; then echo "PASS: $@ ($(1), disk $(or $(QUADRA_DISK),none): $$what, the screen MAME's $(2) ends on; $$D/snap/)"; \
	 else echo "FAIL: $@ (last screen $$last, not stable or not $(2)'s in sim/mame/quadra-m68040.expect; $$D/snap/)"; exit 1; fi
endef

quadra: $(MAMEQ) $(MAMEQROMS)/f1acad13.rom $(MAMEQROMS)/342s0440-b.bin $(MAMEB)/vlt/rd68041_vlt.so $(MAMEDISK)
	$(call quadra-run,macqd650rd,macqd650,$(MAMEB)/vlt/rd68041_vlt.so,$(QUADRA_RD_SECONDS))

quadra-lc: $(MAMEQ) $(MAMEQROMS)/f1acad13.rom $(MAMEQROMS)/342s0440-b.bin $(MAMEDISK)
	@$(MAKE) --no-print-directory $(MAMEB)/vlt-lc/rd68041_vlt.so FPU=0
	$(call quadra-run,macct650rd,macct650,$(MAMEB)/vlt-lc/rd68041_vlt.so,$(QUADRA_RD_SECONDS))

print-rtl:
	@echo $(RTL)

clean:
	rm -rf $(BUILD)
