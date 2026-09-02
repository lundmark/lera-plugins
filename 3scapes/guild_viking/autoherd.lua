-- Auto-Herd: client-side livestock husbandry automation -- SETTINGS HALF
-- ONLY (Stage 4 husbandry plan, Task 3 of 4). This file builds the
-- persisted settings table, the `/vik herd <sub>` config directive parser,
-- and the settings menu. Task 4 adds M.tick() and the planner that actually
-- decides what to buy, on top of the surface built here -- there is no
-- tick() in this file, no planner, and nothing below ever calls mud.send.
-- So, deliberately, nothing in Task 3 can act.
--
-- *** SPENDING WARNING -- stated plainly, not softened ***
-- Turning `page_opts.get("auto_herd")` ON authorises purchases IMMEDIATELY
-- once Task 4's planner lands on top of this file: `restock`, `crossbreed`
-- and `buy_quality` all default to true below (LEGACY's own defaults,
-- verified at guild_viking_husbandry.lua:83-98 and preserved verbatim), and
-- `reserve` (2000 daler) is the ONLY brake stopping the planner from
-- spending every daler above that floor. This is LEGACY's own behaviour and
-- is the CHOSEN behaviour for this port, not an oversight -- it is
-- documented here, plainly, so nobody discovers it by losing daler.
--
-- Auto-Herd emits exactly ONE command form once Task 4's planner is wired
-- up: `vlivestock buy <lineage_token> <id>`. It NEVER emits
-- `vlivestock slaughter` -- the server has that command (vlivestock.c), but
-- LEGACY never called it (grepping guild_viking_husbandry.lua for
-- "slaughter" finds only the two stale comments quoted below, no send
-- site), and slaughtering livestock is irreversible.
--
-- `keep` (default 4) is NOT a slaughter setting, despite LEGACY's own
-- comment on it (guild_viking_husbandry.lua:86) reading "breeders kept when
-- slaughtering surplus" -- that comment is stale. The code only ever reads
-- `keep` as the RESTOCK BREEDING FLOOR once Task 4's planner exists (it
-- will be consumed the same way LEGACY's own ah_keep_ok()/restock planner
-- read it, husbandry.lua:270 -- that citation is to Task 4's own
-- not-yet-written file, so unlike every LEGACY citation in this header it
-- could NOT be grep-verified today; flagged as such rather than asserted).
-- Nothing in this port slaughters anything. Documented correctly here
-- rather than copied stale.
--
-- PROVENANCE, every line grep-verified against
-- /home/simon/code/3s_scripts_old/lua/guild_viking_husbandry.lua before
-- writing (see the task-3 report for the exact grep commands and their
-- output):
--   AH_INTERVAL / AH_CONFIRM_TIMEOUT / AH_COOLDOWN   38-40
--   LIVE_BLDGS                                        42
--   GOAL_W                                            66-73
--   GOAL_ORDER                                        74
--   ah_settings (-> M.settings), DEFAULTS table        81-112 (table 83-98)
--   bldg_tier / owns (-> local helpers)               117-122
--   ah_bldg_alias (-> local bldg_alias)               441-448
--   ah_status_line (-> local status_line)             450-467
--   ah_usage (-> local usage)                         469-474
--   ah_config (-> M.config)                           476-544
--   AH_RESERVE_STEPS / AH_KEEP_STEPS / AH_TRAIT_CHOICES     565-567
--   ah_step (-> local step_fwd, forward-only; see below)    574-580
--   aherd_menu_build (-> M.menu_items)                588
--   aherd_menu_build's "no buildings owned" fallback row
--     (-> M.menu_items' "_none" row)                  646-649
--   viking_show_aherd_menu (-> M.open_menu)           653-687
--   viking_aherd_menu_pick (-> local menu_pick)       689-736
--
-- Review-round citation fixes (this round only; see the task-3 report's
-- "Fix round" section for the grep/awk commands that verified each): the
-- open_menu citation previously read 653-672, which is mid-function (inside
-- a WindowAddHotspot call) -- the real close is 687. The steps-tables/
-- ah_step citation previously read 565-579 as one range; split above into
-- the three one-line step tables (565-567, no ambiguity: each is a
-- single-line local ending on its own line) and ah_step itself (574-580,
-- closing `end` verified). The "no buildings owned" fallback row (LEGACY's
-- `id="_none"` row, previously silently dropped from M.menu_items()) is now
-- ported, at its real location 646-649 -- not 610-611 (that range is
-- actually the middle of the `_hdr` row a few lines above it in the
-- function; a second citation error, this one not mine, corrected here
-- rather than copied). Per updated instruction: citations below and above
-- name the opening line only where a range added nothing; a range is kept
-- only where it usefully bounds a whole function/block, and every range's
-- closing line was located (not estimated) before being written down.
--
-- CORRECTION to the task-3 brief's own citations and directive list: the
-- brief cites the config-directive grammar at
-- "guild_viking_husbandry.lua:471-472" -- that range is only the middle two
-- of the FOUR lines of ah_usage's usage STRING (the string itself spans
-- 470-473; ah_usage the function is 469-474). The function that actually
-- PARSES those directives, ah_config, is 476-544 (grep-verified above), not
-- 471-472. The brief's own directive list also silently omits the master
-- `on`/`off` toggle and `debug on|off | log [clear] | status`, all of which
-- LEGACY's ah_config handles (476-544, see especially 480-481 for on/off).
-- This port keeps all of them: dropping the only on/off switch would leave
-- the master toggle unreachable from `/vik herd on` (Task 4's wiring of
-- LEGACY's own `aherd on` alias), and dropping debug/log/status would
-- narrow "exactly LEGACY's directives" (the brief's own stated goal) to an
-- unstated subset. Reported to the reviewer rather than silently resolved.
--
-- Also flagged for the reviewer: LEGACY's own usage string advertises
-- `age <n|off>`, but ah_config's numeric-directive grammar
-- (`"^(%a+)%s+(%d+)$"`, digits only) never matches the literal word "off",
-- so `aherd age off` has always fallen through to ah_usage() in LEGACY --
-- the documented "|off" form doesn't actually work (age_refresh=0, via
-- `aherd age 0`, achieves the same "off" effect the comment describes).
-- Ported verbatim, not fixed, matching the plan's own "port exactly, don't
-- fix" rule (the same rule autoraid.lua's header applies to its own
-- redundant-guards).
--
-- Adaptations (all mechanical, same idiom as autoraid.lua/autotrader/core.lua):
--   * LEGACY's implicit global `state` -> `S` (require("state").S).
--   * `page_opts.auto_herd` (LEGACY's bare table field) ->
--     page_opts.get("auto_herd") / page_opts.set("auto_herd", v). The key
--     and its `false` default already exist in page_opts.lua (added in
--     Task 2), so no page_opts.lua change is needed here.
--   * ColourNote(name, "", text) -> a local note(hex, text) that calls
--     buffer.color_print(nil, hex, text), same helper shape as
--     autoraid.lua. LEGACY's four colour names here (orange/red/darkorange/
--     gray) map to their standard HTML/CSS hex equivalents, matching the
--     convention autoraid.lua's and autovoyage.lua's own headers already
--     use for the identical named colours: orange=FFA500, red=FF0000,
--     darkorange=FF8C00, gray=808080 (autovoyage.lua's header already uses
--     gray=808080 for this exact name).
--   * OnPluginSaveState() -> a local save() helper that calls
--     require("persist").save(), with the require DEFERRED into the
--     function body rather than a top-level `local persist = ...` -- same
--     idiom and same reasoning as autoraid.lua's own save() (see that
--     module's header): nothing currently requires autoherd.lua from a
--     page, so there is no live cycle today, but deferring costs nothing
--     and keeps this module safe if a later task (Task 4, or a Stats-page
--     Automation-section wiring like pages/stats.lua's own autoraid/
--     autovoyage reads) ends up requiring it from inside the
--     persist -> window -> pages.city require chain.
--   * `aherd_menu_build`'s WindowCreate rows -> M.menu_items() returns
--     require("menu")-shaped items ({id=, label=, value=}); `id` mirrors
--     LEGACY's own row.id, and `value` is set equal to `id` so
--     require("menu")'s on_select dispatch (which reads item.value) works
--     unchanged. Per-item colours (col=... in LEGACY) have no equivalent in
--     menu.lua's plain-label rows and are dropped, same disposition
--     autoraid.lua's own menu port already discloses.
--   * `viking_aherd_menu_pick`'s left/right/middle-click distinctions (its
--     own `right_click`/`middle_click` flags, used to raise/lower reserve
--     and keep, cycle trait either direction, and cycle a building's
--     target/keep on right/middle click) have no equivalent in
--     require("menu")'s single-select model (Enter only). Every cycling
--     item here (goal/reserve/keep/trait) becomes a single FORWARD-only
--     cycle through the same ordered list LEGACY used, and a per-building
--     row's select toggles `enabled` only -- LEGACY's right-click
--     (per-building target) and middle-click (per-building keep override)
--     cycles are dropped. Same "content fidelity, not interaction
--     fidelity" ruling autoraid.lua's own menu port (and its Ships-cycle in
--     particular) already applies; still reachable in full via
--     `/vik herd bldg <name> target <n>` / `keep <n>` (M.config, ported
--     verbatim above).
--
-- No planner, no M.tick(): this file only builds/reads settings and the
-- config/menu surface. Nothing here calls mud.send.
local S = require("state").S
local page_opts = require("page_opts")

