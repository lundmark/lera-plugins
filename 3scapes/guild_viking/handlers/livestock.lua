-- Guild.Livestock payload writers: herds, butchery queue, feed upkeep, pending
-- deliveries, the Livestock Find hall and the per-lineage market.
--
-- Field names are the server's, read from
-- 3s/players/viking/obj/include/client.h's _v_* builders -- NOT from LEGACY's
-- parser, whose local names differ (bid/qual/ster/yld are bldg/quality/
-- sterile/yield on the wire).
--
-- Display calls are deliberately absent: protocol.ingest already marks
-- ui.dirty().
-- No MIP decoder in this file needs util.split: Guild.Livestock has no MIP
-- predecessor in this plugin (see the ORDER-array comment near the bottom),
-- so there is nothing here to zip against a declared field order.
local S = require("state").S

local M = {}

-- The server sends "0" for "no trait" (client.h's _v_herds/_v_lmarket set
-- htrait/mtrait to "0" when the herd or listing has none). Left as "0" it
-- would be looked up as a trait id, so it is normalised here, once, rather
-- than in every consumer.
local function trait_or_nil(t)
  if t == nil or t == "" or t == "0" then return nil end
  return tostring(t)
end

local HERDS_ORDER = { "bldg", "head", "quality", "gen", "sterile", "hard",
                      "fert", "yield", "vigor", "con", "breed", "hv",
                      "trait", "age_ticks" }

-- LEGACY 2300 (guild_viking.lua, the MIP HERDS branch).
-- Keyed by building, because every consumer looks a herd up by the building
-- that houses it. Replaced wholesale on each arrival: the server OMITS a
-- building whose head has dropped to 0, so merging would resurrect dead herds.
function M._gmcp_HERDS(value)
  local out = {}
  for _, r in ipairs(value or {}) do
    if r.bldg then
      out[r.bldg] = {
        bldg = r.bldg,
        head = tonumber(r.head) or 0,
        quality = tonumber(r.quality) or 0,
        gen = tonumber(r.gen) or 0,
        sterile = tonumber(r.sterile) or 0,
        hard = tonumber(r.hard) or 0,
        fert = tonumber(r.fert) or 0,
        yield = tonumber(r.yield) or 0,
        vigor = tonumber(r.vigor) or 0,
        con = tonumber(r.con) or 0,
        breed = tostring(r.breed or ""),
        hv = tonumber(r.hv) or 0,
        trait = trait_or_nil(r.trait),
        age_ticks = tonumber(r.age_ticks) or 0,
      }
    end
  end
  S.herds = out
end

local BQUEUE_SLOT_ORDER = { "slot", "species", "meat", "qty", "secs", "trait" }

