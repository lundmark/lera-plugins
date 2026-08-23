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

-- ---- unload -----------------------------------------------------------------
ri.on_unload()
check("unregisters Room.Info", removed["Room.Info"] == true)

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
