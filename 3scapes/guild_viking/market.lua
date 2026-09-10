-- Market history, price statistics, trends, demand-cycle, and market-mover
-- helpers, ported verbatim from LEGACY guild_viking.lua:357-418
-- (record_price_history, price_stats, price_trend, demand_cycle_color) and
-- :3186-3396 (Task 8: compute_market_movers, best_sell_of, best_buy_of,
-- compute_refined_sells, mover_is_hot). Wired as handlers/trade.lua's
-- `_market_seam.on_tgoods` (see init.lua); on_market is deliberately left
-- unset -- LEGACY's MARKET branch (guild_viking.lua:2459) never calls
-- record_price_history or any other history/demand helper, only TGOODS does
-- (confirmed by grepping LEGACY for every price_history and
-- record_price_history reference), so there is nothing for this module to
-- do with the rebuilt order list Task 3's seam offers.
local S = require("state").S

local M = {}

-- LEGACY:357. Rolling per-(lineage,good) history depth cap.
local PRICE_HIST_MAX = 48

-- LEGACY:360-372 (record_price_history). De-duplicated: only appends when
-- buy or sell actually changed, so history holds one sample per market
-- shift rather than one per packet. Timestamps with os.time() (epoch
-- seconds), matching LEGACY exactly: price_history is the persisted
-- artifact. lera.time() would in fact do just as well -- it returns the same
-- epoch seconds -- but os.time() is what LEGACY used and is the plainer choice
-- for a persisted timestamp.
function M.on_tgoods(lin, good, buy, sell)
  if not buy or not sell then return end
  local ph = S.price_history
  if not ph then ph = {}; S.price_history = ph end
  ph[lin] = ph[lin] or {}
  local arr = ph[lin][good]
  if not arr then arr = {}; ph[lin][good] = arr end
  local last = arr[#arr]
  if last and last.b == buy and last.s == sell then return end
  arr[#arr + 1] = { t = os.time(), b = buy, s = sell }
  while #arr > PRICE_HIST_MAX do table.remove(arr, 1) end
end

-- LEGACY:375-393 (price_stats). Min/max/avg of buy and sell over the
-- recorded history for (lin, good).
function M.price_stats(lin, good)
  local ph = S.price_history and S.price_history[lin]
  local arr = ph and ph[good]
  if not arr or #arr == 0 then return nil end
  local bmin, bmax, bsum = math.huge, -math.huge, 0
  local smin, smax, ssum = math.huge, -math.huge, 0
  for _, e in ipairs(arr) do
    if e.b < bmin then bmin = e.b end
    if e.b > bmax then bmax = e.b end
    bsum = bsum + e.b
    if e.s < smin then smin = e.s end
    if e.s > smax then smax = e.s end
    ssum = ssum + e.s
  end
  local n = #arr
  return { n = n, bmin = bmin, bmax = bmax, bavg = bsum / n,
                  smin = smin, smax = smax, savg = ssum / n }
end

-- LEGACY:395-407 (price_trend). Trend marker vs history average.
-- lower_is_good=true for buy prices (cheap is good), false for sell prices
-- (dear is good). Returns arrow, colour.
local GOOD_COL, BAD_COL, FLAT_COL = 0x00FF00, 0xFF4444, 0x999999
function M.price_trend(cur, avg, lower_is_good)
  if not avg or avg <= 0 then return " ", FLAT_COL end
  local thr = math.max(1, avg * 0.04)
  if cur > avg + thr then
    return "^", (lower_is_good and BAD_COL or GOOD_COL)
  elseif cur < avg - thr then
    return "v", (lower_is_good and GOOD_COL or BAD_COL)
  end
  return "=", FLAT_COL
end

-- LEGACY:409-418 (demand_cycle_color).
function M.demand_cycle_color(name)
  local s = string.lower(name or "")
  if string.find(s, "spring", 1, true) then return 0x88DD44 end
  if string.find(s, "summer", 1, true) then return 0x44CCDD end
  if string.find(s, "autumn", 1, true) or string.find(s, "fall", 1, true) then return 0x4488DD end
  if string.find(s, "winter", 1, true) then return 0xCCCCCC end
  if string.find(s, "calm", 1, true) then return 0xCCCC00 end
  return 0xCCCC00
end

-- ---------------------------------------------------------------------------
-- Market Movers / Refined Sells / "hot" flag, ported verbatim from LEGACY
-- guild_viking.lua:3186-3396 (Task 8; flips parity feature
-- viking_base_05_market_movers_and_trade_rows). Pure computations over
-- S.trade_goods/S.wstock_by_good/S.blocks; page_opts-aware pieces (how many
-- rows to show, lineage-id -> town-name lookup, and the auto_trade on/off
-- gate) stay in pages/goods.lua per the task's split.
-- ---------------------------------------------------------------------------

-- LEGACY:3192-3193 (GOODS_ALL). The primary goods eligible for arbitrage --
-- excludes weapons/armour/finery (never traded lineage-to-lineage) and
-- REFINED_GOODS below (towns only ever BUY those, never supply them).
--
-- The 8 raw husbandry goods (wool/eggs/pork/mutton/poultry/beef/milk/
-- horsemeat) were missing entirely -- this list predates Guild.Livestock,
-- and nothing added them when those goods shipped. None of the 8 is in
-- REFINED_GOODS (only their refined forms -- cloth, smoked_meat, cheese --
-- are, and those stay excluded same as weapons/armour/finery), so they
-- belong here on the same footing as any other raw good.
local GOODS_ALL = {
  "timber", "ore", "iron", "furs", "fish", "grain", "mead", "sunstone",
  "runestones", "spoils", "salted_fish", "bread", "fine_furs", "tools",
  "gemstones", "honey",
  "wool", "eggs", "pork", "mutton", "poultry", "beef", "milk", "horsemeat",
}

-- LEGACY:3201-3210. A profitable arbitrage buy must come from a surplus
-- village (score <= -1) and sell into real demand (score >= +2) -- see
-- LEGACY's own comment: neutral towns always mark sell DOWN and buy UP, so
-- near-neutral round trips are churn, not profit.
local AT_BUY_MAX_SCORE = -1
local AT_SELL_MIN_SCORE = 2
-- LEGACY:3208-3210. Size a deal to this fraction of the sell town's CURRENT
-- demand, leaving a buffer against demand/price shrinking before dispatch.
local AT_DEMAND_SAFETY = 0.8

-- LEGACY:3234-3269 (compute_market_movers). For each good, find the cheapest
-- qualifying buy town and the dearest qualifying sell town; a profitable
-- pair (sell > buy, different towns) becomes one arbitrage row. TGOODS
-- buy/sell are already the server's fully rep/tier/skill-modified actual
-- prices, so no client-side reputation adjustment is applied here (LEGACY's
-- own note: a second rep pass previously inflated sell and deflated buy,
-- producing routes that actually lost money).
function M.compute_market_movers()
  local tg = S.trade_goods
  if not tg or not next(tg) then return {} end
  local arb = {}
  for _, good in ipairs(GOODS_ALL) do
    local bb, bbl, bsup, bs, bsl, bdem
    for lin = 0, 13 do
      local gd = tg[lin] and tg[lin][good]
      if gd then
        if (gd.supply or 0) > 0 and (gd.buy or 0) > 0 and (gd.score or 0) <= AT_BUY_MAX_SCORE then
          if not bb or gd.buy < bb then bb = gd.buy; bbl = lin; bsup = gd.supply end
        end
        if (gd.demand or 0) > 0 and (gd.sell or 0) > 0 and (gd.score or 0) >= AT_SELL_MIN_SCORE then
          if not bs or gd.sell > bs then bs = gd.sell; bsl = lin; bdem = gd.demand end
        end
      end
    end
    if bb and bs and bs > bb and bbl ~= bsl then
      local margin = bs - bb
      local qty = math.min(bsup or 0, math.floor((bdem or 0) * AT_DEMAND_SAFETY))
      arb[#arb + 1] = { good = good, buy = bb, buy_lin = bbl, buy_supply = bsup or 0,
                         sell = bs, sell_lin = bsl, sell_demand = bdem or 0,
                         margin = margin, qty = qty, profit = margin * qty }
    end
  end
  table.sort(arb, function(a, b)
    if a.profit ~= b.profit then return a.profit > b.profit end
    return a.margin > b.margin
  end)
  return arb
end

-- LEGACY:3320-3334 (best_sell_of). Best town to SELL `good`: highest sell
-- price among towns that demand it (NOT score-gated, unlike the mover scan
-- above). Returns price, lineage id, demand -- or nil if no town wants it.
function M.best_sell_of(good)
  local tg = S.trade_goods
  if not tg then return nil end
  local bs, bsl, bdem
  for lin = 0, 13 do
    local gd = tg[lin] and tg[lin][good]
    if gd and (gd.demand or 0) > 0 and (gd.sell or 0) > 0 then
      if not bs or gd.sell > bs then bs = gd.sell; bsl = lin; bdem = gd.demand end
    end
  end
  return bs, bsl, bdem
end

-- LEGACY:3336-3350 (best_buy_of). Cheapest town to BUY `good`: lowest buy
-- price among towns that supply it. Returns price, lineage id, supply -- or
-- nil if no town sells it.
function M.best_buy_of(good)
  local tg = S.trade_goods
  if not tg then return nil end
  local bb, bbl, bsup
  for lin = 0, 13 do
    local gd = tg[lin] and tg[lin][good]
    if gd and (gd.supply or 0) > 0 and (gd.buy or 0) > 0 then
      if not bb or gd.buy < bb then bb = gd.buy; bbl = lin; bsup = gd.supply end
    end
  end
  return bb, bbl, bsup
end

-- LEGACY:3312 (REFINED_GOODS). Goods that towns only ever BUY (produced/
-- refined goods -- shops surcharge them +75%, so they never clear the
-- arbitrage buy gate above; they only ever show up as warehouse stock to
-- sell).
local REFINED_GOODS = { "mead", "salted_fish", "bread", "fine_furs", "tools", "gemstones" }

-- LEGACY:3315-3318 (wh_amount_of). Warehouse amount of a good, from the
-- WSTOCK feed (handlers/trade.lua's write_wstock populates S.wstock_by_good
-- and S.wstock together).
--
-- EXPORTED (husbandry plan, Task 4), and given the S.wstock array
-- fallback LEGACY's second warehouse reader
-- (guild_viking_husbandry.lua:139, warehouse_amount) also carried. This is
-- now the ONE place in the plugin that answers "how much of this good is in
-- the warehouse" -- autoherd.lua's feed guard and pages/livestock.lua's Feed
-- section both call it, so the planner and the page cannot drift apart on
-- the same question. The array fallback is unreachable while write_wstock
-- writes both halves in one go; it is kept because the two LEGACY readers
-- disagreed on whether it was needed and the cheaper answer is to satisfy
-- both.
function M.wh_amount_of(good)
  local rec = S.wstock_by_good and S.wstock_by_good[good]
  if rec then return tonumber(rec.amount) or 0 end
  local n = 0
  for _, ws in ipairs(S.wstock or {}) do
    if ws.good == good then n = n + (tonumber(ws.amount) or 0) end
  end
  return n
end

-- Has the WSTOCK feed arrived at all? state.lua leaves S.wstock_by_good nil
-- until write_wstock runs, and write_wstock always creates it (even for an
-- empty warehouse), so nil means "not received yet" and {} means "received,
-- warehouse empty". Callers that would otherwise render a 0 as fact need to
-- tell those two apart -- see pages/livestock.lua's Feed section, which omits
-- its "Covers" line rather than claim a 0-tick runway it cannot know.
function M.wh_known()
  return S.wstock_by_good ~= nil
end

-- ---------------------------------------------------------------------------
-- Livestock figures shared by pages/livestock.lua and autoherd.lua. They live
-- here, beside wh_amount_of/wh_known, for the same reason those do: the page
-- and the spending planner must not be able to drift apart on the same
-- question. Before this they lived in autoherd.lua, which made loading ANY
-- page pull in the whole spending planner just to render a Feed line -- and
-- the spec's "pure builder ... reading only `state` and `page_opts`"
-- constraint on the pages was never amended to allow that.
-- ---------------------------------------------------------------------------

-- HERD_CAP, tiers 1..5, from the server's HERD_CAP_* constants
-- (3s/players/viking/world/trade_goods.h:1050-1054, dropping its leading
-- tier-0 zero -- LEGACY's own shape at guild_viking.lua:9832-9835). ONE
-- definition: it drives spending, and it was duplicated with divergent
-- semantics (a clamped read in the planner, a direct index on the page).
-- Both readers keep their own out-of-range behaviour AT THE CALL SITE, which
-- is where the difference is meaningful: the planner clamps, because a buy
-- must never be sized against a nil cap, and the page shows head alone.
M.HERD_CAP = {
  sheepfold = { 6, 14, 28, 50, 80 },
  henhouse  = { 12, 28, 56, 100, 160 },
  piggery   = { 6, 14, 28, 50, 80 },
  byre      = { 4, 10, 20, 36, 56 },
  stable    = { 8, 16, 28, 40, 60 },
}

-- LIVESTOCK_FEED_PER_HEAD (trade_goods.h:1074): one grain per eight head.
local LIVESTOCK_FEED_PER_HEAD = 8

-- The herds' per-tick grain draw.
--
-- The SERVER has already computed this figure -- S.lfeed.grain, via
-- _v_lfeed() -> query_livestock_feed_needs() (query.h:2464) -- and its number
-- is strictly better than any client re-derivation, because it applies the
-- fesetr feed-saving skill and the per-building minimum of 1 grain, neither
-- of which a client can see. LEGACY's own ceil(head / 8)
-- (guild_viking_husbandry.lua:231) is therefore kept only as the fallback for
-- the window before the LFEED key has arrived, where `head` is the caller's
-- own head figure.
function M.feed_draw(head)
  local g = tonumber(S.lfeed and S.lfeed.grain) or 0
  if g > 0 then return g end
  return math.ceil((tonumber(head) or 0) / LIVESTOCK_FEED_PER_HEAD)
end

-- LEGACY:3354-3372 (compute_refined_sells). Best-sell opportunities for
-- REFINED_GOODS, ranked by realisable value (stock on hand x price) first,
-- then unit price. `avail` nets out blocked/reserved stock (S.blocks,
-- populated by handlers/trade.lua's BLOCKS parsing).
function M.compute_refined_sells()
  local out = {}
  for _, g in ipairs(REFINED_GOODS) do
    local sp, sl, dem = M.best_sell_of(g)
    if sp and sl then
      local total = M.wh_amount_of(g)
      local blk = (S.blocks and S.blocks[g]) or 0
      local avail = total - blk
      if avail < 0 then avail = 0 end
      out[#out + 1] = { good = g, sell = sp, sell_lin = sl, demand = dem,
                         stock = avail, blocked = blk, value = avail * sp }
    end
  end
  table.sort(out, function(a, b)
    if (a.value > 0) ~= (b.value > 0) then return a.value > 0 end
    if a.value ~= b.value then return a.value > b.value end
    return a.sell > b.sell
  end)
  return out
end

-- LEGACY:3389-3396 (inside build_mover_rows). "HOT": true when a mover's
-- current sell price sits in the top third (>=66th percentile) of that
-- (lineage, good)'s recorded sell-price range.
function M.mover_is_hot(sell, sell_lin, good)
  local st = M.price_stats(sell_lin, good)
  if not (st and st.smax > st.smin) then return false end
  local f = (sell - st.smin) / (st.smax - st.smin)
  return f >= 0.66
end

-- Persisted subset for Task 10's store wiring: the rolling price history is
-- the only state this module owns that needs to survive a reload (LEGACY's
-- comment at guild_viking.lua:182, "auto-persisted via OnPluginSaveState").
function M.snapshot()
  return { price_history = S.price_history }
end

function M.restore(tbl)
  if not tbl then return end
  if tbl.price_history then S.price_history = tbl.price_history end
end

return M
