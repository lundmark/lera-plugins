-- guild_viking pathfinding.lua (vmap BFS) unit tests. Run from the
-- lera-plugins repo root with LERA_ROOT pointing at a built Lera checkout.
package.path = "3scapes/guild_viking/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- ---- lera API stubs (same shape as guild_viking_voyage_test.lua; only
-- ui.dirty is actually exercised -- protocol.ingest's dispatch calls it on
-- every successful handler) --------------------------------------------------
local dirty_count = 0
ui = { dirty = function() dirty_count = dirty_count + 1 end }

local state = require("state")
local pathfinding = require("pathfinding")

-- ---- real ingestion pipeline (protocol.ingest -> handlers.voyage), the SAME
-- registration guild_viking_voyage_test.lua and guild_viking_popup_map_test.lua
-- use -- vmap fixtures are driven through production code, never poked into
-- S by hand. This is the discipline that would have caught a previous
-- stage's Critical: a consumer read S.vmap_rows[r] where the handlers write
-- [ridx+1], and hand-poked fixtures agreed with the bug instead of exposing
-- it.
local protocol = require("protocol")
local voyage = require("handlers.voyage")
for key, fn in pairs(voyage) do
  if key ~= "_patterns" then protocol.handler(key, fn) end
end
for _, p in ipairs(voyage._patterns or {}) do
  protocol.pattern_handler(p.pattern, p.fn)
end

local S = state.S

-- Seeds vmap state via the real handlers, exactly like
-- guild_viking_popup_map_test.lua's seed_vmap. `rows`/`east_edges`/
-- `south_edges` are plain 1-based Lua arrays in WIRE order (rows[1] is wire
-- row 0, i.e. VMR00); seed_vmap does the wire_row-1 translation into the
-- VMR%02d/MEE%02d/MES%02d keys itself, so THIS file never assumes an
-- indexing convention -- it only has to write natural top-to-bottom rows.
local function seed_vmap(t)
  protocol.ingest("VMAPH", string.format("%d|%d|%d|%d",
    t.w, t.h, t.px or -1, t.py or -1))
  for wire_row, row in ipairs(t.rows or {}) do
    protocol.ingest(string.format("VMR%02d", wire_row - 1), row)
  end
  for wire_row, edge in ipairs(t.east_edges or {}) do
    protocol.ingest(string.format("MEE%02d", wire_row - 1), edge)
  end
  for wire_row, edge in ipairs(t.south_edges or {}) do
    protocol.ingest(string.format("MES%02d", wire_row - 1), edge)
  end
end

local function reset_vmap()
  S.vmap_w, S.vmap_h = 0, 0
  S.vmap_px, S.vmap_py = -1, -1
  S.vmap_rows = {}
  S.vmap_east_edges = {}
  S.vmap_south_edges = {}
end

local function path_str(path)
  if not path then return "nil" end
  return "{" .. table.concat(path, ",") .. "}"
end

local function paths_equal(path, expected)
  if not path then return false end
  if #path ~= #expected then return false end
  for i = 1, #path do
    if path[i] ~= expected[i] then return false end
  end
  return true
end

-- =============================================================================
-- Case 1: straight-line path, no obstacles.
--
--   col:      0     1     2
--   row0:   (0,0)-1->(1,0)-1->(2,0)   all tiles 'p' (plains)
--
--   Start=(0,0)  Goal=(2,0)
--   Expected path: {"east", "east"}
-- =============================================================================
reset_vmap()
seed_vmap({
  w = 3, h = 1,
  rows = { "ppp" },
  east_edges = { "111" },
})
local p1 = pathfinding.bfs(0, 0, 2, 0)
check("straight-line: path found", p1 ~= nil, path_str(p1))
check("straight-line: exact route", p1 and paths_equal(p1, { "east", "east" }), path_str(p1))

-- =============================================================================
-- Case 2: detour forced by a blocked east edge.
--
--   col:        0        1        2
--   row0:    (0,0)p --X-- (1,0)p --1-- (2,0)p     (X = east edge of (0,0) blocked)
--               |1                       |1
--   row1:    (0,1)p --1-- (1,1)p --1-- (2,1)p
--
--   east_edges[row0] = "011"  (col0 blocked, col1/col2 open)
--   east_edges[row1] = "111"  (all open)
--   south_edges[row0] = "111" (col0/col1/col2 open, connecting row0<->row1)
--
--   Start=(0,0)  Goal=(2,0). Direct east route is blocked at (0,0)->(1,0), so
--   BFS must detour down and around: south, east, north, east.
--   (Hand-traced against the neighbour order north/south/east/west and the
--   FIFO queue -- see task report for the full trace.)
-- =============================================================================
reset_vmap()
seed_vmap({
  w = 3, h = 2,
  rows = { "ppp", "ppp" },
  east_edges = { "011", "111" },
  south_edges = { "111" },
})
check("east-edge detour: MEE00 landed at the real 1-indexed storage position",
  S.vmap_east_edges[1] == "011")
