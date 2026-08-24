-- GMCP payload key -> MIP handler key, and the shared MIP decoder.
--
-- The map is a table of explicit entries rather than a naming rule because
-- three keys break the rule: `queue` is renamed, and MONUMENTS and SROLES are
-- each split across two GMCP keys. Everything else is the uppercase of its
-- GMCP key, listed anyway so an unrecognized key is unmapped by construction
-- and therefore counted rather than routed somewhere plausible.
local util = require("util")

local M = {}

M.COMPOSITE = {
  MONUMENTS = { "monuments_cap", "monuments_list" },
  SROLES    = { "sroles", "sroles_meta" },
}

local MAP = {
  -- Guild.Settlement
  settlers = "SETTLERS", settlerx = "SETTLERX", sactions = "SACTIONS",
  shplots = "SHPLOTS", scivics = "SCIVICS", sproj = "SPROJ",
  sevents = "SEVENTS", sconsume = "SCONSUME",
  sroles = "SROLES", sroles_meta = "SROLES",

  -- Guild.City
  rbuild = "RBUILD", bdmg = "BDMG", upkeep = "UPKEEP", rupkeep = "RUPKEEP",
  cdtime = "CDTIME", raid = "RAID", heat = "HEAT", patrol = "PATROL",
  builds = "BUILDS", garrison = "GARRISON", buildings = "BUILDINGS",
  monuments_cap = "MONUMENTS", monuments_list = "MONUMENTS",

  -- Guild.State: only the two groups nothing else writes when MIP is off.
  -- The rest of Guild.State stays unmapped and counted -- see the design note
  -- in combat.lua for why a second writer on a trigger-owned field is unsafe.
  target = "TARGET", encounter = "ENCOUNTER",

  -- Guild.Trade
  carts = "CARTS", queue = "TQUEUE", cidle = "CIDLE", cupg = "CUPG",
  routes = "ROUTES", blocks = "BLOCKS", refinery = "REFINERY",
  market = "MARKET", incoming = "INCOMING", missions = "MISSIONS",

  -- Deliberately absent, so they are counted rather than routed:
  --   cart_legs, queue_legs, crpr, refinery_grades  (no MIP handler consumes
  --   these; they carry data MIP either does not send or packs inside another
  --   key, and nothing renders them)
}

function M.mip_key(gmcp_key)
  return MAP[tostring(gmcp_key)]
end

-- Decode MIP's wire form against a declared key order: records joined with
-- ";", fields with "|". This mirrors the server's _v_join(records, order),
-- which is what produces the string, so one decoder covers every key whose
-- MIP encoder is _v_join. A flat key is a one-record list.
--
-- A trailing ";" or a doubled ";;" makes util.split(val, ";") yield an empty
-- chunk -- unlike LEGACY's own val:gmatch("[^;]+"), which never produced one.
-- An empty chunk is skipped so it doesn't become a phantom empty record
-- (e.g. a trailing ";" on a SEVENTS/SPROJ value must not insert a blank
-- card). This is a record-level check only: an empty *field* within a real
-- chunk -- "1||" is one record with two empty fields -- is untouched.
function M.zip(order, val)
  local out = {}
  if type(val) ~= "string" or val == "" then return out end
  for _, chunk in ipairs(util.split(val, ";")) do
    if chunk ~= "" then
      local fields = util.split(chunk, "|")
      local rec = {}
      for i, name in ipairs(order) do
        rec[name] = fields[i] or ""
      end
      out[#out + 1] = rec
    end
  end
  return out
end

return M
