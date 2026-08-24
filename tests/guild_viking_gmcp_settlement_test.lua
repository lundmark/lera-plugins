-- guild_viking Guild.Settlement transport equivalence: the MIP string form and
-- the GMCP structured form of the same data must leave S.* identical.
package.path = "3scapes/guild_viking/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

ui = { dirty = function() end }
store = { load = function() end, get = function() return nil end,
          set = function() end, save = function() end }
lera = { time = function() return 1000 end, version = function() return "test" end }
buffer = { color_print = function() end }
mud = { send = function() end }

local S = require("state").S
local city = require("handlers.city")
local gmcp_map = require("gmcp_map")

-- Deep compare, so a nested record or list difference is caught rather than
-- two tables comparing unequal by identity.
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

-- Snapshot only the fields a key owns, so an unrelated field cannot mask a
-- difference or cause a false one.
local function snapshot(fields)
  local out = {}
  for _, f in ipairs(fields) do out[f] = S[f] end
  return out
end

local function clear(fields)
  for _, f in ipairs(fields) do S[f] = nil end
end

-- Feed the MIP string, snapshot; clear; feed the GMCP structure decoded from
-- the SAME string through zip; snapshot; compare.
local function equivalent(name, mip_key, order, val, fields, gmcp_is_list)
  clear(fields)
  city[mip_key](val)
  local via_mip = snapshot(fields)

  clear(fields)
  local recs = gmcp_map.zip(order, val)
  city._gmcp[mip_key](gmcp_is_list and recs or recs[1])
  local via_gmcp = snapshot(fields)

  check(name .. " transport equivalence", same(via_mip, via_gmcp),
    "mip vs gmcp differ")
end

-- ---- the seven _v_join keys ------------------------------------------------
-- Kills, for every case below: a writer that drifted from its decoder, so the
-- same data renders differently depending on which transport won.

equivalent("settlers", "SETTLERS",
  { "settlers", "mood", "tax_rate", "water", "fert" },
  "42|75|10|3|7",
  { "settlers", "settler_mood", "settler_tax", "city_water", "city_fert" })

equivalent("sactions", "SACTIONS",
  { "assembly", "watch", "crafts", "feast", "relief", "works" },
  "60|0|120|0|0|30",
  { "settler_actions" })

equivalent("shplots", "SHPLOTS",
  { "h1", "h2", "h3", "h4", "h5" },
  "4|3|2|1|0",
  { "settler_housing_cap", "settler_housing_plots", "settler_housing_plot_tiers" })

-- sconsume is the one exception: its MIP wire form predates `_v_join` (an
-- arbitrary, possibly-partial "good:amount" dict -- see write_sconsume's
-- header comment in city.lua, and city_test.lua's own "fish:20;grain:15"
-- case), not a fixed-order positional record, so it does not go through
-- gmcp_map.zip like the other six. A GMCP payload for this key is the same
-- dict shape (good name -> amount); this case checks the same values fed as
-- a MIP string and as a literal GMCP dict leave S.settler_consumption
-- identical.
do
  local fields = { "settler_consumption" }
  clear(fields)
  city.SCONSUME("fish:20;grain:15")
  local via_mip = snapshot(fields)

  clear(fields)
  city._gmcp.SCONSUME({ fish = "20", grain = "15" })
  local via_gmcp = snapshot(fields)

  check("sconsume transport equivalence", same(via_mip, via_gmcp), "mip vs gmcp differ")
end

equivalent("settlerx", "SETTLERX",
  { "edict", "edict_left", "edict_cd", "housing_cap", "housing_plots",
    "housing_avg_tier_x100", "housing_quality", "housing_upkeep", "jobs",
    "employed", "staffed_market_jobs", "mult_pct", "security", "dignity",
    "flourishing", "net", "tax_income", "comm_upkeep", "sustenance",
    "employment_score", "sentiment", "supply_next_secs", "pop_next_secs",
    "max_housing_plots" },
  "feast|30|300|20|8|250|60|12|40|35|4|110|70|65|1|55|80|25|90|85|5|45|600|24",
  { "settler_edict", "settler_edict_left", "settler_edict_cd",
    "settler_housing_cap", "settler_housing_plots", "settler_housing_avg",
    "settler_housing_quality", "settler_housing_upkeep", "settler_jobs",
    "settler_employed", "settler_market_staffed", "settler_mult_pct",
    "settler_security", "settler_dignity", "settler_flourishing",
    "settler_community_net", "settler_community_upkeep", "settler_sustenance",
    "settler_emp_score", "settler_sentiment", "settler_supply_next",
    "settler_pop_next" })

equivalent("sproj", "SPROJ",
  { "id", "kind", "from", "to", "secs", "mats", "done", "detail", "paid" },
  "p1|build|A1|B2|300|timber:5|0|detail one|1;p2|raze|C3|D4|120||1|detail two|0",
  { "settler_projects" }, true)

equivalent("sevents", "SEVENTS",
  { "ts", "msg" },
  "1000|first event;1001|second event",
  { "settler_events" }, true)

-- Kills: a writer that clears state it does not own, which would make a delta
-- frame for one key wipe another key's fields.
S.settler_events = { "sentinel" }
city._gmcp.SETTLERS({ settlers = "1", mood = "1", tax_rate = "1",
                      water = "1", fert = "1" })
check("writer touches only its own fields",
  S.settler_events ~= nil and S.settler_events[1] == "sentinel",
  S.settler_events and S.settler_events[1])

-- Kills: a registry that never exposed the writers, so protocol could not
-- route to them.
for _, k in ipairs({ "SETTLERS", "SETTLERX", "SACTIONS", "SHPLOTS", "SCONSUME",
                     "SPROJ", "SEVENTS" }) do
  check("gmcp writer registered for " .. k, type(city._gmcp[k]) == "function",
    type(city._gmcp[k]))
end

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
