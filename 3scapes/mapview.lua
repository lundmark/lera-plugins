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

-- Rows the contents list will not take from the map, however crowded the room.
local LINES_RESERVED_FOR_MAP = 3

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

  -- Mobs (overrides freshness when mobs present). One colour only: a grid cell
  -- carries a single m glyph however many monsters stand there, so the protocol
  -- cannot express a count and there is no tiering to colour.
  mob1_fg = {255, 255, 180},      -- monsters present: pale yellow

  -- Players
  player_fg = {100, 220, 220},    -- cyan tint

  -- Waypoint
  waypoint_bg = {80, 40, 100},    -- purple background
  waypoint_fg = {190, 130, 220},  -- the [Waypoint: x] tag, echoing the grid bg

  -- Room name annotations
  area_fg = {130, 130, 150},      -- the [Area: x] tag: present but secondary

  -- Items (the third contents kind; monsters use mob1_fg, players player_fg)
  item_fg = {200, 170, 120},      -- warm tan

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

-- A grid cell is a room position when minimap's legend says so -- minimap
-- owns glyph semantics, so this delegates rather than matching characters
-- itself. Absent minimap (a profile may load mapview without it), fall back
-- to "nothing is a room cell": BFS correlation degrades to finding nothing
-- rather than guessing at a legend it cannot see. The handle is passed in:
-- plugin.get is a C lookup and the caller resolves it once per render instead
-- of once per grid cell.
local function is_room_cell(minimap, char)
  if not (minimap and minimap.is_room_cell) then return false end
  return minimap.is_room_cell(char)
end

-- The room cell at an exact column, or nil.
--
-- There is no positional fuzz any more, and there must not be: Room.Map rows
-- are exactly `w` glyphs, validated per row, and nothing strips leading
-- whitespace, so a room's column is exact. Grid rooms sit two cells apart, so
-- searching even one cell either side would land on the neighbouring room's
-- cell and turn a missing cell into a confidently wrong room association.
local function room_cell_at(minimap, line, col)
  if col < 1 or col > #line then return nil end
  local char = line:sub(col, col)
  if not is_room_cell(minimap, char) then return nil end
  return col, char
end

