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
-- num == 0 is now accepted (Chaos Sea rooms report it). Negative numbers are
-- still refused: they are not real mudlib answers.
deliver("Room.Info", { num = -1, name = "Nowhere", area = "", exits = {} })
check("negative num rejected, room unchanged", ri.room() == "A dusty crossroads", ri.room())
check("negative num rejected, id unchanged", ri.room_id() == 4231, ri.room_id())

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

-- ---- duplicate short directions --------------------------------------------
-- Kills: inserting one exit entry per server label. Two labels can shorten to
-- the same key ("north" and "n" in one room), which would put a duplicate in
-- exits() and let the second label drop the first's destination. Unreachable
-- from today's mudlib; guarded so it stays that way by construction. The
-- resolved destination wins over the unresolved 0 whichever order pairs()
-- happens to visit them in.
deliver("Room.Info", { num = 4300, name = "A doubled hall", area = "Midgaard",
                       exits = { north = 4301, n = 0 } })
check("duplicate short direction appears once", sorted_concat(ri.exits()) == "n",
  sorted_concat(ri.exits()))
check("resolved destination survives the duplicate",
  ri.exit_destinations().n == 4301, tostring(ri.exit_destinations().n))
deliver("Room.Info", { num = 4301, name = "A doubled hall II", area = "Midgaard",
                       exits = { north = 0, n = 4302 } })
check("duplicate short direction appears once (reversed)",
  sorted_concat(ri.exits()) == "n", sorted_concat(ri.exits()))
check("resolved destination survives the duplicate (reversed)",
  ri.exit_destinations().n == 4302, tostring(ri.exit_destinations().n))

-- ---- id-less rooms (no-explorer virtual rooms) -------------------------------
-- Every Chaos Sea room reports num 0: room/room.c takes room_id from
-- query_unique_id(), which is only ever set from explorer_d::add_explored(),
-- and the maze room template calls set_no_explorer(1). The frame's name, area
-- and exits are still good and are the only room data that area ever provides.
deliver("Room.Info", {
  num = 0,
  name = "Layer one of the Sea of Chaos",
  area = "Unknown",
  exits = { out = 266, s = 0, w = 0, e = 0 },
})

check("id-less frame is accepted",
  ri.room() == "Layer one of the Sea of Chaos", tostring(ri.room()))
check("id-less frame reports no room id",
  ri.room_id() == nil, tostring(ri.room_id()))
check("id-less frame still carries exits",
  table.concat(ri.exits(), ",") == "e,s,w,out", table.concat(ri.exits(), ","))
check("id-less frame sets synced", ri.is_synced() == true)

-- A negative num is still refused: it is not a real mudlib answer, and
-- accepting it would mean keying on a value nothing can produce.
deliver("Room.Info", { num = -1, name = "Nowhere", area = "X", exits = {} })
check("negative num is still refused",
  ri.room() == "Layer one of the Sea of Chaos", tostring(ri.room()))

