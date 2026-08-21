-- guild_viking window/tab-bar unit tests. Run from the lera-plugins repo
-- root with LERA_ROOT pointing at a built Lera checkout.
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
local function make_rect(x, y, w, h)
  return {
    x = function() return x end, y = function() return y end,
    w = function() return w end, h = function() return h end,
  }
end

local dirty_count = 0
local drawn -- { ansi = {...}, texts = {...} }, reset per case that cares
local function reset_drawn() drawn = { ansi = {}, texts = {} } end
reset_drawn()

ui = {
  dirty = function() dirty_count = dirty_count + 1 end,
  rect = function(x, y, w, h) return make_rect(x, y, w, h) end,
  text = function(r, s) drawn.texts[#drawn.texts + 1] = { x = r:x(), y = r:y(), s = s } end,
  text_ansi = function(r, s) drawn.ansi[#drawn.ansi + 1] = { x = r:x(), y = r:y(), s = s } end,
}

local render_pass = "local"
lera = { render_pass = function() return render_pass end }

local window = require("window")

-- Snapshot the real page modules right after requiring window, before any
-- later section in this file replaces find_page("stats").mod /
-- find_page("city").mod with fake { lines = ... } tables for windowing-math
-- tests -- the Task 10 end-to-end pass appended at the bottom needs the REAL
-- modules restored, regardless of what ran in between.
local real_mods = {}
for _, p in ipairs(window.PAGES) do real_mods[p.key] = p.mod end

-- ---- PAGES registry ---------------------------------------------------------
local expected_pages = {
  { key = "stats",  label = "Stats" },
  { key = "city",   label = "City" },
  { key = "farm",   label = "Farm" },
  { key = "builds", label = "Builds" },
  { key = "people", label = "People" },
  { key = "goods",  label = "Goods" },
  { key = "bonds",  label = "Bonds" },
  { key = "ranks",  label = "Ranks" },
  { key = "court",  label = "Court" },
  { key = "army",   label = "Army" },
  { key = "war",    label = "War" },
  { key = "trade",  label = "Trade" },
}
check("PAGES has 12 entries", #window.PAGES == 12, #window.PAGES)
local pages_ok = true
for i, exp in ipairs(expected_pages) do
  local got = window.PAGES[i]
  if not got or got.key ~= exp.key or got.label ~= exp.label then pages_ok = false end
end
check("PAGES keys/labels match the twelve stage-2 pages", pages_ok)
check("every PAGES entry is a valid page module (stats real, the rest placeholder)", (function()
  for _, p in ipairs(window.PAGES) do
    if type(p.mod) ~= "table" or type(p.mod.lines) ~= "function" then return false end
  end
  return true
end)())
check("current_page defaults to stats", window.current_page() == "stats")

local function find_page(key)
  for _, p in ipairs(window.PAGES) do
    if p.key == key then return p end
  end
end

-- ---- tab bar: all twelve labels rendered, current highlighted --------------
reset_drawn()
window.render(make_rect(0, 0, 100, 5), {})
check("tab bar drew at least the header row", #drawn.ansi >= 1)
local tabrow = drawn.ansi[1] and drawn.ansi[1].s or ""
local all_present = true
for _, p in ipairs(expected_pages) do
  if not tabrow:find(p.label, 1, true) then all_present = false end
end
check("tab bar contains all twelve labels", all_present, tabrow)
check("current tab (Stats) is reverse-video highlighted",
      tabrow:find("\27%[7mStats\27%[27m") ~= nil, tabrow)
check("non-current tab (City) is not reverse-video wrapped",
      not tabrow:find("\27%[7mCity\27%[27m"), tabrow)

-- ---- set_page: switches, unknown key refused --------------------------------
check("set_page switches to a known key", window.set_page("city") == true)
check("current_page reflects the switch", window.current_page() == "city")
check("set_page refuses an unknown key", window.set_page("bogus") == false)
check("current_page unchanged after a refused switch", window.current_page() == "city")
check("set_page back to stats", window.set_page("stats") == true)

-- ---- on_pointer: tab-span down switches page, body down does not -----------
-- Column layout for a 100-wide bar (one label per gap, 1-space separator):
-- Stats[0,5) City[6,10) Farm[11,15) Builds[16,22) ... -- verified against the
-- render above (all twelve labels fit on row 0 at width 100).
reset_drawn()
window.render(make_rect(0, 0, 100, 5), {})

local down_on_farm = { kind = "down", button = "left", x = 12, y = 0,
                       inside = true, width = 100, height = 5 }
check("down on Farm's tab span switches page", window.on_pointer(down_on_farm) == true)
check("current_page is now farm", window.current_page() == "farm")

-- Fix 3: only a LEFT down on a tab switches pages; a middle (or right)
-- button on the exact same span must fall through false and leave the
-- current page untouched, same as a down elsewhere in the pane.
window.set_page("stats")
local middle_down_on_farm = { kind = "down", button = "middle", x = 12, y = 0,
                              inside = true, width = 100, height = 5 }
check("middle-button down on Farm's tab span returns false",
      window.on_pointer(middle_down_on_farm) == false)
check("current_page unchanged by a middle-button tab down", window.current_page() == "stats")

window.set_page("stats")
local down_in_body = { kind = "down", button = "left", x = 5, y = 2,
                        inside = true, width = 100, height = 5 }
check("down in the body returns false", window.on_pointer(down_in_body) == false)
check("current_page unchanged by a body down", window.current_page() == "stats")

-- ---- per-page scroller offsets are independent; windowing respects offset --
local stats_lines = {}
for i = 1, 50 do stats_lines[i] = "L" .. i end
find_page("stats").mod = { lines = function() return stats_lines end }
find_page("city").mod = { lines = function() return { "C1", "C2", "C3" } end }

window.set_page("stats")
local body_rect = make_rect(0, 0, 100, 5) -- tab row (1) + body height (4)

reset_drawn()
window.render(body_rect, {})
-- drawn.ansi[1] is the tab row; body rows follow.
check("stats body starts at L1 before scrolling",
      drawn.ansi[2] and drawn.ansi[2].s:find("^L1%s") ~= nil, drawn.ansi[2] and drawn.ansi[2].s)
check("stats following_tail true before scrolling", window.following_tail() == true)

window.scroll(10)
check("stats following_tail false after scrolling down", window.following_tail() == false)

reset_drawn()
window.render(body_rect, {})
check("stats body windowed to the new offset (L11..L14)",
      drawn.ansi[2] and drawn.ansi[2].s:find("^L11%s") ~= nil
      and drawn.ansi[5] and drawn.ansi[5].s:find("^L14%s") ~= nil,
      drawn.ansi[2] and drawn.ansi[2].s)

check("switching to city switches page", window.set_page("city") == true)
reset_drawn()
window.render(body_rect, {})
check("city (never scrolled) is at its own tail", window.following_tail() == true)
check("city shows its own short content",
      drawn.ansi[2] and drawn.ansi[2].s:find("^C1%s") ~= nil, drawn.ansi[2] and drawn.ansi[2].s)

check("switching back to stats", window.set_page("stats") == true)
check("stats offset preserved across the page switch", window.following_tail() == false)
reset_drawn()
window.render(body_rect, {})
check("stats still windowed at L11..L14 after switching away and back",
      drawn.ansi[2] and drawn.ansi[2].s:find("^L11%s") ~= nil, drawn.ansi[2] and drawn.ansi[2].s)

window.scroll_to_bottom()
check("scroll_to_bottom moves stats to its last page", window.following_tail() == false)
reset_drawn()
window.render(body_rect, {})
check("stats tail window ends at L50",
      drawn.ansi[5] and drawn.ansi[5].s:find("^L50%s") ~= nil, drawn.ansi[5] and drawn.ansi[5].s)

-- ---- remote pass does not clobber hit-test spans ----------------------------
window.set_page("stats")
render_pass = "local"
reset_drawn()
window.render(make_rect(0, 0, 100, 5), {}) -- records spans for the WIDE layout
check("(setup) down on Farm's span works against the wide layout",
      window.on_pointer(down_on_farm) == true and window.current_page() == "farm")
window.set_page("stats")

render_pass = "remote"
reset_drawn()
local ok_remote = pcall(window.render, make_rect(0, 0, 20, 5), {}) -- drastically different layout
check("remote render into a different-width rect does not error", ok_remote)

check("remote pass did not update the recorded spans",
      window.on_pointer(down_on_farm) == true and window.current_page() == "farm")

-- ---- Finding 1 (review round 1): a remote pass at a DIFFERENT height must --
-- not mutate the shared scroller clamp a later local render depends on. -----
window.set_page("stats")
render_pass = "local"
reset_drawn()
window.render(body_rect, {})       -- establishes height = 4 (body_rect's body_h)
window.scroll_to_bottom()          -- offset -> 46 (count 50 - height 4)
reset_drawn()
window.render(body_rect, {})       -- "before": window at H1 = 4
check("(setup) before window ends at L50",
      drawn.ansi[5] and drawn.ansi[5].s:find("^L50%s") ~= nil, drawn.ansi[5] and drawn.ansi[5].s)
local before_window = { drawn.ansi[2].s, drawn.ansi[3].s, drawn.ansi[4].s, drawn.ansi[5].s }

render_pass = "remote"
reset_drawn()
-- H2 = 10 (a TALLER remote body) -- if set_height ran unguarded here, the
-- clamp's max (count - height) would shrink from 46 to 40 and reclamp the
-- LOCAL offset down, even though only a remote viewer's own size changed.
local ok_remote_height = pcall(window.render, make_rect(0, 0, 100, 11), {})
check("remote render at a different height does not error", ok_remote_height)

render_pass = "local"
reset_drawn()
window.render(body_rect, {})       -- render locally again at the SAME H1
local after_window = { drawn.ansi[2].s, drawn.ansi[3].s, drawn.ansi[4].s, drawn.ansi[5].s }
check("local window unchanged after an intervening remote render at a different height",
      after_window[1] == before_window[1] and after_window[2] == before_window[2]
      and after_window[3] == before_window[3] and after_window[4] == before_window[4],
      after_window[1])

-- ---- Finding 4 (carried into Task 3 review): a remote pass at a DIFFERENT
-- width, for a page whose line COUNT itself depends on width (stats is the
-- first such page), must not mutate the shared last_lines cache a later
-- local render's scroller clamp depends on -- the count axis, distinct from
-- Finding 1's height axis above.
window.set_page("stats")
render_pass = "local"
local wide_lines, narrow_lines = {}, {}
for i = 1, 50 do wide_lines[i] = "W" .. i end
for i = 1, 5 do narrow_lines[i] = "N" .. i end
find_page("stats").mod = {
  lines = function(w) return (w >= 50) and wide_lines or narrow_lines end,
}

reset_drawn()
window.render(make_rect(0, 0, 100, 5), {})  -- W1 = 100: wide_lines (50 rows)
window.scroll_to_bottom()                   -- offset -> 46 (50 - body_h 4)
reset_drawn()
window.render(make_rect(0, 0, 100, 5), {})  -- "before": window at W1 = 100
check("(setup) before window ends at W50",
      drawn.ansi[5] and drawn.ansi[5].s:find("^W50%s") ~= nil, drawn.ansi[5] and drawn.ansi[5].s)
local before_count_window = { drawn.ansi[2].s, drawn.ansi[3].s, drawn.ansi[4].s, drawn.ansi[5].s }

render_pass = "remote"
reset_drawn()
-- W2 = 20: narrow_lines (only 5 rows) -- if last_lines were updated here
-- unguarded, count() would drop from 50 to 5 and the next local render's
-- clamp would yank the offset back down, even though only a remote
-- viewer's own width differed.
local ok_remote_count = pcall(window.render, make_rect(0, 0, 20, 5), {})
check("remote render at a different width (different line count) does not error", ok_remote_count)

render_pass = "local"
reset_drawn()
window.render(make_rect(0, 0, 100, 5), {})  -- render locally again at the SAME W1
local after_count_window = { drawn.ansi[2].s, drawn.ansi[3].s, drawn.ansi[4].s, drawn.ansi[5].s }
check("local window unchanged after an intervening remote render at a different width",
      after_count_window[1] == before_count_window[1] and after_count_window[2] == before_count_window[2]
      and after_count_window[3] == before_count_window[3] and after_count_window[4] == before_count_window[4],
      after_count_window[1])

-- ---- Finding 2a (review round 1): a down on a WRAPPED (row>0) tab span ----
-- switches page and returns true. A 30-wide rect wraps the twelve labels
-- onto three rows: row0 Stats/City/Farm/Builds/People, row1
-- Goods/Bonds/Ranks/Court/Army, row2 War/Trade (verified against
-- render_tabbar's column bookkeeping: Goods[0,5) Bonds[6,11) ...).
window.set_page("stats")
render_pass = "local"
reset_drawn()
window.render(make_rect(0, 0, 30, 10), {})
check("narrow rect wraps the tab bar onto multiple rows", #drawn.ansi >= 3)
check("wrapped row 1 contains Bonds",
      drawn.ansi[2] and drawn.ansi[2].s:find("Bonds", 1, true) ~= nil,
      drawn.ansi[2] and drawn.ansi[2].s)

local down_on_wrapped_bonds = { kind = "down", button = "left", x = 8, y = 1,
                                 inside = true, width = 30, height = 10 }
check("down on a wrapped-row tab span switches page",
      window.on_pointer(down_on_wrapped_bonds) == true)
check("current_page is now bonds (from a row-1 span)", window.current_page() == "bonds")
window.set_page("stats")

-- ---- Finding 2b (review round 1): a down on the separator column between --
-- two adjacent labels matches neither span and returns false.
render_pass = "local"
reset_drawn()
window.render(make_rect(0, 0, 100, 5), {}) -- restores the wide layout's spans
local page_before_separator_down = window.current_page()
local down_on_separator = { kind = "down", button = "left", x = 5, y = 0, -- the
                             -- single space between Stats[0,5) and City[6,10)
                             inside = true, width = 100, height = 5 }
check("down on the separator column between two tabs returns false",
      window.on_pointer(down_on_separator) == false)
check("separator down does not change the page",
      window.current_page() == page_before_separator_down)

render_pass = "local"

-- =============================================================================
-- Task 10: end-to-end pane pass -- every page in window.PAGES rendered at
-- real pane dimensions with a representative state slice, no page crashing,
-- no emitted row overflowing the rect width, and scrolling working without
-- error. Seeds below are borrowed from guild_viking_pages1-4_test.lua so most
-- sections have real data rather than falling back to "no data yet" text.
-- This is the "no page crashes at real dimensions" lock the task brief asks
-- for.
-- =============================================================================

local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local S = state.S

-- Restore the REAL page modules (a mid-file section above replaced stats'
-- and city's `.mod` with fake scroller-math doubles).
for _, p in ipairs(window.PAGES) do p.mod = real_mods[p.key] end

-- Replicates render_tabbar's own wrap bookkeeping (window.lua) so the test
-- can tell tab rows apart from body rows in what gets drawn, without
-- exporting that internal from window.lua itself.
local function count_tab_rows(width)
  local row, col = 0, 0
  for _, p in ipairs(window.PAGES) do
    local seg_len = #p.label
    if col > 0 and col + seg_len > width then
      row = row + 1
      col = 0
    end
    col = col + seg_len
    if col < width then col = col + 1 end
  end
  return row + 1
end

-- ---- seed a representative state slice across every page -------------------

-- stats
S.daler = 12345
S.hp, S.mhp, S.hp_delta = 350, 500, 5
S.threk, S.mthrek, S.threk_delta = 10, 50, -2
S.seid, S.mseid, S.seid_delta = 80, 100, 0
S.vig, S.mvig, S.vig_delta = 40, 80, 0
S.rad, S.mrad, S.rad_delta = 20, 40, 0
S.fury = "[***-------]"
S.ldng, S.mldng, S.lrst = 3, 4, 10
S.chain, S.bsdepth = 7, 2
S.god_power_name, S.god_power_next = "Odin's Fury", 125
S.vis, S.vis_gain, S.vis_session = 100, 5, 20
S.kap, S.kap_gain, S.kap_session = 200, 3, 15
S.soe, S.soe_gain, S.soe_session = 50, 0, 5
S.aud, S.aud_gain, S.aud_session = 10, 1, 2
S.xp_session_start = os.time() - 65
S.en5, S.ens, S.rndz = "Wolf", "low", 3
S.mob_name_full, S.estatus_pct, S.combat = "Grey Wolf", 42, true
S.stfx = { { name = "ein", val = "54", cat = "Def" } }

-- city
S.ships = { { name = "Ravager", tier = 2, state = "raiding", target = "Vestergotland",
              return_in = 90, crew = 8, ship_id = nil, convoy = 0, durability = 100 } }
S.raidlog = { { ship = "Ravager", target = "vestergotland", daler = 150,
                goods = { { good = "furs", qty = 12 } }, thralls = 2, lost = false } }
S.buildings = { warehouse = 3, dock = 2 }
S.wstock = {
  { good = "grain", amount = 100, freshness_pct = 100 },
  { good = "fish", amount = 50, freshness_pct = 100 },
  { good = "timber", amount = 200, freshness_pct = 100 },
}
S.next_tick_in = 45
S.production = { timber = 25, ore = 10 }
S.upkeep = { roster = 50, community = 20, throne = 10, roads = 5, forts = 5, total = 90 }
S.routes = { hold = { name = "Hold", road_tier = 2, fort_tier = 1,
                       road_maint = 80, fort_maint = 60, road_name = "", fort_name = "" } }
S.route_upkeep = 12
S.monuments = { "Saga of the North Wind" }
S.monument_cap = 5

-- trade
S.dispatch_cd = 0
S.carts = { { mode = "buy", good = "furs", village = "Vestergotland", return_in = 120,
              amount = 50, halfway_in = 0, quality_pct = 100, cart_id = 3, tier = 2,
              durability = 90, cap = 200, escort = 1, refit = "standard", legs = {} } }
S.idle_carts = { { cart_id = 7, tier = 1, durability = 100, cap = 150, refit = "standard" } }
S.cart_upgrades = { { cart_id = 3, target_tier = 3, secs_left = -1, mats_total = 10,
                       mats_done = 4, mats = { { good = "timber", done = 4, need = 10 } },
                       target_refit = "", job_type = "upgrade" } }
S.courier = { tier = 2, runs = { { good = "fish", village = "Imaird", return_in = 60,
                                    amount = 20, cost = 100, fee = 5 } } }
S.spy = { tier = 1, mode = "sabotage", village = "Holmgard", secs = 300, sab_pct = 10,
          sab_secs = 500, cd_secs = 0, scouts = { { city = "Uppsala", amb = 15, secs = 200 } } }
S.train = { tier = 1, name = "Erik", stat = "combat", trained = 2, secs = 400 }
S.heat = { 10, 80, 5 }
S.grudges = { { town = "Birka", secs = 3600 } }
S.trade_queue = { { mode = "sell", good = "mead", village = "Lejre", amount = 30, escort = 2 } }
S.market_orders = { { id = 1, buyer = "olaf", good = "iron", remaining = 15, price = 8, age_secs = 60 } }
S.incoming_fills = { { good = "honey", amount = 25, arrives_in = 90, seller = "astrid" } }

-- farm
S.season = "spring"
S.weather = "storm"
S.weather_str = 3
S.farm_wmod = 15
S.farm_plots = {
  { coord = "A1", shroom = "fly_agaric_t1", time_left = 0, fertilized = 0, wilt_left = -1 },
  { coord = "A2", shroom = "lions_mane_t2", time_left = 3600, fertilized = 1, wilt_left = -1 },
}
S.city_water = 40
S.city_fert = 25
S.blot_status = "open"
S.blot_reset_in = 3661
S.blot_filled = 4
S.blot_total = 9

-- builds
S.pending_builds = {
  { bldg_id = "warehouse", tier = 2, mats_total = 10, mats_done = 3,
    complete_at_secs = -1, total_build_secs = 0,
    mats = { { good = "timber", done = 3, need = 10 } } },
}
S.ship_upgrades = {
  { name = "Ormen", tier = 3, secs_left = -1, mats_total = 5, mats_done = 2,
    mats = { { good = "iron", done = 2, need = 5 } } },
}
S.bdmg = { { bldg_id = "palisade", pct = 72 } }
S.staff_list = {
  { name = "Ragnar", assigned_to = "0", stat_key = "combat",
    stats = { combat = 10, trade = 2 }, trait = "berserker", loyalty = 4,
    age = "young", arrive_at = 0 },
}

-- people
S.settlers = 42
S.settler_tax = 2
S.settler_edict = "feast"
S.settler_edict_left = 125
S.settler_edict_cd = 0
S.settler_housing_cap = 300
S.settler_housing_plots = 12
S.settler_housing_avg = 250
S.settler_housing_plot_tiers = { t1 = 4, t2 = 3, t3 = 2, t4 = 0 }
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
S.settler_consumption = { grain = 6, water = 4 }
S.settler_supply_next = 300
S.settler_pop_next = 600
S.settler_actions = { { name = "Assembly", secs = 90 } }
S.settler_projects = {
  { id = "longhouse", kind = "housing_upgrade", from_tier = 1, to_tier = 2,
    secs_left = -1, mats_total = 10, mats_done = 4, daler = 50,
    mat_detail = { timber = { have = 4, need = 10 } } },
}
S.settler_identity = "Builders' Hold"
S.settler_roles = {
  { key = "smidir", label = "Builders", cur = 40, tgt = 55, work = 10, bonus = 8 },
  { key = "boendr", label = "Farmers", cur = 30, tgt = 30, work = 5, bonus = 0 },
}
S.settler_commoner = 12
S.patrol = { count = 3, remaining = 45 }
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
S.raid_in = 200
S.raid_faction = "Skalgrim Reavers"
S.raid_strength = 80
S.thralls = 14
S.thrall_assignments = { longhouse = 3, warehouse = 2 }
S.thrall_follower_level = 4
S.thrall_follower_name = "grimna"
S.thrall_follower_xp = 120
S.thrall_follower_xp_cap = 400
S.thrall_follower_carry_used = 10
S.thrall_follower_carry_cap = 40
S.thrall_follower_status = "following"
S.missions = {
  { id = 7, label = "Deliver grain to Holmgard", expires_in = 1800,
    origin_town = "Vestergotland", target_town = "Holmgard",
    reward = 200, reward_rep = 15, want_goods = { grain = 30 } },
}
S.errand = {
  id = 99, label = "Fetch water", expires_in = 5400,
  origin_town = "", target_town = "Holmgard",
  reward = 0, reward_good = "water", reward_qty = 10,
}
S.mission_reg_left = 2
S.mission_new_left = 0

-- goods
S.trade_goods = {
  [0] = { iron = { score = -3, supply = 100, demand = 0, buy = 5, sell = 0 },
          mead = { score = 2, supply = 0, demand = 10, buy = 0, sell = 40 } },
  [1] = { iron = { score = 2, supply = 0, demand = 100, buy = 0, sell = 50 } },
}
S.demand_cycle = "Spring Growth"
S.demand_cycle_in = 0
S.wstock_by_good = { mead = { amount = 20 } }
S.blocks = {}
S.autotrade.show_n = 6
S.autotrade.status = "cooldown"
S.autotrade.last_msg = "sell 4x Mead -> Midgard; buy 2x Furs -> Lodbrok's"
S.autotrade.log = {
  { t = "10:00", jobs = { { mode = "sell", qty = 3, good = "mead", stown_lin = 0, profit = 90, margin = 30 } } },
}
S.price_history = { [0] = { iron = { { t = 1, b = 5, s = 40 }, { t = 2, b = 15, s = 60 } } } }
page_opts.set("auto_trade", true)
page_opts.set("show_goods_atlog", true)

-- bonds
S.hird_by_id = {
  [1] = { name = "Ragnar Ironside" },
  [2] = { name = "Skoll" },
}
S.bonds_list = {
  { id_a = 1, id_b = 2, ticks = 850000, tier = 3 },
  { id_a = 3, id_b = 4, ticks = 30000, tier = 0 },
}

-- ranks
S.standings = {
  [1] = { name = "Own Lineage", score = 50, label = "Neutral", is_own = true },
  [2] = { name = "Rival Lineage", score = 620, label = "Allied", is_own = false },
  [3] = { name = "Foe Lineage", score = -350, label = "Feud", is_own = false },
}
S.village_rep = {
  [2] = { name = "Holmgard", rep = 150, rank = 2, start_at = 100, next_at = 300 },
  [1] = { name = "Vestergotland", rep = 999, rank = 7, start_at = 500, next_at = 0 },
}

-- court
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

-- army
S.army = {
  conscripts = 42, cap = 10, used = 6,
  units = {
    { uid = 1, type = "skirmishers", size = 12, vet = 55, ready = true,
      leader = "Ivar", traits = { "Blooded", "Scarred" } },
    { uid = 2, type = "huscarls", size = 8, vet = 0, ready = false,
      leader = nil, traits = {} },
  },
}

-- war
S.war_map = {
  active = true, dim = 5, turn = 3, mode = "offense", pending = 0,
  town = "Jorvik", works_budget = 0, march_eta = 125,
  rows = { ".....", ".....", ".....", ".....", "....." },
  upkeep = { food = 10, mead = 5, tools = 2, iron = 1, daler = 3 },
  spoils = { daler = 500, renown = 20, deeds = 2 },
}
S.prison = {
  held = 2, cap = 5, kin = 1, pending = true,
  pend_name = "Ragnar", pend_size = 8, pend_cmd = true,
  roster = { { id = 1, name = "Thrall A", size = 3, cmd = false, val = 50 } },
}
S.siege = { engines = 2, cap = 4 }
S.battle = {
  phase = "turn", target = "Jorvik", mode = "field", turn = 3,
  budget = 100, spent = 60, war_points = 30,
  units = {
    { side = "you", label = "huscarls", size = 8, coord = "C3", morale = 80, leader = "Ivar" },
    { side = "foe", label = "foe_raiders", size = 10, coord = "D4", morale = 20 },
  },
}
S.war_points = 30
S.war = {
  incoming = { town = "Kaupang", strength = 120, days = 3 },
  claims = { { town = "Hedeby", days = 10 } },
  campaigns = { { town = "Hedeby", defense = 40, max = 100 } },
}
S.diplomacy = {
  allies = { { house = "Ivarsson", standing = 5 } },
  foes = { { house = "Ragnarsson", standing = -3 } },
}

-- ---- render every page at 80x24 (a real output-pane-sized rect) -----------
render_pass = "local"
local TAB_ROWS_80 = count_tab_rows(80)
for _, p in ipairs(window.PAGES) do
  window.set_page(p.key)
  reset_drawn()
  local ok, err = pcall(window.render, make_rect(0, 0, 80, 24), {})
  check("80x24 " .. p.key .. ": renders without error", ok, err)

  local widest = nil
  for _, d in ipairs(drawn.ansi) do
    local vw = pagelib.visible_width(d.s)
    if widest == nil or vw > widest then widest = vw end
  end
  check("80x24 " .. p.key .. ": at least one non-tab row rendered",
        #drawn.ansi > TAB_ROWS_80, #drawn.ansi)
  check("80x24 " .. p.key .. ": every emitted row's visible width <= 80",
        widest == nil or widest <= 80, widest)

  local ok_scroll, err_scroll = pcall(function()
    window.scroll(-5)
    window.scroll(5)
    window.render(make_rect(0, 0, 80, 24), {})
  end)
  check("80x24 " .. p.key .. ": scroll(-5) then scroll(5) renders without error",
        ok_scroll, err_scroll)
end

-- ---- render every page at a narrow 40x12 rect (tab bar wraps) -------------
local TAB_ROWS_40 = count_tab_rows(40)
check("40x12: tab bar wraps onto more than one row at this width", TAB_ROWS_40 > 1, TAB_ROWS_40)
for _, p in ipairs(window.PAGES) do
  window.set_page(p.key)
  reset_drawn()
  local ok, err = pcall(window.render, make_rect(0, 0, 40, 12), {})
  check("40x12 " .. p.key .. ": renders without error", ok, err)

  local widest = nil
  for _, d in ipairs(drawn.ansi) do
    local vw = pagelib.visible_width(d.s)
    if widest == nil or vw > widest then widest = vw end
  end
  check("40x12 " .. p.key .. ": at least one non-tab row rendered",
        #drawn.ansi > TAB_ROWS_40, #drawn.ansi)
  check("40x12 " .. p.key .. ": every emitted row's visible width <= 40",
        widest == nil or widest <= 40, widest)

  local ok_scroll, err_scroll = pcall(function()
    window.scroll(-5)
    window.scroll(5)
    window.render(make_rect(0, 0, 40, 12), {})
  end)
  check("40x12 " .. p.key .. ": scroll(-5) then scroll(5) renders without error",
        ok_scroll, err_scroll)
end

window.set_page("stats")
render_pass = "local"

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING WINDOW TESTS PASSED")
