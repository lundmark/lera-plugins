-- Transport-agnostic ingestion. Adapters (MIP BBE today, GMCP later) reduce
-- their wire format to ingest(key, value); the parsers never know the source.
local util = require("util")

local protocol = {}

local handlers = {}
local batches, batch_totals, batch_ts = {}, {}, {}
local stats = { ingested = 0, unknown = {}, errors = {}, suppressed = 0 }
local reported_errors = {}
local source_mode = "auto"   -- "mip" | "gmcp" | "auto"
local gmcp_latched = false

function protocol.handler(key, fn)
  if handlers[key] then error("duplicate handler: " .. key) end
  handlers[key] = fn
end

function protocol.ingest(key, value)
  local fn = handlers[key]
  if not fn then
    stats.unknown[key] = (stats.unknown[key] or 0) + 1
    return
  end
  local ok, err = pcall(fn, value)
  if not ok then
    stats.errors[key] = (stats.errors[key] or 0) + 1
    if not reported_errors[key] then
      reported_errors[key] = true
      print("[vik] parser error " .. key .. ": " .. tostring(err))
    end
    return
  end
  stats.ingested = stats.ingested + 1
  ui.dirty()
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

function protocol.on_gmcp(package, data)
  if type(data) ~= "string" then return end
  if source_mode ~= "mip" and not gmcp_latched then gmcp_latched = true end
  if active_source() ~= "gmcp" then
    stats.suppressed = stats.suppressed + 1
    return
  end
  feed(data)
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
