-- Chat Monitor Plugin for Lera
-- Captures MIP chat events (tells, emotes, chat lines) and displays them
-- in a separate panel with color coding and gag support.

local M = {}
M.name = "chat_monitor"
M.version = "1.1"
M.priority = 50  -- Run before most plugins

local wm = require("wm")

-- Configuration
local config = {
  max_lines = 32768,      -- Max lines to keep in scrollback (32k default)
  default_color = "white",
}

-- Default prefix function for built-in types
local function default_tell_prefix(cfg, who)
  return "[" .. (who or "???") .. "] "
end

local function default_emote_prefix(cfg, who)
  return "* " .. (who or "???") .. " "
end

-- Chat line types with their colors and enabled state
-- Format: { color = "color_name", enabled = true/false, gags = {}, prefix = function }
local line_types = {
  -- Built-in types
  tell_in   = { color = "cyan",    enabled = true, gags = {}, label = "Tell (in)",   prefix = default_tell_prefix },
  tell_out  = { color = "magenta", enabled = true, gags = {}, label = "Tell (out)",  prefix = default_tell_prefix },
  emote_in  = { color = "yellow",  enabled = true, gags = {}, label = "Emote (in)",  prefix = default_emote_prefix },
  emote_out = { color = "green",   enabled = true, gags = {}, label = "Emote (out)", prefix = default_emote_prefix },
  -- Chat lines are added dynamically via add_chatline()
}

-- Color codes for ANSI output
local colors = {
  black   = "\027[30m",
  red     = "\027[31m",
  green   = "\027[32m",
  yellow  = "\027[33m",
  blue    = "\027[34m",
  magenta = "\027[35m",
  cyan    = "\027[36m",
  white   = "\027[37m",
  reset   = "\027[0m",
  -- Bright variants
  bright_black   = "\027[90m",
  bright_red     = "\027[91m",
  bright_green   = "\027[92m",
  bright_yellow  = "\027[93m",
  bright_blue    = "\027[94m",
  bright_magenta = "\027[95m",
  bright_cyan    = "\027[96m",
  bright_white   = "\027[97m",
}

-- Chat message buffer
-- Each entry: { type = "type_id", sender = "name", text = "message", seq = N }
local messages = {}
local message_seq = 0  -- Sequence number for ordering

-- MIP handler refs for cleanup
local mip_handlers = {}

-- Wrapped-line cache: a deque so trimming old messages never shifts the array.
-- Rebuilt in full when the render width changes; appended to incrementally.
-- Entries: { text, color_code, is_continuation }
local wrapped = { width = nil, lines = {}, first = 1, last = 0 }

local sc = wm.make_scroller({
  count = function() return wrapped.last - wrapped.first + 1 end,
})

-- Cache helpers are defined after word_wrap (which they use) but called from
-- add_message above them; predeclare so those calls bind these locals, not
-- accidental globals.
local wrapped_reset, wrapped_append, wrapped_ensure, wrapped_trim_front

--------------------------------------------------------------------------------
-- Internal helpers
--------------------------------------------------------------------------------

local function get_color(color_name)
  return colors[color_name] or colors.white
end

