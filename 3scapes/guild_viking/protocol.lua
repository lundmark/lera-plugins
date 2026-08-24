-- Transport-agnostic ingestion. Adapters (MIP BBE today, GMCP later) reduce
-- their wire format to ingest(key, value); the parsers never know the source.
local util = require("util")

local protocol = {}

local handlers = {}
local pattern_handlers = {}  -- ordered list: { {pattern=p, fn=fn}, ... }
local batches, batch_totals, batch_ts = {}, {}, {}
local stats = { ingested = 0, unknown = {}, errors = {}, suppressed = 0 }
local reported_errors = {}
local source_mode = "auto"   -- "mip" | "gmcp" | "auto"
local gmcp_latched = false
local trace_on = false   -- diagnostic: /vik trace -- off by default, silent otherwise

-- GMCP-side writers, keyed by MIP key. Registered from a handler module's
-- `_gmcp` table, so one key's two transports are declared next to each other.
local gmcp_handlers = {}

-- Reserved envelope members the protocol layer owns (gmcp_guild_key_reserved).
local ENVELOPE = { guild = true, full = true, page = true, pages = true }

-- The mudlib stamps this from query_guild() (secure/pinc/guild.h:257, a bare
-- `return guild;` with no normalization) into the frame's `guild` field
-- (secure/pinc/gmcp.h:676); query_guild() in turn reflects whatever
-- set_guild(...) was called with, which for this guild is the lowercase
-- singular literal "viking" (players/viking/room/gatehouse.c:254). Compare
-- case-insensitively so a casing change on either side cannot silently turn
-- every real frame into a dropped "foreign" one again.
local GUILD_NAME = "viking"

local gmcp_stats = { frames = 0, foreign = 0, unknown = {}, applied = {}, errors = {} }
local gmcp_reported_errors = {}

-- GMCP writer outcomes record into gmcp_stats, mirroring the MIP-side
-- reported_errors dedup below but scoped separately -- a MIP key and a GMCP
-- key that happen to share a name must not suppress each other's first-error
-- print. Built as closures over the `gmcp_stats` upvalue (rather than
-- snapshotting its sub-tables) so they keep working after
-- protocol.reset_connection() reassigns gmcp_stats wholesale.
local function gmcp_record_error(key, err)
  gmcp_stats.errors[key] = (gmcp_stats.errors[key] or 0) + 1
  if not gmcp_reported_errors[key] then
    gmcp_reported_errors[key] = true
    print("[vik] gmcp writer error " .. key .. ": " .. tostring(err))
  end
end

local function gmcp_record_success(key)
  gmcp_stats.applied[key] = (gmcp_stats.applied[key] or 0) + 1
  ui.dirty()
end

local gmcp_dispatch_opts = { record_error = gmcp_record_error, record_success = gmcp_record_success }

function protocol.gmcp_handler(key, fn)
  if gmcp_handlers[key] then error("duplicate gmcp handler: " .. key) end
  gmcp_handlers[key] = fn
end

function protocol.gmcp_stats()
  return gmcp_stats
end

function protocol.handler(key, fn)
  if handlers[key] then error("duplicate handler: " .. key) end
  handlers[key] = fn
end

