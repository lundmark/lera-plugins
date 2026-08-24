-- guild_viking pane page unit tests: Task 6's pages/people.lua (LEGACY's
-- draw_page5, guild_viking.lua:9748-10663). Also hosts Task 7's pages
-- (pages/bonds.lua: draw_page8, guild_viking.lua:12756-12831;
-- pages/ranks.lua: draw_page9, guild_viking.lua:12832-13212;
-- pages/court.lua: draw_page_court, guild_viking.lua:13236-13304), per the
-- plan's shared-harness note. Run from the lera-plugins repo root with
-- LERA_ROOT pointing at a built Lera checkout.
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

-- ---- lera API stubs ---------------------------------------------------------
ui = { dirty = function() end }
lera = { render_pass = function() return "local" end }

-- Task 6: the People page's mission/errand "Run There" button actions send
-- through mud.send -- captured here so those tests can assert exact,
-- byte-for-byte command strings.
local send_calls = {}
mud = { send = function(s) send_calls[#send_calls + 1] = s end }

local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local cc = require("pages.city_common")
local people_page = require("pages.people")
local bonds_page = require("pages.bonds")
local ranks_page = require("pages.ranks")
local court_page = require("pages.court")

local S = state.S
local C = pagelib.C
local WIDTH = 80

local function joined(lines)
  return table.concat(lines, "\n")
end

local function find_line(lines, needle)
  for i, l in ipairs(lines) do
    if l:find(needle, 1, true) then return i end
  end
  return nil
end

-- =============================================================================
-- pages/people.lua (Task 6) -- LEGACY draw_page5 (guild_viking.lua:9748-10663)
-- =============================================================================

-- ---- seed Settlers state -----------------------------------------------------
S.settlers = 42
S.settler_tax = 2
S.city_water = 77
S.settler_edict = "feast"
S.settler_edict_left = 125
S.settler_edict_cd = 0
S.settler_housing_cap = 300
S.settler_housing_plots = 12
S.settler_housing_avg = 250   -- -> "2.50"
S.settler_housing_plot_tiers = { t1 = 4, t2 = 3, t3 = 2, t4 = 0, t5 = 1 }
S.settler_housing_upkeep = 15
S.settler_community_upkeep = 8
S.settler_jobs = 30
S.settler_employed = 25
S.settler_market_staffed = 3
S.settler_mood = 82
S.settler_housing_quality = 65
S.settler_sustenance = 44
S.settler_emp_score = 30
S.settler_security = 90
S.settler_dignity = 20
S.settler_sentiment = 5
S.settler_flourishing = 1
S.settler_community_net = 120
S.settler_mult_pct = 150
S.settler_community_buildings = { mead_hall = 2, well = 0 }
S.wstock = {
  { good = "grain", amount = 100, freshness_pct = 100 },
  { good = "fish", amount = 50, freshness_pct = 100 },
  { good = "bread", amount = 20, freshness_pct = 100 },
  { good = "salted_fish", amount = 10, freshness_pct = 100 },
  { good = "mead", amount = 5, freshness_pct = 100 },
  { good = "spoils", amount = 3, freshness_pct = 100 },
}
S.settler_consumption = { grain = 6, water = 4 }
S.settler_supply_next = 300
S.settler_pop_next = 600
S.settler_actions = { { name = "Assembly", secs = 90 } }
S.settler_projects = {
  {
    id = "longhouse", kind = "housing_upgrade", from_tier = 1, to_tier = 2,
    secs_left = -1, mats_total = 10, mats_done = 4, daler = 50,
    mat_detail = { timber = { have = 4, need = 10 } },
  },
}
S.settler_identity = "Builders' Hold"
S.settler_roles = {
  { key = "smidir", label = "Builders", cur = 40, tgt = 55, work = 10, bonus = 8 },
  { key = "boendr", label = "Farmers", cur = 30, tgt = 30, work = 5, bonus = 0 },
}
S.settler_commoner = 12

page_opts.set("show_people_settlers", true)
page_opts.set("show_people_designations", true)

local settlers_lines = people_page.lines(WIDTH)
local settlers_all = joined(settlers_lines)

check("people: non-empty", #settlers_lines > 5, #settlers_lines)

-- ---- Settlers section ---------------------------------------------------
check("people: Settlers header present", find_line(settlers_lines, "Settlers") ~= nil)
check("people: population (42) present", settlers_all:find("42", 1, true) ~= nil)
check("people: tax label (Moderate) present", settlers_all:find("Moderate", 1, true) ~= nil)
check("people: water (77) present", settlers_all:find("77", 1, true) ~= nil)

local edict_idx = find_line(settlers_lines, "Edict:")
check("people: Edict row present", edict_idx ~= nil, settlers_all)
if edict_idx then
  check("people: edict names Festival Feast with its remaining time",
        settlers_lines[edict_idx]:find("Festival Feast", 1, true) ~= nil
        and settlers_lines[edict_idx]:find("2m5s", 1, true) ~= nil, settlers_lines[edict_idx])
end

check("people: housing cap (300) present", settlers_all:find("300", 1, true) ~= nil)
check("people: avg tier (2.50) present", settlers_all:find("2.50", 1, true) ~= nil)

local tiers_idx = find_line(settlers_lines, "Plot Tiers:")
-- Kills: a tier line that stops at T4. write_shplots owns t1..t5 (GMCP's
-- record carries h5), and Plots: above comes from SETTLERX, which counts all
-- five tiers -- so omitting T5 renders a plot count the tier row cannot
-- account for.
check("people: Plot Tiers row present with T1:4  T2:3  T3:2  T5:1 (T4 omitted since 0)",
      tiers_idx ~= nil and settlers_lines[tiers_idx]:find("T1:4", 1, true) ~= nil
      and settlers_lines[tiers_idx]:find("T2:3", 1, true) ~= nil
      and settlers_lines[tiers_idx]:find("T3:2", 1, true) ~= nil
      and settlers_lines[tiers_idx]:find("T5:1", 1, true) ~= nil
      and settlers_lines[tiers_idx]:find("T4:", 1, true) == nil, settlers_all)

-- Kills: summing only t1..t4 to decide whether to draw the row at all. A city
-- whose plots are all tier 5 has a nonzero Plots: count while the tier row
-- vanishes entirely -- the worse half of the same omission.
do
  local saved = S.settler_housing_plot_tiers
  S.settler_housing_plot_tiers = { t1 = 0, t2 = 0, t3 = 0, t4 = 0, t5 = 6 }
  local only5_lines = people_page.lines(WIDTH)
  local only5_idx = find_line(only5_lines, "Plot Tiers:")
  check("people: Plot Tiers row survives a tier-5-only city",
        only5_idx ~= nil
        and only5_lines[only5_idx]:find("T5:6", 1, true) ~= nil,
        table.concat(only5_lines, "\n"))
  S.settler_housing_plot_tiers = saved
end

check("people: housing upkeep (15) and community upkeep (8) present",
      settlers_all:find("Housing Upkeep: 15", 1, true) ~= nil
      and settlers_all:find("Community Upkeep: 8", 1, true) ~= nil, settlers_all)
check("people: jobs/employed/staffed (30/25/3) present",
      settlers_all:find("Jobs: 30", 1, true) ~= nil
      and settlers_all:find("Employed: 25", 1, true) ~= nil
      and settlers_all:find("Market Staffed: 3", 1, true) ~= nil, settlers_all)

-- Exact metric-bar assertion for Mood (82%): pagelib.bar(20, 82, 100, pct_color(82,100)).
local expected_mood_bar = pagelib.bar(20, 82, 100, pagelib.pct_color(82, 100))
check("people: Mood bar matches pagelib.bar(20, 82, 100, pct_color) exactly",
      settlers_all:find(expected_mood_bar, 1, true) ~= nil, settlers_all)
check("people: Security (90%) present", settlers_all:find("90%%", 1) ~= nil, settlers_all)

local sent_idx = find_line(settlers_lines, "Sentiment:")
check("people: Sentiment row present (+5, decaying)",
      sent_idx ~= nil and settlers_lines[sent_idx]:find("+5", 1, true) ~= nil
      and settlers_lines[sent_idx]:find("decaying", 1, true) ~= nil, settlers_all)

check("people: Flourishing: Yes present", settlers_all:find("Flourishing:", 1, true) ~= nil
      and settlers_all:find("Yes", 1, true) ~= nil)

check("people: Community Net (+120/tick) and Mood Mult (x1.50) present",
      settlers_all:find("+120/tick", 1, true) ~= nil and settlers_all:find("x1.50", 1, true) ~= nil,
      settlers_all)

check("people: Civic Buildings names Mead Hall T2 (well T0 omitted)",
      settlers_all:find("Mead Hall T2", 1, true) ~= nil, settlers_all)

check("people: stock line shows Bread (20) and Salted Fish (10)",
      settlers_all:find("20", 1, true) ~= nil and settlers_all:find("Salted Fish:", 1, true) ~= nil
      and settlers_all:find("10", 1, true) ~= nil, settlers_all)

local spoils_idx = find_line(settlers_lines, "Spoils:")
check("people: Spoils row present (3, colored since > 0)",
      spoils_idx ~= nil and settlers_lines[spoils_idx]:find("3", 1, true) ~= nil, settlers_all)

check("people: Consumption/tick lists grain:-6 and water:-4",
      settlers_all:find("Grain", 1, true) ~= nil and settlers_all:find(":-6", 1, true) ~= nil
      and settlers_all:find("Water", 1, true) ~= nil and settlers_all:find(":-4", 1, true) ~= nil,
      settlers_all)

check("people: Supply Tick (5m) and Pop Tick (10m) present",
      settlers_all:find("Supply Tick: ", 1, true) ~= nil and settlers_all:find("5m", 1, true) ~= nil
      and settlers_all:find("Pop Tick: ", 1, true) ~= nil and settlers_all:find("10m", 1, true) ~= nil,
      settlers_all)

check("people: Actions lists Assembly 1m30s", settlers_all:find("Assembly 1m30s", 1, true) ~= nil,
      settlers_all)

check("people: settler project names Longhouse T1 -> T2",
      settlers_all:find("Longhouse T1 %-> T2") ~= nil, settlers_all)
check("people: settler project shows daler cost (50)",
      settlers_all:find("Cost: 50 daler", 1, true) ~= nil, settlers_all)
check("people: settler project mat_detail row for timber (4/10)",
      settlers_all:find("[Tt]imber", 1) ~= nil and settlers_all:find("4/10", 1, true) ~= nil, settlers_all)

-- ---- Designations subsection --------------------------------------------
check("people: Designations header present", find_line(settlers_lines, "Designations") ~= nil)
check("people: Identity (Builders' Hold) present", settlers_all:find("Builders' Hold", 1, true) ~= nil)
-- smidir (Builders) is a cost/time-REDUCTION role (LEGACY's eff_neg table),
-- so its bonus renders with a minus sign, not a plus.
check("people: Builders role row (55% target, -8% Bld effect since smidir is a reduction role)",
      settlers_all:find("Builders", 1, true) ~= nil and settlers_all:find(">>55%%", 1) ~= nil
      and settlers_all:find("%-8%% Bld", 1) ~= nil, settlers_all)
check("people: Farmers role row present (no target arrow, cur==tgt)",
      settlers_all:find("Farmers", 1, true) ~= nil)
check("people: Commoners row present (12%, muted, idle)",
      settlers_all:find("Commoners", 1, true) ~= nil and settlers_all:find("idle", 1, true) ~= nil)
check("people: legend text present", settlers_all:find("green %+gain    red %-cost/time") ~= nil,
      settlers_all)

page_opts.set("show_people_designations", false)
local no_desig = people_page.lines(WIDTH)
check("people: Designations header disappears when show_people_designations is off",
      find_line(no_desig, "Designations") == nil)
check("people: Settlers header stays when only Designations is off",
      find_line(no_desig, "Settlers") ~= nil)
page_opts.set("show_people_designations", true)

page_opts.set("show_people_settlers", false)
local no_settlers = people_page.lines(WIDTH)
check("people: Settlers header disappears when show_people_settlers is off",
      find_line(no_settlers, "Settlers") == nil)
check("people: Designations (nested) disappears too", find_line(no_settlers, "Designations") == nil)
page_opts.set("show_people_settlers", true)

-- ---- "no settlers yet" fallback -----------------------------------------
do
  local saved = S.settlers
  S.settlers = 0
  local zero_lines = people_page.lines(WIDTH)
  check("people: 'No settlers yet' fallback shown when settlers == 0",
        find_line(zero_lines, "No settlers yet") ~= nil, joined(zero_lines))
  S.settlers = saved
end

-- =============================================================================
-- Biome Patrol -- UNGATED section (no page_opts key; source-only condition)
-- =============================================================================

S.patrol = { count = 3, remaining = 45 }
local patrol_lines_on = people_page.lines(WIDTH)
check("people: Biome Patrol header present when state.patrol.count > 0",
      find_line(patrol_lines_on, "Biome Patrol") ~= nil)
-- (a RESET escape sits between the dim label and the value in pagelib.kv's
-- output, so match each half independently rather than one contiguous
-- pattern -- same idiom as pages1/pages2's tests.)
do
  local hird_idx = find_line(patrol_lines_on, "Hirdmadrs:")
  local time_idx = find_line(patrol_lines_on, "Time:")
  check("people: Biome Patrol shows Hirdmadrs (3)",
        hird_idx ~= nil and patrol_lines_on[hird_idx]:find("3", 1, true) ~= nil, joined(patrol_lines_on))
  check("people: Biome Patrol shows Time (45s)",
        time_idx ~= nil and patrol_lines_on[time_idx]:find("45s", 1, true) ~= nil, joined(patrol_lines_on))
end

-- Turning EVERY page_opts gate off does not hide Biome Patrol -- it has none.
page_opts.set("show_people_settlers", false)
page_opts.set("show_people_garrison", false)
page_opts.set("show_people_raids", false)
page_opts.set("show_people_thralls", false)
page_opts.set("show_people_missions", false)
check("people: Biome Patrol survives every OTHER gate being off (it has no gate of its own)",
      find_line(people_page.lines(WIDTH), "Biome Patrol") ~= nil)
page_opts.set("show_people_settlers", true)
page_opts.set("show_people_garrison", true)
page_opts.set("show_people_raids", true)
page_opts.set("show_people_thralls", true)
page_opts.set("show_people_missions", true)

do
  S.patrol = { count = 0, remaining = 0 }
  check("people: Biome Patrol absent when patrol.count == 0",
        find_line(people_page.lines(WIDTH), "Biome Patrol") == nil)
end

-- =============================================================================
-- Garrison (show_people_garrison), including hird_list + Varangian Guards
-- =============================================================================

S.garrison_stationed = 8
S.garrison_free = 2
S.garrison_cap = 10
S.garrison_defpower = 55
S.hird_list = {
  { name = "Ragnar", status = "personal_guard", level = 6, atk = 7, def = 5,
    loyalty = 4, age_phase = "veteran", mode = "offensive", champ = 1, wpn = 3, arm = 2 },
}
S.varang_out = { { name = "Skoll's Band", count = 12, expires_in = 3661 } }
S.varang_in = { { name = "Ingvar's Reinforcements", count = 6, expires_in = 120 } }

local garrison_lines = people_page.lines(WIDTH)
local garrison_all = joined(garrison_lines)

check("people: Garrison header present", find_line(garrison_lines, "Garrison") ~= nil)
check("people: Stationed 8 / 10, Free 2, Total 10 present",
      garrison_all:find("8 / 10", 1, true) ~= nil and garrison_all:find("Free: 2", 1, true) ~= nil
      and garrison_all:find("Total: 10", 1, true) ~= nil, garrison_all)
check("people: Def power (55) present", garrison_all:find("Def power:", 1, true) ~= nil
      and garrison_all:find("55", 1, true) ~= nil, garrison_all)

local ragnar_idx = find_line(garrison_lines, "Ragnar")
check("people: hird row for Ragnar present", ragnar_idx ~= nil, garrison_all)
if ragnar_idx then
  local row = garrison_lines[ragnar_idx]
  check("people: Ragnar shows champion tag [C]", row:find("%[C%]") ~= nil, row)
  check("people: Ragnar shows loyalty (Loyal, index 4)", row:find("Loyal", 1, true) ~= nil, row)
  check("people: Ragnar shows age (Veteran)", row:find("Veteran", 1, true) ~= nil, row)
  check("people: Ragnar shows level (Lv6)", row:find("Lv6", 1, true) ~= nil, row)
  check("people: Ragnar shows gear tag (W3/A2)", row:find("W3/A2", 1, true) ~= nil, row)
  check("people: Ragnar shows status (Guard)", row:find("Guard", 1, true) ~= nil, row)
  check("people: Ragnar shows mode (Offensive)", row:find("Offensive", 1, true) ~= nil, row)
end

check("people: Varangian Guards header present", find_line(garrison_lines, "Varangian Guards") ~= nil)
check("people: dispatched contract (Skoll's Band, 12 men, 1h1m left) present",
      garrison_all:find("Skoll's Band", 1, true) ~= nil and garrison_all:find("12 men", 1, true) ~= nil
      and garrison_all:find("1h1m left", 1, true) ~= nil, garrison_all)
check("people: received contract (Ingvar's Reinforcements, 6 men, 2m left) present",
      garrison_all:find("Ingvar's Reinforcements", 1, true) ~= nil
      and garrison_all:find("6 men", 1, true) ~= nil and garrison_all:find("2m left", 1, true) ~= nil,
      garrison_all)

page_opts.set("show_people_garrison", false)
local no_garrison = people_page.lines(WIDTH)
check("people: Garrison header disappears when show_people_garrison is off",
      find_line(no_garrison, "Garrison") == nil)
check("people: Varangian Guards also disappears (nested inside the garrison gate)",
      find_line(no_garrison, "Varangian Guards") == nil)
page_opts.set("show_people_garrison", true)

-- "No hirdmadrs" fallback.
do
  local saved_st, saved_fr, saved_hl = S.garrison_stationed, S.garrison_free, S.hird_list
  S.garrison_stationed, S.garrison_free, S.hird_list = 0, 0, {}
  check("people: 'No hirdmadrs' fallback shown when garrison and hird_list are empty",
        find_line(people_page.lines(WIDTH), "No hirdmadrs") ~= nil)
  S.garrison_stationed, S.garrison_free, S.hird_list = saved_st, saved_fr, saved_hl
end

-- =============================================================================
-- Incoming Raids (show_people_raids)
-- =============================================================================

S.raid_in = 200
S.raid_faction = "Skalgrim Reavers"
S.raid_strength = 80

local raids_lines_l = people_page.lines(WIDTH)
local raids_all = joined(raids_lines_l)
check("people: Incoming Raids header present", find_line(raids_lines_l, "Incoming Raids") ~= nil)
check("people: raid arrival (3m 20s) present", raids_all:find("3m 20s", 1, true) ~= nil, raids_all)
check("people: raid faction (Skalgrim Reavers) present",
      raids_all:find("Skalgrim Reavers", 1, true) ~= nil)
check("people: raid strength (80) present vs garrison_defpower (55) -> dangerous color",
      raids_all:find("Strength: ", 1, true) ~= nil and raids_all:find("80", 1, true) ~= nil, raids_all)

do
  local saved = S.raid_in
  S.raid_in = -1
  check("people: 'No raid currently scheduled' shown when raid_in < 0",
        find_line(people_page.lines(WIDTH), "No raid currently scheduled") ~= nil)
  S.raid_in = saved
end

page_opts.set("show_people_raids", false)
check("people: Incoming Raids header disappears when show_people_raids is off",
      find_line(people_page.lines(WIDTH), "Incoming Raids") == nil)
page_opts.set("show_people_raids", true)

-- =============================================================================
-- Thralls (show_people_thralls) + Companion (show_people_thrall_companion)
-- =============================================================================

S.thralls = 14
S.thrall_assignments = { longhouse = 3, warehouse = 2 }
S.thrall_follower_level = 4
S.thrall_follower_name = "grimna"
S.thrall_follower_xp = 120
S.thrall_follower_xp_cap = 400
S.thrall_follower_carry_used = 10
S.thrall_follower_carry_cap = 40
S.thrall_follower_status = "following"

page_opts.set("show_people_thrall_companion", true)

local thralls_lines_l = people_page.lines(WIDTH)
local thralls_all = joined(thralls_lines_l)

check("people: Thralls header present", find_line(thralls_lines_l, "Thralls") ~= nil)
check("people: Held (14) and Working (5) present",
      thralls_all:find("Held: 14", 1, true) ~= nil and thralls_all:find("Working: 5", 1, true) ~= nil,
      thralls_all)
check("people: per-building assignment rows for Longhouse (3) and Warehouse (2)",
      thralls_all:find("Longhouse: 3", 1, true) ~= nil and thralls_all:find("Warehouse: 2", 1, true) ~= nil,
      thralls_all)

check("people: Companion row present (Grimna, Lv4, Following)",
      thralls_all:find("Grimna", 1, true) ~= nil and thralls_all:find("Lv4", 1, true) ~= nil
      and thralls_all:find("Following", 1, true) ~= nil, thralls_all)
check("people: Companion XP (120/400) present", thralls_all:find("XP: 120/400", 1, true) ~= nil,
      thralls_all)
check("people: Companion Carry (10/40) present", thralls_all:find("Carry: 10/40", 1, true) ~= nil,
      thralls_all)

local expected_lvl_bar = pagelib.bar(WIDTH - 12, 120, 400, C.bright_green)
check("people: Companion level bar matches pagelib.bar exactly",
      find_line(thralls_lines_l, "    Level: " .. expected_lvl_bar) ~= nil, thralls_all)

page_opts.set("show_people_thrall_companion", false)
local no_companion = people_page.lines(WIDTH)
check("people: Companion row disappears when show_people_thrall_companion is off",
      find_line(no_companion, "Companion:") == nil)
check("people: Thralls header stays when only the companion opt is off",
      find_line(no_companion, "Thralls") ~= nil)
page_opts.set("show_people_thrall_companion", true)

page_opts.set("show_people_thralls", false)
check("people: Thralls header disappears when show_people_thralls is off",
      find_line(people_page.lines(WIDTH), "Thralls") == nil)
page_opts.set("show_people_thralls", true)

-- Section vanishes entirely when both thralls==0 and follower_level==0, even
-- with the opt on (LEGACY's own extra guard around the section, 10392).
do
  local st, sfl = S.thralls, S.thrall_follower_level
  S.thralls, S.thrall_follower_level = 0, 0
  check("people: Thralls section absent when thralls==0 and no companion",
        find_line(people_page.lines(WIDTH), "Thralls") == nil)
  S.thralls, S.thrall_follower_level = st, sfl
end

-- =============================================================================
-- Missions (show_people_missions)
-- =============================================================================

S.missions = {
  {
    id = 7, label = "Deliver grain to Holmgard", expires_in = 1800,
    origin_town = "Vestergotland", target_town = "Holmgard",
    reward = 200, reward_rep = 15, want_goods = { grain = 30 },
  },
}
S.errand = {
  id = 99, label = "Fetch water", expires_in = 5400,
  origin_town = "", target_town = "Holmgard",
  reward = 0, reward_good = "water", reward_qty = 10,
}
S.mission_reg_left = 2
S.mission_new_left = 0

local missions_lines_l = people_page.lines(WIDTH)
local missions_all = joined(missions_lines_l)

check("people: Missions header present", find_line(missions_lines_l, "Missions") ~= nil)
check("people: Missions left (2) and Errands left (0) present",
      missions_all:find("Missions left: ", 1, true) ~= nil and missions_all:find("2", 1, true) ~= nil
      and missions_all:find("Errands left: ", 1, true) ~= nil, missions_all)
check("people: mission [7] label present", missions_all:find("%[7%] Deliver grain to Holmgard") ~= nil,
      missions_all)
check("people: mission town line (Vestergotland -> Holmgard) present",
      missions_all:find("Vestergotland %-> Holmgard") ~= nil, missions_all)
check("people: mission reward (+200 daler, +15 rep) present",
      missions_all:find("+200 daler", 1, true) ~= nil and missions_all:find("+15 rep", 1, true) ~= nil,
      missions_all)
check("people: mission want_goods (Need 30 Grain) present",
      missions_all:find("Need 30 Grain", 1, true) ~= nil, missions_all)

check("people: errand [99] label present", missions_all:find("%[99%] Errand: Fetch water") ~= nil,
      missions_all)
check("people: errand town line (-> Holmgard, no origin) present",
      missions_all:find("%-> Holmgard") ~= nil, missions_all)
check("people: errand reward_good (+10 Water) present", missions_all:find("+10 Water", 1, true) ~= nil,
      missions_all)

page_opts.set("show_people_missions", false)
check("people: Missions header disappears when show_people_missions is off",
      find_line(people_page.lines(WIDTH), "Missions") == nil)
page_opts.set("show_people_missions", true)

-- "No active missions" fallback (timers present, no missions/errand).
do
  local sm, se = S.missions, S.errand
  S.missions, S.errand = {}, nil
  check("people: 'No active missions' shown when timers are known but nothing is active",
        find_line(people_page.lines(WIDTH), "No active missions") ~= nil)
  S.missions, S.errand = sm, se
end

-- Section vanishes entirely with no missions/errand AND no timers.
do
  local sm, se, sr, sn = S.missions, S.errand, S.mission_reg_left, S.mission_new_left
  S.missions, S.errand, S.mission_reg_left, S.mission_new_left = {}, nil, -1, -1
  check("people: Missions section absent with nothing active and no timers",
        find_line(people_page.lines(WIDTH), "Missions") == nil)
  S.missions, S.errand, S.mission_reg_left, S.mission_new_left = sm, se, sr, sn
end

-- =============================================================================
-- Task 6: mission/errand "Run There" buttons -- appearance (BGR workbook),
-- click dispatch (byte-exact mud.send strings), the disabled-button-sends-
-- nothing case, and the errand-return path reaching Task 5's POI machinery
-- at the correct index.
-- =============================================================================
do
  local function find_target(targets, row)
    for _, t in ipairs(targets) do
      if t.row == row then return t end
    end
    return nil
  end

  local saved_wstock = S.wstock
  local saved_missions, saved_errand = S.missions, S.errand
  local saved_vmap = {
    w = S.vmap_w, h = S.vmap_h, rows = S.vmap_rows,
    east_edges = S.vmap_east_edges, pois = S.vmap_pois,
    px = S.vmap_px, py = S.vmap_py,
  }

  -- A tiny 4x1 all-passable strip: Uppsala(0,0) decoy/start, Vestergotland
  -- (1,0) lineage/origin, Holmgard(3,0) capital/target -- three distinct
  -- coordinates so a wrong pick (decoy vs origin vs target) is always a
  -- different, distinguishable send count/sequence.
  local function seed_map(px, py)
    S.vmap_w, S.vmap_h = 4, 1
    S.vmap_rows = { "pppp" }
    S.vmap_east_edges = { "111" }
    S.vmap_pois = {
      { type = "lineage", name = "Uppsala", x = 0, y = 0, owner = "" },
      { type = "lineage", name = "Vestergotland", x = 1, y = 0, owner = "" },
      { type = "capital", name = "Holmgard", x = 3, y = 0, owner = "" },
    }
    S.vmap_px, S.vmap_py = px, py
  end

  S.missions = {
    { id = 7, label = "Deliver grain to Holmgard", expires_in = 1800,
      origin_town = "Vestergotland", target_town = "Holmgard",
      reward = 200, reward_rep = 15, want_goods = { grain = 30 } },
  }
  S.errand = nil

  -- ---- appearance + click: SUFFICIENT goods (enabled, bright_green) -------
  S.wstock = { { good = "grain", amount = 100, freshness_pct = 100 } }
  seed_map(0, 0) -- away from Holmgard (3,0): a real 3-step trip
  send_calls = {}
  local lines_en, targets_en = people_page.lines(WIDTH)
  local btn_row_en = find_line(lines_en, "Run There")
  check("people: mission button row present (sufficient goods)", btn_row_en ~= nil)
  check("people: mission button BGR workbook -- sufficient -> bright_green (0xCCFFCC: B=CC,G=FF,R=CC)",
        lines_en[btn_row_en]:find(C.bright_green, 1, true) ~= nil, lines_en[btn_row_en])
  local target_en = find_target(targets_en, btn_row_en)
  check("people: enabled mission button has a recorded target", target_en ~= nil)
  target_en.action()
  check("people: enabled mission click (real route) sends dirs then enter, no fulfill",
        #send_calls == 4 and send_calls[1] == "east" and send_calls[2] == "east"
        and send_calls[3] == "east" and send_calls[4] == "enter",
        table.concat(send_calls, ","))

  -- ---- click: SUFFICIENT goods, ALREADY AT target (path == {}) -----------
  seed_map(3, 0) -- exactly at Holmgard
  send_calls = {}
  target_en.action()
  check("people: enabled mission click (already at target) sends enter + vmission fulfill",
        #send_calls == 2 and send_calls[1] == "enter" and send_calls[2] == "vmission fulfill 7",
        table.concat(send_calls, ","))

  -- ---- appearance + click: INSUFFICIENT goods (disabled, dim) ------------
  S.wstock = { { good = "grain", amount = 10, freshness_pct = 100 } } -- need 30
  seed_map(0, 0)
  send_calls = {}
  local lines_dis, targets_dis = people_page.lines(WIDTH)
  local btn_row_dis = find_line(lines_dis, "Run There")
  check("people: mission button row present (insufficient goods)", btn_row_dis ~= nil)
  check("people: mission button BGR workbook -- insufficient -> dim (0x888888: B=88,G=88,R=88)",
        lines_dis[btn_row_dis]:find(C.dim, 1, true) ~= nil, lines_dis[btn_row_dis])
  -- M4: the discriminating assertion is the ABSENCE of a target -- "sends
  -- nothing" after a render with no click ever performed is decorative
  -- (there is nothing to send from in the first place; it would pass even
  -- if `has_sufficient_goods` were entirely broken).
  check("people: disabled mission button has NO recorded target (not clickable)",
        find_target(targets_dis, btn_row_dis) == nil)

  S.wstock = saved_wstock

  -- ---- I4: has_sufficient_goods mutation coverage (MAIN 4817-4839) --------
  do
    -- (a) SUMS across multiple wstock rows for the same good, rather than
    -- reading a single row's amount -- two rows of 15 grain each, summing
    -- to exactly the needed 30. A mutation that replaced the running sum
    -- with the last-seen row's amount alone would still see 15 (< 30) and
    -- wrongly disable the button.
    S.wstock = {
      { good = "grain", amount = 15, freshness_pct = 100 },
      { good = "grain", amount = 15, freshness_pct = 100 },
    }
    local lines_sum = people_page.lines(WIDTH)
    local row_sum = find_line(lines_sum, "Run There")
    check("people: I4a has_sufficient_goods SUMS multiple wstock rows for the same good (15+15 >= 30)",
          row_sum ~= nil and lines_sum[row_sum]:find(C.bright_green, 1, true) ~= nil,
          row_sum and lines_sum[row_sum])

    -- (b) BOUNDARY: have == needed is SUFFICIENT. LEGACY's own comparison
    -- is `if have_qty < needed_qty then return false` -- equal is not
    -- less, so it passes; a mutation to `<=` would wrongly disable this
    -- exact-match case.
    S.wstock = { { good = "grain", amount = 30, freshness_pct = 100 } }
    local lines_eq = people_page.lines(WIDTH)
    local row_eq = find_line(lines_eq, "Run There")
    check("people: I4b has_sufficient_goods boundary -- have == needed (30 == 30) is SUFFICIENT",
          row_eq ~= nil and lines_eq[row_eq]:find(C.bright_green, 1, true) ~= nil,
          row_eq and lines_eq[row_eq])

    -- (c) LEGACY's early-return guard has THREE disjunct sub-conditions
    -- (MAIN 4818: `not want_goods or type(want_goods) ~= "table" or
    -- not next(want_goods)`). Two are fixtured below, each with an EMPTY
    -- warehouse (S.wstock = {}); both catch a mutation that flips the
    -- guard's own `return true` to `return false` (verified: reverted
    -- after confirming).
    --
    -- The empty-table fixture (c2) does NOT independently pin the guard's
    -- `not next(want_goods)` sub-condition on its own, though -- dropping
    -- ONLY that sub-condition (leaving `not want_goods or type(...) ~=
    -- "table"`) is an EQUIVALENT MUTANT for an empty table: `{}` is still
    -- a table, so the guard's remaining conditions don't fire, but the
    -- function falls through to `for good, needed_qty in pairs(want_
    -- goods) do ... end`, which iterates ZERO times over an empty table
    -- and reaches the function's own trailing `return true` regardless
    -- (verified: applying just that mutation leaves this suite green).
    -- Kept anyway -- it still documents and exercises the empty-table
    -- INPUT LEGACY's guard names, and it does catch the broader
    -- return-true/false flip above; it just isn't the mutation that
    -- specific sub-condition alone would need to be pinned by.
    --
    -- The THIRD sub-condition (`type(want_goods) ~= "table"`, a non-table
    -- value) is NOT independently fixtured here: `mission_lines`' OWN
    -- want_goods display loop a few lines below (`sorted_keys(m.want_
    -- goods)` -> `pairs(t or {})`) calls `pairs()` on the same value
    -- unconditionally, which raises on a non-table just as LEGACY's own
    -- `for g, q in pairs(m.want_goods) do` display loop would -- this is
    -- a pre-existing shared fragility between the guard and the display
    -- code, not something Task 6 introduced, and the MISSIONS wire parser
    -- (handlers/city.lua) always builds a table, so a non-table
    -- want_goods is not a state this port's own rendering path can reach
    -- in practice. Testing it would require exporting
    -- `has_sufficient_goods` solely for this one fixture, bypassing the
    -- page's real rendering entry point -- not worth the added surface
    -- for a defensive branch neither LEGACY nor this port's display code
    -- can survive past anyway.
    S.wstock = {}
    local saved_missions_i4c = S.missions
    local function check_i4c_arm(name, want_goods_value)
      S.missions = {
        { id = 8, label = "No goods needed", expires_in = 1800,
          origin_town = "Vestergotland", target_town = "Holmgard",
          reward = 50, reward_rep = 0, want_goods = want_goods_value },
      }
      local lines_arm = people_page.lines(WIDTH)
      local row_arm = find_line(lines_arm, "Run There")
      check("people: I4c has_sufficient_goods, " .. name .. ", is SUFFICIENT (empty wstock)",
            row_arm ~= nil and lines_arm[row_arm]:find(C.bright_green, 1, true) ~= nil,
            row_arm and lines_arm[row_arm])
    end
    -- (c1) ABSENT (nil) want_goods -- `not want_goods`.
    check_i4c_arm("absent (nil) want_goods", nil)
    -- (c2) EMPTY table want_goods -- `not next(want_goods)`.
    check_i4c_arm("empty-table want_goods", {})
    S.missions = saved_missions_i4c
    S.wstock = saved_wstock
  end

  -- ---- errand button: normal path, return-and-submit reaches the RIGHT ---
  -- origin index (distinguishable send counts prove items[town_index] was
  -- the pick, not the decoy or the target itself).
  S.missions = {}
  S.errand = {
    id = 99, label = "Fetch water", expires_in = 5400,
    origin_town = "Vestergotland", target_town = "Holmgard",
    reward = 0, reward_good = "water", reward_qty = 10,
  }
  seed_map(0, 0)
  send_calls = {}
  local lines_er, targets_er = people_page.lines(WIDTH)
  local btn_row_er = find_line(lines_er, "Run There")
  check("people: errand button row present", btn_row_er ~= nil)
  check("people: errand button BGR workbook -- always enabled -> bright_green",
        lines_er[btn_row_er]:find(C.bright_green, 1, true) ~= nil, lines_er[btn_row_er])
  local target_er = find_target(targets_er, btn_row_er)
  check("people: errand button has a recorded target (always travelable)", target_er ~= nil)
  target_er.action()
  check("people: errand click reaches errand_return_and_submit at the CORRECT origin index "
        .. "(Vestergotland, 1 step) -- not the decoy (Uppsala) or the target (Holmgard)",
        #send_calls == 9
        and send_calls[1] == "east" and send_calls[2] == "east" and send_calls[3] == "east"
        and send_calls[4] == "enter" and send_calls[5] == "vmission newbie fetch"
        and send_calls[6] == "leave"
        and send_calls[7] == "east"
        and send_calls[8] == "enter" and send_calls[9] == "vmission newbie submit",
        table.concat(send_calls, ","))

  -- ---- I5: errand button, ALREADY AT the target town (#path == 0) -------
  -- Both fixtures above (normal path, blank-origin fallback) only exercise
  -- errand_run_click's NON-empty-path branch. This pins the OTHER
  -- send-bearing branch (MAIN ~12194-12199): dropping `mud.send("leave")`
  -- from the #path==0 arm would survive every other errand test in this
  -- file. Holmgard(3,0) -> Vestergotland(1,0) is 2 "west" steps.
  S.errand = {
    id = 99, label = "Fetch water", expires_in = 5400,
    origin_town = "Vestergotland", target_town = "Holmgard",
    reward = 0, reward_good = "water", reward_qty = 10,
  }
  seed_map(3, 0) -- exactly at Holmgard (the errand's target)
  send_calls = {}
  local lines_at, targets_at = people_page.lines(WIDTH)
  local btn_row_at = find_line(lines_at, "Run There")
  local target_at_errand = find_target(targets_at, btn_row_at)
  check("people: errand button (already at target) has a recorded target", target_at_errand ~= nil)
  target_at_errand.action()
  check("people: errand click (already at target, #path==0) sends enter+fetch+LEAVE, "
        .. "then the return-and-submit sequence (origin Vestergotland is 2 steps back)",
        #send_calls == 7
        and send_calls[1] == "enter" and send_calls[2] == "vmission newbie fetch"
        and send_calls[3] == "leave"
        and send_calls[4] == "west" and send_calls[5] == "west"
        and send_calls[6] == "enter" and send_calls[7] == "vmission newbie submit",
        table.concat(send_calls, ","))

  -- ---- errand button: BLANK origin_town falls back to the first capital --
  -- (Holmgard) over the lineage towns (Uppsala/Vestergotland), matching
  -- viking_errand_return_and_submit's own capital-before-lineage fallback.
  -- Target town is Vestergotland here (NOT the capital) so the fallback's
  -- pick (Holmgard, 3 steps back) is distinguishable from "already there".
  S.errand = {
    id = 99, label = "Fetch water", expires_in = 5400,
    origin_town = "", target_town = "Vestergotland",
    reward = 0, reward_good = "water", reward_qty = 10,
  }
  seed_map(0, 0)
  send_calls = {}
  local lines_fb, targets_fb = people_page.lines(WIDTH)
  local btn_row_fb = find_line(lines_fb, "Run There")
  local target_fb = find_target(targets_fb, btn_row_fb)
  check("people: errand button (blank origin) has a recorded target", target_fb ~= nil)
  target_fb.action()
  check("people: blank-origin fallback picks the capital (Holmgard, 3 steps back) as the "
        .. "return destination, not the target town itself (0 steps) or the decoy",
        #send_calls == 9
        and send_calls[1] == "east" -- outward: to Vestergotland (target), 1 step
        and send_calls[2] == "enter" and send_calls[3] == "vmission newbie fetch"
        and send_calls[4] == "leave"
        and send_calls[5] == "east" and send_calls[6] == "east" and send_calls[7] == "east" -- return: to Holmgard
        and send_calls[8] == "enter" and send_calls[9] == "vmission newbie submit",
        table.concat(send_calls, ","))

  -- ---- errand button: blank target_town is a no-op (guarded) -------------
  S.errand = {
    id = 99, label = "Fetch water", expires_in = 5400,
    origin_town = "Vestergotland", target_town = "",
    reward = 0, reward_good = "water", reward_qty = 10,
  }
  seed_map(0, 0)
  send_calls = {}
  local lines_blank, targets_blank = people_page.lines(WIDTH)
  local btn_row_blank = find_line(lines_blank, "Run There")
  local target_blank = find_target(targets_blank, btn_row_blank)
  check("people: errand button (blank target_town) still has a recorded target "
        .. "(the button itself is unconditional; the GUARD is inside the click handler)",
        target_blank ~= nil)
  target_blank.action()
  check("people: clicking an errand with a blank target_town sends nothing", #send_calls == 0)

  S.wstock = saved_wstock
  S.missions, S.errand = saved_missions, saved_errand
  S.vmap_w, S.vmap_h = saved_vmap.w, saved_vmap.h
  S.vmap_rows, S.vmap_east_edges = saved_vmap.rows, saved_vmap.east_edges
  S.vmap_pois = saved_vmap.pois
  S.vmap_px, S.vmap_py = saved_vmap.px, saved_vmap.py
  send_calls = {}
end

-- =============================================================================
-- width discipline (every gate re-enabled, everything rendering at once)
-- =============================================================================
do
  local all_lines = people_page.lines(WIDTH)
  local width_ok, widest = true, nil
  for _, l in ipairs(all_lines) do
    local vw = pagelib.visible_width(l)
    if vw > WIDTH then width_ok = false; widest = vw end
  end
  check("people: every row's visible width is <= the requested width", width_ok, widest)
end

-- =============================================================================
-- pages/bonds.lua (Task 7) -- LEGACY draw_page8 (guild_viking.lua:12756-12831)
-- =============================================================================

S.hird_by_id = {
  [1] = { name = "Ragnar Ironside" },
  [2] = { name = "Skoll" },  -- single-word name: abbrev() returns it unabbreviated
}
S.bonds_list = {
  { id_a = 1, id_b = 2, ticks = 850000, tier = 3 },  -- 850000-600000 / (2160000-600000) = 16%
  { id_a = 3, id_b = 4, ticks = 30000, tier = 0 },   -- unknown ids -> "#3"/"#4"; 30000/50000 = 60%
}
page_opts.set("show_bonds_list", true)

local bonds_lines = bonds_page.lines(WIDTH)
local bonds_all = joined(bonds_lines)

check("bonds: Fellowship Bonds header present", find_line(bonds_lines, "Fellowship Bonds") ~= nil)

-- Strongest bond (tier 3, higher ticks) sorts first.
local pair1_idx = find_line(bonds_lines, "R. Ironside")
check("bonds: strongest pair (R. Ironside + Skoll) present and abbreviated",
      pair1_idx ~= nil and bonds_lines[pair1_idx]:find("Skoll", 1, true) ~= nil, bonds_all)
check("bonds: tier label Blood-Sworn present for tier 3", bonds_all:find("Blood%-Sworn") ~= nil, bonds_all)
check("bonds: tier-3 bar/percent matches pagelib.bar(24, 16, 100, C.cyan)",
      bonds_all:find(pagelib.bar(24, 16, 100, C.cyan), 1, true) ~= nil
      and bonds_all:find("16%%", 1) ~= nil, bonds_all)

check("bonds: unknown hird ids render as #3 / #4",
      bonds_all:find("#3", 1, true) ~= nil and bonds_all:find("#4", 1, true) ~= nil, bonds_all)
check("bonds: tier label Strangers present for tier 0", bonds_all:find("Strangers", 1, true) ~= nil)
check("bonds: tier-0 bar/percent matches pagelib.bar(24, 60, 100, C.dim)",
      bonds_all:find(pagelib.bar(24, 60, 100, C.dim), 1, true) ~= nil
      and bonds_all:find("60%%", 1) ~= nil, bonds_all)

-- Ordering: the tier-3 pair (higher ticks) must appear before the tier-0 pair.
do
  local i3 = find_line(bonds_lines, "R. Ironside")
  local i0 = find_line(bonds_lines, "#3")
  check("bonds: sorted by ticks descending (tier-3 pair before tier-0 pair)",
        i3 ~= nil and i0 ~= nil and i3 < i0, bonds_all)
end

do
  local empty_bonds = S.bonds_list
  S.bonds_list = {}
  check("bonds: 'No bonds data yet' shown when bonds_list is empty",
        find_line(bonds_page.lines(WIDTH), "No bonds data yet") ~= nil)
  S.bonds_list = empty_bonds
end

page_opts.set("show_bonds_list", false)
check("bonds: Fellowship Bonds header disappears when show_bonds_list is off",
      find_line(bonds_page.lines(WIDTH), "Fellowship Bonds") == nil)
page_opts.set("show_bonds_list", true)

do
  local all_lines = bonds_page.lines(WIDTH)
  local width_ok, widest = true, nil
  for _, l in ipairs(all_lines) do
    local vw = pagelib.visible_width(l)
    if vw > WIDTH then width_ok = false; widest = vw end
  end
  check("bonds: every row's visible width is <= the requested width", width_ok, widest)
end

-- =============================================================================
-- pages/ranks.lua (Task 7) -- LEGACY draw_page9 (guild_viking.lua:12832-13212)
-- =============================================================================

S.standings = {
  [1] = { name = "Own Lineage", score = 50, label = "Neutral", is_own = true },
  [2] = { name = "Rival Lineage", score = 620, label = "Allied", is_own = false },
  [3] = { name = "Foe Lineage", score = -350, label = "Feud", is_own = false },
}
page_opts.set("show_ranks_standings", true)

local standings_lines_l = ranks_page.lines(WIDTH)
local standings_all = joined(standings_lines_l)

check("ranks: Lineage Standings header present", find_line(standings_lines_l, "Lineage Standings") ~= nil)

-- Own lineage sorts first regardless of score.
do
  local own_idx = find_line(standings_lines_l, "Own Lineage")
  local rival_idx = find_line(standings_lines_l, "Rival Lineage")
  check("ranks: own lineage sorts before a higher-scoring rival",
        own_idx ~= nil and rival_idx ~= nil and own_idx < rival_idx, standings_all)
  check("ranks: own lineage row is marked with '*'",
        own_idx ~= nil and standings_lines_l[own_idx]:find("%* ") ~= nil, standings_all)
end

check("ranks: own lineage score (+50) present", standings_all:find("+50", 1, true) ~= nil, standings_all)
check("ranks: Allied rival (score +620, clamped bar) present",
      standings_all:find("Rival Lineage", 1, true) ~= nil and standings_all:find("+620", 1, true) ~= nil
      and standings_all:find("Allied", 1, true) ~= nil, standings_all)
check("ranks: Feud foe (score -350) present",
      standings_all:find("Foe Lineage", 1, true) ~= nil and standings_all:find("%-350") ~= nil
      and standings_all:find("Feud", 1, true) ~= nil, standings_all)

-- Exact bar assertion for the own-lineage row: score 50 -> normalized
-- (50 - (-500)) / 1000 = 55%.
check("ranks: own-lineage bar matches pagelib.bar(18, 550, 1000, C.yellow) exactly",
      standings_all:find(pagelib.bar(18, 550, 1000, C.yellow), 1, true) ~= nil, standings_all)

do
  local saved = S.standings
  S.standings = {}
  check("ranks: 'No standings data yet' shown when standings is empty",
        find_line(ranks_page.lines(WIDTH), "No standings data yet") ~= nil)
  S.standings = saved
end

page_opts.set("show_ranks_standings", false)
check("ranks: Lineage Standings header disappears when show_ranks_standings is off",
      find_line(ranks_page.lines(WIDTH), "Lineage Standings") == nil)
page_opts.set("show_ranks_standings", true)

-- ---- Village Trade Reputation --------------------------------------------

S.village_rep = {
  [2] = { name = "Holmgard", rep = 150, rank = 2, start_at = 100, next_at = 300 },  -- (150-100)/(300-100) = 25%
  [1] = { name = "Vestergotland", rep = 999, rank = 7, start_at = 500, next_at = 0 },  -- MAX rank
}
page_opts.set("show_ranks_village_rep", true)

local vrep_lines_l = ranks_page.lines(WIDTH)
local vrep_all = joined(vrep_lines_l)

check("ranks: Village Trade Reputation header present",
      find_line(vrep_lines_l, "Village Trade Reputation") ~= nil)

-- Sorted by lineage id ascending: id 1 (Vestergotland) before id 2 (Holmgard).
do
  local vester_idx = find_line(vrep_lines_l, "Vestergotland")
  local holm_idx = find_line(vrep_lines_l, "Holmgard")
  check("ranks: village rep sorted by lineage id ascending (Vestergotland before Holmgard)",
        vester_idx ~= nil and holm_idx ~= nil and vester_idx < holm_idx, vrep_all)
end

check("ranks: Holmgard shows rank Kaupmadur and progress 50/200",
      vrep_all:find("Holmgard", 1, true) ~= nil and vrep_all:find("Kaupmadur", 1, true) ~= nil
      and vrep_all:find("50/200", 1, true) ~= nil, vrep_all)
check("ranks: Vestergotland at max rank (Jarl) shows MAX",
      vrep_all:find("Vestergotland", 1, true) ~= nil and vrep_all:find("Jarl", 1, true) ~= nil
      and vrep_all:find("MAX", 1, true) ~= nil, vrep_all)

do
  local saved = S.village_rep
  S.village_rep = {}
  check("ranks: Village Trade Reputation section absent when village_rep is empty",
        find_line(ranks_page.lines(WIDTH), "Village Trade Reputation") == nil)
  S.village_rep = saved
end

page_opts.set("show_ranks_village_rep", false)
check("ranks: Village Trade Reputation header disappears when show_ranks_village_rep is off",
      find_line(ranks_page.lines(WIDTH), "Village Trade Reputation") == nil)
page_opts.set("show_ranks_village_rep", true)

do
  local all_lines = ranks_page.lines(WIDTH)
  local width_ok, widest = true, nil
  for _, l in ipairs(all_lines) do
    local vw = pagelib.visible_width(l)
    if vw > WIDTH then width_ok = false; widest = vw end
  end
  check("ranks: every row's visible width is <= the requested width", width_ok, widest)
end

-- =============================================================================
-- pages/court.lua (Task 7) -- LEGACY draw_page_court (guild_viking.lua:13236-13304)
-- =============================================================================

check("court: 'No court data' fallback shown when state.dynasty is nil",
      find_line(court_page.lines(WIDTH), "No court data") ~= nil)

S.dynasty = {
  realm = "Norvik", house = "Ulfsson",
  spouse = { name = "Astrid", house = "Ulfsson", age = 34, rank = 2 },
  heir = "Bjorn",
  living = 2, cap = 4,
  children = {
    { name = "Bjorn", gender = "male", age = 16, adult = true, trait = "bold", role = "warrior" },
    { name = "Freya", gender = "female", age = 8, adult = false, trait = "", role = nil },
  },
}
page_opts.set("show_court_consort", true)
page_opts.set("show_court_children", true)

local court_lines = court_page.lines(WIDTH)
local court_all = joined(court_lines)

check("court: realm/house title present", find_line(court_lines, "Norvik") ~= nil
      and court_all:find("House Ulfsson", 1, true) ~= nil, court_all)

check("court: Consort header present", find_line(court_lines, "Consort") ~= nil)
check("court: spouse name (Astrid) and house/age (Ulfsson, age 34) present",
      court_all:find("Astrid", 1, true) ~= nil and court_all:find("House Ulfsson", 1, true) ~= nil
      and court_all:find("age 34", 1, true) ~= nil, court_all)
check("court: lineage-match description present (rank == 2)",
      court_all:find("lineage match %-%- their house rides with you, %+2 heirs") ~= nil, court_all)

check("court: Children header shows living/cap (2 / 4)",
      find_line(court_lines, "Children") ~= nil and court_all:find("2 / 4", 1, true) ~= nil, court_all)
check("court: children living/cap bar matches pagelib.bar(20, 2, 4, C.green) exactly",
      court_all:find(pagelib.bar(20, 2, 4, C.green), 1, true) ~= nil, court_all)

local bjorn_idx = find_line(court_lines, "Bjorn")
check("court: heir row (Bjorn) present with meta and [HEIR] tag",
      bjorn_idx ~= nil and court_lines[bjorn_idx]:find("male, age 16, bold, warrior", 1, true) ~= nil
      and court_lines[bjorn_idx]:find("%[HEIR%]") ~= nil, court_all)

local freya_idx = find_line(court_lines, "Freya")
check("court: non-adult non-heir row (Freya) present with 'child' tag",
      freya_idx ~= nil and court_lines[freya_idx]:find("female, age 8", 1, true) ~= nil
      and court_lines[freya_idx]:find("child", 1, true) ~= nil
      and court_lines[freya_idx]:find("%[HEIR%]") == nil, court_all)

-- ---- Consort gate + unmarried fallback -----------------------------------

page_opts.set("show_court_consort", false)
local no_consort = court_page.lines(WIDTH)
check("court: Consort header disappears when show_court_consort is off",
      find_line(no_consort, "Consort") == nil)
check("court: Children header stays when only Consort is off",
      find_line(no_consort, "Children") ~= nil)
page_opts.set("show_court_consort", true)

do
  local saved_spouse = S.dynasty.spouse
  S.dynasty.spouse = nil
  local unmarried = court_page.lines(WIDTH)
  check("court: empty-seat prompt shown when unmarried",
        find_line(unmarried, "The seat beside you is empty.") ~= nil, joined(unmarried))
  check("court: 'vcourt wed' hint present when unmarried",
        joined(unmarried):find("vcourt wed lineage", 1, true) ~= nil, joined(unmarried))
  S.dynasty.spouse = saved_spouse
end

-- ---- Children gate + no-children fallback --------------------------------

page_opts.set("show_court_children", false)
local no_children = court_page.lines(WIDTH)
check("court: Children header disappears when show_court_children is off",
      find_line(no_children, "Children") == nil)
check("court: Consort header stays when only Children is off",
      find_line(no_children, "Consort") ~= nil)
page_opts.set("show_court_children", true)

do
  local saved_kids, saved_living = S.dynasty.children, S.dynasty.living
  S.dynasty.children, S.dynasty.living = {}, 0
  check("court: '(none yet)' shown when the children list is empty",
        find_line(court_page.lines(WIDTH), "(none yet)") ~= nil)
  S.dynasty.children, S.dynasty.living = saved_kids, saved_living
end

do
  local all_lines = court_page.lines(WIDTH)
  local width_ok, widest = true, nil
  for _, l in ipairs(all_lines) do
    local vw = pagelib.visible_width(l)
    if vw > WIDTH then width_ok = false; widest = vw end
  end
  check("court: every row's visible width is <= the requested width", width_ok, widest)
end

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING PAGES3 TESTS PASSED")
