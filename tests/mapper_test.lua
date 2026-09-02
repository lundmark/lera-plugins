-- mapper unit tests. Run from the lera-plugins repo root with LERA_ROOT
-- pointing at a built Lera checkout.
--
-- mapper builds a persistent room graph. Since GMCP Room.Info carries a
-- destination room number for every exit, connections no longer have to be
-- learned by walking a link, and mapping mode is gone.
package.path = "3scapes/?.lua;generic/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- ---- stubs ------------------------------------------------------------------
local clock = 1000
lera = { time = function() return clock end }

local stored = nil
store = {
  load = function() end,
  get = function() return stored end,
  set = function(d) stored = d end,
  save = function() end,
  path = function() return "/tmp" end,
}

-- A roominfo stand-in whose state the test drives directly.
local ri_state = { room = nil, room_id = nil, area = nil, exits = {}, dest = {} }
local ri_callbacks = {}
local fake_roominfo = {
  room = function() return ri_state.room end,
  room_id = function() return ri_state.room_id end,
  area = function() return ri_state.area end,
  exits = function() return ri_state.exits end,
  exit_destinations = function() return ri_state.dest end,
  is_synced = function() return ri_state.room_id ~= nil end,
  on_room_change = function(fn) ri_callbacks[#ri_callbacks + 1] = fn; return #ri_callbacks end,
  off_room_change = function() return true end,
}
plugin = {
  get = function(name)
    if name == "roominfo" then return fake_roominfo end
    return nil
  end,
}

ui = {
  box = function() end,
  rect = function(x, y, w, h) return { x = x, y = y, w = w, h = h } end,
  text = function() end,
}

local printed = {}
local print_real = print
print = function(...)
  local parts = {}
  for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  printed[#printed + 1] = table.concat(parts, " ")
end

local command_stub = {
  register = function() return 1 end,
  unregister = function() return true end,
}
local real_require = require
require = function(name)
  if name == "command" then return command_stub end
  return real_require(name)
end

local mp = require("mapper")
print = print_real

-- Move into a room the way roominfo does: update its state, then fire the
-- room-change callbacks mapper registered.
local function enter(id, name, exits, dest, area)
  ri_state.room_id = id
  ri_state.room = name
  ri_state.area = area
  ri_state.exits = exits or {}
  ri_state.dest = dest or {}
  local previous = ri_state.previous
  ri_state.previous = name
  for _, fn in ipairs(ri_callbacks) do fn(name, previous) end
end

-- ---- MIP is gone ------------------------------------------------------------
-- Kills: leaving the MIP handlers registered. `mip` is deliberately not stubbed
-- in this suite, so a surviving mip.on call raises "attempt to index global
-- 'mip'" and this assertion carries the failure.
local load_ok, load_err = pcall(mp.on_load)
check("loads without touching mip", load_ok, load_err)

-- Kills: keeping the movement-tracking hooks. Their only purpose was to
-- correlate a typed direction with the next room report, which destinations
-- make unnecessary.
check("no on_input hook", mp.on_input == nil)
check("no on_send hook", mp.on_send == nil)
check("no on_line hook", mp.on_line == nil)

-- ---- mapping mode retired ---------------------------------------------------
-- Kills: removing the functions outright. /map start and any profile calling
-- them must keep working.
check("is_mapping always true", mp.is_mapping() == true)
check("start_mapping callable", pcall(mp.start_mapping) == true)
check("stop_mapping callable", pcall(mp.stop_mapping) == true)
check("toggle_mapping callable", pcall(mp.toggle_mapping) == true)

-- ---- connections from destinations ------------------------------------------
-- Kills: still requiring a walk to learn a connection. One Room.Info names
-- every exit's destination, so entering a room is enough.
enter(100, "A dusty crossroads", { "n", "s" }, { n = 101, s = 102 }, "Midgaard")

local room = mp.get_room(100)
check("room created", room ~= nil)
check("connection north from destination", room and room.connections.n == 101,
  room and tostring(room.connections.n))
check("connection south from destination", room and room.connections.s == 102,
  room and tostring(room.connections.s))
check("exits recorded", room and #room.exits == 2, room and #room.exits)

-- Kills: recording a connection to room 0. The mudlib permits a destination of
-- 0 and it means "no usable id"; a link to room 0 makes pathfinding walk into
-- a room that does not exist.
enter(101, "A quiet lane", { "s", "u" }, { s = 100, u = 0 }, "Midgaard")
local lane = mp.get_room(101)
check("zero destination skipped", lane and lane.connections.u == nil,
  lane and tostring(lane.connections.u))
check("nonzero destination kept", lane and lane.connections.s == 100,
  lane and tostring(lane.connections.s))

-- Kills: creating stub rooms for unvisited destinations. This design keeps them
-- out so nothing new appears in a render or in mapview's correlation.
check("unvisited destination is not a room", mp.get_room(102) == nil)

-- ---- positions --------------------------------------------------------------
-- Kills: dropping position assignment along with the walk tracking. GMCP
-- carries no coordinates, so x/y is still derived on first visit from the
-- direction taken out of the previous room.
check("first room at origin", mp.get_room(100).x == 0 and mp.get_room(100).y == 0,
  mp.get_room(100).x .. "," .. mp.get_room(100).y)
check("north neighbour is one row up",
  mp.get_room(101).y == mp.get_room(100).y - 1,
  mp.get_room(101).y .. " vs " .. mp.get_room(100).y)

-- Kills: deriving the direction travelled from the previous room's forward
-- destination alone. That destination is systematically 0 on first discovery --
-- the mudlib resolves it with find_object, which does not load an idle room --
-- so the optimistic case above is the one that never fails in practice. Without
-- a fallback the new room keeps x=0,y=0 forever (positions are assigned on
-- first sight only) and every newly discovered room stacks on the centre cell.
enter(200, "A dim hollow", { "n" }, { n = 0 })
enter(201, "A dim path", { "s" }, { s = 200 })
local hollow, path = mp.get_room(200), mp.get_room(201)
check("unknown forward destination still positions the new room",
  path and hollow and path.y == hollow.y - 1 and path.x == hollow.x,
  path and hollow and (path.x .. "," .. path.y .. " vs " .. hollow.x .. "," .. hollow.y))
-- Kills: writing the inverted back-edge as a connection. The direction is used
-- for positioning only; a reverse edge the server never reported must not
-- appear in the graph.
check("no reverse connection invented", hollow and hollow.connections.n == nil,
  hollow and tostring(hollow.connections.n))

-- Kills: picking the direction with an unordered pairs() scan. Two exits to the
-- same destination must resolve the same way on every run; compass order makes
-- "s" (and so a northward step) the answer, not "w".
enter(310, "Twin gates", { "n", "e" }, { n = 0, e = 0 })
enter(311, "Beyond the gates", { "s", "w" }, { s = 310, w = 310 })
local twin, beyond = mp.get_room(310), mp.get_room(311)
check("ambiguous back-edge resolves in compass order",
  beyond and twin and beyond.x == twin.x and beyond.y == twin.y - 1,
  beyond and twin and (beyond.x .. "," .. beyond.y .. " vs " .. twin.x .. "," .. twin.y))

-- Same determinism requirement on the forward path.
enter(320, "Forked hall", { "n", "e" }, { n = 330, e = 330 })
enter(330, "Past the fork", { "s" }, { s = 320 })
local fork, past = mp.get_room(320), mp.get_room(330)
check("ambiguous forward destination resolves in compass order",
  past and fork and past.x == fork.x and past.y == fork.y - 1,
  past and fork and (past.x .. "," .. past.y .. " vs " .. fork.x .. "," .. fork.y))

-- ---- area -------------------------------------------------------------------
-- Kills: discarding the area name. It is the one genuinely new field, and it is
-- additive so existing saved maps stay readable.
check("area stored on the room", mp.get_room(100).area == "Midgaard",
  tostring(mp.get_room(100).area))

-- ---- room 0 -----------------------------------------------------------------
-- Kills: accepting room id 0 here. roominfo already refuses it, but mapper is
-- also reachable from a stale roominfo state.
local before = mp.stats().rooms
enter(0, "Nowhere", {}, {})
check("room id 0 creates nothing", mp.stats().rooms == before, mp.stats().rooms)

-- ---- persistence ------------------------------------------------------------
mp.save()
check("save wrote rooms", stored ~= nil and stored.rooms ~= nil)
check("save wrote area", stored and stored.rooms and stored.rooms["100"]
  and stored.rooms["100"].area == "Midgaard",
  stored and stored.rooms and stored.rooms["100"] and tostring(stored.rooms["100"].area))

-- Kills: a loader that requires `area`. Existing saved maps predate the field
-- and must load unchanged.
--
-- Order matters: mp.clear() calls save_map(), which overwrites `stored` with
-- the now-empty in-memory map. The fixture has to be installed AFTER the clear,
-- or the loader reads back the wipe instead of the legacy data.
mp.clear()
stored = {
  rooms = {
    ["500"] = { id = 500, name = "An old room", exits = { "n" },
                connections = { n = 501 }, x = 0, y = 0,
                layer = "default", virtual = false, last_seen = 1 },
  },
  current_layer = "default",
  waypoints = {},
}
mp.on_load()
local old = mp.get_room(500)
check("legacy room loads", old ~= nil and old.name == "An old room",
  old and old.name)
check("legacy room has no area", old ~= nil and old.area == nil,
  old and tostring(old.area))

-- Kills: never clearing room.connections before rebuilding it from the current
-- snapshot. The old MIP-era mapper invented a reverse edge for every walked
-- exit (e.g. recording room 500 -> n -> 501 also invented 501 -> s -> 500),
-- and process_room used to only overwrite the keys present in the current
-- destinations table, so an invented edge with no real counterpart in a
-- future Room.Info survived forever. Here room 500's legacy connection (n)
-- is not one the current Room.Info reports (only s), so it must be dropped
-- on revisit rather than left standing alongside the new one.
enter(500, "An old room", { "s" }, { s = 502 }, nil)
local revisited = mp.get_room(500)
check("stale connection dropped on revisit", revisited and revisited.connections.n == nil,
  revisited and tostring(revisited.connections.n))
check("current connection recorded on revisit", revisited and revisited.connections.s == 502,
  revisited and tostring(revisited.connections.s))

-- Kills: rebuilding connections by clearing them outright. A destination of 0
-- means the server could not resolve the exit right now, not that the exit lost
-- its destination -- so revisiting a room while its neighbour happens to be
-- unloaded must not discard what an earlier visit learned. Since the forward
-- destination is the systematically-unknown one, dropping it here drifts the
-- graph towards backward-only edges, which correlate_positions cannot follow.
enter(600, "A waiting hall", {}, {})
enter(500, "An old room", { "s" }, { s = 0 }, nil)
local unresolved = mp.get_room(500)
check("connection survives a 0 destination on a surviving exit",
  unresolved and unresolved.connections.s == 502,
  unresolved and tostring(unresolved.connections.s))

-- ...while a direction that is no longer an exit at all is still dropped.
enter(600, "A waiting hall", {}, {})
enter(500, "An old room", { "n" }, { n = 0 }, nil)
local narrowed = mp.get_room(500)
check("connection dropped when its direction stops being an exit",
  narrowed and narrowed.connections.s == nil,
  narrowed and tostring(narrowed.connections.s))

-- ---- seeding at load -------------------------------------------------------
-- Kills: registering the room-change callback and nothing else. Room.Info fires
-- on room entry only, so a mapper loaded (or /plugins reload'ed) mid-session has
-- no current room until the player next moves -- and mapview's correlation,
-- which starts from the current room, colours nothing while the player stands
-- still.
mp.on_unload()
mp.clear()
ri_state.room_id = 700
ri_state.room = "A lonely tower"
ri_state.exits = { "n" }
ri_state.dest = { n = 0 }
mp.on_load()
local seeded = mp.current_room()
check("seeds the current room from roominfo at load",
  seeded ~= nil and seeded.id == 700, seeded and seeded.id)
check("seeded room carries its name", seeded and seeded.name == "A lonely tower",
  seeded and seeded.name)

mp.on_unload()

-- ---- unmappable areas (ignore list) -----------------------------------------
-- A no-explorer VR area answers every room with the same shared id (roominfo
-- collapses the VR path at its ':' before asking the explorer DB), so mapping
-- it corrupts the map of everywhere else. A room whose name matches an ignore
-- pattern is refused outright. Ships with one default pattern covering the
-- Chaos Sea: "of the sea of chaos".

-- Kills: deleting the `is_ignored` early return in process_room.
mp.clear()
enter(60494, "Depths of the Sea of Chaos", {}, {}, "Chaos Sea")
check("ignored room is not added to the map", mp.get_room(60494) == nil)

-- Kills: keeping `map.current_room_id = rid` instead of clearing it to nil.
-- Room 1 stands in for a real room that happens to carry the same id the
-- (unrelated) ignored area reports on the very next call -- a shared-id area
-- answers every room with one constant, so a coincidence like this is exactly
-- the failure mode the anchor-clearing exists to prevent. Only a cleared
-- anchor stops the next real room from positioning itself off a node that has
-- nothing to do with where the player actually is.
mp.clear()
enter(1, "A quiet dock", { "n" }, {})
enter(1, "Depths of the Sea of Chaos", {}, {})
enter(2, "A sunlit jetty", { "s" }, { s = 1 })
local jetty = mp.get_room(2)
check("entering an ignored area clears the anchor",
  jetty and jetty.x == 0 and jetty.y == 0,
  jetty and (jetty.x .. "," .. jetty.y))

-- Kills: dropping `dest ~= rid` from the destinations guard. The second check
-- is a regression guard: it exists so the guard above cannot pass by refusing
-- every destination outright.
mp.clear()
enter(5001, "A limestone cavern", { "n", "s" }, { n = 5001, s = 5002 })
local cavern = mp.get_room(5001)
check("self-referential destination is not recorded",
  cavern and cavern.connections.n == nil, cavern and tostring(cavern.connections.n))
check("a normal destination is still recorded",
  cavern and cavern.connections.s == 5002, cavern and tostring(cavern.connections.s))

-- ---- load_map repairs a map saved before this fix ---------------------------
mp.clear()
stored = {
  rooms = {
    ["9001"] = { id = 9001, name = "The Depths of the Sea of Chaos", exits = {},
                 connections = {}, x = 0, y = 0, layer = "default",
                 virtual = false, last_seen = 1 },
    ["9002"] = { id = 9002, name = "An ordinary landing", exits = { "n" },
                 connections = { n = 9001 }, x = 0, y = 0, layer = "default",
                 virtual = false, last_seen = 1 },
    ["9003"] = { id = 9003, name = "A calm harbor", exits = { "e" },
                 connections = { e = 9003 }, x = 0, y = 0, layer = "default",
                 virtual = false, last_seen = 1 },
  },
  current_layer = "default",
  waypoints = {},
}
mp.on_load()

-- Kills: skipping the first purge loop in load_map.
check("load_map purges a saved node matching an ignore pattern",
  mp.get_room(9001) == nil)

-- Kills: skipping the second loop in load_map.
local landing = mp.get_room(9002)
check("load_map drops an edge that pointed at a purged node",
  landing and landing.connections.n == nil,
  landing and tostring(landing.connections.n))

-- Kills: dropping the `dest == id` clause from the second loop.
local harbor = mp.get_room(9003)
check("load_map drops a self-referential edge from a surviving node",
  harbor and harbor.connections.e == nil,
  harbor and tostring(harbor.connections.e))

mp.on_unload()

-- ---- is_ignored / ignore_pattern surface -------------------------------------

-- Kills: lowercasing only one side of the comparison in is_ignored. The
-- pattern is added in Title Case and the name embeds it in ALL CAPS, so a
-- comparison that lowercases only the name or only the pattern still fails to
-- find it; only lowering both sides does. This also covers "matches a
-- substring, not a whole name": the pattern is a small fragment of a longer
-- room name, not the name itself.
check("ignore_pattern accepts a new pattern", mp.ignore_pattern("Grey Wastes") == true)
check("is_ignored is case-insensitive and matches a substring",
  mp.is_ignored("You enter the GREY WASTES of ash") == true)

-- Kills: removing the type check in ignore_pattern. A rejected call must
-- neither be accepted nor grow the list, while a genuinely new pattern
-- submitted right after still must. is_ignored defensively skips a
-- non-string list entry (see mapper.lua), so this no longer depends on
-- running last -- a poisoned entry from this mutant is inert everywhere,
-- including in the ordinary-room regression case below.
local before_count = #mp.ignored_patterns()
local rejected = mp.ignore_pattern(42)
mp.ignore_pattern("frost giants of the wild")
local after_count = #mp.ignored_patterns()
check("ignore_pattern rejects a non-string but still extends the list for a valid one",
  rejected == false and after_count == before_count + 1,
  "rejected=" .. tostring(rejected) .. " before=" .. before_count .. " after=" .. after_count)

-- ---- ordinary rooms are unaffected (regression) ------------------------------
mp.clear()
enter(7001, "A sunny meadow", { "e" }, {})
enter(7002, "A shaded grove", { "w" }, { w = 7001 })
local meadow, grove = mp.get_room(7001), mp.get_room(7002)
check("an ordinary room is still mapped and positioned normally",
  meadow and grove and grove.x == meadow.x + 1 and grove.y == meadow.y,
  meadow and grove and (grove.x .. "," .. grove.y .. " vs " .. meadow.x .. "," .. meadow.y))

mp.on_unload()

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