local function add_message(msg_type, sender, text)
  local type_cfg = line_types[msg_type]
  if not type_cfg then
    -- Unknown type, use defaults
    type_cfg = { color = config.default_color, enabled = true, gags = {} }
  end

  -- Check if this type is enabled
  if not type_cfg.enabled then
    return false
  end

  -- Check gags
  for _, pattern in ipairs(type_cfg.gags or {}) do
    if text:match(pattern) or (sender and sender:match(pattern)) then
      return false  -- Gagged
    end
  end

  -- Add to buffer
  message_seq = message_seq + 1
  table.insert(messages, {
    type = msg_type,
    sender = sender,
    text = text,
    seq = message_seq,
  })

  -- Wrap into the cache at the current width (first render builds it otherwise)
  -- and let the scroller hold a scrolled-back view still.
  if wrapped.width then
    local rows = wrapped_append(messages[#messages], wrapped.width)
    sc.on_append(rows)
  end

  -- Trim buffer if too large
  while #messages > config.max_lines do
    local dead = table.remove(messages, 1)
    wrapped_trim_front(dead)
  end

  return true
end

local function parse_delimited(data, delim)
  local parts = {}
  local start = 1
  delim = delim or "~"
  while true do
    local pos = data:find(delim, start, true)
    if pos then
      table.insert(parts, data:sub(start, pos - 1))
      start = pos + 1
    else
      table.insert(parts, data:sub(start))
      break
    end
  end
  return parts
end

-- Word wrap text to fit within width
-- Returns array of lines
local function word_wrap(text, width)
  if width <= 0 then return { text } end
  if #text <= width then return { text } end

  local lines = {}
  local remaining = text

  while #remaining > 0 do
    if #remaining <= width then
      table.insert(lines, remaining)
      break
    end

    -- Find a good break point (space, hyphen, etc.)
    local break_pos = width
    local found_break = false

    -- Look backwards for a space or break character
    for i = width, 1, -1 do
      local c = remaining:sub(i, i)
      if c == " " or c == "-" or c == "," or c == "." or c == ":" or c == ";" then
        break_pos = i
        found_break = true
        break
      end
    end

    -- If no break found, just break at width
    if not found_break then
      break_pos = width
    end

    local line = remaining:sub(1, break_pos)
    -- Trim trailing space if we broke on a space
    if line:sub(-1) == " " then
      line = line:sub(1, -2)
    end
    table.insert(lines, line)

    -- Skip the break character if it was a space
    if remaining:sub(break_pos, break_pos) == " " then
      remaining = remaining:sub(break_pos + 1)
    else
      remaining = remaining:sub(break_pos + 1)
    end
  end

  return lines
end

function wrapped_reset()
  wrapped.width = nil
  wrapped.lines = {}
  wrapped.first = 1
  wrapped.last = 0
end

-- Wrap one message and append its rows to the cache. Returns the row count,
-- which is also recorded on the message for trim accounting.
function wrapped_append(msg, width)
  local type_cfg = line_types[msg.type] or { color = config.default_color }
  local prefix
  if type_cfg.prefix then
    prefix = type_cfg.prefix(type_cfg, msg.sender)
  else
    prefix = "[" .. (msg.sender or msg.type) .. "] "
  end
  local color_code = get_color(type_cfg.color)
  local lines = word_wrap(prefix .. msg.text, width)
  for j = 1, #lines do
    wrapped.last = wrapped.last + 1
    wrapped.lines[wrapped.last] = {
      text = lines[j],
      color_code = color_code,
      is_continuation = (j > 1),
    }
  end
  msg._rows = #lines
  return #lines
end

function wrapped_ensure(width)
  if wrapped.width == width then return end
  wrapped_reset()
  wrapped.width = width
  for i = 1, #messages do
    wrapped_append(messages[i], width)
  end
  sc.on_trim()  -- re-clamp: row count changed with the width
end

-- Drop the oldest message's rows off the front of the cache.
function wrapped_trim_front(msg)
  if not wrapped.width then return end
  if not msg._rows then
    -- A message the cache never saw (e.g. restored from store mid-session):
    -- the bookkeeping is unknowable, rebuild lazily instead.
    wrapped_reset()
    return
  end
  for i = wrapped.first, wrapped.first + msg._rows - 1 do
    wrapped.lines[i] = nil
  end
  wrapped.first = wrapped.first + msg._rows
  sc.on_trim()
end

--------------------------------------------------------------------------------
-- MIP Handlers
--------------------------------------------------------------------------------

-- BAB - Tells
-- Format: direction~object~text
-- direction: "x" = outgoing, "" = incoming
local function handle_tell(key, code, data)
  local parts = parse_delimited(data)
  local direction = parts[1] or ""
  local person = parts[2] or "Unknown"
  local text = parts[3] or ""

  local msg_type = (direction == "x") and "tell_out" or "tell_in"
  add_message(msg_type, person, text)
end

-- BAG - Emotes/Souls
-- Format: direction~person~text
-- direction: "x" = from afar (incoming?), "" = local
local function handle_emote(key, code, data)
  local parts = parse_delimited(data)
  local direction = parts[1] or ""
  local person = parts[2] or "Unknown"
  local text = parts[3] or ""

  local msg_type = (direction == "x") and "emote_in" or "emote_out"
  add_message(msg_type, person, text)
end

-- CAA - Chat lines
-- Format: command~line_name~sender~text
local function handle_chat(key, code, data)
  local parts = parse_delimited(data)
  local command = parts[1] or "unknown"
  local line_name = parts[2] or "Chat"
  local sender = parts[3] or "Unknown"
  local text = parts[4] or ""

  -- Use command as the type ID (e.g., "gossip", "guildchat")
  local msg_type = "chat_" .. command

  -- Auto-register unknown chat types with a default color
  if not line_types[msg_type] then
    -- Assign colors in rotation for new chat types
    local chat_colors = { "bright_cyan", "bright_green", "bright_yellow", "bright_magenta", "bright_blue" }
    local color_idx = 1
    for k, _ in pairs(line_types) do
      if k:match("^chat_") then
        color_idx = color_idx + 1
      end
    end
    line_types[msg_type] = {
      color = chat_colors[((color_idx - 1) % #chat_colors) + 1],
      enabled = true,
      gags = {},
      label = line_name,
      command = command,
      prefix = function(cfg, who)
        return "[" .. (cfg.label or cfg.command or "Chat") .. "] " .. (who or "") .. ": "
      end,
    }
  end

  add_message(msg_type, sender, text)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

local function default_chat_prefix(cfg, who)
  return "[" .. (cfg.label or cfg.command or "Chat") .. "] " .. (who or "") .. ": "
end

-- Configure any line type (built-in or chat)
-- type_id: "tell_in", "tell_out", "emote_in", "emote_out", or "chat_<command>"
-- opts: { color = "color_name", label = "Display Name", prefix = function, enabled = true/false }
function M.configure(type_id, opts)
  opts = opts or {}
  if not line_types[type_id] then
    return false  -- Type doesn't exist
  end
  if opts.color then line_types[type_id].color = opts.color end
  if opts.label then line_types[type_id].label = opts.label end
  if opts.prefix then line_types[type_id].prefix = opts.prefix end
  if opts.enabled ~= nil then line_types[type_id].enabled = opts.enabled end
  return true
end

-- Add or configure a chat line type (for MIP CAA chat lines)
-- id: unique identifier (e.g., "gossip", "guild", "ooc")
-- opts: { color = "color_name", label = "Display Name", enabled = true/false }
function M.add_chatline(id, opts)
  opts = opts or {}
  local type_id = "chat_" .. id

  if line_types[type_id] then
    -- Update existing
    if opts.color then line_types[type_id].color = opts.color end
    if opts.label then line_types[type_id].label = opts.label end
    if opts.prefix then line_types[type_id].prefix = opts.prefix end
    if opts.enabled ~= nil then line_types[type_id].enabled = opts.enabled end
  else
    -- Create new
    line_types[type_id] = {
      color = opts.color or config.default_color,
      enabled = opts.enabled ~= false,
      gags = {},
      label = opts.label or id,
      prefix = opts.prefix or default_chat_prefix,
      command = id,
    }
  end
end

-- Toggle a line type on/off
-- type_id: "tell_in", "tell_out", "emote_in", "emote_out", or "chat_<command>"
function M.toggle(type_id, enabled)
  if line_types[type_id] then
    if enabled == nil then
      line_types[type_id].enabled = not line_types[type_id].enabled
    else
      line_types[type_id].enabled = enabled
    end
    return line_types[type_id].enabled
  end
  return nil
end

-- Enable a line type
function M.enable(type_id)
  return M.toggle(type_id, true)
end

-- Disable a line type
function M.disable(type_id)
  return M.toggle(type_id, false)
end

-- Check if a line type is enabled
function M.is_enabled(type_id)
  if line_types[type_id] then
    return line_types[type_id].enabled
  end
  return nil
end

-- Set color for a line type
function M.set_color(type_id, color)
  if line_types[type_id] and colors[color] then
    line_types[type_id].color = color
    return true
  end
  return false
end

-- Add a gag pattern to a line type
-- pattern: Lua pattern to match against sender or text
function M.add_gag(type_id, pattern)
  if line_types[type_id] then
    table.insert(line_types[type_id].gags, pattern)
    return true
  end
  return false
end

-- Remove a gag pattern from a line type
function M.remove_gag(type_id, pattern)
  if line_types[type_id] then
    for i, p in ipairs(line_types[type_id].gags) do
      if p == pattern then
        table.remove(line_types[type_id].gags, i)
        return true
      end
    end
  end
  return false
end

-- List all gags for a line type
function M.list_gags(type_id)
  if line_types[type_id] then
    return line_types[type_id].gags
  end
  return {}
end

-- Clear all messages
function M.clear()
  messages = {}
  wrapped_reset()
  sc.scroll_to_bottom()
end

-- Get message count
function M.count()
  return #messages
end

-- Scroll the chat pane by wrapped rows. delta < 0 = up/older.
function M.scroll(delta)
  sc.scroll(delta)
end

function M.scroll_to_bottom()
  sc.scroll_to_bottom()
end

-- True when the pane is showing the newest line.
function M.following_tail()
  return sc.following_tail()
end

-- List all configured line types
function M.list_types()
  local result = {}
  for id, cfg in pairs(line_types) do
    table.insert(result, {
      id = id,
      label = cfg.label or id,
      color = cfg.color,
      enabled = cfg.enabled,
      gag_count = #(cfg.gags or {}),
    })
  end
  table.sort(result, function(a, b) return a.id < b.id end)
  return result
end

-- Get messages (for external rendering)
-- Returns array of { type, sender, text, seq, color }
function M.get_messages(limit)
  limit = limit or #messages
  local result = {}
  local start = math.max(1, #messages - limit + 1)
  local stop = #messages

  for i = start, stop do
    local msg = messages[i]
    if msg then
      local type_cfg = line_types[msg.type] or { color = config.default_color }
      local prefix_text
      if type_cfg.prefix then
        prefix_text = type_cfg.prefix(type_cfg, msg.sender)
      else
        prefix_text = "[" .. (msg.sender or msg.type) .. "] "
      end
      table.insert(result, {
        type = msg.type,
        sender = msg.sender,
        text = msg.text,
        seq = msg.seq,
        color = type_cfg.color,
        color_code = get_color(type_cfg.color),
        prefix = prefix_text,
      })
    end
  end

  return result
end

-- Render the chat monitor in a given rect
-- rect: { x, y, w, h } or rect object with :x(), :y(), :w(), :h() methods
-- opts: { show_border = true, title = "Chat" }
function M.render(rect, opts)
  opts = opts or {}
  local show_border = opts.show_border ~= false
  local title = opts.title or "Chat"

  -- Get rect dimensions
  local x, y, w, h
  if type(rect.x) == "function" then
    x, y, w, h = rect:x(), rect:y(), rect:w(), rect:h()
  else
    x, y, w, h = rect.x, rect.y, rect.w, rect.h
  end

  -- Draw border if requested
  if show_border then
    ui.box(rect, "single", title)
    x, y, w, h = x + 1, y + 1, w - 2, h - 2
  end

  if w <= 0 or h <= 0 then return end

  wrapped_ensure(w)

  local offset = sc.offset()
  for screen_row = h, 1, -1 do
    local idx = wrapped.last - offset - (h - screen_row)
    if idx >= wrapped.first then
      local line = wrapped.lines[idx]
      local line_y = y + screen_row - 1
      local display_text
      if line.is_continuation then
        display_text = line.color_code .. "  " .. line.text .. colors.reset
      else
        display_text = line.color_code .. line.text .. colors.reset
      end
      ui.text_ansi(ui.rect(x, line_y, w, 1), display_text, nil)
    end
  end

  -- Show scroll indicator if not at bottom
  if offset > 0 then
    local indicator = string.format(" [+%d] ", offset)
    ui.text(ui.rect(x + w - #indicator - 1, y + h - 1, #indicator, 1), indicator)
  end
end

-- Set max lines (history size)
function M.set_max_lines(n)
  config.max_lines = n or 32768
  -- Trim existing messages if needed
  while #messages > config.max_lines do
    local dead = table.remove(messages, 1)
    wrapped_trim_front(dead)
  end
end

-- Get max lines setting
function M.get_max_lines()
  return config.max_lines
end

--------------------------------------------------------------------------------
-- Persistence helpers
--------------------------------------------------------------------------------

-- Serialize line type config (only serializable parts, not functions)
local function serialize_line_types()
  local data = {}
  for id, cfg in pairs(line_types) do
    data[id] = {
      color = cfg.color,
      enabled = cfg.enabled,
      gags = cfg.gags or {},
      label = cfg.label,
      command = cfg.command,
    }
  end
  return data
end

-- Restore line type config from saved data
local function restore_line_types(data)
  if not data then return end
  for id, saved in pairs(data) do
    if line_types[id] then
      -- Update existing type
      if saved.color then line_types[id].color = saved.color end
      if saved.enabled ~= nil then line_types[id].enabled = saved.enabled end
      if saved.gags then line_types[id].gags = saved.gags end
      if saved.label then line_types[id].label = saved.label end
    else
      -- Create new chat type (only for chat_* types)
      if id:match("^chat_") then
        line_types[id] = {
          color = saved.color or config.default_color,
          enabled = saved.enabled ~= false,
          gags = saved.gags or {},
          label = saved.label or id:sub(6),  -- Remove "chat_" prefix
          command = saved.command or id:sub(6),
          prefix = default_chat_prefix,
        }
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Plugin lifecycle
--------------------------------------------------------------------------------

function M.on_load()
  -- Load saved data from disk
  store.load()
  local data = store.get()
  if data then
    -- Restore config
    if data.config then
      if data.config.max_lines then config.max_lines = data.config.max_lines end
      if data.config.default_color then config.default_color = data.config.default_color end
    end
    -- Restore line type configurations
    restore_line_types(data.line_types)
    -- Restore message history
    if data.messages then
      messages = data.messages
      message_seq = data.message_seq or #messages
    end
    -- Restored messages carry stale (or absent) _rows bookkeeping; force a
    -- clean rebuild of the wrapped cache on first render.
    wrapped_reset()
  end

  -- Register MIP handlers
  table.insert(mip_handlers, mip.on("BAB", handle_tell))
  table.insert(mip_handlers, mip.on("BAG", handle_emote))
  table.insert(mip_handlers, mip.on("CAA", handle_chat))
end

function M.on_unload()
  -- Unregister MIP handlers
  for _, handler_id in ipairs(mip_handlers) do
    mip.off(handler_id)
  end
  mip_handlers = {}

  -- Save data to disk
  store.set({
    config = {
      max_lines = config.max_lines,
      default_color = config.default_color,
    },
    line_types = serialize_line_types(),
    messages = messages,
    message_seq = message_seq,
  })
  store.save()
end

return M
