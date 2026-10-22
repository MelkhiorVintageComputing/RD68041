# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041

# The clock period the design can actually run at, from the paths Vivado reports.
#
# Sourced by impl.tcl. This design is single-edge (doc/coding-standard.md), so
# every path's requirement should be the whole period; the computation is kept
# from RD68031, where half-period paths existed, because it costs nothing and
# stays right if a path with another requirement (a multicycle, a false path
# made true) ever appears: a path that needs d nanoseconds of a requirement r
# that is a fraction r/T of the period needs a period of d * T / r.

proc rd_fmax {{n 4000}} {
    set period [get_property PERIOD [get_clocks clk]]
    set worst 0.0
    set wp {}
    foreach p [get_timing_paths -delay_type max -max_paths $n -nworst 1] {
        set req [get_property REQUIREMENT $p]
        set sl  [get_property SLACK $p]
        if {$req <= 0} { continue }
        set need [expr {($req - $sl) * $period / $req}]
        if {$need > $worst} { set worst $need; set wp $p }
    }
    return [list $worst $wp]
}

proc rd_report_fmax {tag} {
    lassign [rd_fmax] need p
    puts [format "%s: needs a period of %.2f ns -- %.2f MHz" $tag $need [expr {1000.0 / $need}]]
    puts "$tag: limited by [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p]\
          ([get_property LOGIC_LEVELS $p] levels, requirement [get_property REQUIREMENT $p] ns)"
    return $need
}
