-- Goods page: LEGACY's draw_page6 (/home/simon/code/3s_scripts_old/lua/
-- guild_viking.lua:10703-10984 -- the function BODY; the wider 10703-12376
-- span the task brief names also covers unrelated page-menu/popup-menu
-- handlers for the whole detached window, not draw_page6 itself -- see the
-- task report). Pure builder: lines(width) -> array of ANSI strings, reading
-- state.lua's S, page_opts.lua, and market.lua (Task 8's Part A verbatim
-- ports) only.
--
-- Section order/gates, read from the source top to bottom:
--   Demand cycle (show_goods_cycle, 10711-10723) -- season/cycle name,
--     colored by intent, plus time-to-next-shift when known.
--   EARLY EXIT (10725-10730, UNGATED): if state.trade_goods is completely
--     empty, draw ONLY a "Trade Goods" header + "No data -- enable with:
--     vtoggle mip_trade_goods" and stop. Market Movers, Refined Goods, the
--     Auto-Trade status block and the price rows below are ALL skipped in
--     that case, regardless of their own opts, because draw_page6 itself
--     returns before build_mover_rows or the price-row loop ever runs.
--   Market Movers block (show_goods_movers; rows built by LEGACY's
--     build_mover_rows, :3376-3484) -- LOAD-BEARING QUIRK: build_mover_rows
--     returns an EMPTY row list immediately when show_goods_movers is false
--     (:3378), before ever reaching the Refined Goods or Auto-Trade
--     sections below -- so turning Market Movers off also hides Refined
--     Goods and the whole Auto-Trade status/log block, regardless of THEIR
--     own opts. Preserved faithfully; same disposition as pages/trade.lua's
--     Carts-nesting quirk. Within this block:
--       - Market Movers header + rows (market.compute_market_movers(),
--         sliced to state.autotrade.show_n or 6): rank, good, buy town +
--         price, sell town + price, profit, margin, and a HOT tag
--         (market.mover_is_hot) when the sell price sits in the top third
--         of its recorded range.
--       - "Gathering data" fallback when compute_market_movers() is empty.
--       - Refined Goods sub-section (show_goods_refined, nested; only drawn
--         when market.compute_refined_sells() is non-empty): rank, good,
--         sell town, unit price, stock+realisable value or "no stock",
--         demand, and a blocked-stock note.
--       - Auto-Trade status block (UNCONDITIONAL once the movers gate is
--         open -- NOT gated by show_goods_atlog): ON/off
--         (page_opts.auto_trade), Margin/Reserve/Carts, optional Pack/
--         Use-stock tags; an "Idle: <status>" line when on and a status is
--         set; "Last run:" job lines from state.autotrade.last_jobs (or a
--         ';'-split fallback parse of last_msg for older saved sessions).
--       - Auto-Trade Log (show_goods_atlog, nested in the same block, only
--         when state.autotrade.log is non-empty): the last 12 entries.
--       - Auto-trade controls placeholder (stage 4; see below).
--   Price rows (show_goods_prices, :10763-10774's rows loop) -- one header +
--     goods table per lineage present in state.trade_goods, in lineage-id
--     order: good name, affinity marker, buy/sell price with trend arrows
--     (market.price_trend), supply, demand.
--
-- Disclosed simplifications / dropped surfaces (Global Constraints: content
-- fidelity, not pixel fidelity):
--   - The bespoke pixel scrollbar (_g6_max_scroll, g6_scroll/g6_dragging,
--     the hotspot drag handlers, the scrollbar draw block at :10940-10982)
--     is NOT ported -- window.lua's top-scroller owns scrolling uniformly
--     for every stage-2 page.
--   - The pixel-column multi-good-per-row packing (`cols`, sized from
--     WindowTextWidth measurements so several goods can share one visual
--     row side by side) collapses to ONE ROW PER GOOD: a text pane has no
--     equivalent to measuring pixel text widths to pack columns, and one
--     row per good is easier to scan in a narrow terminal pane besides.
--   - The Phase-4 sell-price range mini-bar (drawn only when the pixel
--     layout happened to collapse to a single column AND history exists,
--     :10924-10938) is dropped: it is a second, purely graphical rendering
--     of the same min/max-relative position the trend arrow (^ / v / =)
--     already conveys in text.
--   - `vrep_header`/`vrep_entry` row kinds are handled in draw_page6's row
--     switch (:10847-10866) but NOTHING in draw_page6 ever appends a row of
--     that kind -- dead code, almost certainly copy-pasted from
--     draw_page9's Village Trade Reputation renderer (already ported at
--     pages/ranks.lua). Not ported here; source (what actually executes)
--     wins per the plan's Global Constraints.
--   - Any autotrader CONTROL surface -- the right-click "Auto-Trade
--     Options" popup menu (viking_show_atrade_menu, guild_viking.lua:11321)
--     that lets a player toggle Auto-Trade/Pack/Use-stock and cycle
--     Margin/Reserve/Carts/Shown -- is stage 4. A gated placeholder line,
--     "Auto-trade controls: stage 4", renders under the Auto-Trade block in
--     its place, per the task brief.
--   - MUSHclient colors in this source range are 0xBBGGRR (guild_viking.lua
--     line 301); every mapping below was decoded byte-by-byte first.
--     AFF_COLOR's polarity is disclosed explicitly where it matters (see
--     the comment above it); price_trend's GOOD_COL/BAD_COL are mapped by
--     documented NAME/intent rather than literal decode, same precedent as
--     pages/people.lua's Designations legend note (BAD_COL's literal decode
--     is blue, not red -- the name "BAD_COL", used everywhere as "this
--     trend is unfavorable", wins).
local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local market = require("market")
local cc = require("pages.city_common")

