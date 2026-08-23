-- Mapper Plugin for Lera
-- Tracks rooms via GMCP Room.Info and renders a minimal ASCII map

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
  waypoints = {},       -- name -> room_id
}

local command_id = nil
local roominfo_callback_id = nil

-- require("command") is optional: a profile that never required 'commands' has
-- no registry, and the mapping itself still works.
local command
do
  local ok, mod = pcall(require, "command")
  if ok then command = mod end
end

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

-- Positioning only. This names the opposite of a direction so the room we just
-- walked into can tell us which way we came, and it is never used to write a
-- connection: inventing a reverse edge is the bug this design removed.
local dir_reverse = {
  n = "s", s = "n", e = "w", w = "e",
  ne = "sw", sw = "ne", nw = "se", se = "nw",
  u = "d", d = "u",
}

-- Compass order, used only to make the direction search below deterministic
-- when a room has two exits to the same destination. pairs() order is
-- unspecified, so without this a two-exit room could be positioned differently
-- from one run to the next.
local dir_rank = {
  n = 1, ne = 2, e = 3, se = 4, s = 5, sw = 6, w = 7, nw = 8, u = 9, d = 10,
}

local function dir_before(a, b)
  local ra, rb = dir_rank[a], dir_rank[b]
  if ra and rb then return ra < rb end
  if ra then return true end
  if rb then return false end
  return a < b
end

-- The compass-first direction in `connections` that leads to `target`, or nil.
local function direction_to(connections, target)
  local best = nil
  for dir, dest in pairs(connections or {}) do
    if dest == target and (best == nil or dir_before(dir, best)) then
      best = dir
    end
  end
  return best
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
      area = room.area,
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
          area = room.area,
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
-- Room Processing (fed by roominfo's GMCP Room.Info snapshot)
--------------------------------------------------------------------------------

-- Core room processing logic - called when we detect a room change
local function process_room(rid, name, exits, destinations, area)
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
      area = area,
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
    if area then room.area = area end
    room.last_seen = lera.time()
  end

  -- Exits and their destinations come straight from Room.Info: there is nothing
  -- to learn by walking, so no mapping mode and no pending move.
  local exit_set = {}
  room.exits = {}
  for _, dir in ipairs(exits or {}) do
    local short = normalize_dir(dir)
    exit_set[short] = true
    table.insert(room.exits, short)
  end

  -- Rebuild connections from the snapshot, but delete only what the snapshot
  -- actually contradicts. A destination of 0 means "this exit exists, but the
  -- server could not resolve where it goes right now" -- find_object does not
  -- load an idle room -- so an exit that is still an exit keeps whatever
  -- destination an earlier visit learned. Dropping it would push the graph
  -- towards backward-only edges, which is the one direction mapview's
  -- correlation cannot follow. A direction that has left the exit set entirely
  -- is gone for real, which is what still sheds the invented reverse edges an
  -- older map carries: an invented direction was never an exit.
  local kept = {}
  for dir, dest in pairs(room.connections) do
    if exit_set[dir] then kept[dir] = dest end
  end
  room.connections = kept

  for dir, dest in pairs(destinations or {}) do
    -- A destination of 0 means the server reported the exit but no usable id.
    -- Recording it would point pathfinding at a room that does not exist.
    if dest and dest > 0 then
      room.connections[normalize_dir(dir)] = dest
    end
  end

  -- Position the room on first sight, relative to where we came from.
  local previous_id = map.current_room_id
  if is_new_room and previous_id and previous_id ~= rid then
    local prev = map.rooms[previous_id]
    if prev then
      -- First ask the room we came from where it thought this exit led. That
      -- answer is systematically missing on first discovery: the mudlib resolves
      -- a destination with find_object, which does not load an object, and an
      -- idle room destructs itself -- so a quiet area reports 0 for the room
      -- ahead exactly when it is new to us, and a 0 is never recorded as a
      -- connection.
      local dir = direction_to(prev.connections, rid)
      if not dir then
        -- Fall back to the back-edge in the room we just entered. Its snapshot
        -- was built while the previous room was certainly loaded, so the
        -- destination pointing back at it is reliably present. Inverting it
        -- yields the direction travelled -- a direction only; no connection is
        -- written from it.
        local back = direction_to(room.connections, previous_id)
        if back then dir = dir_reverse[back] end
      end
      if dir and is_cardinal(dir) and not room.virtual then
        local offset = cardinal_offsets[dir]
        room.x = prev.x + offset[1]
        room.y = prev.y + offset[2]
        room.layer = prev.layer
      elseif dir then
        room.layer = prev.layer .. "_" .. dir
        room.x = 0
        room.y = 0
        map.current_layer = room.layer
      end
    end
  end

  map.current_room_id = rid

  if room.layer then
    map.current_layer = room.layer
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
    print("[mapper] Mapping: always on")
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
    print("[mapper] Resync is unnecessary - GMCP exit destinations keep the map in sync")

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
    print("[mapper] Mapping: always on")

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
    print("  /map                    - mapping is always on (GMCP)")
    print("  /map status             - show current room info")
    print("  /map resync             - unnecessary now, kept for old habits")
    print("  /map wp <name>          - set waypoint here")
    print("  /map wps                - list waypoints")
    print("  /map delwp <name>       - delete waypoint")
    print("  /map find <name>        - search rooms by name")
    print("  /map virtual/unvirtual  - mark room as virtual")
    print("  /map stats              - show map statistics")
    print("  /map clear confirm      - delete all map data")
  end
end

-- roominfo is the sole GMCP Room.* subscriber; mapper reads the snapshot it
-- publishes whenever the room changes.
local function on_roominfo_change(new_room, old_room)
  local roominfo = plugin.get("roominfo")
  if not roominfo or not roominfo.room_id then return end
  local rid = roominfo.room_id()
  if not rid or rid <= 0 then return end
  process_room(rid, new_room,
    roominfo.exits and roominfo.exits() or {},
    roominfo.exit_destinations and roominfo.exit_destinations() or {},
    roominfo.area and roominfo.area() or nil)
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

-- Mapping mode is retired: Room.Info names every exit's destination, so
-- connections are learned on sight and there is nothing to switch on. These
-- remain so /map start|stop|toggle and any profile calling them keep working.
function M.start_mapping()
  print("[mapper] Mapping is always on (GMCP Room.Info carries exit destinations)")
end

function M.stop_mapping()
  save_map()
  print("[mapper] Mapping is always on; map saved")
end

function M.is_mapping()
  return true
end

function M.toggle_mapping()
  print("[mapper] Mapping is always on (GMCP Room.Info carries exit destinations)")
  return true
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
  map.waypoints = {}
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
    mapping_mode = true,
  }
