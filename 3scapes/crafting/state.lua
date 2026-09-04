-- The crafting record: a flat projection of protocol.lua's per-sub-package
-- mirrors, matching crafting_daemon.c's own Craft.* payload shapes 1:1 so
-- pages never have to know about GMCP framing.

local M = {}

local REALMS = { "Chaos", "Fantasy", "Science" }
local REALM_KEYS = { "chaos", "fantasy", "science" }

local function num(v, dflt)
  local n = tonumber(v)
  if n then return n end
  return dflt or 0
end

-- Skills and Recipes split one logical push across several GMCP frames using
-- distinctly-named top-level keys instead of the driver's page/pages
-- envelope (see protocol.lua's header comment): "skills", "skills_1",
-- "skills_2", ... or "known_chaos", "known_chaos_1", ... Collect every
-- key sharing `base` (as an exact prefix before the "_<n>" suffix) in index
-- order, base itself first.
local function collect_chunks(mirror, base)
  local ordered = { { key = base, idx = -1 } }
  for k in pairs(mirror) do
    local prefix, n = k:match("^(.-)_(%d+)$")
    if prefix == base then
      ordered[#ordered + 1] = { key = k, idx = tonumber(n) }
    end
  end
  table.sort(ordered, function(a, b) return a.idx < b.idx end)
  return ordered
end

local function collect_rows(m, base)
  local out = {}
  for _, c in ipairs(collect_chunks(m, base)) do
    local part = m[c.key]
    if type(part) == "table" then
      for i = 1, #part do out[#out + 1] = part[i] end
    end
  end
  return out
end

local rec

function M.reset()
  rec = {
    realms = {}, standing = {},
    soul_tier = 0, soul_cap_building = 0, storage_tier = 0, storage_cap = 0,
    bonus_speed = 0, bonus_logistics = 0, bonus_soul_cap = 0, bonus_soul_gain = 0,

    -- tokens/materials/soul_tiers/buildings/refineries are all arrays of
    -- flat records now, not mappings keyed by a dynamic name -- the latter
    -- was confirmed to vanish entirely over GMCP (see crafting_daemon's
    -- gmcp.h _cgmcp_push_state comment).
    tokens = {}, souls = 0, soul_cap = 0, soul_tiers = {},
    materials = {},
    stock_used = 0, stock_cap = 0,

    skills = {},

    buildings = {}, refineries = {},

    builds = {}, pending_builds = {}, masterwork = {}, queues = {}, queue_total = 0, queue_cap = 0, ready = {},

    recipes_known = {}, recipes_catalogue = {},

    orders = {}, material_orders = {}, exchanges = {}, auctions = {},

    last_update = 0,
  }
  for _, rk in ipairs(REALM_KEYS) do
    rec.recipes_known[rk] = {}
    rec.recipes_catalogue[rk] = {}
  end
end

M.reset()

function M.get() return rec end
function M.has_data() return rec.last_update > 0 end

local function apply_info(m)
  for _, name in ipairs(REALMS) do
    local r = m.realms and m.realms[name] or {}
    rec.realms[name] = { level = num(r.level), bonus = num(r.bonus),
      xp = num(r.xp), license = num(r.license) }
    local s = m.standing and m.standing[name] or {}
    rec.standing[name] = { drop_rank = num(s.drop_rank),
      drop_extra = num(s.drop_extra), drop_bump = num(s.drop_bump) }
  end
  local soul = m.soul or {}
  rec.soul_tier = num(soul.tier)
  rec.soul_cap_building = num(soul.cap)
  local storage = m.storage or {}
  rec.storage_tier = num(storage.tier)
  rec.storage_cap = num(storage.cap)
  local b = m.bonuses or {}
  rec.bonus_speed = num(b.speed)
  rec.bonus_logistics = num(b.logistics)
  rec.bonus_soul_cap = num(b.soul_cap)
  rec.bonus_soul_gain = num(b.soul_gain)
end

-- Tokens arrive as 3 separate small per-realm keys ("tokens_chaos",
-- "tokens_fantasy", "tokens_science"), not one combined array -- a single
-- 15-element "tokens" array riding in the same frame as souls/stock/
-- soul_tiers was confirmed to silently lose realms/tiers even well under
-- GMCP's 128-element cap (see crafting_daemon's gmcp.h _cgmcp_push_state
-- comment). Concatenated back into one flat list here so pages/inventory.lua
-- doesn't need to know about the wire split.
local function collect_tokens(m)
  local out = {}
  local k
  for _, k in ipairs({ "tokens_chaos", "tokens_fantasy", "tokens_science" }) do
    local part = m[k]
    if type(part) == "table" then
      local i
      for i = 1, #part do out[#out + 1] = part[i] end
    end
  end
  return out
end

local function apply_state(m)
  rec.tokens = collect_tokens(m)
  rec.souls = num(m.souls)
  rec.soul_cap = num(m.soul_cap)
  rec.soul_tiers = m.soul_tiers or {}
  -- materials is chunked ("materials", "materials_1", ...), same convention
  -- as Recipes' known/catalogue arrays: a single array over 128 elements is
  -- silently refused whole by GMCP validation (see crafting_daemon's gmcp.h
  -- _cgmcp_push_state comment), and this game has ~90-110 distinct materials.
  rec.materials = collect_rows(m, "materials")
  rec.stock_used = num(m.stock_used)
  rec.stock_cap = num(m.stock_cap)
end

local function apply_skills(m)
  local skills = {}
  for _, c in ipairs(collect_chunks(m, "skills")) do
    local part = m[c.key]
    if type(part) == "table" then
      for name, r in pairs(part) do skills[name] = r end
    end
  end
  rec.skills = skills
end

-- Server fields are "bldgs"/"refineries", chunked ("bldgs", "bldgs_1", ...)
-- like materials/recipes/skills -- collect_rows() already unions those
-- generically. Each row is a plain "|"-delimited STRING, not a mapping
-- record -- confirmed live (server-side debug trace: every chunk reported a
-- successful send; client's raw Buildings mirror never once contained an
-- "owned" key at all, not even garbled under another name) that a 2-key
-- mapping record ({name=.., tier=..}) was the one array-of-mappings shape in
-- this whole plugin that never survived delivery, no matter how it was
-- chunked/paced/isolated -- every other working array-of-mappings here
-- carries more fields (Jobs' queues: 8, catalogue: 4, materials: 6). Same
-- fix this file already applies to nested arrays-of-mappings elsewhere
-- (Jobs' "items", Recipes' "materials"): flatten to strings instead of
-- inventing another structural variant. Parsed back into the {name,tier}/
-- {building,tier,material,percent} shape here so buildings.lua and the
-- refinery-allocation display need no changes.
--
-- The field name itself was renamed "owned" -> "bldgs" on top of all that:
-- even fully isolated one-chunk-per-round-trip (materials' own staging
-- proved that pacing works), a key literally spelled "owned" never once
-- survived delivery, while "refineries" sent the exact same way always did
-- -- pointing at the key text itself as reserved/mishandled by the
-- transport, not shape, chunking, or pacing (see gmcp.h's
-- _cgmcp_push_buildings_step comment).
local function parse_owned_row(s)
  local name, tier = s:match("^(.*)|(%-?%d+)$")
  if not name then return nil end
  return { name = name, tier = tonumber(tier) }
end

local function parse_refinery_row(s)
  local building, tier, material, percent = s:match("^(.-)|(%-?%d+)|(.-)|(%-?%d+)$")
  if not building then return nil end
  return { building = building, tier = tonumber(tier), material = material, percent = tonumber(percent) }
end

local function apply_buildings(m)
  local owned_rows = {}
  for _, s in ipairs(collect_rows(m, "bldgs")) do
    local row = parse_owned_row(s)
    if row then owned_rows[#owned_rows + 1] = row end
  end
  rec.buildings = owned_rows

  local ref_rows = {}
  for _, s in ipairs(collect_rows(m, "refineries")) do
    local row = parse_refinery_row(s)
    if row then ref_rows[#ref_rows + 1] = row end
  end
  rec.refineries = ref_rows
end

local function apply_jobs(m)
  rec.builds = m.builds or {}
  rec.pending_builds = m.pending_builds or {}
  rec.masterwork = m.masterwork or {}
  rec.queues = m.queues or {}
  rec.queue_total = num(m.queue_total)
  rec.queue_cap = num(m.queue_cap)
  rec.ready = m.ready or {}
end


local function apply_recipes(m)
  for _, rk in ipairs(REALM_KEYS) do
    rec.recipes_known[rk] = collect_rows(m, "known_" .. rk)
    rec.recipes_catalogue[rk] = collect_rows(m, "catalogue_" .. rk)
  end
end

local function apply_market(m)
  rec.orders = m.orders or {}
  rec.material_orders = m.material_orders or {}
  rec.exchanges = m.exchanges or {}
  rec.auctions = m.auctions or {}
end

local APPLY = {
  Info = apply_info, State = apply_state, Skills = apply_skills,
  Buildings = apply_buildings, Jobs = apply_jobs, Recipes = apply_recipes,
  Market = apply_market,
}

function M.apply(sub, mirror)
  local fn = APPLY[sub]
  if not fn then return false end
  fn(mirror)
  rec.last_update = lera.time()
  return true
end

function M.snapshot()
  local function deep(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, iv in pairs(v) do out[k] = deep(iv) end
    return out
  end
  return deep(rec)
end

return M