-- ---- on_room_info ------------------------------------------------------------
-- "a frame arrived" and "identity changed" are different questions. In the
-- Chaos Sea the id is nil and the name is the same for a whole layer, so
-- on_room_change fires once per layer while on_room_info fires per room.
local seen_a, seen_b, seen_c = {}, {}, {}
local id_a = ri.on_room_info(function(info) seen_a[#seen_a + 1] = info.room end)
local id_b = ri.on_room_info(function(info) seen_b[#seen_b + 1] = info.room end)
local id_c = ri.on_room_info(function(info) seen_c[#seen_c + 1] = info.room end)
check("on_room_info returns distinct ids", id_a ~= nil and id_b ~= nil and id_c ~= nil and id_a ~= id_b and id_b ~= id_c,
  tostring(id_a) .. "/" .. tostring(id_b) .. "/" .. tostring(id_c))

deliver("Room.Info", { num = 0, name = "Layer one of the Sea of Chaos",
                       area = "Unknown", exits = { s = 0, w = 0, e = 0 } })
check("on_room_info fires on an accepted frame", #seen_a == 1, tostring(#seen_a))
check("on_room_info fires for every registration", #seen_b == 1 and #seen_c == 1,
  tostring(#seen_b) .. "/" .. tostring(#seen_c))

-- Same name, same id: no identity change at all, but a frame did arrive.
deliver("Room.Info", { num = 0, name = "Layer one of the Sea of Chaos",
                       area = "Unknown", exits = { e = 0, w = 0 } })
check("on_room_info fires without an identity change", #seen_a == 2 and #seen_b == 2 and #seen_c == 2,
  tostring(#seen_a) .. "/" .. tostring(#seen_b) .. "/" .. tostring(#seen_c))

-- Removing the FIRST registration must not renumber the second or third. This is the
-- bug the on_room_change registry has: it allocates ids with table.insert and
-- releases them with table.remove, so every later id then points at the wrong
-- callback. The bug is only observable after a second removal.
check("off_room_info removes by id", ri.off_room_info(id_a) == true)
deliver("Room.Info", { num = 0, name = "Layer one of the Sea of Chaos",
                       area = "Unknown", exits = { n = 0 } })
check("removed callback stops firing", #seen_a == 2, tostring(#seen_a))
check("survivors still fire after a removal",
  #seen_b == 3 and #seen_c == 3, tostring(#seen_b) .. "/" .. tostring(#seen_c))

check("off_room_info removes a later id after an earlier removal",
  ri.off_room_info(id_c) == true)
deliver("Room.Info", { num = 0, name = "Layer one of the Sea of Chaos",
                       area = "Unknown", exits = { s = 0, n = 0 } })
check("a later id still addresses its own callback after an earlier removal",
  #seen_c == 3, tostring(#seen_c))
check("the untouched registration keeps firing", #seen_b == 4, tostring(#seen_b))
check("off_room_info on an unknown id is false", ri.off_room_info(id_a) == false)

-- One raising handler must not stop the rest (same convention as gmcp.on).
-- Wrap delivery in pcall so we can observe the failure as a named test case.
local after = 0
local id_raise = ri.on_room_info(function() error("boom") end)
local id_after = ri.on_room_info(function() after = after + 1 end)
print = function() end
local delivered = pcall(deliver, "Room.Info",
  { num = 0, name = "Layer one of the Sea of Chaos",
    area = "Unknown", exits = { s = 0 } })
print = print_real
check("a raising handler does not stop the rest",
  delivered and after == 1, tostring(delivered) .. "/" .. tostring(after))
ri.off_room_info(id_raise)
ri.off_room_info(id_after)
ri.off_room_info(id_b)

-- ---- on_room_contents --------------------------------------------------------
-- Mirrors on_room_info's registry exactly (same id shape, same renumbering and
-- raising-handler precedents), but fires only from commit_contents: once for a
-- complete single-page list, and once -- after the final page -- for a paged
-- one. Never from handle_room_contents, which also runs once per intermediate
-- page and would hand a consumer a partial list.
local rc_seen_a, rc_seen_b, rc_seen_c = {}, {}, {}
local rc_id_a = ri.on_room_contents(function(info) rc_seen_a[#rc_seen_a + 1] = info.monster_count end)
local rc_id_b = ri.on_room_contents(function(info) rc_seen_b[#rc_seen_b + 1] = info.monster_count end)
local rc_id_c = ri.on_room_contents(function(info) rc_seen_c[#rc_seen_c + 1] = info.monster_count end)
check("on_room_contents returns distinct ids",
  rc_id_a ~= nil and rc_id_b ~= nil and rc_id_c ~= nil and rc_id_a ~= rc_id_b and rc_id_b ~= rc_id_c,
  tostring(rc_id_a) .. "/" .. tostring(rc_id_b) .. "/" .. tostring(rc_id_c))

-- Kills: firing from handle_room_contents instead of commit_contents, which
-- would notify once per page rather than once per complete list.
deliver("Room.Contents", { full = 1, items = { { name = "a troll", type = "monster", count = 1 } } })
check("single-page list notifies once",
  #rc_seen_a == 1 and #rc_seen_b == 1 and #rc_seen_c == 1,
  tostring(#rc_seen_a) .. "/" .. tostring(#rc_seen_b) .. "/" .. tostring(#rc_seen_c))
check("single-page notify carries the committed count", rc_seen_a[1] == 1, tostring(rc_seen_a[1]))

-- Paged list: only the final page notifies, and only once.
deliver("Room.Contents", { full = 1, page = 1, pages = 2, items = {
  { name = "a goblin", type = "monster", count = 1 },
} })
check("intermediate page does not notify", #rc_seen_a == 1, tostring(#rc_seen_a))
deliver("Room.Contents", { full = 1, page = 2, pages = 2, items = {
  { name = "a bandit", type = "monster", count = 1 },
} })
check("final page notifies exactly once", #rc_seen_a == 2, tostring(#rc_seen_a))
check("final-page notify carries both pages' monsters", rc_seen_a[2] == 2, tostring(rc_seen_a[2]))

-- Kills: notifying before the page-order check, which would fire a notify for
-- a page that then gets discarded as out-of-order/mismatched.
deliver("Room.Contents", { full = 1, page = 1, pages = 2, items = {
  { name = "a wight", type = "monster", count = 1 },
} })
deliver("Room.Contents", { full = 1, page = 3, pages = 2, items = {
  { name = "a wraith", type = "monster", count = 1 },
} })
check("out-of-order page does not notify", #rc_seen_a == 2, tostring(#rc_seen_a))
-- The discarded accumulator must not poison the next list.
deliver("Room.Contents", { full = 1, items = { { name = "a specter", type = "monster", count = 1 } } })
check("handler recovers after a mismatched page", #rc_seen_a == 3, tostring(#rc_seen_a))

-- Removing the FIRST registration must not renumber the second or third; only
-- observable after a second removal (same precedent as on_room_info).
check("off_room_contents removes by id", ri.off_room_contents(rc_id_a) == true)
deliver("Room.Contents", { full = 1, items = { { name = "a rat", type = "monster", count = 1 } } })
check("removed callback stops firing", #rc_seen_a == 3, tostring(#rc_seen_a))
check("survivors still fire after a removal",
  #rc_seen_b == 4 and #rc_seen_c == 4, tostring(#rc_seen_b) .. "/" .. tostring(#rc_seen_c))

check("off_room_contents removes a later id after an earlier removal",
  ri.off_room_contents(rc_id_c) == true)
deliver("Room.Contents", { full = 1, items = { { name = "a rat", type = "monster", count = 1 } } })
check("a later id still addresses its own callback after an earlier removal",
  #rc_seen_c == 4, tostring(#rc_seen_c))
check("the untouched registration keeps firing", #rc_seen_b == 5, tostring(#rc_seen_b))
check("off_room_contents on an unknown id is false", ri.off_room_contents(rc_id_a) == false)

-- One raising handler must not stop the rest. Wrap delivery in pcall so we can
-- observe the failure as a named test case rather than aborting the suite.
local rc_after = 0
local rc_id_raise = ri.on_room_contents(function() error("boom") end)
local rc_id_after = ri.on_room_contents(function() rc_after = rc_after + 1 end)
print = function() end
local rc_delivered = pcall(deliver, "Room.Contents",
  { full = 1, items = { { name = "a rat", type = "monster", count = 1 } } })
print = print_real
check("a raising handler does not stop the rest",
  rc_delivered and rc_after == 1, tostring(rc_delivered) .. "/" .. tostring(rc_after))
ri.off_room_contents(rc_id_raise)
ri.off_room_contents(rc_id_after)
ri.off_room_contents(rc_id_b)

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