local S = state.S
local C = pagelib.C

local M = {}

-- ---------------------------------------------------------------------------
-- Town names (guild_viking.lua:10668-10677, LIN_NAMES) and the "strip the
-- redundant Hold suffix" helper (mover_town_short, guild_viking.lua:
-- 3282-3284) used by the Movers/Refined/Auto-Trade sections.
-- ---------------------------------------------------------------------------

local LIN_NAMES = {
  [0] = "Midgard", [1] = "Lodbrok's Hold", [2] = "Eiriksson Hold", [3] = "Ui Imair Hold",
  [4] = "Rurikid Hold", [5] = "Harfagre Hold", [6] = "Yngling Hold", [7] = "Skallagrim Hold",
  [8] = "Stenkil Hold", [9] = "Sverker Hold", [10] = "Eric's Hold", [11] = "Munso Hold",
  [12] = "Skjoldung Hold", [13] = "Sigurdsson Hold",
}

local function town_short(lin)
  local name = LIN_NAMES[lin] or ("Lin" .. tostring(lin or "?"))
  return (name:gsub("%s+Hold$", ""))
end

-- ---------------------------------------------------------------------------
-- Demand cycle (guild_viking.lua:10711-10723, gated show_goods_cycle)
-- ---------------------------------------------------------------------------

-- Ported from LEGACY's demand_cycle_color intent (market.demand_cycle_color
-- holds the literal hex; this maps by season keyword rather than re-decoding
-- the hex here, since the by-name mapping is clearer than round-tripping
-- through market.lua's opaque return value). Decoded BGR: spring 0x88DD44 ->
-- R68/G221/B136 (green-lean); summer 0x44CCDD -> R221/G204/B68 (warm,
-- R~=G/low-B = yellow); autumn/fall 0x4488DD -> R221/G136/B68 (R>>G, low-B =
-- orange, nearest available is red); winter 0xCCCCCC -> even grey; calm/
-- default 0xCCCC00 -> R0/G204/B204 (cyan).
local DEMAND_CYCLE_ANSI = {
  spring = C.bright_green, summer = C.yellow, autumn = C.red, fall = C.red, winter = C.white,
}
local function demand_cycle_ansi(name)
  local s = string.lower(name or "")
  for key, col in pairs(DEMAND_CYCLE_ANSI) do
    if string.find(s, key, 1, true) then return col end
  end
  return C.cyan -- calm / unknown default
end

local function demand_cycle_line(width)
  local name = (S.demand_cycle and S.demand_cycle ~= "") and S.demand_cycle or "Calm Season"
  local text = (S.demand_cycle_in or 0) > 0
    and (name .. "  " .. cc.fmt_time(S.demand_cycle_in))
    or name
  return pagelib.trunc(string.format("%sDemand cycle%s  %s%s%s",
    C.dim, pagelib.RESET, demand_cycle_ansi(name), text, pagelib.RESET), width)
end

-- ---------------------------------------------------------------------------
-- No-data fallback (guild_viking.lua:10725-10730, UNGATED)
-- ---------------------------------------------------------------------------

