-- guild_viking handlers/city.lua unit tests. Run from the lera-plugins repo
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

-- ---- lera API stubs (same shape as guild_viking_kingdom_test.lua) ---------
local dirty_count = 0
ui = { dirty = function() dirty_count = dirty_count + 1 end }
local stored = nil
store = {
  load = function() end,
  get = function() return stored end,
  set = function(d) stored = d end,
  save = function() end,
}
lera = { time = function() return 1000 end, version = function() return "test" end }
buffer = { color_print = function() end }
mud = { send = function() end }
local mip_handlers, mip_handler_count = {}, 0
mip = {
  on = function(code, cb)
    mip_handlers[code] = cb
    mip_handler_count = mip_handler_count + 1
    return mip_handler_count
  end,
  off = function() end,
  enabled = function() return true end,
  fire = function(code, data) mip_handlers[code](12345, code, data) end,
}
local gmcp_handlers, gmcp_handler_count = {}, 0
gmcp = {
  on = function(pkg, cb)
    gmcp_handlers[pkg] = cb
    gmcp_handler_count = gmcp_handler_count + 1
    return gmcp_handler_count
  end,
  remove = function() end,
  enabled = function() return false end,
  fire = function(pkg, data) gmcp_handlers[pkg](pkg, data) end,
}
trigger = { add = function() return 1 end, remove = function() end }
timer = { every = function() return 1 end, remove = function() end }
alias = { add = function() return 1 end, remove = function() end }
plugin = { get = function() return nil end }
local real_require = require
require = function(name)
  if name == "command" then
    return { register = function() return 1 end, unregister = function() return true end,
             get = function() return nil end, list = function() return {} end }
  end
  return real_require(name)
end

local protocol = require("protocol")
local S = require("state").S
local city = require("handlers.city")
for key, fn in pairs(city) do
  if key ~= "_patterns" and key ~= "_gmcp" and key ~= "_market_seam" then
    protocol.handler(key, fn)
  end
end
for _, p in ipairs(city._patterns or {}) do
  protocol.pattern_handler(p.pattern, p.fn)
end

-- BLOT (LEGACY 1683): blot_state|reset_in|filled|total
protocol.ingest("BLOT", "open|300|4|9")
check("blot fields", S.blot_status == "open" and S.blot_reset_in == 300
      and S.blot_filled == 4 and S.blot_total == 9)

-- FARM (LEGACY 1691): coord|shroom|time_left|fertilized|wilt_left entries;
-- a "meta|wmod" entry instead sets farm_wmod. cap 50.
protocol.ingest("FARM", "A1|redcap|100|1|20;meta|15")
check("farm plots", #S.farm_plots == 1 and S.farm_plots[1].coord == "A1"
      and S.farm_plots[1].shroom == "redcap" and S.farm_plots[1].time_left == 100)
check("farm wmod", S.farm_wmod == 15)

