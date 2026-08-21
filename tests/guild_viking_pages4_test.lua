-- guild_viking pane page unit tests: Task 8's pages/goods.lua (LEGACY's
-- draw_page6, guild_viking.lua:10703-10984) plus the Part-A market.lua
-- computations it consumes. Task 9 appends its own pages here later, per
-- the plan's shared-harness note. Run from the lera-plugins repo root with
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

local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local goods_page = require("pages.goods")

local S = state.S
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

-- Finds a row whose ANSI-stripped, trailing-space-trimmed text is EXACTLY
-- `text` -- used for the price-section's lineage header row, which is just
-- the town name alone (find_line's substring match would otherwise hit the
-- SAME town name embedded inside an earlier Market Movers row).
local function find_exact(lines, text)
  for i, l in ipairs(lines) do
    local stripped = l:gsub("\27%[[%d;]*m", ""):gsub("%s+$", "")
    if stripped == text then return i end
  end
  return nil
end

local function check_width(lines, label)
  local width_ok, widest = true, nil
  for _, l in ipairs(lines) do
    local vw = pagelib.visible_width(l)
    if vw > WIDTH then width_ok = false; widest = vw end
  end
  check(label .. ": every row's visible width is <= the requested width", width_ok, widest)
end

-- =============================================================================
-- pages/goods.lua (Task 8) -- LEGACY draw_page6 (guild_viking.lua:10703-10984)
-- =============================================================================

-- ---- No-data early exit (LEGACY:10725-10730, UNGATED) -----------------------
-- With state.trade_goods completely empty, only the demand-cycle line (if
-- gated on) and a "Trade Goods"/"No data" fallback render -- Market Movers,
-- Refined Goods, Auto-Trade status and price rows are ALL skipped.
S.trade_goods = {}
S.demand_cycle = "Spring Growth"
S.demand_cycle_in = 0
page_opts.set("show_goods_cycle", true)
page_opts.set("show_goods_movers", true)
page_opts.set("show_goods_prices", true)

local nodata_lines = goods_page.lines(WIDTH)
local nodata_all = joined(nodata_lines)
check("goods: 'Trade Goods' no-data header present when trade_goods is empty",
      find_line(nodata_lines, "Trade Goods") ~= nil, nodata_all)
check("goods: no-data message names the toggle",
      nodata_all:find("vtoggle mip_trade_goods", 1, true) ~= nil, nodata_all)
check("goods: Market Movers is skipped entirely when trade_goods is empty",
      find_line(nodata_lines, "Market Movers") == nil, nodata_all)
check("goods: demand cycle line still renders before the no-data exit",
      find_line(nodata_lines, "Demand cycle") ~= nil, nodata_all)
check("goods: demand cycle names the season (Spring Growth)",
      nodata_all:find("Spring Growth", 1, true) ~= nil, nodata_all)

page_opts.set("show_goods_cycle", false)
local nodata_no_cycle = goods_page.lines(WIDTH)
check("goods: demand cycle line disappears when show_goods_cycle is off",
      find_line(nodata_no_cycle, "Demand cycle") == nil)
check("goods: no-data header stays when only the cycle opt is off",
      find_line(nodata_no_cycle, "Trade Goods") ~= nil)
page_opts.set("show_goods_cycle", true)

-- ---- Seed real trade_goods data for the rest of the page --------------------
-- lin0 supplies iron cheaply (score -3 <= -1 gate) and lin1 demands it highly
-- (score 3 >= 2 gate): margin 45, qty = min(supply 100, floor(demand 100*0.8))
-- = 80, profit = 3600 -- same hand-computed fixture shape as the trade-test
-- market.lua cases, reused here so the PAGE's rendering of the SAME numbers
-- can be asserted (rank, town names, buy/sell price, profit, margin).
S.trade_goods = {
  [0] = { iron = { score = -3, supply = 100, demand = 0, buy = 5, sell = 0 } },
  [1] = { iron = { score = 2, supply = 0, demand = 100, buy = 0, sell = 50 } },
}
S.wstock_by_good = {}
S.blocks = {}
S.autotrade.show_n = 6

local movers_lines = goods_page.lines(WIDTH)
local movers_all = joined(movers_lines)

check("goods: Market Movers header present with real trade_goods data",
      find_line(movers_lines, "Market Movers") ~= nil, movers_all)
