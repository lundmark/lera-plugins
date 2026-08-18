-- Mapview Plugin for Lera
-- Hybrid visualization combining minimap (real-time ASCII) and mapper (persistent DB)
-- Uses color to show: mapped vs unmapped, freshness, mobs, players, waypoints

local M = {}
M.name = "mapview"
M.version = "1.0"
M.priority = 70  -- Run after mapper (60), minimap (15), roominfo (10)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local settings = {
  show_mobs = true,
  show_players = true,
  show_freshness = true,
  show_waypoints = true,
  show_unmapped = true,
}

local command_id = nil

-- require("command") is optional: a profile that never required 'commands' has
-- no registry, and the map rendering still works.
local command
do
  local ok, mod = pcall(require, "command")
  if ok then command = mod end
end

-- Direction offsets for correlating minimap positions to mapper rooms
-- Minimap uses room-corridor-room pattern (2 units apart)
local direction_offsets = {
  n = {-2, 0}, s = {2, 0}, e = {0, 2}, w = {0, -2},
  ne = {-2, 2}, nw = {-2, -2}, se = {2, 2}, sw = {2, -2},
}

local reverse_dirs = {
  n = "s", s = "n", e = "w", w = "e",
  ne = "sw", nw = "se", se = "nw", sw = "ne",
}

--------------------------------------------------------------------------------
-- Color Definitions (ANSI RGB)
--------------------------------------------------------------------------------

-- Format: {r, g, b} for foreground, {r, g, b} for background, or nil for default

local colors = {
  -- Current room
  current_fg = {255, 255, 255},
  current_bg = {40, 40, 100},

  -- Freshness levels (mapped rooms)
  fresh_fg = {200, 220, 255},     -- < 5 min: light blue-white
  stale_fg = {140, 150, 180},     -- < 1 hr: dim blue-gray
  old_fg = {90, 95, 110},         -- < 24 hr: very dim gray
  ancient_fg = {60, 60, 70},      -- > 24 hr: almost invisible

  -- Unmapped (visible in minimap but not in mapper DB)
  unmapped_fg = {70, 70, 80},     -- dark gray

  -- Mobs (overrides freshness when mobs present)
  mob1_fg = {255, 255, 180},      -- 1 mob: pale yellow
  mob2_fg = {255, 200, 100},      -- 2 mobs: yellow-orange
  mob3_fg = {255, 150, 50},       -- 3-5 mobs: orange
  mob6_fg = {255, 80, 80},        -- 6+ mobs: red

  -- Players
  player_fg = {100, 220, 220},    -- cyan tint

  -- Waypoint
  waypoint_bg = {80, 40, 100},    -- purple background

  -- Corridors/connections
  corridor_fg = {100, 100, 120},  -- dim for corridors
  corridor_mapped_fg = {130, 130, 150},

  -- Unknown exits
  unknown_fg = {50, 50, 60},
}

--------------------------------------------------------------------------------
-- ANSI Color Helpers
--------------------------------------------------------------------------------

local function rgb_fg(r, g, b)
  return string.format("\027[38;2;%d;%d;%dm", r, g, b)
end

local function rgb_bg(r, g, b)
  return string.format("\027[48;2;%d;%d;%dm", r, g, b)
end

local function reset()
  return "\027[0m"
end

local function colorize(char, fg, bg)
  local result = ""
  if bg then
    result = result .. rgb_bg(bg[1], bg[2], bg[3])
  end
  if fg then
    result = result .. rgb_fg(fg[1], fg[2], fg[3])
  end
  result = result .. char .. reset()
  return result
end

--------------------------------------------------------------------------------
-- Position Correlation
--------------------------------------------------------------------------------

-- Room character pattern for matching
local room_char_pattern = "[O@XE123456789#%?%+v%^]"

-- Search for a room character near the expected position
-- Minimap lines can have varying leading spaces, so rooms may not be at exact offsets
-- Returns: col, char if found; nil otherwise
local function find_room_near(line, expected_col, max_offset)
  max_offset = max_offset or 2
  local len = #line

  -- Check exact position first
  if expected_col >= 1 and expected_col <= len then
    local char = line:sub(expected_col, expected_col)
    if char:match(room_char_pattern) then
      return expected_col, char
    end
  end

  -- Search nearby positions (left and right)
  for offset = 1, max_offset do
    -- Check right
    local right_col = expected_col + offset
    if right_col >= 1 and right_col <= len then
      local char = line:sub(right_col, right_col)
      if char:match(room_char_pattern) then
        return right_col, char
      end
    end

    -- Check left
    local left_col = expected_col - offset
    if left_col >= 1 and left_col <= len then
      local char = line:sub(left_col, left_col)
      if char:match(room_char_pattern) then
        return left_col, char
      end
    end
  end

  return nil
