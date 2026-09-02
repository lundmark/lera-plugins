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

-- ---- start seeds itself from the room we are standing in ---------------------
-- On the real path the entry room's Room.Info arrives when the player WALKS
-- INTO the area, which is before explore mode is started, and the server never
-- resends an identical payload -- so there may be no further frame at all. A
-- mode that waits for one records its origin with no exits, finds no frontier,
-- and ends the run on its first decision: the whole feature, dead. Note that no
-- frame is delivered anywhere in this section; start() has to read roominfo.
ri_info = { room = "Layer one of the Sea of Chaos", room_id = nil,
            exits = { "e", "s", "w", "out" } }
quiet(function() mode.start(profile, "clear") end)
quiet(mode.on_arrival)
local seed_st = mode.stats()
check("the seeded origin records exactly one room", seed_st.rooms == 1,
  tostring(seed_st.rooms))
check("start seeds the origin's exits from roominfo, so a frontier exists",
  mode.next_step() ~= nil, "no frontier")
check("start seeds the room name from roominfo, so the layer is known",
  seed_st.layer == 0, tostring(seed_st.layer))
mode.stop()

-- The seeded exits go through the same exclusion filter a delivered frame does.
-- 'n' is walkable and ranks first in compass order, so a profile excluding it
-- is the case that distinguishes a filtered seed from a raw one.
ri_info = { room = "Layer one of the Sea of Chaos", room_id = nil,
            exits = { "n", "e" } }
quiet(function() mode.start(excl_profile, "clear") end)
quiet(mode.on_arrival)
local seed_ex = mode.next_step()
check("a seeded exit the profile excludes is never proposed",
  seed_ex and seed_ex.raw == "e", seed_ex and seed_ex.raw)
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
  -- A real layer, not nil: this section only walks 'e'/'n'/'s', so z stays
  -- reckoned at 0 throughout and a constant-0 layer never disagrees with it
  -- (no correction ever fires here). Layer is incidental to what this section
  -- tests (multi-hop routing) -- an always-nil layer_of used to make this the
  -- first place a mutated (guard-dropped) layer check reached a nil layer,
  -- which crashed inside the topology check's map:room() before the actual
  -- "unparseable layer" test ever got to run.
  layer_of = function() return 0 end,
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

-- ---- z is read from the room name, not dead-reckoned -------------------------
-- Every z/layer assertion above sits at the origin room, where pending_dir is
-- nil, map:move never runs, and dead reckoning (z stays 0) and the
-- name-derived layer (also 0 for "Layer one...") are indistinguishable. No
-- fixture above ever takes a "d" or "u" step, so the layer-override block in
-- on_arrival -- the entire reason this module reads z from the room name
-- instead of the vertical delta -- has never actually been exercised.
--
-- The maze's set_level_exit_pairs((["down":"up"])) makes "down" the level-UP
-- direction, so a "d" step must INCREASE z. Dead reckoning alone would give
-- z = -1 here; only the name-derived layer gives the correct z = 1 -- that
-- is what discriminates a correct implementation from one that either
-- skips the override or gets its sign backwards.
quiet(function() mode.start(profile, "clear") end)
frame({ name = "Layer one of the Sea of Chaos", exits = { "d" } })
quiet(mode.on_arrival)

local before_corrections = mode.stats().layer_corrections
local vstep = mode.next_step()
check("the only exit -- 'd' -- is the one taken", vstep and vstep.raw == "d",
  vstep and vstep.raw)

frame({ name = "Layer two of the Sea of Chaos", exits = { "u" } })
quiet(mode.on_arrival)
local vst = mode.stats()
check("z is read from the room name, not the vertical delta -- a 'd' step still increases z",
  vst.z == 1, tostring(vst.z))
check("layer_corrections increments when the name overrides dead reckoning",
  vst.layer_corrections == before_corrections + 1, tostring(vst.layer_corrections))
mode.stop()

-- ---- the room name is the authority for z ------------------------------------
-- Not a desync: the profile reads an absolute layer out of the room name, so a
-- reckoned z that differs is corrected, not disputed. The area this exists for
-- inverts up/down (its level-exit override makes "down" increase z), which is
-- exactly why the vertical delta is never trusted.
quiet(function() mode.start(profile, "clear") end)
frame(CAPTURE[1])
quiet(mode.on_arrival)
local before_desyncs = mode.desyncs()
step = mode.next_step()
check("a step is available on layer one", step ~= nil)

-- Arrive somewhere naming layer two while we reckoned z = 0.
frame({ num = 0, area = "Unknown", name = "Layer two of the Sea of Chaos",
        exits = { "e", "w" } })
