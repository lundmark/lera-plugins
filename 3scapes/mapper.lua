-- Mapper Plugin for Lera
-- Tracks rooms via MIP data and renders a minimal ASCII map

local M = {}
M.name = "mapper"
M.version = "1.0"
M.priority = 60

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local map = {
  rooms = {},           -- id -> room table
  current_room_id = nil,
  current_layer = "default",
  pending_move = nil,   -- single pending direction
  waypoints = {},       -- name -> room_id
}

local mapping_mode = false  -- only learn connections when true
local mapping_lost = false  -- true if we moved too fast and lost sync
local mip_handlers = {}
local alias_ids = {}
local roominfo_callback_id = nil

--------------------------------------------------------------------------------
-- Direction mappings
--------------------------------------------------------------------------------

-- Only cardinal directions can be mapped on a 2D grid
local cardinal_offsets = {
  n = {0, -1}, s = {0, 1}, e = {1, 0}, w = {-1, 0},
  ne = {1, -1}, nw = {-1, -1}, se = {1, 1}, sw = {-1, 1},
}

-- Normalize long direction names to short form
local dir_short = {
  north = "n", south = "s", east = "e", west = "w",
  northeast = "ne", northwest = "nw", southeast = "se", southwest = "sw",
}

local function normalize_dir(dir)
  return dir_short[dir] or dir
end

-- Check if direction is cardinal (can be mapped on 2D grid)
local function is_cardinal(dir)
  local d = normalize_dir(dir)
  return cardinal_offsets[d] ~= nil
end

--------------------------------------------------------------------------------
-- Persistence (requires store API - currently in-memory only)
--------------------------------------------------------------------------------

-- Check if store API is available
local has_store = (type(store) == "table" and type(store.get) == "function")

local function save_map()
  if not has_store then return end

  local save_data = {
    rooms = {},
    current_layer = map.current_layer,
    waypoints = map.waypoints,
  }

  for id, room in pairs(map.rooms) do
    save_data.rooms[tostring(id)] = {
      id = room.id,
      name = room.name,
      exits = room.exits,
      connections = room.connections,
      x = room.x,
      y = room.y,
      layer = room.layer,
      virtual = room.virtual,
      last_seen = room.last_seen,
    }
  end

  store.set(save_data)
  store.save()
end

local function load_map()
  if not has_store then return end

  store.load()
  local data = store.get()
  if not data then return end

  map.rooms = {}
  if data.rooms then
    for id_str, room in pairs(data.rooms) do
      local id = tonumber(id_str) or tonumber(room.id)
      if id then
        map.rooms[id] = {
          id = id,
          name = room.name or "Unknown",
          exits = room.exits or {},
          connections = room.connections or {},
          x = room.x or 0,
          y = room.y or 0,
          layer = room.layer or "default",
          virtual = room.virtual or false,
          last_seen = room.last_seen or 0,
        }
      end
    end
  end

  map.current_layer = data.current_layer or "default"
  map.waypoints = data.waypoints or {}
end

--------------------------------------------------------------------------------
-- Room Processing (shared by MIP and =R= handlers)
--------------------------------------------------------------------------------