end

-- Build a map from minimap grid positions to mapper room IDs
-- Uses BFS from player position following known exits
local function correlate_positions(minimap_lines, player_pos, mapper, current_room_id)
  if not player_pos or not current_room_id then
    return {}
  end

  local room = mapper.get_room(current_room_id)
  if not room then
    return {}
  end

  -- Map of "row,col" -> room_id
  local position_to_room = {}
  -- Map of room_id -> {row, col}
  local room_to_position = {}

  -- Start with current room at player position
  local key = player_pos.row .. "," .. player_pos.col
  position_to_room[key] = current_room_id
  room_to_position[current_room_id] = {row = player_pos.row, col = player_pos.col}

  -- BFS queue: {room_id, row, col}
  local queue = {{current_room_id, player_pos.row, player_pos.col}}
  local visited = {[current_room_id] = true}

  while #queue > 0 do
    local item = table.remove(queue, 1)
    local rid, row, col = item[1], item[2], item[3]

    local r = mapper.get_room(rid)
    if r and r.connections then
      for dir, target_id in pairs(r.connections) do
        if not visited[target_id] then
          local offset = direction_offsets[dir]
          if offset then
            local new_row = row + offset[1]
            local expected_col = col + offset[2]

            -- Verify row is within map bounds
            if new_row >= 1 and new_row <= #minimap_lines then
              local line = minimap_lines[new_row]
              -- Search for room near expected position (handles varying leading spaces)
              local found_col, char = find_room_near(line, expected_col, 2)
              if found_col then
                local new_key = new_row .. "," .. found_col
                position_to_room[new_key] = target_id
                room_to_position[target_id] = {row = new_row, col = found_col}
                visited[target_id] = true
                table.insert(queue, {target_id, new_row, found_col})
              end
            end
          end
        end
      end
    end
  end

  return position_to_room, room_to_position
end

--------------------------------------------------------------------------------
-- Get Room Info at Position
--------------------------------------------------------------------------------