local function no_data_lines(add, width)
  add(pagelib.header(width, "Trade Goods"))
  add(pagelib.trunc(C.dim .. "No data -- enable with: vtoggle mip_trade_goods" .. pagelib.RESET, width))
end

-- ---------------------------------------------------------------------------
-- Market Movers (guild_viking.lua:3376-3437 build_mover_rows's movers part;
-- rendering shape from draw_mover_row, :3507-3540)
-- ---------------------------------------------------------------------------

local function mover_row(width, rank, a)
  local left = string.format("%s%2d.%s %s%-12s%s",
    C.yellow, rank, pagelib.RESET, cc.good_color(a.good), cc.good_label(a.good), pagelib.RESET)
  local buy = string.format("%s%-10s%s %s%4d%s",
    C.dim, town_short(a.buy_lin), pagelib.RESET, C.bright_cyan, a.buy, pagelib.RESET)
  local sell = string.format("%s%-10s%s %s%4d%s",
    C.bright_green, town_short(a.sell_lin), pagelib.RESET, C.bright_green, a.sell, pagelib.RESET)
  local tail = string.format("%s+%dd%s  %s(%d/u)%s",
    C.bright_green, a.profit or 0, pagelib.RESET, C.dim, a.margin or 0, pagelib.RESET)
  local hot_tag = market.mover_is_hot(a.sell, a.sell_lin, a.good)
    and ("  " .. C.bright_green .. "HOT" .. pagelib.RESET) or ""
  return pagelib.trunc(left .. " " .. buy .. " -> " .. sell .. "  " .. tail .. hot_tag, width)
end

-- ---------------------------------------------------------------------------
-- Refined Goods (guild_viking.lua:3376-3437's refined part; rendering shape
-- from draw_refsell_row, :3544-3572)
-- ---------------------------------------------------------------------------

local function refsell_row(width, rank, r)
  local left = string.format("%s%2d.%s %s%-12s%s -> %s%-10s%s %s%d/u%s",
    C.yellow, rank, pagelib.RESET, cc.good_color(r.good), cc.good_label(r.good), pagelib.RESET,
    C.bright_green, town_short(r.sell_lin), pagelib.RESET, C.bright_green, r.sell, pagelib.RESET)
  local stock
  if (r.stock or 0) > 0 then
    stock = string.format("%shave %d%s  %s(~%dd)%s",
      C.bright_cyan, r.stock, pagelib.RESET, C.bright_green, r.value or 0, pagelib.RESET)
  else
    stock = C.dim .. "no stock" .. pagelib.RESET
  end
  local demand = string.format("%sDemand: %d%s", C.dim, r.demand or 0, pagelib.RESET)
  local blocked = (r.blocked or 0) > 0
    and string.format("  %s%d blocked%s", C.yellow, r.blocked, pagelib.RESET) or ""
  return pagelib.trunc(left .. "  " .. stock .. "  " .. demand .. blocked, width)
end

-- ---------------------------------------------------------------------------
-- Auto-Trade status / log (guild_viking.lua:3376-3437's at_line part;
-- job-segment shape from at_build_job_segs, :3288-3306)
-- ---------------------------------------------------------------------------

local function job_row(width, j, indent)
  local pad = string.rep(" ", indent or 4)
  local out = C.dim .. "- " .. pagelib.RESET
  out = out .. ((j.mode == "sell")
    and (C.yellow .. "sell " .. pagelib.RESET)
    or (C.bright_green .. "buy " .. pagelib.RESET))
  out = out .. C.white .. (j.qty or 0) .. "x " .. pagelib.RESET
  out = out .. cc.good_color(j.good) .. cc.good_label(j.good) .. pagelib.RESET
  if j.mode == "buy" and j.btown_lin then
    out = out .. "  " .. C.dim .. town_short(j.btown_lin) .. pagelib.RESET
  elseif j.stock then
    out = out .. "  " .. C.dim .. "(stock)" .. pagelib.RESET
  end
  out = out .. " " .. C.dim .. "->" .. pagelib.RESET .. " "
  out = out .. C.bright_green .. town_short(j.stown_lin) .. pagelib.RESET
  out = out .. "  " .. C.bright_green .. string.format("+%dd", j.profit or 0) .. pagelib.RESET
  if (j.margin or 0) > 0 then
    out = out .. "  " .. C.dim .. string.format("(%d/u)", j.margin) .. pagelib.RESET
  end
  return pagelib.trunc(pad .. out, width)
end

