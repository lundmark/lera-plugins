-- Minimap Plugin for Lera
-- Captures and displays the ASCII minimap sent by the MUD
-- Integrates with speedwalk for path highlighting

local M = {}
M.name = "minimap"
M.version = "1.0"
M.priority = 5  -- Run before roominfo (10) to capture =R= lines before they're suppressed

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local map_buffer = {}         -- Buffered map lines (list of {text=, styles=})
local last_map = {}           -- Last complete map for redrawing
local capturing = false       -- Are we currently buffering map lines?
local alias_id = nil          -- Alias ID for /minimap command

-- Settings (persisted)
local settings = {
  show_room_name = false,
  show_exits = false,
  show_steps = false,
}

--------------------------------------------------------------------------------
-- Map Line Detection
--------------------------------------------------------------------------------

-- Valid map characters: | O X E - / \ @ # v ? + ^ 0-9 and space
-- These form the ASCII representation of the MUD's minimap:
--   | = north/south corridor
--   - = east/west corridor
--   / = NE/SW diagonal
--   \ = NW/SE diagonal
--   O = empty room
--   @ = player position
--   X = blocked/special room
--   E = exit room
--   # = wall/intersection
--   v = down exit indicator
--   ^ = up exit indicator
--   ? = unknown/unexplored
--   + = junction
--   0-9 = room with N mobs/players

-- Check if a line looks like a map line
local function is_map_line(line)
  -- Strip ANSI codes for pattern matching
  local plain = line:gsub("\027%[[0-9;]*m", "")

  -- Count leading spaces
  local leading_spaces = #(plain:match("^(%s*)") or "")
  local content = plain:sub(leading_spaces + 1)

  -- Trim trailing spaces
  content = content:match("^(.-)%s*$") or content

  -- Empty line is not a map line
  if #content == 0 then
    return false
  end

  -- Pattern 1: 50+ leading spaces = definitely map output area
  -- The MUD sends map at column 55+
  if leading_spaces >= 50 then
    -- Check if content is valid map characters
    if content:match("^[|OXE%-/%\\@#v%?%+%^ 0-9]+$") then
      return true
    end
  end

  -- Pattern 2: Check if line is purely map characters
  -- This catches map lines that may have fewer leading spaces
  if content:match("^[|OXE%-/%\\@#v%?%+%^ 0-9]+$") then
    -- Must contain at least one structural map character (not just spaces)
    if content:match("[|OXE%-/%\\@#v%?%+%^0-9]") then
      -- Heuristic: map lines typically have multiple map chars
      local map_char_count = 0
      for c in content:gmatch("[|OXE%-/%\\@#v%?%+%^0-9]") do
        map_char_count = map_char_count + 1
      end
      -- At least 2 structural chars, or line is short (could be edge of map)
      if map_char_count >= 2 or #content <= 5 then
        return true
      end
    end
  end

  return false
end

--------------------------------------------------------------------------------
-- Map Parsing & Buffering
--------------------------------------------------------------------------------

local function add_map_line(line, styles)
  capturing = true
  table.insert(map_buffer, {
    text = line,
    styles = styles or {},
  })
end

local function finalize_map()
  if #map_buffer > 0 then
    -- Copy buffer to last_map
    last_map = {}
    for _, entry in ipairs(map_buffer) do
      table.insert(last_map, entry)
    end
    map_buffer = {}
  end
  capturing = false
end

--------------------------------------------------------------------------------
-- Path Highlighting (speedwalk integration)
--------------------------------------------------------------------------------

-- Direction offsets for 2D map (row, col)
-- Map uses: room-corridor-room pattern where rooms are 2 units apart
local direction_offsets = {
  n = {-2, 0}, s = {2, 0}, e = {0, 2}, w = {0, -2},
  ne = {-2, 2}, nw = {-2, -2}, se = {2, 2}, sw = {2, -2},
  u = {0, 0}, d = {0, 0},  -- vertical doesn't move on 2D map
}

-- Known directions for validation
local known_directions = {
  n = true, s = true, e = true, w = true,
  ne = true, nw = true, se = true, sw = true,
  u = true, d = true,
}

-- Find the player (@) position in the map
local function find_player_position(map_lines)
  for row_idx, line in ipairs(map_lines) do
    local col = line:find("@", 1, true)
    if col then
      return {row = row_idx, col = col}
    end
  end
  return nil
end

