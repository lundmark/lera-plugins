-- Transport-agnostic ingestion. Adapters (MIP BBE today, GMCP later) reduce
-- their wire format to ingest(key, value); the parsers never know the source.
local util = require("util")
local gmcp_map = require("gmcp_map")

local protocol = {}

local handlers = {}
local pattern_handlers = {}  -- ordered list: { {pattern=p, fn=fn}, ... }
local batches, batch_totals, batch_ts = {}, {}, {}
local stats = { ingested = 0, unknown = {}, errors = {}, suppressed = 0 }
local reported_errors = {}
local source_mode = "auto"   -- "mip" | "gmcp" | "auto"
local trace_on = false   -- diagnostic: /vik trace -- off by default, silent otherwise

-- Keys fed by GMCP this connection. Per key, not per transport: GMCP covers
-- five panels, so a wholesale latch would take every MIP-only page dark.
local gmcp_keys = {}

function protocol.gmcp_keys()
  local out = {}
  for k in pairs(gmcp_keys) do out[k] = true end
  return out
end

-- GMCP-side writers, keyed by MIP key. Registered from a handler module's
-- `_gmcp` table, so one key's two transports are declared next to each other.
local gmcp_handlers = {}

-- Reserved envelope members the protocol layer owns (gmcp_guild_key_reserved).
local ENVELOPE = { guild = true, full = true, page = true, pages = true }

-- A composite MIP key (gmcp_map.COMPOSITE) receives two GMCP keys -- e.g.
-- SROLES gets `sroles` and `sroles_meta`. Both halves may arrive in the same
-- frame, or a delta may carry just one; either way the writer gets a single
-- table keyed by GMCP key, built from whichever halves this frame had,
-- rather than being invoked once per half. Reverse-indexed once here so
-- frame processing can test membership in O(1).
local composite_of = {}
for mip_key, parts in pairs(gmcp_map.COMPOSITE) do
  for _, gk in ipairs(parts) do composite_of[gk] = mip_key end
end

-- The mudlib stamps this from query_guild() (secure/pinc/guild.h:257, a bare
-- `return guild;` with no normalization) into the frame's `guild` field
-- (secure/pinc/gmcp.h:676); query_guild() in turn reflects whatever
-- set_guild(...) was called with, which for this guild is the lowercase
-- singular literal "viking" (players/viking/room/gatehouse.c:254). Compare
-- case-insensitively so a casing change on either side cannot silently turn
-- every real frame into a dropped "foreign" one again.
local GUILD_NAME = "viking"

local gmcp_stats = { frames = 0, foreign = 0, malformed = 0, suppressed = 0,
                     unknown = {}, applied = {}, errors = {} }
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
  gmcp_keys[key] = true
  ui.dirty()
end

local gmcp_dispatch_opts = { record_error = gmcp_record_error, record_success = gmcp_record_success }

function protocol.gmcp_handler(key, fn)
  if gmcp_handlers[key] then error("duplicate gmcp handler: " .. key) end
  gmcp_handlers[key] = fn
end

-- A copy, like protocol.gmcp_keys() above: callers (init.lua's /vik source and
-- /vik status) get a snapshot they cannot accidentally mutate into the live
-- counters. Sub-tables are copied too, since the counts that matter live in
-- them.
function protocol.gmcp_stats()
  local out = {}
  for k, v in pairs(gmcp_stats) do
    if type(v) == "table" then
      local sub = {}
      for sk, sv in pairs(v) do sub[sk] = sv end
      out[k] = sub
    else
      out[k] = v
    end
  end
  return out
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

-- With per-key latching there is no global "which source won": `auto` means
-- each key answers for itself.
local function gmcp_allowed()
  return source_mode ~= "mip"
end

local function mip_allowed(key)
  if source_mode == "mip" then return true end
  if source_mode == "gmcp" then return false end
  return not gmcp_keys[key]
end

function protocol.ingest(key, value)
  if not mip_allowed(key) then
    stats.suppressed = stats.suppressed + 1
    return
  end
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

function protocol.on_bbe(text)
  feed(text)
end

-- Paging state, per package: two panels can be mid-run at once.
local page_runs = {}

