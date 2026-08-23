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

mp.on_unload()

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
