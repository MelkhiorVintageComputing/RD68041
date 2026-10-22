-- SPDX-License-Identifier: CERN-OHL-S-2.0
-- Copyright 2026 Romain Dolbeau
-- Source location: https://github.com/MelkhiorVintageComputing/RD68041
--
-- MAME autoboot script for sim/mame/quadra.sh (M0 spike 4, `make quadra-m68040`;
-- doc/oracles.md, "MAME's Quadra"). Every QUADRA_STEP emulated seconds it
-- saves the screen as snap/NNNN.png and prints one line,
--     sample <n> t <emulated s> pc <hex> sr <hex>
-- then, at QUADRA_SECONDS, prints "emulated time" and leaves MAME cleanly.
-- The PNGs are compared by quadra.sh, which needs no Lua to hash pixels.
local step = tonumber(os.getenv("QUADRA_STEP") or "1")
local stop = tonumber(os.getenv("QUADRA_SECONDS") or "30")
local nexts = step
local n = 0
local cpu = manager.machine.devices[":maincpu"]
local scr = manager.machine.screens:at(1)
emu.register_periodic(function()
  local t = manager.machine.time:as_double()
  if t < nexts then return end
  nexts = nexts + step
  n = n + 1
  local pc = cpu.state["PC"].value
  local sr = cpu.state["SR"].value
  scr:snapshot(string.format("%04d.png", n))
  print(string.format("sample %d t %.3f pc %08x sr %04x", n, t, pc, sr))
  io.stdout:flush()
  if t >= stop then
    print(string.format("emulated time: %.3f s", t))
    manager.machine:exit()
  end
end)
