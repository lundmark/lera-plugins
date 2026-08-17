-- GMCP State Plugin for Lera
--
-- Subscribes to GMCP packages, tracks the latest state, and formats it for
-- display. Registering a package IS the request: Lera derives Core.Supports.Set
-- from these names, so a server only sends what is listed in PACKAGES.
--
-- Deliberately owns no layout and writes no files. Plugins have no io, so a
-- profile that wants the observation on disk writes M.report() itself:
--
--   local gs = plugin.load("gmcp_state")
--   local f = io.open(path, "w"); f:write(gs.report()); f:close()

local M = {}
M.name = "gmcp_state"
M.version = "1.0"

-- Optional: a profile that never required 'commands' has no registry, and the
-- plugin still works through its function API.
local command
do
  local ok, mod = pcall(require, "command")
  if ok then command = mod end
end

-- Top-level names only. Dispatch is by dot-boundary prefix, so "Char" receives
-- Char.Vitals and everything else under Char.
local PACKAGES = { "Core", "Char", "Room", "Comm" }

local CHANNEL_LIMIT = 200   -- retained channel lines
local FIELD_DEPTH = 3       -- how deep to flatten payloads for field reporting

-- Known current/maximum pairs, drawn as bars. 3K's Char.Vitals is
-- {hp, maxhp, sp, maxsp}; anything else falls through to generic rendering.
local BAR_PAIRS = {
  { label = "hp", current = "hp", maximum = "maxhp" },
  { label = "sp", current = "sp", maximum = "maxsp" },
}

local state
local handler_ids = {}
local command_id

local function blank_state()
  return {
    packages = {},  -- full package names, first-seen order
    counts = {},    -- package -> messages seen
    last = {},      -- package -> latest payload, summarized
    fields = {},    -- package -> { "a.b" -> latest scalar as text }
    vitals = nil,
    room = nil,
    channels = {},  -- newest first
  }
end

state = blank_state()

--------------------------------------------------------------------------------
-- Formatting helpers
--------------------------------------------------------------------------------

local function sorted_keys(map)
  local keys = {}
  for k in pairs(map or {}) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  return keys
end

