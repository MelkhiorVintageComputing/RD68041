# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041

# Vivado place and route, for the numbers that mean something.
#
#   vivado -mode batch -source scripts/impl.tcl \
#          -tclargs <part> <top> <repo-root> <fpu>
#
# `make synth` reports post-synthesis timing, which is an estimate: most of a
# path's delay on this fabric is routing, and before placement the router's
# contribution is a guess. This runs the real thing, so doc/implementation.md can
# quote a number that survives contact with the fabric.
#
# Out of context, like the synthesis: this is a core, not a board design.
# Hierarchy is kept, so that the per-module utilisation means something and so
# that a path report can name module pins.

set part   [lindex $argv 0]
set top    [lindex $argv 1]
set root   [lindex $argv 2]
set fpu    [lindex $argv 3]

# The host has 15 GB and no swap (CLAUDE.md): never more than four threads.
set_param general.maxThreads 4

puts "RD68041: implementing $top for $part, FPU=$fpu"

set f [open rtl.f r]
set rtl [split [string trim [read $f]] "\n"]
close $f

# A signal used before its declaration is only an info in Vivado. tools/src_lint.py
# catches it in `make lint`; this makes the vendor run agree.
set_msg_config -id "Synth 8-6901" -new_severity ERROR

read_verilog -sv $rtl
read_xdc $root/scripts/rd68041.xdc

synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy none \
             -generic FPU=$fpu
opt_design
place_design
phys_opt_design
route_design

report_utilization              -file impl_utilization.rpt
report_utilization -hierarchical -file impl_utilization_hier.rpt
report_ram_utilization          -file impl_ram.rpt
report_timing_summary -delay_type max -max_paths 20 -file impl_timing.rpt

# One path per endpoint with a distinct pin set: twenty FAMILIES rather than the
# same path twenty times over. tools/timing/paths.py groups the file.
report_timing -delay_type max -max_paths 400 -unique_pins -nworst 1 \
    -file impl_timing_families.rpt

write_checkpoint -force ${top}_impl.dcp

set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]

puts "RD68041: routed worst negative slack = $wns ns (hold $whs ns)"
source $root/scripts/fmax.tcl
rd_report_fmax RD68041
puts "RD68041: cells (primitives, not the report's Slice LUTs): LUT [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]] \
     LUTRAM [llength [get_cells -hier -filter {PRIMITIVE_GROUP == DMEM}]] \
     FF [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]] \
     CARRY [llength [get_cells -hier -filter {PRIMITIVE_GROUP == CARRY}]] \
     DSP [llength [get_cells -hier -filter {REF_NAME =~ DSP*}]] \
     BRAM [llength [get_cells -hier -filter {REF_NAME =~ RAMB*}]]"

if {$wns < 0 || $whs < 0} {
    puts "RD68041: TIMING NOT MET"
    exit 1
}
puts "RD68041: implementation ok"
exit 0
