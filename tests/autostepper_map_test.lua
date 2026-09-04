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

-- ---- BFS ---------------------------------------------------------------------
-- Build an explicit corridor so the shortest path is a known, exact string.
--
--   (0,0) e- (1,0) e- (2,0) e- (3,0) e->       <- east corridor; (3,0)'s e leads
--     |n                                          into unrecorded (4,0), so the
--   (0,1) n->                                     corridor HAS a far frontier
--
-- (3,0,0) must carry that "e". Without it the corridor is closed, and once
-- (0,1,0)'s "n" is removed below the whole map has no frontier at all --
-- search_frontier then correctly returns nil and the distant-path case fails on
-- the fixture rather than on anything it is testing.
--
-- From (0,0) the nearest frontier is north at distance 1 (room (0,1)'s n exit),
-- not the east corridor's far end at distance 3.
local function build(rooms)
  local mm = map_mod.new()
  for _, r in ipairs(rooms) do
    mm:set_position(r[1], r[2], r[3])
    mm:record(r[4])
  end
  mm:set_position(0, 0, 0)
  return mm
end

local corridor = build({
  { 0, 0, 0, { "e", "n" } },
  { 1, 0, 0, { "e", "w" } },
  { 2, 0, 0, { "e", "w" } },
  { 3, 0, 0, { "w", "e" } },
  { 0, 1, 0, { "s", "n" } },
})

local path = corridor:search_frontier({})
check("nearest frontier wins over a distant one",
  table.concat(path or {}, "") == "nn", table.concat(path or {}, ","))

-- Remove the near frontier: (0,1)'s n exit goes away, so the only frontier left
-- is at the far end of the corridor and the path must be the exact shortest
-- route. A LIFO queue -- which is what legacy's "BFS" actually was -- returns a
-- longer path here or reaches the frontier the long way round.
corridor:set_position(0, 1, 0)
corridor:record({ "s" })
corridor:set_position(0, 0, 0)
path = corridor:search_frontier({})
check("path to a distant frontier is the exact shortest route",
  table.concat(path or {}, "") == "eeee", table.concat(path or {}, ","))

-- Two searches in a row on the same map. Legacy stored parent pointers on the
-- room records and needed a defensive sweep to clear them, because an aborted
-- search left them behind and poisoned the next one.
local again = corridor:search_frontier({})
check("a second search on the same map gives the same answer",
  table.concat(again or {}, "") == "eeee", table.concat(again or {}, ","))

-- Fully explored map: every exit leads somewhere recorded.
local closed = build({
  { 0, 0, 0, { "e" } },
  { 1, 0, 0, { "w" } },
})
check("a fully explored map has no frontier", closed:search_frontier({}) == nil,
  table.concat(closed:search_frontier({}) or {}, ","))

-- Standing somewhere unrecorded is not a search failure to paper over.
local orphan = map_mod.new()
orphan:set_position(5, 5, 5)
check("searching from an unrecorded room returns nil",
  orphan:search_frontier({}) == nil)

-- A frontier reachable only through an unrecorded coordinate is not reachable:
-- the search walks recorded rooms, and an exit into the void IS the frontier.
local disjoint = build({
  { 0, 0, 0, { "e" } },
  { 5, 0, 0, { "e", "w" } },
})
path = disjoint:search_frontier({})
check("the search does not teleport across a gap",
  table.concat(path or {}, "") == "e", table.concat(path or {}, ","))

-- FIFO vs LIFO needs a graph the corridor cannot provide. Every fixture above
-- has a reachable graph that is a TREE -- one route per room -- and in a tree
-- both queue disciplines yield the same dist, because dist is assigned at
-- DISCOVERY time and a tree room is discovered exactly once. The bug legacy
-- actually shipped (reading the last pushed entry, making its "BFS" a DFS) only
-- shows where a room is reachable by two routes of different length AND the
-- longer one is explored first. DIR_ORDER puts "n" before "e", so a stack pops
-- the "e" branch first -- which is why the long route hangs off "e" here.
--
--   (0,2) F <-w- (1,2)      F = (0,2,0); its "n" leads to unrecorded (0,3,0)
--     ^n           ^n       short route: n,n      (dist 2)
--   (0,1)        (1,1)      long route:  e,n,n,w  (dist 4)
--     ^n           ^n
--   (0,0) --e---> (1,0)
local twoway = build({
  { 0, 0, 0, { "n", "e" } },
  { 0, 1, 0, { "s", "n" } },
  { 0, 2, 0, { "s", "n", "e" } },
  { 1, 0, 0, { "w", "n" } },
  { 1, 1, 0, { "s", "n" } },
  { 1, 2, 0, { "s", "w" } },
})
local tw = twoway:search_frontier({})
check("the shortest of two routes to one frontier wins",
  table.concat(tw or {}, "") == "nnn", table.concat(tw or {}, ","))

-- ---- termination and cost ----------------------------------------------------
-- The real upper bound from setup_maze: min(8, 3+diff/20) floors of
-- min(50+diff*1.25, 250) rooms. 8 x 250 = 2000 rooms, fully connected in a line
-- per floor, with exactly one frontier at the very end.
local big = map_mod.new()
for z = 0, 7 do
  for i = 0, 249 do
    big:set_position(i, 0, z)
    local exits = {}
    if i > 0 then exits[#exits + 1] = "w" end
    if i < 249 then exits[#exits + 1] = "e" end
    -- Gated to match DELTA, which is the ordinary convention here: u is z+1 and
    -- d is z-1. So "u" needs a floor ABOVE (z < 7) and "d" needs one BELOW
    -- (z > 0). Inverting these adds a "d" at z=0 into unrecorded (0,0,-1) and a
    -- "u" at z=7 into (0,0,8) -- two extra frontiers, one of them at distance 0
    -- from the origin, which the search then correctly prefers over the single
    -- deep frontier this fixture exists to find.
    if z < 7 and i == 0 then exits[#exits + 1] = "u" end
    if z > 0 and i == 0 then exits[#exits + 1] = "d" end
    big:record(exits)
  end
end
-- Open one frontier: the deepest floor's far end gains a south exit.
big:set_position(249, 0, 7)
big:record({ "w", "s" })
big:set_position(0, 0, 0)
check("the 2000-room map is fully recorded", big:count() == 2000, tostring(big:count()))
local big_path = big:search_frontier({})
check("the search terminates on a 2000-room map", big_path ~= nil)
check("and finds the single frontier",
  big_path and big_path[#big_path] == "s", big_path and big_path[#big_path])

-- ---- policy ------------------------------------------------------------------
-- One room with an unexplored 'u' and an unexplored 'e', plus a far room with an
-- unexplored 'd'. Distances: e and u are 0 away, d is 3 away.
local policy_map = build({
  { 0, 0, 0, { "e", "u", "s" } },
  { 0, -1, 0, { "n", "s" } },
  { 0, -2, 0, { "n", "s" } },
  { 0, -3, 0, { "n", "d" } },
})

local clear = policy_map:next_frontier({ policy = "clear", dive_dirs = { "d" },
                                         defer_dirs = { "u" } })
check("clear takes the nearest frontier",
  table.concat(clear or {}, "") == "e", table.concat(clear or {}, ","))

-- With 'e' explored away, only 'u' (here) and 'd' (three rooms south) remain.
-- clear ranks a deferred direction last, but it is still nearer, so it wins.
policy_map:set_position(1, 0, 0)
policy_map:record({ "w" })
policy_map:set_position(0, 0, 0)
clear = policy_map:next_frontier({ policy = "clear", dive_dirs = { "d" },
                                   defer_dirs = { "u" } })
check("clear still prefers a near deferred exit over a far ordinary one",
  table.concat(clear or {}, "") == "u", table.concat(clear or {}, ","))

-- dive goes for the descent wherever it is: three rooms south, then down.
local dive = policy_map:next_frontier({ policy = "dive", dive_dirs = { "d" },
                                        defer_dirs = { "u" } })
check("dive prefers a distant descent over a near frontier",
  table.concat(dive or {}, "") == "sssd", table.concat(dive or {}, ","))

-- With no descent anywhere, dive falls back to clear rather than giving up.
local nodive = build({ { 0, 0, 0, { "e" } } })
local fallback = nodive:next_frontier({ policy = "dive", dive_dirs = { "d" },
                                        defer_dirs = { "u" } })
check("dive falls back to clear when nothing descends",
  table.concat(fallback or {}, "") == "e", table.concat(fallback or {}, ","))

-- Tie-breaking must be deterministic, or the explorer picks differently on two
-- identical maps and nothing here is testable.
local tie = build({ { 0, 0, 0, { "e", "n", "w", "s" } } })
local first = tie:next_frontier({ policy = "clear", defer_dirs = { "u" } })
local second = tie:next_frontier({ policy = "clear", defer_dirs = { "u" } })
check("equal-distance ties break in compass order",
  table.concat(first or {}, "") == "n", table.concat(first or {}, ","))
check("tie-breaking is stable across calls",
  table.concat(first or {}, "") == table.concat(second or {}, ","))

-- A deferred direction must LOSE an equal-distance tie. The tie map above cannot
-- show this: it has no vertical exit, so defer_dirs never applies to it and a
-- rank function that ranked deferred directions FIRST would still pass. This map
-- puts a deferred exit and an ordinary one at the same distance, which is the
-- only shape that discriminates.
local defertie = build({ { 0, 0, 0, { "u", "n" } } })
local dt = defertie:next_frontier({ policy = "clear", defer_dirs = { "u" } })
check("a deferred direction loses an equal-distance tie",
  table.concat(dt or {}, "") == "n", table.concat(dt or {}, ","))

-- ---- path_to -------------------------------------------------------------
-- Reuses the shape of the "twoway" fixture above (two routes to one target,
-- of different lengths), rebuilt fresh so this section does not depend on
-- anything mutated onto the earlier `twoway` object.
--
--   (0,2) T <-w- (1,2)      T = (0,2,0); a RECORDED room, unlike the
--     ^n           ^n       search_frontier fixture's unrecorded frontier.
--   (0,1)        (1,1)      short route: n,n      (dist 2)
--     ^n           ^n       long route:  e,n,n,w  (dist 4)
--   (0,0) --e---> (1,0)
local function build_twoway()
  return build({
    { 0, 0, 0, { "n", "e" } },
    { 0, 1, 0, { "s", "n" } },
    { 0, 2, 0, { "s", "n", "e" } },
    { 1, 0, 0, { "w", "n" } },
    { 1, 1, 0, { "s", "n" } },
    { 1, 2, 0, { "s", "w" } },
  })
end

local pt = build_twoway()
local pt_route = pt:path_to(0, 2, 0)
check("path_to returns the exact shortest path between two recorded rooms",
  table.concat(pt_route or {}, "") == "nn", table.concat(pt_route or {}, ","))

check("path_to at the current position returns an empty array, not nil",
  (function()
    local here = pt:path_to(0, 0, 0)
    return here ~= nil and #here == 0
  end)(),
  tostring(pt:path_to(0, 0, 0)))

check("path_to to an unrecorded coordinate returns nil",
  pt:path_to(9, 9, 9) == nil)

-- A second, genuinely disconnected component: an island room with no exits
-- of its own and nothing else's exit pointing at it.
local disc = map_mod.new()
disc:record({ "e" })              -- (0,0,0)
disc:set_position(1, 0, 0)
disc:record({ "w" })              -- (1,0,0), connected back to the origin
disc:set_position(50, 50, 50)
disc:record({})                   -- an island: recorded, but reachable from nowhere
disc:set_position(0, 0, 0)
check("path_to a recorded but unreachable room returns nil",
  disc:path_to(50, 50, 50) == nil)

-- Two consecutive calls must not interfere with each other. Calling with the
-- SAME start and target twice cannot discriminate dist/prev hoisted to
-- module scope: nothing about the search changes between the calls, so
-- stale leftover state happens to reproduce the same correct answer. The
-- second call needs a DIFFERENT start and target so a leftover dist/prev
-- table -- pre-populated with coordinates and distances relative to the
-- FIRST call's start -- has something to corrupt: with dist/prev hoisted,
-- the previously-visited nodes never get re-discovered relative to the new
-- start, and the target (already marked reachable from the earlier call)
-- reports a path built from the stale prev chain, walking back to the
-- WRONG start.
local pt_again = pt:path_to(0, 2, 0)
check("path_to from the same start to the same target agrees on repeat",
  table.concat(pt_again or {}, "") == "nn", table.concat(pt_again or {}, ","))

pt:set_position(1, 0, 0)
local pt_second = pt:path_to(1, 2, 0)
check("a second path_to call from a different start is not corrupted by the first",
  table.concat(pt_second or {}, "") == "nn", table.concat(pt_second or {}, ","))

-- ---- per-map vertical convention (Task V) ------------------------------------
-- The Chaos Sea capture (sea.log) proved that 'd' increases z there instead of
-- decreasing it -- the ordinary lattice convention DELTA declares is not
-- universal. M.new(opts.vertical) lets an area profile override the z
-- component of 'u'/'d' per map, so a vertical exit predicts the coordinate the
-- area actually generates instead of a permanent phantom frontier.

-- M.new with no opts, and M.new({}), must both keep today's ordinary
-- convention: an area that declares nothing is unaffected.
local ordinary = map_mod.new()
check("a map with no vertical option moves 'd' the ordinary way (z-1)",
  (function()
     ordinary:move("d")
     local _, _, oz = ordinary:position()
     return oz == -1
   end)())
local ordinary_empty = map_mod.new({})
check("a map with an empty opts table also keeps the ordinary convention",
  (function()
     ordinary_empty:move("d")
     local _, _, oz = ordinary_empty:position()
     return oz == -1
   end)())

-- Property: move() follows the declared direction. Sea of Chaos convention:
-- 'd' is z+1, 'u' is z-1.
local inverted = map_mod.new({ vertical = { d = 1, u = -1 } })
inverted:move("d")
local ix, iy, iz = inverted:position()
check("move follows the declared vertical convention ('d' is z+1)",
  ix == 0 and iy == 0 and iz == 1, ix .. "," .. iy .. "," .. iz)
inverted:move("u")
ix, iy, iz = inverted:position()
check("move follows the declared vertical convention ('u' is z-1)",
  ix == 0 and iy == 0 and iz == 0, ix .. "," .. iy .. "," .. iz)

-- Property: with vertical declared, 'd' from z=1 predicts z=2 -- so a vertical
-- exit into an already-visited room is NOT a frontier. This is the owner's
-- capture in miniature: Layer two (z=1) and Layer three (z=2), joined by d/u,
-- both mapped.
local capture = map_mod.new({ vertical = { d = 1, u = -1 } })
capture:set_position(8, 6, 1)
capture:record({ "d" })
capture:set_position(8, 6, 2)
capture:record({ "u" })
capture:set_position(8, 6, 1)
local capture_frontier = capture:frontier_dirs(capture:room(8, 6, 1))
check("a vertical exit to a visited room is not a frontier once vertical is declared",
  #capture_frontier == 0, table.concat(capture_frontier, ","))
-- Reverse view: from the deeper room, 'u' back to the shallower one is
-- likewise not a frontier.
capture:set_position(8, 6, 2)
local capture_frontier2 = capture:frontier_dirs(capture:room(8, 6, 2))
check("the reverse vertical exit is not a frontier either",
  #capture_frontier2 == 0, table.concat(capture_frontier2, ","))

-- Ignoring opts.vertical in M.new is the mutant for the two properties above:
-- with the ordinary convention, 'd' from z=1 predicts z=0 (never recorded),
-- so it would stay a permanent frontier and frontier_dirs would return {"d"}
-- instead of {}. Confirmed by hand against the ordinary map built earlier:
check("ordinary convention: a fresh map's 'd' from a recorded room IS still a frontier",
  (function()
     local plain = map_mod.new()
     plain:set_position(8, 6, 1)
     plain:record({ "d" })
     local f = plain:frontier_dirs(plain:room(8, 6, 1))
     return #f == 1 and f[1] == "d"
   end)())

-- Property: search_frontier (and therefore next_frontier/the traversal it
-- shares with path_to) crosses the declared vertical edge to reach a frontier
-- recorded on the OTHER side of it. A(8,6,1) --d--> B(8,6,2), and B has an
-- unexplored 'e'. If only frontier_dirs honoured the declared convention (and
-- the BFS traversal loop that discovers B still used the ordinary DELTA), the
-- BFS would compute A's 'd' neighbour as (8,6,0) -- unrecorded -- so it would
-- never enqueue B at all, and the frontier at B's 'e' would never be found.
local cross = map_mod.new({ vertical = { d = 1, u = -1 } })
cross:set_position(8, 6, 1)
cross:record({ "d" })
cross:set_position(8, 6, 2)
cross:record({ "u", "e" })
cross:set_position(8, 6, 1)
local cross_path = cross:search_frontier({})
check("search_frontier crosses the declared vertical edge to a farther frontier",
  table.concat(cross_path or {}, "") == "de", table.concat(cross_path or {}, ","))

-- Property: two maps with different vertical conventions do not share state.
-- Built in an order chosen to catch a module-level (rather than per-instance)
-- delta table: the SECOND map's construction must not retroactively change
-- the FIRST map's already-built delta.
local map_a = map_mod.new({ vertical = { d = 1, u = -1 } })
local map_b = map_mod.new()  -- ordinary convention, built after map_a
map_a:move("d")
map_b:move("d")
local ax, ay, az = map_a:position()
local bx, by, bz = map_b:position()
check("two maps built with different vertical options move independently",
  az == 1 and bz == -1, "a=" .. az .. " b=" .. bz)
-- And the reverse construction order, so this cannot pass by accident of
-- which map happened to be built first.
local map_c = map_mod.new()  -- ordinary convention, built first this time
local map_d = map_mod.new({ vertical = { d = 1, u = -1 } })
map_c:move("d")
map_d:move("d")
local cx, cy, cz = map_c:position()
local dx, dy, dz = map_d:position()
check("construction order does not matter -- neither map leaks into the other",
  cz == -1 and dz == 1, "c=" .. cz .. " d=" .. dz)

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
