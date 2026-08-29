-- mapview unit tests. Run from the lera-plugins repo root with LERA_ROOT
-- pointing at a built Lera checkout.
--
-- These cover the info block mapview draws under the map: the annotated room
-- name line, the exits line, the speedwalk place line and the contents lines.
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
local stored = nil
store = {
  load = function() end,
  get = function() return stored end,
  set = function(d) stored = d end,
  save = function() end,
}

-- roominfo: the room the info block describes.
local ri = {
  room_name = "Wizard's Main Board Room",
  area = nil,
  exits = { "u", "d" },
  monsters = {},
  players = {},
  items = {},
}
local fake_roominfo = {
  room = function() return ri.room_name end,
  area = function() return ri.area end,
  exits = function() return ri.exits end,
  exits_string = function()
    if #ri.exits == 0 then return "" end
    return "(" .. table.concat(ri.exits, ", ") .. ")"
  end,
  monsters = function() return ri.monsters end,
  players = function() return ri.players end,
  items = function() return ri.items end,
}

-- minimap: a single room glyph is enough; the grid is not under test here.
local fake_minimap = {
  has_map = function() return true end,
  get_map_lines = function() return { "#" } end,
  get_player_position = function() return { row = 1, col = 1 } end,
  glyph_class = function(c) return c == "#" and "room" or "other" end,
  is_room_cell = function(c) return c == "#" end,
  room_name = function() return ri.room_name end,
}