-- Expand speedwalk shorthand notation
-- "3e" -> {"e", "e", "e"}
-- "2(nw)" -> {"nw", "nw"}
-- "(portal)" -> {"portal"}
local function expand_step(step)
  local expanded = {}
  local pos = 1

  while pos <= #step do
    -- Try: count + (direction)
    local count_str, paren_dir, new_pos = step:match("^(%d*)%(([^)]+)%)()", pos)
    if paren_dir then
      local count = (count_str and count_str ~= "") and tonumber(count_str) or 1
      for _ = 1, count do
        table.insert(expanded, paren_dir)
      end
      pos = new_pos
    else
      -- Try: count + single char direction
      local count_str2, dir, new_pos2 = step:match("^(%d*)([a-z])()", pos)
      if dir then
        local count = (count_str2 and count_str2 ~= "") and tonumber(count_str2) or 1
        for _ = 1, count do
          table.insert(expanded, dir)
        end
        pos = new_pos2
      else
        -- Can't parse, skip character
        pos = pos + 1
      end
    end
  end

  if #expanded == 0 then
    table.insert(expanded, step)
  end

  return expanded
end

-- Calculate path positions from player position following steps
-- steps: list of direction strings (may include shorthand like "3e")
local function calculate_path(steps, start_pos, map_lines)
  if not start_pos or not steps or #steps == 0 then
    return {}
  end

  local positions = {}
  local row, col = start_pos.row, start_pos.col
  local step_num = 0

  for _, step in ipairs(steps) do
    -- Expand shorthand notation
    local expanded = expand_step(step)

    for _, dir in ipairs(expanded) do
      step_num = step_num + 1

      -- Stop at vertical movement (changes level)
      if dir == "u" or dir == "d" then
        return positions
      end

      -- Stop at unknown/custom commands
      if not known_directions[dir] then
        return positions
      end

      local offset = direction_offsets[dir]
      if offset then
        row = row + offset[1]
        col = col + offset[2]

        -- Only add if within map bounds
        if row >= 1 and row <= #map_lines and col >= 1 and col <= #map_lines[row] then
          table.insert(positions, {
            row = row,
            col = col,
            step_num = step_num,
            direction = dir,
          })
        end
      end
    end
  end

  return positions
end