local function summarize(value, depth)
  depth = depth or 0
  local t = type(value)
  if t ~= "table" then
    if t == "string" then return string.format("%q", value) end
    return tostring(value)
  end
  if depth >= FIELD_DEPTH then return "{...}" end
  local parts, n = {}, 0
  for k, v in pairs(value) do
    n = n + 1
    if n > 12 then
      parts[#parts + 1] = "..."
      break
    end
    parts[#parts + 1] = tostring(k) .. "=" .. summarize(v, depth + 1)
  end
  return "{" .. table.concat(parts, " ") .. "}"
end

-- Flatten into dotted paths, so a report shows which field names a server
-- actually uses -- the thing needed to specialize a display later.
local function record_fields(into, value, prefix, depth)
  if type(value) ~= "table" then
    into[prefix == "" and "(value)" or prefix] = tostring(value)
    return
  end
  if depth > FIELD_DEPTH then return end
  for k, v in pairs(value) do
    local path = prefix == "" and tostring(k) or (prefix .. "." .. tostring(k))
    record_fields(into, v, path, depth + 1)
  end
end

local function ratio_color(ratio)
  if ratio > 0.5 then return "\027[32m" end
  if ratio > 0.25 then return "\027[33m" end
  return "\027[91m"
end

-- "hp [######----] 90/120", never wider than width. Too narrow for a gauge and
-- it degrades to "hp 90/120", then to bare numbers: overflowing would corrupt
-- the pane, which is worse than losing the gauge.
local function bar(label, current, maximum, width)
  local cur = math.max(0, math.floor(tonumber(current) or 0))
  local max = math.floor(tonumber(maximum) or 0)
  local ratio = 0
  if max > 0 then
    if cur > max then cur = max end
    ratio = cur / max
  end

  local numbers = string.format("%d/%d", cur, max > 0 and max or 0)
  local prefix = label .. " "
  local gauge_width = width - #prefix - 3 - #numbers   -- "[" + gauge + "] "
  if gauge_width >= 1 then
    local filled = math.floor(ratio * gauge_width)
    return prefix .. "[" .. string.rep("#", filled)
                  .. string.rep("-", gauge_width - filled) .. "] " .. numbers
  end

  local compact = prefix .. numbers
  if #compact <= width then return compact end
  return numbers:sub(1, math.max(0, width))
end

-- Generic rendering, pairing a value with its maximum when the names make the
-- relationship obvious (hp/maxhp, sp/sp_max). skip omits what bars already drew.
local function generic_parts(map, skip)
  if type(map) ~= "table" then return {} end
  local keys = sorted_keys(map)
  local used, parts = {}, {}
  for key in pairs(skip or {}) do used[tostring(key)] = true end

  for _, key in ipairs(keys) do
    if not used[key] and type(map[key]) ~= "table" then
      local lower = key:lower()
      local max_key
      for _, candidate in ipairs({ "max" .. lower, lower .. "_max", lower .. "max" }) do
        for _, other in ipairs(keys) do
          if other ~= key and not used[other] and other:lower() == candidate then
            max_key = other
            break
          end
        end
        if max_key then break end
      end

      used[key] = true
      if max_key then
        used[max_key] = true
        parts[#parts + 1] = key .. " " .. tostring(map[key]) .. "/" .. tostring(map[max_key])
      else
        parts[#parts + 1] = key .. "=" .. tostring(map[key])
      end
    end
  end
  return parts
end

local function wrap(parts, width, max_lines)
  local lines, current = {}, ""
  for _, part in ipairs(parts) do
    local candidate = current == "" and part or (current .. "  " .. part)
    if #candidate <= width then
      current = candidate
    else
      if current ~= "" then lines[#lines + 1] = current end
      if #lines >= max_lines then return lines end
      current = part:sub(1, width)
    end
  end
  if current ~= "" and #lines < max_lines then lines[#lines + 1] = current end
  return lines
end

--------------------------------------------------------------------------------
-- Recording
--------------------------------------------------------------------------------

local function note_channel(data)
  if type(data) ~= "table" then return end
  table.insert(state.channels, 1, {
    channel = data.channel and tostring(data.channel) or "",
    talker = data.talker and tostring(data.talker) or "",
    text = data.text and tostring(data.text) or "",
  })
  while #state.channels > CHANNEL_LIMIT do
    table.remove(state.channels)
  end
end

local function record(pkg, data)
  pkg = tostring(pkg or "")
  if not state.counts[pkg] then
    state.packages[#state.packages + 1] = pkg
    state.fields[pkg] = {}
  end
  state.counts[pkg] = (state.counts[pkg] or 0) + 1
  state.last[pkg] = summarize(data)
  if data ~= nil then record_fields(state.fields[pkg], data, "", 0) end

  local lower = pkg:lower()
  if lower == "char.vitals" then
    if type(data) == "table" then state.vitals = data end
  elseif lower == "room.info" then
    if type(data) == "table" then state.room = data end
  elseif lower:find("^comm%.channel") then
    note_channel(data)
  end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function M.vitals() return state.vitals end
function M.room() return state.room end

-- Newest first. limit caps how many are returned.
function M.channels(limit)
  local n = tonumber(limit) or #state.channels
  if n < 0 then n = 0 end
  local out = {}
  for i = 1, math.min(n, #state.channels) do out[i] = state.channels[i] end
  return out
end

function M.stats()
  local fields = {}
  for pkg, map in pairs(state.fields) do fields[pkg] = sorted_keys(map) end
  local packages, counts, last = {}, {}, {}
  for i, pkg in ipairs(state.packages) do packages[i] = pkg end
  for pkg, n in pairs(state.counts) do counts[pkg] = n end
  for pkg, text in pairs(state.last) do last[pkg] = text end
  return { packages = packages, counts = counts, last = last, fields = fields }
end

-- Rows of { text, color } for a pane of the given width. Empty when nothing has
-- arrived, so a pane shows nothing rather than an empty labelled block.
function M.vitals_lines(width, max_lines)
  local v = state.vitals
  if type(v) ~= "table" then return {} end
  width = math.max(1, math.floor(tonumber(width) or 1))
  max_lines = math.floor(tonumber(max_lines) or 0)

  local rows, used = {}, {}
  for _, pair in ipairs(BAR_PAIRS) do
    if v[pair.current] ~= nil and v[pair.maximum] ~= nil and #rows < max_lines then
      used[pair.current], used[pair.maximum] = true, true
      local c = tonumber(v[pair.current]) or 0
      local m = tonumber(v[pair.maximum]) or 0
      local ratio = 0
      if m > 0 then ratio = math.min(1, math.max(0, c / m)) end
      rows[#rows + 1] = {
        text = bar(pair.label, c, m, width),
        color = ratio_color(ratio),
      }
    end
  end

  local leftover = generic_parts(v, used)
  if #leftover > 0 and #rows < max_lines then
    for _, line in ipairs(wrap(leftover, width, max_lines - #rows)) do
      rows[#rows + 1] = { text = line }
    end
  end
  return rows
end

-- Plain text for a profile to print or write to a file.
function M.report()
  local out = {}
  out[#out + 1] = "-- GMCP state --"
  out[#out + 1] = "gmcp.enabled = " .. tostring(gmcp.enabled())
  out[#out + 1] = "gmcp.trace   = " .. tostring(gmcp.trace())
  out[#out + 1] = string.format("packages seen: %d", #state.packages)
  if #state.packages == 0 then
    out[#out + 1] = "(no GMCP messages received)"
  end
  for _, pkg in ipairs(state.packages) do
    out[#out + 1] = string.format("%s  x%d", pkg, state.counts[pkg] or 0)
    out[#out + 1] = "  last: " .. tostring(state.last[pkg] or "")
    for _, key in ipairs(sorted_keys(state.fields[pkg])) do
      out[#out + 1] = string.format("  %s = %s", key, state.fields[pkg][key])
    end
  end
  if #state.channels > 0 then
    out[#out + 1] = string.format("-- channels (%d retained, newest first) --",
                                  #state.channels)
    for i, entry in ipairs(state.channels) do
      out[#out + 1] = string.format("%3d [%s] %s: %s",
                                    i, entry.channel, entry.talker, entry.text)
    end
  end
  return table.concat(out, "\n")
end

-- Diagnostic passthrough: print every GMCP message in and out.
function M.trace(on)
  if on == nil then return gmcp.trace() end
  return gmcp.trace(on and true or false)
end

function M.reset()
  state = blank_state()
end

function M.packages()
  local out = {}
  for i, pkg in ipairs(PACKAGES) do out[i] = pkg end
  return out
end

--------------------------------------------------------------------------------
-- Status output
--------------------------------------------------------------------------------

local function print_status()
  buffer.color_print(nil, 3, "-- GMCP --")
  buffer.color_print(nil, nil, "enabled = " .. tostring(gmcp.enabled())
                     .. "   trace = " .. tostring(gmcp.trace()))
  if #state.packages == 0 then
    buffer.color_print(nil, 1, "  no GMCP messages received yet")
    return
  end
  for _, pkg in ipairs(state.packages) do
    buffer.color_print(nil, 2, "  " .. pkg,
                       nil, nil, string.format("  x%d  %s",
                                               state.counts[pkg] or 0,
                                               state.last[pkg] or ""))
    local keys = sorted_keys(state.fields[pkg])
    if #keys > 0 then
      buffer.color_print(nil, 6, "      fields: ", nil, nil, table.concat(keys, ", "))
    end
  end
  if #state.channels > 0 then
    buffer.color_print(nil, 6, string.format("  channels retained: %d", #state.channels))
  end
end

--------------------------------------------------------------------------------
-- Hooks
--------------------------------------------------------------------------------

function M.on_load()
  for _, package in ipairs(PACKAGES) do
    local id = gmcp.on(package, function(pkg, data) record(pkg, data) end)
    if id then handler_ids[#handler_ids + 1] = id end
  end

  if not command then return end
  local id, err = command.register({
    name = "/gmcp",
    usage = "/gmcp [trace]",
    summary = "Show GMCP state, or toggle GMCP tracing",
    description = "Reports whether GMCP negotiated, which packages have "
      .. "arrived with their field names, and how many channel lines are "
      .. "retained. 'trace' toggles printing every GMCP message in and out.",
    accepts_args = true,
    handler = function(args)
      if args and args:match("^%s*trace%s*$") then
        buffer.color_print(nil, 3, "gmcp trace = " .. tostring(M.trace(not gmcp.trace())))
        return
      end
      print_status()
    end,
  })
  if id then
    command_id = id
  else
    print("[gmcp_state] command registration failed: " .. tostring(err))
  end
end

function M.on_unload()
  for _, id in ipairs(handler_ids) do pcall(gmcp.remove, id) end
  handler_ids = {}
  -- The loader drops a plugin's commands on unload; unregistering here keeps a
  -- manual reload from colliding with its own leftover record.
  if command and command_id then
    pcall(command.unregister, command_id)
    command_id = nil
  end
end

function M.on_disconnect()
  -- Registrations survive a disconnect (Lera keeps them, and the handshake
  -- re-runs), but the observed values belong to the session that ended.
  state.vitals = nil
  state.room = nil
end

return M
