-- Chaos Sea area profile: data plus four predicates. No engine logic lives in
-- a profile.
--
-- The area is players/setinekht/maze/example/maze.c, a maze generated once per
-- run and served through a virtual master. Its rooms inherit /room/room.c so
-- they do send GMCP Room.*, but they are no-explorer virtual rooms, so every
-- one of them reports num 0 and every exit destination is 0. The room name is
-- the only per-room information the protocol carries, and it carries only the
-- layer.

local M = {}

M.name = "chaossea"

-- 'out' is the way back to the real world -- the entry room reports it with a
-- real destination while every maze exit reports 0 -- and walking it would take
-- the explorer out of the area it is mapping.
M.exclude_exits = { out = true, enter = true, ["in"] = true }

-- set_level_exit_pairs((["down":"up"])): descending a floor is 'down', and the
-- portal sits on the deepest floor. 'up' climbs back into an explored layer.
M.dive_dirs = { "d" }
M.defer_dirs = { "u" }
M.default_policy = "clear"

function M.in_area(room_name)
  if type(room_name) ~= "string" then return false end
  return room_name:lower():find("sea of chaos", 1, true) ~= nil
end

-- The mudlib renders the layer as number_switch(query_z() + 1), so "one" is
-- z = 0. set_num_floors(min(8, 3 + diff/20)) caps the range at eight.
local LAYER_WORDS = {
  one = 0, two = 1, three = 2, four = 3,
  five = 4, six = 5, seven = 6, eight = 7,
}

function M.layer_of(room_name)
  if type(room_name) ~= "string" then return nil end
  local word = room_name:lower():match("^layer%s+(%a+)%s+of the sea of chaos")
  if not word then return nil end
  return LAYER_WORDS[word]
end

-- The portal object's short is set in example/objs/portal.c, so it reaches the
-- client as a Room.Contents item.
--
-- This is inferred from mudlib source rather than observed: the capture this
-- was designed against contains no portal room. Legacy's line triggers for the
-- same two objects are deliberately not ported -- the design keeps no text
-- dependency -- so if the portal does not surface as an item, the farm loop
-- never fires. That is the first thing to check on a live run.
local COMPLETION_ITEMS = {
  "glowing portal",
  "cask of chaotic energy",
}

function M.complete(ctx)
  for _, item in ipairs((ctx and ctx.items) or {}) do
    local low = tostring(item):lower()
    for _, needle in ipairs(COMPLETION_ITEMS) do
      if low:find(needle, 1, true) then return true end
    end
  end
  return false
end

local DIFFICULTIES = { risky = true, alarming = true, deadly = true }

-- Legacy's cycle, plus the difficulty word it never sent. 'setsea <level>
-- <risky|alarming|deadly>' (rooms/seatest.c): difficulty decides whether
-- diagonals and up/down exist in the generated maze at all, and therefore
-- whether dive has anything to dive through.
function M.restart(opts)
  opts = opts or {}
  local level = tonumber(opts.level) or 0
  local difficulty = opts.difficulty
  if not (difficulty and DIFFICULTIES[difficulty]) then difficulty = "risky" end
  return {
    "open cask",
    "enter portal",
    "unsetsea",
    "setsea " .. math.floor(level) .. " " .. difficulty,
    "enter sea",
  }
end

return M
