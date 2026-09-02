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

M.Map = Map

return M
