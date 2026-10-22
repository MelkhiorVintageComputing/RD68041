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
        rtl/rd68041_biu.sv \
        rtl/rd68041_shifter.sv \
        rtl/rd68041_divider.sv \
        rtl/rd68041_bitfield.sv \
        rtl/rd68041_top.sv

RTL  := $(PKGS) $(GENPKG) $(GENSRC) $(SRCS)
VLT  := rtl/rd68041.vlt

IVFLAGS := -g2012 -Wall -Wno-timescale -DTB_FPU=$(FPU)

.PHONY: all help dirs lint lint-source lint-iverilog lint-verilator lint-yosys \
        lint-quartus lint-questa quartus synth impl audit sim sim-bus check \
        check-lc print-rtl clean

all: lint

help:
	@echo "RD68041 -- SystemVerilog MC68040 / MC68LC040"
	@echo
	@echo "The gate:"
	@echo "  make check       lint, audit and sim, then lint and audit again with FPU=0"
	@echo "  make lint        elaborate every rtl module under iverilog, Verilator and yosys"
	@echo "  make audit       prove no register initialises outside reset"
	@echo "  make sim         the directed testbenches"
	@echo "  make sim-bus     ... just the bus-level ones"
	@echo
	@echo "Vendor tools, tens of minutes each:"
	@echo "  make impl         Vivado place and route ($(XPART)), out of context"
	@echo "  make synth        Vivado synthesis only"
	@echo "  make quartus      Quartus fit and timing ($(AFAMILY) $(APART))"
	@echo "  make lint-quartus Quartus analysis and synthesis"
	@echo "  make lint-questa  Questa vlog + vopt"
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
# The gate. The MC68LC040 build is elaborated and audited too, in its own
# build directory, so that FPU=0 cannot rot unseen.
# ---------------------------------------------------------------------------
check: lint audit sim check-lc
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

print-rtl:
	@echo $(RTL)

clean:
	rm -rf $(BUILD)
