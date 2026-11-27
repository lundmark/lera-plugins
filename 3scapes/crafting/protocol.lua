-- Craft.* GMCP ingest.
--
-- Crafting has no per-entity attribution field the way Merc.* has "merc"
-- (a session has exactly one crafting standing, not a switchable roster), so
-- this is simpler than mercenary/protocol.lua: one mirror table per
-- sub-package, delta-merged key by key, replaced outright on a `full` frame.
--
-- Two of the sub-packages (Skills, Recipes) split a single logical push
-- across SEVERAL separate GMCP frames using distinctly-named top-level keys
-- ("skills", "skills_2", "skills_4", ... and "recipes_chaos",
-- "recipes_chaos_2", "catalogue_chaos", ...) rather than the driver's generic
-- page/pages envelope -- see doc/GMCP.md and include/gmcp.h in the crafting
-- source. Ordinary delta-merge already handles this correctly: each chunk
-- just adds its own key to the mirror, and state.lua's projection combines
-- the numbered keys back into one flat table when it reads the mirror.
local M = {}

-- Info and State have compatibility wire names. Structures is exposed
-- internally as Buildings so the same page can consume it.
local PACKAGES = {
  info = "Info", state = "State",
  infodata = "Info", statedata = "State", skills = "Skills",
  structures = "Buildings", jobs = "Jobs", recipes = "Recipes",
  market = "Market",
}

local ENVELOPE = { full = true, page = true, pages = true }

