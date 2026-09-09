-- Minimap Plugin for Lera
-- Renders the GMCP Room.Map line-of-sight grid roominfo publishes.
-- Integrates with speedwalk for path highlighting.
--
-- Owns glyph semantics for itself and for mapview: X is a link, # is darkness
-- and + is a room with both up and down exits.
--
-- That mapping is a fixed contract, mirrored in code below from the mudlib's
-- protocol_map_legend(). The `legend` field Room.Map transports is
-- informational -- it is carried for a human reading the packet and is NOT
-- consulted when classifying a glyph. This is deliberate: a legend arriving
-- from the server would let a mudlib change silently repaint the grid, and
-- mapview's correlation depends on which classes count as room cells. A future
-- legend change on the server therefore needs a matching edit here.

local M = {}
M.name = "minimap"
M.version = "2.0"
M.priority = 15  -- After roominfo (10), which is now this plugin's data source

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local command_id = nil        -- Registered command ID for cleanup

-- require("command") is optional: a profile that never required 'commands' has
-- no registry, and the minimap capture still works.
local command
do
  local ok, mod = pcall(require, "command")
  if ok then command = mod end
end

-- Settings (persisted)
local settings = {
  show_room_name = false,
  show_exits = false,
  show_steps = false,
  show_next_steps = false,
}

--------------------------------------------------------------------------------
-- Glyph semantics
--------------------------------------------------------------------------------

-- The Room.Map legend, as protocol_map_legend() defines it. minimap is the one
-- owner of this mapping; mapview calls glyph_class rather than re-deriving
-- meaning from characters. Kept in step with the mudlib by hand -- see the
-- header: the transported legend field is informational only.
local glyph_classes = {
  ["O"] = "room",
  ["@"] = "you",
  ["^"] = "up",
  ["v"] = "down",
  ["+"] = "updown",
  ["E"] = "enter",
  ["#"] = "dark",
  ["?"] = "unknown",
  ["p"] = "players",
  ["m"] = "monsters",
  ["|"] = "link",
  ["-"] = "link",
  ["/"] = "link",
  ["\\"] = "link",
  ["X"] = "link",
  [" "] = "blank",
}

function M.glyph_class(char)
  if type(char) ~= "string" or #char == 0 then return "other" end
  return glyph_classes[char:sub(1, 1)] or "other"
end

-- Classes that occupy a room position on the grid: everything except a
-- corridor link, a blank cell, and an unrecognized glyph. mapview's BFS
-- correlation uses this to recognize a room cell without re-deriving the
-- legend from a character class of its own.
local room_cell_classes = {
  room = true, you = true, up = true, down = true, updown = true,
  enter = true, dark = true, unknown = true, players = true, monsters = true,
}

function M.is_room_cell(char)
  return room_cell_classes[M.glyph_class(char)] == true
end

--------------------------------------------------------------------------------
-- Grid access
--------------------------------------------------------------------------------

local function current_grid()
  local roominfo = plugin.get("roominfo")
  if not roominfo or not roominfo.map then return nil end
  return roominfo.map()
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

-- Calculate path positions from player position following steps
-- steps: parsed commands from speedwalk's step-list
local function calculate_path(steps, start_pos, map_lines)
  if not start_pos or not steps or #steps == 0 then
    return {}
  end

  local positions = {}
  local row, col = start_pos.row, start_pos.col
  for step_num, dir in ipairs(steps) do
    -- Vertical and custom commands leave the known 2D path.
    if dir == "u" or dir == "d" or not known_directions[dir] then
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
        -- Only highlight rooms and links. Digits are gone: the mudlib collapses
        -- per-cell counts to p and m before they reach the wire.
        local class = M.glyph_class(char)
        if class == "room" or class == "link" or class == "players"
            or class == "monsters" then
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

  elseif cmd == "next" then
    local value = args[2]
    if value and value ~= "on" and value ~= "off" then
      print("[minimap] Usage: /minimap next [on|off]")
      return
    end
    if value then
      settings.show_next_steps = value == "on"
    else
      settings.show_next_steps = not settings.show_next_steps
    end
    store.set({settings = settings})
    store.save()
    print("[minimap] Next steps: " .. (settings.show_next_steps and "ON" or "OFF"))

  elseif cmd == "status" then
    print("[minimap] Status:")
    print("  Room name: " .. (settings.show_room_name and "ON" or "OFF"))
    print("  Exits: " .. (settings.show_exits and "ON" or "OFF"))
    print("  Steps: " .. (settings.show_steps and "ON" or "OFF"))
    print("  Next steps: " .. (settings.show_next_steps and "ON" or "OFF"))
    local grid = current_grid()
    print("  Has map: " .. (grid and ("Yes (" .. grid.h .. " lines)") or "No"))

    local roominfo_plugin = plugin.get("roominfo")
    local display_room = (roominfo_plugin and roominfo_plugin.room()) or ""
    if display_room ~= "" then
      print("  Room: " .. display_room)
    end
    local exits_text = (roominfo_plugin and roominfo_plugin.exits_string()) or ""
    if exits_text ~= "" then
      print("  Exits: " .. exits_text)
    end

  elseif cmd == "clear" then
    print("[minimap] The grid comes from GMCP Room.Map via roominfo; nothing local to clear")

  else
    print("[minimap] Commands:")
    print("  /minimap room   - Toggle room name display")
    print("  /minimap exits  - Toggle exits display")
    print("  /minimap steps  - Toggle step path display")
    print("  /minimap next [on|off] - Upcoming directions in minimap and mapview")
    print("  /minimap status - Show current status")
    print("  /minimap clear  - Clear map data")
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
      name = "/minimap",
      usage = "/minimap [room|exits|steps|next [on|off]|status|clear]",
      summary = "Compact minimap capture and display",
      description = "Captures the MUD's minimap output into a pane and toggles "
        .. "the extra lines drawn with it: room name, exits, step path and upcoming directions.",
      accepts_args = true,
      handler = function(args)
        local words = {}
        for word in tostring(args or ""):gmatch("%S+") do
          words[#words + 1] = word
        end
        handle_minimap_command(words)
      end,
    })
    if id then
      command_id = id
    else
      print("[minimap] command registration failed: " .. tostring(err))
    end
  end

  print("[minimap] Loaded")
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

  print("[minimap] Unloaded")
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

