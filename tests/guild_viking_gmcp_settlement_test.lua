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

-- Kills: a decoder that zips a short frame against the canonical 24-field
-- order regardless of length, which would silently misread every field from
-- LEGACY's retired 17-field layout onward (its position 17 is comm_upkeep,
-- not tax_income, so everything shifts). A 17-field frame is well short of
-- even the 23-field layout city_test.lua's own SETTLERX case sends (safe,
-- since positions 1-23 mean the same thing in both layouts -- see
-- write_settlerx's header comment), so the guard must reject this one.
do
  local fields = { "settler_edict", "settler_edict_left", "settler_edict_cd",
    "settler_housing_cap", "settler_housing_plots", "settler_housing_avg",
    "settler_housing_quality", "settler_housing_upkeep", "settler_jobs",
    "settler_employed", "settler_market_staffed", "settler_mult_pct",
    "settler_security", "settler_dignity", "settler_flourishing",
    "settler_community_net", "settler_community_upkeep", "settler_sustenance",
    "settler_emp_score", "settler_sentiment", "settler_supply_next",
    "settler_pop_next" }
  for _, f in ipairs(fields) do S[f] = "sentinel" end
  -- 17 pipe fields -- LEGACY's shortest retired tier.
  city.SETTLERX("feast|100|20|500|20|30|80|10|200|150|5|105|60|40|75|20|5")
  local all_unchanged = true
  for _, f in ipairs(fields) do
    if S[f] ~= "sentinel" then all_unchanged = false end
  end
  check("settlerx short frame writes nothing", all_unchanged)
end

equivalent("sproj", "SPROJ",
  { "id", "kind", "from", "to", "secs", "mats", "done", "detail", "paid" },
  "p1|build|A1|B2|300|timber:5|0|detail one|1;p2|raze|C3|D4|120||1|detail two|0",
  { "settler_projects" }, true)

-- sevents is also hand-encoded (players/viking/obj/include/client.h:
-- `out += r["ts"] + "|" + r["msg"]"), not _v_join -- msg is inserted raw and
-- may itself contain "|", so (like sconsume) it cannot go through
-- gmcp_map.zip: zip would split every "|" and truncate msg at the first one.
-- LEGACY's own decode (`entry:match("^([^|]+)|(.*)$")`) splits only the
-- first pipe, capturing the remainder greedily; city.SEVENTS keeps doing
-- exactly that. So, like sconsume, these cases construct the "GMCP form" as
-- a literal records list rather than via zip.
do
  local fields = { "settler_events" }
  clear(fields)
  city.SEVENTS("1000|first event;1001|second event")
  local via_mip = snapshot(fields)

  clear(fields)
  city._gmcp.SEVENTS({ { ts = "1000", msg = "first event" },
                        { ts = "1001", msg = "second event" } })
  local via_gmcp = snapshot(fields)

  check("sevents transport equivalence", same(via_mip, via_gmcp), "mip vs gmcp differ")
end

-- Kills: a decoder that splits msg on every "|" (e.g. zip against a
-- declared {ts, msg} order), which would truncate msg at the first embedded
-- pipe instead of keeping LEGACY's "capture the remainder greedily"
-- behavior. A real chat/event message can contain "|" (e.g. a copied
-- command or a channel name), so this is not a hypothetical.
do
  local fields = { "settler_events" }
  clear(fields)
  city.SEVENTS("1000|msg|with|pipe")
  local via_mip = snapshot(fields)

  clear(fields)
  city._gmcp.SEVENTS({ { ts = "1000", msg = "msg|with|pipe" } })
  local via_gmcp = snapshot(fields)

  check("sevents pipe-in-msg transport equivalence", same(via_mip, via_gmcp),
    "mip vs gmcp differ")
  check("sevents pipe-in-msg preserves the full message",
    via_mip.settler_events and via_mip.settler_events[1]
      and via_mip.settler_events[1].msg == "msg|with|pipe",
    via_mip.settler_events and via_mip.settler_events[1]
      and via_mip.settler_events[1].msg)
end

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
