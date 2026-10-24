-- SPDX-License-Identifier: CERN-OHL-S-2.0
-- Copyright 2026 Romain Dolbeau
-- Source location: https://github.com/MelkhiorVintageComputing/RD68041
--
-- MAME autoboot script for sim/mame/quadra.sh (M0 spike 4, M14; doc/oracles.md,
-- "MAME's Quadra"). Every QUADRA_STEP emulated seconds it saves the screen as
-- snap/NNNN.png and prints one line,
--     sample <n> t <emulated s> pc <hex> sr <hex> screen <hash>
-- the hash an FNV-1a of the screen's pixels with the menu bar's clock masked
-- out (x >= 448, y < 20): MAME's RTC starts from the host's time, so the
-- clock is the one part of a Mac OS screen that is not the same from one run
-- to the next. It stops at QUADRA_SECONDS, or earlier once the screen has had
-- one of the hashes in QUADRA_UNTIL (a comma list) for QUADRA_UNTIL_N (3)
-- samples in a row -- the core is slow, and the end of a boot is a screen.
local step = tonumber(os.getenv("QUADRA_STEP") or "1")
local stop = tonumber(os.getenv("QUADRA_SECONDS") or "30")
local until_set = {}
for h in string.gmatch(os.getenv("QUADRA_UNTIL") or "", "[^,]+") do until_set[h] = true end
local until_n = tonumber(os.getenv("QUADRA_UNTIL_N") or "3")
local held = 0
local nexts = step
local n = 0
local cpu = manager.machine.devices[":maincpu"]
local scr = manager.machine.screens:at(1)

local function screen_hash()
  local px, w, h = scr:pixels()
  local hv = 2166136261
  local rowfmt = string.rep("I4", w)
  for y = 0, h - 1 do
    local row = { string.unpack(rowfmt, px, y * w * 4 + 1) }
    local last = (y < 20) and math.min(w, 448) or w
    for x = 1, last do
      hv = ((hv ~ row[x]) * 16777619) & 0xffffffff
    end
  end
  return string.format("%08x", hv)
end

emu.register_periodic(function()
  local t = manager.machine.time:as_double()
  if t < nexts then return end
  nexts = nexts + step
  n = n + 1
  local pc = cpu.state["PC"].value
  local sr = cpu.state["SR"].value
  scr:snapshot(string.format("%04d.png", n))
  local hs = screen_hash()
  print(string.format("sample %d t %.3f pc %08x sr %04x screen %s", n, t, pc, sr, hs))
  io.stdout:flush()
  if until_set[hs] then held = held + 1 else held = 0 end
  if t >= stop or held >= until_n then
    print(string.format("emulated time: %.3f s", t))
    manager.machine:exit()
  end
end)