-- Second dispatch tier for LEGACY's key:match(...) branches (numbered row/edge
-- keys like VCR%d%d). Registration-ordered; ingest tries the exact table
-- first, then walks this list and fires the first pattern that matches --
-- so a literal handlers[key] entry always wins over a pattern that would
-- also have matched. The matched fn receives (key, value), unlike an exact
-- handler's (value), since the row branches extract their row index from
-- the key itself.
function protocol.pattern_handler(pattern, fn)
  for _, p in ipairs(pattern_handlers) do
    if p.pattern == pattern then error("duplicate pattern handler: " .. pattern) end
  end
  pattern_handlers[#pattern_handlers + 1] = { pattern = pattern, fn = fn }
end

-- Shared invoke path for MIP's two dispatch tiers and GMCP's per-key
-- writers: same pcall/first-error-print/success-accounting semantics
-- regardless of transport, parameterized by opts.record_error/
-- opts.record_success so each transport's stats scope (and error message
-- text) stays exactly what it was before this was unified, byte-for-byte
-- for the MIP path.
local function dispatch(key, fn, opts, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    opts.record_error(key, err)
    return
  end
  opts.record_success(key)
end

local mip_dispatch_opts = {
  record_error = function(key, err)
    stats.errors[key] = (stats.errors[key] or 0) + 1
    if not reported_errors[key] then
      reported_errors[key] = true
      print("[vik] parser error " .. key .. ": " .. tostring(err))
    end
  end,
  record_success = function()
    stats.ingested = stats.ingested + 1
    ui.dirty()
  end,
}

function protocol.ingest(key, value)
  if trace_on then print("[vik] ingest " .. key) end
  local fn = handlers[key]
  if fn then
    dispatch(key, fn, mip_dispatch_opts, value)
    return
  end
  for _, p in ipairs(pattern_handlers) do
    if key:match(p.pattern) then
      dispatch(key, p.fn, mip_dispatch_opts, key, value)
      return
    end
  end
  stats.unknown[key] = (stats.unknown[key] or 0) + 1
end

local function dispatch_batch(root_key)
  local parts_map = batches[root_key]
  local idx = {}
  for n in pairs(parts_map) do idx[#idx + 1] = n end
  table.sort(idx)
  local joined = {}
  for _, n in ipairs(idx) do joined[#joined + 1] = parts_map[n] end
  batches[root_key], batch_totals[root_key], batch_ts[root_key] = nil, nil, nil
  protocol.ingest(root_key, table.concat(joined))
end

local function feed(text)
  local parts = util.split(text, "%^%^")
  local i = 1
  while i <= #parts do
    local key = parts[i]
    local val = parts[i + 1] or ""
    if key ~= "" then
      local root_key, batch_num, batch_total = key:match("^(.*)_(%d+)of(%d+)$")
      if not root_key then
        root_key, batch_num = key:match("^(.*)_(%d+)$")
      end
      if root_key and batch_num then
        if not batches[root_key] then batches[root_key] = {} end
        batches[root_key][tonumber(batch_num)] = val
        if batch_total then
          batch_totals[root_key] = tonumber(batch_total)
          local have = 0
          for _ in pairs(batches[root_key]) do have = have + 1 end
          if have >= batch_totals[root_key] then dispatch_batch(root_key) end
        end
      else
        protocol.ingest(key, val)
      end
    end
    i = i + 2
  end
end

local function active_source()
  if source_mode ~= "auto" then return source_mode end
  return gmcp_latched and "gmcp" or "mip"
end

function protocol.on_bbe(text)
  if active_source() ~= "mip" then
    stats.suppressed = stats.suppressed + 1
    return
  end
  feed(text)
end

-- One Guild.* frame. Keys are applied individually: a key absent from a frame
-- means unchanged, never empty, because ordinary frames are deltas.
function protocol.on_gmcp(package, data)
  if type(data) ~= "table" then return end
  gmcp_stats.frames = gmcp_stats.frames + 1

  -- Whose guild sent this. A frame from another guild must never reach a
  -- writer: the protocol layer stamps `guild` precisely so a client can
  -- tell. Compared case-insensitively -- see GUILD_NAME's comment above.
  local guild = data.guild
  if type(guild) ~= "string" or guild:lower() ~= GUILD_NAME then
    gmcp_stats.foreign = gmcp_stats.foreign + 1
    return
  end

  for key, value in pairs(data) do
    if not ENVELOPE[key] then
      protocol.apply_gmcp_key(key, value)
    end
  end
end

-- Route one payload key. Task 4 replaces the naive uppercase with the key map.
function protocol.apply_gmcp_key(gmcp_key, value)
  local mip_key = tostring(gmcp_key):upper()
  local fn = gmcp_handlers[mip_key]
  if not fn then
    gmcp_stats.unknown[mip_key] = (gmcp_stats.unknown[mip_key] or 0) + 1
    return
  end
  dispatch(mip_key, fn, gmcp_dispatch_opts, value)
end

-- Cleared on disconnect: the next session may not negotiate GMCP at all, and
-- stale GMCP state must not outlive the connection that produced it.
function protocol.reset_connection()
  gmcp_stats = { frames = 0, foreign = 0, unknown = {}, applied = {}, errors = {} }
end

-- Legacy KEY_N (no total) batches complete only here. LEGACY
-- (guild_viking.lua:2932-2942, "dispatch whatever we have after the 0.1s
-- grace period, as before") dispatches whatever has accumulated for a
-- no-total root key on the very first sweep it survives to, sorted by
-- numeric key and joined -- there is no completeness/contiguity gate and no
-- staleness handling for this branch, unlike the known-total case below.
-- A known-total batch surviving to a sweep call is, by construction,
-- incomplete (a complete one dispatches instantly from feed() above); give
-- it up to 2 seconds from first sight to finish before dropping it whole
-- (guild_viking.lua:2896-2931, `_mip_batch_ts`, guild_viking.lua:489).
-- `now` is SECONDS (LEGACY semantics); the caller (init.lua's sweep timer)
-- divides lera.time()'s milliseconds down before calling in.
-- Note: the no-total branch above differs slightly from LEGACY in timing,
-- not outcome -- LEGACY arms a fixed 0.1s one-shot timer per batch, while
-- this sweep is a free-running 100ms timer that dispatches whatever no-total
-- batch it finds pending, so a batch can dispatch sooner than LEGACY's fixed
-- delay depending on poll phase. Known, accepted.
function protocol.sweep(now)
  for root_key in pairs(batches) do
    if batch_totals[root_key] then
      if not batch_ts[root_key] then batch_ts[root_key] = now end
      if now - batch_ts[root_key] > 2 then
        batches[root_key], batch_totals[root_key], batch_ts[root_key] = nil, nil, nil
      end
    else
      dispatch_batch(root_key)
    end
  end
end

function protocol.source(mode)
  if mode == "mip" or mode == "gmcp" or mode == "auto" then
    source_mode = mode
    if mode ~= "auto" then gmcp_latched = (mode == "gmcp") end
  end
  return source_mode
end

-- Diagnostic trace, mirroring gmcp.trace's convention: no argument reports
-- the current setting, true/false sets it. Off by default; printed lines go
-- through protocol.ingest above so both exact and pattern/unknown keys show.
function protocol.trace(on)
  if on ~= nil then trace_on = on and true or false end
  return trace_on
end

function protocol.stats()
  local pending = 0
  for _ in pairs(batches) do pending = pending + 1 end
  return {
    ingested = stats.ingested, unknown = stats.unknown, errors = stats.errors,
    suppressed = stats.suppressed, batches_pending = pending,
    source = source_mode, latched = gmcp_latched,
  }
end

return protocol
