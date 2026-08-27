-- Merc.* GMCP ingest.
--
-- Keeps one mirror table per sub-package, congruent key for key with the
-- server's own delta cache (protocol_gmcp_ns_cache["Merc"][pkg], set in
-- secure/pinc/gmcp.h:715-718). A delta frame merges into its mirror; a `full`
-- frame replaces it outright. state.lua then projects the mirrors into the
-- flat public record.
--
-- Separating the mirror from the projection is what makes `full` correct for
-- free: replace one table and re-project, instead of working out per key which
-- fields to clear.

local M = {}

local PACKAGES = {
  vitals = "Vitals", info = "Info", stats = "Stats",
  skills = "Skills", talents = "Talents",
}

-- gmcp_ns_key_reserved() maintains ONE reserved set shared across every
-- namespace, so `guild` is reserved on a Merc frame too, even though Merc.*
-- attributes with `merc` and never stamps `guild`.
local ENVELOPE = { merc = true, guild = true, full = true, page = true, pages = true }

local mirrors, page_runs, seen, counters, current_merc
local apply_cb, handler_id

local function blank_counters()
  return { frames = 0, applied = 0, bad_package = 0,
           bad_attribution = 0, bad_page = 0 }
end

function M.reset_connection()
  mirrors = {}
  page_runs = {}
  seen = {}
  counters = blank_counters()
  current_merc = nil
end

M.reset_connection()

function M.on_apply(fn) apply_cb = fn end
function M.mirror(sub) return mirrors[sub] end
function M.merc_name() return current_merc end
function M.seen(sub) return seen[sub] end

function M.counters()
  local out = {}
  for k, v in pairs(counters) do out[k] = v end
  return out
end

local function subpackage(pkg)
  if type(pkg) ~= "string" then return nil end
  local suffix = pkg:match("^[Mm][Ee][Rr][Cc]%.(.+)$")
  if not suffix then return nil end
  return PACKAGES[suffix:lower()]
end

local function accepted(data)
  local out = {}
  for k, v in pairs(data) do
    if not ENVELOPE[k] then out[k] = v end
  end
  return out
end

-- Merge one page's keys into a run. A key repeated across pages is a sliced
-- array and its slices concatenate in page order; anything else is a plain
-- overwrite. Envelope members are excluded here too, so a completed run's keys
-- never carry them.
local function merge_page(run, data)
  for k, v in pairs(data) do
    if not ENVELOPE[k] then
      local prev = run.keys[k]
      if type(prev) == "table" and type(v) == "table"
         and #prev > 0 and #v > 0 then
        for i = 1, #v do prev[#prev + 1] = v[i] end
      else
        run.keys[k] = v
      end
    end
  end
end

local function apply(sub, keys, full, merc)
  local switched = (current_merc ~= nil) and (current_merc ~= merc)
  current_merc = merc

  if full or not mirrors[sub] then
    mirrors[sub] = keys
  else
    local mirror = mirrors[sub]
    for k, v in pairs(keys) do mirror[k] = v end
  end

  seen[sub] = lera.time()
  counters.applied = counters.applied + 1
  if apply_cb then apply_cb(sub, mirrors[sub], merc, switched) end
end

function M.on_gmcp(pkg, data)
  counters.frames = counters.frames + 1

  local sub = subpackage(pkg)
  if not sub then
    counters.bad_package = counters.bad_package + 1
    return false
  end
  if type(data) ~= "table" then
    counters.bad_attribution = counters.bad_attribution + 1
    return false
  end

  -- The protocol layer stamps `merc` on every frame, so its absence is a
  -- malformed frame rather than an anonymous one. Applying it would file the
  -- data under a nil identity and defeat switch detection.
  local merc = data.merc
  if type(merc) ~= "string" or merc == "" then
    counters.bad_attribution = counters.bad_attribution + 1
    return false
  end

  -- page/pages appear only when a frame is split, so their absence -- or a
  -- pages of 1 -- means an ordinary unpaged frame.
  local page = tonumber(data.page)
  local pages = tonumber(data.pages)
  if not page or not pages or pages <= 1 then
    page_runs[sub] = nil
    apply(sub, accepted(data), data.full == 1, merc)
    return true
  end

  local run = page_runs[sub]
  -- A fresh page 1 abandons whatever was accumulating: it is a new snapshot.
  if page == 1 or not run then
    run = { pages = pages, next_page = 1, full = (data.full == 1), keys = {} }
    page_runs[sub] = run
  end
  if page ~= run.next_page or pages ~= run.pages then
    -- Out of order or a pages mismatch: the run cannot be trusted.
    page_runs[sub] = nil
    counters.bad_page = counters.bad_page + 1
    return false
  end

  merge_page(run, data)
  run.next_page = page + 1
  if page == pages then
    page_runs[sub] = nil
    apply(sub, run.keys, run.full, merc)
  end
  return true
end

function M.subscribe()
  if handler_id then return handler_id end
  -- One registration at the root. The codec resolves `Merc 1` to every
  -- sub-package (gmcp_codec.c:402-405), so a sub-package added server-side
  -- later arrives with no client change.
  handler_id = gmcp.on("Merc", function(pkg, data) M.on_gmcp(pkg, data) end)
  return handler_id
end

function M.unsubscribe()
  if not handler_id then return false end
  gmcp.remove(handler_id)
  handler_id = nil
  return true
end

return M
