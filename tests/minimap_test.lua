-- minimap unit tests. Run from the lera-plugins repo root with LERA_ROOT
-- pointing at a built Lera checkout.
--
-- minimap is a pure renderer over the GMCP Room.Map grid roominfo publishes. It
-- owns glyph semantics for itself and for mapview.
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

local grid = nil
local fake_roominfo = {
  map = function() return grid end,
  room = function() return "A dusty crossroads" end,
  exits_string = function() return "(n, s)" end,
  exits = function() return { "n", "s" } end,
}
plugin = {
  get = function(name)
    if name == "roominfo" then return fake_roominfo end
    return nil
  end,
}

-- Record every ui.text call so render can be asserted without a screen.
local drawn = {}
ui = {
  box = function() end,
  rect = function(x, y, w, h) return { x = x, y = y, w = w, h = h } end,
  text = function(_, s) drawn[#drawn + 1] = s end,
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

local mm = require("minimap")
print = print_real

local function set_grid(g) grid = g end

local function render()
  drawn = {}
  mm.render({ x = 0, y = 0, w = 20, h = 10 }, { show_border = false })
  return table.concat(drawn, "\n")
end

mm.on_load()

-- ---- priority ---------------------------------------------------------------
-- Kills: leaving priority at 5. That value exists only to read =R= lines before
-- roominfo suppressed them; minimap now consumes roominfo and must run after
-- it. mapview's own header comment already assumes 15.
check("priority is 15", mm.priority == 15, mm.priority)

-- ---- no line hook -----------------------------------------------------------
-- Kills: keeping on_line. Any surviving hook would still scrape and, worse,
-- still gag map lines from the buffer, which this design explicitly does not do.
check("no on_line hook", mm.on_line == nil)

-- ---- no map -----------------------------------------------------------------
set_grid(nil)
check("has_map false with no grid", mm.has_map() == false)
check("get_map_lines empty with no grid", #mm.get_map_lines() == 0)
check("get_player_position nil with no grid", mm.get_player_position() == nil)
check("get_map_size zero with no grid",
  mm.get_map_size().rows == 0 and mm.get_map_size().cols == 0)
-- Kills: indexing a nil grid in render. A room with no map provider sends no
-- Room.Map at all, so this is a normal state, not an error.
check("render says no map data", render():find("No map data", 1, true) ~= nil, render())

-- ---- glyph classes ----------------------------------------------------------
-- Kills: minimap's pre-GMCP guesses. The mudlib legend is authoritative: X is a
-- link (not a blocked room), # is darkness (not a wall), + is a room with both
-- up and down exits (not a junction).
check("X classes as link", mm.glyph_class("X") == "link", mm.glyph_class("X"))
check("# classes as dark", mm.glyph_class("#") == "dark", mm.glyph_class("#"))
check("+ classes as updown", mm.glyph_class("+") == "updown", mm.glyph_class("+"))
check("O classes as room", mm.glyph_class("O") == "room", mm.glyph_class("O"))
check("@ classes as you", mm.glyph_class("@") == "you", mm.glyph_class("@"))
check("^ classes as up", mm.glyph_class("^") == "up", mm.glyph_class("^"))
check("v classes as down", mm.glyph_class("v") == "down", mm.glyph_class("v"))
check("E classes as enter", mm.glyph_class("E") == "enter", mm.glyph_class("E"))
check("? classes as unknown", mm.glyph_class("?") == "unknown", mm.glyph_class("?"))
check("pipe classes as link", mm.glyph_class("|") == "link", mm.glyph_class("|"))
check("dash classes as link", mm.glyph_class("-") == "link", mm.glyph_class("-"))
check("slash classes as link", mm.glyph_class("/") == "link", mm.glyph_class("/"))
check("backslash classes as link", mm.glyph_class("\\") == "link", mm.glyph_class("\\"))
check("space classes as blank", mm.glyph_class(" ") == "blank", mm.glyph_class(" "))

-- Kills: treating digits as mob counts. The mudlib collapses per-cell counts to
-- p and m before they reach the wire, so a digit can no longer appear.
check("p classes as players", mm.glyph_class("p") == "players", mm.glyph_class("p"))
check("m classes as monsters", mm.glyph_class("m") == "monsters", mm.glyph_class("m"))
check("digit is not a class", mm.glyph_class("3") == "other", mm.glyph_class("3"))

-- ---- grid accessors ---------------------------------------------------------
set_grid({
  kind = "los", w = 5, h = 3,
  rows = { "O-O-O", "  |  ", "  @  " },
  legend = { O = "room", ["@"] = "you", ["|"] = "link", ["-"] = "link" },
  up = true, down = false, enter = false,
})

check("has_map true with a grid", mm.has_map() == true)
check("get_map_lines returns rows", mm.get_map_lines()[1] == "O-O-O", mm.get_map_lines()[1])
check("get_map_size from payload",
  mm.get_map_size().rows == 3 and mm.get_map_size().cols == 5,
  mm.get_map_size().rows .. "x" .. mm.get_map_size().cols)

local pos = mm.get_player_position()
check("player position row", pos and pos.row == 3, pos and pos.row)
check("player position col", pos and pos.col == 3, pos and pos.col)

check("get_char_at reads a cell", mm.get_char_at({ row = 1, col = 1 }) == "O",
  mm.get_char_at({ row = 1, col = 1 }))
check("get_char_at out of range is nil", mm.get_char_at({ row = 9, col = 1 }) == nil)

-- Kills: inferring up/down from the home marker glyph. The mudlib collapses all
-- five home markers to @ and moves that information to the payload flags.
local vert = mm.vertical_exits()
check("vertical up from flag", vert.up == true, tostring(vert.up))
check("vertical down from flag", vert.down == false, tostring(vert.down))

-- ---- render -----------------------------------------------------------------
local out = render()
check("render draws the grid", out:find("O-O-O", 1, true) ~= nil, out)
check("render draws the player row", out:find("@", 1, true) ~= nil, out)

-- ---- room name and exits lines ---------------------------------------------
-- Kills: the pre-existing crash. last_room_name and last_exits were never
-- assigned anywhere in the file, so with either toggle on, `#nil` errored in
-- render. Both now come from roominfo.
mm.toggle_room_name()
mm.toggle_exits()
local ok, err = pcall(render)
check("render survives room-name and exits toggles on", ok, err)
if ok then
  local shown = render()
  check("render shows the roominfo room name",
    shown:find("A dusty crossroads", 1, true) ~= nil, shown)
  check("render shows the roominfo exits", shown:find("(n, s)", 1, true) ~= nil, shown)
end
mm.toggle_room_name()
mm.toggle_exits()

-- ---- clear ------------------------------------------------------------------
-- Kills: minimap reaching into roominfo to wipe a grid it does not own, and a
-- clear() that errors now that the scraper's buffers are gone. The server
-- decides when the next Room.Map arrives; there is nothing local left to drop.
local clear_ok, clear_err = pcall(mm.clear)
check("clear is callable", clear_ok, clear_err)
check("clear leaves roominfo's grid alone", mm.has_map() == true)

mm.on_unload()

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