local M = {}

-- persist.lua's own require("window") chain can circle back through a page
-- that requires this module (see the OnPluginSaveState adaptation note
-- above) -- deferred the same way autoraid.lua's own save() is.
local function save()
  require("persist").save()
end

-- LEGACY:38-40.
local AH_INTERVAL        = 20   -- seconds between planning cycles
local AH_CONFIRM_TIMEOUT = 15   -- seconds to wait for confirmation (Task 4)
local AH_COOLDOWN        = 30   -- seconds to pause after an unconfirmed action (Task 4)
M.AH_INTERVAL = AH_INTERVAL

local function note(hex, text)
  buffer.color_print(nil, hex, text)
end

-- LEGACY:42.
local LIVE_BLDGS = { "sheepfold", "henhouse", "piggery", "byre", "stable" }

-- LEGACY:83-98 (the DEFAULTS half of ah_settings). Preserved verbatim,
-- including the three spending actions defaulting ON -- see the module
-- header's spending warning. `keep`'s comment is corrected, not copied
-- stale (see the header).
local DEFAULTS = {
  goal        = "yield",  -- stat weighting: yield|fert|con|hard|vigor|balanced
  reserve     = 2000,     -- daler kept untouched by buys
  keep        = 4,        -- restock breeding floor (NOT a slaughter
                           -- setting -- see module header)
  gen_refresh = 0,        -- crossbreed when generation >= this (0 = auto via Con)
  age_refresh = 40,       -- crossbreed when herd age >= this (0 = off, matches server penalty)
  restock     = true,     -- buy foundation stock into empty/under-target buildings
  trait_pref  = "any",    -- prefer trait animals: "any" | "off" | a trait id
  crossbreed  = true,     -- allow fresh-breed injections (hybrid vigor)
  buy_quality = true,     -- allow stat-improving buy-ins
  feed_guard  = true,     -- warn / queue grain when herds would go unfed
  feed_ticks  = 4,        -- grain buffer target, in ticks
  quality_margin = 5,     -- min score improvement to justify a quality buy
  debug       = false,
}