end

-- Force save
function M.save()
  save_map()
  print("[mapper] Saved")
end

--------------------------------------------------------------------------------
-- Command
--------------------------------------------------------------------------------

local function register_command()
  if not command then return end
  -- The registry installs "^/map(?:\s+(.*))?$", which does not match /mapview
  -- or /mapper: those have no space after "/map".
  local id, err = command.register({
    name = "/map",
    usage = "/map [start|stop|status|resync|wp <name>|wps|delwp <name>|stats|find <name>|clear]",
    summary = "Room mapping and waypoints",
    description = "Learns room connections while mapping is on, tracks the "
      .. "current room, and stores named waypoints to walk back to. 'resync' "
      .. "recovers after moving faster than the mapper could follow.",
    accepts_args = true,
    handler = function(args)
      local words = {}
      for word in tostring(args or ""):gmatch("%S+") do
        words[#words + 1] = word
      end
      handle_map_command(words)
    end,
  })
  if id then
    command_id = id
  else
    print("[mapper] command registration failed: " .. tostring(err))
  end
end

local function unregister_command()
  -- The loader drops a plugin's commands on unload; unregistering here keeps a
  -- manual reload from colliding with its own leftover record.
  if command and command_id then
    pcall(command.unregister, command_id)
    command_id = nil
  end
end

--------------------------------------------------------------------------------
-- Plugin lifecycle
--------------------------------------------------------------------------------

function M.on_load()
  load_map()

  -- Register roominfo callback: it is the sole GMCP Room.* subscriber.
  local roominfo = plugin.get("roominfo")
  if roominfo and roominfo.on_room_change then
    roominfo_callback_id = roominfo.on_room_change(on_roominfo_change)
  end

  register_command()

  -- Seed from roominfo's current state. Room.Info fires on room entry only, so
  -- a mapper loaded (or reloaded) mid-session would otherwise have no current
  -- room until the player next moved -- and mapview's correlation, which starts
  -- from the current room, would colour nothing while the player stood still.
  if roominfo and roominfo.is_synced and roominfo.is_synced() then
    on_roominfo_change(roominfo.room and roominfo.room() or nil, nil)
  end

  local stats = M.stats()
  local persist_note = has_store and "" or " (no persistence)"
  print("[mapper] Loaded: " .. stats.rooms .. " rooms, " .. stats.waypoints .. " waypoints" .. persist_note)
end

function M.on_unload()
  save_map()

  -- Unregister roominfo callback
  if roominfo_callback_id then
    local roominfo = plugin.get("roominfo")
    if roominfo and roominfo.off_room_change then
      roominfo.off_room_change(roominfo_callback_id)
    end
    roominfo_callback_id = nil
  end

  unregister_command()

  print("[mapper] Saved and unloaded")
end

return M