check("goods: mover row shows Iron (good label)", movers_all:find("Iron", 1, true) ~= nil, movers_all)
-- Town names: LIN_NAMES[0]="Midgard" (no " Hold" suffix to strip),
-- LIN_NAMES[1]="Lodbrok's Hold" -> shortened to "Lodbrok's".
check("goods: mover row names buy town Midgard and sell town Lodbrok's",
      movers_all:find("Midgard", 1, true) ~= nil and movers_all:find("Lodbrok's", 1, true) ~= nil,
      movers_all)
check("goods: mover row shows buy price 5 and sell price 50",
      movers_all:find(" 5 ", 1, true) ~= nil or movers_all:find("5\27", 1, true) ~= nil, movers_all)
check("goods: mover row shows profit +3600d", movers_all:find("+3600d", 1, true) ~= nil, movers_all)
check("goods: mover row shows margin (45/u)", movers_all:find("(45/u)", 1, true) ~= nil, movers_all)

page_opts.set("show_goods_movers", false)
local no_movers = goods_page.lines(WIDTH)
check("goods: Market Movers header disappears when show_goods_movers is off",
      find_line(no_movers, "Market Movers") == nil)
page_opts.set("show_goods_movers", true)

-- ---- LOAD-BEARING QUIRK: show_goods_movers==false also hides Refined Goods
-- and the Auto-Trade status block (LEGACY's build_mover_rows returns an
-- EMPTY row list before either is ever reached, guild_viking.lua:3378).
S.wstock_by_good = { mead = { amount = 20 } }
S.blocks = {}
S.trade_goods[0].mead = { score = 2, supply = 0, demand = 10, buy = 0, sell = 40 }
page_opts.set("auto_trade", true)
S.autotrade.status = "cooldown"

do
  local with_movers = goods_page.lines(WIDTH)
  check("goods: Refined Goods present when show_goods_movers is on",
        find_line(with_movers, "Refined Goods") ~= nil, joined(with_movers))
  check("goods: Auto-Trade status line present when show_goods_movers is on",
        find_line(with_movers, "Auto-Trade") ~= nil, joined(with_movers))

  page_opts.set("show_goods_movers", false)
  local without_movers = goods_page.lines(WIDTH)
  check("goods: Refined Goods ALSO disappears when show_goods_movers is off",
        find_line(without_movers, "Refined Goods") == nil, joined(without_movers))
  check("goods: Auto-Trade status ALSO disappears when show_goods_movers is off",
        find_line(without_movers, "Auto-Trade") == nil, joined(without_movers))
  page_opts.set("show_goods_movers", true)
end

-- ---- Refined Goods own gate (nested inside show_goods_movers) --------------
page_opts.set("show_goods_refined", false)
local no_refined = goods_page.lines(WIDTH)
check("goods: Refined Goods disappears when show_goods_refined is off (movers stays)",
      find_line(no_refined, "Refined Goods") == nil and find_line(no_refined, "Market Movers") ~= nil,
      joined(no_refined))
page_opts.set("show_goods_refined", true)

-- ---- Auto-Trade status block: ON/off, Idle, Last run, controls placeholder -
local at_lines = goods_page.lines(WIDTH)
local at_all = joined(at_lines)
check("goods: Auto-Trade shows ON when page_opts.auto_trade is true",
      at_all:find("ON", 1, true) ~= nil, at_all)
check("goods: Idle status line shown (cooldown)", at_all:find("cooldown", 1, true) ~= nil, at_all)
check("goods: Auto-trade controls placeholder present (stage 4)",
      at_all:find("Auto%-trade controls: stage 4") ~= nil, at_all)

page_opts.set("auto_trade", false)
local at_off_lines = goods_page.lines(WIDTH)
local at_off_all = joined(at_off_lines)
check("goods: Auto-Trade shows off when page_opts.auto_trade is false",
      at_off_all:find("off", 1, true) ~= nil, at_off_all)
check("goods: Idle status hidden when auto_trade is off",
      at_off_all:find("cooldown", 1, true) == nil, at_off_all)
page_opts.set("auto_trade", true)

