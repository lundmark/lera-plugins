-- Pure coordinate map for maze exploration.
--
-- No lera API, no MUD, no I/O: everything here is plain tables over integer
-- coordinates, so it can be unit tested directly. That matters because every
-- bug the legacy chaossea explorer shipped lived in this layer.
--
-- The maze this was written for is a static lattice: the mudlib generates it
-- once (generate_maze() inside setup_maze) and bakes each room's coordinates
-- into its own virtual file name. So a coordinate identifies a room for the
-- life of a run, which is the whole reason dead reckoning works in an area that
-- reports no room ids at all.

local M = {}

-- Unit steps per direction. The eight compass entries mirror the mudlib's own
-- switch (players/setinekht/maze/maze.c:588-645): north = y+1, east = x+1.
--
-- u and d are the ordinary lattice convention and are NOT universal: the Chaos
-- Sea inverts them, because set_level_exit_pairs((["down":"up"])) makes "down"
-- its level-UP direction and the override at maze.c:646-652 beats the plain case
-- label, so "down" increases z there. mode.lua therefore reads z from the room
-- name whenever the area profile can supply one, and only falls back to these
-- two entries for an area that cannot.
local DELTA = {
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

-- Deterministic iteration order. pairs() order is undefined, and an explorer
-- that picks a different frontier on two identical maps is untestable.
local DIR_ORDER = { "n", "ne", "e", "se", "s", "sw", "w", "nw", "d", "u" }

M.DELTA = DELTA
M.DIR_ORDER = DIR_ORDER

-- True when two exit sets hold exactly the same directions. Used to detect a
-- coordinate whose topology contradicts what was recorded there before.
function M.same_exits(a, b)
  a = a or {}
  b = b or {}
  for dir in pairs(a) do
    if not b[dir] then return false end
  end
  for dir in pairs(b) do
    if not a[dir] then return false end
  end
  return true
end

local Map = {}
Map.__index = Map

local function key(x, y, z)
  return x .. "," .. y .. "," .. z
end

function M.new()
  return setmetatable({ rooms = {}, n = 0, pos = { 0, 0, 0 } }, Map)
end

function Map:position()
  return self.pos[1], self.pos[2], self.pos[3]
end

function Map:set_position(x, y, z)
  self.pos = { x, y, z }
end

function Map:room(x, y, z)
  return self.rooms[key(x, y, z)]
end

function Map:visited(x, y, z)
  return self.rooms[key(x, y, z)] ~= nil
end

function Map:count()
  return self.n
end

-- Record the room at the current position and the exits it reports. The exit
-- list is replaced rather than merged: a lattice room's exits do not change
-- within a run, so a differing set means something else is wrong (the caller
-- checks for that with same_exits before recording).
function Map:record(exit_list)
  local x, y, z = self:position()
  local k = key(x, y, z)
  local room = self.rooms[k]
  if not room then
    room = { x = x, y = y, z = z, exits = {} }
    self.rooms[k] = room
    self.n = self.n + 1
  end
  local set = {}
  for _, dir in ipairs(exit_list or {}) do
    -- Anything without a delta is not walkable in the lattice: 'out' and
    -- 'enter' leave the area, and walking one would take the explorer out of
    -- the map it was asked to build.
    if DELTA[dir] then set[dir] = true end
  end
  room.exits = set
  return room
end

function Map:move(dir)
  local d = DELTA[dir]
  if not d then return false end
  self.pos = { self.pos[1] + d[1], self.pos[2] + d[2], self.pos[3] + d[3] }
  return true
end

-- The exits of `room` that lead to a coordinate never recorded.
function Map:frontier_dirs(room)
  local out = {}
  if not room then return out end
  for _, dir in ipairs(DIR_ORDER) do
    if room.exits[dir] then
      local d = DELTA[dir]
      if not self:visited(room.x + d[1], room.y + d[2], room.z + d[3]) then
        out[#out + 1] = dir
      end
    end
  end
  return out
end

-- Breadth-first search from the current position over RECORDED rooms, stopping
-- at the nearest room holding an exit into a coordinate never visited. Returns
-- the path there followed by the frontier direction itself, or nil.
--
-- This one operation replaces four cooperating mechanisms in the legacy
-- explorer: a flat (x,y,z,dir) frontier queue, a separate search to route to a
-- queue entry's source room, skip logic for entries the queue had outlived, and
-- a reseed pass for when the queue drained while real frontier remained.
-- Deriving the frontier on demand means nothing can go stale, so there is
-- nothing to reseed and no obsolete entry to skip.
--
-- opts.only  -- consider frontier ONLY in these directions (dive mode)
-- opts.defer -- rank these last when breaking a distance tie
function Map:search_frontier(opts)
  opts = opts or {}

  local only = nil
  if opts.only and #opts.only > 0 then
    only = {}
    for _, dir in ipairs(opts.only) do only[dir] = true end
  end

  local defer = {}
  for _, dir in ipairs(opts.defer or {}) do defer[dir] = true end

  local rank_of = {}
  for i, dir in ipairs(DIR_ORDER) do rank_of[dir] = i end
  local function rank(dir)
    return (defer[dir] and 200 or 100) + (rank_of[dir] or 99)
  end

  local sx, sy, sz = self:position()
  local start = key(sx, sy, sz)
  local start_room = self.rooms[start]
  if not start_room then return nil end

  -- Search bookkeeping lives here, keyed by coordinate -- never written onto the
  -- room records. Legacy stored parent/parent_dir on the rooms and needed a
  -- defensive sweep to clear stale markers left by an aborted search; with the
  -- state scoped to the call that failure mode is structurally impossible.
  local dist = { [start] = 0 }
  local prev = {}

  -- FIFO. Dequeue at head, enqueue at tail. Legacy read the LAST pushed entry
  -- and pushed after it, which is a stack: that made its "BFS" a DFS returning
  -- non-shortest paths, and is why it ran the wrong way and doubled back.
  local queue = { start_room }
  local head = 1
  local best = nil

  while head <= #queue do
    local room = queue[head]
    head = head + 1
    local rk = key(room.x, room.y, room.z)
    local d0 = dist[rk]

    -- Every remaining room is at least this far, so once a frontier is found
    -- nothing deeper can beat it.
    if best and d0 > best.dist then break end

    for _, dir in ipairs(self:frontier_dirs(room)) do
      if (not only) or only[dir] then
        local r = rank(dir)
        if (not best) or d0 < best.dist or (d0 == best.dist and r < best.rank) then
          best = { dist = d0, rank = r, room = room, dir = dir }
        end
      end
    end

    for _, dir in ipairs(DIR_ORDER) do
      if room.exits[dir] then
        local d = DELTA[dir]
        local nk = key(room.x + d[1], room.y + d[2], room.z + d[3])
        if self.rooms[nk] and dist[nk] == nil then
          dist[nk] = d0 + 1
          prev[nk] = { from = rk, dir = dir }
          queue[#queue + 1] = self.rooms[nk]
        end
      end
    end
  end

  if not best then return nil end

  local path = {}
  local cur = key(best.room.x, best.room.y, best.room.z)
  while prev[cur] do
    local p = prev[cur]
    table.insert(path, 1, p.dir)
    cur = p.from
  end
  path[#path + 1] = best.dir
  return path
end

-- Breadth-first search from the current position to a NAMED recorded
-- coordinate -- unlike search_frontier, which searches for an unrecorded
-- frontier, this searches for a specific, already-recorded room. Used by
-- explore/mode.lua's M.leave() to route back to the run's origin.
--
-- Same discipline as search_frontier: FIFO queue, dist/prev scoped to the
-- call and never written onto room records, DIR_ORDER for determinism.
--
-- Three distinct return shapes, on purpose:
--   * an array of directions, when a route through recorded rooms exists;
--   * an empty array, when the current position IS the target;
--   * nil, when the target is not a recorded room, or is recorded but
--     unreachable through recorded rooms.
-- A caller has to be able to tell "already there" from "cannot get there",
-- so the empty-array case must never collapse into nil, and nil must never
-- collapse into an empty array.
function Map:path_to(x, y, z)
  local target = key(x, y, z)
  if not self.rooms[target] then return nil end

  local sx, sy, sz = self:position()
  local start = key(sx, sy, sz)
  if start == target then return {} end

  local start_room = self.rooms[start]
  if not start_room then return nil end

  -- Search bookkeeping lives here, keyed by coordinate -- never written onto
  -- the room records, and never shared across calls. See search_frontier's
  -- comment above for why: state left behind on rooms (or hoisted to module
  -- scope) is exactly the class of bug this engine was built to avoid.
  local dist = { [start] = 0 }
  local prev = {}

  -- FIFO, exactly like search_frontier: dequeue at head, enqueue at tail.
  local queue = { start_room }
  local head = 1

  while head <= #queue do
    local room = queue[head]
    head = head + 1
    local rk = key(room.x, room.y, room.z)
    local d0 = dist[rk]

    for _, dir in ipairs(DIR_ORDER) do
      if room.exits[dir] then
        local d = DELTA[dir]
        local nk = key(room.x + d[1], room.y + d[2], room.z + d[3])
        if self.rooms[nk] and dist[nk] == nil then
          dist[nk] = d0 + 1
          prev[nk] = { from = rk, dir = dir }
          queue[#queue + 1] = self.rooms[nk]
        end
      end
    end
  end

  if dist[target] == nil then return nil end

  local path = {}
  local cur = target
  while prev[cur] do
    local p = prev[cur]
    table.insert(path, 1, p.dir)
    cur = p.from
  end
  return path
end

-- Policy wrapper over search_frontier.
--
-- "clear"  -- nearest frontier; a distance tie breaks by compass order with
--             defer_dirs ranked last. This is legacy's behaviour: it descends
--             whenever a descent happens to be the nearest frontier, and only
--             ranks 'up' behind everything else.
-- "dive"   -- take the nearest UNEXPLORED descent wherever it is, however far,
--             and fall back to "clear" when the map holds none. The portal sits
--             on the deepest floor, so this reaches it far sooner at the cost of
--             leaving most of each layer unexplored.
function Map:next_frontier(opts)
  opts = opts or {}
  if opts.policy == "dive" then
    local dived = self:search_frontier({ only = opts.dive_dirs,
                                         defer = opts.defer_dirs })
    if dived then return dived end
  end
  return self:search_frontier({ defer = opts.defer_dirs })
end

M.Map = Map

return M