-- Core room processing logic - called when we detect a room change
local function process_room(rid, name)
  if not rid or rid == 0 then return end

  name = name or "Unknown"
  -- Strip exits from name if present: "Room Name (exits)" -> "Room Name"
  name = name:gsub("%s*%([^)]*%)%s*$", "")
  -- Collapse multiple spaces into single space and trim
  name = name:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

  -- Get or create room
  local room = map.rooms[rid]
  local is_new_room = (room == nil)

  if not room then
    room = {
      id = rid,
      name = name,
      exits = {},
      connections = {},
      x = 0,
      y = 0,
      layer = map.current_layer,
      virtual = false,
      last_seen = lera.time(),
    }
    map.rooms[rid] = room
  else
    room.name = name
    room.last_seen = lera.time()
  end

  -- Check if we're lost and trying to recover
  if mapping_lost then
    local has_connections = false
    for _, _ in pairs(room.connections) do
      has_connections = true
      break
    end
    if has_connections then
      mapping_lost = false
      map.pending_move = nil
      print("[mapper] Back in known territory. Mapping resumed.")
    else
      -- Still lost, just update current room
      map.current_room_id = rid
      if room.layer then
        map.current_layer = room.layer
      end
      return
    end
  end

  -- Only learn connections in mapping mode
  local pending_dir = map.pending_move
  map.pending_move = nil  -- clear it

  if mapping_mode and pending_dir and map.current_room_id then
    -- If same room, movement failed - don't record connection
    if rid == map.current_room_id then
      return
    end

    local prev = map.rooms[map.current_room_id]
    local dir = normalize_dir(pending_dir)

    if prev then
      -- Record the connection both ways
      prev.connections[dir] = rid
      local reverse = { n="s", s="n", e="w", w="e", ne="sw", sw="ne", nw="se", se="nw" }
      if reverse[dir] then
        room.connections[reverse[dir]] = map.current_room_id
      end

      -- Only calculate position for cardinal directions on non-virtual rooms
      if is_cardinal(dir) and not room.virtual then
        local offset = cardinal_offsets[dir]

        if is_new_room then
          -- New room - set position relative to previous
          room.x = prev.x + offset[1]
          room.y = prev.y + offset[2]
          room.layer = prev.layer
        end
      elseif not is_cardinal(dir) then
        -- Non-cardinal direction = layer change
        if is_new_room then
          room.layer = prev.layer .. "_" .. dir
          room.x = 0
          room.y = 0
        end
        map.current_layer = room.layer
      end
    end
  end

  map.current_room_id = rid

  -- Update current layer to match room's layer
  if room.layer then
    map.current_layer = room.layer
  end
end

--------------------------------------------------------------------------------
-- MIP Handlers
--------------------------------------------------------------------------------

local function handle_room(key, code, data)
  -- Strip any trailing whitespace/newlines
  data = data:gsub("%s+$", "")

  -- Format: "Short desc~ID"
  local name, rid_str = data:match("^(.-)~(%d+)$")
  if not rid_str then return end

  local rid = tonumber(rid_str)
  process_room(rid, name)
end

