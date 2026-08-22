-- guild_viking autotrader/core.lua unit tests (stage 4 Task 1: settings,
-- warehouse/cart policy, quality math). Ported verbatim from LEGACY
-- guild_viking_autotrader.lua:19-296. Run from the lera-plugins repo root
-- with LERA_ROOT pointing at a built Lera checkout.
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

-- ---- lera API stubs (same shape as guild_viking_trade_test.lua) -----------
ui = { dirty = function() end }
lera = { time = function() return 1000 end, version = function() return "test" end }
local stored = nil
store = {
  load = function() end,
  get = function() return stored end,
  set = function(d) stored = d end,
  save = function() end,
}

local protocol = require("protocol")
local S = require("state").S
local trade = require("handlers.trade")
for key, fn in pairs(trade) do
  if key ~= "_market_seam" then protocol.handler(key, fn) end
end
local city = require("handlers.city")
for key, fn in pairs(city) do
  if key ~= "_patterns" then protocol.handler(key, fn) end
end

local at_core = require("autotrader.core")

-- ---------------------------------------------------------------------------
-- at_settings (LEGACY:19-31): default-knob guard, exercised on both the
-- fully-absent branch and the partial-table backfill branch. state.lua
-- normally seeds S.autotrade eagerly (see its own header comment), so this
-- clobbers it directly to exercise both of at_settings' own guard paths --
-- S.autotrade is plugin-local settings state, not a wire-parsed field, so
-- this is the same "direct S poke" market.lua's own test uses for
-- S.trade_goods, not the wire-fixture rule.
-- ---------------------------------------------------------------------------
S.autotrade = nil
local at = at_core.settings()
check("settings: fully-absent defaults",
      at.reserve == 0 and at.min_margin == 3 and at.min_profit == 200
      and at.max_carts == 2 and at.last == 0 and at.use_stock == false
      and at.last_msg == "" and at.show_n == 6 and #at.log == 0
      and at.stock_priority == true and at.auto_stock == 0)

S.autotrade = { reserve = 9 }   -- partial table missing log/min_profit/auto_stock/stock_priority
local at2 = at_core.settings()
check("settings: partial-table backfill preserves existing field",
      at2.reserve == 9)
check("settings: partial-table backfill fills in missing knobs",
      type(at2.log) == "table" and #at2.log == 0 and at2.min_profit == 200
      and at2.auto_stock == 0 and at2.stock_priority == true)
check("settings: partial-table backfill leaves OTHER missing fields alone (verbatim, not a superset)",
      at2.min_margin == nil and at2.max_carts == nil)