local p2 = pathfinding.bfs(0, 0, 2, 0)
check("east-edge detour: path found", p2 ~= nil, path_str(p2))
check("east-edge detour: exact route",
  p2 and paths_equal(p2, { "south", "east", "north", "east" }), path_str(p2))

-- =============================================================================
-- Case 3: detour forced by a blocked south edge.
--
--   col:       0                 1
--   row0:   (0,0)p ----1---- (1,0)p
--             |X (blocked)        |1
--   row1:   (0,1)p ----1---- (1,1)p
--             |1                  |1
--   row2:   (0,2)p ----1---- (1,2)p
--
--   south_edges[row0] = "01"  (col0 blocked, col1 open)
--   south_edges[row1] = "11"  (both open)
--   east_edges[*]     = "10"  (col0 open; col1's east edge is unused, w=2)
--
--   Start=(0,0)  Goal=(0,2). Direct south route is blocked at (0,0)->(0,1),
--   so BFS must detour across and back down: east, south, south, west.
-- =============================================================================
reset_vmap()
seed_vmap({
  w = 2, h = 3,
  rows = { "pp", "pp", "pp" },
  east_edges = { "10", "10", "10" },
  south_edges = { "01", "11" },
})
check("south-edge detour: MES00 landed at the real 1-indexed storage position",
  S.vmap_south_edges[1] == "01")
local p3 = pathfinding.bfs(0, 0, 0, 2)
check("south-edge detour: path found", p3 ~= nil, path_str(p3))
check("south-edge detour: exact route",
  p3 and paths_equal(p3, { "east", "south", "south", "west" }), path_str(p3))

-- =============================================================================
-- Case 4: unreachable target (impassable water tile blocks the only route)
-- returns nil, even though every edge is fully open.
--
--   col:      0     1     2
--   row0:   (0,0)p-1->(1,0)W-1->(2,0)p    (W = water, impassable tile)
--
--   Start=(0,0)  Goal=(2,0). No route exists.
-- =============================================================================
reset_vmap()
seed_vmap({
  w = 3, h = 1,
  rows = { "pWp" },
  east_edges = { "111" },
})
local p4 = pathfinding.bfs(0, 0, 2, 0)
check("unreachable: returns nil", p4 == nil, path_str(p4))

-- =============================================================================
-- Case 5: start == goal returns an empty path immediately (matches MAIN
-- 12123/12181/12351's "#path == 0 -> already there" branch), independent of
-- grid contents.
-- =============================================================================
reset_vmap()
seed_vmap({ w = 1, h = 1, rows = { "p" } })
local p5 = pathfinding.bfs(0, 0, 0, 0)
check("start==goal: returns a table, not nil", type(p5) == "table", path_str(p5))
check("start==goal: empty path", p5 and #p5 == 0, path_str(p5))

-- =============================================================================
-- Case 6: exact element shape. Every path element is a plain Lua string,
-- exactly one of "north"/"south"/"east"/"west" (case-sensitive), in travel
-- order -- the shape MAIN's `for _, dir in ipairs(path) do Send(dir) end`
-- depends on.
-- =============================================================================
local VALID_DIRS = { north = true, south = true, east = true, west = true }
reset_vmap()
seed_vmap({
  w = 3, h = 1,
  rows = { "ppp" },
  east_edges = { "111" },
})
local p6 = pathfinding.bfs(0, 0, 2, 0)
check("element shape: is a table", type(p6) == "table", path_str(p6))
check("element shape: exact length", p6 and #p6 == 2, path_str(p6))
local all_valid = true
if p6 then
  for i, dir in ipairs(p6) do
    if type(dir) ~= "string" or not VALID_DIRS[dir] then all_valid = false end
  end
end
check("element shape: every entry is a bare direction string", all_valid, path_str(p6))
check("element shape: first two moves are both 'east'",
  p6 and p6[1] == "east" and p6[2] == "east", path_str(p6))

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING PATHFINDING TESTS PASSED")
