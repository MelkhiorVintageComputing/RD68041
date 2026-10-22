# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041

# RD68041 timing constraints.
#
# 33.333 ns, 30 MHz: BCLK. The MC68040's grades are 25, 33 and 40 MHz (the
# MC68LC040 adds 20); the goal is at least 20 MHz and preferably 25 or more
# (CLAUDE.md), and this asks for margin above that. The constraint is what the
# tools work to, not only what they check: RD68031 measured Vivado stopping once
# it had met a loose constraint and reporting less than the design could make.
#
# Single-edge design: the duty cycle does not matter to any path.

create_clock -period 33.333 -name clk -waveform {0.000 16.667} [get_ports clk]

# rst_n is asynchronous by construction and is not timed.
set_false_path -from [get_ports rst_n]
