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

  synced = true

  -- Only an actual change enters the history. The server force-sends a snapshot
  -- on every subscription change, and recording those would fill the history
  -- with repeats of the room the player is standing in. That same force-sent
  -- snapshot is also why the accumulator reset lives here, not unconditionally
  -- above: clearing it on every accepted Room.Info would discard an in-flight
  -- multi-page list for the room the player is still standing in. Only an
  -- actual room change abandons the accumulator, since its remaining pages
  -- describe the room we just left.
  if old_room ~= current.room or old_room_id ~= current.room_id then
    contents_accum = nil
    add_to_history(current.room)
    notify_room_change(old_room, current.room)
  end
end

local function classify_entry(raw)
  if type(raw) ~= "table" then return nil, nil end
  if raw.name == nil then return nil, nil end
  local kind = raw.type and tostring(raw.type) or ""
  if kind ~= "player" and kind ~= "monster" and kind ~= "item" then
    return nil, nil
  end
  local count = tonumber(raw.count) or 1
  if count < 1 then count = 1 end
  if count > 99 then count = 99 end
  return kind, {
    name = tostring(raw.name),
    count = count,
    hp = raw.hp and tostring(raw.hp) or nil,
    attacking = raw.attacking and tostring(raw.attacking) or nil,
  }
end

local function commit_contents(items, truncated)
  local players, monsters, objects = {}, {}, {}
  for _, raw in ipairs(items) do
    local kind, entry = classify_entry(raw)
    if kind == "player" then
      players[#players + 1] = entry
    elseif kind == "monster" then
      monsters[#monsters + 1] = entry
    elseif kind == "item" then
      objects[#objects + 1] = entry
    end
  end
  current.players = players
  current.monsters = monsters
  current.items = objects
  current.truncated = truncated and true or false
end

local function handle_room_contents(data)
  if type(data) ~= "table" then return end

  local items = type(data.items) == "table" and data.items or {}
  local truncated = data.truncated ~= nil and data.truncated ~= 0
  local page = tonumber(data.page)
  local pages = tonumber(data.pages)

  -- page/pages appear only when there is more than one page, so a payload
  -- without them is a complete list.
  if not page or not pages or pages <= 1 then
    contents_accum = nil
    commit_contents(items, truncated)
    return
  end

  -- A new page 1 abandons whatever was accumulating: it is a fresh list, not a
  -- continuation.
  if page == 1 or not contents_accum then
    contents_accum = { pages = pages, next_page = 1, items = {}, truncated = false }
  end

  if page ~= contents_accum.next_page or pages ~= contents_accum.pages then
    -- Out-of-order or mismatched page: the list cannot be trusted.
    contents_accum = nil
    return
  end

  for _, raw in ipairs(items) do
    contents_accum.items[#contents_accum.items + 1] = raw
  end
  contents_accum.truncated = contents_accum.truncated or truncated
  contents_accum.next_page = page + 1

  if page == pages then
    local accumulated = contents_accum
    contents_accum = nil
    commit_contents(accumulated.items, accumulated.truncated)
  end
end

local function handle_room_map(data)
  if type(data) ~= "table" then return end
  if type(data.rows) ~= "table" then return end

  local w = tonumber(data.w)
  local h = tonumber(data.h)
  if not w or not h or w < 1 or h < 1 then return end

  local rows = {}
  for i = 1, h do
    if type(data.rows[i]) ~= "string" then return end
    if #data.rows[i] ~= w then return end
    rows[i] = data.rows[i]
  end

  local legend = {}
  if type(data.legend) == "table" then
    for glyph, meaning in pairs(data.legend) do
      legend[tostring(glyph)] = tostring(meaning)
    end
  end

  map_grid = {
    kind = data.kind and tostring(data.kind) or "los",
    w = w,
    h = h,
    rows = rows,
    legend = legend,
    -- 0 is truthy in Lua; normalize so a renderer can test these directly.
    up = data.up ~= nil and data.up ~= 0,
    down = data.down ~= nil and data.down ~= 0,
    enter = data.enter ~= nil and data.enter ~= 0,
  }
end

--------------------------------------------------------------------------------
-- Plugin Hooks
--------------------------------------------------------------------------------

function M.on_load()
  handler_ids[#handler_ids + 1] = gmcp.on("Room.Info", function(_, data)
    handle_room_info(data)
  end)
  handler_ids[#handler_ids + 1] = gmcp.on("Room.Contents", function(_, data)
    handle_room_contents(data)
  end)
  handler_ids[#handler_ids + 1] = gmcp.on("Room.Map", function(_, data)
    handle_room_map(data)
  end)
  print("[roominfo] Loaded - subscribed to GMCP Room.Info, Room.Contents, Room.Map")
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

-- The last Room.Map grid, or nil. Returns a copy: renderers mutate rows for
-- path highlighting.
function M.map()
  if not map_grid then return nil end
  local rows = {}
  for i, row in ipairs(map_grid.rows) do rows[i] = row end
  local legend = {}
  for glyph, meaning in pairs(map_grid.legend) do legend[glyph] = meaning end
  return {
    kind = map_grid.kind,
    w = map_grid.w,
    h = map_grid.h,
    rows = rows,
    legend = legend,
    up = map_grid.up,
    down = map_grid.down,
    enter = map_grid.enter,
  }
end

-- Name strings, one per counted individual. The mudlib stacks duplicates into a
-- count; expanding restores the shape the old per-line =P=/=M= data had, which
-- mapper, mapview and autostepper all concat or measure.
local function expand_names(entries)
  local names = {}
  for _, e in ipairs(entries) do
    for _ = 1, e.count do
      names[#names + 1] = e.name
    end
  end
  return names
end

local function copy_entries(entries)
  local result = {}
  for i, e in ipairs(entries) do
    result[i] = { name = e.name, count = e.count, hp = e.hp, attacking = e.attacking }
  end
  return result
end

-- Get list of players in current room (name strings; see player_entries()
-- for the rich form)
function M.players()
  return expand_names(current.players)
end

-- Get list of monsters in current room (name strings; see monster_entries()
-- for the rich form)
function M.monsters()
  return expand_names(current.monsters)
end

-- Get list of items in current room
function M.items()
  return copy_entries(current.items)
end

-- Get rich player entries ({name, count, hp?, attacking?})
function M.player_entries()
  return copy_entries(current.players)
end

-- Get rich monster entries ({name, count, hp?, attacking?})
function M.monster_entries()
  return copy_entries(current.monsters)
end

-- Get count of players
function M.player_count()
  return #M.players()
end

-- Get count of monsters
function M.monster_count()
  return #M.monsters()
end

-- True when the last Room.Contents reported dropped entries
function M.contents_truncated()
  return current.truncated
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
  for _, e in ipairs(current.players) do
    local n = e.name:lower()
    if n == name_lower or n:find(name_lower, 1, true) then
      return true
    end
  end
  return false
end

-- Check if a specific monster is in the room
function M.has_monster(name)
  local name_lower = name:lower()
  for _, e in ipairs(current.monsters) do
    local n = e.name:lower()
    if n == name_lower or n:find(name_lower, 1, true) then
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
