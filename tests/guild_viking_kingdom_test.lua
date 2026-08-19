-- guild_viking handlers/kingdom.lua unit tests. Run from the lera-plugins repo
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

-- ---- lera API stubs (same shape as guild_viking_voyage_test.lua) ----------
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
local kingdom = require("handlers.kingdom")
for key, fn in pairs(kingdom) do
  if key ~= "_patterns" then protocol.handler(key, fn) end
end
for _, p in ipairs(kingdom._patterns or {}) do
  protocol.pattern_handler(p.pattern, p.fn)
end

-- RAIDLOG (LEGACY 1127): ship|target|daler|thralls|lost(0/1)|good:qty,...;...  cap 20
protocol.ingest("RAIDLOG", "Ormen|Havn|300|2|1|fish:5,salt:2;Drage|Fjord|100|0|0|")
check("raidlog count", #S.raidlog == 2)
check("raidlog fields", S.raidlog[1].ship == "Ormen" and S.raidlog[1].target == "Havn"
      and S.raidlog[1].daler == 300 and S.raidlog[1].lost == true)
check("raidlog goods", #S.raidlog[1].goods == 2 and S.raidlog[1].goods[1].good == "fish"
      and S.raidlog[1].goods[1].qty == 5)
check("raidlog second not lost", S.raidlog[2].lost == false)

do
  local entries = {}
  for i = 1, 21 do
    entries[#entries + 1] = string.format("Ship%d|Town|10|0|0|", i)
  end
  protocol.ingest("RAIDLOG", table.concat(entries, ";"))
  check("raidlog safety cap", #S.raidlog == 20)
end

-- RTARGETS (LEGACY 1143): "lin;lin;...|hist;hist;..." each "name:g1:g2"
protocol.ingest("RTARGETS", "Havn:fish:salt;Fjord:furs:|Alt:silver:")
check("rtargets flat", #S.raid_targets == 3)
check("rtargets lin", #S.raid_targets_lin == 2 and S.raid_targets_lin[1].name == "Havn"
      and S.raid_targets_lin[1].g1 == "fish" and S.raid_targets_lin[1].g2 == "salt")
check("rtargets lin nil g2", S.raid_targets_lin[2].g2 == nil)
check("rtargets hist", #S.raid_targets_hist == 1 and S.raid_targets_hist[1].name == "Alt")

-- DYNASTY (LEGACY 1478): realm|house|spouseName:spouseHouse:spouseAge:rank|heir|living:cap|child;...
protocol.ingest("DYNASTY", "Norheim|Ivarsson|Sigrid:Haraldsson:28:2|Bjorn|3:5|Astrid,f,10,0,brave,-;Bjorn,m,16,1,strong,heir")
check("dynasty fields", S.dynasty.realm == "Norheim" and S.dynasty.house == "Ivarsson"
      and S.dynasty.heir == "Bjorn")
check("dynasty spouse", S.dynasty.spouse.name == "Sigrid" and S.dynasty.spouse.rank == 2)
check("dynasty counts", S.dynasty.living == 3 and S.dynasty.cap == 5)
check("dynasty children", #S.dynasty.children == 2 and S.dynasty.children[1].name == "Astrid"
      and S.dynasty.children[1].adult == false and S.dynasty.children[1].role == nil)
check("dynasty children role", S.dynasty.children[2].role == "heir")

protocol.ingest("DYNASTY", "")
check("dynasty cleared on empty", S.dynasty == nil)

-- ARMY (LEGACY 1511): conscripts|cap|used|uid,type,size,vet,ready(0/1),leader,traits;...
protocol.ingest("ARMY", "10|20|5|1,hird,50,2,1,Erik,brave:strong")
check("army fields", S.army.conscripts == 10 and S.army.cap == 20 and S.army.used == 5)
check("army units", #S.army.units == 1 and S.army.units[1].uid == 1 and S.army.units[1].type == "hird"
      and S.army.units[1].ready == true)
check("army traits", #S.army.units[1].traits == 2 and S.army.units[1].traits[1] == "brave")

-- ARMY back-compat 6-field unit form (no traits)
protocol.ingest("ARMY", "10|20|5|1,hird,50,2,1,Erik")
check("army unit fallback traits empty", #S.army.units[1].traits == 0
      and S.army.units[1].leader == "Erik")

protocol.ingest("ARMY", "")
check("army cleared on empty", S.army == nil)

-- BATTLE (LEGACY 1544): active|phase|turn|warpoints|mode|target|budget:spent|w:h:dz|terrain|works|units
-- 2x2 terrain/works grids, one fielded unit and one reserve unit.
protocol.ingest("BATTLE",
  "1|deploy|1|15|offense|Havn|100:20|2:2:1|..#.|....|" ..
  "Y,you1,10,A1,80,hird,Erik,101,0;R,res1,5,55,10,Bjorn")
check("battle active", S.battle ~= nil and S.battle.phase == "deploy" and S.battle.turn == 1)
check("battle war_points", S.war_points == 15)
check("battle dims", S.battle.width == 2 and S.battle.height == 2 and S.battle.dz == 1)
check("battle budget", S.battle.budget == 100 and S.battle.spent == 20)
check("battle terrain rows", #S.battle.terrain_rows == 2 and S.battle.terrain_rows[1] == "..")
check("battle works rows", #S.battle.works_rows == 2 and S.battle.works_rows[2] == "..")
check("battle fielded unit", #S.battle.units == 1 and S.battle.units[1].side == "you"
      and S.battle.units[1].label == "you1" and S.battle.units[1].bid == 101)
check("battle reserve unit", #S.battle.reserve == 1 and S.battle.reserve[1].uid == 55
      and S.battle.reserve[1].leader == "Bjorn")

-- BATTLE inactive (active flag 0): only war_points recorded, no state.battle
-- 11 fields: active=0, phase="", turn="", wp=3, mode..units all empty.
protocol.ingest("BATTLE", "0|||3|||||||")
check("battle inactive clears battle, keeps war_points", S.battle == nil and S.war_points == 3)

-- DIPLO (LEGACY 1636): allies:House@standing,...|foes:House@standing,...
protocol.ingest("DIPLO", "allies:Ivarsson@50,Haraldsson@10|foes:Ragnarsson@-20")
check("diplo allies", #S.diplomacy.allies == 2 and S.diplomacy.allies[1].house == "Ivarsson"
      and S.diplomacy.allies[1].standing == 50)
check("diplo foes", #S.diplomacy.foes == 1 and S.diplomacy.foes[1].standing == -20)

protocol.ingest("DIPLO", "")
check("diplo cleared on empty", S.diplomacy == nil)

-- WAR (LEGACY 1655): cb:Town@days,...|incoming:Town@days@strength|camp:Town@def@max,...
protocol.ingest("WAR", "cb:Havn@3,Fjord@1|incoming:Alt@2@120|camp:Havn@40@100")
check("war claims", #S.war.claims == 2 and S.war.claims[1].town == "Havn" and S.war.claims[1].days == 3)
check("war incoming", S.war.incoming.town == "Alt" and S.war.incoming.strength == 120)
check("war campaigns", #S.war.campaigns == 1 and S.war.campaigns[1].defense == 40 and S.war.campaigns[1].max == 100)

protocol.ingest("WAR", "")
check("war cleared on empty", S.war == nil)

-- WMAP -> WMR -> WMEND flow (LEGACY 1914-2029): double-buffered war-map,
-- committed only on WMEND when the expected row count matches.
protocol.ingest("WMAP", "1|2|4|offense|1|Havn|500|30")
check("wmap pending active", S.wm_pending.active == true and S.wm_pending.dim == 2
      and S.wm_pending.turn == 4 and S.wm_pending.town == "Havn")
check("wmap pending march_eta", S.wm_pending.march_eta == 30)

-- WMU (LEGACY 1929): per-tile upkeep food|mead|tools|iron|daler
protocol.ingest("WMU", "10|5|2|1|50")
check("wmu upkeep", S.wm_pending.upkeep.food == 10 and S.wm_pending.upkeep.daler == 50)

-- WMP (LEGACY 1938): held|capacity|kin|pendingFlag|pendName|pendSize|pendCmd
protocol.ingest("WMP", "3|10|1|1|Bjorn|2|0")
check("wmp prison", S.wm_pending.prison.held == 3 and S.wm_pending.prison.cap == 10
      and S.wm_pending.prison.pending == true and S.wm_pending.prison.pend_name == "Bjorn")

-- WSPOIL (LEGACY 1948): daler|renown|deedCount
protocol.ingest("WSPOIL", "200|15|2")
check("wspoil", S.wm_pending.spoils.daler == 200 and S.wm_pending.spoils.renown == 15
      and S.wm_pending.spoils.deeds == 2)

-- WSG (LEGACY 1956): engines|capacity
protocol.ingest("WSG", "3|5")
check("wsg", S.wm_pending.siege.engines == 3 and S.wm_pending.siege.cap == 5)

-- WMPL (LEGACY 1963): captive roster id,name,size,cmd,val;...
protocol.ingest("WMPL", "1,Bjorn,2,0,10;2,Astrid,1,1,5")
check("wmpl roster", #S.wm_pending.prison.roster == 2 and S.wm_pending.prison.roster[1].name == "Bjorn"
      and S.wm_pending.prison.roster[1].cmd == false)
check("wmpl roster cmd true", S.wm_pending.prison.roster[2].cmd == true)

-- WMR%d%d (LEGACY 1975, pattern-dispatched): row content keyed by a 2-digit
-- row index embedded in the key itself (0-indexed -> 1-indexed).
protocol.ingest("WMR00", "..")
protocol.ingest("WMR01", "#.")
check("wmr row 0 lands at index 1", S.wm_pending.rows[1] == "..")
check("wmr row 1 lands at index 2", S.wm_pending.rows[2] == "#.")

-- WMO (LEGACY 1980): "A:c,r,size,f" (yours), "*:c,r,0" (objective), "<n>:c,r,size,f" (enemy)
protocol.ingest("WMO", "A:0,0,10,N;*:1,1,0")
check("wmo count", #S.wm_pending.units == 2)
check("wmo own unit", S.wm_pending.units[1].id == "A" and S.wm_pending.units[1].size == 10
      and S.wm_pending.units[1].f == "N")
check("wmo objective", S.wm_pending.units[2].id == "*" and S.wm_pending.units[2].size == 0
      and S.wm_pending.units[2].f == "")

-- WMQ (LEGACY 1994): "A:A1;B2|F:C3" queued paths per unit (1-based col letter/row)
protocol.ingest("WMQ", "A:A1;B2|F:C3")
check("wmq per-unit", S.wm_pending.queues.A ~= nil and #S.wm_pending.queues.A == 2
      and S.wm_pending.queues.A[1].c == 0 and S.wm_pending.queues.A[1].r == 0)
check("wmq second unit", S.wm_pending.queues.F ~= nil and #S.wm_pending.queues.F == 1
      and S.wm_pending.queues.F[1].c == 2 and S.wm_pending.queues.F[1].r == 2)
check("wmq default queue aliases unit A", S.wm_pending.queue == S.wm_pending.queues.A)

-- WMEND (LEGACY 2014): commits wm_pending -> war_map/prison/siege when the
-- row count matches; both are populated above, so this should commit.
protocol.ingest("WMEND", "2")
check("wmend commits war_map", S.war_map ~= nil and #S.war_map.rows == 2 and S.war_map.town == "Havn")
check("wmend commits prison/siege", S.prison.held == 3 and S.siege.engines == 3)
check("wmend clears pending", S.wm_pending == nil)

-- WMEND with active=0 clears war_map (build a fresh pending batch first)
protocol.ingest("WMAP", "0|1|1|offense|0|Havn|0|0")
protocol.ingest("WMEND", "0")
check("wmend inactive clears war_map", S.war_map == nil)
check("wmend inactive clears pending", S.wm_pending == nil)

-- WMEND with mismatched row count: keeps the previous war_map (still nil here)
protocol.ingest("WMAP", "1|3|1|offense|0|Havn|0|0")
protocol.ingest("WMR00", "...")
protocol.ingest("WMEND", "3")
check("wmend mismatch does not commit", S.war_map == nil)

-- PATROL (LEGACY 2031): count|remaining
protocol.ingest("PATROL", "3|2")
check("patrol", S.patrol.count == 3 and S.patrol.remaining == 2)

-- GARRISON (LEGACY 2094): stationed|free|cap|defpower
protocol.ingest("GARRISON", "5|3|10|40")
check("garrison", S.garrison_stationed == 5 and S.garrison_free == 3
      and S.garrison_cap == 10 and S.garrison_defpower == 40)

-- VARANG (LEGACY 2102): out;out^in;in  (name|count|expires_in entries), cap 30 each
protocol.ingest("VARANG", "Havn|2|100;Fjord|1|50^Alt|3|20")
check("varang out", #S.varang_out == 2 and S.varang_out[1].name == "Havn" and S.varang_out[1].count == 2)
check("varang in", #S.varang_in == 1 and S.varang_in[1].name == "Alt" and S.varang_in[1].expires_in == 20)

-- THRALLS (LEGACY 2117): total|per-building-count in fixed bldg_order
protocol.ingest("THRALLS", "12|3|2|1")
check("thralls total", S.thralls == 12)
check("thralls assignments", S.thrall_assignments.longhouse == 3 and S.thrall_assignments.warehouse == 2
      and S.thrall_assignments.farm == 1)
check("thralls convenience fields", S.thralls_longhouse == 3 and S.thralls_warehouse == 2)

-- THRALL_FOLLOWER (LEGACY 2128): lvl|name|xp|xp_cap|carry_used|carry_cap|state
protocol.ingest("THRALL_FOLLOWER", "2|Rurik|30|100|5|10|following")
check("thrall_follower fields", S.thrall_follower_level == 2 and S.thrall_follower_name == "Rurik"
      and S.thrall_follower_xp == 30 and S.thrall_follower_status == "following")

-- RAID (LEGACY 2142): in|faction|strength
protocol.ingest("RAID", "120|Ragnarsson|60")
check("raid", S.raid_in == 120 and S.raid_faction == "Ragnarsson" and S.raid_strength == 60)

-- GRUDGES (LEGACY 2149): town:secs_left,...
protocol.ingest("GRUDGES", "Havn:200,Fjord:50")
check("grudges count", #S.grudges == 2)
check("grudges fields", S.grudges[1].town == "Havn" and S.grudges[1].secs == 200)

protocol.ingest("GRUDGES", "")
check("grudges empty clears", #S.grudges == 0)

-- BDMG (LEGACY 2338): bldg_id|pct;...
protocol.ingest("BDMG", "longhouse|40;warehouse|10")
check("bdmg count", #S.bdmg == 2)
check("bdmg fields", S.bdmg[1].bldg_id == "longhouse" and S.bdmg[1].pct == 40)

-- STANDINGS (LEGACY 2384): lin_id|name|score|label|is_own(0/1);... keyed by lin_id
protocol.ingest("STANDINGS", "1|Ivarsson|500|Jarl|1;2|Haraldsson|300|Karl|0")
check("standings fields", S.standings[1].name == "Ivarsson" and S.standings[1].score == 500
      and S.standings[1].is_own == true)
check("standings second", S.standings[2].label == "Karl" and S.standings[2].is_own == false)

-- VREP (LEGACY 2398): lin_id|name|rep|rank|start_at|next_at;... keyed by lin_id
protocol.ingest("VREP", "1|Havn|20|2|0|100")
check("vrep fields", S.village_rep[1].name == "Havn" and S.village_rep[1].rep == 20
      and S.village_rep[1].rank == 2 and S.village_rep[1].next_at == 100)

-- HIRD (LEGACY 2413): entries separated by ";", fields WITHIN an entry
-- separated by "|" (unlike most other keys' comma-separated sub-fields):
-- id|name|status|level|atk|def|loy|hired|age_phase|mode|champ|wpn|arm
-- (13-field newest form; also exercise the 6-field back-compat fallback)
protocol.ingest("HIRD", "5|Bjorn|active|3|10|8|4|100|veteran|offensive|1|2|1")
check("hird fields", #S.hird_list == 1 and S.hird_list[1].name == "Bjorn"
      and S.hird_list[1].level == 3 and S.hird_list[1].mode == "offensive")
check("hird champ/wpn/arm", S.hird_list[1].champ == 1 and S.hird_list[1].wpn == 2 and S.hird_list[1].arm == 1)
check("hird by_id", S.hird_by_id[5] ~= nil and S.hird_by_id[5].name == "Bjorn")

-- HIRD 6-field back-compat form (no id -> hird_by_id not populated for this entry)
protocol.ingest("HIRD", "Astrid|active|2|8|6|3")
check("hird fallback fields", #S.hird_list == 1 and S.hird_list[1].name == "Astrid"
      and S.hird_list[1].mode == "neutral")

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING KINGDOM TESTS PASSED")
