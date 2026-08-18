-- Chat Monitor Plugin for Lera
-- Captures chat events (tells, emotes, chat lines) and displays them in a
-- separate panel with color coding and gag support.
--
-- Two protocols can carry channel lines. MIP CAA is the historical source;
-- GMCP Comm.Channel.Text is preferred when the server proves it is sending it,
-- because 3K sends the same line over both and printing both would double
-- every message. See the "Source selection" section below.

local M = {}
M.name = "chat_monitor"
M.version = "1.2"
M.priority = 50  -- Run before most plugins

local wm = require("wm")

-- Configuration
local config = {
  max_lines = 32768,      -- Max lines to keep in scrollback (32k default)
  default_color = "white",
  timestamps = true,      -- Prepend a timestamp to every message
  timestamp_format = "%H:%M",
  timestamp_color = "white",
}

-- Default prefix function for built-in types
local function default_tell_prefix(cfg, who)
  return "[" .. (who or "???") .. "] "
end

local function default_emote_prefix(cfg, who)
  return "* " .. (who or "???") .. " "
end

-- MIP CAA text already contains the formatted line ("Simon <Wiz>: hi"), so
-- chat lines get no prefix of their own; use configure() to opt back in.
local function default_chat_prefix(cfg, who)
  return ""
end

-- The three prefixes above are defaults, not user intent. A prefix installed
-- through configure() is, which is why the two are told apart when deciding
-- what a line's lead-in should be.
local BUILTIN_PREFIXES = {
  [default_tell_prefix] = true,
  [default_emote_prefix] = true,
  [default_chat_prefix] = true,
}

-- GMCP channels that map onto the built-in directional types, so an incoming
-- tell keeps its colour, its gags and the "tells" push channel whichever
-- protocol delivered it. Requires the server to say which way it went:
-- Comm.Channel.Text has no direction of its own, and targets only reveals it to
-- a client that knows its own character name.
local DIRECTED_CHANNELS = {
  tell = { ["in"] = "tell_in", out = "tell_out" },
  soul = { ["in"] = "emote_in", out = "emote_out" },
}

-- Channels whose text reads as a continuation of the speaker's name ("smiles at
-- you.") rather than something quoted after a colon. Pure guesswork about
-- server-side channel semantics, and superseded the moment the server sends its
-- own prefix field -- see gmcp_prefix() below.
local SPACE_JOINED_CHANNELS = {
  soul = true, souls = true, emote = true, emotes = true,
}