-- Apply path highlighting to map lines
-- Returns new map lines with path markers
local function highlight_path(map_lines, path_positions)
  if #path_positions == 0 then
    return map_lines
  end

  -- Copy map lines
  local result = {}
  for i, line in ipairs(map_lines) do
    result[i] = line
  end

  -- Apply highlights
  for _, pos in ipairs(path_positions) do
    local row = pos.row
    if row >= 1 and row <= #result then
      local line = result[row]
      local col = pos.col
      if col >= 1 and col <= #line then
        local char = line:sub(col, col)
        -- Only highlight room/corridor characters
        if char:match("[O123456789|%-/\\]") then
          -- Use step number as marker (1-9, then wrap to 0)
          local marker = tostring(pos.step_num % 10)
          result[row] = line:sub(1, col - 1) .. marker .. line:sub(col + 1)
        end
      end
    end
  end

  return result
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local function handle_minimap_command(args)
  local cmd = args[1] or "help"

  if cmd == "room" then
    settings.show_room_name = not settings.show_room_name
    print("[minimap] Room name: " .. (settings.show_room_name and "ON" or "OFF"))

  elseif cmd == "exits" then
    settings.show_exits = not settings.show_exits
    print("[minimap] Exits: " .. (settings.show_exits and "ON" or "OFF"))

  elseif cmd == "steps" then
    settings.show_steps = not settings.show_steps
    print("[minimap] Steps: " .. (settings.show_steps and "ON" or "OFF"))

  elseif cmd == "status" then
    print("[minimap] Status:")
    print("  Room name: " .. (settings.show_room_name and "ON" or "OFF"))
    print("  Exits: " .. (settings.show_exits and "ON" or "OFF"))
    print("  Steps: " .. (settings.show_steps and "ON" or "OFF"))
    print("  Has map: " .. (#last_map > 0 and "Yes (" .. #last_map .. " lines)" or "No"))

    -- Show room info from roominfo plugin if available
    local roominfo_plugin = plugin.get("roominfo")
    local display_room = last_room_name
    if roominfo_plugin then
      local ri_room = roominfo_plugin.room()
      if ri_room and ri_room ~= "" then
        display_room = ri_room
      end
    end
    if display_room ~= "" then
      print("  Room: " .. display_room)
    end
    if last_exits ~= "" then
      print("  Exits: " .. last_exits)
    end

  elseif cmd == "clear" then
    M.clear()
    print("[minimap] Cleared")

  else
    print("[minimap] Commands:")
    print("  /minimap room   - Toggle room name display")
    print("  /minimap exits  - Toggle exits display")
    print("  /minimap steps  - Toggle step path display")
    print("  /minimap status - Show current status")
    print("  /minimap clear  - Clear map data")
  end
end

--------------------------------------------------------------------------------
-- Plugin Hooks
--------------------------------------------------------------------------------


function M.on_line(line)
  local plain = line:gsub("\027%[[0-9;]*m", "")

  -- Check for =R= room line (roominfo handles parsing, we just detect for map finalization)
  -- Note: =R= can be prefixed by prompts like "> "
  if plain:match("=R=") then
    -- Finalize any pending map
    if capturing then
      finalize_map()
    end
    -- Don't suppress - let roominfo handle it
    return line
  end

  -- Check for map line
  if is_map_line(line) then
    add_map_line(line)
    return nil  -- suppress map lines from main output
  end

  -- Non-map line - finalize any buffered map
  if capturing and #map_buffer > 0 then
    finalize_map()
  end

  return line
end

function M.on_load()
  -- Load settings
  store.load()
  local data = store.get()
  if data and data.settings then
    for k, v in pairs(data.settings) do
      settings[k] = v
    end
  end

  -- Register /minimap command alias
  alias_id = alias.add("^/minimap\\s*(.*)$", function(_, args_str)
    local args = {}
    for arg in (args_str or ""):gmatch("%S+") do
      table.insert(args, arg)
    end
    handle_minimap_command(args)
    return nil  -- suppress
  end)

  print("[minimap] Loaded")
end

function M.on_unload()
  -- Save settings
  store.set({settings = settings})
  store.save()

  if alias_id then
    alias.remove(alias_id)
    alias_id = nil
  end

  print("[minimap] Unloaded")
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

  -- Calculate content heights
  local room_height = (settings.show_room_name and last_room_name ~= "") and 1 or 0
  local exits_height = (settings.show_exits and last_exits ~= "") and 1 or 0
  local step_height = 0

  -- Get speedwalk info if available
  local speedwalk_plugin = plugin.get("speedwalk")
  local step_info = nil
  local next_steps = {}

  if speedwalk_plugin and settings.show_steps then
    step_info = speedwalk_plugin.step_info()
    if step_info and step_info.total > 0 then
      step_height = step_height + 1  -- step counter line
      -- Get next steps for display
      local current_idx = step_info.current
      for i = 1, 5 do
        local idx = current_idx + i
        if idx <= step_info.total then
          -- We need to get the step from speedwalk - but we don't have direct access
          -- For now just show the count
        end
      end
      if #next_steps > 0 then
        step_height = step_height + 1  -- next steps line
      end
    end
  end

  local info_height = room_height + exits_height + step_height
  local map_area_height = rh - info_height

  -- No map data
  if #last_map == 0 then
    ui.text(ui.rect(rx, ry, rw, 1), "No map data")
    return
  end

  -- Find minimum leading spaces to strip
  local min_leading = 9999
  for _, entry in ipairs(last_map) do
    local plain = entry.text:gsub("\027%[[0-9;]*m", "")
    local leading = #(plain:match("^(%s*)") or "")
    if leading < min_leading then
      min_leading = leading
    end
  end

  -- Calculate map dimensions and build clean lines
  local map_lines = {}
  local max_width = 0
  for _, entry in ipairs(last_map) do
    local plain = entry.text:gsub("\027%[[0-9;]*m", "")
    local stripped = plain:sub(min_leading + 1)
    -- Trim trailing spaces
    stripped = stripped:match("^(.-)%s*$") or stripped
    table.insert(map_lines, stripped)
    if #stripped > max_width then
      max_width = #stripped
    end
  end

  -- Apply path highlighting if speedwalk is active
  if speedwalk_plugin and settings.show_steps and step_info and step_info.total > 0 then
    local player_pos = find_player_position(map_lines)
    if player_pos then
      -- Get next steps from speedwalk if available
      local next_steps = {}

      -- Try to get step commands from speedwalk
      -- The speedwalk plugin exposes peek_step() and step_info()
      -- We need to iterate through remaining steps
      local remaining = step_info.total - step_info.current
      if remaining > 0 then
        -- Get current place's steps configuration
        local place_config = speedwalk_plugin.get_place_config(step_info.place)
        if place_config and place_config.steps then
          -- Parse the steps string (pipe-separated)
          local all_steps = {}
          for step in place_config.steps:gmatch("[^|]+") do
            step = step:match("^%s*(.-)%s*$")
            if step ~= "" then
              table.insert(all_steps, step)
            end
          end
          -- Get steps from current position onward (up to 10 for display)
          for i = step_info.current + 1, math.min(step_info.current + 10, #all_steps) do
            table.insert(next_steps, all_steps[i])
          end
        end
      end

      if #next_steps > 0 then
        local path_positions = calculate_path(next_steps, player_pos, map_lines)
        if #path_positions > 0 then
          map_lines = highlight_path(map_lines, path_positions)
        end
      end
    end
  end

  -- Center map vertically in available space
  local map_height = #map_lines
  local y_offset = math.max(0, math.floor((map_area_height - map_height) / 2))

  -- Center map horizontally
  local x_offset = math.max(0, math.floor((rw - max_width) / 2))

  -- Draw map lines
  for i, line in ipairs(map_lines) do
    local y = ry + y_offset + i - 1
    if y < ry + map_area_height then
      ui.text(ui.rect(rx + x_offset, y, rw - x_offset, 1), line)
    end
  end

  -- Draw info below map
  local info_y = ry + map_area_height

  -- Get room name from roominfo plugin if available, otherwise use our own
  local display_room_name = last_room_name
  local roominfo_plugin = plugin.get("roominfo")
  if roominfo_plugin then
    local ri_room = roominfo_plugin.room()
    if ri_room and ri_room ~= "" then
      display_room_name = ri_room
    end
  end

  if settings.show_room_name and display_room_name ~= "" then
    local room_str = display_room_name
    if #room_str > rw then
      room_str = room_str:sub(1, rw - 1) .. "~"
    end
    ui.text(ui.rect(rx, info_y, rw, 1), room_str)
    info_y = info_y + 1
  end

  if settings.show_exits and last_exits ~= "" then
    local exits_str = last_exits
    if #exits_str > rw then
      exits_str = exits_str:sub(1, rw - 1) .. "~"
    end
    ui.text(ui.rect(rx, info_y, rw, 1), exits_str)
    info_y = info_y + 1
  end

  if settings.show_steps and step_info and step_info.total > 0 then
    local step_str = string.format("%s [%d/%d]",
      step_info.place or "?",
      step_info.current,
      step_info.total)
    if #step_str > rw then
      step_str = step_str:sub(1, rw - 1) .. "~"
    end
    ui.text(ui.rect(rx, info_y, rw, 1), step_str)
  end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Get current room name (prefers roominfo plugin data if available)
function M.room_name()
  local roominfo_plugin = plugin.get("roominfo")
  if roominfo_plugin then
    local ri_room = roominfo_plugin.room()
    if ri_room and ri_room ~= "" then
      return ri_room
    end
  end
  return last_room_name
end

-- Get current exits (list of short direction names)
-- Uses roominfo as the authoritative source
function M.exits()
  local roominfo_plugin = plugin.get("roominfo")
  if roominfo_plugin and roominfo_plugin.exits then
    return roominfo_plugin.exits()
  end
  return {}
end

-- Get exits as formatted string
-- Uses roominfo as the authoritative source
function M.exits_string()
  local roominfo_plugin = plugin.get("roominfo")
  if roominfo_plugin and roominfo_plugin.exits_string then
    return roominfo_plugin.exits_string()
  end
  return ""
end

-- Check if we have map data
function M.has_map()
  return #last_map > 0
end

-- Get raw map lines (stripped of ANSI)
function M.get_map_lines()
  local result = {}
  for _, entry in ipairs(last_map) do
    local plain = entry.text:gsub("\027%[[0-9;]*m", "")
    table.insert(result, plain)
  end
  return result
end

-- Toggle settings
function M.toggle_room_name()
  settings.show_room_name = not settings.show_room_name
  return settings.show_room_name
end

function M.toggle_exits()
  settings.show_exits = not settings.show_exits
  return settings.show_exits
end

function M.toggle_steps()
  settings.show_steps = not settings.show_steps
  return settings.show_steps
end

-- Get settings
function M.get_settings()
  return {
    show_room_name = settings.show_room_name,
    show_exits = settings.show_exits,
    show_steps = settings.show_steps,
  }
end

-- Clear map data
function M.clear()
  map_buffer = {}
  last_map = {}
  capturing = false
end

-- Get player position in the map (1-indexed row, col)
-- Returns {row=N, col=N} or nil if not found
function M.get_player_position()
  if #last_map == 0 then return nil end

  local map_lines = M.get_map_lines()
  return find_player_position(map_lines)
end

-- Get map dimensions
function M.get_map_size()
  if #last_map == 0 then
    return {rows = 0, cols = 0}
  end

  local map_lines = M.get_map_lines()
  local max_cols = 0
  for _, line in ipairs(map_lines) do
    if #line > max_cols then
      max_cols = #line
    end
  end

  return {rows = #map_lines, cols = max_cols}
end

-- Get the character at a specific map position
-- pos: {row=N, col=N} (1-indexed)
-- Returns the character or nil if out of bounds
function M.get_char_at(pos)
  if #last_map == 0 then return nil end
  if not pos or not pos.row or not pos.col then return nil end

  local map_lines = M.get_map_lines()
  if pos.row < 1 or pos.row > #map_lines then return nil end

  local line = map_lines[pos.row]
  if pos.col < 1 or pos.col > #line then return nil end

  return line:sub(pos.col, pos.col)
end

return M
