-- Market history, price statistics, trends, and demand-cycle helpers,
-- ported verbatim from LEGACY guild_viking.lua:357-418 (record_price_history,
-- price_stats, price_trend, demand_cycle_color). Wired as
-- handlers/trade.lua's `_market_seam.on_tgoods` (see init.lua); on_market is
-- deliberately left unset -- LEGACY's MARKET branch (guild_viking.lua:2459)
-- never calls record_price_history or any other history/demand helper, only
-- TGOODS does (confirmed by grepping LEGACY for every price_history and
-- record_price_history reference), so there is nothing for this module to
-- do with the rebuilt order list Task 3's seam offers.
local S = require("state").S

local M = {}

-- LEGACY:357. Rolling per-(lineage,good) history depth cap.
local PRICE_HIST_MAX = 48

-- LEGACY:360-372 (record_price_history). De-duplicated: only appends when
-- buy or sell actually changed, so history holds one sample per market
-- shift rather than one per packet. LEGACY timestamps with os.time(); this
-- uses lera.time() instead per the brief (the test suite stubs lera.time,
-- and lera.time() reflects the same wall clock outside tests, so behavior
-- is unchanged in production).
function M.on_tgoods(lin, good, buy, sell)
  if not buy or not sell then return end
  local ph = S.price_history
  if not ph then ph = {}; S.price_history = ph end
  ph[lin] = ph[lin] or {}
  local arr = ph[lin][good]
  if not arr then arr = {}; ph[lin][good] = arr end
  local last = arr[#arr]
  if last and last.b == buy and last.s == sell then return end
  arr[#arr + 1] = { t = lera.time(), b = buy, s = sell }
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

-- Persisted subset for Task 10's store wiring: the rolling price history is
-- the only state this module owns that needs to survive a reload (LEGACY's
-- comment at guild_viking.lua:134, "auto-persisted via OnPluginSaveState").
function M.snapshot()
  return { price_history = S.price_history }
end

function M.restore(tbl)
  if not tbl then return end
  if tbl.price_history then S.price_history = tbl.price_history end
end

return M