-- Returns info about what should be displayed at a minimap position
local function get_position_info(row, col, char, position_to_room, mapper, roominfo, waypoint_rooms)
  local info = {
    char = char,
    fg = nil,
    bg = nil,
    is_current = false,
    is_mapped = false,
    is_waypoint = false,
    mob_count = 0,
    has_players = false,
    freshness = 0,
  }

  -- Check if this is the current room (player position)
  if char == "@" then
    info.is_current = true
    info.is_mapped = true
    info.fg = colors.current_fg
    info.bg = colors.current_bg
    return info
  end

  -- Check if this position correlates to a mapped room
  local key = row .. "," .. col
  local room_id = position_to_room[key]

  if room_id then
    info.is_mapped = true

    -- Check if it's a waypoint
    if settings.show_waypoints and waypoint_rooms and waypoint_rooms[room_id] then
      info.is_waypoint = true
      info.bg = colors.waypoint_bg
    end

    -- Get freshness
    if mapper and mapper.get_freshness then
      info.freshness = mapper.get_freshness(room_id)
    end
  end

  -- Parse mob count from minimap character (1-9)
  if char:match("[1-9]") then
    info.mob_count = tonumber(char)
  end

  -- Corridors and connections
  if char:match("[|%-/\\]") then
    if info.is_mapped then
      info.fg = colors.corridor_mapped_fg
    else
      info.fg = colors.corridor_fg
    end
    return info
  end

  -- Unknown/unexplored
  if char == "?" then
    info.fg = colors.unknown_fg
    return info
  end

  -- Room characters: determine color based on state
  -- Include v (down exit) and ^ (up exit) as room characters
  if char:match("[OXE#%+v%^]") or info.mob_count > 0 then
    -- Mob coloring takes priority (if enabled)
    if settings.show_mobs and info.mob_count >= 6 then
      info.fg = colors.mob6_fg
    elseif settings.show_mobs and info.mob_count >= 3 then
      info.fg = colors.mob3_fg
    elseif settings.show_mobs and info.mob_count >= 2 then
      info.fg = colors.mob2_fg
    elseif settings.show_mobs and info.mob_count >= 1 then
      info.fg = colors.mob1_fg
    elseif info.is_mapped and settings.show_freshness then
      -- Color by freshness
      if info.freshness >= 0.7 then
        info.fg = colors.fresh_fg
      elseif info.freshness >= 0.4 then
        info.fg = colors.stale_fg
      elseif info.freshness >= 0.1 then
        info.fg = colors.old_fg
      else
        info.fg = colors.ancient_fg
      end
    elseif not info.is_mapped and settings.show_unmapped then
      -- Unmapped room visible in minimap
      info.fg = colors.unmapped_fg
    end
  end

  return info
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

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

  -- Get plugin references
  local minimap = plugin.get("minimap")
  local mapper = plugin.get("mapper")
  local roominfo = plugin.get("roominfo")

  -- Fallback: if no minimap, use mapper's render
  if not minimap or not minimap.has_map() then
    if mapper then
      mapper.render(rect, opts)
    else
      ui.text(ui.rect(rx, ry, rw, 1), "No map data")
    end
    return
  end

  -- Get minimap data
  local minimap_lines = minimap.get_map_lines()
  if #minimap_lines == 0 then
    ui.text(ui.rect(rx, ry, rw, 1), "No minimap")
    return
  end

  local player_pos = minimap.get_player_position()
  local current_room_id = mapper and mapper.current_room() and mapper.current_room().id

  -- Build position correlation
  local position_to_room = {}
  local waypoint_rooms = {}

  -- Only correlate if:
  -- 1. roominfo is fully synced (not waiting for RID from a split packet)
  -- 2. roominfo and mapper agree on the current room_id
  -- This prevents "one room behind" highlighting when data is out of sync
  local roominfo_synced = not roominfo or not roominfo.is_synced or roominfo.is_synced()
  local roominfo_rid = roominfo and roominfo.room_id and roominfo.room_id()
  local ids_match = not roominfo_rid or not current_room_id or (roominfo_rid == current_room_id)

  if mapper and roominfo_synced and ids_match then
    position_to_room = correlate_positions(minimap_lines, player_pos, mapper, current_room_id)

    -- Build waypoint lookup
    local waypoints = mapper.list_waypoints()
    for _, wp in ipairs(waypoints) do
      waypoint_rooms[wp.room_id] = wp.name
    end
  end

  -- Find minimum leading spaces to strip
  local min_leading = 9999
  for _, line in ipairs(minimap_lines) do
    local leading = #(line:match("^(%s*)") or "")
    if leading < min_leading then
      min_leading = leading
    end
  end

  -- Build colored output lines
  local output_lines = {}
  local max_width = 0

  for row_idx, raw_line in ipairs(minimap_lines) do
    local stripped = raw_line:sub(min_leading + 1)
    stripped = stripped:match("^(.-)%s*$") or stripped

    if #stripped > max_width then
      max_width = #stripped
    end

    local colored_line = ""
    for col_idx = 1, #stripped do
      local char = stripped:sub(col_idx, col_idx)
      local actual_col = min_leading + col_idx

      if char == " " then
        colored_line = colored_line .. " "
      else
        local info = get_position_info(row_idx, actual_col, char, position_to_room, mapper, roominfo, waypoint_rooms)

        if info.fg or info.bg then
          -- Use the original char from minimap (preserves mob counts, etc)
          colored_line = colored_line .. colorize(info.char, info.fg, info.bg)
        else
          colored_line = colored_line .. char
        end
      end
    end

    table.insert(output_lines, colored_line)
  end

  -- Build info lines first (so we know how much space they need)
  local info_lines = {}
  local speedwalk = plugin.get("speedwalk")

  -- Room name (from roominfo or minimap) - trim whitespace
  local room_name = nil
  if roominfo then
    room_name = roominfo.room()
  end
  if (not room_name or room_name == "") and minimap then
    room_name = minimap.room_name()
  end
  if room_name and room_name ~= "" then
    room_name = room_name:match("^%s*(.-)%s*$")  -- trim
    if #room_name > rw then room_name = room_name:sub(1, rw - 1) .. "~" end
    if room_name ~= "" then
      table.insert(info_lines, room_name)
    end
  end

  -- Exits (from roominfo)
  if roominfo then
    local exits_str = roominfo.exits_string()
    if exits_str and exits_str ~= "" then
      if #exits_str > rw then exits_str = exits_str:sub(1, rw - 1) .. "~" end
      table.insert(info_lines, exits_str)
    end
  end

  -- Speedwalk place and step counter
  if speedwalk then
    local place = speedwalk.get_current_place()
    if place then
      local step_info = speedwalk.step_info()
      local step_str = ""
      if step_info and step_info.total > 0 then
        step_str = string.format(" [%d/%d]", step_info.current, step_info.total)
      end
      local place_line = place .. step_str
      if #place_line > rw then place_line = place_line:sub(1, rw - 1) .. "~" end
      table.insert(info_lines, place_line)

      -- Targets
      local targets = speedwalk.get_targets()
      if #targets == 0 then
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
        table.insert(info_lines, tgt_line)
      end
    end
  end

  -- Monsters and players from roominfo
  if roominfo then
    local monsters = roominfo.monsters()
    local players = roominfo.players()

    if #monsters > 0 then
      local mon_str = "M:" .. table.concat(monsters, ",")
      if #mon_str > rw then mon_str = mon_str:sub(1, rw - 1) .. "~" end
      table.insert(info_lines, mon_str)
    end

    if #players > 0 then
      local ply_str = "P:" .. table.concat(players, ",")
      if #ply_str > rw then ply_str = ply_str:sub(1, rw - 1) .. "~" end
      table.insert(info_lines, ply_str)
    end
  end

  -- Calculate layout: info at bottom, map centered in remaining space
  local info_height = #info_lines
  local map_area_height = rh - info_height
  local map_height = #output_lines
  local y_offset = math.max(0, math.floor((map_area_height - map_height) / 2))
  local x_offset = math.max(0, math.floor((rw - max_width) / 2))

  -- Render map (centered in map area)
  for i, line in ipairs(output_lines) do
    local y = ry + y_offset + i - 1
    if y < ry + map_area_height then
      ui.text_ansi(ui.rect(rx + x_offset, y, rw - x_offset, 1), line)
    end
  end

  -- Render info at fixed bottom position
  local info_y = ry + rh - info_height
  for i, line in ipairs(info_lines) do
    ui.text(ui.rect(rx, info_y + i - 1, rw, 1), line)
  end
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local function handle_command(args)
  local cmd = args[1] or "help"

  if cmd == "mobs" then
    settings.show_mobs = not settings.show_mobs
    print("[mapview] Mob colors: " .. (settings.show_mobs and "ON" or "OFF"))

  elseif cmd == "players" then
    settings.show_players = not settings.show_players
    print("[mapview] Player colors: " .. (settings.show_players and "ON" or "OFF"))

  elseif cmd == "freshness" then
    settings.show_freshness = not settings.show_freshness
    print("[mapview] Freshness colors: " .. (settings.show_freshness and "ON" or "OFF"))

  elseif cmd == "waypoints" then
    settings.show_waypoints = not settings.show_waypoints
    print("[mapview] Waypoint colors: " .. (settings.show_waypoints and "ON" or "OFF"))

  elseif cmd == "unmapped" then
    settings.show_unmapped = not settings.show_unmapped
    print("[mapview] Unmapped room colors: " .. (settings.show_unmapped and "ON" or "OFF"))

  elseif cmd == "status" or cmd == "debug" then
    print("[mapview] Settings:")
    print("  Mob colors: " .. (settings.show_mobs and "ON" or "OFF"))
    print("  Player colors: " .. (settings.show_players and "ON" or "OFF"))
    print("  Freshness colors: " .. (settings.show_freshness and "ON" or "OFF"))
    print("  Waypoint colors: " .. (settings.show_waypoints and "ON" or "OFF"))
    print("  Unmapped colors: " .. (settings.show_unmapped and "ON" or "OFF"))

    local minimap = plugin.get("minimap")
    local mapper = plugin.get("mapper")
    local roominfo = plugin.get("roominfo")
    print("  Minimap: " .. (minimap and minimap.has_map() and "available" or "unavailable"))
    print("  Mapper: " .. (mapper and "available" or "unavailable"))

    -- Debug info for correlation
    if cmd == "debug" then
      -- Roominfo sync state
      if roominfo then
        local is_synced = roominfo.is_synced and roominfo.is_synced() or "N/A"
        local ri_room_id = roominfo.room_id and roominfo.room_id() or nil
        print("  Roominfo synced: " .. tostring(is_synced))
        print("  Roominfo room_id: " .. tostring(ri_room_id))
        if roominfo.debug_state then
          local state = roominfo.debug_state()
          print("  Roominfo pending: " .. tostring(state.pending_room))
        end
      end

      if minimap and minimap.has_map() then
        local player_pos = minimap.get_player_position()
        print("  Player pos: " .. (player_pos and (player_pos.row .. "," .. player_pos.col) or "nil"))
      end
      if mapper then
        local current = mapper.current_room()
        if current then
          print("  Mapper room_id: " .. current.id .. " (" .. current.name .. ")")
          local conn_count = 0
          local conn_dirs = {}
          for dir, _ in pairs(current.connections or {}) do
            conn_count = conn_count + 1
            table.insert(conn_dirs, dir)
          end
          print("  Connections: " .. conn_count .. " (" .. table.concat(conn_dirs, ", ") .. ")")
          local freshness = mapper.get_freshness(current.id)
          print("  Freshness: " .. string.format("%.2f", freshness))

          -- Check if roominfo and mapper agree
          if roominfo and roominfo.room_id then
            local ri_id = roominfo.room_id()
            if ri_id and ri_id ~= current.id then
              print("  WARNING: roominfo and mapper have different room IDs!")
            end
          end
        else
          print("  Mapper room: nil")
        end

        -- Test correlation
        if minimap and minimap.has_map() then
          local minimap_lines = minimap.get_map_lines()
          local player_pos = minimap.get_player_position()
          local current_room_id = current and current.id
          local position_to_room = correlate_positions(minimap_lines, player_pos, mapper, current_room_id)
          local corr_count = 0
          for _ in pairs(position_to_room) do corr_count = corr_count + 1 end
          print("  Correlated positions: " .. corr_count)
        end
      end
    end

  else
    print("[mapview] Hybrid minimap/mapper visualization")
    print("")
    print("Color meanings:")
    print("  Bright white on blue - current room")
    print("  Light blue-white - recently visited (< 5 min)")
    print("  Dim blue-gray - visited within the hour")
    print("  Very dim gray - old room (< 24 hr)")
    print("  Dark gray - unmapped (visible but not explored)")
    print("  Yellow/orange/red - rooms with mobs (1/2-5/6+)")
    print("  Purple background - waypoint")
    print("")
    print("Commands:")
    print("  /mapview mobs      - Toggle mob coloring")
    print("  /mapview players   - Toggle player coloring")
    print("  /mapview freshness - Toggle freshness coloring")
    print("  /mapview waypoints - Toggle waypoint highlighting")
    print("  /mapview unmapped  - Toggle unmapped room coloring")
    print("  /mapview status    - Show current settings")
  end
