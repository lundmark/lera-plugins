-- roominfo unit tests. Run from the lera-plugins repo root with LERA_ROOT
-- pointing at a built Lera checkout.
--
-- roominfo is the sole subscriber to the GMCP Room.* packages. It owns room
-- identity, contents and the map grid, and publishes them to mapper, minimap,
-- mapview and autostepper.
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

local handlers = {}   -- package name as registered -> callback
local removed = {}
gmcp = {
  on = function(pkg, fn) handlers[pkg] = fn; return pkg end,
  remove = function(id) removed[id] = true; return true end,
  enabled = function() return true end,
}

local printed = {}
print_real = print
print = function(...)
  local parts = {}
  for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  printed[#printed + 1] = table.concat(parts, " ")
end

local ri = require("roominfo")
print = print_real

-- Deliver a GMCP message the way the C dispatcher does: the handler registered
-- for a package receives the full package name and the decoded payload.
local function deliver(pkg, data)
  local fn = handlers[pkg]
  if not fn then return false end
  fn(pkg, data)
  return true
end

local function sorted_concat(list)
  local copy = {}
  for i, v in ipairs(list) do copy[i] = v end
  return table.concat(copy, ",")
end

ri.on_load()

-- ---- subscription -----------------------------------------------------------
-- Kills: an implementation that only subscribes to "Room", which would work at
-- runtime but hides which packages this plugin actually consumes.
check("subscribes to Room.Info", handlers["Room.Info"] ~= nil)

-- ---- is_synced --------------------------------------------------------------
-- Kills: is_synced() hardcoded to true, which tells mapview to correlate
-- positions against room state that has never arrived.
check("is_synced false before any Room.Info", ri.is_synced() == false)

-- ---- Room.Info --------------------------------------------------------------
deliver("Room.Info", {
  num = 4231,
  name = "A dusty crossroads",
  area = "Midgaard",
  exits = { north = 4232, south = 4230, ["northeast"] = 0 },
})

check("room name set", ri.room() == "A dusty crossroads", ri.room())
check("room id set", ri.room_id() == 4231, ri.room_id())
check("area set", ri.area() == "Midgaard", ri.area())
check("is_synced true after Room.Info", ri.is_synced() == true)

-- Kills: exits emitted in pairs() order, which is undefined in LuaJIT and makes
-- both the rendered exit list and every downstream test non-deterministic.
check("exits in canonical order", sorted_concat(ri.exits()) == "n,ne,s",
  sorted_concat(ri.exits()))

-- Kills: exit keys passed through verbatim, leaving "north" where every
-- consumer (mapper's cardinal_offsets, minimap's direction_offsets) expects "n".
check("exits shortened", ri.exits()[1] == "n", ri.exits()[1])

check("exits_string formatted", ri.exits_string() == "(n, ne, s)", ri.exits_string())

-- Kills: destinations dropped, which is the whole reason mapper can stop
-- walking links to discover where they lead.
local dest = ri.exit_destinations()
check("destination recorded", dest.n == 4232, tostring(dest.n))
check("zero destination preserved as 0", dest.ne == 0, tostring(dest.ne))

-- ---- num == 0 ---------------------------------------------------------------
-- Kills: accepting num == 0 as a room id. The mudlib permits it and it means
-- "no usable id"; mapper.process_room already refuses it, and letting it
-- through here would clobber good state with an unusable room.
deliver("Room.Info", { num = 0, name = "Nowhere", area = "", exits = {} })
check("num 0 rejected, room unchanged", ri.room() == "A dusty crossroads", ri.room())
check("num 0 rejected, id unchanged", ri.room_id() == 4231, ri.room_id())

-- ---- callbacks --------------------------------------------------------------
local seen = {}
local cb_id = ri.on_room_change(function(new_room, old_room)
  seen[#seen + 1] = tostring(old_room) .. "->" .. tostring(new_room)
end)

deliver("Room.Info", { num = 4232, name = "A quiet lane", area = "Midgaard", exits = { south = 4231 } })
check("callback fired on room change", seen[1] == "A dusty crossroads->A quiet lane", seen[1])

-- Kills: firing the callback on every packet. The server force-sends a
-- snapshot on subscription change, so an unchanged room arrives legitimately
-- and must not look like a move to mapper.
deliver("Room.Info", { num = 4232, name = "A quiet lane", area = "Midgaard", exits = { south = 4231 } })
check("callback not fired when room unchanged", #seen == 1, #seen)

check("off_room_change removes", ri.off_room_change(cb_id) == true)

-- ---- history ----------------------------------------------------------------
local hist = ri.get_history(5)
check("history newest first", hist[1] and hist[1].room == "A quiet lane",
  hist[1] and hist[1].room)

-- ---- info() -----------------------------------------------------------------
local info = ri.info()
check("info carries area", info.area == "Midgaard", tostring(info.area))
check("info carries exits_string", info.exits_string == "(s)", tostring(info.exits_string))

-- ---- Room.Contents ----------------------------------------------------------
check("subscribes to Room.Contents", handlers["Room.Contents"] ~= nil)

deliver("Room.Info", { num = 5000, name = "A guard post", area = "Midgaard", exits = {} })
deliver("Room.Contents", { full = 1, items = {
  { name = "Bob", type = "player", count = 1 },
  { name = "a city guard", type = "monster", count = 2, hp = "healthy" },
  { name = "a rusty sword", type = "item", count = 1 },
} })

-- Kills: returning entry tables from players()/monsters(). mapper.lua:562,
-- mapview.lua:499 and autostepper.lua:114 all table.concat these lists, which
-- errors on a table element.
check("players are name strings", ri.players()[1] == "Bob", tostring(ri.players()[1]))

-- Kills: ignoring `count`. The mudlib stacks duplicates into a count, so a
-- room with two identical guards arrives as one entry; not expanding it makes
-- monster_count() under-report what the old =M= lines showed.
check("counted monsters expand", #ri.monsters() == 2, #ri.monsters())
check("monster_count matches", ri.monster_count() == 2, ri.monster_count())
check("player_count matches", ri.player_count() == 1, ri.player_count())

-- Kills: dropping the extras. hp and attacking are the only combat-relevant
-- fields in the payload.
check("entry keeps hp", ri.monster_entries()[1].hp == "healthy",
  tostring(ri.monster_entries()[1].hp))
check("entry keeps count", ri.monster_entries()[1].count == 2,
  tostring(ri.monster_entries()[1].count))

-- Kills: filing items under monsters. type "item" is a third category the old
-- =M=/=P= scraping never had.
check("items separated", #ri.items() == 1 and ri.items()[1].name == "a rusty sword",
  tostring(#ri.items()))
check("items not counted as monsters", ri.monster_count() == 2, ri.monster_count())

check("has_monster finds by substring", ri.has_monster("guard") == true)
check("has_player finds exact", ri.has_player("bob") == true)

-- ---- the retained-state invariant ------------------------------------------
-- Kills: clearing players/monsters on Room.Info and waiting for Room.Contents.
-- The server suppresses a Contents resend when the list is identical to the
-- last one sent, so two adjacent rooms with the same occupants send Contents
-- once. Clearing on entry shows the second room as empty.
deliver("Room.Info", { num = 5001, name = "Another guard post", area = "Midgaard", exits = {} })
check("contents retained across Room.Info", ri.monster_count() == 2, ri.monster_count())
check("players retained across Room.Info", ri.player_count() == 1, ri.player_count())

-- ---- single-page payload ----------------------------------------------------
-- Kills: requiring `page`/`pages`. They are present only when there is more
-- than one page, so a complete one-page list has neither.
deliver("Room.Contents", { full = 1, items = { { name = "a rat", type = "monster", count = 1 } } })
check("single page replaces list", ri.monster_count() == 1, ri.monster_count())
check("single page clears players", ri.player_count() == 0, ri.player_count())

-- ---- multi-page reassembly --------------------------------------------------
deliver("Room.Contents", { full = 1, page = 1, pages = 2, items = {
  { name = "a rat", type = "monster", count = 1 },
} })
-- Kills: committing each page as it arrives, which makes the pane flicker
-- through partial lists and briefly reports the wrong monster_count.
check("page 1 of 2 not committed yet", ri.monster_count() == 1, ri.monster_count())

deliver("Room.Contents", { full = 1, page = 2, pages = 2, items = {
  { name = "a kobold", type = "monster", count = 1 },
  { name = "Alice", type = "player", count = 1 },
} })
check("both pages committed", ri.monster_count() == 2, ri.monster_count())
check("page 2 players committed", ri.player_count() == 1, ri.player_count())

-- ---- abandoned partial page -------------------------------------------------
-- Kills: an accumulator that survives a new page 1. Without the reset, the
-- stale first list is concatenated onto the new one and the room shows monsters
-- that are not there.
deliver("Room.Contents", { full = 1, page = 1, pages = 2, items = {
  { name = "a ghost", type = "monster", count = 1 },
} })
deliver("Room.Contents", { full = 1, page = 1, pages = 2, items = {
  { name = "a wolf", type = "monster", count = 1 },
} })
deliver("Room.Contents", { full = 1, page = 2, pages = 2, items = {} })
check("restarted paging drops the abandoned list", ri.monster_count() == 1, ri.monster_count())
check("restarted paging keeps the new list", ri.monsters()[1] == "a wolf",
  tostring(ri.monsters()[1]))

-- Kills: an accumulator that survives a room change, committing the previous
-- room's occupants into the new room. The mudlib emits every page back-to-back
-- after the Room.Info, so a page 2 arriving after a room change is an orphan
-- with no trustworthy page 1: it must be dropped, not committed.
deliver("Room.Contents", { full = 1, page = 1, pages = 2, items = {
  { name = "a spectre", type = "monster", count = 1 },
} })
deliver("Room.Info", { num = 5002, name = "A crypt", area = "Midgaard", exits = {} })
deliver("Room.Contents", { full = 1, page = 2, pages = 2, items = {
  { name = "a bat", type = "monster", count = 1 },
} })
check("room change abandons partial page", ri.monsters()[1] == "a wolf",
  tostring(ri.monsters()[1]))
check("orphan page not committed", ri.monster_count() == 1, ri.monster_count())

-- Kills: a handler left wedged by the orphan, silently ignoring every later
-- list. Dropping the orphan must not poison the accumulator.
deliver("Room.Contents", { full = 1, items = {
  { name = "a crow", type = "monster", count = 1 },
} })
check("handler recovers after an orphan page", ri.monsters()[1] == "a crow",
  tostring(ri.monsters()[1]))

-- ---- truncated --------------------------------------------------------------
-- Kills: swallowing the flag. A busy room where the mudlib dropped entries is
-- otherwise indistinguishable from a complete list.
deliver("Room.Contents", { full = 1, truncated = 1, items = {
  { name = "a crowd", type = "player", count = 1 },
} })
check("truncated recorded", ri.contents_truncated() == true)
deliver("Room.Contents", { full = 1, items = { { name = "a rat", type = "monster", count = 1 } } })
check("truncated cleared on a complete list", ri.contents_truncated() == false)

-- ---- malformed --------------------------------------------------------------
-- Kills: trusting the payload. gmcp delivers data == nil for undecodable JSON.
deliver("Room.Contents", nil)
check("nil payload leaves contents intact", ri.monster_count() == 1, ri.monster_count())
deliver("Room.Contents", { full = 1, items = { { type = "monster", count = 1 }, "junk" } })
check("nameless and non-table entries skipped", ri.monster_count() == 0, ri.monster_count())

-- ---- Room.Map ---------------------------------------------------------------
check("subscribes to Room.Map", handlers["Room.Map"] ~= nil)
check("map nil before any Room.Map", ri.map() == nil)

local legend = { O = "room", ["@"] = "you", ["|"] = "link", ["-"] = "link" }
deliver("Room.Map", {
  kind = "los", w = 5, h = 3,
  rows = { "O-O-O", "  |  ", "  @  " },
  legend = legend,
  up = 1, down = 0, enter = 0,
})

local grid = ri.map()
check("map kind", grid and grid.kind == "los", grid and grid.kind)
check("map dimensions", grid and grid.w == 5 and grid.h == 3,
  grid and (grid.w .. "x" .. grid.h))
check("map rows", grid and grid.rows[3] == "  @  ", grid and grid.rows[3])
check("map legend", grid and grid.legend["@"] == "you", grid and grid.legend["@"])

-- Kills: passing the flags through as truthy numbers. 0 is truthy in Lua, so a
-- renderer testing `if grid.down then` draws a down indicator for every room.
check("up flag boolean true", grid and grid.up == true, tostring(grid and grid.up))
check("down flag boolean false", grid and grid.down == false, tostring(grid and grid.down))

-- Kills: handing out the live table. A renderer that mutates rows for path
-- highlighting would corrupt the stored grid for every later frame.
grid.rows[3] = "MUTATED"
check("map returns a copy", ri.map().rows[3] == "  @  ", ri.map().rows[3])

-- Kills: blanking the map on Room.Info. Two rooms with identical line-of-sight
-- output send Room.Map once, so clearing on entry flashes the pane empty.
deliver("Room.Info", { num = 5100, name = "A corridor", area = "Midgaard", exits = {} })
check("map retained across Room.Info", ri.map() ~= nil and ri.map().w == 5,
  ri.map() and ri.map().w)

-- Kills: trusting the payload shape.
deliver("Room.Map", nil)
check("nil payload leaves map intact", ri.map() ~= nil and ri.map().w == 5)
deliver("Room.Map", { kind = "los", w = 5, h = 3, rows = "not a list", legend = {} })
check("malformed rows rejected", ri.map() ~= nil and ri.map().rows[1] == "O-O-O",
  ri.map() and ri.map().rows[1])

-- Kills: missing a per-row width check. Without it, a row narrower or wider
-- than w would be accepted, and every consumer that uses grid.w for column
-- math (minimap's centering, get_char_at) would read past or short of the
-- actual row content. Row 1 here ("AAAAA") differs from the retained grid's
-- ("O-O-O"), so acceptance and rejection are distinguishable.
deliver("Room.Map", { kind = "los", w = 5, h = 3, rows = { "AAAAA", "BBBBB", "C" }, legend = {} })
check("wrong-width row rejected", ri.map() ~= nil and ri.map().rows[1] == "O-O-O",
  ri.map() and ri.map().rows[1])

-- ---- unload -----------------------------------------------------------------
ri.on_unload()
check("unregisters Room.Info", removed["Room.Info"] == true)
check("unregisters Room.Contents", removed["Room.Contents"] == true)
check("unregisters Room.Map", removed["Room.Map"] == true)

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