-- Last run: last_jobs preferred over last_msg fallback.
S.autotrade.last_jobs = {
  { mode = "buy", qty = 10, good = "iron", btown_lin = 0, stown_lin = 1, profit = 200, margin = 5 },
}
local jobs_lines = goods_page.lines(WIDTH)
local jobs_all = joined(jobs_lines)
check("goods: Last run job line shows buy 10x Iron -> Lodbrok's +200d (5/u)",
      jobs_all:find("Iron", 1, true) ~= nil and jobs_all:find("Lodbrok's", 1, true) ~= nil
      and jobs_all:find("+200d", 1, true) ~= nil and jobs_all:find("(5/u)", 1, true) ~= nil, jobs_all)

S.autotrade.last_jobs = nil
S.autotrade.last_msg = "sell 4x Mead -> Midgard; buy 2x Furs -> Lodbrok's"
local msg_lines = goods_page.lines(WIDTH)
local msg_all = joined(msg_lines)
check("goods: last_msg fallback splits on ';' into two '- ' lines",
      msg_all:find("sell 4x Mead %-> Midgard", 1) ~= nil
      and msg_all:find("buy 2x Furs %-> Lodbrok's", 1) ~= nil, msg_all)
S.autotrade.last_msg = ""

-- ---- Auto-Trade Log (show_goods_atlog, nested in the same movers block) ----
S.autotrade.log = {
  { t = "10:00", jobs = { { mode = "sell", qty = 3, good = "mead", stown_lin = 0, profit = 90, margin = 30 } } },
}
page_opts.set("show_goods_atlog", true)
local atlog_lines = goods_page.lines(WIDTH)
check("goods: Auto-Trade Log header present when show_goods_atlog is on and log is non-empty",
      find_line(atlog_lines, "Auto-Trade Log:") ~= nil, joined(atlog_lines))

page_opts.set("show_goods_atlog", false)
local no_atlog_lines = goods_page.lines(WIDTH)
check("goods: Auto-Trade Log header disappears when show_goods_atlog is off",
      find_line(no_atlog_lines, "Auto-Trade Log:") == nil, joined(no_atlog_lines))
check("goods: controls placeholder still present when atlog is off",
      joined(no_atlog_lines):find("Auto%-trade controls: stage 4") ~= nil)
page_opts.set("show_goods_atlog", true)

-- ---- Price rows (show_goods_prices) + trend arrows via market.price_trend --
-- Build a known price_history for lin0/iron so the trend arrow is
-- deterministic: two samples, buy 5 and 15 (bavg=10); current buy=5 is well
-- below avg-thr (thr = max(1, 10*0.04)=1) -> "v" (down), which is GOOD for a
-- buy price per market.price_trend's lower_is_good=true semantics.
S.price_history = { [0] = { iron = { { t = 1, b = 5, s = 40 }, { t = 2, b = 15, s = 60 } } } }

local price_lines = goods_page.lines(WIDTH)
local price_all = joined(price_lines)
local midgard_header_idx = find_exact(price_lines, "Midgard")
check("goods: price rows header names the lineage (Midgard) as its own row",
      midgard_header_idx ~= nil, price_all)

-- The FIRST "Iron" after the price-section's own Midgard header row is the
-- price row (an earlier "Iron" also appears inside the Market Movers row).
local iron_row_idx = nil
if midgard_header_idx then
  for i = midgard_header_idx + 1, #price_lines do
    if price_lines[i]:find("Iron", 1, true) then iron_row_idx = i; break end
  end
end
check("goods: an Iron price row exists under the Midgard header", iron_row_idx ~= nil, price_all)
if iron_row_idx then
  check("goods: Iron price row shows the down-trend arrow 'v' for buy (5, well below avg 10)",
        price_lines[iron_row_idx]:find("v", 1, true) ~= nil, price_lines[iron_row_idx])
  check("goods: Iron price row shows Supply/Demand values",
        price_lines[iron_row_idx]:find("Sup:", 1, true) ~= nil
        and price_lines[iron_row_idx]:find("Dem:", 1, true) ~= nil, price_lines[iron_row_idx])
end

page_opts.set("show_goods_prices", false)
local no_prices = goods_page.lines(WIDTH)
check("goods: price rows disappear when show_goods_prices is off",
      find_line(no_prices, "Sup:") == nil, joined(no_prices))
page_opts.set("show_goods_prices", true)

-- ---- width discipline (every gate on, everything rendering at once) --------
check_width(goods_page.lines(WIDTH), "goods")

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING PAGES4 TESTS PASSED")