-- Build a map from minimap grid positions to mapper room IDs
-- Uses BFS from player position following known exits
local function correlate_positions(minimap_lines, player_pos, mapper, current_room_id, minimap)
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
              local found_col = room_cell_at(minimap, line, expected_col)
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
local function get_position_info(row, col, char, position_to_room, mapper, waypoint_rooms, minimap)
  -- minimap owns glyph semantics: the fixed legend contract makes X a link, and
  -- per-cell counts no longer exist. The handle is passed in so a render
  -- resolves the plugin once instead of once per grid cell.
  local class = (minimap and minimap.glyph_class) and minimap.glyph_class(char) or "other"

  local info = {
    char = char,
    class = class,
    fg = nil,
    bg = nil,
    is_current = false,
    is_mapped = false,
    is_waypoint = false,
    mob_count = 0,
    has_players = false,
    freshness = 0,
  }

  if class == "you" then
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

  -- Room.Map reports that a room holds monsters, but not how many: the
  -- mudlib collapses counts to a single m glyph, and the current room's own
  -- cell renders as "you" (returned above), never as "monsters" -- so a
  -- per-cell count is never available here. The real count for the room the
  -- player is standing in reaches the pane separately, via the M: info line
  -- built from roominfo.monsters() below.
  if class == "monsters" then
    info.mob_count = 1
    if settings.show_mobs then
      info.fg = colors.mob1_fg
    end
    return info
  end

  if class == "players" then
    info.has_players = true
    if settings.show_players then
      info.fg = colors.player_fg
    end
    return info
  end

  if class == "link" then
    if info.is_mapped then
      info.fg = colors.corridor_mapped_fg
    else
      info.fg = colors.corridor_fg
    end
    return info
  end

  if class == "unknown" then
    info.fg = colors.unknown_fg
    return info
  end

  if class == "room" or class == "enter" or class == "dark"
      or class == "updown" or class == "up" or class == "down" then
    if info.is_mapped and settings.show_freshness then
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

  -- roominfo is the sole GMCP Room.* subscriber and mapper seeds itself from
  -- roominfo's current state at load, so the two room ids agree: there is no
  -- longer even a hot-reload window where mapper trails behind. The guards that
  -- tolerated two independently timed sources are gone with the sources, and so
  -- is /mapview debug's divergence warning.
  local position_to_room = {}
  local waypoint_rooms = {}
  if mapper then
    position_to_room = correlate_positions(minimap_lines, player_pos, mapper,
                                          current_room_id, minimap)
    local waypoints = mapper.list_waypoints()
    for _, wp in ipairs(waypoints) do
      waypoint_rooms[wp.room_id] = wp.name
    end
  end

  -- Build colored output lines
  local output_lines = {}
  local max_width = 0

  for row_idx, raw_line in ipairs(minimap_lines) do
    local stripped = raw_line:match("^(.-)%s*$") or raw_line

    if #stripped > max_width then
      max_width = #stripped
    end

    local colored_line = ""
    for col_idx = 1, #stripped do
      local char = stripped:sub(col_idx, col_idx)
      local actual_col = col_idx

      if char == " " then
        colored_line = colored_line .. " "
      else
        local info = get_position_info(row_idx, actual_col, char, position_to_room,
                                       mapper, waypoint_rooms, minimap)

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

  -- Truncate against the pane width on the plain text, before any colour is
  -- added: an SGR escape costs bytes but no cells, so measuring the coloured
  -- string would clip visible text that actually fits.
  local function fit(text)
    if #text > rw then return text:sub(1, rw - 1) .. "~" end
    return text
  end

  local function add_line(text, fg)
    text = fit(text)
    if text == "" then return end
    info_lines[#info_lines + 1] = fg and colorize(text, fg, nil) or text
  end

  -- Room name, annotated with facts about the room the player is standing in.
  -- The annotations ride on the name line rather than taking lines of their
  -- own, and spill onto a continuation line only when the pane is too narrow.
  local room_name = nil
  if roominfo then
    room_name = roominfo.room()
  end
  if (not room_name or room_name == "") and minimap then
    room_name = minimap.room_name()
  end
  room_name = room_name and room_name:match("^%s*(.-)%s*$") or ""

  if room_name ~= "" then
    local segments = { { text = room_name } }

    -- The waypoint tag is mapper's, keyed by room id, so it is true of THIS
    -- room. speedwalk's current_place is deliberately not used here: it only
    -- moves when a walk completes or /speedwalk place is run, and it persists
    -- in the store, so it would label every room with wherever the last walk
    -- ended -- including across sessions, in a profile with no speedwalks.
    local wp_name = current_room_id and waypoint_rooms[current_room_id]
    if wp_name then
      segments[#segments + 1] = {
        text = "[Waypoint: " .. wp_name .. "]",
        fg = colors.waypoint_fg,
      }
    end

    local area = roominfo and roominfo.area()
    if not area or area == "" then area = "Unknown" end
    segments[#segments + 1] = { text = "[Area: " .. area .. "]", fg = colors.area_fg }

    local line, plain = "", ""
    local function flush()
      if plain ~= "" then info_lines[#info_lines + 1] = line end
      line, plain = "", ""
    end
    for _, seg in ipairs(segments) do
      local text = fit(seg.text)
      local sep = (plain == "") and "" or " "
      if plain ~= "" and #plain + #sep + #text > rw then
        flush()
        sep = ""
      end
      plain = plain .. sep .. text
      line = line .. sep .. (seg.fg and colorize(text, seg.fg, nil) or text)
    end
    flush()
  end

  -- Exits (from roominfo)
  if roominfo then
    local exits_str = roominfo.exits_string()
    if exits_str and exits_str ~= "" then
      add_line(exits_str)
    end
  end

  -- Speedwalk place and step counter, but only while a walk is actually
  -- running. See the note above: an idle session has a stale current_place,
  -- and rendering it unconditionally is what put a permanent "home" under
  -- every room name.
  if speedwalk then
    local step_info = speedwalk.step_info()
    local total = step_info and tonumber(step_info.total) or 0
    local place = (total > 0) and speedwalk.get_current_place() or nil
    if place then
      add_line(place .. string.format(" [%d/%d]", step_info.current, total))

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
        add_line("T:" .. table.concat(targets, ","))
      end
    end
  end

  -- Room contents from roominfo, one line per occupant: names are sentences on
  -- this mud and a comma-joined run of them is unreadable. The colour IS the
  -- type marker -- monsters, players and items each take the colour their glyph
  -- gets on the grid above -- so the lines carry no M:/P:/I: prefix and spend
  -- every cell of a narrow pane on the name.
  local contents = {}
  if roominfo then
    for _, name in ipairs(roominfo.monsters()) do
      contents[#contents + 1] = { text = name, fg = colors.mob1_fg }
    end

    for _, name in ipairs(roominfo.players()) do
      contents[#contents + 1] = { text = name, fg = colors.player_fg }
    end

    -- items() is newer than the rest of the roominfo surface; tolerate a
    -- roominfo that predates it rather than erroring the whole pane. Unlike
    -- monsters()/players() it returns entries rather than name strings, since
    -- the mudlib stacks duplicates into a count.
    local items = roominfo.items and roominfo.items() or {}
    for _, e in ipairs(items) do
      local n = tostring(e.name)
      local count = tonumber(e.count) or 1
      if count > 1 then n = n .. " x" .. count end
      contents[#contents + 1] = { text = n, fg = colors.item_fg }
    end
  end

  -- One line per occupant is unbounded, and this is still the map pane: a busy
  -- room would otherwise consume the whole height and push the grid off the
  -- top. Contents get whatever is left after the fixed lines, minus a few rows
  -- kept for the map, and the remainder collapses into a "+N more" marker.
  if #contents > 0 then
    local reserved = math.min(#output_lines, LINES_RESERVED_FOR_MAP)
    local budget = rh - #info_lines - reserved
    if budget >= 1 then
      local shown = #contents
      if shown > budget then
        -- The last available line states what did not fit, so a truncated
        -- list never looks like a complete one.
        shown = budget - 1
      end
      for i = 1, shown do
        add_line(contents[i].text, contents[i].fg)
      end
      if shown < #contents then
        add_line("+" .. (#contents - shown) .. " more", colors.area_fg)
      end
    end
  end

  -- Calculate layout: info at bottom, map centered in remaining space. The
  -- clamp matters: without it a pane shorter than the info block gives a
  -- negative map area and an info_y above ry, drawing over whatever sits
  -- above this pane.
  local info_height = math.min(#info_lines, rh)
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
  for i = 1, info_height do
    -- text_ansi, not text: the contents lines and the name-line tags carry SGR.
    ui.text_ansi(ui.rect(rx, info_y + i - 1, rw, 1), info_lines[i])
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
        -- tostring, not `or "N/A"`: false is the normal pre-connection answer.
        local is_synced = roominfo.is_synced and tostring(roominfo.is_synced()) or "N/A"
        local ri_room_id = roominfo.room_id and roominfo.room_id() or nil
        print("  Roominfo synced: " .. tostring(is_synced))
        print("  Roominfo room_id: " .. tostring(ri_room_id))
        if roominfo.debug_state then
          local state = roominfo.debug_state()
          print("  Roominfo has_map: " .. tostring(state.has_map))
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
        else
          print("  Mapper room: nil")
        end

        -- Test correlation
        if minimap and minimap.has_map() then
          local minimap_lines = minimap.get_map_lines()
          local player_pos = minimap.get_player_position()
          local current_room_id = current and current.id
          local position_to_room = correlate_positions(minimap_lines, player_pos, mapper,
                                                      current_room_id, minimap)
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
    print("  Pale yellow - rooms with monsters")
    print("  Purple background - waypoint")
    print("")
    print("Info lines under the map (the colour is the only type marker):")
    print("  Pale yellow - monsters in the room")
    print("  Cyan - players in the room")
    print("  Warm tan - items in the room")
    print("  Purple - [Waypoint: name], when this room is a mapper waypoint")
    print("  Dim gray - [Area: name]")
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
