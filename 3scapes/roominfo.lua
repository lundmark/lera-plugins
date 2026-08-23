-- Room Info Plugin for Lera
-- Sole subscriber to the GMCP Room.* packages: Room.Info (identity, area,
-- exits and their destinations), Room.Contents (players, monsters, items) and
-- Room.Map (the line-of-sight grid).
--
-- The server suppresses a resend when a payload is identical to the last one it
-- sent, so absence of a packet means "unchanged", never "empty". Each handler
-- therefore writes only its own slice of state: a Room.Info must not clear
-- contents or the map.
--
-- Exposes API for other plugins to query current room state.

local M = {}
M.name = "roominfo"
M.version = "2.0"
M.priority = 10

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local current = {
  room = nil,        -- Current room short description (string)
  room_id = nil,     -- Current room ID (number)
  area = nil,        -- Area name from Room.Info
  exits = {},        -- List of exit directions (short form, canonical order)
  exits_raw = "",    -- Exits joined with ", "
  exit_dest = {},    -- short direction -> destination room number (0 = unknown)
  players = {},      -- List of player entries
  monsters = {},     -- List of monster entries
  items = {},        -- List of item entries
  truncated = false, -- Room.Contents reported dropped entries
  timestamp = 0,     -- When the room identity was last updated
}

local synced = false          -- has any Room.Info been accepted this session
local map_grid = nil          -- last Room.Map payload
local contents_accum = nil    -- multi-page Room.Contents accumulator
local handler_ids = {}        -- gmcp handler ids, removed on unload

-- History of recent rooms (for tracking movement)
local history = {}
local history_max = 50

-- Callbacks for when room changes
local on_room_change_callbacks = {}

--------------------------------------------------------------------------------
-- Direction Helpers
--------------------------------------------------------------------------------

local direction_short = {
  north = "n", south = "s", east = "e", west = "w",
  northeast = "ne", northwest = "nw", southeast = "se", southwest = "sw",
  up = "u", down = "d",
  ["in"] = "in", out = "out",
}

local function shorten_direction(dir)
  return direction_short[dir:lower()] or dir:lower()
end

-- GMCP delivers exits as a mapping, and pairs() order is undefined. Sort into a
-- canonical compass order so the rendered exit list and the tests are stable;
-- anything unrecognized sorts alphabetically after the known directions.
local direction_rank = {
  n = 1, ne = 2, e = 3, se = 4, s = 5, sw = 6, w = 7, nw = 8,
  u = 9, d = 10, ["in"] = 11, out = 12,
}

local function direction_less(a, b)
  local ra, rb = direction_rank[a], direction_rank[b]
  if ra and rb then return ra < rb end
  if ra then return true end
  if rb then return false end
  return a < b
end

--------------------------------------------------------------------------------
-- Internal Functions
--------------------------------------------------------------------------------

local function notify_room_change(old_room, new_room)
  for _, callback in ipairs(on_room_change_callbacks) do
    local ok, err = pcall(callback, new_room, old_room)
    if not ok then
      print("[roominfo] Callback error: " .. tostring(err))
    end
  end
end

local function add_to_history(room_name)
  if not room_name then return end

  table.insert(history, 1, {
    room = room_name,
    timestamp = lera.time(),
  })

  -- Trim history
  while #history > history_max do
    table.remove(history)
  end
end

--------------------------------------------------------------------------------
-- GMCP Handlers
--------------------------------------------------------------------------------

local function handle_room_info(data)
  if type(data) ~= "table" then return end

  local num = tonumber(data.num)
  -- The mudlib permits num == 0 and it means "no usable id". Accepting it would
  -- replace a good room with one nothing can key off.
  if not num or num <= 0 then return end

  local old_room = current.room
  local old_room_id = current.room_id

  current.room = data.name and tostring(data.name) or ""
  current.room_id = num
  current.area = data.area and tostring(data.area) or nil
  current.timestamp = lera.time()

  current.exits = {}
  current.exit_dest = {}
  if type(data.exits) == "table" then
    for dir, dest in pairs(data.exits) do
      local short = shorten_direction(tostring(dir))
      table.insert(current.exits, short)
      current.exit_dest[short] = tonumber(dest) or 0
    end
    table.sort(current.exits, direction_less)
  end
  current.exits_raw = table.concat(current.exits, ", ")

  -- A room change abandons any half-received Room.Contents list: its remaining
  -- pages describe the room we just left.
  contents_accum = nil
  synced = true

  -- Only an actual change enters the history. The server force-sends a snapshot
  -- on every subscription change, and recording those would fill the history
  -- with repeats of the room the player is standing in.
  if old_room ~= current.room or old_room_id ~= current.room_id then
    add_to_history(current.room)
    notify_room_change(old_room, current.room)
  end
