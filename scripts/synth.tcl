# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041

# Vivado out-of-context synthesis.
#
#   vivado -mode batch -source scripts/synth.tcl \
#          -tclargs <build> <top> <part> <fpu>
#
# Out of context because this is a processor core, not a board design: there are no
# pads, no I/O buffers and no board constraints, and the numbers are about the logic.

set build   [lindex $argv 0]
set top     [lindex $argv 1]
set part    [lindex $argv 2]
set fpu     [lindex $argv 3]

# The host has 15 GB and no swap (CLAUDE.md): never more than four threads.
set_param general.maxThreads 4

# A signal used before its declaration is only [Synth 8-6901], an *info* message, and
# a design can carry one for months without anyone seeing it. Questa rejects the same
# thing outright, so make Vivado agree.
set_msg_config -id {Synth 8-6901} -new_severity ERROR

# [Synth 8-3332] is NOT promoted. It reads like an implicit-declaration warning
# and is not: it is "sequential element ... is unused and will be removed", which
# is ordinary optimisation and is the normal state of a design whose upper units
# are still stubs. Promoting it failed a perfectly good synthesis run.

set fp [open $build/rtl.f r]
set files [split [string trim [read $fp]] "\n"]
close $fp

foreach f $files {
    if {[string length [string trim $f]] > 0} {
        read_verilog -sv $f
    }
}

read_xdc scripts/rd68041.xdc

synth_design -top $top -part $part -mode out_of_context \
    -generic FPU=$fpu

write_checkpoint -force $build/${top}_synth.dcp
report_utilization -file $build/${top}_synth_util.rpt
report_timing_summary -file $build/${top}_synth_timing.rpt

# A one-line summary, so a run that is only being sanity-checked does not need the
# reports opened. A skeleton with no logic between flops has no timing paths at all,
# which is not an error -- it is what a design that has not been built yet looks
# like -- so do not let reporting it fail the run.
set paths [get_timing_paths -delay_type max -quiet]
if {[llength $paths] > 0} {
    puts [format "SYNTH: part %s  WNS %s ns" $part [get_property SLACK [lindex $paths 0]]]
} else {
    puts "SYNTH: part $part  no timing paths (nothing between flops yet)"
}
# DSP and block RAM by cell name, as impl.tcl counts them: Vivado 2025.2 has no
# PRIMITIVE_GROUP called ARITHMETIC or BLOCKRAM, and the filters that asked for
# them reported 0 DSP and 0 BRAM for a netlist with 4 and 6 (measured, M15).
puts [format "SYNTH: LUT %s  FF %s  DSP %s  BRAM %s" \
    [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]] \
    [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]] \
    [llength [get_cells -hier -quiet -filter {REF_NAME =~ DSP*}]] \
    [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB*}]]]
