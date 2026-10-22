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
PKGS    := rtl/rd68041_pkg.sv
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
        rtl/rd68041_agu.sv \
        rtl/rd68041_shifter.sv \
        rtl/rd68041_divider.sv \
        rtl/rd68041_bitfield.sv \
        rtl/rd68041_top.sv

RTL  := $(PKGS) $(GENPKG) $(GENSRC) $(SRCS)
VLT  := rtl/rd68041.vlt

IVFLAGS := -g2012 -Wall -Wno-timescale -DTB_FPU=$(FPU)

.PHONY: all help dirs lint lint-source lint-iverilog lint-verilator lint-yosys \
        lint-quartus lint-questa quartus synth impl audit sim sim-bus check \
        check-lc spike ucode ucode-check print-rtl clean uae040 uae040-smoke cputest-gen

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
TBS := $(patsubst sim/tb/%.sv,%,$(wildcard sim/tb/*_tb.sv))
MODELS := $(wildcard sim/models/*.sv)
SIMJOBS ?= 4

sim: dirs
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

uae040: $(O40BUILD)/uae040_trace

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
# WinUAE's cputest corpus for the MC68040
#
# cputestgen (built out of tree into build/cputest/gen/ by
# tools/cputest/build.sh) writes the integer corpus from CPUTEST_INI into
# build/cputest/run/data/ and the FPU corpus from CPUTEST_FPU_INI into
# build/cputest/fpu/data/, one instruction per generator run
# (tools/cputest/generate.sh). tools/cputest/convert.py summary then decodes
# every test and counts them (build/cputest/summary.txt). There is no bench
# yet (M7).
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

print-rtl:
	@echo $(RTL)

clean:
	rm -rf $(BUILD)
