# Making it smaller, and making it faster

Each row is a before-and-after on the same tree with one change, from `make impl`
(Artix-7) and `make quartus` (Cyclone V).

| change | kept | what it was worth |
|---|:--:|---|
| **M4 frequency spike** (`make spike`, `sim/spike/rd68041_spike.sv`): the design's ATCs, cache arrays, register file, address adder, shifter and bus unit in the pipeline's arrangement, with stand-in control | measurement | Artix-7 xc7a100t-1, out of context, 33.333 ns constraint: **4,357 LUTs** (600 as memory), 2,176 FFs, 18 RAMB tiles, **21.17 ns, 47.23 MHz**. Limited by OF, the data ATC through the tag compare and way select into the aligner (19 levels); then EX's branch into the instruction cache's RAM address (19.47 ns), IF2 (18.87 ns), EX's ALU (14.61 ns), EA into the data cache's RAM address (13.62 ns) |
| the block RAM written a byte lane per process | no | Vivado could not infer a RAM ("multiple writes via different ports in same process") and built all eight cache ways from registers: 32 minutes in timing optimisation and over 5 GB before the host ran out. One process per port, lanes written out, fixed it (`rtl/rd68041_bram.sv`) |

*Started fresh at M0. The first row is M4's frequency spike.*
