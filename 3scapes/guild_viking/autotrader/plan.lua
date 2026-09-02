-- Auto-trade route planner: builds one tick's arbitrage/stock-offload plan,
-- ported verbatim from LEGACY guild_viking_autotrader.lua:281-667
-- (at_dispatch_stock_sell:281, at_add_stock_leg:307, at_add_deal_legs:337,
-- viking_autotrader_plan:398). Stage 4 Task 2 of the automation plan; the
-- paced/MIP-confirmed execution loop that actually calls mud.send on a
-- rate-limited timer (auto_trade_tick, LEGACY:812-849, and the command/menu
-- surfaces at LEGACY:670-811) is a later task's territory, not this
-- module's -- this module never calls mud.send.
--
-- Return shape (plan.build()): nil ONLY when the tick is off
-- (page_opts.auto_trade false) or still inside the 30s AT_INTERVAL cooldown
-- -- LEGACY returns bare/silently in exactly those two spots too (TRADER:399,
-- 416-417). There is no change-detection: every OTHER gate-blocked call
-- (not connected, settling, cart-packing cooldown, waiting for city data, no
-- idle carts, cart limit reached, no profitable deals) recomputes from
-- current state and returns a fresh table with a freshly-set `status`
-- string every time it is called, exactly as LEGACY recomputes `at.status`
-- on every one of those branches. Otherwise the table shape is:
--   { status = <string|nil>,   -- mirrors at.status: nil once jobs dispatch,
--                               -- else the human-readable reason nothing did
--     jobs = <array>,          -- LEGACY's own job-record shape verbatim:
--                               -- { mode, stock, good, qty, btown_lin,
--                               --   stown_lin, margin, profit, label }
--     commands = <array>,      -- ordered "vtrade ..." strings, exactly what
--                               -- LEGACY's Send() calls would have produced,
--                               -- in emission order
--     last_msg = <string|nil> }  -- mirrors at.last_msg (set only when jobs
--                                -- were produced)
-- `jobs`/`commands` are always present (possibly empty {}); `status`/
-- `last_msg` mirror the same-named fields core.settings() carries, which
-- this module mutates exactly as LEGACY's at.status/at.last/at.last_jobs/
-- at.last_msg -- so a caller that only wants "what does the trader think
-- right now" can also just read core.settings() directly, same as LEGACY.
--
-- Adaptations (all mechanical/architectural, no policy-math changes):
--
--   * Send(cmd) -> a local `send(cmd)` that appends to a module-level
--     capture list instead of writing to the socket, mirroring LEGACY's OWN
--     wrapper architecture (guild_viking_autotrader.lua:793-804, which
--     redirects the global Send into a `captured` table for exactly the
--     same reason: planning and paced/confirmed sending are different
--     phases). The paced runner that replays `commands` -- LEGACY's
--     `transactions()` (LEGACY:772-787) groups them into route/dispatch
--     transactions bounded by "route clear"/"queue add"/"dispatch " -- is
--     Task 3's auto_trade_tick port, not this module.
--
--   * ColourNote/the local `dbg()` closure (LEGACY:420-422, 435-436,
--     448-450, 660) are dropped. Every reason dbg() would have printed is
--     already present, word-for-word or near enough, in the `at.status`
--     string this module sets on the same branch, and the LEGACY 660
--     success line only restates `at.last_msg`/`jobs`. Since real dispatch
--     is deferred to Task 3's paced runner, printing the announcement at
--     PLAN time (as LEGACY does, eagerly, before anything is actually sent)
--     would be misleading in this architecture and would double up with
--     whatever Task 3 prints when it actually executes; Task 3 owns all
--     buffer output for this feature and has `status`/`jobs`/`last_msg`
--     available to do it.
--
--   * AT_INTERVAL = 30 (LEGACY:17) is declared HERE, not in core.lua.
--     core.lua's header attributes it to "the tick-wiring task", but its
--     only USE site (LEGACY:416, `if at.last and (now - at.last) <
--     AT_INTERVAL then return end`) is inside viking_autotrader_plan, i.e.
--     squarely in THIS task's ported range (TRADER 281-669) -- so this
--     module owns the constant and the gate. auto_trade_tick
--     (LEGACY:812-849) does not reference AT_INTERVAL at all.
--
--   * AT_MIN_LEG_QTY (guild_viking.lua:3215), AT_SELL_MIN_SCORE
--     (guild_viking.lua:3203), AT_CURE_MIN_PCT
--     (guild_viking_autotrader.lua:159) are re-declared as module-local
--     constants here (same values). All three are MAIN-scope/private-scope
--     values this module's ported functions read but do not own; market.lua
--     already sets the precedent of privately duplicating AT_SELL_MIN_SCORE
--     for the same reason (it is a MAIN global there too).
--
--   * AT_TOWN (guild_viking.lua:3219-3223) and LIN_NAMES
--     (guild_viking.lua:10668-10677) are module-local data tables here,
--     ported verbatim -- the same two tables the bridge
--     (viking_autotrader_context, MAIN:4128-4135) hands TRADER as
--     `dependencies.towns`/`dependencies.lineage_names`. pages/goods.lua
--     already carries its own private, unexported copy of LIN_NAMES for
--     display; this is a second verbatim copy, following the precedent
--     pages/city_common.lua sets for its own duplicated fmt_time ("this is
--     the one pair of pages that happens to need it too").
--
--   * good_label(good) -> require("pages.city_common").good_label, the
--     already-ported 1:1 copy of the same LEGACY function
--     (guild_viking.lua:7512). A logic module reaching into a pages/ module
--     is a mild layering exception, chosen over a third copy of the
--     ~20-entry label table.
--
--   * IsConnected() -> mud.connected().
--
--   * state.at_hold_until -> S.at_hold_until, read verbatim (LEGACY:405-406
--     is inside this task's range). LEGACY only ever WRITES this global from
--     an on-connect hook at guild_viking.lua:4774, which was outside both
--     TRADER's line range and every stage-4 task's assigned file list at
--     the time this module was written -- flagged in this task's report as
--     dormant until a future task wires a connect hook. Stage 4 Task 3
--     (autotrader/tick.lua) went on to do exactly that, in
--     guild_viking/init.lua's M.on_connect: S.at_hold_until = os.time() + 60,
--     alongside the state.carts/trade_queue/idle_carts wipe from the same
--     LEGACY range. This branch is live from Task 3 onward.
--
--   * state.carts / state.idle_carts vs. state.trade_queue: LEGACY's
--     "waiting for city data" gate (LEGACY:412-413) reads all three as
--     nil-until-MIP-arrives. state.lua (an earlier stage's choice, not this
--     task's) pre-seeds S.carts and S.idle_carts to `{}` at load, which is
--     always truthy, while S.trade_queue genuinely stays nil until the
--     TQUEUE handler first runs. The check below is ported literally
--     (`not S.carts or not S.trade_queue or not S.idle_carts`); in this
--     codebase it is effectively driven by S.trade_queue alone. Not this
--     task's fix to make.
--
--   * The three helpers LEGACY made `local function` (at_dispatch_stock_sell,
--     at_add_stock_leg, at_add_deal_legs) stay private module-locals here
--     too (`at_` prefix dropped, matching core.lua's own convention), not
--     part of this module's public interface -- only `viking_autotrader_plan`
--     (LEGACY's one function meant to be called from outside the file) is
--     exported, as `M.build`.
--
--   * LEGACY:339 declares `local floor = at.min_profit or 0` inside
--     at_add_deal_legs and never reads it again (confirmed by grep over the
--     function body) -- omitted here as dead code, no behavior change.
local S = require("state").S
local page_opts = require("page_opts")
local core = require("autotrader.core")
local market = require("market")
local cc = require("pages.city_common")

local M = {}

-- LEGACY:17. See header: owned here, not core.lua, since this is its only
-- use site.
local AT_INTERVAL = 30

-- LEGACY guild_viking.lua:3215.
local AT_MIN_LEG_QTY = 5

-- LEGACY guild_viking.lua:3203.
local AT_SELL_MIN_SCORE = 2

-- LEGACY guild_viking_autotrader.lua:159 (also privately duplicated in
-- core.lua, which needs it for at_cured_amount/at_cured_premium).
local AT_CURE_MIN_PCT = 78

-- LEGACY guild_viking.lua:3219-3223 (AT_TOWN). lineage_id -> the keyword
-- the server's 'vtrade route/dispatch' commands accept (display names like
-- "Lodbrok's Hold" are NOT accepted).
local AT_TOWN = {
  [0] = "midgard", [1] = "lodbrok", [2] = "eiriksson", [3] = "ui_imair", [4] = "rurikid",
  [5] = "harfagre", [6] = "yngling", [7] = "skallagrim", [8] = "stenkil", [9] = "sverker",
  [10] = "eric", [11] = "munso", [12] = "skjoldung", [13] = "sigurdsson",
}

-- LEGACY guild_viking.lua:10668-10677 (LIN_NAMES). lineage_id -> display
-- name, for job labels.
local LIN_NAMES = {
  [0] = "Midgard", [1] = "Lodbrok's Hold", [2] = "Eiriksson Hold", [3] = "Ui Imair Hold",
  [4] = "Rurikid Hold", [5] = "Harfagre Hold", [6] = "Yngling Hold", [7] = "Skallagrim Hold",
  [8] = "Stenkil Hold", [9] = "Sverker Hold", [10] = "Eric's Hold", [11] = "Munso Hold",
  [12] = "Skjoldung Hold", [13] = "Sigurdsson Hold",
}

-- Send()-capture list for the current M.build() call. See header: a local
-- `send()` stands in for LEGACY's Send(), mirroring LEGACY's own wrapper.
local commands = {}

local function send(cmd)
  commands[#commands + 1] = cmd
end

-- LEGACY:281-303 (at_dispatch_stock_sell). Single direct dispatch of owned
-- warehouse stock (no route/queue machinery) -- the default stock-sell mode.
local function dispatch_stock_sell(at, a, cap)
  local stown = AT_TOWN[a.sell_lin]
  if not stown then return nil end
  local have = core.wh_amount(a.good)
  -- A voluntary graded-good sell moves only the cured portion; a forced
  -- overflow dump ignores this.
  if core.is_graded(a.good) and not a.force then
    local cured = core.cured_amount(a.good)
    if cured < have then have = cured end
  end
  local sq = math.min(have, cap, (a.sell_demand and a.sell_demand > 0) and a.sell_demand or have)
  if sq < 1 then return nil end
  if sq < AT_MIN_LEG_QTY and not a.force then return nil end   -- no trickle carts
  local gain = math.floor(sq * a.sell * core.direct_sell_quality(a.good, sq) + 0.5)
  if gain < (at.min_profit or 0) and not a.force then return nil end   -- overflow dumps bypass the floor
  send(string.format("vtrade dispatch sell %d %s %s%s", sq, a.good, stown, core.sell_qual(a.good)))
  return { mode = "sell", stock = true, good = a.good, qty = sq,
           stown_lin = a.sell_lin, margin = a.margin, profit = gain,
           label = string.format("sell %d %s (stock)->%s +%dd", sq, cc.good_label(a.good),
             LIN_NAMES[a.sell_lin] or stown, gain) }
end

-- LEGACY:307-331 (at_add_stock_leg). Add a stock sell as a ROUTE leg (batch
-- mode) so several stock sells can share ONE cart. Returns (record, units).
local function add_stock_leg(at, a, cap_left)
  local stown = AT_TOWN[a.sell_lin]
  if not stown or cap_left < 1 then return nil end
  local have = core.wh_amount(a.good)
  if core.is_graded(a.good) and not a.force then
    local cured = core.cured_amount(a.good)
    if cured < have then have = cured end
  end
  local sq = math.min(have, cap_left, (a.sell_demand and a.sell_demand > 0) and a.sell_demand or have)
  if sq < 1 then return nil end
  if sq < AT_MIN_LEG_QTY and not a.force then return nil end   -- no trickle legs
  local gain = math.floor(sq * a.sell * core.route_sell_quality(a.good, sq) + 0.5)
  -- Viability only; the caller checks the packed route's total against the
  -- whole-cart floor.
  if gain < 1 and not a.force then return nil end
  send(string.format("vtrade route add sell %d %s %s%s", sq, a.good, stown, core.route_sell_suffix(a.good)))
  return { mode = "sell", stock = true, good = a.good, qty = sq, stown_lin = a.sell_lin,
           margin = a.margin, profit = gain,
           label = string.format("sell %d %s (stock)->%s +%dd", sq, cc.good_label(a.good),
             LIN_NAMES[a.sell_lin] or stown, gain) }, sq
end

-- LEGACY:337-394 (at_add_deal_legs). Add one arbitrage deal's legs to the
-- current route draft (already cleared by the caller). Returns
-- (job_record, cost, units) or nil.
local function add_deal_legs(at, a, budget, cap_left)
  if cap_left < 1 then return nil end

  local btown = AT_TOWN[a.buy_lin]
  local stown = AT_TOWN[a.sell_lin]
  if not stown then return nil end
  -- Use-stock: sell what we already hold, skip buying.
  if at.use_stock then
    local have = core.wh_amount(a.good)
    if core.is_graded(a.good) then
      local cured = core.cured_amount(a.good)
      if cured < have then have = cured end
    end
    if have >= 1 then
      local sq = math.min(have, cap_left, (a.sell_demand and a.sell_demand > 0) and a.sell_demand or have)
      if sq >= AT_MIN_LEG_QTY then
        local gain = math.floor(sq * a.sell * core.route_sell_quality(a.good, sq) + 0.5)
        if gain < 1 then return nil end
        send(string.format("vtrade route add sell %d %s %s%s", sq, a.good, stown, core.route_sell_suffix(a.good)))
        return { mode = "sell", stock = true, good = a.good, qty = sq,
                 stown_lin = a.sell_lin, margin = a.margin, profit = gain,
                 label = string.format("sell %d %s (stock)->%s +%dd", sq, cc.good_label(a.good),
                   LIN_NAMES[a.sell_lin] or stown, gain) }, 0, sq
      end
    end
  end
  if not btown then return nil end
  -- Cap the whole deal by what we actually hold; never dispatch a buy-only
  -- cart (pure spend) -- the sell leg drains the WAREHOUSE, not this route's
  -- own cargo.
  local have = core.wh_amount(a.good)
  if core.is_graded(a.good) then
    local cured = core.cured_amount(a.good)
    if cured < have then have = cured end
  end
  local qty = math.floor(budget / math.max(1, a.buy))
  if a.qty and a.qty > 0 and qty > a.qty then qty = a.qty end
  if qty > cap_left then qty = cap_left end
  if qty > have then qty = have end
  if qty < AT_MIN_LEG_QTY then return nil end   -- no trickle buy legs
  local unit_margin = math.floor(a.sell * core.route_sell_quality(a.good, qty) - a.buy + 0.5)
  local gain = qty * unit_margin
  if gain < 1 then return nil end
  send(string.format("vtrade route add buy %d %s %s", qty, a.good, btown))
  send(string.format("vtrade route add sell %d %s %s%s", qty, a.good, stown, core.route_sell_suffix(a.good)))
  return { mode = "buy", good = a.good, qty = qty, btown_lin = a.buy_lin,
           stown_lin = a.sell_lin, margin = unit_margin, profit = gain,
           label = string.format("buy %d %s @%s->%s (+%d/u, ~%dd)", qty, cc.good_label(a.good),
             LIN_NAMES[a.buy_lin] or btown, LIN_NAMES[a.sell_lin] or stown, unit_margin, gain) },
         qty * a.buy, qty
end

-- LEGACY:398-667 (viking_autotrader_plan). See module header for the return
-- shape and every adaptation.
function M.build()
  commands = {}

  if not page_opts.get("auto_trade") then return nil end
  local at = core.settings()
  if not mud.connected() then
    at.status = "not connected"
    return { status = at.status, jobs = {}, commands = commands }
  end
  local now = os.time()
  if S.at_hold_until and now < S.at_hold_until then
    at.status = string.format("settling after reconnect (%ds)", S.at_hold_until - now)
    return { status = at.status, jobs = {}, commands = commands }
  end
  if S.dispatch_cd_expires_at and S.dispatch_cd_expires_at > now then
    at.status = string.format("cart-packing cooldown, %ds left", S.dispatch_cd_expires_at - now)
    return { status = at.status, jobs = {}, commands = commands }
  end
  if not S.carts or not S.trade_queue or not S.idle_carts then
    -- Reworded, not ported verbatim: Guild.City is a GMCP package here, always
    -- sent, with no toggle and no `vtoggle` command in this client at all. The
    -- port-exactly-don't-fix rule this plugin applies to LEGACY response
    -- strings does not extend to telling a user to run a command that does not
    -- exist. Same disposition as the two livestock hints in autoherd.lua.
    at.status = "waiting for city data"
    return { status = at.status, jobs = {}, commands = commands }
  end
  if #S.idle_carts == 0 then
    at.status = "no idle carts -- all dispatched, upgrading, or none built"
    return { status = at.status, jobs = {}, commands = commands }
  end
  if at.last and (now - at.last) < AT_INTERVAL then return nil end
  at.last = now

  local in_use = #(S.carts or {}) + #(S.trade_queue or {})
  local free = (at.max_carts or 2) - in_use
  local idle = #(S.idle_carts or {})
  if idle < free then free = idle end
  if free <= 0 then
    at.status = string.format("cart limit reached (max %d, %d out/queued, %d idle)", at.max_carts or 2, in_use, idle)
    return { status = at.status, jobs = {}, commands = commands }
  end

  local arb = market.compute_market_movers() or {}
  -- Stock offload can run even with NO arbitrage buys.
  local want_stock = at.use_stock or (at.auto_stock or 0) > 0 or core.warehouse_pct() >= 85
  if #arb == 0 and not want_stock then
    at.status = "no profitable deals right now (and no stock set to offload)"
    return { status = at.status, jobs = {}, commands = commands }
  end

  local cand, seen = {}, {}
  local auto_stock = at.auto_stock or 0
  local wh_full = core.warehouse_pct() >= 85
  local have_stock = at.use_stock or auto_stock > 0 or wh_full
  local sc = {}
  if have_stock then
    local stock_cap = core.cart_cap()
    for _, item in ipairs(S.wstock or {}) do
      local g = item.good
      local amt = (item.amount or 0) - ((S.blocks and S.blocks[g]) or 0)
      if amt < 0 then amt = 0 end
      local overflow = (auto_stock > 0 and amt >= auto_stock) or wh_full
      local include = at.use_stock or overflow
      -- Hold-for-cure: an under-cured refined good sells below par, so don't
      -- voluntarily offload it. A forced overflow dump ignores this.
      local cured_ok = overflow or not core.is_graded(g)
                       or (item.freshness_pct or 100) >= AT_CURE_MIN_PCT
      if amt >= 1 and include and cured_ok then
        local sp, sl, dem = market.best_sell_of(g)
        if sp and sl then
          -- "Sell when high": durable stock waits for real demand instead
          -- of dumping into a weak market; perishables/overflow can't wait.
          local gd = S.trade_goods[sl] and S.trade_goods[sl][g]
          local weak_sell = not core.perishable(g) and not overflow
                            and (gd and (gd.score or 0) or 0) < AT_SELL_MIN_SCORE
          if not weak_sell then
            -- Cap by ONE cart's capacity, matching the dispatch.
            local qty = math.min(amt, stock_cap, (dem and dem > 0) and dem or amt)
            local eff
            if core.is_graded(g) then
              eff = math.floor(sp * core.cured_premium(g) + 0.5)
            elseif core.perishable(g) then
              eff = math.floor(sp * core.fifo_quality(g, qty) / 100 + 0.5)
            else
              eff = sp
            end
            -- Overflow dumps ignore the profit floor.
            if overflow or qty * eff >= (at.min_profit or 0) then
              sc[#sc + 1] = { good = g, stock_only = true, sell_lin = sl, sell = sp,
                              sell_demand = dem, margin = eff, qty = qty, force = overflow }
            end
          end
        end
      end
    end
  end
  if at.stock_priority ~= false then
    -- Default: stock sells first, then arbitrage.
    table.sort(sc, function(x, y) return (x.margin * x.qty) > (y.margin * y.qty) end)
    for _, a in ipairs(sc) do seen[a.good] = true; cand[#cand + 1] = a end
    for _, threshold in ipairs({ math.max(1, at.min_margin or 1), 1 }) do
      for _, a in ipairs(arb) do
        if not seen[a.good] and a.margin >= threshold then
          seen[a.good] = true
          cand[#cand + 1] = a
        end
      end
    end
  else
    -- Mixed mode: merge stock sells and arbitrage deals, sort by profit.
    for _, a in ipairs(sc) do
      if a.stock_only then
        local bb = market.best_buy_of(a.good)
        a.profit_margin = (a.margin or a.sell) - (bb or 0)
      end
    end
    for _, a in ipairs(sc) do seen[a.good] = true end
    for _, a in ipairs(arb) do
      if not seen[a.good] and a.margin >= 1 then
        a.profit_margin = a.margin
        seen[a.good] = true; sc[#sc + 1] = a
      end
    end
    table.sort(sc, function(x, y)
      local xp = (x.profit_margin or x.margin or 0) * (x.qty or 0)
      local yp = (y.profit_margin or y.margin or 0) * (y.qty or 0)
      if xp ~= yp then return xp > yp end
      return (x.profit_margin or x.margin or 0) > (y.profit_margin or y.margin or 0)
    end)
    for _, a in ipairs(sc) do cand[#cand + 1] = a end
  end

  -- Pack mode: chain up to (stops/2) buy->sell pairs onto ONE cart.
  local pairs_per_cart = at.pack and math.max(1, math.floor(core.max_stops() / 2)) or 1
  local cap = core.cart_cap()
  local budget = (S.daler or 0) - (at.reserve or 0)
  local jobs = {}
  local ci = 1
  local dispatched = 0
  while dispatched < free and ci <= #cand do
    local before = #jobs
    local head = cand[ci]
    if head.stock_only then
      if at.stock_route then
        -- Batch mode: fold several stock sells onto ONE cart via a route.
        local chosen = core.pick_cart("stock", head and head.qty or 0, wh_full)
        local chosen_cap = (chosen and chosen.cap) or cap
        send("vtrade route clear quiet")
        if chosen and chosen.cart_id then send("vtrade route cart " .. chosen.cart_id) end
        local packed, cap_left, forced = {}, chosen_cap, false
        local max_legs = at.pack and core.max_stops() or 1
        while ci <= #cand and cand[ci].stock_only and #packed < max_legs and cap_left >= 1 do
          local a = cand[ci]; ci = ci + 1
          local rec, units = add_stock_leg(at, a, cap_left)
          if rec then cap_left = cap_left - (units or 0); packed[#packed + 1] = rec
            if a.force then forced = true end end
        end
        if #packed > 0 then
          local total = 0
          for _, r in ipairs(packed) do total = total + (r.profit or 0) end
          if total < (at.min_profit or 0) and not forced then
            send("vtrade route clear quiet")   -- trickle: not worth a cart, drop the draft
          else
            send("vtrade queue add")
            for _, r in ipairs(packed) do
              if chosen and chosen.cart_id then r.label = r.label .. " [cart #" .. chosen.cart_id .. "]" end
              jobs[#jobs + 1] = r
            end
          end
        end
      else
        -- Default: a single direct dispatch (no route/queue). One cart.
        ci = ci + 1
        local chosen = core.pick_cart("stock", head and head.qty or 0, wh_full)
        local chosen_cap = (chosen and chosen.cap) or cap
        local rec = dispatch_stock_sell(at, head, chosen_cap)
        if rec then
          if chosen and chosen.cart_id then rec.label = rec.label .. " [cart #" .. chosen.cart_id .. "]" end
          jobs[#jobs + 1] = rec
        end
      end
    else
      -- Arbitrage: build a packed buy->sell route on this cart.
      local chosen = core.pick_cart("arb", head and head.qty or 0, false)
      local chosen_cap = (chosen and chosen.cap) or cap
      send("vtrade route clear quiet")   -- fresh draft; failed queue-add can't accumulate
      if chosen and chosen.cart_id then send("vtrade route cart " .. chosen.cart_id) end
      local packed, cap_left, forced, spent = {}, chosen_cap, false, 0
      for _ = 1, pairs_per_cart do
        if ci > #cand then break end
        if cand[ci].stock_only then break end   -- don't fold stock sells into an arb route
        local a = cand[ci]; ci = ci + 1
        local rec, cost, units = add_deal_legs(at, a, budget - spent, cap_left)
        if rec then
          spent    = spent + (cost or 0)
          cap_left = cap_left - (units or 0)
          packed[#packed + 1] = rec
          if a.force then forced = true end
          if cap_left < 1 then break end
        end
      end
      if #packed > 0 then
        local total = 0
        for _, r in ipairs(packed) do total = total + (r.profit or 0) end
        if total < (at.min_profit or 0) and not forced then
          send("vtrade route clear quiet")   -- below floor: drop the draft, spend nothing
        else
          budget = budget - spent            -- commit the spend only when the cart ships
          send("vtrade queue add")
          for _, r in ipairs(packed) do
            if chosen and chosen.cart_id then r.label = r.label .. " [cart #" .. chosen.cart_id .. "]" end
            jobs[#jobs + 1] = r
          end
        end
      end
    end
    if #jobs > before then dispatched = dispatched + 1 end
  end

  if #jobs > 0 then
    local labels = {}
    for _, j in ipairs(jobs) do labels[#labels + 1] = j.label end
    at.last_jobs = jobs
    at.last_msg  = table.concat(labels, "; ")
    at.status    = nil   -- dispatched something; the "Last run" line tells the story
    core.log(jobs)
  else
    at.status = string.format(
      "%d deal(s) found but none affordable after reserve (budget %dd) -- lower reserve/margin/min-profit or raise carts",
      #cand, (S.daler or 0) - (at.reserve or 0))
  end

  return { status = at.status, jobs = jobs, commands = commands, last_msg = at.last_msg }
end

return M
