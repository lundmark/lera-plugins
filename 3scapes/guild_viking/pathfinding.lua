-- Pathfinding: BFS across the vmap terrain/edge grid, ported verbatim from
-- LEGACY guild_viking.lua:11689-11761 (vmap_bfs). PURE module: reads
-- S.vmap_w / S.vmap_h / S.vmap_rows / S.vmap_east_edges / S.vmap_south_edges
-- only; sends nothing, prints nothing, mutates no state. Later tasks (the
-- map popup's POI travel and the People pane's mission/errand "Run There")
-- own dispatching the returned directions through mud.send.
--
-- Return shape is pinned to LEGACY's three call sites (MAIN 12123, 12181,
-- 12351: `local path = vmap_bfs(state.vmap_px, state.vmap_py, tx, ty)`),
-- all of which use the result the same way:
--   if not path then                 -- no passable route -> nil
--   elseif #path == 0 then           -- already at the target -> {}
--   else for _, dir in ipairs(path) do Send(dir) end   -- direction strings
-- This module reproduces exactly that: nil, an empty table, or an array of
-- "north"/"south"/"east"/"west" strings in travel order. Those three sites
-- are NOT ported here -- this task only produces the value they consume.
--
-- Indexing: LEGACY reads state.vmap_rows[y+1], state.vmap_east_edges[cy+1]
-- and state.vmap_south_edges[cy+1] (MAIN 11709-11731) -- 1-indexed Lua
-- storage for a 0-based wire row/coordinate. handlers/voyage.lua's
-- vmr_row/mee_row/mes_row (LEGACY 2571-2579) write S.vmap_rows[ridx+1],
-- S.vmap_east_edges[ridx+1] and S.vmap_south_edges[ridx+1] with the
-- identical `ridx+1` convention -- verified by reading the handler source
-- directly (see task report), not inferred from comments -- so these reads
-- carry over with NO adaptation.
--
-- No other adaptation: same neighbour order (north, south, east, west),
-- same FIFO array-queue BFS, same parent-chain path reconstruction, same
-- terrain/edge passability rules. LEGACY's `explored` counter (MAIN 11694,
-- 11737) is retained even though nothing in the function or the rest of
-- guild_viking.lua ever reads it -- it is genuinely dead bookkeeping, not a
-- side effect to preserve, but dropping it would be "cleaning up" the
-- traversal rather than porting it, so it stays.
--
-- Testability adaptation (review round 1): `tile_passable`/`edge_passable`/
-- `can_move` are exposed as `M._tile_passable`/`M._edge_passable`/
-- `M._can_move` purely so tests can pin their indexing directly against a
-- known row/edge string, instead of only through BFS's aggregate nil/path
-- answer (which can hide a mutant when two indexing errors happen to
-- cancel out -- see the pathfinding test file's header for the concrete
-- case). This is exposure only: no behavior, traversal, passability rule,
-- or return shape changed.
local S = require("state").S

local M = {}

-- LEGACY:11697-11700 (tile_passable). Water (W) and river rooms (r) are
-- impassable; everything else is open.
local function tile_passable(x, y)
  local tile = (S.vmap_rows[y + 1] or ""):sub(x + 1, x + 1)
  return tile ~= "W" and tile ~= "r"
end

-- LEGACY:11701-11722 (edge_passable). "1" means passable, everything else
-- (including a missing row, which reads back as ""->"" via :sub) means NOT
-- passable. That is a deliberate fail-closed default: a boundary this
-- module has no explicit "1" for is treated as blocked for movement. This
-- differs from popups/map.lua's edge_blocked, which treats missing data as
-- "no wall to draw" (its concern is rendering, not routing) -- both are
-- correct for their own purpose, and porting vmap_bfs verbatim means
-- keeping ITS default rather than aligning with the renderer's.
local function edge_passable(cx, cy, nx, ny)
  if nx > cx then
    -- Moving east: check east edge of current tile
    local edge_str = S.vmap_east_edges[cy + 1] or ""
    local edge_char = edge_str:sub(cx + 1, cx + 1)
    return edge_char == "1"
  elseif nx < cx then
    -- Moving west: check east edge of destination tile
    local edge_str = S.vmap_east_edges[ny + 1] or ""
    local edge_char = edge_str:sub(nx + 1, nx + 1)
    return edge_char == "1"
  elseif ny > cy then
    -- Moving south: check south edge of current tile
    local edge_str = S.vmap_south_edges[cy + 1] or ""
    local edge_char = edge_str:sub(cx + 1, cx + 1)
    return edge_char == "1"
  elseif ny < cy then
    -- Moving north: check south edge of destination tile
    local edge_str = S.vmap_south_edges[ny + 1] or ""
    local edge_char = edge_str:sub(nx + 1, nx + 1)
    return edge_char == "1"
  end
  return true
end

-- LEGACY:11724-11726 (can_move).
local function can_move(cx, cy, nx, ny, gw, gh)
  return nx >= 0 and nx < gw and ny >= 0 and ny < gh
    and tile_passable(nx, ny) and edge_passable(cx, cy, nx, ny)
end

-- LEGACY:11689-11761 (vmap_bfs). BFS across the terrain grid from (fx,fy)
-- to (tx,ty). Returns an array of direction strings, {} when already at
-- the target, or nil when no passable route exists.
function M.bfs(fx, fy, tx, ty)
  if fx == tx and fy == ty then return {} end
  local gw, gh = S.vmap_w, S.vmap_h
  local vis, par = {}, {}
  local qx, qy, head, tail = {}, {}, 1, 1
  local explored = 0  -- Must be declared before nested functions
  local function key(x, y) return y * gw + x end
  qx[1] = fx; qy[1] = fy; vis[key(fx, fy)] = true
  local dirs = { { 0, -1, "north" }, { 0, 1, "south" }, { 1, 0, "east" }, { -1, 0, "west" } }
  while head <= tail do
    local cx, cy = qx[head], qy[head]; head = head + 1
    explored = explored + 1
    if cx == tx and cy == ty then
      local path, x, y = {}, tx, ty
      while not (x == fx and y == fy) do
        local p = par[key(x, y)]
        table.insert(path, 1, p[3])
        x, y = p[1], p[2]
      end
      return path
    end
    for _, d in ipairs(dirs) do
      local nx, ny = cx + d[1], cy + d[2]
      if can_move(cx, cy, nx, ny, gw, gh) then
        local k = key(nx, ny)
        if not vis[k] then
          vis[k] = true
          par[k] = { cx, cy, d[3] }
          tail = tail + 1
          qx[tail] = nx; qy[tail] = ny
        end
      end
    end
  end
  return nil  -- no passable route
end

-- Testability exposure only -- see the header note above. No behavior change.
M._tile_passable = tile_passable
M._edge_passable = edge_passable
M._can_move = can_move

return M
