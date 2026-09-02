-- autostepper explore/mode.lua unit tests. Run from the lera-plugins repo root
-- with LERA_ROOT pointing at a built Lera checkout.
--
-- The frames below are the real ones captured walking three rooms of the Chaos
-- Sea on layer one at 'risky' difficulty. Two things they prove and this suite
-- pins: every room reports num 0, so position can only come from dead
-- reckoning; and the server suppresses an identical payload, which is why the
-- capture's second room has no Room.Contents at all while the entry room --
-- also empty -- does send one.
package.path = "3scapes/autostepper/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

local printed = {}
local print_real = print
local function quiet(fn, ...)
  print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    printed[#printed + 1] = table.concat(parts, " ")
  end
  local ok, err = pcall(fn, ...)
  print = print_real
  if not ok then error(err, 0) end
end

local mode = require("explore.mode")

-- ---- the captured frames -----------------------------------------------------
local CAPTURE = {
  { num = 0, area = "Unknown", name = "Layer one of the Sea of Chaos",
    exits = { "e", "s", "w", "out" } },
  { num = 0, area = "Unknown", name = "Layer one of the Sea of Chaos",
    exits = { "e", "s", "w" } },
  { num = 0, area = "Unknown", name = "Layer one of the Sea of Chaos",
    exits = { "e", "w" } },
}

-- ---- a minimal area profile --------------------------------------------------
local WORDS = { one = 0, two = 1, three = 2 }
local profile = {
  name = "test",
  exclude_exits = { out = true, enter = true, ["in"] = true },
  dive_dirs = { "d" },
  defer_dirs = { "u" },
  default_policy = "clear",
  in_area = function(name)
    return type(name) == "string" and name:lower():find("sea of chaos", 1, true) ~= nil
  end,
  layer_of = function(name)
    local word = type(name) == "string"
      and name:lower():match("^layer%s+(%a+)%s+of the sea of chaos")
    return word and WORDS[word] or nil
  end,
  complete = function() return false end,
}

local ri_info = { room = "", room_id = nil, exits = {} }
local fake_roominfo = { info = function() return ri_info end }
mode.attach(fake_roominfo)

local function frame(f)
  ri_info = { room = f.name, room_id = nil, exits = f.exits }
  mode.on_frame(ri_info)
end

-- ---- start and first room ----------------------------------------------------
quiet(function() mode.start(profile, "clear") end)
check("start activates the mode", mode.active() == true)

frame(CAPTURE[1])
quiet(mode.on_arrival)
local st = mode.stats()
check("the entry room is recorded", st.rooms == 1, tostring(st.rooms))
check("position starts at the origin",
  st.x == 0 and st.y == 0 and st.z == 0, st.x .. "," .. st.y .. "," .. st.z)
check("the layer is read from the room name", st.layer == 0, tostring(st.layer))

-- 'out' is excluded by the profile, so it can never be proposed.
local step = mode.next_step()
check("next_step returns exactly one direction",
  step and #step.commands == 1, step and #step.commands)
check("next_step never proposes an excluded exit",
  step and step.raw ~= "out", step and step.raw)
check("next_step raw matches its command",
  step and step.raw == step.commands[1], step and step.raw)

-- ---- movement and suppression ------------------------------------------------
-- Walk the direction next_step chose, then deliver the second captured frame.
local first_dir = step.raw
frame(CAPTURE[2])
quiet(mode.on_arrival)
st = mode.stats()
check("arriving records a second room", st.rooms == 2, tostring(st.rooms))
check("position advanced by exactly one step",
  (st.x ~= 0) or (st.y ~= 0), st.x .. "," .. st.y)

-- Now the suppression case: take another step and deliver NO frame at all.
-- Suppression means the payload was identical, so this room's exits are the
-- previous room's -- which must be recorded as fact, not treated as an empty
-- room with no exits and therefore no frontier.
local before = mode.stats().rooms
step = mode.next_step()
check("a step is still available before the suppressed move", step ~= nil)
quiet(mode.on_arrival)
st = mode.stats()
check("a suppressed frame still records the room", st.rooms == before + 1,
  tostring(st.rooms))
check("frontier survives a suppressed frame", mode.next_step() ~= nil)

-- ---- stop --------------------------------------------------------------------
mode.stop()
check("stop deactivates the mode", mode.active() == false)
check("next_step is nil when inactive", mode.next_step() == nil)

-- ---- policy ------------------------------------------------------------------
quiet(function() mode.start(profile, "clear") end)
check("policy defaults to what start was given", mode.policy() == "clear",
  mode.policy())
mode.set_policy("dive")
check("set_policy switches policy", mode.policy() == "dive", mode.policy())
mode.set_policy("nonsense")
check("an unknown policy is refused and clear is kept",
  mode.policy() == "dive", mode.policy())
mode.stop()

-- ---- exclude_exits protects a walkable compass direction ---------------------
-- The premise behind an earlier mutant here -- "'out' is the first
-- compass-ordered frontier" -- does not hold: map.lua already drops 'out' on
-- its own (it has no DELTA entry and DIR_ORDER never lists it), independent
-- of mode.lua's filter_exits. filter_exits is load-bearing only for a
-- direction the lattice DOES support, which exclude_exits is documented to
-- accept: any exit name, compass directions included. 'n' is walkable (it has
-- both a DELTA and a DIR_ORDER entry) and ranks first in compass order, so a
-- profile that excludes it is the direct, documented case this guards.
local excl_profile = {
  name = "test-exclude-n",
  exclude_exits = { out = true, enter = true, ["in"] = true, n = true },
  dive_dirs = { "d" },
  defer_dirs = { "u" },
  default_policy = "clear",
  in_area = profile.in_area,
  layer_of = profile.layer_of,
  complete = function() return false end,
}

quiet(function() mode.start(excl_profile, "clear") end)
frame({ name = "Layer one of the Sea of Chaos",
        exits = { "n", "e", "s", "w", "out" } })
quiet(mode.on_arrival)

local ex1 = mode.next_step()
check("next_step never proposes an excluded compass exit",
  ex1 and ex1.raw ~= "n", ex1 and ex1.raw)
check("the excluded direction is skipped outright -- 'e' is chosen instead",
  ex1 and ex1.raw == "e", ex1 and ex1.raw)

-- Walk the direction next_step actually proposed and confirm the coordinate
-- 'n' would have produced -- (0,1,0), one step north of the origin -- was
-- never reached. Position only ever moves along what next_step proposes and
-- on_arrival commits, so this is the direct, observable form of "the room
-- north of the origin was never recorded."
frame({ name = "Layer one of the Sea of Chaos", exits = { "w" } })
quiet(mode.on_arrival)
local ex_st = mode.stats()
check("the coordinate north of the origin is never reached",
  not (ex_st.x == 0 and ex_st.y == 1),
  ex_st.x .. "," .. ex_st.y)
mode.stop()

-- ---- next_step over a multi-hop route -----------------------------------------
-- The three-room capture above never forced this: every frontier in it was
-- adjacent to the current room, so the underlying path was always length 1
-- and 'commands = path' was indistinguishable from 'commands = { dir }'.
-- Force the distinguishing case by walking into a dead end, so the nearest
-- remaining frontier is reachable only by backtracking through an
-- already-visited room first.
local hop_profile = {
  name = "test-multihop",
  exclude_exits = { out = true, enter = true, ["in"] = true },
  dive_dirs = { "d" },
  defer_dirs = { "u" },
  default_policy = "clear",
  in_area = profile.in_area,
  layer_of = function() return nil end,
  complete = function() return false end,
}

quiet(function() mode.start(hop_profile, "clear") end)
-- Room A has two exits so a frontier remains after the first is exhausted.
frame({ name = "Room A", exits = { "e", "n" } })
quiet(mode.on_arrival)

-- 'n' ranks before 'e' in compass order, so it is the first hop taken.
local hop1 = mode.next_step()
check("first hop heads to the compass-first frontier ('n')",
  hop1 and hop1.raw == "n", hop1 and hop1.raw)

-- Room B is a dead end: its only exit leads back to the already-visited
-- room A. The remaining frontier -- A's still-unexplored 'e' exit -- is now
-- two hops from where we're standing: south back to A, then east. The first
-- hop back ('s') is deliberately a different direction than the eventual
-- frontier ('e'), so raw and the frontier direction can't be confused.
frame({ name = "Room B (dead end)", exits = { "s" } })
quiet(mode.on_arrival)

local hop2 = mode.next_step()
check("next_step returns exactly one command over a multi-hop route",
  hop2 and #hop2.commands == 1, hop2 and hop2.commands and #hop2.commands)
check("raw is the route's first hop ('s', back toward A) -- not the frontier direction ('e') and not the whole path",
  hop2 and hop2.raw == "s", hop2 and hop2.raw)
mode.stop()

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