-- LEGACY:66-73.
local GOAL_W = {
  yield    = { hard=1, fert=1, yield=4, vigor=1, con=2 },
  fert     = { hard=1, fert=4, yield=1, vigor=2, con=1 },
  con      = { hard=2, fert=1, yield=1, vigor=1, con=4 },
  hard     = { hard=4, fert=1, yield=1, vigor=1, con=2 },
  vigor    = { hard=1, fert=2, yield=1, vigor=4, con=1 },
  balanced = { hard=1, fert=1, yield=1, vigor=1, con=1 },
}
-- LEGACY:74.
local GOAL_ORDER = { "yield", "fert", "con", "hard", "vigor", "balanced" }

-- LEGACY:117-122 (bldg_tier / owns).
local function bldg_tier(b)
  return (S.buildings and (S.buildings[b] or 0)) or 0
end
local function owns(b)
  return bldg_tier(b) >= 1
end

-- LEGACY:81-112 (ah_settings). Creates S.autoherd from DEFAULTS on first
-- call (plus the UI/log bookkeeping fields LEGACY's own table literal also
-- carried: buildings, last, status, log), then backfills any per-building
-- entry missing from an older save -- same two-phase guard shape LEGACY's
-- own function used.
function M.settings()
  if not S.autoherd then
    local ah = {}
    for k, v in pairs(DEFAULTS) do ah[k] = v end
    ah.buildings = {}
    ah.last = 0
    ah.status = ""
    ah.log = {}
    S.autoherd = ah
  end
  local ah = S.autoherd
  if ah.buildings == nil then ah.buildings = {} end
  if ah.log == nil then ah.log = {} end
  -- Default per-building config: enabled, target head (0 = breed toward
  -- cap), keep (nil = use global keep). LEGACY:106-108.
  for _, b in ipairs(LIVE_BLDGS) do
    if ah.buildings[b] == nil then
      ah.buildings[b] = { enabled = true, target = 0, keep = nil }
    end
  end
  return ah
