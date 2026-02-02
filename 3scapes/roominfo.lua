-- Room Info Plugin for Lera
-- Collects room information from =R=, =P=, =M= prefixed lines
-- Handles multi-line exits, prompt prefixes, and various formats
-- Exposes API for other plugins to query current room state

local M = {}
M.name = "roominfo"
M.version = "1.1"
M.priority = 10  -- Run early to parse before other plugins

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local current = {
  room = nil,       -- Current room short description (string)
  room_id = nil,    -- Current room ID (number)
  exits = {},       -- List of exit directions (short form)
  exits_raw = "",   -- Raw exits string
  players = {},     -- List of player names in room
  monsters = {},    -- List of monster names in room
  timestamp = 0,    -- When this info was last updated
}

-- Pending state for multi-line parsing
local pending = {
  expecting_exits = false,  -- Are we expecting exit continuation?
  room_without_rid = nil,   -- Room data waiting for RID (deferred notification)
}

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

-- Parse exits string into list of short directions
local function parse_exits(exits_str)
  local exits = {}
  -- Strip ANSI codes first
  local clean = exits_str:gsub("\027%[[0-9;]*m", "")
  for exit in clean:gmatch("[^,]+") do
    exit = exit:match("^%s*(.-)%s*$")  -- trim
    if exit ~= "" then
      table.insert(exits, shorten_direction(exit))
    end
  end
  return exits
end

--------------------------------------------------------------------------------
-- Parsing
--------------------------------------------------------------------------------

-- Try to find =X= prefix anywhere in the line (handles prompt prefixes like "> ")
-- Returns: prefix_type ("R"/"P"/"M"), value after prefix, or nil
local function find_prefix(line)
  -- Look for =X= pattern anywhere in the line
  local before, prefix_char, value = line:match("^(.-)=([RrPpMm])=(.*)$")
  if prefix_char then
    value = value:match("^%s*(.-)%s*$")  -- trim
    return prefix_char:upper(), value
  end
  return nil, nil
end

-- Parse room value: extract name, exits, room_id
-- Format variations:
--   "Room Name (exits) [RID:room_id]"
--   "Room Name [RID:room_id] (exits)"
--   "Room Name (exits)"
--   "Room Name [room_id]"
--   "Room Name"
local function parse_room_value(value)
  local room_id = nil
  local exits_str = nil

  -- Strip ANSI codes before parsing
  local name = value:gsub("\027%[[0-9;]*m", "")

  -- Extract [RID:room_id] or [room_id] from ANYWHERE in the string (not just end)
  -- This handles both "Room (exits) [RID:123]" and "Room [RID:123] (exits)"
  local rid_str = name:match("%[RID:(%d+)%]") or name:match("%[(%d+)%]")
  if rid_str then
    room_id = tonumber(rid_str)
    -- Remove the RID from wherever it appears
    name = name:gsub("%s*%[RID:%d+%]%s*", " "):gsub("%s*%[%d+%]%s*", " ")
  end

  -- Extract (exits) from anywhere (usually at end, but be flexible)
  local exits_match = name:match("%(([^)]+)%)")
  if exits_match then
    exits_str = exits_match
    name = name:gsub("%s*%([^)]*%)", "")
  end

  -- Collapse multiple spaces and trim
  name = name:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

  return name, exits_str, room_id
end

-- Check for "There is/are N obvious exit(s): ..." format
local function parse_obvious_exits(line)
  -- Strip ANSI codes first
  local plain = line:gsub("\027%[[0-9;]*m", "")

  local exits = plain:match("[Tt]here%s+[ia][sr]e?%s+.-%s+obvious%s+exits?:%s*(.*)$")
  if exits then
    return exits:match("^%s*(.-)%s*$")
  end

  -- Simpler pattern: "obvious exit(s): n, s, e"
  exits = plain:match("obvious%s+exits?:%s*(.*)$")
  if exits then
    return exits:match("^%s*(.-)%s*$")
  end

  return nil
end

-- Check for standalone exits in parentheses: "(n, s, e)"
local function parse_standalone_exits(line)
  local exits = line:match("^%s*%(([^)]+)%)%s*$")
  return exits
end

-- Check for exit continuation line (indented directions)
local function parse_exit_continuation(line)
  -- Heavily indented line with just directions
  if pending.expecting_exits then
    -- Match line that's mostly spaces followed by direction-like content
    local content = line:match("^%s%s%s%s%s%s+([a-z, ]+)%s*$")
    if content and content:match("[nesw]") then
      return content:match("^%s*(.-)%s*$")
    end
  end
  return nil
end

-- Check for standalone [RID:12345] line
local function parse_standalone_rid(line)
  -- Strip ANSI codes first
  local plain = line:gsub("\027%[[0-9;]*m", "")
  -- Match [RID:NNNN] anywhere in the line
  local rid_str = plain:match("%[RID:(%d+)%]")
  if rid_str then
    -- Make sure this isn't part of a =R= line (which handles RID itself)
    if not plain:match("=R=") then
      return tonumber(rid_str)
    end
  end
  return nil
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