local function autotrade_status_lines(add, width)
  local at = S.autotrade or {}
  local on = page_opts.get("auto_trade")

  add("")
  local parts = {
    C.dim .. "Auto-Trade " .. pagelib.RESET .. (on and (C.bright_green .. "ON") or (C.cyan .. "off"))
      .. pagelib.RESET,
    C.dim .. "Margin " .. pagelib.RESET .. C.bright_cyan .. ">=" .. tostring(at.min_margin or 3)
      .. pagelib.RESET,
    C.dim .. "Reserve " .. pagelib.RESET .. C.yellow .. tostring(at.reserve or 0) .. pagelib.RESET,
    C.dim .. "Carts " .. pagelib.RESET .. C.yellow .. tostring(at.max_carts or 2) .. pagelib.RESET,
  }
  if at.pack then parts[#parts + 1] = C.magenta .. "Pack" .. pagelib.RESET end
  if at.use_stock then parts[#parts + 1] = C.bright_green .. "Use-stock" .. pagelib.RESET end
  add(pagelib.trunc(table.concat(parts, "   "), width))

  if on and at.status and at.status ~= "" then
    add(pagelib.trunc(C.yellow .. "Idle: " .. at.status .. pagelib.RESET, width))
  end

  if at.last_jobs and #at.last_jobs > 0 then
    add(pagelib.trunc(C.dim .. "Last run:" .. pagelib.RESET, width))
    for _, j in ipairs(at.last_jobs) do
      add(job_row(width, j, 4))
    end
  elseif at.last_msg and at.last_msg ~= "" then
    -- Fallback for sessions saved before structured job data existed
    -- (LEGACY:3452-3459).
    add(pagelib.trunc(C.dim .. "Last run:" .. pagelib.RESET, width))
    for job in (at.last_msg):gmatch("[^;]+") do
      job = job:gsub("^%s+", ""):gsub("%s+$", "")
      if job ~= "" then
        add(pagelib.trunc("  " .. C.white .. "- " .. job .. pagelib.RESET, width))
      end
    end
  end

  if page_opts.get("show_goods_atlog") and at.log and #at.log > 0 then
    add(pagelib.trunc(C.dim .. "Auto-Trade Log:" .. pagelib.RESET, width))
    local first = math.max(1, #at.log - 12)
    for li = first, #at.log do
      local e = at.log[li]
      if type(e) == "table" and e.jobs then
        add(pagelib.trunc(string.format("  %s%s  %s%d %s%s",
          C.bright_cyan, e.t or "", C.yellow, #e.jobs, (#e.jobs == 1 and "job" or "jobs"),
          pagelib.RESET), width))
        for _, j in ipairs(e.jobs) do
          add(job_row(width, j, 6))
        end
      else
        -- Legacy plain-string entry from an older session (LEGACY:3477-3479).
        add(pagelib.trunc("    " .. C.dim .. tostring(e) .. pagelib.RESET, width))
      end
    end
  end

  -- Stage 4: the right-click Auto-Trade Options popup menu (toggle Auto-
  -- Trade/Pack/Use-stock, cycle Margin/Reserve/Carts/Shown) is not ported.
  add(pagelib.trunc(C.dim .. "Auto-trade controls: stage 4" .. pagelib.RESET, width))
end

local function movers_block_lines(add, width)
  add(pagelib.header(width, "Market Movers"))
  local arb = market.compute_market_movers()
  if #arb == 0 then
    add(pagelib.trunc(
      C.dim .. "Gathering data - need town prices (vtoggle mip_trade_goods)" .. pagelib.RESET, width))
  else
    local show_n = (S.autotrade and S.autotrade.show_n) or 6
    local shown = math.min(#arb, show_n)
    for i = 1, shown do
      add(mover_row(width, i, arb[i]))
    end
  end

  if page_opts.get("show_goods_refined") then
    local rsell = market.compute_refined_sells()
    if #rsell > 0 then
      add("")
      add(pagelib.header(width, "Refined Goods"))
      for i, r in ipairs(rsell) do
        add(refsell_row(width, i, r))
      end
    end
  end

  autotrade_status_lines(add, width)
end

-- ---------------------------------------------------------------------------
-- Price rows (guild_viking.lua:10731-10763 GOOD_ORDER/header setup,
-- :10763-10774 the rows loop, gated show_goods_prices)
-- ---------------------------------------------------------------------------

local GOOD_ORDER = {
  "timber", "ore", "iron", "furs", "fish", "grain", "mead", "sunstone", "runestones",
  "spoils", "salted_fish", "bread", "fine_furs", "tools", "gemstones", "honey",
  "weapons", "armour", "finery",
}

-- Ported from LEGACY's AFF_LABEL (guild_viking.lua:10692-10702): numeric
-- affinity score (-3..3) -> a short marker (trailing pixel-alignment spaces
-- dropped; not needed in a text row).
local AFF_LABEL = { [3] = "+++", [2] = "++", [1] = "+", [0] = "", [-1] = "-", [-2] = "--", [-3] = "---" }

-- Ported from LEGACY's AFF_COLOR (guild_viking.lua:10685-10691), decoded
-- BGR: +3..+1 (demand side) decode to a green family (0x44FF44 -> R44/G255/
-- B44, etc); 0 (neutral) decodes to grey; -1..-3 (produces side) decode to a
-- RED family (0xAAAAFF -> R255/G170/B170, etc -- NOT blue, despite the "AA..
-- FF" pattern looking blue-ish at a glance). Banded coarser than LEGACY's
-- three-shades-per-side gradient (pagelib's 16-color table has no pale
-- green/pale red distinct from grey), but the demand=green / produces=red
-- POLARITY is preserved exactly.
local AFF_COLOR = {
  [3] = C.bright_green, [2] = C.green, [1] = C.green, [0] = C.dim,
  [-1] = C.red, [-2] = C.red, [-3] = C.bright_red,
}

-- price_trend's returned hex color (market.lua, ported from LEGACY's
-- GOOD_COL/BAD_COL/FLAT_COL) is mapped by NAME/intent, not literal BGR
-- decode: BAD_COL (0xFF4444) literally decodes to blue (R44/G44/B255), but
-- every call site uses it to mean "this trend is unfavorable" -- same
-- documented-intent-wins precedent as pages/people.lua's Designations
-- legend. FLAT_COL (0x999999) is decode-neutral grey either way.
local function trend_color(hex)
  if hex == 0x00FF00 then return C.bright_green end
  if hex == 0xFF4444 then return C.bright_red end
  return C.dim
end

local function price_row(width, good, gd, lin)
  local score = gd.score or 0
  local aff_label = AFF_LABEL[score] or ""
  local aff_color = AFF_COLOR[score] or C.dim
  local st = market.price_stats(lin, good)
  local ba, bc_hex = market.price_trend(gd.buy or 0, st and st.bavg, true)
  local sa, sc_hex = market.price_trend(gd.sell or 0, st and st.savg, false)
  local bc, sc = trend_color(bc_hex), trend_color(sc_hex)
  return pagelib.trunc(string.format(
    "  %s%-12s%s %s%-3s%s B:%s%4d%s %s%s%s S:%s%4d%s %s%s%s Sup:%s%3d%s Dem:%s%3d%s",
    cc.good_color(good), cc.good_label(good), pagelib.RESET,
    aff_color, aff_label, pagelib.RESET,
    C.magenta, gd.buy or 0, pagelib.RESET, bc, ba, pagelib.RESET,
    C.cyan, gd.sell or 0, pagelib.RESET, sc, sa, pagelib.RESET,
    C.dim, gd.supply or 0, pagelib.RESET,
    C.dim, gd.demand or 0, pagelib.RESET), width)
end

local function price_rows_lines(add, width)
  for lin = 0, 13 do
    local gdata = S.trade_goods[lin]
    if gdata and next(gdata) then
      add(pagelib.trunc(C.bright_cyan .. (LIN_NAMES[lin] or ("Lineage " .. lin)) .. pagelib.RESET, width))
      for _, good in ipairs(GOOD_ORDER) do
        local gd = gdata[good]
        if gd then
          add(price_row(width, good, gd, lin))
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------

function M.lines(width)
  width = width or 80
  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  if page_opts.get("show_goods_cycle") then
    add(demand_cycle_line(width))
  end

  -- UNGATED early exit (LEGACY:10725-10730): everything below is skipped
  -- when trade_goods carries no data at all, regardless of any other opt.
  if not S.trade_goods or not next(S.trade_goods) then
    no_data_lines(add, width)
    return lines
  end

  if page_opts.get("show_goods_movers") then
    movers_block_lines(add, width)
  end

  if page_opts.get("show_goods_prices") then
    price_rows_lines(add, width)
  end

  return lines
end

return M