local function is_array(v)
  return type(v) == "table" and (#v > 0 or next(v) == nil)
end

-- Merge one page's keys into a run. A key repeated across pages is a sliced
-- array and its slices concatenate in page order; only arrays are ever sliced
-- server-side, so a repeated non-array is last-wins and counted malformed.
local function merge_page(run, data)
  for key, value in pairs(data) do
    if not ENVELOPE[key] then
      local prev = run.keys[key]
      if prev == nil then
        -- Stored by reference, and an array key sliced across later pages is
        -- appended to in place below -- so a future consumer must not retain
        -- the decoded payload table expecting it to stay as delivered.
        run.keys[key] = value
      elseif is_array(prev) and is_array(value) then
        for i = 1, #value do prev[#prev + 1] = value[i] end
      else
        run.keys[key] = value
        gmcp_stats.malformed = gmcp_stats.malformed + 1
      end
    end
  end
end

-- Shared tail for both the single-key and composite paths: look up the
-- registered writer for a MIP key and dispatch it, or count the key as
-- unknown when no writer is registered (e.g. MONUMENTS, which has no writer
-- yet -- see composite_of's callers).
local function dispatch_gmcp(mip_key, value)
  local fn = gmcp_handlers[mip_key]
  if not fn then
    gmcp_stats.unknown[mip_key] = (gmcp_stats.unknown[mip_key] or 0) + 1
    return
  end
  dispatch(mip_key, fn, gmcp_dispatch_opts, value)
end

-- Route one payload key through the explicit key map.
function protocol.apply_gmcp_key(gmcp_key, value)
  local mip_key = gmcp_map.mip_key(gmcp_key)
  if not mip_key then
    -- Counted under the GMCP name, so /vik source shows the key the guild
    -- actually sent rather than a synthesised MIP name.
    gmcp_stats.unknown[gmcp_key] = (gmcp_stats.unknown[gmcp_key] or 0) + 1
    return
  end
  dispatch_gmcp(mip_key, value)
end

-- Order two apply units. Mapped keys go first, sorted by the MIP key they
-- resolve to; unmapped ones (which only bump a counter) follow, sorted by the
-- GMCP name they were sent under. Two distinct GMCP keys resolving to the same
-- MIP key without being declared COMPOSITE cannot happen today, but the
-- secondary comparison on the GMCP name keeps even that case deterministic --
-- a composite unit carries no single GMCP name and sorts as "".
local function unit_lt(a, b)
  if (a.mip ~= nil) ~= (b.mip ~= nil) then return a.mip ~= nil end
  if a.mip == nil then return a.gmcp < b.gmcp end
  if a.mip ~= b.mip then return a.mip < b.mip end
  return (a.gmcp or "") < (b.gmcp or "")
end

-- Apply every key of one frame, gathering a composite's halves into a single
-- writer call instead of one call per GMCP key. `skip_envelope` is needed
-- only for the unpaged branch's raw `data`; merge_page already excludes
-- envelope members from a de-paged run's `keys`.
--
-- Keys are applied in a declared, stable order (see unit_lt above) rather than
-- in pairs() order. pairs() order is unspecified -- it follows the table's
-- internal hashing, not the frame -- so two writers that touch a common state
-- field would land in an arbitrary order, and since frames are deltas either
-- key may also arrive alone. The visible symptom is a pane value flickering
-- between two answers with no underlying state change, intermittently and
-- with nothing in the frame to explain it. No such collision exists today
-- (SETTLERX owns the housing totals outright -- see write_shplots in
-- handlers/city.lua), but a later plan adds ~20 more keys, and this is the one
-- class of bug that cannot be reconstructed from a bug report.
local function apply_gmcp_frame(data, skip_envelope)
  local pending = {}  -- mip_key -> { [gmcp_key] = value }, composites only
  local units = {}    -- { mip = <MIP key or nil>, gmcp = <name>, value = ... }
  for key, value in pairs(data) do
    if not skip_envelope or not ENVELOPE[key] then
      local composite_key = composite_of[key]
      if composite_key then
        local parts = pending[composite_key]
        if not parts then
          parts = {}
          pending[composite_key] = parts
          units[#units + 1] =
            { mip = composite_key, gmcp = "", value = parts, composite = true }
        end
        parts[key] = value
      else
        units[#units + 1] = { mip = gmcp_map.mip_key(key), gmcp = key, value = value }
      end
    end
  end
  table.sort(units, unit_lt)
  for _, u in ipairs(units) do
    if u.composite then
      dispatch_gmcp(u.mip, u.value)
    else
      -- Single keys keep going through apply_gmcp_key, so the unmapped-key
      -- accounting lives in exactly one place.
      protocol.apply_gmcp_key(u.gmcp, u.value)
    end
  end
end

-- One Guild.* frame. Keys are applied individually: a key absent from a frame
-- means unchanged, never empty, because ordinary frames are deltas. A frame
-- may be split across pages, and an oversized array key sliced across those
-- pages (the key repeated with successive slices) -- see merge_page above.
function protocol.on_gmcp(package, data)
  if type(data) ~= "table" then return end
  if not gmcp_allowed() then
    -- Its own counter, not the MIP-scoped stats.suppressed: that one means
    -- "MIP keys the per-key latch dropped", which /vik status reports as
    -- such. Folding GMCP frames dropped by `source mip` into it makes the
    -- number unreadable in exactly the mode you would set to debug the latch.
    gmcp_stats.suppressed = gmcp_stats.suppressed + 1
    return
  end
  gmcp_stats.frames = gmcp_stats.frames + 1

  -- Whose guild sent this. A frame from another guild must never reach a
  -- writer: the protocol layer stamps `guild` precisely so a client can
  -- tell. Compared case-insensitively -- see GUILD_NAME's comment above.
  local guild = data.guild
  if type(guild) ~= "string" or guild:lower() ~= GUILD_NAME then
    gmcp_stats.foreign = gmcp_stats.foreign + 1
    return
  end

  local page = tonumber(data.page)
  local pages = tonumber(data.pages)

  -- page/pages appear only when a frame is split, so their absence means
  -- this frame is complete on its own.
  if not page or not pages or pages <= 1 then
    page_runs[package] = nil
    apply_gmcp_frame(data, true)
    return
  end

  local run = page_runs[package]
  -- A fresh page 1 abandons whatever was accumulating: it is a new snapshot.
  if page == 1 or not run then
    run = { pages = pages, next_page = 1, keys = {} }
    page_runs[package] = run
  end

  if page ~= run.next_page or pages ~= run.pages then
    -- Out of order or a pages mismatch: the run cannot be trusted.
    page_runs[package] = nil
    gmcp_stats.malformed = gmcp_stats.malformed + 1
    return
  end

  merge_page(run, data)
  run.next_page = page + 1

  if page == pages then
    page_runs[package] = nil
    apply_gmcp_frame(run.keys, false)
  end
end

-- Cleared on disconnect: the next session may not negotiate GMCP at all, and
-- stale GMCP state must not outlive the connection that produced it.
function protocol.reset_connection()
  gmcp_stats = { frames = 0, foreign = 0, malformed = 0, suppressed = 0,
                 unknown = {}, applied = {}, errors = {} }
  page_runs = {}
  gmcp_keys = {}
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
    source = source_mode,
  }
end

return protocol