local function set_exits(exits_str)
  if exits_str and exits_str ~= "" then
    current.exits_raw = exits_str
    current.exits = parse_exits(exits_str)
    pending.expecting_exits = false
  end
end

-- Common logic for updating room state and notifying callbacks
local function update_room(name, exits_str, room_id)
  local old_room = current.room
  local old_room_id = current.room_id

  current.room = name
  current.room_id = room_id
  current.timestamp = lera.time()
  current.players = {}
  current.monsters = {}

  if exits_str then
    set_exits(exits_str)
  else
    current.exits = {}
    current.exits_raw = ""
    pending.expecting_exits = true
  end

  add_to_history(name)

  if old_room ~= name or old_room_id ~= room_id then
    notify_room_change(old_room, name)
  end
end

--------------------------------------------------------------------------------
-- Plugin Hooks
--------------------------------------------------------------------------------

function M.on_line(line)
  -- First check for =X= prefixes (handles prompts like "> =R=...")
  local prefix_type, value = find_prefix(line)

  if prefix_type then
    current.timestamp = lera.time()

    if prefix_type == "R" then
      local name, exits_str, room_id = parse_room_value(value)

      if room_id then
        -- Have RID - process normally with immediate notification
        pending.room_without_rid = nil
        update_room(name, exits_str, room_id)
      else
        -- No RID yet - store pending, wait for RID line before notifying
        -- This prevents mapper from rendering with stale room_id
        pending.room_without_rid = { name = name, exits_str = exits_str }

        -- Still update basic state so exits/players/monsters work
        current.room = name
        current.timestamp = lera.time()
        current.players = {}
        current.monsters = {}

        if exits_str then
          set_exits(exits_str)
        else
          current.exits = {}
          current.exits_raw = ""
          pending.expecting_exits = true
        end
      end

      return nil  -- suppress

    elseif prefix_type == "P" then
      if value and value ~= "" then
        table.insert(current.players, value)
      end
      return nil  -- suppress

    elseif prefix_type == "M" then
      if value and value ~= "" then
        table.insert(current.monsters, value)
      end
      return nil  -- suppress
    end
  end

  -- Check for standalone [RID:12345] line (comes after =R= line)
  local standalone_rid = parse_standalone_rid(line)
  if standalone_rid then
    if pending.room_without_rid then
      -- Complete the pending room notification with full data
      local p = pending.room_without_rid
      pending.room_without_rid = nil
      update_room(p.name, p.exits_str, standalone_rid)
    elseif current.room_id ~= standalone_rid then
      -- Update existing room with new RID
      current.room_id = standalone_rid
      current.timestamp = lera.time()
      notify_room_change(current.room, current.room)
    end
    return nil  -- suppress the [RID:] line
  end

  -- Check for "obvious exits" format
  local obvious_exits = parse_obvious_exits(line)
  if obvious_exits then
    set_exits(obvious_exits)
    -- Don't suppress - let it display
    return line
  end

  -- Check for standalone (exits) format
  local standalone_exits = parse_standalone_exits(line)
  if standalone_exits and pending.expecting_exits then
    set_exits(standalone_exits)
    -- Don't suppress
    return line
  end

  -- Check for exit continuation
  local continuation = parse_exit_continuation(line)
  if continuation then
    -- Append to existing exits
    if current.exits_raw ~= "" then
      current.exits_raw = current.exits_raw .. ", " .. continuation
    else
      current.exits_raw = continuation
    end
    current.exits = parse_exits(current.exits_raw)
    -- Don't suppress
    return line
  end

  -- Any other line stops exit continuation expectation
  if pending.expecting_exits and line:match("%S") then
    -- Non-empty line that's not exits - stop expecting
    pending.expecting_exits = false
  end

  return line
end

function M.on_load()
  print("[roominfo] Loaded - collecting =R=, =P=, =M= data")
end

function M.on_unload()
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

-- Check if room data is fully synced (not waiting for RID)
-- Returns false if we received =R= but are still waiting for RID
function M.is_synced()
  return pending.room_without_rid == nil
end

-- Debug function to check internal state
function M.debug_state()
  return {
    room = current.room,
    room_id = current.room_id,
    is_synced = pending.room_without_rid == nil,
    pending_room = pending.room_without_rid and pending.room_without_rid.name or nil,
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
    exits = M.exits(),
    exits_string = M.exits_string(),
    players = M.players(),
    monsters = M.monsters(),
    player_count = #current.players,
    monster_count = #current.monsters,
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
  current.exits = {}
  current.exits_raw = ""
  current.players = {}
  current.monsters = {}
  current.timestamp = 0
  pending.expecting_exits = false
  pending.room_without_rid = nil
  history = {}
end

return M
