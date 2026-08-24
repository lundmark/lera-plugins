-- guild_viking Guild.Settlement writers unit tests. Run from the lera-plugins
-- repo root with LERA_ROOT pointing at a built Lera checkout.
--
-- This suite used to assert TRANSPORT EQUIVALENCE: it fed each key's MIP wire
-- string and its GMCP form and compared the resulting state. That framing died
-- with the MIP handlers -- there is no second transport left to agree with --
-- and it was always the weaker of the two things a test here can do, since two
-- sources can agree on a shape no consumer can read. Every case now asserts the
-- writer's output against values written out literally, and names the state
-- field its consumer reads.
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
lera = { time = function() return 1000 end }
buffer = { color_print = function() end }

local S = require("state").S
local city = require("handlers.city")
local w = city._gmcp

local function count_keys(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

-- ---- settlers --------------------------------------------------------------
w.SETTLERS({ settlers = 42, mood = 75, tax_rate = 10, water = 3, fert = 7 })
check("settlers fields", S.settlers == 42 and S.settler_mood == 75
      and S.settler_tax == 10 and S.city_water == 3 and S.city_fert == 7)
-- Every field is a number in state, whatever the payload's JSON types were.
check("settlers values are numbers, not strings", type(S.settlers) == "number")

-- ---- sactions --------------------------------------------------------------
-- Only actions with time left are listed, in a fixed order, with a display
-- name rather than the payload's key.
w.SACTIONS({ assembly = 60, watch = 0, crafts = 120, feast = 0, relief = 0,
             works = 30 })
check("sactions lists only the running actions, named and in order",
      #S.settler_actions == 3
      and S.settler_actions[1].name == "Assembly" and S.settler_actions[1].secs == 60
      and S.settler_actions[2].name == "Crafts" and S.settler_actions[2].secs == 120
      and S.settler_actions[3].name == "Works" and S.settler_actions[3].secs == 30,
      #S.settler_actions)
w.SACTIONS({})
check("no running actions yields an empty list", #S.settler_actions == 0)

-- ---- shplots ---------------------------------------------------------------
-- SHPLOTS owns only the per-tier plot counts. The housing totals belong to
-- SETTLERX -- both used to write them, and over a delta transport that made
-- the rendered value depend on arrival order.
S.settler_housing_cap, S.settler_housing_plots = nil, nil
w.SHPLOTS({ h1 = 4, h2 = 3, h3 = 2, h4 = 1, h5 = 0 })
check("shplots tier counts", S.settler_housing_plot_tiers.t1 == 4
      and S.settler_housing_plot_tiers.t2 == 3
      and S.settler_housing_plot_tiers.t3 == 2
      and S.settler_housing_plot_tiers.t4 == 1
      and S.settler_housing_plot_tiers.t5 == 0)
check("shplots writes neither housing total",
      S.settler_housing_cap == nil and S.settler_housing_plots == nil,
      "cap=" .. tostring(S.settler_housing_cap) ..
        " plots=" .. tostring(S.settler_housing_plots))

-- ---- settlerx --------------------------------------------------------------
w.SETTLERX({ edict = "feast", edict_left = 30, edict_cd = 300, housing_cap = 20,
             housing_plots = 8, housing_avg_tier_x100 = 250,
             housing_quality = 60, housing_upkeep = 12, jobs = 40,
             employed = 35, staffed_market_jobs = 4, mult_pct = 110,
             security = 70, dignity = 65, flourishing = 1, net = 55,
             tax_income = 80, comm_upkeep = 25, sustenance = 90,
             employment_score = 85, sentiment = 5, supply_next_secs = 45,
             pop_next_secs = 600, max_housing_plots = 24 })
check("settlerx edict block", S.settler_edict == "feast"
      and S.settler_edict_left == 30 and S.settler_edict_cd == 300)
-- SETTLERX owns the housing totals outright.
check("settlerx owns the housing totals", S.settler_housing_cap == 20
      and S.settler_housing_plots == 8)
check("settlerx housing detail", S.settler_housing_avg == 250
      and S.settler_housing_quality == 60 and S.settler_housing_upkeep == 12)
check("settlerx jobs block", S.settler_jobs == 40 and S.settler_employed == 35
      and S.settler_market_staffed == 4)
-- These four are similarly-sized integers in one record, so each is named
-- individually: a swapped pair is exactly what a bulk comparison cannot see.
check("settlerx net lands on settler_community_net", S.settler_community_net == 55)
check("settlerx comm_upkeep lands on settler_community_upkeep",
      S.settler_community_upkeep == 25)
check("settlerx employment_score lands on settler_emp_score",
      S.settler_emp_score == 85)
check("settlerx supply_next_secs lands on settler_supply_next",
      S.settler_supply_next == 45)
check("settlerx remaining scalars", S.settler_mult_pct == 110
      and S.settler_security == 70 and S.settler_dignity == 65
      and S.settler_flourishing == 1 and S.settler_sustenance == 90
      and S.settler_sentiment == 5 and S.settler_pop_next == 600)
-- mult_pct is a multiplier, so its absent default is 100 rather than 0.
w.SETTLERX({ edict = "" })
check("an absent mult_pct defaults to 100, not 0", S.settler_mult_pct == 100)

-- ---- sconsume --------------------------------------------------------------
-- A "good -> amount" dictionary rather than a positional record: the guild
-- sends whichever of the thirteen goods the settlers are actually consuming,
-- so a fixed-order decode was never possible for it.
w.SCONSUME({ fish = 20, grain = 15 })
check("sconsume is a good -> amount lookup",
      count_keys(S.settler_consumption) == 2
      and S.settler_consumption.fish == 20
      and S.settler_consumption.grain == 15)
w.SCONSUME({})
check("an empty sconsume clears the breakdown",
      count_keys(S.settler_consumption) == 0)

-- ---- sproj -----------------------------------------------------------------
w.SPROJ({
  { id = "p1", kind = "build", from = 1, to = 2, secs = 300,
    mats = 5, done = 0, detail = "timber:2/5,iron:1/3", paid = 1 },
  { id = "p2", kind = "raze", from = 3, to = 4, secs = 120,
    mats = 0, done = 1, detail = "", paid = 0 },
})
check("sproj count", #S.settler_projects == 2)
local pr = S.settler_projects[1]
check("sproj from/to land on from_tier/to_tier",
      pr.from_tier == 1 and pr.to_tier == 2)
check("sproj secs/mats/done/paid land on their own fields",
      pr.secs_left == 300 and pr.mats_total == 5 and pr.mats_done == 0
      and pr.daler == 1)
check("sproj scalar fields", pr.id == "p1" and pr.kind == "build")
-- `detail` is a comma-joined "good:have/need" list and becomes a lookup, not
-- a list -- pages/people.lua indexes it by good name.
check("sproj detail becomes a good -> have/need lookup",
      count_keys(pr.mat_detail) == 2
      and pr.mat_detail.timber.have == 2 and pr.mat_detail.timber.need == 5
      and pr.mat_detail.iron.have == 1 and pr.mat_detail.iron.need == 3)
check("a project with no detail has an empty lookup",
      count_keys(S.settler_projects[2].mat_detail) == 0)
local many = {}
for i = 1, 40 do many[i] = { id = "p" .. i, kind = "build" } end
w.SPROJ(many)
check("sproj cap at 30", #S.settler_projects == 30, #S.settler_projects)

-- ---- sevents ---------------------------------------------------------------
w.SEVENTS({ { ts = 1000, msg = "first event" },
            { ts = 1001, msg = "second event" } })
check("sevents", #S.settler_events == 2
      and S.settler_events[1].ts == 1000
      and S.settler_events[1].msg == "first event"
      and S.settler_events[2].msg == "second event")
-- The message is its own field here. Over MIP it was everything after the
-- first pipe, and a decoder splitting on every pipe truncated it -- a real
-- event message can contain one (a copied command, a channel name). The field
-- keeps it whole by construction, which is worth pinning so a future writer
-- cannot reintroduce a split.
w.SEVENTS({ { ts = 1000, msg = "msg|with|pipe" } })
check("a message containing pipes survives whole",
      S.settler_events[1].msg == "msg|with|pipe", S.settler_events[1].msg)

-- ---- scivics ---------------------------------------------------------------
-- S.settler_community_buildings is a { civic_id = count } MAPPING, not an
-- array: state.lua declares it that way and pages/people.lua walks it with
-- sorted_keys(). An array of records would render nothing.
w.SCIVICS({ { id = "longhouse", count = 2 }, { id = "forge", count = 1 } })
check("scivics is keyed by civic id, not positional",
      S.settler_community_buildings.longhouse == 2
      and S.settler_community_buildings.forge == 1
      and S.settler_community_buildings[1] == nil,
      tostring(S.settler_community_buildings[1]))
check("scivics has exactly the civics sent",
      count_keys(S.settler_community_buildings) == 2)

-- ---- sroles (composite) ----------------------------------------------------
w.SROLES({
  sroles = { { role = "farmer", cur = 10, target = 12, work = 3, bonus = 5 },
             { role = "", cur = 1 } },
  sroles_meta = { commoner = 40, identity = "Freeholders" },
})
check("sroles drops a record with no role key", #S.settler_roles == 1)
check("sroles target lands on tgt", S.settler_roles[1].tgt == 12
      and S.settler_roles[1].cur == 10 and S.settler_roles[1].work == 3
      and S.settler_roles[1].bonus == 5)
check("a role gets its key and a display label",
      S.settler_roles[1].key == "farmer"
      and type(S.settler_roles[1].label) == "string"
      and S.settler_roles[1].label ~= "")
check("sroles_meta", S.settler_commoner == 40
      and S.settler_identity == "Freeholders")
-- Two independent keys over a delta transport: one arriving alone must not
-- clobber the other half.
w.SROLES({ sroles_meta = { commoner = 41, identity = "Freeholders" } })
check("a meta-only delta leaves the role list standing",
      S.settler_commoner == 41 and #S.settler_roles == 1)
w.SROLES({ sroles = { { role = "smith", cur = 2, target = 4 } } })
check("a roles-only delta leaves the meta standing",
      S.settler_roles[1].key == "smith" and S.settler_commoner == 41)

-- ---- writer isolation ------------------------------------------------------
-- Kills a writer that clears state it does not own, which would make a delta
-- frame for one key wipe another key's fields.
S.settler_events = { "sentinel" }
w.SETTLERS({ settlers = 1, mood = 1, tax_rate = 1, water = 1, fert = 1 })
check("a writer touches only its own fields",
      S.settler_events[1] == "sentinel")

-- ---- registration ----------------------------------------------------------
for _, k in ipairs({ "SETTLERS", "SETTLERX", "SACTIONS", "SHPLOTS", "SCONSUME",
                     "SPROJ", "SEVENTS", "SCIVICS", "SROLES" }) do
  check("gmcp writer registered for " .. k, type(w[k]) == "function",
    type(w[k]))
end

if failures > 0 then
  print("FAILURES: " .. failures)
  os.exit(1)
end
print("ALL PASS")