end

--------------------------------------------------------------------------------
-- Plugin Hooks
--------------------------------------------------------------------------------

function M.on_load()
  -- Load settings
  store.load()
  local data = store.get()
  if data and data.settings then
    for k, v in pairs(data.settings) do
      settings[k] = v
    end
  end

  if command then
    local id, err = command.register({
      name = "/mapview",
      usage = "/mapview [mobs|players|freshness|waypoints|unmapped|status]",
      summary = "Hybrid minimap/mapper visualization",
      description = "Draws the MUD's own minimap with mapper data overlaid: "
        .. "mob and player coloring, room freshness, waypoint highlighting and "
        .. "unmapped rooms, each toggled independently.",
      accepts_args = true,
      handler = function(args)
        local words = {}
        for word in tostring(args or ""):gmatch("%S+") do
          words[#words + 1] = word
        end
        handle_command(words)
      end,
    })
    if id then
      command_id = id
    else
      print("[mapview] command registration failed: " .. tostring(err))
    end
  end

  print("[mapview] Loaded - hybrid minimap/mapper visualization")
  print("[mapview] Use /mapview for help")
end

function M.on_unload()
  -- Save settings
  store.set({settings = settings})
  store.save()

  -- The loader drops a plugin's commands on unload; unregistering here keeps a
  -- manual reload from colliding with its own leftover record.
  if command and command_id then
    pcall(command.unregister, command_id)
    command_id = nil
  end

  print("[mapview] Unloaded")
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Get current settings
function M.get_settings()
  local result = {}
  for k, v in pairs(settings) do
    result[k] = v
  end
  return result
end

-- Set a setting
function M.set_setting(key, value)
  if settings[key] ~= nil then
    settings[key] = value
    return true
  end
  return false
end

-- Get color definitions (for customization)
function M.get_colors()
  local result = {}
  for k, v in pairs(colors) do
    if type(v) == "table" then
      result[k] = {v[1], v[2], v[3]}
    end
  end
  return result
end

-- Set a color
function M.set_color(name, r, g, b)
  if colors[name] then
    colors[name] = {r, g, b}
    return true
  end
  return false
end

return M