-- ---------------------------------------------------------------------------
-- at_log (LEGACY:33-39): appends, then trims to the 40-entry cap, oldest
-- first.
-- ---------------------------------------------------------------------------
S.autotrade = nil
at_core.settings()
for i = 1, 41 do at_core.log({ idx = i }) end
local at3 = at_core.settings()
check("log: capped at 40 entries", #at3.log == 40, #at3.log)
check("log: oldest (idx 1) dropped, idx 2 now first", at3.log[1].jobs.idx == 2)
check("log: newest (idx 41) is last", at3.log[#at3.log].jobs.idx == 41)
check("log: entry carries a t timestamp field", at3.log[1].t ~= nil)

-- ---------------------------------------------------------------------------
-- at_wh_amount (LEGACY:41-50): warehouse total minus vtrade-blocked amount,
-- floored at 0.
-- ---------------------------------------------------------------------------
protocol.ingest("WSTOCK", "salt|100|100")
protocol.ingest("BLOCKS", "salt:30")
check("wh_amount: total 100 minus blocked 30 = 70", at_core.wh_amount("salt") == 70)
protocol.ingest("BLOCKS", "salt:150")
check("wh_amount: blocked exceeding total floors at 0", at_core.wh_amount("salt") == 0)
check("wh_amount: unknown good is 0", at_core.wh_amount("nosuchgood") == 0)

-- ---------------------------------------------------------------------------
-- FIFO-vs-fresh quality (LEGACY:203-243) over a seeded warehouse stock of a
-- perishable good (fish: 3 freshness brackets from WSTOCK, oldest to
-- newest). Hand-computed for amount = 70:
--
--   fresh (newest-first, pct desc: 100/60, 80/40, 50/20):
--     take 60 @ 100%  -> val = 60*100        = 6000
--     take 10 @ 80%   -> val += 10*80 = 800   -> 6800
--     quality = floor(6800/70 + 0.5) = floor(97.142857 + 0.5) = floor(97.642857) = 97
--
--   fifo (oldest-first, pct asc: 50/20, 80/40, 100/60):
--     take 20 @ 50%   -> val = 20*50          = 1000
--     take 40 @ 80%   -> val += 40*80 = 3200  -> 4200
--     take 10 @ 100%  -> val += 10*100 = 1000 -> 5200
--     quality = floor(5200/70 + 0.5) = floor(74.285714 + 0.5) = floor(74.785714) = 74
--
-- fresh (97) and fifo (74) diverge sharply because the newest bracket is
-- much larger (60 units) than the oldest (20 units).
-- ---------------------------------------------------------------------------
protocol.ingest("WSTOCK", "fish|60|100;fish|40|80;fish|20|50")
check("fresh_quality: fish amount 70 -> 97 (hand-computed above)",
      at_core.fresh_quality("fish", 70) == 97, at_core.fresh_quality("fish", 70))
check("fifo_quality: fish amount 70 -> 74 (hand-computed above)",
      at_core.fifo_quality("fish", 70) == 74, at_core.fifo_quality("fish", 70))
check("fresh_quality: non-perishable good always 100", at_core.fresh_quality("timber", 70) == 100)
check("fifo_quality: non-perishable good always 100", at_core.fifo_quality("timber", 70) == 100)
check("fresh_quality: amount < 1 returns 100", at_core.fresh_quality("fish", 0) == 100)
check("fifo_quality: no stock at all returns 100", at_core.fifo_quality("nosuchfish", 5) == 100)

-- ---------------------------------------------------------------------------
-- at_cured_amount / at_cured_premium (LEGACY:161-194) over a seeded mead
-- cellar (WSTOCK freshness brackets for a graded good). AT_CURE_MIN_PCT =
-- 78 (LEGACY:159) gates which brackets count at all.
--
-- Brackets: 10 units @ 100% (>=100 -> premium 1.16), 20 units @ 90%
-- (>=90 -> 1.09), 5 units @ 80% (>=78, <90 -> 1.02), 100 units @ 50%
-- (< 78 -> excluded entirely, both from cured_amount and the premium
-- weighting).
--
--   cured_amount = 10 + 20 + 5           = 35   (the 100-unit 50% bracket is dropped)
--   val = 10*1.16 + 20*1.09 + 5*1.02
--       = 11.6   + 21.8   + 5.1          = 38.5
--   premium = val / qty = 38.5 / 35      = 1.1
-- ---------------------------------------------------------------------------
protocol.ingest("WSTOCK", "mead|10|100;mead|20|90;mead|5|80;mead|100|50")
check("is_graded: mead is graded", at_core.is_graded("mead") == true)
check("is_graded: timber is not graded", at_core.is_graded("timber") == false)
check("cured_amount: mead sums only >=78%-fresh brackets (10+20+5=35)",
      at_core.cured_amount("mead") == 35, at_core.cured_amount("mead"))
check("cured_premium: mead weighted premium = 38.5/35 = 1.1 (hand-computed above)",
      at_core.cured_premium("mead") == 1.1, at_core.cured_premium("mead"))
check("cured_amount: non-graded good returns full wh_amount (no cure gate)",
      at_core.cured_amount("nosuchgraded") == at_core.wh_amount("nosuchgraded"))
check("cured_premium: non-graded good is always 1.0", at_core.cured_premium("timber") == 1.0)
protocol.ingest("WSTOCK", "mead|100|50")   -- nothing cured at all
check("cured_premium: no cured stock at all is 1.0", at_core.cured_premium("mead") == 1.0)

-- ---------------------------------------------------------------------------
-- at_perishable (LEGACY:196-201).
-- ---------------------------------------------------------------------------
check("perishable: grain/fish/honey", at_core.perishable("grain") and at_core.perishable("fish")
      and at_core.perishable("honey"))
check("perishable: mead is NOT perishable (it is graded/ages up instead)",
      at_core.perishable("mead") == false)
check("perishable: durable goods are not perishable", at_core.perishable("timber") == false)

-- ---------------------------------------------------------------------------
-- at_cart_cap (LEGACY:52-65). Signature note: the plan brief's interface
-- list wrote "core.cart_cap(cart)", but LEGACY's at_cart_cap takes NO
-- arguments -- it scans state.idle_carts, falling back to state.carts. This
-- ports as zero-arg to mirror LEGACY's own signature exactly (see this
-- task's report for the full discrepancy note).
-- ---------------------------------------------------------------------------
protocol.ingest("CIDLE", "1|1|100|40|standard;2|2|90|60|heavy")
check("cart_cap: biggest idle cart's capacity (60)", at_core.cart_cap() == 60)
protocol.ingest("CIDLE", "")
protocol.ingest("CARTS", "sell|fish|Havn|120|40|60|85|c1|2|90|35|1|armored|leg1,leg2")
check("cart_cap: falls back to state.carts when no idle carts (35)", at_core.cart_cap() == 35)
protocol.ingest("CARTS", "")
check("cart_cap: LEGACY's 60 fallback when nothing at all is known", at_core.cart_cap() == 60)

-- ---------------------------------------------------------------------------
-- at_pick_cart (LEGACY:81-109): mode/idle/tier/refit preference order.
-- Fixture (via CIDLE, real handler): 5 idle carts spanning refits and caps,
-- one with durability 0 (must never be picked).
--   id1: tier1 dur100 cap40 standard
--   id2: tier2 dur90  cap60 heavy
--   id3: tier1 dur80  cap30 speed
--   id4: tier3 dur0   cap100 standard  (durability 0 -> excluded entirely)
--   id5: tier2 dur100 cap60 standard
-- ---------------------------------------------------------------------------
local function cart_id(c) return c and c.cart_id end

-- Low warehouse fullness (2%, well under the 85% "fullish" threshold) so an
-- explicit wh_full=false argument is not accidentally overridden by a real
-- warehouse_pct() that also happens to read >= 85.
protocol.ingest("BUILDINGS", "warehouse:1")
protocol.ingest("WSTOCK", "junk|10|100")
check("warehouse_pct: sanity check, low fixture reads 2% (well under 85)",
      at_core.warehouse_pct() == 2, at_core.warehouse_pct())

protocol.ingest("CIDLE",
  "1|1|100|40|standard;2|2|90|60|heavy;3|1|80|30|speed;4|3|0|100|standard;5|2|100|60|standard")

check("pick_cart: stock mode, warehouse full -> prefers heavy refit (id2)",
      cart_id(at_core.pick_cart("stock", nil, true)) == 2)
check("pick_cart: stock mode, not full, qty hint 50 -> cap>=50 excluding heavy (id5; id2 is heavy)",
      cart_id(at_core.pick_cart("stock", 50, false)) == 5)
check("pick_cart: stock mode, not full, no qty hint -> prefers speed refit (id3)",
      cart_id(at_core.pick_cart("stock", 0, false)) == 3)
check("pick_cart: arb mode, qty hint 50 -> cap>=50 excluding heavy (id5)",
      cart_id(at_core.pick_cart("arb", 50, false)) == 5)
check("pick_cart: arb mode ignores the fullish/heavy branch entirely (still id5 even when full)",
      cart_id(at_core.pick_cart("arb", 50, true)) == 5)
check("pick_cart: arb mode, no qty hint -> prefers speed refit (id3)",
      cart_id(at_core.pick_cart("arb", 0, false)) == 3)
check("pick_cart: unrecognized mode falls back to best overall; cap60 tie (id2/id5) breaks to lowest id",
      cart_id(at_core.pick_cart("other", nil, nil)) == 2)

protocol.ingest("CIDLE", "")
check("pick_cart: no idle carts at all returns nil", at_core.pick_cart("stock", 10, false) == nil)

-- Fullish DERIVED from real warehouse_pct (no wh_full argument at all):
-- grain 350 / cap 400 (tier 1) = floor(87.5) = 87% >= 85 -> heavy branch.
protocol.ingest("WSTOCK", "grain|350|100")
protocol.ingest("BUILDINGS", "warehouse:1")
protocol.ingest("CIDLE", "1|1|100|40|standard;2|2|90|60|heavy;3|1|80|30|speed")
check("warehouse_pct: 350/400 = 87 (hand-computed: floor(350/400*100))",
      at_core.warehouse_pct() == 87, at_core.warehouse_pct())
check("pick_cart: derived fullish (87% >= 85) with no wh_full arg still prefers heavy (id2)",
      cart_id(at_core.pick_cart("stock", nil, nil)) == 2)

-- ---------------------------------------------------------------------------
-- at_max_stops (LEGACY:125-138): trading_post tier, +1 for an assigned
-- silver_tongue staffer.
-- ---------------------------------------------------------------------------
protocol.ingest("BUILDINGS", "trading_post:3")
protocol.ingest("STAFF", "")
check("max_stops: trading_post tier 3, no staff -> 3", at_core.max_stops() == 3)
protocol.ingest("STAFF", "Bjorn|trading_post|trade|5,3,2,1,4,2,1|silver_tongue|4|veteran|1000")
check("max_stops: +1 for an assigned silver_tongue staffer -> 4", at_core.max_stops() == 4)
protocol.ingest("STAFF", "Bjorn|trading_post|trade|5,3,2,1,4,2,1|0|4|veteran|1000")
check("max_stops: staffer assigned but not silver_tongue -> back to 3", at_core.max_stops() == 3)
protocol.ingest("BUILDINGS", "")
check("max_stops: no trading_post building at all -> LEGACY's default tier 1", at_core.max_stops() == 1)

-- ---------------------------------------------------------------------------
-- Sell-suffix / quality policy for graded vs. perishable vs. durable goods
-- (LEGACY:245-279). Re-seed the mead/fish brackets from above for the
-- quality-multiplier assertions.
-- ---------------------------------------------------------------------------
protocol.ingest("WSTOCK",
  "mead|10|100;mead|20|90;mead|5|80;mead|100|50;fish|60|100;fish|40|80;fish|20|50")

check("route_sell_suffix: graded good sells ' best' first", at_core.route_sell_suffix("iron") == " best")
check("route_sell_suffix: perishable good sells ' oldest' first", at_core.route_sell_suffix("fish") == " oldest")
check("route_sell_suffix: durable good has no suffix", at_core.route_sell_suffix("timber") == "")

check("sell_qual: graded good sells ' best' first", at_core.sell_qual("iron") == " best")
check("sell_qual: non-graded good has no suffix", at_core.sell_qual("timber") == "")

check("route_sell_quality: graded good is the cured premium (1.1, hand-computed above)",
      at_core.route_sell_quality("mead", 99) == 1.1)
check("route_sell_quality: perishable good is fifo_quality/100 (74/100 = 0.74, hand-computed above)",
      at_core.route_sell_quality("fish", 70) == 0.74)
check("route_sell_quality: durable good is 1.0", at_core.route_sell_quality("timber", 99) == 1.0)

check("direct_sell_quality: graded good is the cured premium (1.1)",
      at_core.direct_sell_quality("mead", 99) == 1.1)
check("direct_sell_quality: perishable good is fresh_quality/100 (97/100 = 0.97, hand-computed above)",
      at_core.direct_sell_quality("fish", 70) == 0.97)
check("direct_sell_quality: durable good is 1.0", at_core.direct_sell_quality("timber", 99) == 1.0)

-- ---------------------------------------------------------------------------
-- snapshot()/restore() round-trip (mirrors market.lua's own test).
-- ---------------------------------------------------------------------------
S.autotrade = nil
at_core.settings()
S.autotrade.min_margin = 42
local snap = at_core.snapshot()
check("snapshot: carries the autotrade table", snap.autotrade == S.autotrade)
local saved = S.autotrade
S.autotrade = nil
at_core.restore(snap)
check("restore: round-trips the autotrade table", S.autotrade == saved and S.autotrade.min_margin == 42)
at_core.restore(nil)
check("restore: nil-safe", S.autotrade == saved)

-- ---------------------------------------------------------------------------
-- Settings defaults round-trip through persist.lua (the real save/load
-- path, not just this module's own snapshot/restore): persist.save() must
-- store the autotrade table, and persist.load() into a wiped S.autotrade
-- must bring it back with the settings a user configured.
-- ---------------------------------------------------------------------------
local persist = require("persist")

S.autotrade = nil
local at4 = at_core.settings()
at4.min_margin = 7
at4.reserve = 42
at4.max_carts = 5

persist.save()
check("persist round-trip: store.set() received the autotrade table",
      stored ~= nil and stored.autotrade ~= nil and stored.autotrade.min_margin == 7)

S.autotrade = nil   -- simulate a fresh process before persist.load()
persist.load()
check("persist round-trip: reloaded settings match what was saved",
      S.autotrade ~= nil and S.autotrade.min_margin == 7 and S.autotrade.reserve == 42
      and S.autotrade.max_carts == 5)

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING AUTOTRADER TESTS PASSED")