local function handle_exits(key, code, data)
  -- Format: "n~s~e~ID" - exits separated by ~, last element is room ID
  local parts = {}
  for part in data:gmatch("[^~]+") do
    table.insert(parts, part)
  end

  if #parts < 2 then return end  -- need at least one exit + room ID

  -- Last part is the room ID
  local rid = tonumber(parts[#parts])
  if not rid then return end

  -- Get or verify room
  local room = map.rooms[rid]
  if not room then return end

  -- All parts except last are exits
  room.exits = {}
  for i = 1, #parts - 1 do
    local exit = normalize_dir(parts[i])
    if exit ~= "" then
      table.insert(room.exits, exit)
    end
  end
end

--------------------------------------------------------------------------------
-- Track movement commands (only in mapping mode)
--------------------------------------------------------------------------------

local function track_movement(text)
  if not mapping_mode then return end
  if mapping_lost then return end  -- don't track while lost

  local cmd = text:lower():match("^(%S+)")
  if cmd then
    local dir = normalize_dir(cmd)
    local is_move = false

    -- Check if it looks like a direction (cardinal or known exit)
    if cardinal_offsets[dir] then
      is_move = true
    else
      -- Could be a non-cardinal exit (up, down, enter, portal, etc)
      local room = map.rooms[map.current_room_id]
      if room then
        for _, exit in ipairs(room.exits or {}) do
          if exit == dir or exit == cmd then
            is_move = true
            break
          end
        end
      end
    end

    if is_move then
      -- If we already have a pending move, we're moving too fast
      if map.pending_move then
        mapping_lost = true
        map.pending_move = nil
        print("[mapper] Moving too fast! Mapping paused until you return to a known room.")
      else
        map.pending_move = cmd
      end
    end
  end
end

-- Patterns that indicate movement failed
local failed_move_patterns = {
  "cannot go",
  "can't go",
  "no exit",
  "there is no",
  "you can't",
  "you cannot",
  "unable to",
  "blocked",
  "closed",
  "locked",
}

local function check_failed_movement(line)
  if not mapping_mode or not map.pending_move then return end

  local lower = line:lower()
  for _, pattern in ipairs(failed_move_patterns) do
    if lower:find(pattern, 1, true) then
      map.pending_move = nil  -- clear the failed move
      return
    end
  end
end

--------------------------------------------------------------------------------
-- Command handler (/map commands)
--------------------------------------------------------------------------------

local function handle_map_command(args)
  local cmd = args[1] or "help"

  if cmd == "start" or cmd == "on" then
    M.start_mapping()

  elseif cmd == "stop" or cmd == "off" then
    M.stop_mapping()

  elseif cmd == "toggle" then
    M.toggle_mapping()

  elseif cmd == "status" then
    print("[mapper] Mapping: " .. (mapping_mode and "ON" or "OFF"))
    if mapping_lost then
      print("[mapper] STATUS: LOST - move to a known room or use /map resync")
    end
    local room = map.rooms[map.current_room_id]
    if room then
      print("[mapper] Room: " .. room.name .. " (id=" .. room.id .. ")")
      print("[mapper] Position: " .. room.x .. "," .. room.y .. " layer=" .. room.layer)
      print("[mapper] Exits: " .. table.concat(room.exits or {}, ", "))
      local conn_count = 0
      for _ in pairs(room.connections) do conn_count = conn_count + 1 end
      print("[mapper] Connections: " .. conn_count)
    end

  elseif cmd == "resync" then
    mapping_lost = false
    map.pending_move = nil
    print("[mapper] Resync - mapping resumed from current position")

  elseif cmd == "wp" or cmd == "waypoint" then
    local name = args[2]
    if not name then
      print("[mapper] Usage: /map wp <name>")
    else
      M.set_waypoint(name)
    end

  elseif cmd == "wps" or cmd == "waypoints" then
    local wps = M.list_waypoints()
    if #wps == 0 then
      print("[mapper] No waypoints set")
    else
      print("[mapper] Waypoints:")
      for _, wp in ipairs(wps) do
        print("  " .. wp.name .. " -> " .. wp.room_name .. " (id=" .. wp.room_id .. ")")
      end
    end

  elseif cmd == "delwp" then
    local name = args[2]
    if not name then
      print("[mapper] Usage: /map delwp <name>")
    else
      if M.remove_waypoint(name) then
        -- already prints
      else
        print("[mapper] Waypoint '" .. name .. "' not found")
      end
    end

  elseif cmd == "virtual" then
    M.mark_virtual()

  elseif cmd == "unvirtual" then
    M.unmark_virtual()

  elseif cmd == "stats" then
    local s = M.stats()
    print("[mapper] Rooms: " .. s.rooms .. " (" .. s.virtual_rooms .. " virtual)")
    print("[mapper] Connections: " .. s.connections)
    print("[mapper] Waypoints: " .. s.waypoints)
    print("[mapper] Layers: " .. #s.layers)
    print("[mapper] Mapping: " .. (s.mapping_mode and "ON" or "OFF"))

  elseif cmd == "clear" then
    print("[mapper] Are you sure? Type: /map clear confirm")
    if args[2] == "confirm" then
      M.clear()
    end

  elseif cmd == "find" then
    local pattern = args[2]
    if not pattern then
      print("[mapper] Usage: /map find <name>")
    else
      local results = M.find(pattern)
      if #results == 0 then
        print("[mapper] No rooms matching '" .. pattern .. "'")
      else
        print("[mapper] Found " .. #results .. " rooms:")
        for i, room in ipairs(results) do
          if i > 10 then
            print("  ... and " .. (#results - 10) .. " more")
            break
          end
          print("  " .. room.name .. " (id=" .. room.id .. ") " .. room.layer)
        end
      end
    end

  else
    print("[mapper] Commands:")
    print("  /map start/stop/toggle  - control mapping mode")
    print("  /map status             - show current room info")
    print("  /map resync             - recover from 'lost' state")
    print("  /map wp <name>          - set waypoint here")
    print("  /map wps                - list waypoints")
    print("  /map delwp <name>       - delete waypoint")
    print("  /map find <name>        - search rooms by name")
    print("  /map virtual/unvirtual  - mark room as virtual")
    print("  /map stats              - show map statistics")
    print("  /map clear confirm      - delete all map data")
  end
end

function M.on_input(text)
  -- Track user-typed movement commands
  track_movement(text)
  return text
end

function M.on_send(text)
  -- Track programmatic movement (from speedwalk, triggers, etc.)
  track_movement(text)
  return text
end

function M.on_line(line)
  -- Check for failed movement messages
  check_failed_movement(line)
  return line
end

-- Called by roominfo when room changes
local function on_roominfo_change(new_room, old_room)
  local roominfo = plugin.get("roominfo")
  if roominfo and roominfo.room_id then
    local rid = roominfo.room_id()
    if rid and rid > 0 then
      process_room(rid, new_room)
    end
  end
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

local chars = {
  room = "#",
  current = "@",
  waypoint = "*",
  virtual = "~",
  unknown = "?",
  h_line = "-",
  v_line = "|",
  ne_line = "/",
  nw_line = "\\",
  se_line = "\\",
  sw_line = "/",
  empty = " ",
}

-- Helper to get external plugin info
local function get_info_lines(rw)
  local lines = {}

  -- Get speedwalk info
  local speedwalk = plugin.get("speedwalk")
  if speedwalk then
    local place = speedwalk.get_current_place()
    if place then
      local info = speedwalk.step_info()
      local step_str = ""
      if info.total > 0 then
        step_str = string.format(" [%d/%d]", info.current, info.total)
      end
      local place_line = place .. step_str
      if #place_line > rw then place_line = place_line:sub(1, rw - 1) .. "~" end
      table.insert(lines, place_line)

      -- Show targets - first try active targets, then fall back to place config
      local targets = speedwalk.get_targets()
      if #targets == 0 then
        -- Try to get from place config
        local place_config = speedwalk.get_place_config(place)
        if place_config and place_config.targets and place_config.targets ~= "" then
          for target in place_config.targets:gmatch("[^,]+") do
            target = target:match("^%s*(.-)%s*$")
            if target ~= "" then
              table.insert(targets, target)
            end
          end
        end
      end
      if #targets > 0 then
        local tgt_line = "T:" .. table.concat(targets, ",")
        if #tgt_line > rw then tgt_line = tgt_line:sub(1, rw - 1) .. "~" end
        table.insert(lines, tgt_line)
      end
    end
  end

  -- Get roominfo (monsters/players in room)
  local roominfo = plugin.get("roominfo")
  if roominfo then
    local monsters = roominfo.monsters()
    local players = roominfo.players()

    if #monsters > 0 then
      local mon_line = "M:" .. table.concat(monsters, ",")
      if #mon_line > rw then mon_line = mon_line:sub(1, rw - 1) .. "~" end
      table.insert(lines, mon_line)
    end

    if #players > 0 then
      local ply_line = "P:" .. table.concat(players, ",")
      if #ply_line > rw then ply_line = ply_line:sub(1, rw - 1) .. "~" end
      table.insert(lines, ply_line)
    end
  end

  return lines
end

function M.render(rect, opts)
  opts = opts or {}
  local show_border = opts.show_border ~= false
  local title = opts.title or "Map"
  if mapping_lost then
    title = title .. " [LOST]"
  elseif mapping_mode then
    title = title .. " [MAPPING]"
  end

  local rx, ry, rw, rh
  if type(rect.x) == "function" then
    rx, ry, rw, rh = rect:x(), rect:y(), rect:w(), rect:h()
  else
    rx, ry, rw, rh = rect.x, rect.y, rect.w, rect.h
  end

  if show_border then
    ui.box(rect, "single", title)
    rx, ry, rw, rh = rx + 1, ry + 1, rw - 2, rh - 2
  end

  if rw <= 0 or rh <= 0 then return end

  -- Get info lines to display below map
  local info_lines = get_info_lines(rw)
  local info_height = #info_lines
  local map_height = rh - info_height
  if map_height < 3 then map_height = 3 end  -- minimum map height

  if not map.current_room_id or not map.rooms[map.current_room_id] then
    ui.text(ui.rect(rx, ry, rw, 1), "No map data")
    ui.text(ui.rect(rx, ry + 1, rw, 1), "id=" .. tostring(map.current_room_id))
    -- Still show info lines
    for i, line in ipairs(info_lines) do
      ui.text(ui.rect(rx, ry + map_height + i - 1, rw, 1), line)
    end
    return
  end

  local current = map.rooms[map.current_room_id]

  -- Check if current room is virtual - show info instead of map
  if current.virtual then
    ui.text(ui.rect(rx, ry, rw, 1), "[Virtual Room]")
    ui.text(ui.rect(rx, ry + 2, rw, 1), current.name:sub(1, rw))
    ui.text(ui.rect(rx, ry + 3, rw, 1), "ID: " .. current.id)
    if current.exits and #current.exits > 0 then
      ui.text(ui.rect(rx, ry + 5, rw, 1), "Exits:")
      ui.text(ui.rect(rx, ry + 6, rw, 1), "  " .. table.concat(current.exits, ", "))
    end
    ui.text(ui.rect(rx, ry + rh - 1, rw, 1), "(/map unvirtual to unmark)")
    return
  end

  -- Build reverse waypoint lookup
  local room_waypoints = {}
  for name, rid in pairs(map.waypoints) do
    room_waypoints[rid] = name
  end

  -- Check if current room is unmapped (no connections yet)
  local current_is_unmapped = true
  for _, _ in pairs(current.connections) do
    current_is_unmapped = false
    break
  end

  -- Find all rooms in current layer
  local layer_rooms = {}
  if current_is_unmapped then
    -- Only show current room in isolation
    layer_rooms[map.current_room_id] = current
  else
    for id, room in pairs(map.rooms) do
      if room.layer == current.layer and not room.virtual then
        layer_rooms[id] = room
      end
    end
  end

  -- Grid setup - rooms at even positions, connections at odd
  local grid_w = rw
  local grid_h = map_height
  local center_gx = math.floor(grid_w / 2)
  local center_gy = math.floor(grid_h / 2)
  -- Make center even so rooms land on even positions
  if center_gx % 2 == 1 then center_gx = center_gx - 1 end
  if center_gy % 2 == 1 then center_gy = center_gy - 1 end

  local grid = {}
  for y = 1, grid_h do
    grid[y] = {}
    for x = 1, grid_w do
      grid[y][x] = chars.empty
    end
  end

  local function room_to_grid(room)
    local gx = center_gx + (room.x - current.x) * 2
    local gy = center_gy + (room.y - current.y) * 2
    return gx, gy
  end

  -- Place rooms
  for id, room in pairs(layer_rooms) do
    local gx, gy = room_to_grid(room)
    if gx >= 1 and gx <= grid_w and gy >= 1 and gy <= grid_h then
      if id == map.current_room_id then
        grid[gy][gx] = chars.current
      elseif room_waypoints[id] then
        grid[gy][gx] = chars.waypoint
      else
        grid[gy][gx] = chars.room
      end
    end
  end

  -- Helper to get connection character for a direction
  local function get_conn_char(offset)
    if offset[1] == 0 then
      return chars.v_line
    elseif offset[2] == 0 then
      return chars.h_line
    elseif offset[1] > 0 and offset[2] < 0 then
      return chars.ne_line
    elseif offset[1] < 0 and offset[2] < 0 then
      return chars.nw_line
    elseif offset[1] > 0 and offset[2] > 0 then
      return chars.se_line
    else
      return chars.sw_line
    end
  end

  -- Draw exits and connections
  for id, room in pairs(layer_rooms) do
    local gx, gy = room_to_grid(room)

    -- Draw all exits as connection lines
    for _, exit in ipairs(room.exits or {}) do
      local offset = cardinal_offsets[exit]
      if offset then
        local cx = gx + offset[1]
        local cy = gy + offset[2]

        if cx >= 1 and cx <= grid_w and cy >= 1 and cy <= grid_h then
          grid[cy][cx] = get_conn_char(offset)
        end

        -- Check if this exit leads to an unexplored room
        local target_id = room.connections[exit]
        if not target_id then
          -- Unexplored exit - show ? where the room would be
          local rx = gx + offset[1] * 2
          local ry = gy + offset[2] * 2
          if rx >= 1 and rx <= grid_w and ry >= 1 and ry <= grid_h then
            if grid[ry][rx] == chars.empty then
              grid[ry][rx] = chars.unknown
            end
          end
        end
      end
    end
  end

  -- Render grid
  for y = 1, grid_h do
    local line = ""
    for x = 1, grid_w do
      line = line .. grid[y][x]
    end
    ui.text(ui.rect(rx, ry + y - 1, rw, 1), line)
  end

  -- Render info lines below map
  for i, line in ipairs(info_lines) do
    ui.text(ui.rect(rx, ry + map_height + i - 1, rw, 1), line)
  end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Mapping mode control
function M.start_mapping()
  mapping_mode = true
  mapping_lost = false
  map.pending_move = nil
  print("[mapper] Mapping mode ON - connections will be learned")
end

function M.stop_mapping()
  mapping_mode = false
  mapping_lost = false
  map.pending_move = nil
  save_map()
  print("[mapper] Mapping mode OFF - saved")
end

function M.is_mapping()
  return mapping_mode
end

function M.toggle_mapping()
  if mapping_mode then
    M.stop_mapping()
  else
    M.start_mapping()
  end
  return mapping_mode
end

-- Waypoint management
function M.set_waypoint(name, room_id)
  room_id = room_id or map.current_room_id
  if not room_id then
    print("[mapper] No current room")
    return false
  end
  local room = map.rooms[room_id]
  if not room then
    print("[mapper] Room not found")
    return false
  end
  map.waypoints[name] = room_id
  save_map()
  print("[mapper] Waypoint '" .. name .. "' set to: " .. room.name)
  return true
end

function M.remove_waypoint(name)
  if map.waypoints[name] then
    map.waypoints[name] = nil
    save_map()
    print("[mapper] Waypoint '" .. name .. "' removed")
    return true
  end
  return false
end

function M.get_waypoint(name)
  local rid = map.waypoints[name]
  if rid then
    return map.rooms[rid]
  end
  return nil
end

function M.list_waypoints()
  local result = {}
  for name, rid in pairs(map.waypoints) do
    local room = map.rooms[rid]
    table.insert(result, {
      name = name,
      room_id = rid,
      room_name = room and room.name or "Unknown",
      layer = room and room.layer or "unknown",
    })
  end
  table.sort(result, function(a, b) return a.name < b.name end)
  return result
end

-- Room info
function M.current_room()
  if map.current_room_id then
    return map.rooms[map.current_room_id]
  end
  return nil
end

function M.get_room(id)
  return map.rooms[id]
end

function M.get_rooms()
  return map.rooms
end

-- Get freshness of a room (0.0 = very old, 1.0 = just seen)
-- age_thresholds: { fresh = seconds, stale = seconds, old = seconds }
-- Returns: freshness (0.0-1.0), age_seconds
function M.get_freshness(room_id, age_thresholds)
  age_thresholds = age_thresholds or { fresh = 300, stale = 3600, old = 86400 }
  local room = map.rooms[room_id]
  if not room or not room.last_seen or room.last_seen == 0 then
    return 0.0, math.huge
  end

  local now = lera.time()
  local age = now - room.last_seen

  if age <= age_thresholds.fresh then
    -- Fresh: 1.0 to 0.7
    return 1.0 - (age / age_thresholds.fresh) * 0.3, age
  elseif age <= age_thresholds.stale then
    -- Stale: 0.7 to 0.4
    local t = (age - age_thresholds.fresh) / (age_thresholds.stale - age_thresholds.fresh)
    return 0.7 - t * 0.3, age
  elseif age <= age_thresholds.old then
    -- Old: 0.4 to 0.1
    local t = (age - age_thresholds.stale) / (age_thresholds.old - age_thresholds.stale)
    return 0.4 - t * 0.3, age
  else
    -- Ancient: 0.1
    return 0.1, age
  end
end

function M.get_layer()
  return map.current_layer
end

-- Find rooms by name
function M.find(name_pattern)
  local results = {}
  local pattern = name_pattern:lower()
  for id, room in pairs(map.rooms) do
    if room.name:lower():find(pattern, 1, true) then
      table.insert(results, room)
    end
  end
  return results
end

-- Mark current room as virtual (unmappable)
function M.mark_virtual(room_id)
  room_id = room_id or map.current_room_id
  local room = map.rooms[room_id]
  if room then
    room.virtual = true
    save_map()
    print("[mapper] Marked as virtual: " .. room.name)
    return true
  end
  return false
end

-- Clear virtual flag
function M.unmark_virtual(room_id)
  room_id = room_id or map.current_room_id
  local room = map.rooms[room_id]
  if room then
    room.virtual = false
    save_map()
    return true
  end
  return false
end

-- Clear all map data
function M.clear()
  map.rooms = {}
  map.current_room_id = nil
  map.current_layer = "default"
  map.pending_move = nil
  map.waypoints = {}
  mapping_lost = false
  save_map()
  print("[mapper] Map cleared")
end

-- Export/stats
function M.export()
  return {
    rooms = map.rooms,
    current_room_id = map.current_room_id,
    current_layer = map.current_layer,
    waypoints = map.waypoints,
  }
end

function M.stats()
  local room_count = 0
  local connection_count = 0
  local virtual_count = 0
  local layers = {}

  for id, room in pairs(map.rooms) do
    room_count = room_count + 1
    if room.virtual then virtual_count = virtual_count + 1 end
    layers[room.layer] = (layers[room.layer] or 0) + 1
    for _, _ in pairs(room.connections) do
      connection_count = connection_count + 1
    end
  end

  local waypoint_count = 0
  for _ in pairs(map.waypoints) do
    waypoint_count = waypoint_count + 1
  end

  local layer_list = {}
  for layer, count in pairs(layers) do
    table.insert(layer_list, { name = layer, rooms = count })
  end

  return {
    rooms = room_count,
    connections = connection_count,
    virtual_rooms = virtual_count,
    waypoints = waypoint_count,
    layers = layer_list,
    current_layer = map.current_layer,
    current_room_id = map.current_room_id,
    mapping_mode = mapping_mode,
  }
end

-- Force save
function M.save()
  save_map()
  print("[mapper] Saved")
end

--------------------------------------------------------------------------------
-- Plugin lifecycle
--------------------------------------------------------------------------------

function M.on_load()
  load_map()

  table.insert(mip_handlers, mip.on("BAD", handle_room))
  table.insert(mip_handlers, mip.on("DDD", handle_exits))

  -- Register roominfo callback for faster room detection (no MIP delay)
  local roominfo = plugin.get("roominfo")
  if roominfo and roominfo.on_room_change then
    roominfo_callback_id = roominfo.on_room_change(on_roominfo_change)
  end

  -- Register /map command alias (must be before speedwalk's catch-all)
  -- Use two patterns: one for /map with args, one for bare /map
  table.insert(alias_ids, alias.add("^/map\\s+(.*)$", function(full_line, args_str)
    local args = {}
    for arg in (args_str or ""):gmatch("%S+") do
      table.insert(args, arg)
    end
    -- Don't intercept /mapview, /mapper, etc.
    if args[1] and args[1]:match("^view") then
      return full_line  -- Pass through unchanged
    end
    handle_map_command(args)
    return nil  -- suppress
  end))

  -- Handle bare /map with no args
  table.insert(alias_ids, alias.add("^/map$", function()
    handle_map_command({})
    return nil
  end))

  local stats = M.stats()
  local persist_note = has_store and "" or " (no persistence)"
  print("[mapper] Loaded: " .. stats.rooms .. " rooms, " .. stats.waypoints .. " waypoints" .. persist_note)
end

function M.on_unload()
  save_map()

  for _, handler_id in ipairs(mip_handlers) do
    mip.off(handler_id)
  end
  mip_handlers = {}

  -- Unregister roominfo callback
  if roominfo_callback_id then
    local roominfo = plugin.get("roominfo")
    if roominfo and roominfo.off_room_change then
      roominfo.off_room_change(roominfo_callback_id)
    end
    roominfo_callback_id = nil
  end

  for _, id in ipairs(alias_ids) do
    alias.remove(id)
  end
  alias_ids = {}

  print("[mapper] Saved and unloaded")
end

return M