-- GMCP Comm.Channel.Text carries the body alone, with the speaker, the channel
-- and any targets in separate fields, so the text on its own loses all of that.
-- The server may send the finished lead-in as a "prefix" field; when it does it
-- is used verbatim, because only the server knows how it phrases a tell, a soul
-- or a multi-target tell. This is the fallback for when it does not.
local function gmcp_prefix(channel, talker, targets)
  if not talker or talker == "" then return "" end
  if SPACE_JOINED_CHANNELS[channel] then return talker .. " " end

  -- A multi-target tell names its recipients; without them "Simon: test" gives
  -- no hint that it went to anyone in particular.
  if type(targets) == "table" and #targets > 0 then
    local named = {}
    for _, name in ipairs(targets) do
      if type(name) == "string" and name ~= "" and name ~= talker then
        named[#named + 1] = name
      end
    end
    if #named > 0 then
      return talker .. " -> " .. table.concat(named, ", ") .. ": "
    end
  end

  return talker .. ": "
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

-- Protocol handler refs for cleanup
local mip_handlers = {}
local gmcp_handlers = {}
local command_id = nil

-- require("command") is optional: a profile that never required 'commands' has
-- no registry, and the chat pane still works.
local command
do
  local ok, mod = pcall(require, "command")
  if ok then command = mod end
end

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

--------------------------------------------------------------------------------
-- Source selection
--------------------------------------------------------------------------------
--
-- mode is the user's preference and persists; channels is which protocol is
-- actually feeding channel lines right now and resets on every disconnect.
--
-- In "auto", channel lines come from MIP until GMCP delivers one, then GMCP
-- owns them for the rest of the connection. That ordering is deliberate: a
-- server can negotiate GMCP and never send Comm.Channel.Text, and latching the
-- other way round would leave the pane empty with no fallback.
--
-- The latch covers every kind of chat line, because Comm.Channel.Text carries
-- all of them -- channels, tells (channel "tell") and souls (channel "soul").
-- An earlier version latched channels only and left MIP BAB/BAG always on,
-- which double-printed every tell and soul once GMCP took over.
local source = {
  mode = "auto",        -- "auto" | "mip" | "gmcp"
  active = "mip",       -- "mip" | "gmcp": which protocol feeds every chat line
  mip_count = 0,
  gmcp_count = 0,
  gmcp_unmapped = 0,
  last_unmapped = nil,  -- { package = "Comm.Channel.List", fields = "channels" }
}

local function mip_allowed()
  if source.mode == "gmcp" then return false end
  if source.mode == "mip" then return true end
  return source.active ~= "gmcp"
end

local function gmcp_allowed()
  return source.mode ~= "mip"
end

-- Reported by /chat source, and the answer to "is GMCP actually arriving?".
local function source_status()
  local qualifier
  if source.mode == "auto" then
    qualifier = (source.active == "gmcp") and "auto; latched" or
                "auto; no GMCP chat seen yet"
  else
    qualifier = "pinned"
  end
  return {
    mode = source.mode,
    active = source.active,
    channels = source.active,  -- kept: earlier name for the same value
    qualifier = qualifier,
    mip_count = source.mip_count,
    gmcp_count = source.gmcp_count,
    gmcp_unmapped = source.gmcp_unmapped,
    last_unmapped = source.last_unmapped and {
      package = source.last_unmapped.package,
      fields = source.last_unmapped.fields,
    } or nil,
  }
end

local function get_color(color_name)
  return colors[color_name] or colors.white
end

-- push_notify sink, resolved in on_setup (nil when push_notify isn't loaded)
local pushn

-- One prefix rule for both the pane and the push_notify forward.
--
-- A prefix set through configure() always wins: the user asked for it. Failing
-- that, a structured (GMCP) message uses the lead-in worked out at intake and
-- stored on the record, since its text carries no speaker of its own. MIP text
-- is already a formatted line, which is why the default is empty.
local function resolve_prefix(type_cfg, msg)
  -- A lead-in the server sent with this message wins outright. A configured
  -- prefix cannot know whether the body already carries its own attribution,
  -- and the same setting has to serve both protocols: an empty emote prefix is
  -- right for MIP text that reads "Simon smiles at you." and wrong for a GMCP
  -- body of "smiles at you.".
  if msg.prefix_from_server and type(msg.prefix) == "string" then
    return msg.prefix
  end

  local prefix_fn = type_cfg.prefix
  if prefix_fn and not BUILTIN_PREFIXES[prefix_fn] then
    return prefix_fn(type_cfg, msg.sender)
  end
  if type(msg.prefix) == "string" then return msg.prefix end
  if prefix_fn then return prefix_fn(type_cfg, msg.sender) end
  return "[" .. (msg.sender or msg.type) .. "] "
end

local function add_message(msg_type, sender, text, opts)
  local structured = opts and opts.structured or false
  local prefix_text = opts and opts.prefix or nil
  local prefix_from_server = opts and opts.prefix_from_server or false
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

  -- Forward to push_notify: incoming tells/emotes and chat lines, never our
  -- own outgoing messages. push_notify applies its own per-channel gating.
  if pushn then
    local channel
    if msg_type == "tell_in" then
      channel = "tells"
    elseif msg_type == "emote_in" then
      channel = "emotes"
    else
      channel = msg_type:match("^chat_(.+)")
    end
    if channel then
      local prefix = resolve_prefix(type_cfg, {
        type = msg_type, sender = sender, structured = structured,
        prefix = prefix_text, prefix_from_server = prefix_from_server,
      })
      pushn.notify(channel, prefix .. text)
    end
  end

  -- Add to buffer
  message_seq = message_seq + 1
  table.insert(messages, {
    type = msg_type,
    sender = sender,
    text = text,
    seq = message_seq,
    time = os.time(),
    -- Persisted: a restored GMCP line must keep rendering its lead-in.
    structured = structured or nil,
    prefix = prefix_text,
    prefix_from_server = prefix_from_server or nil,
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

-- Format + word-wrap one message at a given width. Shared by the local cache
-- builder (wrapped_append) and the transient remote-pass builder below, so
-- prefix/color formatting can't drift between the two.
local function wrap_msg(msg, width)
  local type_cfg = line_types[msg.type] or { color = config.default_color }
  local prefix = resolve_prefix(type_cfg, msg)
  local stamp = ""
  if config.timestamps and msg.time then
    stamp = "[" .. os.date(config.timestamp_format, msg.time) .. "] "
  end
  local color_code = get_color(type_cfg.color)
  local lines = word_wrap(stamp .. prefix .. msg.text, width)
  -- Colorize the stamp after wrapping so escape codes never enter the width
  -- math; skipped when the first line is narrower than the stamp itself.
  if #stamp > 0 and #lines[1] >= #stamp then
    lines[1] = get_color(config.timestamp_color) .. lines[1]:sub(1, #stamp)
               .. color_code .. lines[1]:sub(#stamp + 1)
  end
  return color_code, lines
end

-- Wrap one message and append its rows to the cache. Returns the row count,
-- which is also recorded on the message for trim accounting.
function wrapped_append(msg, width)
  local color_code, lines = wrap_msg(msg, width)
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
  if not mip_allowed() then return end
  source.mip_count = source.mip_count + 1
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
  if not mip_allowed() then return end
  source.mip_count = source.mip_count + 1
  local parts = parse_delimited(data)
  local direction = parts[1] or ""
  local person = parts[2] or "Unknown"
  local text = parts[3] or ""

  local msg_type = (direction == "x") and "emote_in" or "emote_out"
  add_message(msg_type, person, text)
end

-- Colors assigned in rotation to newly discovered chat types.
local CHAT_COLORS = { "bright_cyan", "bright_green", "bright_yellow", "bright_magenta", "bright_blue" }

-- Both protocols name the same channel the same way ("wiz"), so both land on
-- the same type ID and a channel keeps its color, label and gags when the
-- source flips. Shared so the two intake paths cannot drift apart.
local function ensure_chat_type(command, label)
  local msg_type = "chat_" .. command
  if line_types[msg_type] then return msg_type end

  local color_idx = 1
  for k, _ in pairs(line_types) do
    if k:match("^chat_") then
      color_idx = color_idx + 1
    end
  end
  line_types[msg_type] = {
    color = CHAT_COLORS[((color_idx - 1) % #CHAT_COLORS) + 1],
    enabled = true,
    gags = {},
    label = label or command,
    command = command,
    prefix = default_chat_prefix,
  }
  return msg_type
end

-- CAA - Chat lines
-- Format: command~line_name~sender~text
local function handle_chat(key, code, data)
  if not mip_allowed() then return end
  source.mip_count = source.mip_count + 1

  local parts = parse_delimited(data)
  local command = parts[1] or "unknown"
  local line_name = parts[2] or "Chat"
  local sender = parts[3] or "Unknown"
  local text = parts[4] or ""

  -- Use command as the type ID (e.g., "gossip", "guildchat")
  add_message(ensure_chat_type(command, line_name), sender, text)
end

-- Anything under Comm that is not a channel line we can read. Counted and
-- described rather than printed, so "GMCP is silent" stays distinguishable
-- from "GMCP is arriving in a shape this does not understand".
local function note_unmapped(package, data)
  source.gmcp_unmapped = source.gmcp_unmapped + 1

  local fields = {}
  if type(data) == "table" then
    for k, _ in pairs(data) do fields[#fields + 1] = tostring(k) end
    table.sort(fields)
  end
  source.last_unmapped = {
    package = package,
    fields = (#fields > 0) and table.concat(fields, ", ") or "(none)",
  }
end

-- GMCP Comm.Channel.Text, as 3K sends it:
--   { "channel": "wiz", "talker": "Simon", "text": "test" }
-- The channel name is used exactly as sent.
local function handle_gmcp_comm(package, data)
  if not gmcp_allowed() then return end
  if tostring(package):lower() ~= "comm.channel.text" then
    return note_unmapped(package, data)
  end
  if type(data) ~= "table" then
    return note_unmapped(package, data)
  end

  local channel, text = data.channel, data.text
  if type(channel) ~= "string" or channel == "" or type(text) ~= "string" then
    return note_unmapped(package, data)
  end
  local talker = (type(data.talker) == "string" and data.talker ~= "") and data.talker or nil

  -- The server's own lead-in, when it sends one, beats anything reconstructed
  -- here: it knows how it phrases "You tell X, Y:" against "X tells you:".
  local prefix, from_server = data.prefix, true
  if type(prefix) ~= "string" then
    prefix, from_server = gmcp_prefix(channel, talker, data.targets), false
  end

  -- A directed channel lands on the matching built-in type, but only when the
  -- server says which direction it went; without that it stays an ordinary
  -- chat_<channel> type rather than being guessed into the wrong one.
  local msg_type
  local directed = DIRECTED_CHANNELS[channel:lower()]
  local direction = type(data.direction) == "string" and data.direction:lower() or nil
  if directed and direction and directed[direction] then
    msg_type = directed[direction]
  else
    msg_type = ensure_chat_type(channel, channel)
  end

  source.gmcp_count = source.gmcp_count + 1
  -- The latch: a real chat line is what promotes GMCP, not negotiation.
  if source.mode == "auto" then source.active = "gmcp" end

  add_message(msg_type, talker, text,
              { structured = true, prefix = prefix, prefix_from_server = from_server })
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

local function formatting_options_changed(opts)
  return opts.color ~= nil or opts.label ~= nil or opts.prefix ~= nil
end

local function invalidate_wrapped_formatting()
  wrapped.width = nil
end

-- Configure any line type (built-in or chat)
-- type_id: "tell_in", "tell_out", "emote_in", "emote_out", or "chat_<command>"
-- opts: { color = "color_name", label = "Display Name", prefix = function, enabled = true/false }
-- Source control. "auto" latches to GMCP once it delivers a channel line,
-- "mip" and "gmcp" pin it. Returns true, or false plus a reason.
function M.set_source(mode)
  if mode ~= "auto" and mode ~= "mip" and mode ~= "gmcp" then
    return false, "source must be auto, mip or gmcp"
  end
  source.mode = mode
  if mode == "mip" then
    source.active = "mip"
  elseif mode == "gmcp" then
    source.active = "gmcp"
  else
    -- Back to latching: GMCP has to prove itself again this connection.
    source.active = (source.gmcp_count > 0) and "gmcp" or "mip"
  end
  return true
end

-- Snapshot of which protocol is feeding the pane and what each has delivered.
function M.source()
  return source_status()
end

function M.configure(type_id, opts)
  opts = opts or {}
  if not line_types[type_id] then
    return false  -- Type doesn't exist
  end
  if opts.color then line_types[type_id].color = opts.color end
  if opts.label then line_types[type_id].label = opts.label end
  if opts.prefix then line_types[type_id].prefix = opts.prefix end
  if opts.enabled ~= nil then line_types[type_id].enabled = opts.enabled end
  if formatting_options_changed(opts) then invalidate_wrapped_formatting() end
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
    if formatting_options_changed(opts) then invalidate_wrapped_formatting() end
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
    invalidate_wrapped_formatting()
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
        time = msg.time,
        color = type_cfg.color,
        color_code = get_color(type_cfg.color),
        prefix = prefix_text,
      })
    end
  end

  return result
end

-- Draw one already-wrapped row (or nothing, if line is nil) at screen row y.
-- Shared by the local (cached) and remote (transient) render paths so the
-- ANSI/indicator formatting can't drift between them.
local function draw_row(x, y, w, line)
  if not line then return end
  local display_text
  if line.is_continuation then
    display_text = line.color_code .. "  " .. line.text .. colors.reset
  else
    display_text = line.color_code .. line.text .. colors.reset
  end
  ui.text_ansi(ui.rect(x, y, w, 1), display_text, nil)
end

-- Paint h rows bottom-up. get_row(screen_row) returns the wrapped-line entry
-- (or nil) for that screen row; screen_row runs h..1 (h = bottom row).
local function draw_rows(x, y, w, h, get_row)
  for screen_row = h, 1, -1 do
    draw_row(x, y + screen_row - 1, w, get_row(screen_row))
  end
end

-- Build a disposable (non-cached) wrapped-line list at `width`, newest rows
-- first, stopping once `need_rows` rows are collected. This mirrors the
-- pre-cache render's early-exit shape and exists so the WebSocket remote
-- render pass (which can run at a different width than the local screen)
-- never touches the local `wrapped` cache or `sc` scroller state.
local function build_transient(width, need_rows)
  local list = {}
  for i = #messages, 1, -1 do
    local color_code, lines = wrap_msg(messages[i], width)
    for j = #lines, 1, -1 do
      list[#list + 1] = {
        text = lines[j],
        color_code = color_code,
        is_continuation = (j > 1),
      }
      if #list >= need_rows then return list end
    end
  end
  return list
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

  local offset

  if lera.render_pass() == "remote" then
    offset = sc.offset()
    -- The render callback runs a second time per dirty frame when a
    -- WebSocket client is connected, at the CLIENT screen's width. Mutating
    -- the local cache/scroller from here would thrash the width-keyed
    -- wrapped cache and re-clamp the LOCAL user's scroll offset against the
    -- REMOTE row count, silently yanking a scrolled-back local view. So:
    -- build a throwaway wrapped list at the remote width instead, and
    -- render it through the untouched local offset. The remote viewer sees
    -- approximately the local scroll position, per spec.
    local list = build_transient(w, h + offset)
    draw_rows(x, y, w, h, function(screen_row)
      return list[1 + offset + (h - screen_row)]
    end)
  else
    wrapped_ensure(w)
    offset = sc.offset()
    draw_rows(x, y, w, h, function(screen_row)
      local idx = wrapped.last - offset - (h - screen_row)
      if idx >= wrapped.first then return wrapped.lines[idx] end
      return nil
    end)
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

-- Toggle timestamps on every message; format is an os.date() format string
-- (default "%H:%M"), color a name from the color table (default "white").
-- Returns the new enabled state.
function M.set_timestamps(enabled, format, color)
  config.timestamps = enabled and true or false
  if format then config.timestamp_format = format end
  if color and colors[color] then config.timestamp_color = color end
  invalidate_wrapped_formatting()
  return config.timestamps
end

-- Returns enabled, format, color
function M.timestamps()
  return config.timestamps, config.timestamp_format, config.timestamp_color
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

--------------------------------------------------------------------------------
-- Command
--------------------------------------------------------------------------------

local function print_source()
  local st = source_status()
  print("[chat] source: " .. st.active .. " (" .. st.qualifier .. ")")
  print("[chat] mip: " .. st.mip_count .. " messages    gmcp: " ..
        st.gmcp_count .. " mapped, " .. st.gmcp_unmapped .. " unmapped")
  if st.last_unmapped then
    print("[chat] last unmapped: " .. st.last_unmapped.package ..
          " (fields: " .. st.last_unmapped.fields .. ")")
  end
end

local function chat_help()
  print("Chat monitor commands:")
  print("  /chat source [mip|gmcp|auto] - Show or pin the channel source")
  print("  /chat types           - List all chat line types")
  print("  /chat toggle <type>   - Toggle a line type on/off")
  print("  /chat enable <type>   - Enable a line type")
  print("  /chat disable <type>  - Disable a line type")
  print("  /chat color <type> <color> - Set color for a type")
  print("  /chat gag <type> <pattern> - Add a gag pattern")
  print("  /chat ungag <type> <pattern> - Remove a gag pattern")
  print("  /chat gags <type>     - List gags for a type")
  print("  /chat clear           - Clear all chat messages")
  print("")
  print("Colors: black, red, green, yellow, blue, magenta, cyan, white")
  print("        bright_black, bright_red, bright_green, etc.")
end

local function chat_command(args)
  local parts = {}
  for word in tostring(args or ""):gmatch("%S+") do parts[#parts + 1] = word end
  local subcmd = (parts[1] or ""):lower()

  if subcmd == "" or subcmd == "help" then
    chat_help()
  elseif subcmd == "source" then
    if parts[2] then
      local ok, err = M.set_source(parts[2]:lower())
      if not ok then
        print("[chat] " .. err)
        return
      end
    end
    print_source()
  elseif subcmd == "types" then
    local types = M.list_types()
    print("Chat line types:")
    for _, item in ipairs(types) do
      local status = item.enabled and "ON" or "OFF"
      local gags = item.gag_count > 0 and (" [" .. item.gag_count .. " gags]") or ""
      print(string.format("  %-15s %-12s %s (%s)%s",
        item.id, item.color, status, item.label, gags))
    end
  elseif subcmd == "toggle" then
    local type_id = parts[2]
    if not type_id then return print("Usage: /chat toggle <type>") end
    local enabled = M.toggle(type_id)
    if enabled ~= nil then
      print(type_id .. " is now " .. (enabled and "enabled" or "disabled"))
    else
      print("Unknown type: " .. type_id)
    end
  elseif subcmd == "enable" then
    local type_id = parts[2]
    if not type_id then return print("Usage: /chat enable <type>") end
    print(M.enable(type_id) and (type_id .. " enabled") or ("Unknown type: " .. type_id))
  elseif subcmd == "disable" then
    local type_id = parts[2]
    if not type_id then return print("Usage: /chat disable <type>") end
    print(M.disable(type_id) and (type_id .. " disabled") or ("Unknown type: " .. type_id))
  elseif subcmd == "color" then
    local type_id, color = parts[2], parts[3]
    if not type_id or not color then return print("Usage: /chat color <type> <color>") end
    if M.set_color(type_id, color) then
      print(type_id .. " color set to " .. color)
    else
      print("Failed - unknown type or invalid color")
    end
  elseif subcmd == "gag" then
    local type_id, pattern = parts[2], parts[3]
    if not type_id or not pattern then return print("Usage: /chat gag <type> <pattern>") end
    if M.add_gag(type_id, pattern) then
      print("Added gag '" .. pattern .. "' to " .. type_id)
    else
      print("Unknown type: " .. type_id)
    end
  elseif subcmd == "ungag" then
    local type_id, pattern = parts[2], parts[3]
    if not type_id or not pattern then return print("Usage: /chat ungag <type> <pattern>") end
    print(M.remove_gag(type_id, pattern)
      and ("Removed gag '" .. pattern .. "' from " .. type_id) or "Gag not found")
  elseif subcmd == "gags" then
    local type_id = parts[2]
    if not type_id then return print("Usage: /chat gags <type>") end
    local gags = M.list_gags(type_id)
    if #gags == 0 then
      print("No gags for " .. type_id)
    else
      print("Gags for " .. type_id .. ":")
      for index, gag in ipairs(gags) do print("  " .. index .. ". " .. gag) end
    end
  elseif subcmd == "clear" then
    M.clear()
    print("Chat cleared")
  else
    print("Unknown subcommand: " .. subcmd)
    print("Type /chat help for usage")
  end
end

-- Hosted mode registers its own /chat (scripts/hosted/commands.lua) before any
-- plugin loads, and a plugin cannot replace a profile-owned command. Claiming
-- it only when it is free gives local profiles the same interface without
-- fighting hosted for the name.
local function register_command()
  if not command then return end
  if command.get("/chat") then return end

  local id, err = command.register({
    name = "/chat",
    usage = "/chat <subcommand>",
    summary = "Manage the chat monitor",
    description = "List and configure chat types, colors, gags and messages, "
      .. "and choose whether channel lines come from MIP or GMCP.",
    accepts_args = true,
    handler = chat_command,
  })
  if id then
    command_id = id
  else
    print("[chat_monitor] command registration failed: " .. tostring(err))
  end
end

function M.on_load()
  -- Load saved data from disk
  store.load()
  local data = store.get()
  if data then
    -- Restore config
    if data.config then
      if data.config.max_lines then config.max_lines = data.config.max_lines end
      if data.config.default_color then config.default_color = data.config.default_color end
      if data.config.timestamps ~= nil then config.timestamps = data.config.timestamps end
      if data.config.timestamp_format then config.timestamp_format = data.config.timestamp_format end
      if data.config.timestamp_color then config.timestamp_color = data.config.timestamp_color end
      -- The preference persists; the latch does not (it is per connection).
      local mode = data.config.source_mode
      if mode == "auto" or mode == "mip" or mode == "gmcp" then
        source.mode = mode
        source.active = (mode == "gmcp") and "gmcp" or "mip"
      end
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

  -- One GMCP subscription: dot-boundary matching delivers everything under
  -- Comm, so Comm.Channel.Text arrives here along with anything else the
  -- server sends under that package.
  local gmcp_id = gmcp.on("Comm", handle_gmcp_comm)
  if gmcp_id then table.insert(gmcp_handlers, gmcp_id) end

  register_command()
end

-- The latch belongs to a connection: a reconnect (or a different server) must
-- re-prove GMCP rather than inherit the last session's answer. The counters
-- describe the session too, so they reset with it.
function M.on_disconnect()
  if source.mode == "auto" then source.active = "mip" end
  source.mip_count = 0
  source.gmcp_count = 0
  source.gmcp_unmapped = 0
  source.last_unmapped = nil
end

function M.on_setup()
  pushn = plugin.get("push_notify")
  if pushn and pushn.register_channel then
    pushn.register_channel("tells", { priority = 1 })
  end
end

function M.on_unload()
  -- Unregister protocol handlers
  for _, handler_id in ipairs(mip_handlers) do
    mip.off(handler_id)
  end
  mip_handlers = {}

  for _, handler_id in ipairs(gmcp_handlers) do
    pcall(gmcp.remove, handler_id)
  end
  gmcp_handlers = {}

  -- The loader drops a plugin's commands on unload; unregistering here keeps a
  -- manual reload from colliding with its own leftover record.
  if command and command_id then
    pcall(command.unregister, command_id)
    command_id = nil
  end

  -- Save data to disk
  store.set({
    config = {
      max_lines = config.max_lines,
      default_color = config.default_color,
      timestamps = config.timestamps,
      timestamp_format = config.timestamp_format,
      timestamp_color = config.timestamp_color,
      source_mode = source.mode,
    },
    line_types = serialize_line_types(),
    messages = messages,
    message_seq = message_seq,
  })
  store.save()
end

return M