-- Shared by the direct and hybrid renderers; never loads or advances a route.
function M.next_steps_text()
  if not settings.show_next_steps then return nil end
  local sw = plugin.get("speedwalk")
  if not sw or not sw.upcoming_steps then return nil end
  local steps = sw.upcoming_steps(5)
  if #steps == 0 then return nil end
  return "Next: " .. table.concat(steps, ", ")
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

  local roominfo = plugin.get("roominfo")
  local room_name = (roominfo and roominfo.room()) or ""
  local exits_text = (roominfo and roominfo.exits_string()) or ""

  -- Calculate content heights
  local room_height = (settings.show_room_name and room_name ~= "") and 1 or 0
  local exits_height = (settings.show_exits and exits_text ~= "") and 1 or 0
  local step_height = 0

  -- Get speedwalk info if available
  local speedwalk_plugin = plugin.get("speedwalk")
  local step_info = nil
  local next_text = M.next_steps_text()

  if speedwalk_plugin and settings.show_steps then
    step_info = speedwalk_plugin.step_info()
    if step_info and step_info.total > 0 then
      step_height = 1
    end
  end

  local info_height = room_height + exits_height + step_height + (next_text and 1 or 0)
  local map_area_height = math.max(0, rh - info_height)

  local grid = current_grid() or {rows = {"No map data"}, w = 11}

  local map_lines = {}
  for i, row in ipairs(grid.rows) do map_lines[i] = row end
  local max_width = grid.w

  -- Apply path highlighting if speedwalk is active
  if speedwalk_plugin and settings.show_steps and step_info and step_info.total > 0 then
    local player_pos = find_player_position(map_lines)
    if player_pos then
      local next_steps = speedwalk_plugin.upcoming_steps
        and speedwalk_plugin.upcoming_steps(10) or {}

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

  if settings.show_room_name and room_name ~= "" and info_y < ry + rh then
    local room_str = room_name
    if #room_str > rw then
      room_str = room_str:sub(1, rw - 1) .. "~"
    end
    ui.text(ui.rect(rx, info_y, rw, 1), room_str)
    info_y = info_y + 1
  end

  if settings.show_exits and exits_text ~= "" and info_y < ry + rh then
    local exits_str = exits_text
    if #exits_str > rw then
      exits_str = exits_str:sub(1, rw - 1) .. "~"
    end
    ui.text(ui.rect(rx, info_y, rw, 1), exits_str)
    info_y = info_y + 1
  end

  if settings.show_steps and step_info and step_info.total > 0 and info_y < ry + rh then
    local step_str = string.format("%s [%d/%d]",
      step_info.place or "?",
      step_info.current,
      step_info.total)
    if #step_str > rw then
      step_str = step_str:sub(1, rw - 1) .. "~"
    end
    ui.text(ui.rect(rx, info_y, rw, 1), step_str)
    info_y = info_y + 1
  end
  if next_text and info_y < ry + rh then
    if #next_text > rw then next_text = next_text:sub(1, rw - 1) .. "~" end
    ui.text(ui.rect(rx, info_y, rw, 1), next_text)
  end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Get current room name. Uses roominfo as the authoritative source.
function M.room_name()
  local roominfo_plugin = plugin.get("roominfo")
  return (roominfo_plugin and roominfo_plugin.room()) or ""
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

function M.has_map()
  return current_grid() ~= nil
end

-- Grid rows, top to bottom. Empty when no Room.Map has arrived.
function M.get_map_lines()
  local grid = current_grid()
  if not grid then return {} end
  return grid.rows
end

function M.vertical_exits()
  local grid = current_grid()
  if not grid then return { up = false, down = false, enter = false } end
  return { up = grid.up, down = grid.down, enter = grid.enter }
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
    show_next_steps = settings.show_next_steps,
  }
end

function M.clear()
  -- The grid lives in roominfo; there is nothing cached here to drop.
end

-- Player position in the grid (1-indexed row, col), or nil.
function M.get_player_position()
  local grid = current_grid()
  if not grid then return nil end
  return find_player_position(grid.rows)
end

function M.get_map_size()
  local grid = current_grid()
  if not grid then return { rows = 0, cols = 0 } end
  return { rows = grid.h, cols = grid.w }
end

function M.get_char_at(pos)
  local grid = current_grid()
  if not grid then return nil end
  if not pos or not pos.row or not pos.col then return nil end
  if pos.row < 1 or pos.row > #grid.rows then return nil end
  local line = grid.rows[pos.row]
  if pos.col < 1 or pos.col > #line then return nil end
  return line:sub(pos.col, pos.col)
end

return M