do
  local entries = {}
  for i = 1, 51 do
    entries[#entries + 1] = string.format("P%d|redcap|10|0|5", i)
  end
  protocol.ingest("FARM", table.concat(entries, ";"))
  check("farm safety cap", #S.farm_plots == 50)
end

-- BUILDS (LEGACY 1709): bid|tier|mats_total|mats_done|complete_at_secs|total_build_secs|good:done/need,...
protocol.ingest("BUILDS", "longhouse|2|10|5|300|600|timber:5/10,ore:0/5")
check("builds count", #S.pending_builds == 1)
check("builds fields", S.pending_builds[1].bldg_id == "longhouse"
      and S.pending_builds[1].tier == 2 and S.pending_builds[1].total_build_secs == 600)
check("builds mats", #S.pending_builds[1].mats == 2 and S.pending_builds[1].mats[1].good == "timber"
      and S.pending_builds[1].mats[1].done == 5 and S.pending_builds[1].mats[1].need == 10)

do
  local entries = {}
  for i = 1, 31 do
    entries[#entries + 1] = string.format("b%d|1|1|0|10|20|", i)
  end
  protocol.ingest("BUILDS", table.concat(entries, ";"))
  check("builds safety cap", #S.pending_builds == 30)
end

-- SUPG (LEGACY 1735): ship_upgrades: name|tier|secs_left|mats_total|mats_done|good:done/need,...
protocol.ingest("SUPG", "Ormen|2|120|8|3|timber:3/8")
check("supg count", #S.ship_upgrades == 1)
check("supg fields", S.ship_upgrades[1].name == "Ormen" and S.ship_upgrades[1].tier == 2
      and S.ship_upgrades[1].secs_left == 120)
check("supg mats", #S.ship_upgrades[1].mats == 1 and S.ship_upgrades[1].mats[1].good == "timber")

do
  local entries = {}
  for i = 1, 21 do
    entries[#entries + 1] = string.format("Ship%d|1|10|0|0|", i)
  end
  protocol.ingest("SUPG", table.concat(entries, ";"))
  check("supg safety cap", #S.ship_upgrades == 20)
end

-- SETTLERS (LEGACY 1756): count|mood|tax|water|fert
protocol.ingest("SETTLERS", "40|70|10|60|55")
check("settlers fields", S.settlers == 40 and S.settler_mood == 70 and S.settler_tax == 10
      and S.city_water == 60 and S.city_fert == 55)

-- SETTLERX (LEGACY 1765): 23-field pipe-delimited edict/housing/civic summary
protocol.ingest("SETTLERX",
  "feast|100|20|500|20|30|80|10|200|150|5|105|60|40|75|20|5|10|65|70|55|300|400")
check("settlerx edict", S.settler_edict == "feast" and S.settler_edict_left == 100
      and S.settler_edict_cd == 20)
check("settlerx housing", S.settler_housing_cap == 500 and S.settler_housing_plots == 20
      and S.settler_housing_avg == 30 and S.settler_housing_quality == 80
      and S.settler_housing_upkeep == 10)
check("settlerx jobs", S.settler_jobs == 200 and S.settler_employed == 150
      and S.settler_market_staffed == 5)
check("settlerx scores", S.settler_mult_pct == 105 and S.settler_security == 60
      and S.settler_dignity == 40 and S.settler_flourishing == 75
      and S.settler_community_net == 20 and S.settler_community_upkeep == 10)
check("settlerx new fields", S.settler_sustenance == 65 and S.settler_emp_score == 70
      and S.settler_sentiment == 55 and S.settler_supply_next == 300
      and S.settler_pop_next == 400)

-- SACTIONS (LEGACY 1811): 6 pipe fields, seconds for Assembly/Watch/Crafts/Feast/Relief/Works;
-- zero/blank entries are skipped.
protocol.ingest("SACTIONS", "100|0|50||20|0")
check("sactions count", #S.settler_actions == 3)
check("sactions fields", S.settler_actions[1].name == "Assembly" and S.settler_actions[1].secs == 100
      and S.settler_actions[2].name == "Crafts" and S.settler_actions[2].secs == 50
      and S.settler_actions[3].name == "Relief" and S.settler_actions[3].secs == 20)

-- SROLES (LEGACY 1827): first ";"-segment is "meta|commoner|identity"; the
-- rest are "key:cur:tgt:work:bonus"
protocol.ingest("SROLES", "meta|30|Fisherfolk;smidir:5:10:8:2;boendr:12:15:10:0;xyz:1:2:0:0")
check("sroles meta", S.settler_commoner == 30 and S.settler_identity == "Fisherfolk")
check("sroles count", #S.settler_roles == 3)
check("sroles fields", S.settler_roles[1].key == "smidir" and S.settler_roles[1].label == "Builders"
      and S.settler_roles[1].cur == 5 and S.settler_roles[1].tgt == 10
      and S.settler_roles[1].work == 8 and S.settler_roles[1].bonus == 2)
check("sroles known label", S.settler_roles[2].key == "boendr" and S.settler_roles[2].label == "Farmers")
check("sroles unknown label falls back to key", S.settler_roles[3].key == "xyz"
      and S.settler_roles[3].label == "xyz")

-- CPLAN -> CPT%d%d (pattern) -> CPP -> CPB -> CPU -> CPEND: double-buffered
-- city-plan grid, committed only when the row count matches expected.
protocol.ingest("CPLAN", "1|2|3|10|1|1|1|6|50|3")
check("cplan pending", S.cp_pending.enabled == true and S.cp_pending.dim == 2
      and S.cp_pending.placed == 3 and S.cp_pending.cap == 10
      and S.cp_pending.moat == true and S.cp_pending.wall == true
      and S.cp_pending.gate == 6 and S.cp_pending.mood == 50 and S.cp_pending.margin == 3)

-- CPP (LEGACY 1867): perks string
protocol.ingest("CPP", "shrine,forge")
check("cpp perks", S.cp_pending.perks == "shrine,forge")

-- CPT%d%d (LEGACY 1869, pattern-dispatched): row content keyed by a 2-digit
-- row index embedded in the key itself (0-indexed -> 1-indexed).
protocol.ingest("CPT00", "..")
protocol.ingest("CPT01", "##")
check("cpt row 0 lands at index 1", S.cp_pending.rows[1] == "..")
check("cpt row 1 lands at index 2", S.cp_pending.rows[2] == "##")

-- CPB (LEGACY 1874): placed buildings id|x|y|w|h|pal|glyph|name;...
protocol.ingest("CPB", "b1|0|0|2|2|e|L|Longhouse")
check("cpb count", #S.cp_pending.blds == 1)
check("cpb fields", S.cp_pending.blds[1].id == "b1" and S.cp_pending.blds[1].x == 0
      and S.cp_pending.blds[1].w == 2 and S.cp_pending.blds[1].name == "Longhouse")

-- CPU (LEGACY 1887): unplaced buildings id|pal|glyph|name;...
protocol.ingest("CPU", "b2|e|W|")
check("cpu count", #S.cp_pending.unplaced == 1)
check("cpu fields", S.cp_pending.unplaced[1].id == "b2"
      and S.cp_pending.unplaced[1].name == "b2")  -- empty name falls back to id

-- CPEND (LEGACY 1898): commits cp_pending -> city_plan when got == expected.
protocol.ingest("CPEND", "2")
check("cpend commits city_plan", S.city_plan ~= nil and #S.city_plan.rows == 2
      and S.city_plan.perks == "shrine,forge")
check("cpend clears pending", S.cp_pending == nil)

-- CPEND with a mismatched row count keeps the previous grid and records dbg.
protocol.ingest("CPLAN", "1|2|3|10|1|1|1|6|50|3")
protocol.ingest("CPT00", "..")
protocol.ingest("CPEND", "2")
check("cpend mismatch keeps previous plan", S.city_plan.rows[1] == ".."
      and S.city_plan.dbg ~= nil and S.city_plan.dbg:match("dropped"))

-- SPROJ (LEGACY 2037): settler projects id|kind|from_tier|to_tier|secs|mats_total|mats_done|mat_detail|daler
protocol.ingest("SPROJ", "p1|upgrade|1|2|100|10|4|timber:4/10|500")
check("sproj count", #S.settler_projects == 1)
check("sproj fields", S.settler_projects[1].id == "p1" and S.settler_projects[1].kind == "upgrade"
      and S.settler_projects[1].from_tier == 1 and S.settler_projects[1].to_tier == 2
      and S.settler_projects[1].daler == 500)
check("sproj mat_detail", S.settler_projects[1].mat_detail.timber.have == 4
      and S.settler_projects[1].mat_detail.timber.need == 10)

do
  local entries = {}
  for i = 1, 31 do
    entries[#entries + 1] = string.format("p%d|upgrade|1|2|10|0|0||0", i)
  end
  protocol.ingest("SPROJ", table.concat(entries, ";"))
  check("sproj safety cap", #S.settler_projects == 30)
end

-- SHPLOTS (LEGACY 2065): housing plot tier counts t1|t2|t3|t4
protocol.ingest("SHPLOTS", "5|3|2|1")
check("shplots tiers", S.settler_housing_plot_tiers.t1 == 5 and S.settler_housing_plot_tiers.t4 == 1)
-- Replaces the old "shplots recompute" case, which pinned LEGACY's per-tier
-- 18/30/45/65 arithmetic. That table does not exist server-side:
-- _community_housing_capacity() (players/viking/obj/include/settlers.h:302-314)
-- is (t1+t2+t3+t4+t5) * HEARTH_CAP_FLAT, flat at 11 per plot, and SETTLERX's
-- housing_cap/housing_plots carry that computation. SHPLOTS now owns only the
-- tier counts, so the SETTLERX values fed above (cap 500, plots 20) must
-- survive it untouched -- which is also what stops the two writers colliding
-- over GMCP, where frames are deltas and arrive in no fixed order.
check("shplots leaves the SETTLERX housing totals alone",
      S.settler_housing_plots == 20 and S.settler_housing_cap == 500,
      "plots=" .. tostring(S.settler_housing_plots) ..
        " cap=" .. tostring(S.settler_housing_cap))

-- SCIVICS (LEGACY 2078): civic_id:tier,...
protocol.ingest("SCIVICS", "shrine:2;hall:1")
check("scivics fields", S.settler_community_buildings.shrine == 2
      and S.settler_community_buildings.hall == 1)

-- SCONSUME (LEGACY 2086): good:amount,...
protocol.ingest("SCONSUME", "fish:20;grain:15")
check("sconsume fields", S.settler_consumption.fish == 20 and S.settler_consumption.grain == 15)

-- BUILDINGS (LEGACY 2160): bldg_id:tier,...
protocol.ingest("BUILDINGS", "longhouse:3,warehouse:2")
check("buildings fields", S.buildings.longhouse == 3 and S.buildings.warehouse == 2)

protocol.ingest("BUILDINGS", "")
check("buildings empty clears", next(S.buildings) == nil)

-- PRODUCTION (LEGACY 2226): good:amount,... (full replace)
protocol.ingest("PRODUCTION", "timber:10,fish:-5")
check("production fields", S.production.timber == 10 and S.production.fish == -5)

-- MONUMENTS (LEGACY 2236): cap;inscription;inscription;...
protocol.ingest("MONUMENTS", "5;First jarl;Second jarl")
check("monuments cap", S.monument_cap == 5)
check("monuments count", #S.monuments == 2 and S.monuments[1] == "First jarl")

do
  -- parts caps at 51 total (1 cap slot + up to 50 names): feed a cap value
  -- plus 51 name entries (52 segments) and expect only the first 50 names
  -- to survive.
  local entries = { "5" }
  for i = 1, 51 do
    entries[#entries + 1] = string.format("Monument%d", i)
  end
  protocol.ingest("MONUMENTS", table.concat(entries, ";"))
  check("monuments safety cap", #S.monuments == 50)
end

-- MISSIONS (LEGACY 2248): new 8-field: id|label|reward_rep|reward_daler|expires_in|origin_town|target_town|want_goods
protocol.ingest("MISSIONS", "1|Deliver fish|10|200|300|Havn|Fjord|fish:5,salt:2")
check("missions count", #S.missions == 1)
check("missions fields", S.missions[1].id == 1 and S.missions[1].label == "Deliver fish"
      and S.missions[1].origin_town == "Havn" and S.missions[1].target_town == "Fjord")
check("missions want_goods", S.missions[1].want_goods.fish == 5 and S.missions[1].want_goods.salt == 2)

do
  local entries = {}
  for i = 1, 21 do
    entries[#entries + 1] = string.format("%d|M|1|1|1|Havn|Fjord|fish:1", i)
  end
  protocol.ingest("MISSIONS", table.concat(entries, ";"))
  check("missions safety cap", #S.missions == 20)
end

-- ERRAND (LEGACY 2297): new 8-field: id|label|reward|expires|origin_town|target_town|reward_good|reward_qty
protocol.ingest("ERRAND", "9|Fetch salt|100|60|Havn|Fjord|salt|10")
check("errand fields", S.errand.id == 9 and S.errand.label == "Fetch salt"
      and S.errand.origin_town == "Havn" and S.errand.target_town == "Fjord"
      and S.errand.reward_good == "salt" and S.errand.reward_qty == 10)

-- NEXTTICK (LEGACY 2488): plain number
protocol.ingest("NEXTTICK", "45")
check("nexttick", S.next_tick_in == 45)

-- CDTIME (LEGACY 2490): positive seconds -> cd + expires_at (os.time() + cd);
-- else cleared. expires_at is wall-clock, so check it's a plausible future
-- timestamp rather than pinning an exact value.
local before_cdtime = os.time()
protocol.ingest("CDTIME", "30")
check("cdtime positive", S.dispatch_cd == 30
      and S.dispatch_cd_expires_at ~= nil
      and S.dispatch_cd_expires_at >= before_cdtime + 30
      and S.dispatch_cd_expires_at <= os.time() + 30)

protocol.ingest("CDTIME", "0")
check("cdtime zero clears", S.dispatch_cd == 0 and S.dispatch_cd_expires_at == nil)

-- GOD_POWER / GOD_ACTIVE (LEGACY 2499): both keys share one branch; a valid
-- god name is kept, anything else becomes "".
protocol.ingest("GOD_POWER", "Thor")
check("god_power valid name", S.god_power_name == "Thor")

protocol.ingest("GOD_ACTIVE", "NotAGod")
check("god_active invalid name clears", S.god_power_name == "")

protocol.ingest("GOD_ACTIVE", "Loki")
check("god_active valid name", S.god_power_name == "Loki")

-- GOD_POWER_NEXT / GOD_NEXT (LEGACY 2507): both keys share one branch;
-- negative seconds clamp to 0. god_power_next_at is os.time()-derived, so
-- check it's a plausible timestamp rather than pinning an exact value.
local before_godnext = os.time()
protocol.ingest("GOD_POWER_NEXT", "120")
check("god_power_next", S.god_power_next == 120
      and S.god_power_next_at >= before_godnext + 120
      and S.god_power_next_at <= os.time() + 120)

local before_godnext2 = os.time()
protocol.ingest("GOD_NEXT", "-5")
check("god_next clamps negative to zero", S.god_power_next == 0
      and S.god_power_next_at >= before_godnext2 and S.god_power_next_at <= os.time())

-- GOD_POWER_FOCUS (LEGACY 2512): plain string
protocol.ingest("GOD_POWER_FOCUS", "war")
check("god_power_focus", S.god_power_focus == "war")

-- DCYCLE (LEGACY 2514): name|secs
protocol.ingest("DCYCLE", "surplus|600")
check("dcycle fields", S.demand_cycle == "surplus" and S.demand_cycle_in == 600)

-- SEVENTS (LEGACY 2648): ts|msg;...
protocol.ingest("SEVENTS", "1000|A feast was held;1050|A fire broke out")
check("sevents count", #S.settler_events == 2)
check("sevents fields", S.settler_events[1].ts == 1000 and S.settler_events[1].msg == "A feast was held")

-- ---- Census: porting-completeness lock across all four handler modules ---
local trade = require("handlers.trade")
local voyage = require("handlers.voyage")
local kingdom = require("handlers.kingdom")

local EXPECTED_EXACT_KEYS = {
  -- trade.lua (23)
  "CARTS", "COURIER", "SPY", "HEAT", "TRAIN", "CUPG", "CIDLE", "TQUEUE",
  "WSTOCK", "BLOCKS", "CELLAR", "REFINERY", "ROUTES", "RUPKEEP", "UPKEEP",
  "RBUILD", "STAFF", "BONDS", "MARKET", "INCOMING", "DALER", "TGOODS", "VFIND",
  -- voyage.lua (27 -- VMAPH/VMAPL/VMAPL_END are registered as explicit no-ops
  -- now that Guild.Map owns the territory map, so protocol.ingest does not
  -- file the server's still-arriving MIP map keys under `unknown`)
  "SHIPS", "LONGSHIP", "VOYAGE", "VOYAGE_WAIT", "VRESOLVE", "VOFFERS",
  "VCHART", "VCHH", "VQPATH", "VSAGA", "VMEM", "VBOONS", "VSPOILS", "VGOODS",
  "VAIDS", "VRUNES", "VRELICS", "VCURIOS", "VREAGENT", "VSAILED", "VMREG",
  "VMNEW", "WEATHER", "VMAPH", "VMAPL", "VMAPL_END", "FLEET_RENOWN",
  -- kingdom.lua (27)
  "RAIDLOG", "RTARGETS", "DYNASTY", "ARMY", "BATTLE", "DIPLO", "WAR", "WMAP",
  "WMU", "WMP", "WSPOIL", "WSG", "WMPL", "WMO", "WMQ", "WMEND", "PATROL",
  "GARRISON", "VARANG", "THRALLS", "THRALL_FOLLOWER", "RAID", "GRUDGES",
  "BDMG", "STANDINGS", "VREP", "HIRD",
  -- city.lua (31 -- GOD_POWER/GOD_ACTIVE and GOD_POWER_NEXT/GOD_NEXT each
  -- register two keys sharing one fn)
  "BLOT", "FARM", "BUILDS", "SUPG", "SETTLERS", "SETTLERX", "SACTIONS",
  "SROLES", "CPLAN", "CPP", "CPB", "CPU", "CPEND", "SPROJ", "SHPLOTS",
  "SCIVICS", "SCONSUME", "BUILDINGS", "PRODUCTION", "MONUMENTS", "MISSIONS",
  "ERRAND", "NEXTTICK", "CDTIME", "GOD_POWER", "GOD_ACTIVE", "GOD_POWER_NEXT",
  "GOD_NEXT", "GOD_POWER_FOCUS", "DCYCLE", "SEVENTS",
}

local EXPECTED_PATTERNS = {
  "^VCR%d%d$", "^VMR%d%d$", "^MEE%d%d$", "^MES%d%d$", "^WMR%d%d$", "^CPT%d%d$",
}

local function collect_exact_keys()
  local keys = {}
  for _, mod in ipairs({ trade, voyage, kingdom, city }) do
    for key, _ in pairs(mod) do
      -- The module-level convention fields, not MIP keys. `_gmcp` is
      -- censused separately below: counting it here made this census churn by
      -- one every time a handler module gained its first GMCP writer, which
      -- says nothing about MIP porting completeness -- what this census is
      -- for.
      if key ~= "_patterns" and key ~= "_market_seam" and key ~= "_gmcp" then
        keys[#keys + 1] = key
      end
    end
  end
  table.sort(keys)
  return keys
end

local function collect_patterns()
  local pats = {}
  for _, mod in ipairs({ trade, voyage, kingdom, city }) do
    for _, p in ipairs(mod._patterns or {}) do
      pats[#pats + 1] = p.pattern
    end
  end
  table.sort(pats)
  return pats
end

local function same_set(list, expected)
  if #list ~= #expected then return false, ("count %d ~= %d"):format(#list, #expected) end
  local sorted_expected = {}
  for i, v in ipairs(expected) do sorted_expected[i] = v end
  table.sort(sorted_expected)
  for i, v in ipairs(list) do
    if v ~= sorted_expected[i] then
      return false, ("mismatch at %d: %s ~= %s"):format(i, v, sorted_expected[i])
    end
  end
  return true
end

local actual_keys = collect_exact_keys()
local ok_keys, err_keys = same_set(actual_keys, EXPECTED_EXACT_KEYS)
check("census exact keys match hardcoded list", ok_keys, err_keys)
check("census exact key count is 108", #actual_keys == 108, #actual_keys)

-- ---- Census: which MIP keys have a GMCP writer ----------------------------
-- The migration's own progress bar. A key listed here is fed by GMCP when the
-- server sends its panel, and protocol.ingest's per-key latch then suppresses
-- the MIP copy; a key absent from it is still MIP-only. This is the list to
-- extend as each panel's writers land, and it is what makes an accidentally
-- unregistered writer visible -- init.lua registers `_gmcp` for every handler
-- module, so a writer defined but left out of the table would otherwise just
-- silently never run.
local EXPECTED_GMCP_WRITERS = {
  -- Guild.Settlement (9 MIP keys; 10 GMCP keys, since SROLES is a composite
  -- over `sroles` and `sroles_meta`)
  "SETTLERS", "SETTLERX", "SACTIONS", "SHPLOTS", "SCONSUME", "SPROJ",
  "SEVENTS", "SCIVICS", "SROLES",
  -- Guild.Map (1, composite over all eleven of its payload keys)
  "VMAP",
  -- Guild.Fleet (4)
  "SHIPS", "SUPG", "RAIDLOG", "RTARGETS",
  -- Guild.Roster (10)
  "STAFF", "BONDS", "TRAIN", "COURIER", "SPY", "VFIND", "HIRD", "THRALLS",
  "THRALL_FOLLOWER", "VARANG",
  -- Guild.Trade (10; TGOODS deliberately stays MIP-only until its GMCP source
  -- lands -- see the gap note in gmcp_map.lua)
  "CARTS", "TQUEUE", "CIDLE", "CUPG", "ROUTES", "BLOCKS", "REFINERY", "MARKET",
  "INCOMING", "WSTOCK",
}

local function collect_gmcp_writers()
  local keys = {}
  for _, mod in ipairs({ trade, voyage, kingdom, city }) do
    for key in pairs(mod._gmcp or {}) do keys[#keys + 1] = key end
  end
  table.sort(keys)
  return keys
end

local actual_writers = collect_gmcp_writers()
local ok_w, err_w = same_set(actual_writers, EXPECTED_GMCP_WRITERS)
check("census GMCP writers match hardcoded list", ok_w, err_w)

local actual_patterns = collect_patterns()
local ok_pats, err_pats = same_set(actual_patterns, EXPECTED_PATTERNS)
check("census patterns match hardcoded list", ok_pats, err_pats)
check("census pattern count is 6", #actual_patterns == 6, #actual_patterns)

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING CITY TESTS PASSED")
