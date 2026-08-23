-- Auto-Voyage: the client-side voyage-chart router. Ported verbatim from
-- LEGACY guild_viking.lua:3576-4343 (the whole "Auto-Voyage (client-side)"
-- section) plus MAIN:11437-11541 (the settings mini-window menu):
--   AV_INTERVAL/AV_HAZARD/AV_SEVERE/AV_POI/AV_HARBOR   3581-3590
--   av_settings          3592  ->  M.settings
--   av_pick_offer        3618  ->  M.pick_offer
--   av_log               3657  ->  M.log
--   av_cell              3665  ->  M.cell
--   av_label             3673  ->  M.label
--   av_key               3677  ->  M.key
--   av_skip               3678  ->  M.skip
--   av_nearest            3688  ->  M.nearest
--   av_step               3721  ->  M.step        -- the VOYAGE-CHART router;
--                                                     see the note below, this
--                                                     is NOT pathfinding.lua's
--                                                     land-map vmap_bfs (Task 4).
--   av_pick_resolve       3789  ->  M.pick_resolve
--   av_has_trait          3820  ->  M.has_trait
--   av_per_step           3834  ->  M.per_step
--   av_path_steps         3846  ->  M.path_steps
--   av_hull_floor         3890  ->  M.hull_floor
--   av_goal               3898  ->  M.goal
--   av_all_ships          3944  ->  M.all_ships
--   auto_voyage_tick      3957  ->  M.tick          -- gate at 3958, AV_INTERVAL
--                                                       at 3962, one action per
--                                                       tick (every branch below
--                                                       ends in an early return)
--   av_cmd + vk_avoyage_handler   4306-4343  ->  M.config / M.voyage_command
--   avoyage_menu_build            11444      ->  menu_items (local)
--   viking_show_avoyage_menu      11468      ->  M.open_menu
--   viking_avoyage_menu_pick      11503      ->  menu_pick (local)
--   av_cycle_ship                 11494      ->  cycle_ship (local)
--
-- Reached via `/vik voyage auto [<sub>]` (init.lua); notify.lua calls
-- M.tick() itself from countdown_tick's tail, THIRD (after autotrade and
-- autoraid -- LEGACY guild_viking.lua:2885-2890's own order), so init.lua
-- only needs this module for the command surface, same division of labour
-- as autotrader/tick.lua.
--
-- OFF BY DEFAULT: page_opts.get("auto_voyage") is false until a user opts
-- in, and M.tick()'s very first line (mirroring LEGACY:3958 exactly) is that
-- gate -- nothing below it runs, and nothing is ever sent, until it is
-- flipped on. Every send in this module goes through mud.send(), so the
-- deadmans plugin's on_send governance applies for free (see CLAUDE.md's
-- Push/deadmans section) -- this module needs no deadmans-specific code.
--
-- Adaptations (all mechanical, no logic changes):
--   * LEGACY's implicit global `state` -> `S` (require("state").S), same
--     idiom as every other module in this plugin.
--   * `page_opts.auto_voyage` / `page_opts.av_verbose` (LEGACY's bare table
--     fields) -> `page_opts.get("auto_voyage")` / `page_opts.set(...)` --
--     both keys already exist in page_opts.lua's defaults (added ahead of
--     this task, both false), so no page_opts.lua change is needed here.
--   * IsConnected() -> mud.connected(); Send(cmd) -> mud.send(cmd).
--   * Functions LEGACY made top-level GLOBALS (`function av_foo()` with no
--     `local`) purely to stay under MUSHclient Lua's 200-main-chunk-local
--     cap are ordinary module members here (same disclosed reasoning as
--     autotrader/core.lua's header).
--   * ColourNote(name, "", text) -> a local note(hex, text) that calls
--     buffer.color_print(nil, hex, text). The four named colours LEGACY uses
--     here (orange/red/teal/gray) are mapped to their standard HTML/CSS hex
--     equivalents -- the same values MUSHclient's own named-colour table
--     resolves them to -- rather than an arbitrary pick: orange=FFA500 (also
--     the exact value pagelib.pct_color's LEGACY-ported thresholds use for
--     "orange"), red=FF0000, teal=008080, gray=808080.
--   * OnPluginSaveState() -> persist.save().
--   * av_cmd's own alias dispatch (`AddAlias("vk_avoyage", ...)`,
--     LEGACY:4339-4343) has no equivalent -- `/vik voyage auto <sub>`
--     (init.lua) calls M.voyage_command(rest) directly, matching the plan
--     brief's explicit command mapping. Every response STRING is unchanged,
--     including the literal word "avoyage" in the usage line (LEGACY's own
--     alias name, now stale under `/vik voyage auto` but kept byte-for-byte
--     per the plan's verbatim-string rule).
--   * Bare `/vik voyage auto` (rest == "") opens the settings menu -- this
--     is the ONE deliberate behavior change in this module, not a verbatim
--     port. LEGACY's own bare `avoyage` (no argument) fell through av_cmd's
--     last branch and just printed the trailing status line (the menu was
--     reachable only from a right-click page-context item with no alias
--     equivalent, guild_viking.lua:11234-11239 -- item.action ==
--     "avoyage_config"). lera has no such right-click page chrome (dropped
--     in stage 2/3) and the task brief assigns the bare form to the menu
--     explicitly, so that mapping wins here -- the exact same disposition
--     autotrader/tick.lua's header discloses for `/vik trader`'s bare form.
--   * M.open_menu/menu_pick replace viking_show_avoyage_menu/
--     viking_avoyage_menu_pick: LEGACY's bespoke WindowCreate/AddHotspot
--     popup (11468-11492) becomes a require("menu") menu (13 items, LEGACY's
--     own id/label/val order). menu.lua has one label string per row, not
--     LEGACY's two side-by-side columns, so each row's label/value pair is
--     concatenated "Label: value" (mission-priority rows: "  N. Type
--     (hint)") -- content fidelity, not pixel fidelity, the same ruling
--     this plan's Global Constraints applies elsewhere and autotrader/
--     tick.lua's own menu already relies on. Per-item colours (LEGACY's
--     `col=`) have no equivalent in menu.lua's plain rows and are dropped.
--     Selecting an item performs the exact same toggle/cycle LEGACY's pick
--     handler did, saves, then reopens the menu in place (LEGACY did the
--     same at 11539: `viking_show_avoyage_menu(mx, my)`). LEGACY's
--     `viking_avoyage_menu_pick` also calls `viking_window.update()`
--     (11540) right after that reopen -- dropped here, same disposition as
--     every other `viking_window.*` call cut from this port (stage 2's own
--     ruling: that Portal detached-window repaint has no lera analog).
--     Almost certainly inert in this architecture regardless: `menu.open`
--     already calls `ui.dirty()`, and every renderer re-reads state fresh
--     each frame, so there is nothing left for a second repaint to catch.
--   * S.autovoyage is shared module state, exactly like S.autotrade
--     (autotrader/core.lua's M.settings()) -- not module-local like
--     autotrader/tick.lua's `sm`, so there is no M.reset(): a test resets it
--     the same documented way guild_viking_autotrader_test.lua resets
--     S.autotrade directly (plugin-local settings state, not a wire-parsed
--     field). Fix round 1, I-2: it is ALSO now persisted to disk exactly
--     like S.autotrade, through M.snapshot()/M.restore() below and
--     persist.lua's M.save()/M.load() -- before this fix, persist.lua had
--     no way to carry S.autovoyage at all, so only page_opts' auto_voyage/
--     av_verbose on-off flags survived a reload; risk/ship/mission_prio/
--     diff_min/diff_max/allow_abyssal were silently lost every restart,
--     unlike LEGACY's OnPluginSaveState (MAIN 3023-3024), which serializes
--     the whole `state` table and so persisted state.autovoyage for free.
local S = require("state").S
local page_opts = require("page_opts")
local persist = require("persist")

local M = {}

-- LEGACY:3581.
local AV_INTERVAL = 8   -- seconds between auto-voyage actions

-- LEGACY:3582-3590. Cells the router prefers to steer around (higher step
-- cost). V=maelstrom and C=ice floes are the punishing Abyssal weathers;
-- A=aurora calm is a boon, so it is intentionally NOT a hazard (the ship may
-- sail through it freely).
local AV_HAZARD = { T=true, W=true, B=true, D=true, F=true, M=true, ["="]=true, V=true, C=true }
-- Severe cells cost double a normal hazard: a maelstrom can wrench the ship
-- a tile off her line (wasting a step), so the router avoids it hard.
local AV_SEVERE = { V=true }
local AV_POI    = { X=true, I=true, ["?"]=true }   -- objective / island / unknown node
local AV_HARBOR = { H=true, Y=true }               -- harbor (unresolved / resolved)

-- LEGACY:3592-3612 (av_settings).
function M.settings()
  if not S.autovoyage then
    S.autovoyage = { risk = "balanced", ship = "", last = 0, target = nil,
                     returning = false, worked = 0, log = {},
                     visited = {}, avoid = {}, stuck = 0,
                     mission_prio = { "raid", "salvage", "discovery", "harvest", "hunt" },
                     diff_min = 1, diff_max = 99, allow_abyssal = false }
  end
  local a = S.autovoyage
  if a.risk == nil then a.risk = "balanced" end
  if a.allow_abyssal == nil then a.allow_abyssal = false end
  if type(a.visited) ~= "table" then a.visited = {} end   -- cells already worked/reached
  if type(a.avoid)   ~= "table" then a.avoid   = {} end   -- cells proven unreachable
  if a.stuck == nil then a.stuck = 0 end
  if type(a.mission_prio) ~= "table" or #a.mission_prio == 0 then
    a.mission_prio = { "raid", "salvage", "discovery", "harvest", "hunt" }
  end
  if a.diff_min == nil then a.diff_min = 1 end
  if a.diff_max == nil then a.diff_max = 99 end
  return a
end

-- LEGACY:3614-3655 (av_pick_offer). Choose a launch contract from the
-- offered set. Keep contracts whose danger is in the acceptable
-- [diff_min, diff_max] range, then rank by the mission-type PRIORITY list
-- (raid #1, salvage #2, ... by default) so the most-wanted available type
-- wins; ties break to the highest danger (best reward under the ceiling).
function M.pick_offer(a, offers)
  local list = offers and offers.list or {}
  if #list == 0 then return 1 end
  local lo = a.diff_min or 1
  local hi = a.diff_max or 99
  local rank = {}
  for i, t in ipairs(a.mission_prio or {}) do rank[t:lower()] = i end
  local function prio(o) return rank[(o.type or ""):lower()] or 999 end   -- unknown types rank last

  -- Abyssal band (danger 11-15) is opt-in; a suicidal fit (0) is never taken.
  local function eligible(o)
    local d = o.danger or 0
    local fit = o.fit or 3
    if fit < 1 then return false end                     -- never auto-launch a doomed ship
    if d >= 11 and not a.allow_abyssal then return false end
    return d >= lo and d <= hi
  end
  local pool = {}
  for _, o in ipairs(list) do
    if eligible(o) then pool[#pool + 1] = o end
  end
  if #pool == 0 then
    -- nothing in range: fall back to any non-suicidal, non-Abyssal offer
    for _, o in ipairs(list) do
      if (o.fit or 3) >= 1 and (o.danger or 0) <= 10 then pool[#pool + 1] = o end
    end
    if #pool == 0 then return 1 end
  end

  table.sort(pool, function(x, y)
    local px, py = prio(x), prio(y)
    if px ~= py then return px < py end                 -- higher priority (lower rank) first
    local fx, fy = x.fit or 3, y.fit or 3
    if fx ~= fy then return fx > fy end                 -- prefer the safer-fitted contract
    return (x.danger or 0) > (y.danger or 0)             -- then hardest for best reward
  end)
  return (pool[1] and pool[1].index) or 1
end

-- LEGACY:3657-3663 (av_log). Only prints to the buffer when
-- page_opts.get("av_verbose") is on; the entry is always recorded.
function M.log(msg)
  local a = M.settings()
  a.log = a.log or {}
  a.log[#a.log + 1] = os.date("%H:%M ") .. msg
  while #a.log > 30 do table.remove(a.log, 1) end
  if page_opts.get("av_verbose") then
    buffer.color_print(nil, "008080", "[Auto-Voyage] " .. msg)
  end
end

-- LEGACY:3665-3671 (av_cell).
function M.cell(x, y)
  local rows = S.voyage_chart_rows
  if not rows then return "#" end
  local row = rows[y + 1]
  if not row or #row < (x + 1) then return "#" end
  return row:sub(x + 1, x + 1)
end

-- LEGACY:3673 (av_label).
function M.label(x, y) return string.char(65 + y) .. tostring(x + 1) end

-- LEGACY:3675-3683 (av_key, av_skip). Stable key for a chart cell, and the
-- set of cells the autopilot should NOT pick as an explore target again
-- (already worked, or proven unreachable).
function M.key(x, y) return x .. "," .. y end
function M.skip(a)
  local s = {}
  for k in pairs(a.visited or {}) do s[k] = true end
  for k in pairs(a.avoid   or {}) do s[k] = true end
  return s
end

-- LEGACY:3685-3712 (av_nearest). Nearest cell whose symbol is in `set`, by
-- Manhattan distance from (cx,cy). `exclude` (optional, keyed by M.key)
-- skips cells already handled so the autopilot stops fixating on the same
-- island/unknown and wasting moves.
function M.nearest(set, cx, cy, exclude)
  local rows = S.voyage_chart_rows or {}
  -- Map centre, used only to break DISTANCE ties: among equally-near
  -- candidates prefer the one nearer the middle of the chart. This stops the
  -- explorer from hugging the grid edges (where scan order would otherwise
  -- pick the top/left frontier cell), so it heads into open water and
  -- reveals more new map. It never overrides hazard avoidance -- that lives
  -- in M.step's path cost.
  local w = S.voyage_chart_width  or (#(rows[1] or ""))
  local h = S.voyage_chart_height or #rows
  local ccx, ccy = (w - 1) / 2, (h - 1) / 2
  local best, bd, bc
  for y = 0, #rows - 1 do
    local row = rows[y + 1] or ""
    for x = 0, #row - 1 do
      if set[row:sub(x + 1, x + 1)] and not (exclude and exclude[M.key(x, y)]) then
        local d = math.max(math.abs(x - cx), math.abs(y - cy))
        local cdist = math.abs(x - ccx) + math.abs(y - ccy)
        if not bd or d < bd or (d == bd and cdist < bc) then
          bd = d; bc = cdist; best = { x = x, y = y }
        end
      end
    end
  end
  return best
end

-- LEGACY:3714-3782 (av_step). Weighted shortest-path from (cx,cy) to
-- (tx,ty). Hazard cells have a cost penalty based on the risk profile so the
-- ship prefers clean routes but will cut through storms when the risk
-- setting allows it:
--   safe (10x)  -- goes far around hazards before entering them
--   balanced (3x) -- takes a few hazard steps if it saves significant distance
--   max (1x)    -- treats hazards as ordinary cells, shortest path wins
-- Returns the label of the FIRST step ("G2") or nil if unreachable. This is
-- the VOYAGE-CHART router (Dijkstra over state.voyage_chart_rows) -- a
-- different map and a different algorithm from pathfinding.lua's Task 4
-- vmap_bfs (a pure BFS over the separate TERRITORY map, state.vmap_*).
function M.step(cx, cy, tx, ty)
  local w = S.voyage_chart_width or 0
  local h = S.voyage_chart_height or 0
  if cx == tx and cy == ty then return nil end
  local a = M.settings()
  local hazard_cost = (a.risk == "safe" and 10) or (a.risk == "max" and 1) or 3
  local dirs = { {1,0}, {0,1}, {-1,0}, {0,-1}, {1,1}, {-1,1}, {1,-1}, {-1,-1} }   -- E,S,W,NW,NE,SW,SE

  -- Dijkstra: dist stores best-known cost to each cell; prev stores back-links.
  local dist, prev, open = {}, {}, {}
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local k = M.key(x, y)
      dist[k] = 1/0; prev[k] = nil; open[#open+1] = k
    end
  end
  dist[M.key(cx, cy)] = 0

  -- Simple array-based scan (fast enough for voyage chart sizes).
  while #open > 0 do
    -- Find the open cell with smallest dist
    local best, best_k, best_i
    for i, k in ipairs(open) do
      if not best or dist[k] < best then best = dist[k]; best_k = k; best_i = i end
    end
    if not best_k or best == 1/0 then break end   -- unreachable remainder
    table.remove(open, best_i)

    if best_k == M.key(tx, ty) then
      -- Walk backwards to find the first step from (cx,cy)
      local cx_out, cy_out = tx, ty
      while prev[M.key(cx_out, cy_out)] do
        local p = prev[M.key(cx_out, cy_out)]
        if p.x == cx and p.y == cy then return M.label(cx_out, cy_out) end
        cx_out, cy_out = p.x, p.y
      end
      return nil
    end

    -- Parse coordinates from key
    local comma = best_k:find(",")
    local px, py = tonumber(best_k:sub(1, comma - 1)), tonumber(best_k:sub(comma + 1))

    for _, d in ipairs(dirs) do
      local nx, ny = px + d[1], py + d[2]
      if nx >= 0 and ny >= 0 and nx < w and ny < h then
        local nk = M.key(nx, ny)
        local _wc = M.cell(nx, ny)
        local step_cost = AV_SEVERE[_wc] and (hazard_cost * 2) or (AV_HAZARD[_wc] and hazard_cost or 1)
        -- Sailed tiles give a ~15% speed bonus: prefer paths through known waters.
        if step_cost > 0.5 and S.voyage_sailed and S.voyage_sailed[ny + 1] and S.voyage_sailed[ny + 1][nx + 1] then
          step_cost = step_cost / 1.15
        end
        local nd = best + step_cost
        if nd < dist[nk] then
          dist[nk] = nd; prev[nk] = { x = px, y = py }
        end
      end
    end
  end
  return nil
end

-- LEGACY:3784-3817 (av_pick_resolve). Pick a node resolution by what the
-- voyage needs, aware of the node type. Harbor nodes: "repair" (free +hull,
-- some loot) when the hull is hurt, else "trade" for the best haul.
-- Island/other nodes: take the free "resupply" choice when supplies are low
-- (avoids paying daler later), otherwise "plunder" for the biggest daler +
-- thralls. hull_floor is passed so it matches the return maths.
function M.pick_resolve(vs, opts, node_type, hull_floor)
  local has = {}
  for _, o in ipairs(opts) do has[o:lower()] = o end
  local function pick(...)
    for _, k in ipairs({ ... }) do if has[k] then return has[k] end end
    return nil
  end
  local hull_low = (vs.hull or 100) < (hull_floor or 30)
  local sup_low  = (vs.supplies or 100) < 45
  if node_type == "harbor" then
    if hull_low then local c = pick("repair", "careen", "mend"); if c then return c end end
    local c = pick("trade", "repair", "recruit", "shore"); if c then return c end
  elseif node_type == "prompt_ship" then
    -- Sighted ship: pirate or trader. Without MIP ship_type info, avoid combat.
    if hull_low or sup_low then
      local c = pick("flee", "evade"); if c then return c end
    end
    if (vs.threat_level or 0) >= 4 then
      local c = pick("flee", "evade"); if c then return c end
    end
    local c = pick("flee", "evade"); if c then return c end
  else
    if sup_low  then local c = pick("resupply", "ration"); if c then return c end end
    if hull_low then local c = pick("repair", "careen", "mend", "resupply"); if c then return c end end
    if (vs.threat_level or 0) >= 4 then local c = pick("avoid", "hide", "refuse", "scout"); if c then return c end end
    local c = pick("plunder", "hunt", "press", "raid", "take", "scout"); if c then return c end
  end
  return opts[1]
end

-- LEGACY:3819-3828 (av_has_trait). Does the crew/ship carry a named trait?
-- (crew_traits + ship_traits from MIP)
function M.has_trait(vs, name)
  name = name:lower()
  for _, list in ipairs({ vs.crew_traits or {}, vs.ship_traits or {} }) do
    for _, t in ipairs(list) do
      if tostring(t):lower():find(name, 1, true) then return true end
    end
  end
  return false
end

-- LEGACY:3830-3840 (av_per_step). Estimated supplies burned per sailing step
-- (mirrors the server: 1 + danger/3, minus savings from "hidden lockers" and
-- high fleet renown). Drives the point-of-no-return maths, so it must track
-- the real drain as closely as we can from client-visible data.
function M.per_step(vs)
  local n = 1 + math.floor((vs.danger or 1) / 3)
  if M.has_trait(vs, "hidden lockers") then n = n - 1 end
  if (S.fleet_renown or 0) >= 60 then n = n - 1 end
  if n < 1 then n = 1 end
  return n
end

-- LEGACY:3842-3887 (av_path_steps). Actual shortest-path step count from
-- (cx,cy) to (tx,ty), or nil if unreachable. Uses the same Dijkstra cost
-- model as M.step (including sailed discount and hazard penalties) so the
-- supply point-of-no-return in M.goal reflects real terrain, not a
-- straight-line guess.
function M.path_steps(cx, cy, tx, ty)
  local w = S.voyage_chart_width or 0
  local h = S.voyage_chart_height or 0
  if cx == tx and cy == ty then return 0 end
  local a = M.settings()
  local hazard_cost = (a.risk == "safe" and 10) or (a.risk == "max" and 1) or 3
  local dirs = { {1,0}, {0,1}, {-1,0}, {0,-1}, {1,1}, {-1,1}, {1,-1}, {-1,-1} }
  local dist, open = {}, {}
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local k = M.key(x, y)
      dist[k] = 1/0; open[#open+1] = k
    end
  end
  dist[M.key(cx, cy)] = 0
  local target_k = M.key(tx, ty)
  while #open > 0 do
    local best, best_k, best_i
    for i, k in ipairs(open) do
      if not best or dist[k] < best then best = dist[k]; best_k = k; best_i = i end
    end
    if not best_k or best == 1/0 then break end
    table.remove(open, best_i)
    if best_k == target_k then return math.floor(best + 0.5) end
    local comma = best_k:find(",")
    local px, py = tonumber(best_k:sub(1, comma - 1)), tonumber(best_k:sub(comma + 1))
    for _, d in ipairs(dirs) do
      local nx, ny = px + d[1], py + d[2]
      if nx >= 0 and ny >= 0 and nx < w and ny < h then
        local nk = M.key(nx, ny)
        local _wc = M.cell(nx, ny)
        local step_cost = AV_SEVERE[_wc] and (hazard_cost * 2) or (AV_HAZARD[_wc] and hazard_cost or 1)
        if step_cost > 0.5 and S.voyage_sailed and S.voyage_sailed[ny + 1] and S.voyage_sailed[ny + 1][nx + 1] then
          step_cost = step_cost / 1.15
        end
        local nd = best + step_cost
        if nd < dist[nk] then dist[nk] = nd end
      end
    end
  end
  return nil
end

-- LEGACY:3889-3892 (av_hull_floor). Hull floor at which we insist on a
-- harbor repair, by risk profile.
function M.hull_floor(a)
  return (a.risk == "max" and 20) or (a.risk == "safe" and 45) or 30
end

-- LEGACY:3894-3939 (av_goal). Decide the current objective: "repair" |
-- "resupply" | "end" | "explore". Priority: survive (hull) > sustain
-- (supplies/morale) > bank when done > explore. "repair"/"resupply"/"end"
-- all route to the NEAREST harbor; the tick then does the right thing on
-- arrival (repair node choice / resupply command / end).
--
-- NOTE: LEGACY's own comment names a fourth outcome, "resupply", but no
-- branch below ever returns that literal string -- av_goal's actual return
-- values are "end", "repair", and "explore" only (verified against every
-- `return` in this function, LEGACY:3916-3938). Ported as-is; not this
-- module's place to invent a resupply branch LEGACY itself never wrote.
function M.goal(a, vs)
  local hull = vs.hull or 100
  local sup  = vs.supplies or 100
  local mor  = vs.morale or 100
  local per_step = M.per_step(vs)

  local h = M.nearest(AV_HARBOR, vs.x, vs.y)
  local steps_harbor = 8
  if h then
    local path_steps = M.path_steps(vs.x, vs.y, h.x, h.y)
    steps_harbor = path_steps or (math.abs(h.x - vs.x) + math.abs(h.y - vs.y))
  end
  local sup_to_harbor = steps_harbor * per_step

  -- 1) Supplies point-of-no-return: keep just enough to REACH a harbor and
  --    END there (daler resupply is a rare last resort, so we bank rather
  --    than burn coin). Buffer scales with risk. This is the main "when to
  --    head back".
  local reserve = (a.risk == "safe" and 8) or (a.risk == "max" and 2) or 4
  if sup <= sup_to_harbor + reserve then return "end" end

  -- 2) Hull safety -- detour to a harbor and take its "repair" node (free
  --    +hull, even a little loot) so the voyage can keep going rather than
  --    end early.
  if hull < M.hull_floor(a) and h then return "repair" end

  -- 3) Dire morale risks crew loss -- bank what we have.
  if a.risk ~= "max" and mor < 12 then return "end" end

  -- 4) Nothing left worth visiting -> bank the spoils at the nearest harbor.
  --    Ignore cells already worked or proved unreachable, so a map of only
  --    cleared POIs correctly reads as "done" instead of looping.
  local skip = M.skip(a)
  if not (M.nearest(AV_POI, vs.x, vs.y, skip) or M.nearest({ ["#"] = true }, vs.x, vs.y, skip)) then
    return "end"
  end

  -- 5) Risk-based "good enough": safe banks sooner, balanced later, max only
  --    stops when forced by the checks above.
  local worked = a.worked or 0
  if a.risk == "safe" and worked >= 3 then return "end" end
  if a.risk == "balanced" and worked >= 9 then return "end" end
  return "explore"
end

-- LEGACY:3941-3955 (av_all_ships). Every ship name the client knows, merging
-- both fleet feeds (LONGSHIP + SHIPS), deduped and in order. The voyage feed
-- only carries some ships, so the picker must also read S.ships or it misses
-- the rest of the fleet.
function M.all_ships()
  local names, seen = {}, {}
  for _, src in ipairs({ S.voyage_longships or {}, S.ships or {} }) do
    for _, s in ipairs(src) do
      if s.name and s.name ~= "" and not seen[s.name] then
        seen[s.name] = true
        names[#names + 1] = s.name
      end
    end
  end
  return names
end

-- LEGACY:3957-4124 (auto_voyage_tick). See the module header for the safety
-- framing; every one of the gates and branches below is enumerated with its
-- covering test in the task report. Every branch ends in an early `return`
-- (or falls out the bottom of the function with no send at all), so at most
-- ONE mud.send() happens per M.tick() call.
function M.tick()
  if not page_opts.get("auto_voyage") then return end
  if not mud.connected() then return end
  local a = M.settings()
  local now = os.time()
  if a.last and (now - a.last) < AV_INTERVAL then return end
  a.last = now

  -- Wait for the first voyage MIP snapshot before deciding. Without this the
  -- tick can't tell an active voyage from a missing MIP feed and will spam
  -- relaunches while the user actually has a voyage running.
  if not S.mip_voyage_seen then return end

  local vs = S.voyage_status

  -- No active voyage -> relaunch back-to-back.
  if not vs then
    a.returning = false; a.target = nil; a.harbor_target = nil; a.harbor_goal = nil; a.harbor_step_pos = nil; a.worked = 0; a.goal = nil
    -- Fresh map next voyage: forget worked/unreachable cells and stuck state.
    a.visited = {}; a.avoid = {}; a.stuck = 0
    a.plan_pos = nil; a.plan_target = nil; a.plan_goal = nil
    local ship = a.ship
    if ship == nil or ship == "" then
      for _, s in ipairs(S.voyage_longships or {}) do
        local st = (s.state or ""):lower()
        if st == "" or st == "docked" or st == "harbor" then ship = s.name; break end
      end
      if not ship or ship == "" then ship = M.all_ships()[1] end   -- fall back to any known ship
    end
    if not ship or ship == "" then M.log("no idle ship available to launch"); return end

    -- If we already hold fresh contracts for this ship, pick one by type/difficulty.
    local offers = S.voyage_offers
    if offers and offers.ship and offers.ship:lower() == ship:lower() and #(offers.list or {}) > 0 then
      local idx = M.pick_offer(a, offers)
      M.log("launch " .. ship .. " contract " .. idx ..
            " (prio " .. table.concat(a.mission_prio or {}, ">") .. ", danger " ..
            (a.diff_min or 1) .. "-" .. ((a.diff_max or 99) >= 99 and "max" or a.diff_max) .. ")")
      mud.send("vvoyage launch " .. ship .. " " .. idx)
      S.voyage_offers = nil
      a.offers_req = nil
      return
    end

    -- Otherwise ask for the contract board (which pushes a VOFFERS packet),
    -- but no more than once every ~20s while we wait for it to arrive.
    if not a.offers_req or (now - a.offers_req) > 20 then
      a.offers_req = now
      M.log("requesting contracts for " .. ship)
      mud.send("vvoyage launch " .. ship)
    end
    return
  end

  -- Paused at a node -> act on it. A harbor we came to bank at is ended
  -- here; otherwise resolve by need (harbors we pass get looted via
  -- "trade"/"repair").
  if S.voyage_wait and S.voyage_wait ~= "" and #(S.voyage_resolve_options or {}) > 0 then
    local nt = S.voyage_wait
    if nt == "harbor" and a.goal == "end" then
      M.log("docked at harbor -- ending voyage to bank spoils")
      mud.send("vvoyage end")
      a.goal = nil; a.target = nil; a.harbor_target = nil; a.harbor_goal = nil
      return
    end
    if nt ~= "harbor" then
      a.worked = (a.worked or 0) + 1                            -- count loot stops
      a.visited = a.visited or {}
      a.visited[M.key(vs.x, vs.y)] = true                       -- and never re-target it
    end
    local choice = M.pick_resolve(vs, S.voyage_resolve_options, nt, M.hull_floor(a))
    M.log(nt .. " node -> " .. tostring(choice))
    mud.send("vvoyage resolve " .. choice)
    return
  end

  -- Still under way -> wait for it to arrive before queuing anything else.
  -- (Without this it re-queues the same step every tick while sailing.)
  if vs.state == "sailing" then return end
  if S.voyage_queue and #S.voyage_queue > 0 then return end
  if vs.next_move and vs.next_move > now then return end

  -- Stuck guard: if the step we queued last tick did not move us, this
  -- explore target is unreachable (boxed by hazards, or the server refused
  -- the cell). Blacklist it after a few tries and pick something else,
  -- rather than firing the same "explore -> J1" at it forever and wasting
  -- the voyage's moves.
  local poskey = M.key(vs.x, vs.y)
  if a.plan_goal == "explore" and a.plan_pos == poskey and a.plan_target then
    a.stuck = (a.stuck or 0) + 1
    if a.stuck >= 3 then
      a.avoid = a.avoid or {}
      a.avoid[a.plan_target] = true
      M.log("stuck near " .. poskey .. " -- giving up on " .. a.plan_target)
      a.stuck = 0; a.plan_target = nil
    end
  else
    a.stuck = 0
  end

  -- Plan this move: survive (hull) > sustain (supplies) > bank > explore.
  local goal = M.goal(a, vs)
  a.goal = goal

  local target
  if goal == "explore" then
    -- Nearest POI/unknown we have NOT already worked or written off.
    local skip = M.skip(a)
    target = M.nearest(AV_POI, vs.x, vs.y, skip) or M.nearest({ ["#"] = true }, vs.x, vs.y, skip)
    if not target then goal = "end"; a.goal = "end" end
  end
  if goal == "repair" or goal == "end" then
    -- Stick to one harbor until reached, so two equally-near harbors don't
    -- flip each tick and send the ship ping-ponging. BUT re-pick if we are
    -- sitting on the very cell we last queued a harbor step from with an
    -- empty queue: that means we did NOT move (the queue was cleared out
    -- from under us, or the step was refused), so a stale target would just
    -- re-fire the same wrong direction. Recomputing here lets a manual
    -- 'clear' choose a fresh (possibly nearer) harbor from where we
    -- actually are.
    if not a.harbor_target or a.harbor_goal ~= goal or a.harbor_step_pos == poskey then
      a.harbor_target = M.nearest(AV_HARBOR, vs.x, vs.y)
      a.harbor_goal = goal
    end
    target = a.harbor_target
  end

  if not target then
    -- No harbor charted yet: if we wanted to bank, try ending where we sit
    -- (the server rejects it harmlessly if we are not actually at a
    -- harbor); otherwise there is simply nothing to do this tick.
    if goal == "end" then mud.send("vvoyage end") end
    return
  end

  -- Arrived on the target cell already?
  if vs.x == target.x and vs.y == target.y then
    if goal == "end" then
      M.log("ending voyage at harbor"); mud.send("vvoyage end")
      a.goal = nil; a.harbor_target = nil; a.harbor_goal = nil
    else
      -- A POI we reached that did not open a node is spent -- mark it so we
      -- do not turn straight back around to it next tick.
      a.visited = a.visited or {}
      a.visited[poskey] = true
      a.plan_target = nil; a.stuck = 0
      mud.send("vvoyage continue")   -- nudge a node that did not auto-pause
    end
    return
  end

  local step = M.step(vs.x, vs.y, target.x, target.y)
  if step then
    a.plan_pos = poskey
    a.plan_target = M.key(target.x, target.y)
    a.plan_goal = goal
    -- Remember where we queued a harbor step from. If next idle tick finds
    -- us still here with an empty queue, we know we didn't move and should
    -- re-pick the harbor (see the repair/end branch). Cleared for
    -- non-harbor goals so a later harbor plan can't false-match an old
    -- explore position.
    a.harbor_step_pos = (goal == "repair" or goal == "end") and poskey or nil
    M.log(goal .. " -> " .. step)
    mud.send("vvoyage queue " .. step)
  else
    -- No safe, progress-making step toward this target at all: write it off
    -- (when exploring) so a different POI gets a turn.
    if goal == "explore" then
      a.avoid = a.avoid or {}
      a.avoid[M.key(target.x, target.y)] = true
    end
    M.log("boxed in (" .. goal .. "); holding")
  end
end

-- ---------------------------------------------------------------------------
-- Control surface: /vik voyage auto <sub> (LEGACY:4306-4343, av_cmd +
-- vk_avoyage_handler) and the settings menu (LEGACY guild_viking.lua:
-- 11437-11541). See module header for both adaptations.
-- ---------------------------------------------------------------------------

local function note(hex, text)
  buffer.color_print(nil, hex, text)
end

-- LEGACY:4306-4333 (av_cmd).
function M.config(rest)
  local a = M.settings()
  rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local low = rest:lower()
  if low == "on" then
    page_opts.set("auto_voyage", true); note("FFA500", "[Auto-Voyage] ON.")
  elseif low == "off" then
    page_opts.set("auto_voyage", false); note("FFA500", "[Auto-Voyage] OFF.")
  elseif low == "balanced" or low == "max" or low == "safe" then
    a.risk = low; note("FFA500", "[Auto-Voyage] risk = " .. low)
  elseif low == "verbose on" then
    page_opts.set("av_verbose", true); note("FFA500", "[Auto-Voyage] verbose ON.")
  elseif low == "verbose off" then
    page_opts.set("av_verbose", false); note("FFA500", "[Auto-Voyage] verbose OFF.")
  elseif low == "abyssal on" then
    a.allow_abyssal = true
    note("FFA500", "[Auto-Voyage] Abyssal (danger 11-15) contracts ENABLED. Fit your ship well.")
  elseif low == "abyssal off" then
    a.allow_abyssal = false
    note("FFA500", "[Auto-Voyage] Abyssal contracts disabled (caps at danger 10).")
  elseif low == "auto" then
    a.ship = ""; note("FFA500", "[Auto-Voyage] ship = (auto-pick idle)")
  elseif rest:match("^ship%s+") then
    -- NOTE: matched against `rest`, not `low` -- LEGACY's own quirk
    -- (LEGACY:4319), so this one keyword is case-SENSITIVE ("Ship foo"
    -- falls through to the usage error below) while every other keyword
    -- above matches case-insensitively via `low`. Ported as-is.
    a.ship = (rest:gsub("^%S+%s+", "")); note("FFA500", "[Auto-Voyage] ship = " .. a.ship)
  elseif low == "log" then
    note("008080", "[Auto-Voyage] recent actions:")
    for _, m in ipairs(a.log or {}) do note("808080", "  " .. m) end
    return
  elseif rest ~= "" and low ~= "status" then
    note("FF0000", "[Auto-Voyage] usage: avoyage on|off | balanced|max|safe | abyssal on|off | "
      .. "ship <name>|auto | verbose on|off | log")
    return
  end
  persist.save()
  note("FFA500", string.format(
    "[Auto-Voyage] %s | risk %s | ship %s",
    page_opts.get("auto_voyage") and "ON" or "OFF", a.risk or "balanced",
    (a.ship ~= "" and a.ship) or "(auto)"))
end

-- LEGACY guild_viking.lua:11494-11501 (av_cycle_ship).
local function cycle_ship(a)
  local names = { "" }   -- "" = auto-pick an idle ship
  for _, n in ipairs(M.all_ships()) do names[#names + 1] = n end
  local cur, idx = (a.ship or ""), 1
  for i, n in ipairs(names) do if n == cur then idx = i; break end end
  a.ship = names[(idx % #names) + 1]
end

-- LEGACY guild_viking.lua:11524 (the danger-ladder cycle in
-- viking_avoyage_menu_pick).
local DANGER_LADDER = { 1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 99 }

-- LEGACY guild_viking.lua:11444-11466 (avoyage_menu_build). Item order and
-- values are verbatim; per-item colours have no menu.lua equivalent and are
-- dropped (see module header).
local function menu_items()
  local a = M.settings()
  local on = page_opts.get("auto_voyage")
  local items = {
    { label = "Auto-Voyage: " .. (on and "ON" or "off"), value = "on" },
    { label = "Risk profile: " .. (a.risk or "balanced"), value = "risk" },
    { label = "Min danger: " .. tostring(a.diff_min or 1), value = "dmin" },
    { label = "Max danger: " .. (((a.diff_max or 99) >= 99) and "any" or tostring(a.diff_max)), value = "dmax" },
    { label = "Abyssal 11-15: " .. (a.allow_abyssal and "yes" or "no"), value = "abyssal" },
    { label = "Ship: " .. ((a.ship ~= nil and a.ship ~= "") and a.ship or "(auto)"), value = "ship" },
    { label = "Verbose log: " .. (page_opts.get("av_verbose") and "yes" or "no"), value = "verbose" },
    { label = "Mission priority (click to raise):", value = "_hdr" },
  }
  for i, t in ipairs(a.mission_prio or {}) do
    local hint = (i > 1) and "^ up" or "top"
    items[#items + 1] = {
      label = "  " .. i .. ". " .. t:gsub("^%l", string.upper) .. " (" .. hint .. ")",
      value = "prio_" .. t,
    }
  end
  return items
end

-- LEGACY guild_viking.lua:11503-11541 (viking_avoyage_menu_pick), minus the
-- WindowInfo position bookkeeping (no window to reposition here).
local function menu_pick(id)
  local a = M.settings()
  if id == "on" then
    page_opts.set("auto_voyage", not page_opts.get("auto_voyage"))
  elseif id == "risk" then
    a.risk = (a.risk == "balanced" and "max") or (a.risk == "max" and "safe") or "balanced"
  elseif id == "abyssal" then
    a.allow_abyssal = not a.allow_abyssal
  elseif id == "_hdr" then
    -- header row, no action
  elseif id:match("^prio_") then
    -- promote the clicked mission type up one rank in the priority list
    local t = id:sub(6)
    local prio = a.mission_prio or {}
    for i = 2, #prio do
      if prio[i] == t then prio[i], prio[i - 1] = prio[i - 1], prio[i]; break end
    end
  elseif id == "dmin" or id == "dmax" then
    -- Cycle the danger bound through a ladder (99 = "any/max ceiling").
    local key = (id == "dmin") and "diff_min" or "diff_max"
    local cur = a[key] or (key == "diff_min" and 1 or 99)
    local idx = 1
    for i, v in ipairs(DANGER_LADDER) do if v == cur then idx = i; break end end
    a[key] = DANGER_LADDER[(idx % #DANGER_LADDER) + 1]
    if (a.diff_min or 1) > (a.diff_max or 99) then           -- keep min <= max
      if id == "dmin" then a.diff_max = a.diff_min else a.diff_min = a.diff_max end
    end
  elseif id == "ship" then
    cycle_ship(a)
  elseif id == "verbose" then
    page_opts.set("av_verbose", not page_opts.get("av_verbose"))
  end
  persist.save()
  -- Rebuild in place so the new value shows immediately -- LEGACY did the
  -- same (viking_show_avoyage_menu(mx, my), LEGACY:11539).
  M.open_menu()
end

-- LEGACY guild_viking.lua:11468-11492 (viking_show_avoyage_menu), opened by
-- bare `/vik voyage auto` -- see module header for the bare-form adaptation.
function M.open_menu()
  require("menu").open({
    items = menu_items(),
    title = "Auto-Voyage Settings",
    on_select = function(value) menu_pick(value) end,
  })
end

-- /vik voyage auto <sub> dispatch (init.lua). Bare (rest == "") opens the
-- menu; anything else goes through M.config.
function M.voyage_command(rest)
  rest = rest or ""
  if rest == "" then
    M.open_menu()
    return
  end
  M.config(rest)
end

-- Cross-session persistence snapshot/restore, called from persist.lua's
-- M.save()/M.load() -- same shape as autotrader/core.lua's M.snapshot()/
-- M.restore(). Fix round 1, I-2 (see the module header for the full
-- rationale): without this pair, risk/ship/mission_prio/diff_min/diff_max/
-- allow_abyssal were silently lost every restart.
function M.snapshot()
  return { autovoyage = S.autovoyage }
end

function M.restore(tbl)
  if not tbl then return end
  if tbl.autovoyage then S.autovoyage = tbl.autovoyage end
end

return M