-- LEGACY 2330 (guild_viking.lua, the MIP BQUEUE branch). A sibling split of
-- one server mapping (_v_bqueue()'s used/max/slots), so a delta frame may
-- carry any subset of the three halves -- each is applied only when present,
-- matching write_sroles/write_monuments in handlers/city.lua.
function M._gmcp_BQUEUE(parts)
  parts = parts or {}
  if parts.bqueue_used ~= nil then
    S.bqueue_used = tonumber(parts.bqueue_used) or 0
  end
  if parts.bqueue_max ~= nil then
    S.bqueue_max = tonumber(parts.bqueue_max) or 0
  end
  if type(parts.bqueue) == "table" then
    local out = {}
    for _, r in ipairs(parts.bqueue) do
      table.insert(out, {
        slot = tonumber(r.slot) or 0,
        species = tostring(r.species or ""),
        meat = tostring(r.meat or ""),
        qty = tonumber(r.qty) or 0,
        secs = tonumber(r.secs) or 0,
        trait = trait_or_nil(r.trait),
      })
    end
    S.bqueue = out
  end
end

local LFEED_ORDER = { "grain", "water", "head" }

-- LEGACY 2340 (guild_viking.lua, the MIP LFEED branch). The only mapping key
-- in this file: grain/water/head, not a positional record.
function M._gmcp_LFEED(value)
  value = value or {}
  S.lfeed = {
    grain = tonumber(value.grain) or 0,
    water = tonumber(value.water) or 0,
    head = tonumber(value.head) or 0,
  }
end

local LPENDING_ORDER = { "bldg", "species", "breed", "count", "secs" }

-- LEGACY 2350 (guild_viking.lua, the MIP LPENDING branch).
function M._gmcp_LPENDING(value)
  local out = {}
  for _, r in ipairs(value or {}) do
    table.insert(out, {
      bldg = tostring(r.bldg or ""),
      species = tostring(r.species or ""),
      breed = tostring(r.breed or ""),
      count = tonumber(r.count) or 0,
      secs = tonumber(r.secs) or 0,
    })
  end
  S.lpending = out
end

local LFIND_POSTS_ORDER = { "id", "species", "min_quality", "max_price",
                            "bldg", "tier", "trait", "state" }
local LFIND_OFFERS_ORDER = { "id", "species", "breed", "count", "quality",
                             "price", "hard", "fert", "yield", "vigor", "con",
                             "secs", "trait" }
local LFIND_AUCTIONS_ORDER = { "id", "species", "breed", "quality", "reserve",
                               "my_bid", "secs", "trait" }

-- LEGACY 2360-ish (guild_viking.lua, the MIP LFIND branch; bespoke '!'-joined
-- three-section value, matching client.h's _mip_lfind_value()). Three
-- sub-arrays -- postings, offers, auctions -- each applied only when its own
-- key arrived in this frame.
function M._gmcp_LFIND(parts)
  parts = parts or {}
  if type(parts.lfind_posts) == "table" then
    local out = {}
    for _, r in ipairs(parts.lfind_posts) do
      table.insert(out, {
        id = tonumber(r.id) or 0,
        species = tostring(r.species or ""),
        min_quality = tonumber(r.min_quality) or 0,
        max_price = tonumber(r.max_price) or 0,
        bldg = tostring(r.bldg or ""),
        tier = tonumber(r.tier) or 0,
        trait = trait_or_nil(r.trait),
        state = (r.state and tostring(r.state) ~= "") and tostring(r.state) or "open",
      })
    end
    S.lfind.posts = out
  end
  if type(parts.lfind_offers) == "table" then
    local out = {}
    for _, r in ipairs(parts.lfind_offers) do
      table.insert(out, {
        id = tonumber(r.id) or 0,
        species = tostring(r.species or ""),
        breed = tostring(r.breed or ""),
        count = tonumber(r.count) or 0,
        quality = tonumber(r.quality) or 0,
        price = tonumber(r.price) or 0,
        hard = tonumber(r.hard) or 0,
        fert = tonumber(r.fert) or 0,
        yield = tonumber(r.yield) or 0,
        vigor = tonumber(r.vigor) or 0,
        con = tonumber(r.con) or 0,
        secs = tonumber(r.secs) or 0,
        trait = trait_or_nil(r.trait),
      })
    end
    S.lfind.offers = out
  end
  if type(parts.lfind_auctions) == "table" then
    local out = {}
    for _, r in ipairs(parts.lfind_auctions) do
      table.insert(out, {
        id = tonumber(r.id) or 0,
        species = tostring(r.species or ""),
        breed = tostring(r.breed or ""),
        quality = tonumber(r.quality) or 0,
        reserve = tonumber(r.reserve) or 0,
        my_bid = tonumber(r.my_bid) or 0,
        secs = tonumber(r.secs) or 0,
        trait = trait_or_nil(r.trait),
      })
    end
    S.lfind.auctions = out
  end
end

local LMARKET_ORDER = { "lin", "idx", "species", "breed", "count", "price",
                        "hard", "fert", "yield", "vigor", "con", "trait" }

local function build_lmarket_record(r)
  return {
    lin = tonumber(r.lin) or 0,
    idx = tonumber(r.idx) or 0,
    species = tostring(r.species or ""),
    breed = tostring(r.breed or ""),
    count = tonumber(r.count) or 0,
    price = tonumber(r.price) or 0,
    hard = tonumber(r.hard) or 0,
    fert = tonumber(r.fert) or 0,
    yield = tonumber(r.yield) or 0,
    vigor = tonumber(r.vigor) or 0,
    con = tonumber(r.con) or 0,
    trait = trait_or_nil(r.trait),
  }
end

-- LEGACY 2370-ish (guild_viking.lua, the MIP LMARKET branch). The server
-- sends one key per lineage (lmarket_1..lmarket_13) and OMITS a lineage
-- with no pool entirely, so this composite is inherently variable-arity --
-- MERGE, do not replace. A delta frame carrying only some lineages must
-- leave the others' last-known pools standing.
function M._gmcp_LMARKET(parts)
  parts = parts or {}
  for k, records in pairs(parts) do
    local lin = tostring(k):match("^lmarket_(%d+)$")
    if lin and type(records) == "table" then
      local out = {}
      for _, r in ipairs(records) do
        table.insert(out, build_lmarket_record(r))
      end
      S.lmarket[tonumber(lin)] = out
    end
  end
end

local LNEEDS_ORDER = { "species", "current", "cap" }

-- LEGACY 2380-ish (guild_viking.lua, the MIP LNEEDS branch).
function M._gmcp_LNEEDS(value)
  local out = {}
  for _, r in ipairs(value or {}) do
    table.insert(out, {
      species = tostring(r.species or ""),
      current = tonumber(r.current) or 0,
      cap = tonumber(r.cap) or 0,
    })
  end
  S.lneeds = out
end

-- MIP-side ORDER arrays, for symmetry with the other handler modules'
-- declared-order convention (city.lua's SETTLERS_ORDER etc.). None of these
-- profiles are exercised by any MIP branch here -- Guild.Livestock is
-- GMCP-only in this plugin, so these are unused by the tested path and exist
-- only to document the wire order gmcp_map.zip() would need if a MIP decoder
-- were ever added for this package.
M._mip_orders = {
  HERDS = HERDS_ORDER,
  BQUEUE_SLOT = BQUEUE_SLOT_ORDER,
  LFEED = LFEED_ORDER,
  LPENDING = LPENDING_ORDER,
  LFIND_POSTS = LFIND_POSTS_ORDER,
  LFIND_OFFERS = LFIND_OFFERS_ORDER,
  LFIND_AUCTIONS = LFIND_AUCTIONS_ORDER,
  LMARKET = LMARKET_ORDER,
  LNEEDS = LNEEDS_ORDER,
}

M._gmcp = {
  HERDS = M._gmcp_HERDS, BQUEUE = M._gmcp_BQUEUE, LFEED = M._gmcp_LFEED,
  LPENDING = M._gmcp_LPENDING, LFIND = M._gmcp_LFIND,
  LMARKET = M._gmcp_LMARKET, LNEEDS = M._gmcp_LNEEDS,
}

return M
