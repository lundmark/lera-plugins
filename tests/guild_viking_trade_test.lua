-- guild_viking handlers/trade.lua unit tests. Run from the lera-plugins repo
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

-- ---- lera API stubs (same shape as guild_viking_test.lua) -------------------
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
local trade = require("handlers.trade")
for key, fn in pairs(trade) do
  if key ~= "_market_seam" then protocol.handler(key, fn) end
end

-- CARTS (LEGACY 941): mode|good|village|return_in|amount|halfway_in|quality|
--   cart_id|tier|durability|cap|escorts|refit|legs  (>=14 fields -> refit at 13)
protocol.ingest("CARTS",
  "sell|fish|Havn|120|40|60|85|c1|2|90|50|1|armored|leg1,leg2;buy|salt|Fjord|30|10|15|70|c2|1|80|40|0||")
check("carts count", #S.carts == 2)
check("cart fields", S.carts[1].good == "fish" and S.carts[1].village == "Havn"
      and tonumber(S.carts[1].return_in) == 120)
check("cart refit", S.carts[1].refit == "armored")
check("cart default refit", S.carts[2].refit == "standard")

-- CARTS safety cap: 31 entries -> capped at 30
do
  local entries = {}
  for i = 1, 31 do
    entries[#entries + 1] = string.format("sell|fish|Havn|10|1|1|100|c%d|1|100|10|0||", i)
  end
  protocol.ingest("CARTS", table.concat(entries, ";"))
  check("carts safety cap", #S.carts == 30)
end

-- DALER (LEGACY 2486): plain number
protocol.ingest("DALER", "1234")
check("daler", S.daler == 1234)

-- COURIER (LEGACY 978): "<tier>!<entries>"; entry good|village|secs|amount|cost|fee
protocol.ingest("COURIER", "2!fish|Havn|100|20|50|5;salt|Fjord|80|15|40|3")
check("courier tier", S.courier.tier == 2)
check("courier runs count", #S.courier.runs == 2)
check("courier run fields", S.courier.runs[1].good == "fish" and S.courier.runs[1].village == "Havn"
      and S.courier.runs[1].return_in == 100)

-- SPY (LEGACY 993): "<tier>|<mode>|<village>|<secs>|<sabpct>|<sabsecs>|<cdsecs>!<scouts>"
protocol.ingest("SPY", "3|scout|Havn|120|50|30|10!Fjord:20:5;Bergen:10:15")
check("spy scalar fields", S.spy.tier == 3 and S.spy.mode == "scout" and S.spy.village == "Havn")
check("spy scouts count", #S.spy.scouts == 2)
check("spy scout fields", S.spy.scouts[1].city == "Fjord" and S.spy.scouts[1].amb == 20)

-- HEAT (LEGACY 1015): ";"-separated numbers
protocol.ingest("HEAT", "10;20;30")
check("heat count", #S.heat == 3)
check("heat values", S.heat[1] == 10 and S.heat[3] == 30)

-- TRAIN (LEGACY 1020): "<tier>|<name>|<stat>|<trained>|<secs>"
protocol.ingest("TRAIN", "2|Bjorn|strength|5|300")
check("train fields", S.train.tier == 2 and S.train.name == "Bjorn" and S.train.stat == "strength"
      and S.train.trained == 5)

-- CUPG (LEGACY 1031): cid|ttier|sleft|mt|md|mat_str|target_refit|job_type
protocol.ingest("CUPG", "5|3|120|2|1|iron:1/2,timber:5/5||;7|2|0|0|0||armored|")
check("cupg count", #S.cart_upgrades == 2)
check("cupg mats", #S.cart_upgrades[1].mats == 2 and S.cart_upgrades[1].mats[1].good == "iron"
      and S.cart_upgrades[1].mats[1].done == 1 and S.cart_upgrades[1].mats[1].need == 2)
check("cupg default job_type", S.cart_upgrades[1].job_type == "upgrade")
check("cupg refit job_type", S.cart_upgrades[2].target_refit == "armored"
      and S.cart_upgrades[2].job_type == "refit")

-- CIDLE (LEGACY 1060): cid|ctier|cdur|ccap|crefit (5-field), or 4-field fallback -> "standard"
protocol.ingest("CIDLE", "c1|2|90|50|armored;c2|1|80|40")
check("cidle count", #S.idle_carts == 2)
check("cidle refit", S.idle_carts[1].refit == "armored" and S.idle_carts[2].refit == "standard")

-- TQUEUE (LEGACY 1074): legs joined by "!", fields mode|good|amount|village(|escort on last leg)
protocol.ingest("TQUEUE", "buy|fish|20|Havn|3")
check("tqueue count", #S.trade_queue == 1)
check("tqueue fields", S.trade_queue[1].good == "fish" and S.trade_queue[1].village == "Havn"
      and S.trade_queue[1].escort == 3)

-- WSTOCK (LEGACY 1411): good|amount|pct  or good|amount|pct|gradelabel
protocol.ingest("WSTOCK", "fish|40|90;salt|100|100|coarse")
check("wstock count", #S.wstock == 2)
check("wstock fields", S.wstock[1].good == "fish" and S.wstock_by_good.fish.amount == 40)
check("wstock grade", S.wstock[2].grade == "coarse")

-- WSTOCK safety cap: 51 entries -> capped at 50
do
  local entries = {}
  for i = 1, 51 do
    entries[#entries + 1] = string.format("good%d|1|100", i)
  end
  protocol.ingest("WSTOCK", table.concat(entries, ";"))
  check("wstock safety cap", #S.wstock == 50)
end

-- BLOCKS (LEGACY 1430): good:amount pairs
protocol.ingest("BLOCKS", "fish:10;salt:5")
check("blocks fields", S.blocks.fish == 10 and S.blocks.salt == 5)

-- CELLAR (LEGACY 1437): stock|cap|tier;qty|pct;qty|pct
protocol.ingest("CELLAR", "500|1000|2;50|90;30|75")
check("cellar header", S.cellar.stock == 500 and S.cellar.cap == 1000 and S.cellar.tier == 2)
check("cellar lots", #S.cellar.lots == 2 and S.cellar.lots[1].qty == 50 and S.cellar.lots[1].pct == 90)

-- REFINERY (LEGACY 1455): bid:tier:stock:cap:grades  (grades: name,qty,pct;name,qty)
protocol.ingest("REFINERY", "r1:2:100:200:iron,50,90;steel,20")
check("refinery count", #S.refineries == 1)
check("refinery fields", S.refineries[1].id == "r1" and S.refineries[1].tier == 2)
check("refinery grades", #S.refineries[1].grades == 2 and S.refineries[1].grades[1].name == "iron"
      and S.refineries[1].grades[1].qty == 50 and S.refineries[1].grades[1].pct == 90)
check("refinery grade fallback pct", S.refineries[1].grades[2].name == "steel"
      and S.refineries[1].grades[2].qty == 20 and S.refineries[1].grades[2].pct == 100)

-- ROUTES (LEGACY 2168): vid|vname|road_tier|fort_tier|road_maint|fort_maint|road_name|fort_name
protocol.ingest("ROUTES", "v1|Havn|2|1|50|20|King's Road|Fort Alpha")
check("routes fields", S.routes.v1.name == "Havn" and S.routes.v1.road_tier == 2
      and S.routes.v1.fort_maint == 20 and S.routes.v1.road_name == "King's Road")

-- RUPKEEP (LEGACY 2186): plain number
protocol.ingest("RUPKEEP", "75")
check("rupkeep", S.route_upkeep == 75)

-- UPKEEP (LEGACY 2188): ro|co|th|rd|fo|tot
protocol.ingest("UPKEEP", "10|20|5|15|8|58")
check("upkeep fields", S.upkeep.roster == 10 and S.upkeep.community == 20 and S.upkeep.total == 58)

-- RBUILD (LEGACY 2197): vid|vname|kind|tier|mt|md|cs|tbs|mat_str, keyed "kind:vid"
protocol.ingest("RBUILD", "v1|Havn|road|2|4|1|300|600|timber:1/4,ore:0/2")
check("rbuild fields", S.route_builds["road:v1"].vid == "v1" and S.route_builds["road:v1"].tier == 2
      and S.route_builds["road:v1"].mats_total == 4 and S.route_builds["road:v1"].complete_at_secs == 300)
check("rbuild mats", #S.route_builds["road:v1"].mats == 2 and S.route_builds["road:v1"].mats[1].good == "timber"
      and S.route_builds["road:v1"].mats[1].done == 1 and S.route_builds["road:v1"].mats[1].need == 4)

-- STAFF (LEGACY 2346): name|assigned_to|stat_key|stats_s|trait|loyalty|age|arrive_at
protocol.ingest("STAFF", "Bjorn|w1|trade|5,3,2,1,4,2,1|2|4|veteran|1000")
check("staff count", #S.staff_list == 1)
check("staff fields", S.staff_list[1].name == "Bjorn" and S.staff_list[1].loyalty == 4
      and S.staff_list[1].arrive_at == 1000)
check("staff stats", S.staff_list[1].stats.combat == 5 and S.staff_list[1].stats.trade == 3)

-- STAFF safety cap: 51 entries -> capped at 50
do
  local entries = {}
  for i = 1, 51 do
    entries[#entries + 1] = string.format("Staff%d|w1||||||", i)
  end
  protocol.ingest("STAFF", table.concat(entries, ";"))
  check("staff safety cap", #S.staff_list == 50)
end

-- BONDS (LEGACY 2372): fa|fb|ticks|tier
protocol.ingest("BONDS", "1|2|100|3;4|5|50|2")
check("bonds count", #S.bonds_list == 2)
check("bonds fields", S.bonds_list[1].id_a == 1 and S.bonds_list[1].id_b == 2
      and S.bonds_list[1].ticks == 100 and S.bonds_list[1].tier == 3)

-- MARKET (LEGACY 2459): id|buyer|good|remaining|price|age_secs; seam invoked with the list
local market_seam_calls = {}
trade._market_seam.on_market = function(orders) market_seam_calls[#market_seam_calls + 1] = orders end
protocol.ingest("MARKET", "1|PlayerA|fish|20|15|300")
check("market count", #S.market_orders == 1)
check("market fields", S.market_orders[1].id == 1 and S.market_orders[1].buyer == "PlayerA"
      and S.market_orders[1].good == "fish" and S.market_orders[1].remaining == 20)
check("market seam invoked", #market_seam_calls == 1 and market_seam_calls[1] == S.market_orders)
trade._market_seam.on_market = nil

-- INCOMING (LEGACY 2474): good|amount|arrives_in|seller
protocol.ingest("INCOMING", "fish|20|60|PlayerB")
check("incoming count", #S.incoming_fills == 1)
check("incoming fields", S.incoming_fills[1].good == "fish" and S.incoming_fills[1].amount == 20
      and S.incoming_fills[1].arrives_in == 60 and S.incoming_fills[1].seller == "PlayerB")

-- TGOODS (LEGACY 2581): "lin=abbr:score:sup:dem:buy:sell;..." lineages joined by "|";
-- seam invoked only when buy > 0 or sell > 0 (mirrors record_price_history's gate).
local tgoods_seam_calls = {}
trade._market_seam.on_tgoods = function(lin, good, buy, sell)
  tgoods_seam_calls[#tgoods_seam_calls + 1] = { lin, good, buy, sell }
end
protocol.ingest("TGOODS", "0=t:3:10:20:5:8;h:-1:5:3:0:0|1=i:2:50:60:12:15")
check("tgoods lineage 0", S.trade_goods[0].timber.buy == 5 and S.trade_goods[0].timber.sell == 8
      and S.trade_goods[0].timber.score == 3 and S.trade_goods[0].timber.demand == 20)
check("tgoods lineage 0 zero-price good present", S.trade_goods[0].fish ~= nil
      and S.trade_goods[0].fish.buy == 0)
check("tgoods lineage 1", S.trade_goods[1].iron.demand == 60 and S.trade_goods[1].iron.sell == 15)
check("tgoods seam count", #tgoods_seam_calls == 2)
check("tgoods seam args", tgoods_seam_calls[1][1] == 0 and tgoods_seam_calls[1][2] == "timber"
      and tgoods_seam_calls[1][3] == 5 and tgoods_seam_calls[1][4] == 8)
check("tgoods seam skips zero-price good", tgoods_seam_calls[2][2] == "iron")
trade._market_seam.on_tgoods = nil

-- VFIND (LEGACY 2624): "<tier>!<posts>!<offers>!<aucs>"
protocol.ingest("VFIND", "1!p1|str|5|100|brave|open!o1|Erik|50|2|300!a1|Sven|200|150|600")
check("vfind tier", S.vfind.tier == 1)
check("vfind postings", #S.vfind.postings == 1 and S.vfind.postings[1].stat == "str")
check("vfind offers", #S.vfind.offers == 1 and S.vfind.offers[1].name == "Erik")
check("vfind auctions", #S.vfind.auctions == 1 and S.vfind.auctions[1].name == "Sven"
      and S.vfind.auctions[1].reserve == 200)

-- market.lua: price history recording, rolling-window trim, statistics,
-- trend, and demand-cycle color (LEGACY guild_viking.lua:357-418), wired
-- through handlers/trade.lua's _market_seam.on_tgoods.
local market = require("market")
trade._market_seam.on_tgoods = market.on_tgoods

-- Two TGOODS fixtures at different timestamps: history appends oldest-first
-- (LEGACY 360-372, record_price_history).
lera.time = function() return 1000 end
protocol.ingest("TGOODS", "0=t:3:10:20:5:8")
lera.time = function() return 2000 end
protocol.ingest("TGOODS", "0=t:3:10:20:6:9")
local hist = S.price_history[0].timber
check("price history count", #hist == 2)
check("price history oldest first", hist[1].t == 1000 and hist[1].b == 5 and hist[1].s == 8
      and hist[2].t == 2000 and hist[2].b == 6 and hist[2].s == 9)

-- De-duplicated: an unchanged buy/sell does not append another sample
-- (LEGACY:369, "one sample per market shift").
lera.time = function() return 3000 end
protocol.ingest("TGOODS", "0=t:3:10:20:6:9")
check("price history dedup", #S.price_history[0].timber == 2)

-- Rolling-window trim at LEGACY's PRICE_HIST_MAX = 48 (LEGACY:357): the 49th
-- distinct sample drops the oldest, leaving exactly 48, boundary at 48/49.
for i = 1, 49 do
  lera.time = function() return i end
  protocol.ingest("TGOODS", string.format("9=i:2:50:60:%d:%d", i, i + 100))
end
local trimmed = S.price_history[9].iron
check("price history trim count", #trimmed == 48)
check("price history trim drops oldest", trimmed[1].t == 2 and trimmed[1].b == 2
      and trimmed[48].t == 49 and trimmed[48].b == 49)

-- Statistics (LEGACY 375-393): hand-computed from the two-sample timber
-- history above (buy 5,6 / sell 8,9 -> bavg=5.5, savg=8.5).
local stats = market.price_stats(0, "timber")
check("price stats", stats.n == 2 and stats.bmin == 5 and stats.bmax == 6
      and stats.bavg == 5.5 and stats.smin == 8 and stats.smax == 9 and stats.savg == 8.5)
check("price stats missing good", market.price_stats(0, "nosuchgood") == nil)

-- Trend vs that same average (LEGACY 397-407): thr = max(1, avg*0.04) = 1
-- here, so cur=7 crosses above and cur=4 crosses below.
local arrow_up, col_up = market.price_trend(7, stats.bavg, true)
check("price trend up is bad for buy", arrow_up == "^" and col_up == 0xFF4444)
local arrow_down, col_down = market.price_trend(4, stats.bavg, true)
check("price trend down is good for buy", arrow_down == "v" and col_down == 0x00FF00)
local arrow_flat = market.price_trend(stats.bavg, stats.bavg, true)
check("price trend flat", arrow_flat == "=")
local arrow_nil, col_nil = market.price_trend(100, nil, true)
check("price trend nil avg", arrow_nil == " " and col_nil == 0x999999)

-- Demand-cycle color helper (LEGACY 409-418).
check("demand cycle color spring", market.demand_cycle_color("Spring Growth") == 0x88DD44)
check("demand cycle color summer", market.demand_cycle_color("Summer Heat") == 0x44CCDD)
check("demand cycle color autumn", market.demand_cycle_color("Autumn Harvest") == 0x4488DD)
check("demand cycle color fall alias", market.demand_cycle_color("Fall Frenzy") == 0x4488DD)
check("demand cycle color winter", market.demand_cycle_color("Winter Frost") == 0xCCCCCC)
check("demand cycle color calm", market.demand_cycle_color("Calm Season") == 0xCCCC00)
check("demand cycle color unknown default", market.demand_cycle_color("") == 0xCCCC00)

-- snapshot()/restore() round-trip: the persisted subset is price_history.
local snap = market.snapshot()
check("snapshot has price_history", snap.price_history == S.price_history)
local saved = S.price_history
S.price_history = {}
market.restore(snap)
check("restore round-trips", S.price_history == saved)
market.restore(nil)
check("restore nil-safe", S.price_history == saved)

trade._market_seam.on_tgoods = nil

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING TRADE TESTS PASSED")