-- Skills, Recipes, State and Buildings are fragmented across MANY separate
-- GMCP frames per logical update (numbered keys, see this file's header
-- comment) -- unlike every other Craft.* package, no single frame is ever a
-- complete snapshot of the sub-package on its own (State's "materials"
-- chunks the same way once a player's distinct-material count crosses the
-- 128-element GMCP container cap). A `full` stamp on any one chunk therefore
-- must never wholesale-replace the mirror (that would erase every chunk
-- accumulated so far, leaving only whichever chunk arrives last -- this was
-- observed live as "only 1 skill" / "no recipes visible", matching a
-- 33-skill, 2-per-chunk split's 1-skill remainder chunk). These packages
-- merge forever instead; M.reset_connection() (on disconnect) is what
-- actually clears them between sessions.
--
-- Buildings was missing from this list entirely -- every Craft.Structures
-- frame arrives tagged full:1 (confirmed live via on_gmcp's raw trace:
-- `{"full":1,"bldgs_2":[...]}`), so without ALWAYS_MERGE every chunk
-- wholesale-replaced the mirror the instant the next one landed: "bldgs"
-- written then wiped by "bldgs_1", wiped by "bldgs_2", wiped by
-- "refineries" -- always leaving exactly the last chunk of the cycle
-- standing, which is always "refineries". This was the actual root cause of
-- the whole "owned"/"bldgs" saga: the server-side pacing/renaming/fallthrough
-- fixes were all real bugs worth having fixed, but none of them were ever
-- going to matter while this file discarded every earlier chunk on arrival.
local ALWAYS_MERGE = { Skills = true, Recipes = true, State = true, Buildings = true }

local mirrors, seen, counters, wire_names
-- Batched snapshots being assembled, per package (Jobs, Market).
local batch_stage = {}
local apply_cb, handler_id
-- Materials staging (see handle_materials below): { gen, chunks = {[key]=rows}, expected }.
local materials_stage

local function blank_counters()
  return { frames = 0, applied = 0, bad_package = 0, bad_payload = 0 }
end

local function blank_materials_stage()
  return { gen = nil, chunks = {}, expected = nil }
end

function M.reset_connection()
  batch_stage = {}
  mirrors = {}
  seen = {}
  counters = blank_counters()
  wire_names = {}
  materials_stage = blank_materials_stage()
end

M.reset_connection()

-- Diagnostic only: chunks arrive staged now (see handle_materials), never
-- written to the live mirror until a generation is confirmed whole -- so
-- /craft status needs a direct window into staging to show what's stuck
-- mid-flight, since the mirror itself no longer reveals a partial cycle.
function M.materials_stage_debug()
  local n = 0
  local sizes = {}
  local k, v
  for k, v in pairs(materials_stage.chunks) do
    n = n + 1
    sizes[#sizes + 1] = tostring(k) .. ":" .. tostring(type(v) == "table" and #v or v)
  end
  table.sort(sizes)
  return { gen = materials_stage.gen, expected = materials_stage.expected, have = n,
    sizes = table.concat(sizes, ", ") }
end

function M.on_apply(fn) apply_cb = fn end
function M.mirror(sub) return mirrors[sub] end
function M.seen(sub) return seen[sub] end

function M.counters()
  local out = {}
  for k, v in pairs(counters) do out[k] = v end
  return out
end

local function subpackage(pkg)
  if type(pkg) ~= "string" then return nil end
  local suffix = pkg:match("^[Cc][Rr][Aa][Ff][Tt]%.(.+)$")
  if not suffix then return nil end
  suffix = suffix:lower()
  return PACKAGES[suffix], suffix
end

local function accepted(data)
  local out = {}
  for k, v in pairs(data) do
    if not ENVELOPE[k] then out[k] = v end
  end
  return out
end

-- Chunk keys are "materials_g<gen>c<idx>" now, not "materials"/"materials_N"
-- with a separate co-key: confirmed live that adding "materials_gen" as a
-- SECOND key alongside the chunk's array value made the whole chunk vanish
-- on delivery -- even sent completely alone, one chunk per isolated network
-- round-trip, ruling out burst collision. A single-key payload (this array,
-- and nothing else) is the one shape already proven reliable, so the
-- generation moves into the key text instead of riding as a co-key.
local function materials_chunk_match(k)
  local gen_s, idx_s = k:match("^materials_g(%d+)c(%d+)$")
  if not gen_s then return nil, nil end
  return tonumber(gen_s), tonumber(idx_s)
end

-- Closing count key is "materials_chunks_g<gen>" now, not a bare
-- "materials_chunks" riding alongside a separate "materials_gen" co-key --
-- confirmed live that the two-key shape never once survived delivery (the
-- client's materials.expected stayed permanently nil no matter how long a
-- cycle was given), the same root cause independently confirmed by
-- Craft.Buildings' "owned"+"refineries" two-key push. Same fix as the chunk
-- keys just above: the correlation moves into the key text instead.
local function materials_closing_match(k)
  local gen_s = k:match("^materials_chunks_g(%d+)$")
  if not gen_s then return nil end
  return tonumber(gen_s)
end

local function is_materials_key(k)
  return materials_chunk_match(k) ~= nil or materials_closing_match(k) ~= nil
end

local function clear_materials_keys(mirror)
  mirror.materials = nil
  -- Generous upper bound (see CRAFT_GMCP_ARR_CHUNK=12 in gmcp.h): ~90-110
  -- possible materials in this game tops out around 9-10 chunks. This is the
  -- OUTPUT naming committed into the mirror (unchanged, plain "materials"/
  -- "materials_N") -- state.lua's collect_rows() already reads exactly this
  -- shape, so only the wire key scheme changed, not what lands in the mirror.
  local i
  for i = 1, 32 do mirror["materials_" .. i] = nil end
end

-- Materials arrive as a chunked, generation-tagged cycle (see gmcp.h's
-- _cgmcp_push_materials/_cgmcp_push_materials_from). Staged here separately
-- from the live mirror and committed ATOMICALLY only once a cycle is
-- confirmed whole -- an earlier version pruned/wrote the mirror directly as
-- each piece arrived, which glitched multiple ways across several fixes:
-- pruning as the FIRST message of a cycle opened a visible gap every ~6s
-- fast-beat; even pruning last, a shuffled LPC mapping iteration order
-- between cycles means which materials land in chunk 0 vs chunk 3 differs
-- cycle to cycle, so a bare numbered key couldn't tell a fresh chunk from a
-- stale one sharing that same number. Gen-tagging (now via the key text,
-- see materials_chunk_match) removes that ambiguity: nothing is ever written
-- to the mirror until every chunk the closing count implies has actually
-- arrived under this exact generation.
local function handle_materials(keys)
  local k, v
  for k, v in pairs(keys) do
    local gen, idx = materials_chunk_match(k)
    if gen ~= nil then
      -- Generations only ever increase; adopt whichever is newest seen and
      -- discard anything staged for an older one, in case an older gen's
      -- straggler chunk arrives late after a newer gen already started.
      if materials_stage.gen == nil or gen > materials_stage.gen then
        materials_stage = { gen = gen, chunks = {}, expected = nil }
      end
      if gen == materials_stage.gen then materials_stage.chunks[idx] = v end
    else
      local cgen = materials_closing_match(k)
      if cgen ~= nil then
        if materials_stage.gen == nil or cgen > materials_stage.gen then
          materials_stage = { gen = cgen, chunks = {}, expected = nil }
        end
        if cgen == materials_stage.gen then
          materials_stage.expected = tonumber(v) or 0
        end
      end
    end
  end
  if materials_stage.expected == nil then return end

  local n = materials_stage.expected
  local have, i = 0, 0
  while i < n do
    if materials_stage.chunks[i] ~= nil then have = have + 1 end
    i = i + 1
  end
  if have < n then return end   -- cycle still streaming in; not yet whole

  local mirror = mirrors["State"] or {}
  mirrors["State"] = mirror
  clear_materials_keys(mirror)
  i = 0
  while i < n do
    local out_key = (i == 0) and "materials" or ("materials_" .. i)
    mirror[out_key] = materials_stage.chunks[i]
    i = i + 1
  end
end

local JOB_LISTS = {
  b = "builds", p = "pending_builds", m = "masterwork",
  q = "queues", r = "ready", a = "automation",
}

-- Craft.Market batches (players/skuggis/crafting doc/GMCP.md): prefix mkt_,
-- one code per list in the server's order, closing `l` with an empty array.
local MARKET_LISTS = {
  o = "orders", m = "material_orders", e = "exchanges", a = "auctions",
  s = "scroll_orders", u = "scroll_auctions", c = "scroll_outbox",
}

-- Per package: key prefix, list codes, and what a valid closing `l` frame
-- looks like (its rows are written into the
-- snapshot by `close`).
local BATCHES = {
  Jobs = { prefix = "jobs", lists = JOB_LISTS,
    close = function(rows, snapshot)
      if type(rows[1]) ~= "number" or type(rows[2]) ~= "number" then return false end
      snapshot.queue_total, snapshot.queue_cap = rows[1], rows[2]
      return true
    end },
  Market = { prefix = "mkt", lists = MARKET_LISTS,
    close = function() return true end },
}

-- Server batches carry one complete snapshot. Keep the previous timers and
-- controls until the matching final frame arrives (for Jobs, with both
-- queue limits). Returns is_batch, snapshot-when-complete. Any frame that
-- does not fit the stage drops it, so a bad closing frame cannot pin the
-- stage and block the batches after it until the next full snapshot.
local function accept_batch(sub, key, rows)
  local spec = BATCHES[sub]
  if not spec then return false end
  local prefix, gen, index, count, code = key:match("^(%a+)_(%x+)_(%d+)_(%d+)_([a-z])$")
  if not gen or prefix ~= spec.prefix then return false end
  index, count = tonumber(index), tonumber(count)
  if type(rows) ~= "table" or index < 1 or index > count
      or (code ~= "l" and not spec.lists[code]) then
    batch_stage[sub] = nil
    return true
  end
  if index == 1 then
    batch_stage[sub] = { gen = gen, count = count, next = 1, snapshot = {} }
    for _, name in pairs(spec.lists) do batch_stage[sub].snapshot[name] = {} end
  end
  local stage = batch_stage[sub]
  if not stage or stage.gen ~= gen or stage.count ~= count or stage.next ~= index then
    batch_stage[sub] = nil
    return true
  end
  if code == "l" then
    batch_stage[sub] = nil
    if index ~= count or not spec.close(rows, stage.snapshot) then return true end
    return true, stage.snapshot
  end
  local target = stage.snapshot[spec.lists[code]]
  for _, row in ipairs(rows) do target[#target + 1] = row end
  stage.next = index + 1
  return true
end

local function applied(sub)
  seen[sub] = lera.time()
  counters.applied = counters.applied + 1
  if apply_cb then apply_cb(sub, mirrors[sub]) end
  return true
end

function M.on_gmcp(pkg, data)
  counters.frames = counters.frames + 1

  local sub, suffix = subpackage(pkg)
  if not sub then
    counters.bad_package = counters.bad_package + 1
    return false
  end
  if type(data) ~= "table" then
    counters.bad_payload = counters.bad_payload + 1
    return false
  end

  -- Use the first wire name received for each feed until reconnect. Servers
  -- sending both aliases have separate delta streams, including material chunks.
  if sub == "Info" or sub == "State" then
    if wire_names[sub] and wire_names[sub] ~= suffix then return true end
    wire_names[sub] = suffix
  end

  local keys = accepted(data)
  if BATCHES[sub] then
    for key, value in pairs(keys) do
      local is_batch, snapshot = accept_batch(sub, key, value)
      if is_batch then
        if not snapshot then return true end
        mirrors[sub] = snapshot
        return applied(sub)
      end
    end
    -- An ordinary frame between batches abandons a half-built snapshot.
    batch_stage[sub] = nil
  end

  -- Materials chunk/count/gen keys are staged and committed separately (see
  -- handle_materials) -- pulled out of the ordinary merge below so a
  -- still-streaming cycle's raw keys never land directly in the mirror.
  local ordinary = keys
  if sub == "State" then
    ordinary = {}
    local k, v
    for k, v in pairs(keys) do
      if not is_materials_key(k) then ordinary[k] = v end
    end
  end

  -- A full push the server splits over several frames stamps full:1 on
  -- EVERY page, so only its first page may start the mirror afresh; later
  -- pages add to it (replacing on each page kept only the last one -- Market
  -- showed only "orders", losing material_orders, exchanges and auctions).
  local first_page = data.page == nil or tonumber(data.page) == 1
  if not ALWAYS_MERGE[sub] and ((data.full == 1 and first_page) or not mirrors[sub]) then
    mirrors[sub] = ordinary
  else
    local mirror = mirrors[sub] or {}
    mirrors[sub] = mirror
    for k, v in pairs(ordinary) do mirror[k] = v end
  end

  if sub == "State" then handle_materials(keys) end

  return applied(sub)
end

function M.subscribe()
  if handler_id then return handler_id end
  -- One registration at the root; the codec resolves "Craft 1" to every
  -- sub-package, the same way it does for Merc/Guild.
  handler_id = gmcp.on("Craft", function(pkg, data) M.on_gmcp(pkg, data) end)
  if not handler_id then
    print("[crafting] GMCP subscription to Craft failed; no crafting data "
      .. "will arrive this session")
  end
  return handler_id
end

function M.unsubscribe()
  if not handler_id then return false end
  gmcp.remove(handler_id)
  handler_id = nil
  return true
end

return M