end

-- LEGACY:441-448 (ah_bldg_alias). Map rebuilt per call, matching LEGACY's
-- own shape exactly (a local table literal inside the function body).
local function bldg_alias(name)
  name = (name or ""):lower()
  local map = {
    sheep = "sheepfold", fold = "sheepfold", hen = "henhouse", coop = "henhouse",
    chicken = "henhouse", pig = "piggery", sty = "piggery", swine = "piggery",
    cow = "byre", cattle = "byre", horse = "stable", stable = "stable",
    sheepfold = "sheepfold", henhouse = "henhouse", piggery = "piggery", byre = "byre",
  }
  return map[name]
end

-- LEGACY:469-474 (ah_usage). Text unchanged, including the stale "aherd"
-- alias name (Task 4 maps `/vik herd <sub>` onto M.config, same fold
-- autoraid.lua's own header discloses for its "araid" usage-line naming).
local function usage()
  note("FF0000", "[Auto-Herd] usage: aherd on|off | goal <yield|fert|con|hard|vigor|balanced> | "
    .. "reserve <n> | keep <n> | gen <n|auto> | age <n|off> | trait <any|off|prolific|hardy|bountiful|purebred> | stock on|off | cross on|off | quality on|off | "
    .. "feed on|off | feedticks <n> | margin <n> | bldg <name> on|off|target <n>|keep <n> | "
    .. "debug on|off | log [clear] | status")
end

-- LEGACY:450-467 (ah_status_line).
local function status_line(ah)
  note("FFA500", string.format(
    "[Auto-Herd] %s | goal %s | trait %s | reserve %d | keep %d | gen %s | age %s | stock %s | cross %s | quality %s | feed-guard %s (%d tk)",
    page_opts.get("auto_herd") and "ON" or "OFF", ah.goal, ah.trait_pref or "any", ah.reserve, ah.keep,
    (ah.gen_refresh and ah.gen_refresh > 0) and tostring(ah.gen_refresh) or "auto",
    (ah.age_refresh and ah.age_refresh > 0) and tostring(ah.age_refresh) or "off",
    ah.restock and "on" or "off", ah.crossbreed and "on" or "off", ah.buy_quality and "on" or "off",
    ah.feed_guard and "on" or "off", ah.feed_ticks))
  local parts = {}
  for _, b in ipairs(LIVE_BLDGS) do
    if owns(b) then
      local c = ah.buildings[b] or {}
      parts[#parts + 1] = string.format("%s[%s t%d]", b, c.enabled ~= false and "on" or "off", bldg_tier(b))
    end
  end
  if #parts > 0 then note("FF8C00", "  owned: " .. table.concat(parts, " ")) end
  if ah.status and ah.status ~= "" then note("808080", "  status: " .. tostring(ah.status)) end
end

-- ---------------------------------------------------------------------------
-- Control surface: /vik herd <sub> (Task 4 wires the alias; this is the
-- LEGACY:476-544 ah_config port) and the settings menu (LEGACY:588-736,
-- aherd_menu_build + viking_aherd_menu_pick). See module header for every
-- adaptation.
-- ---------------------------------------------------------------------------

-- LEGACY:476-544 (ah_config).
function M.config(rest)
  local ah = M.settings()
  rest = (rest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

  if rest == "on" then
    page_opts.set("auto_herd", true); note("FFA500", "[Auto-Herd] ON.")
  elseif rest == "off" then
    page_opts.set("auto_herd", false); note("FFA500", "[Auto-Herd] OFF.")
  elseif rest == "stock on" then
    ah.restock = true; note("FFA500", "[Auto-Herd] stock/restock ON.")
  elseif rest == "stock off" then
    ah.restock = false; note("FFA500", "[Auto-Herd] stock/restock OFF.")
  elseif rest == "cross on" then
    ah.crossbreed = true; note("FFA500", "[Auto-Herd] crossbreed ON.")
  elseif rest == "cross off" then
    ah.crossbreed = false; note("FFA500", "[Auto-Herd] crossbreed OFF.")
  elseif rest == "quality on" then
    ah.buy_quality = true; note("FFA500", "[Auto-Herd] quality buy-ins ON.")
  elseif rest == "quality off" then
    ah.buy_quality = false; note("FFA500", "[Auto-Herd] quality buy-ins OFF.")
  elseif rest == "feed on" then
    ah.feed_guard = true; note("FFA500", "[Auto-Herd] feed guard ON.")
  elseif rest == "feed off" then
    ah.feed_guard = false; note("FFA500", "[Auto-Herd] feed guard OFF.")
  elseif rest == "debug on" then
    ah.debug = true; note("FFA500", "[Auto-Herd] debug ON.")
  elseif rest == "debug off" then
    ah.debug = false; note("FFA500", "[Auto-Herd] debug OFF.")
  elseif rest == "gen auto" then
    ah.gen_refresh = 0; note("FFA500", "[Auto-Herd] crossbreed gen threshold: auto (Constitution-based).")
  elseif rest == "log clear" then
    ah.log = {}; note("FFA500", "[Auto-Herd] log cleared.")
  elseif rest == "log" then
    if #ah.log == 0 then
      note("FFA500", "[Auto-Herd] log is empty.")
    else
      note("FFA500", "[Auto-Herd] recent activity:")
      for _, e in ipairs(ah.log) do
        note("FF8C00", "  " .. (e.t or "") .. " " .. (e.desc or ""))
      end
    end
  elseif rest == "" or rest == "status" then
    status_line(ah)
  else
    local goal = rest:match("^goal%s+(%a+)$")
    if goal and GOAL_W[goal] then
      ah.goal = goal; note("FFA500", "[Auto-Herd] goal set to " .. goal .. ".")
      save(); return
    end
    if goal then
      note("FF0000", "[Auto-Herd] goals: " .. table.concat(GOAL_ORDER, ", ")); return
    end

    local tp = rest:match("^trait%s+(%a+)$")
    if tp then
      local valid = { any = true, off = true, prolific = true, hardy = true,
                       bountiful = true, purebred = true }
      if valid[tp] then
        ah.trait_pref = tp; note("FFA500", "[Auto-Herd] trait preference = " .. tp .. ".")
        save(); return
      else
        note("FF0000", "[Auto-Herd] trait: any | off | prolific | hardy | bountiful | purebred"); return
      end
    end

    local key, num = rest:match("^(%a+)%s+(%d+)$")
    if key == "reserve" then
      ah.reserve = tonumber(num); note("FFA500", "[Auto-Herd] reserve = " .. num)
    elseif key == "keep" then
      ah.keep = tonumber(num); note("FFA500", "[Auto-Herd] keep = " .. num)
    elseif key == "gen" then
      ah.gen_refresh = tonumber(num); note("FFA500", "[Auto-Herd] crossbreed gen threshold = " .. num)
    elseif key == "age" then
      ah.age_refresh = tonumber(num); note("FFA500", "[Auto-Herd] crossbreed age threshold = " .. num .. " ticks (0 = off)")
    elseif key == "feedticks" then
      ah.feed_ticks = tonumber(num); note("FFA500", "[Auto-Herd] feed buffer = " .. num .. " ticks")
    elseif key == "margin" then
      ah.quality_margin = tonumber(num); note("FFA500", "[Auto-Herd] quality margin = " .. num)
    else
      -- Per-building: aherd bldg <name> on|off|target <n>|keep <n>
      local bname, brest = rest:match("^bldg%s+(%a+)%s+(.+)$")
      local bldg = bldg_alias(bname)
      if bldg then
        ah.buildings[bldg] = ah.buildings[bldg] or { enabled = true, target = 0 }
        local bc = ah.buildings[bldg]
        if brest == "on" then
          bc.enabled = true; note("FFA500", "[Auto-Herd] " .. bldg .. " enabled.")
        elseif brest == "off" then
          bc.enabled = false; note("FFA500", "[Auto-Herd] " .. bldg .. " disabled.")
        else
          local bk, bv = brest:match("^(%a+)%s+(%d+)$")
          if bk == "target" then
            bc.target = tonumber(bv); note("FFA500", "[Auto-Herd] " .. bldg .. " target head = " .. bv)
          elseif bk == "keep" then
            bc.keep = tonumber(bv); note("FFA500", "[Auto-Herd] " .. bldg .. " keep = " .. bv)
          else
            usage()
          end
        end
      else
        usage(); return
      end
    end
  end
  save()   -- persist auto_herd on/off (page_opts) + settings immediately
end

-- LEGACY:565-567 (AH_RESERVE_STEPS/AH_KEEP_STEPS/AH_TRAIT_CHOICES, three
-- one-line locals). LEGACY's own ah_step (574-580, verified via its closing
-- `end` -- see the task-3 report's Fix round) supported a `back` direction
-- for right-click; menu.lua has no equivalent gesture, so step_fwd below
-- only ever steps forward -- see module header's interaction-fidelity note.
local AH_RESERVE_STEPS = { 0, 500, 1000, 2000, 3000, 5000, 10000 }
local AH_KEEP_STEPS    = { 0, 2, 4, 6, 8, 10, 15 }
local AH_TRAIT_CHOICES = { "any", "prolific", "hardy", "bountiful", "purebred", "off" }

-- LEGACY:574-580 (ah_step). Forward-only port, see comment above.
local function step_fwd(cur, list)
  local i = 1
  for k, v in ipairs(list) do if v == cur then i = k break end end
  i = i + 1
  if i > #list then i = 1 end
  return list[i]
end

-- LEGACY:588 (aherd_menu_build). Item order/labels/ids are verbatim
-- (id = row.id); per-item colours (col=...) and tooltips (tip=...) have no
-- equivalent in menu.lua's plain-label rows and are dropped, same
-- disposition as autoraid.lua's own menu port. The "no buildings owned"
-- fallback row (LEGACY:646-649, `id="_none"`) is ported below too -- a
-- settings menu that silently renders no per-building rows when the player
-- owns none of the five livestock buildings would be worse than one that
-- says so.
function M.menu_items()
  local ah = M.settings()
  local on = page_opts.get("auto_herd")
  local items = {
    { id = "on", value = "on", label = "Auto-Herd: " .. (on and "ON" or "off") },
    { id = "goal", value = "goal", label = "Goal (stat weighting): " .. ah.goal },
    { id = "reserve", value = "reserve", label = "Daler reserve: " .. tostring(ah.reserve) },
    { id = "keep", value = "keep", label = "Keep breeders (restock floor): " .. tostring(ah.keep) },
    { id = "restock", value = "restock", label = "Stock/restock buildings: " .. (ah.restock and "on" or "off") },
    { id = "trait", value = "trait", label = "Prefer trait: " .. (ah.trait_pref or "any") },
    { id = "cross", value = "cross", label = "Crossbreed (fresh blood): " .. (ah.crossbreed and "on" or "off") },
    { id = "quality", value = "quality", label = "Quality buy-ins: " .. (ah.buy_quality and "on" or "off") },
    { id = "feed", value = "feed", label = "Feed guard: " .. (ah.feed_guard and "on" or "off") },
    { id = "_hdr", value = "_hdr", label = "Per-building (L-click toggles on/off):" },
  }
  local any_bldg = false
  for _, b in ipairs(LIVE_BLDGS) do
    if owns(b) then
      any_bldg = true
      local bc = ah.buildings[b] or { enabled = true, target = 0 }
      local en = bc.enabled ~= false
      local tgt = (bc.target and bc.target > 0) and tostring(bc.target) or "auto"
      items[#items + 1] = {
        id = "bldg_" .. b, value = "bldg_" .. b, bldg = b,
        label = string.format("  %s t%d [%s, target %s]", b, bldg_tier(b), en and "on" or "off", tgt),
      }
    end
  end
  -- LEGACY:646-649 (aherd_menu_build's `if not any_bldg then` fallback).
  if not any_bldg then
    items[#items + 1] = { id = "_none", value = "_none",
      label = "  (no husbandry buildings owned)" }
  end
  return items
end

-- LEGACY:689-736 (viking_aherd_menu_pick). Every branch saves and reopens
-- the menu in place, matching LEGACY's own OnPluginSaveState() +
-- viking_show_aherd_menu() tail (no target-picker-style quirk here, unlike
-- autoraid.lua's raid target).
local function menu_pick(id)
  local ah = M.settings()
  if id == "on" then
    page_opts.set("auto_herd", not page_opts.get("auto_herd"))
  elseif id == "restock" then
    ah.restock = not ah.restock
  elseif id == "trait" then
    ah.trait_pref = step_fwd(ah.trait_pref or "any", AH_TRAIT_CHOICES)
  elseif id == "cross" then
    ah.crossbreed = not ah.crossbreed
  elseif id == "quality" then
    ah.buy_quality = not ah.buy_quality
  elseif id == "feed" then
    ah.feed_guard = not ah.feed_guard
  elseif id == "goal" then
    ah.goal = step_fwd(ah.goal, GOAL_ORDER)
  elseif id == "reserve" then
    ah.reserve = step_fwd(ah.reserve, AH_RESERVE_STEPS)
  elseif id == "keep" then
    ah.keep = step_fwd(ah.keep, AH_KEEP_STEPS)
  else
    local b = id:match("^bldg_(%a+)$")
    if b then
      ah.buildings[b] = ah.buildings[b] or { enabled = true, target = 0 }
      local bc = ah.buildings[b]
      bc.enabled = not (bc.enabled ~= false)
    end
    -- "_hdr", "_none", and anything else unrecognised: no-op, reopen below.
  end
  save()
  M.open_menu()
end

-- LEGACY:653-687 (viking_show_aherd_menu; closing `end` verified, see the
-- task-3 report's Fix round -- the previous 653-672 citation ended
-- mid-function, inside a WindowAddHotspot call).
function M.open_menu()
  require("menu").open({
    items = M.menu_items(),
    title = "Auto-Herd Settings",
    on_select = function(value) menu_pick(value) end,
  })
end

-- Cross-session persistence snapshot/restore, called from persist.lua's
-- M.save()/M.load() -- same shape as autoraid.lua's own M.snapshot()/
-- M.restore(), persist.lua's established pattern for a plugin-local
-- automation-settings table (see persist.lua's header and Fix round 1, I-2
-- note on autoraid.lua for why this pair exists at all).
function M.snapshot()
  return { autoherd = S.autoherd }
end

function M.restore(tbl)
  if not tbl then return end
  if tbl.autoherd then S.autoherd = tbl.autoherd end
end

return M