end

--------------------------------------------------------------------------------
-- Plugin Hooks
--------------------------------------------------------------------------------

function M.on_load()
  handler_ids[#handler_ids + 1] = gmcp.on("Room.Info", function(_, data)
    handle_room_info(data)
  end)
  print("[roominfo] Loaded - subscribed to GMCP Room.Info")
end

function M.on_unload()
  for _, id in ipairs(handler_ids) do
    if id then gmcp.remove(id) end
  end
  handler_ids = {}
  on_room_change_callbacks = {}
  print("[roominfo] Unloaded")
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Get current room name
function M.room()
  return current.room
end

-- Get current room ID
function M.room_id()
  return current.room_id
end

-- True once a Room.Info has been accepted. Before that there is no room state
-- to correlate against, which is exactly what mapview needs to know.
function M.is_synced()
  return synced
end

function M.area()
  return current.area
end

-- short direction -> destination room number. 0 means the server reported the
-- exit but no usable destination id.
function M.exit_destinations()
  local result = {}
  for dir, dest in pairs(current.exit_dest) do
    result[dir] = dest
  end
  return result
end

-- Debug function to check internal state
function M.debug_state()
  return {
    room = current.room,
    room_id = current.room_id,
    area = current.area,
    synced = synced,
    has_map = map_grid ~= nil,
  }
end

-- Get list of exits (short form: n, s, e, w, etc.)
function M.exits()
  local result = {}
  for i, e in ipairs(current.exits) do
    result[i] = e
  end
  return result
end

-- Get exits as formatted string "(n, s, e, w)"
function M.exits_string()
  if #current.exits == 0 then
    return ""
  end
  return "(" .. table.concat(current.exits, ", ") .. ")"
end

-- Get list of players in current room
function M.players()
  local result = {}
  for i, p in ipairs(current.players) do
    result[i] = p
  end
  return result
end

-- Get list of monsters in current room
function M.monsters()
  local result = {}
  for i, m in ipairs(current.monsters) do
    result[i] = m
  end
  return result
end

-- Get list of items in current room (stub; Task 2 fills this in from
-- Room.Contents)
function M.items()
  local result = {}
  for i, e in ipairs(current.items) do
    result[i] = e
  end
  return result
end

-- Get count of players
function M.player_count()
  return #current.players
end

-- Get count of monsters
function M.monster_count()
  return #current.monsters
end

-- Get all current room info as a table
function M.info()
  return {
    room = current.room,
    room_id = current.room_id,
    area = current.area,
    exits = M.exits(),
    exits_string = M.exits_string(),
    players = M.players(),
    monsters = M.monsters(),
    items = M.items(),
    player_count = M.player_count(),
    monster_count = M.monster_count(),
    truncated = current.truncated,
    timestamp = current.timestamp,
  }
end

-- Get room history
function M.get_history(limit)
  limit = limit or history_max
  local result = {}
  for i = 1, math.min(limit, #history) do
    result[i] = {
      room = history[i].room,
      timestamp = history[i].timestamp,
    }
  end
  return result
end

-- Check if a specific player is in the room
function M.has_player(name)
  local name_lower = name:lower()
  for _, p in ipairs(current.players) do
    if p:lower() == name_lower or p:lower():find(name_lower, 1, true) then
      return true
    end
  end
  return false
end

-- Check if a specific monster is in the room
function M.has_monster(name)
  local name_lower = name:lower()
  for _, m in ipairs(current.monsters) do
    if m:lower() == name_lower or m:lower():find(name_lower, 1, true) then
      return true
    end
  end
  return false
end

-- Register callback for room changes
-- callback(new_room, old_room)
function M.on_room_change(callback)
  table.insert(on_room_change_callbacks, callback)
  return #on_room_change_callbacks
end

-- Unregister callback
function M.off_room_change(id)
  if id and on_room_change_callbacks[id] then
    table.remove(on_room_change_callbacks, id)
    return true
  end
  return false
end

-- Clear all data (useful for reconnects)
function M.clear()
  current.room = nil
  current.room_id = nil
  current.area = nil
  current.exits = {}
  current.exits_raw = ""
  current.exit_dest = {}
  current.players = {}
  current.monsters = {}
  current.items = {}
  current.truncated = false
  current.timestamp = 0
  synced = false
  map_grid = nil
  contents_accum = nil
  history = {}
end

return M
