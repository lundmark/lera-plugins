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
  -- Guild.Fleet. raidlog's per-entry goods breakdown is a mapping, which a
  -- record used as a container element may not hold, so the server flattens
  -- it to its own top-level key foreign-keyed by `idx`; the two halves have
  -- to reach one writer to be rejoined. rtargets never had a _v_ builder --
  -- MIP joined two arrays with a '|' -- so GMCP sends them as the two arrays
  -- they always were, and the writer keeps MIP's lineage-then-historical
  -- order for the flat name list.
  RAIDLOG   = { "raidlog", "raidlog_goods" },
  RTARGETS  = { "rtargets_lineage", "rtargets_historical" },
  -- Guild.Map is composite in full, not per key. Its planes cannot be read
  -- without `enc` (which encoding packed them) and `legend` (what each code
  -- means), and its rows cannot be sized without `w` -- so routing the keys
  -- individually would hand a writer a packed plane it has no way to decode.
  -- Gathering the frame's keys into one call is exactly what the composite
  -- path exists for; the writer still treats every member as optional,
  -- because ordinary frames are deltas and a step sends `pos` alone.
  VMAP      = { "w", "h", "active", "pos", "legend", "legend_edge", "enc",
                "terrain", "east", "south", "landmarks" },
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

  -- Guild.Fleet
  ships = "SHIPS", supg = "SUPG",
  raidlog = "RAIDLOG", raidlog_goods = "RAIDLOG",
  rtargets_lineage = "RTARGETS", rtargets_historical = "RTARGETS",

  -- Guild.Map (all composite; see M.COMPOSITE above)
  w = "VMAP", h = "VMAP", active = "VMAP", pos = "VMAP", legend = "VMAP",
  legend_edge = "VMAP", enc = "VMAP", terrain = "VMAP", east = "VMAP",
  south = "VMAP", landmarks = "VMAP",

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
