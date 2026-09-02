-- autostepper explore/map.lua unit tests. Run from the lera-plugins repo root
-- with LERA_ROOT pointing at a built Lera checkout.
--
-- map.lua is pure: no lera API, no MUD, no I/O. That is deliberate, because
-- every bug the legacy chaossea explorer shipped lived in exactly this code --
-- inverted diagonal deltas, a BFS that was really a LIFO stack, and search
-- state left behind on rooms between searches -- and each is an executable
-- mutant here.
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

local map_mod = require("explore.map")

-- ---- direction deltas --------------------------------------------------------
-- The eight compass deltas mirror the switch in
-- players/setinekht/maze/maze.c:588-645. The legacy script shipped nw and se
-- inverted for a while, which silently folded distinct rooms onto one
-- coordinate.
--
-- u and d are the ORDINARY lattice convention (up = z+1) and are deliberately
-- NOT claimed to match the Chaos Sea, which inverts them: its
-- set_level_exit_pairs((["down":"up"])) makes "down" the level-UP direction, and
-- the override at maze.c:646-652 runs after the plain case labels and wins, so
-- "down" increases z there. That is why explore/mode.lua takes z from the room
-- name rather than from these values -- see its on_arrival. These entries are
-- the fallback for an area whose name carries no layer.
local EXPECTED = {
  n  = {  0,  1,  0 },
  s  = {  0, -1,  0 },
  e  = {  1,  0,  0 },
  w  = { -1,  0,  0 },
  ne = {  1,  1,  0 },
  nw = { -1,  1,  0 },
  se = {  1, -1,  0 },
  sw = { -1, -1,  0 },
  u  = {  0,  0,  1 },
  d  = {  0,  0, -1 },
}
local delta_ok, delta_bad = true, nil
for dir, want in pairs(EXPECTED) do
  local got = map_mod.DELTA[dir]
  if not got or got[1] ~= want[1] or got[2] ~= want[2] or got[3] ~= want[3] then
    delta_ok = false
    delta_bad = dir
  end
end
check("direction deltas match the mudlib switch", delta_ok, tostring(delta_bad))

local delta_count = 0
for _ in pairs(map_mod.DELTA) do delta_count = delta_count + 1 end
check("exactly ten walkable directions", delta_count == 10, tostring(delta_count))

-- ---- recording ---------------------------------------------------------------
local m = map_mod.new()
local x, y, z = m:position()
check("a new map starts at the origin", x == 0 and y == 0 and z == 0,
  x .. "," .. y .. "," .. z)
check("a new map has no rooms", m:count() == 0, tostring(m:count()))

m:record({ "n", "e" })
check("record creates the room we stand in", m:visited(0, 0, 0) == true)
check("record counts one room", m:count() == 1, tostring(m:count()))
local here = m:room(0, 0, 0)
check("record stores the exits", here.exits.n == true and here.exits.e == true)
check("record stores no other exits", here.exits.s == nil and here.exits.w == nil)

-- Exits with no delta are not walkable and are never recorded. 'out' leaves the
-- maze entirely; recording it would let the explorer walk out of the area it
-- was asked to map.
m:record({ "n", "e", "out", "enter", "in" })
here = m:room(0, 0, 0)
check("non-walkable exits are dropped", here.exits.out == nil and here.exits.enter == nil
  and here.exits["in"] == nil)
check("re-recording keeps the exits still reported",
  here.exits.n == true and here.exits.e == true)

-- Replace, not merge -- and this needs its own map. The case above cannot show
-- it: both records list n and e, so a merging implementation produces exactly
-- the same table and passes. The property only becomes visible when an exit
-- STOPS being reported. A separate map keeps the main sequence's origin at
-- {n,e}, which the frontier case below depends on.
local rep = map_mod.new()
rep:record({ "n", "e" })
rep:record({ "n" })
local rep_room = rep:room(0, 0, 0)
check("re-recording drops an exit no longer reported",
  rep_room.exits.n == true and rep_room.exits.e == nil,
  tostring(rep_room.exits.n) .. "/" .. tostring(rep_room.exits.e))

-- ---- movement ----------------------------------------------------------------
check("move follows the delta", m:move("n") == true)
x, y, z = m:position()
check("north increments y", x == 0 and y == 1 and z == 0, x .. "," .. y .. "," .. z)
check("move refuses a direction with no delta", m:move("out") == false)
x, y, z = m:position()
check("a refused move does not shift position", x == 0 and y == 1 and z == 0,
  x .. "," .. y .. "," .. z)
m:record({ "s" })
check("recording after a move creates the new coordinate", m:visited(0, 1, 0) == true)
check("the origin is still recorded", m:visited(0, 0, 0) == true)
check("two rooms recorded", m:count() == 2, tostring(m:count()))

-- ---- frontier ----------------------------------------------------------------
-- The origin has exits n and e. n now leads to a visited room; e does not.
local frontier = m:frontier_dirs(m:room(0, 0, 0))
check("frontier excludes exits into visited rooms",
  #frontier == 1 and frontier[1] == "e", table.concat(frontier, ","))

local none = m:frontier_dirs(m:room(0, 1, 0))
check("a room whose only exit is visited has no frontier",
  #none == 0, table.concat(none, ","))

-- ---- same_exits --------------------------------------------------------------
check("same_exits accepts identical sets",
  map_mod.same_exits({ n = true, e = true }, { e = true, n = true }) == true)
check("same_exits rejects an extra exit",
  map_mod.same_exits({ n = true }, { n = true, e = true }) == false)
check("same_exits rejects a missing exit",
  map_mod.same_exits({ n = true, e = true }, { n = true }) == false)
check("same_exits accepts two empty sets", map_mod.same_exits({}, {}) == true)

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