quiet(mode.on_arrival)
st = mode.stats()
check("z is taken from the room name", st.z == 1, tostring(st.z))
check("a layer correction is not a desync",
  mode.desyncs() == before_desyncs, tostring(mode.desyncs()))
check("the correction is counted", st.layer_corrections >= 1,
  tostring(st.layer_corrections))
check("the map is NOT reset by a layer correction", st.rooms >= 2,
  tostring(st.rooms))

-- An unparseable name leaves the reckoned z alone rather than zeroing it.
local z_before = mode.stats().z
before_desyncs = mode.desyncs()
frame({ num = 0, area = "Unknown", name = "Somewhere unparseable",
        exits = { "e", "w" } })
quiet(mode.on_arrival)
check("an unparseable layer leaves z as reckoned",
  mode.stats().z == z_before, tostring(mode.stats().z))
check("an unparseable layer is not a desync",
  mode.desyncs() == before_desyncs, tostring(mode.desyncs()))
mode.stop()

-- ---- a string layer must not corrupt the map -----------------------------------
-- A profile whose layer_of returns a STRING must leave the position reckoned
-- and record exactly one room -- not a second one keyed on the garbage
-- string. This is the only case in the suite that distinguishes the
-- type(layer) == "number" guard from a nil-only check (layer ~= nil and
-- layer ~= z): a nil-only check passes every OTHER case here, including
-- Mutant 2 above, so without this case a maintainer narrowing the guard to
-- "handles the nil I've seen" would ship a guard that lets a string sail
-- straight through to map:set_position and map.lua's key(), producing a
-- garbage coordinate like "0,0,layer two" with no crash and no diagnostic.
local string_layer_profile = {
  name = "test-string-layer",
  exclude_exits = { out = true, enter = true, ["in"] = true },
  dive_dirs = { "d" },
  defer_dirs = { "u" },
  default_policy = "clear",
  in_area = function() return true end,
  layer_of = function() return "layer two" end,  -- deliberately not a number
  complete = function() return false end,
}

quiet(function() mode.start(string_layer_profile, "clear") end)
frame({ name = "Room X", exits = { "e", "w" } })
quiet(mode.on_arrival)
local sl_st = mode.stats()
check("a string layer leaves z as reckoned", sl_st.z == 0, tostring(sl_st.z))
check("a string layer is not counted as a correction",
  sl_st.layer_corrections == 0, tostring(sl_st.layer_corrections))
check("a string layer records exactly one room", sl_st.rooms == 1,
  tostring(sl_st.rooms))

-- A second arrival at the same reckoned coordinate must land on the SAME
-- room, not fork a second one keyed on the garbage string -- that is the
-- observable shape of the corruption this case guards against.
frame({ name = "Room X", exits = { "e", "w" } })
quiet(mode.on_arrival)
check("a second arrival at the same coordinate does not fork a room",
  mode.stats().rooms == 1, tostring(mode.stats().rooms))
mode.stop()

-- ---- desync: contradicted topology -------------------------------------------
-- The maze is generated once per run and each room's coordinates are baked into
-- its file name, so a coordinate's exits cannot legitimately change. If they
-- do, we are not where we think we are.
quiet(function() mode.start(profile, "clear") end)
frame({ num = 0, area = "Unknown", name = "Layer one of the Sea of Chaos",
        exits = { "e", "w" } })
quiet(mode.on_arrival)
step = mode.next_step()
local out_dir = step.raw

-- Walk out and back, so we return to the origin coordinate...
frame({ num = 0, area = "Unknown", name = "Layer one of the Sea of Chaos",
        exits = { "e", "w" } })
quiet(mode.on_arrival)
before_desyncs = mode.desyncs()

-- ...and now claim the origin has a completely different exit set.
mode.debug_set_position(0, 0, 0)
frame({ num = 0, area = "Unknown", name = "Layer one of the Sea of Chaos",
        exits = { "n", "s" } })
quiet(mode.on_arrival)
check("contradicted topology is detected",
  mode.desyncs() == before_desyncs + 1, tostring(mode.desyncs()))
check("the map is reset after a topology desync",
  mode.stats().rooms == 1, tostring(mode.stats().rooms))

-- Re-recording an identical exit set is not a contradiction.
before_desyncs = mode.desyncs()
mode.debug_set_position(0, 0, 0)
frame({ num = 0, area = "Unknown", name = "Layer one of the Sea of Chaos",
        exits = { "n", "s" } })
quiet(mode.on_arrival)
check("an identical re-record is not a desync",
  mode.desyncs() == before_desyncs, tostring(mode.desyncs()))
mode.stop()

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