-- mapper: supplies the current room id and the waypoint table.
local mp = { room_id = 50205, waypoints = {} }
local fake_mapper = {
  current_room = function() return { id = mp.room_id, name = ri.room_name, exits = {} } end,
  get_room = function() return nil end,
  get_freshness = function() return nil end,
  list_waypoints = function()
    local out = {}
    for name, rid in pairs(mp.waypoints) do out[#out + 1] = { name = name, room_id = rid } end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
  end,
  render = function() end,
}

-- speedwalk: the fossil place value and the live step counter.
local sw = { place = nil, step = { current = 0, total = 0 }, targets = {} }
local fake_speedwalk = {
  get_current_place = function() return sw.place end,
  step_info = function() return sw.step end,
  get_targets = function() return sw.targets end,
  get_place_config = function() return nil end,
}

local loaded = {
  roominfo = fake_roominfo,
  minimap = fake_minimap,
  mapper = fake_mapper,
  speedwalk = fake_speedwalk,
}
plugin = { get = function(name) return loaded[name] end }

-- Record draws with their y so the info block can be read back in order.
local drawn = {}
ui = {
  box = function() end,
  rect = function(x, y, w, h) return { x = x, y = y, w = w, h = h } end,
  text = function(r, s) drawn[#drawn + 1] = { y = r.y, s = s } end,
  text_ansi = function(r, s) drawn[#drawn + 1] = { y = r.y, s = s } end,
}

local printed = {}
local print_real = print
print = function(...)
  local parts = {}
  for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  printed[#printed + 1] = table.concat(parts, " ")
end

local registered = {}
local command_stub = {
  register = function(spec) registered[#registered + 1] = spec; return #registered end,
  unregister = function() return true end,
}
local real_require = require
require = function(name)
  if name == "command" then return command_stub end
  return real_require(name)
end

local mv = require("mapview")
print = print_real

local function strip(s) return (s:gsub("\027%[[0-9;]*m", "")) end

-- Render at a width wide enough that nothing truncates, and return the drawn
-- lines bottom-up: the info block is anchored to the bottom of the pane.
local function render(width)
  drawn = {}
  mv.render({ x = 0, y = 0, w = width or 60, h = 12 }, { show_border = false })
  local lines = {}
  for _, d in ipairs(drawn) do lines[#lines + 1] = d end
  table.sort(lines, function(a, b) return a.y < b.y end)
  return lines
end

local function info_text(width)
  local out = {}
  for _, d in ipairs(render(width)) do
    local t = strip(d.s)
    if t:match("%S") then out[#out + 1] = t end
  end
  return out
end

local function find(lines, pattern)
  for _, l in ipairs(lines) do
    if l:find(pattern) then return l end
  end
  return nil
end

local function raw_find(width, pattern)
  for _, d in ipairs(render(width)) do
    if strip(d.s):find(pattern) then return d.s end
  end
  return nil
end

-- ---- cases ------------------------------------------------------------------

-- The room name carries its room-derived annotations inline, not on lines of
-- their own.
ri.area = nil
local lines = info_text()
local name_line = find(lines, "Wizard's Main Board Room")
check("name line present", name_line ~= nil, table.concat(lines, " | "))
check("area unknown annotates the name line",
  name_line and name_line:find("%[Area: Unknown%]") ~= nil, name_line)

ri.area = "Wizard Hall"
lines = info_text()
name_line = find(lines, "Wizard's Main Board Room")
check("area annotates the name line",
  name_line and name_line:find("%[Area: Wizard Hall%]") ~= nil, name_line)

-- The waypoint tag is room-derived: it appears only when THIS room is a mapper
-- waypoint, and names that waypoint.
mp.waypoints = { angfield = 44 }
lines = info_text()
name_line = find(lines, "Wizard's Main Board Room")
check("no waypoint tag when the room is not a waypoint",
  name_line and name_line:find("%[Waypoint:") == nil, name_line)

mp.waypoints = { home = 50205 }
lines = info_text()
name_line = find(lines, "Wizard's Main Board Room")
check("waypoint tag names this room's waypoint",
  name_line and name_line:find("%[Waypoint: home%]") ~= nil, name_line)
mp.waypoints = {}

-- The speedwalk place is not a room fact. A stale current_place with no walk in
-- progress must not render: that is the "home" that appeared in every room.
sw.place = "home"
sw.step = { current = 0, total = 0 }
lines = info_text()
check("stale speedwalk place does not render",
  find(lines, "^home") == nil, table.concat(lines, " | "))

sw.step = { current = 2, total = 7 }
lines = info_text()
check("active walk renders place and step counter",
  find(lines, "home %[2/7%]") ~= nil, table.concat(lines, " | "))
sw.place = nil
sw.step = { current = 0, total = 0 }

-- Room items reach the info block.
ri.items = {
  { name = "A newspaper rack.", count = 1 },
  { name = "A nifty machine with a lever on one side.", count = 1 },
}
lines = info_text(120)
check("items render", find(lines, "newspaper rack") ~= nil, table.concat(lines, " | "))

-- The colour is the type marker, so the contents lines carry no M:/P:/I:
-- prefix -- every cell goes to names instead.
ri.monsters = { "a rat" }
ri.players = { "Bob" }
lines = info_text(120)
check("contents lines carry no type prefix",
  find(lines, "^[MPI]:") == nil, table.concat(lines, " | "))
check("monsters render unprefixed", find(lines, "^a rat$") ~= nil, table.concat(lines, " | "))
check("players render unprefixed", find(lines, "^Bob$") ~= nil, table.concat(lines, " | "))

-- Contents lines are coloured by type, and the three types differ.
local item_line = raw_find(120, "newspaper rack")
local mon_line = raw_find(120, "a rat")
local ply_line = raw_find(120, "Bob")
local function sgr(s) return s and s:match("\027%[38;2;[0-9;]+m") or nil end
check("item line is coloured", sgr(item_line) ~= nil, item_line)
check("monster line is coloured", sgr(mon_line) ~= nil, mon_line)
check("player line is coloured", sgr(ply_line) ~= nil, ply_line)
check("item and monster colours differ", sgr(item_line) ~= sgr(mon_line),
  tostring(sgr(item_line)) .. " vs " .. tostring(sgr(mon_line)))
check("player and monster colours differ", sgr(ply_line) ~= sgr(mon_line),
  tostring(sgr(ply_line)) .. " vs " .. tostring(sgr(mon_line)))

-- A narrow pane must not lose the room name to its own annotations.
ri.area = "Wizard Hall"
mp.waypoints = { home = 50205 }
lines = info_text(24)
check("narrow pane keeps the room name",
  find(lines, "Wizard's") ~= nil, table.concat(lines, " | "))
check("narrow pane keeps the annotations",
  find(lines, "%[Area: Wizard Hall%]") ~= nil, table.concat(lines, " | "))

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("all mapview cases passed")
