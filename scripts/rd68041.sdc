# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68041

# Quartus timing constraints. Mirrors scripts/rd68041.xdc.
#
# derive_clock_uncertainty is added explicitly because Quartus adds none by default
# where Vivado does; without it the two tools are not reporting the same thing.

create_clock -period 33.333 -name clk -waveform {0.000 16.667} [get_ports clk]
derive_clock_uncertainty

set_false_path -from [get_ports rst_n]
