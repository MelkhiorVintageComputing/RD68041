# Making it smaller, and making it faster

Each row is a before-and-after on the same tree with one change, from `make impl`
(Artix-7) and `make quartus` (Cyclone V).

| change | kept | what it was worth |
|---|:--:|---|
| **M4 frequency spike** (`make spike`, `sim/spike/rd68041_spike.sv`): the design's ATCs, cache arrays, register file, address adder, shifter and bus unit in the pipeline's arrangement, with stand-in control | measurement | Artix-7 xc7a100t-1, out of context, 33.333 ns constraint: **4,357 LUTs** (600 as memory), 2,176 FFs, 18 RAMB tiles, **21.17 ns, 47.23 MHz**. Limited by OF, the data ATC through the tag compare and way select into the aligner (19 levels); then EX's branch into the instruction cache's RAM address (19.47 ns), IF2 (18.87 ns), EX's ALU (14.61 ns), EA into the data cache's RAM address (13.62 ns) |
| the block RAM written a byte lane per process | no | Vivado could not infer a RAM ("multiple writes via different ports in same process") and built all eight cache ways from registers: 32 minutes in timing optimisation and over 5 GB before the host ran out. One process per port, lanes written out, fixed it (`rtl/rd68041_bram.sv`) |
| the decoder's addressing modes worked out once, outside the decode case (`ea_of`, `DEC_EA`/`DEC_IND`/`DEC_SRC`), instead of about 69 inlined calls in it | yes | yosys on `rd68041_decode` alone: **20 m 47 s and 3.9 GB → 57 s and 450 MB** (19,008 cells). `proc_mux` had taken 93 % of the time on one process of 24,283 signals; it had made `make check` take 86 minutes |
| **M9: the whole processor, caches in** (`make impl`, `c701b41`) | measurement | Artix-7 xc7a100t-1, 33.333 ns constraint: routed slack +1.807 ns, **31.53 ns, 31.72 MHz**; 19,740 LUTs, 996 LUTRAM, 4,949 FFs, 591 CARRY, 10 DSP, 16 BRAM; 5 minutes, 2.4 GB. Limited by instruction fetch: the queue's head into a queue entry's enable (25 levels) -- the cache hit's up-to-four words placed at the tail |
| **M10: the MMU in** (`make impl`, `3d6fd5d`) | measurement | Artix-7 xc7a100t-1, 33.333 ns constraint: routed slack +2.023 ns, **31.31 ns, 31.94 MHz**; 23,600 LUTs, 2,040 LUTRAM, 6,661 FFs, 646 CARRY, 10 DSP, 16 BRAM -- the two ATCs (LUT RAM), the walker and the write-fault frame's capture add about 3,900 LUTs and 1,700 FFs to M9. Limited by the data memory unit's state into an instruction-queue entry's enable (33 levels): whether the write queue is empty holds write-back, and so what the queue takes. The ATC in front of the fast read's tag compare is not the limit |

*Started fresh at M0. The first row is M4's frequency spike.*
