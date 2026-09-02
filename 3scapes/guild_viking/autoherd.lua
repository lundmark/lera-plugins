-- Auto-Herd: client-side livestock husbandry automation (Stage 4 husbandry
-- plan, Tasks 3 and 4 -- now complete). Task 3 built the persisted settings
-- table, the `/vik herd <sub>` config directive parser and the settings
-- menu; Task 4 added the four-action planner (M.plan) and the paced
-- executor (M.tick) below the status_line helper. M.tick() is the ONLY
-- function in this file that calls mud.send.
--
-- *** SPENDING WARNING -- stated plainly, not softened ***
-- Turning `page_opts.get("auto_herd")` ON authorises purchases IMMEDIATELY:
-- `restock`, `crossbreed` and `buy_quality` all default to true below
-- (LEGACY's own defaults, verified at guild_viking_husbandry.lua:83-98 and
-- preserved verbatim), and `reserve` (2000 daler) is the ONLY brake
-- stopping the planner from spending every daler above that floor. This is
-- LEGACY's own behaviour and is the CHOSEN behaviour for this port, not an
-- oversight -- it is documented here, plainly, so nobody discovers it by
-- losing daler.
--
-- Auto-Herd emits exactly ONE command form, built in exactly one place
-- (buy_cmd, below): `vlivestock buy <lineage_token> <id>`, with a 1-based
-- id. It NEVER emits `vlivestock slaughter` -- the server has that command
-- (vlivestock.c's do_slaughter), but LEGACY never called it (grepping
-- guild_viking_husbandry.lua for "slaughter" finds only the two stale
-- comments quoted below, no send site), and slaughtering livestock is
-- irreversible, so it is outside the authority the master toggle grants.
-- At most ONE action is taken per AH_INTERVAL cycle, and every access check
-- (owned + enabled building, budget above `reserve`, herd space under the
-- building cap, no matching delivery already in S.lpending) happens BEFORE
-- any command is constructed -- see M.plan's own header block.
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
-- TASK 4 additions to this header:
--   * The planner/executor port table lives above M.plan, not here (it is
--     long enough to be worth keeping beside the code it describes).
--   * FOUR corrections to LEGACY or to the task-4 brief are called out
--     inline where they bite, and each is repeated in the task-4 report:
--     (a) `herd.generation` -> `herd.gen`  (crossbreed branch of M.plan);
--     (b) `page_opts.auto_herd` -> page_opts.get("auto_herd")  (M.tick's
--         first line -- a literal port makes the whole module dead);
--     (c) the feed guard compares warehouse grain STOCK against the herds'
--         need, not S.lfeed.grain, which is itself a per-tick NEED figure
--         (see warehouse_amount's comment for the server citations);
--     (d) LEGACY's feed guard also queued grain into the auto-TRADER's buy
--         queue; that cross-module spend is not ported (see branch 1).
--   * `/vik herd [<sub>]` is wired in init.lua by M.herd_command below --
--     without it the entire Task 3 config/menu surface is unreachable.
--   * FIX ROUND, two further adaptations:
--     (e) LEGACY's two `vtoggle` hints are REWORDED, not ported verbatim:
--         "no livestock data - buy stock, or enable: vtoggle mip_livestock"
--         (LEGACY:356) and "waiting for city data (vtoggle mip_city)"
--         (LEGACY:399). The port-exactly-don't-fix rule this plugin applies
--         to LEGACY response strings does not extend to telling a user to
--         run a command that does not exist: Guild.Livestock and Guild.City
--         are GMCP packages here, always sent, with no toggle and no
--         `vtoggle` command in this client. pages/livestock.lua already
--         dropped the same half of the same hint in Task 2 (see that file's
--         header) -- this makes the two files consistent.
--     (f) The per-tick grain draw and the warehouse grain stock each have
--         exactly ONE implementation now, shared with pages/livestock.lua's
--         Feed section: M.feed_draw (below) and market.lua's
--         M.wh_amount_of/M.wh_known. The page previously divided the
--         server's per-tick NEED by a client re-derivation of the same need
--         and labelled the result a starvation runway; the planner and the
--         page can no longer disagree about either quantity.
local S = require("state").S
local page_opts = require("page_opts")
-- Fix round: the ONE warehouse reader in the plugin (M.wh_amount_of /
-- M.wh_known) now lives in market.lua, so the feed guard here and
-- pages/livestock.lua's Feed section answer "how much grain is in the
-- warehouse" from the same code. market.lua requires only state, so this is
-- a leaf require -- no cycle, unlike the deferred persist require below.
local market = require("market")

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

-- ---------------------------------------------------------------------------
-- Static game data mirrored from the server (defines.h / set.h) -- the
-- planner half (Task 4). pages/livestock.lua already carries its own private
-- copies of HERD_CAP and LIVESTOCK_FEED_PER_HEAD for display maths; these
-- are deliberately a SECOND private copy rather than a new shared module,
-- matching the convention this plugin already follows for LIN_NAMES (three
-- private copies today: pages/goods.lua:105, pages/livestock.lua:131,
-- autotrader/plan.lua:157).
-- ---------------------------------------------------------------------------

-- LEGACY:43. LEGACY:44's SPECIES_BLDG is deliberately NOT carried over: it
-- is dead code in LEGACY too (`grep -n SPECIES_BLDG
-- guild_viking_husbandry.lua` finds only its own declaration, line 44, and
-- no reader), and nothing in the planner ever maps a species back to a
-- building.
local BLDG_SPECIES = { sheepfold = "sheep", henhouse = "chicken",
                       piggery = "pig", byre = "cow", stable = "horse" }

-- LEGACY:46 (HERD_CAP; tiers 1..5, from defines.h's HERD_CAP_* constants).
-- Same five rows pages/livestock.lua:117 mirrors.
local HERD_CAP = {
  sheepfold = { 6, 14, 28, 50, 80 },
  henhouse  = { 12, 28, 56, 100, 160 },
  piggery   = { 6, 14, 28, 50, 80 },
  byre      = { 4, 10, 20, 36, 56 },
  stable    = { 8, 16, 28, 40, 60 },
}

-- LEGACY:53.
local LIVESTOCK_FEED_PER_HEAD = 8

-- LEGACY:58 (AH_LINEAGE_TOKEN). Single-word lineage tokens the server's
-- lineage_id_from_name() accepts, keyed by the numeric lineage id LMARKET
-- carries -- this avoids display-name mismatches ("Ui Imair" is not a token).
-- ONE deliberate difference from LEGACY: [3] is "ui_imair" here, the primary
-- spelling in the authoritative lmap
-- (3s/players/viking/cmd/vlivestock.c:46), where LEGACY wrote "imair". That
-- same lmap line registers "ui_imair", "uiimair" AND "imair" as three keys
-- all mapping to 3, so both spellings work -- this is the authoritative one
-- the task brief asked for, not a bug fix.
local LIN_TOKENS = {
  [1]  = "lodbrok",    [2]  = "eiriksson", [3]  = "ui_imair",   [4]  = "rurikid",
  [5]  = "harfagre",   [6]  = "yngling",   [7]  = "skallagrim", [8]  = "stenkil",
  [9]  = "sverker",    [10] = "eric",      [11] = "munso",      [12] = "skjoldung",
  [13] = "sigurdsson",
}

-- LEGACY:75. Score boost so a wanted-trait animal wins outright.
local AH_TRAIT_BONUS = 1000

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
-- PLANNER + EXECUTOR (Task 4). Everything from here to M.plan()/M.tick()
-- decides what to buy, and M.tick() is the ONLY function in this module that
-- calls mud.send. Read the module header's spending warning first.
--
-- Ported from guild_viking_husbandry.lua:
--   cap_for                123      -> cap_for (local)
--   pending_head           131      -> pending_head (local)
--   warehouse_amount       139      -> warehouse_amount (local)
--   score_stats            148      -> score_stats (local)
--   inbreed_threshold      154      -> inbreed_threshold (local)
--   log_action             157      -> log_action (local)
--   best_listing           169      -> best_listing (local)
--   buy_cmd                192      -> buy_cmd (local); its format string 195
--   ah_plan                202-359  -> M.plan  (closing `end` at 359, located
--                                      not estimated -- see the task report)
--     feed guard             219
--     stock / restock        256
--     crossbreed refresh     289
--     quality buy-in         320
--   ah_sm                  366      -> ah_sm (local)
--   ah_state_sig           368      -> ah_state_sig (local)
--   auto_herd_tick         386-436  -> M.tick  (closing `end` at 436; the
--                                      master-toggle gate is 387)
-- ---------------------------------------------------------------------------

-- Every numeric read out of S goes through this rather than `x or 0`.
-- handlers/livestock.lua does coerce what it writes, but each of S.lfeed,
-- S.lmarket, S.lpending, S.lneeds and S.buildings is legitimately `{}` (or
-- absent) before its first Guild.Livestock/Guild.City frame, S.daler starts
-- at -1 ("not yet received"), and per-building overrides come from a
-- user-editable persisted table. `x or 0` would still let a STRING reach an
-- arithmetic operator; tonumber(x) or 0 cannot.
local function num(x)
  return tonumber(x) or 0
end

-- LEGACY:123 (cap_for).
local function cap_for(bldg, tier)
  local t = HERD_CAP[bldg]
  if not t then return 0 end
  if tier < 1 then tier = 1 elseif tier > 5 then tier = 5 end
  return t[tier] or 0
end

-- LEGACY:131 (pending_head; the brief's ":130" is the second line of its own
-- two-line comment, 129-130). Animals already paid for and in transit
-- (LPENDING) count toward the herd, "so the planner doesn't keep re-buying
-- while deliveries are on the road" -- LEGACY's own words. This is the
-- pending-delivery access check, and all three buy branches below apply it.
local function pending_head(bid)
  local n = 0
  for _, p in ipairs(S.lpending or {}) do
    if p.bldg == bid then n = n + num(p.count) end
  end
  return n
end

-- LEGACY:139 (warehouse_amount). NOTE, and this is a correction to the task
-- brief rather than a port decision: the brief says to compare the herds'
-- per-tick draw "against S.lfeed.grain". S.lfeed.grain is not a grain STOCK
-- -- the server's _v_lfeed() (client.h:4202) fills it from
-- query_livestock_feed_needs() (query.h:2464), which sums grain NEEDED PER
-- TICK, and vlivestock.c:609 renders that very number as "Feed per tick: N
-- grain + N water (N head)". Comparing need against need * feed_ticks is
-- true whenever any head exists, so the brief's literal reading makes the
-- feed guard fire unconditionally forever. LEGACY compared the WAREHOUSE
-- stock (warehouse_amount("grain"), LEGACY:233) against the need, which is
-- the only comparison that means anything, so that is what is ported here.
--
-- Fix round: the body moved to market.lua's M.wh_amount_of (LEGACY:3315-3318
-- extended with LEGACY:139's array fallback), which pages/livestock.lua's
-- Feed section now calls too. Kept as a one-line local so the call sites
-- below still read like LEGACY's.
local function warehouse_amount(good)
  return market.wh_amount_of(good)
end

-- The herds' per-tick grain draw, and the single answer both this module's
-- feed guard and pages/livestock.lua's Feed section use.
--
-- The SERVER has already computed this figure -- S.lfeed.grain, via
-- _v_lfeed() -> query_livestock_feed_needs() (query.h:2464) -- and its
-- number is strictly better than any client re-derivation, because it
-- applies the fesetr feed-saving skill and the per-building minimum of 1
-- grain, neither of which a client can see. LEGACY's own ceil(head / 8)
-- (guild_viking_husbandry.lua:231) is therefore kept only as the fallback
-- for the window before the LFEED key has arrived. `head` is the caller's
-- own head figure, so the feed guard keeps LEGACY's owned-buildings-only
-- scoping while the page passes the server's total.
function M.feed_draw(head)
  local g = num(S.lfeed and S.lfeed.grain)
  if g > 0 then return g end
  return math.ceil(num(head) / LIVESTOCK_FEED_PER_HEAD)
end

-- LEGACY:148 (score_stats). Works on a herd record and a market record
-- alike: handlers/livestock.lua gives both the same five stat field names
-- (hard/fert/yield/vigor/con).
local function score_stats(s, w)
  return num(s.hard) * w.hard + num(s.fert) * w.fert + num(s.yield) * w.yield
       + num(s.vigor) * w.vigor + num(s.con) * w.con
end

-- LEGACY:154 (inbreed_threshold). This is what `gen_refresh = 0` ("auto via
-- Con") resolves to -- a real server-derived function, NOT a formula
-- invented here: the server's inbreeding drift sets in once a herd's
-- generation exceeds con/20 + 5, which is the point a fresh outside breed
-- becomes worth injecting. LEGACY's own crossbreed line is
--   local thresh = (ah.gen_refresh and ah.gen_refresh > 0)
--                  and ah.gen_refresh or inbreed_threshold(herd)
-- and it is reproduced verbatim (modulo num()) in M.plan below.
local function inbreed_threshold(herd)
  return math.floor(num(herd.con) / 20) + 5
end

-- LEGACY:157 (log_action). Feeds M.config's `log` directive.
local function log_action(ah, desc)
  ah.log[#ah.log + 1] = { t = os.date("%H:%M"), desc = desc }
  while #ah.log > 40 do table.remove(ah.log, 1) end
end

-- STRUCTURAL ADAPTATION, the only one in the planner: LEGACY read ONE flat
-- array, state.livestock_market. Here S.lmarket is keyed by numeric lineage
-- id, each value a per-lineage array, because the server sends one
-- lmarket_1..lmarket_13 key per lineage and omits a lineage with no pool
-- (handlers/livestock.lua's write_lmarket merges rather than replaces for
-- exactly that reason). So every listing sweep goes through this two-level
-- iterator instead of ipairs()ing a flat list -- and, importantly, `#S.lmarket`
-- would be 0 for a table keyed { [1] = ..., [7] = ... }, which is why the
-- any-data tail of M.plan counts through here too rather than taking a length.
--
-- The lineage keys are visited in sorted order rather than raw pairs() order
-- on purpose: pairs() order is unspecified, so two listings with an equal
-- goal score in different lineages would otherwise be tie-broken
-- unpredictably -- and the tie-break decides which animal gets BOUGHT.
-- LEGACY's single flat array had a stable order for free; this restores it.
local function each_listing(fn)
  local lm = S.lmarket
  if type(lm) ~= "table" then return end
  local keys = {}
  for k in pairs(lm) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then return na < nb end
    return tostring(a) < tostring(b)
  end)
  for _, k in ipairs(keys) do
    local pool = lm[k]
    if type(pool) == "table" then
      for _, m in ipairs(pool) do fn(m) end
    end
  end
end

-- What the server will actually CHARGE for a listing, which is NOT the
-- record's `price` field. CORRECTION TO LEGACY (and to this port's own first
-- cut), verified against the server:
--   * world/livestock_daemon.c:310 stores `"price": price * count` -- the
--     record's price is already a LOT TOTAL, not a per-head price;
--   * cmd/vlivestock.c's do_buy then sets `int buy_count = lot_count;` when
--     no count argument is given (buy_cmd below never passes one) and
--     requires `int total_cost = price * buy_count;`.
-- So the daler the player needs on hand is price * count, and the server's
-- own market table agrees -- vlivestock.c:210 renders `price * qty` as the
-- "T:" (total) column beside "P:". Gating on `price` alone lets the planner
-- send a buy the server refuses, and because a refusal changes no state the
-- phase machine cools down, replans, picks the SAME listing and repeats
-- forever. Every count = 1 lot is the one case where the two figures agree.
local function lot_cost(m)
  return num(m.price) * math.max(1, num(m.count))
end

-- LEGACY:169 (best_listing). Best AFFORDABLE listing of `species`, optionally
-- requiring a breed different from `avoid_breed` and/or a score at or above
-- `min_score`, scored by the active goal. The server already gates and scales
-- each village pool by reputation, and this scans every village, so taking
-- the top-scored listing needs no separate rep filter (LEGACY:161-166).
-- `m.trait ~= "0"` is kept even though handlers/livestock.lua already
-- normalises "0" to nil: the check is free, and it keeps this function honest
-- against a hand-built record (the tests pass trait = "0" literally).
local function best_listing(ah, species, budget, avoid_breed, min_score)
  local w = GOAL_W[ah.goal] or GOAL_W.balanced
  local best, best_score
  each_listing(function(m)
    if m.species == species and lot_cost(m) <= budget then
      if not (avoid_breed and m.breed == avoid_breed) then
        local sc = score_stats(m, w)
        -- Trait preference: strongly reward a rare-trait animal so the
        -- planner grabs the bloodline while one is on the market.
        local pref = ah.trait_pref or "any"
        if pref ~= "off" and m.trait and m.trait ~= "0" then
          if pref == "any" or pref == m.trait then sc = sc + AH_TRAIT_BONUS end
        end
        if (not min_score or sc >= min_score) and (not best or sc > best_score) then
          best, best_score = m, sc
        end
      end
    end
  end)
  return best, best_score
end

-- LEGACY:192 (buy_cmd), format string at LEGACY:195. THE ONLY command form
-- this module ever builds, anywhere: `vlivestock buy <lineage_token> <id>`.
-- The wire id is 1-BASED while the record's `idx` is the server's 0-based
-- pool index, hence the +1. An unknown lineage id returns nil and every
-- caller treats nil as "no action" -- a half-built command is never sent.
--
-- `vlivestock slaughter` is NEVER built here or anywhere else in this file.
-- The server has it (vlivestock.c's do_slaughter), LEGACY never called it,
-- and it destroys livestock irreversibly, so it is outside the authority the
-- master toggle grants.
local function buy_cmd(m)
  local tok = LIN_TOKENS[num(m.lin)]
  if not tok then return nil end
  return string.format("vlivestock buy %s %d", tok, num(m.idx) + 1)
end

-- LEGACY:202-359 (ah_plan). Returns ONE action or nil, plus a reason string:
--   action = { kind = "buy"|"warn", cmd = string|nil, why = string }
-- Exported (rather than local, as in LEGACY) specifically so the tests can
-- drive the planner without a timer and without a mud connection.
--
-- ACCESS CHECKS, all of which sit BEFORE any command is built:
--   1. owned + enabled  -- the `owned` list below; nothing past it can even
--      name a building the player does not own, or one the user disabled.
--   2. budget           -- `budget = S.daler - reserve`, and each of the
--      three buy branches is gated on `budget > 0`; best_listing() then only
--      ever returns a listing whose WHOLE LOT (lot_cost: price x count, the
--      figure the server's own precondition uses) is <= budget.
--   3. herd space       -- `head + pending_head(b) < cap_for(b, tier)`.
--   4. pending delivery -- pending_head(b) is added to head in all three
--      branches, so a delivery already on the road blocks a re-buy.
-- buy_cmd() is called only after all four have passed, inside the branch.
--
-- The feed guard (branch 1) builds no command at all: LEGACY:251 is explicit
-- that it is "Not a vlivestock action; fall through to other planning this
-- tick", so it records `ah.status` and falls through, and the "warn" action
-- materialises in the tail below only when no branch produced a buy. That
-- ordering is LEGACY's, and it is why turning Auto-Herd on still stocks an
-- empty building for a player with no grain in the warehouse instead of
-- warning forever and never acting.
function M.plan()
  local ah = M.settings()
  ah.status = ""   -- recomputed fresh each cycle; the feed guard may set it
  local w = GOAL_W[ah.goal] or GOAL_W.balanced
  local budget = num(S.daler) - num(ah.reserve)

  -- Access check 1: owned livestock buildings that are also enabled.
  local owned = {}
  for _, b in ipairs(LIVE_BLDGS) do
    local bc = ah.buildings and ah.buildings[b]
    if owns(b) and bc and bc.enabled ~= false then
      owned[#owned + 1] = b
    end
  end
  if #owned == 0 then
    return nil, "no husbandry buildings owned (or all disabled)"
  end

  -- --- 1. Feed guard: never let herds starve. LEGACY:219. ----------------
  -- Emits NOTHING (LEGACY:251). LEGACY additionally pushed the shortfall
  -- onto the auto-TRADER's buy queue when that module was loaded
  -- (LEGACY:238-248); that is deliberately NOT ported. It is a write into
  -- another automation's settings that would make a DIFFERENT module spend
  -- daler on grain, which is outside the authority Auto-Herd's own master
  -- toggle grants, and no test in this plan would have caught it. The
  -- status text therefore always takes LEGACY's own un-queued branch
  -- (" - stock grain!").
  if ah.feed_guard then
    local head = 0
    local f = S.lfeed
    if f and num(f.head) > 0 then
      head = num(f.head)
    else
      for _, b in ipairs(owned) do
        local h = S.herds and S.herds[b]
        if h then head = head + num(h.head) end
      end
    end
    if head > 0 then
      local per_tick = M.feed_draw(head)
      local need = per_tick * math.max(1, num(ah.feed_ticks))
      local grain = warehouse_amount("grain")   -- STOCK, not S.lfeed.grain
      if grain < need then
        ah.status = string.format(
          "feed low: %d grain, herds need %d/tick (%d buffer) - stock grain!",
          grain, per_tick, need)
        -- Not a vlivestock action; fall through to other planning this tick.
      end
    end
  end

  -- --- 2. Stock / restock: seed EMPTY buildings, refill below target. ----
  -- LEGACY:256. This is what makes "turn it on" actually acquire animals:
  -- branches 3 and 4 only ever touch a herd that already exists.
  if ah.restock and budget > 0 then
    for _, b in ipairs(owned) do
      local tier = bldg_tier(b)
      local cap  = cap_for(b, tier)
      local herd = S.herds and S.herds[b]
      -- Access checks 3 + 4: herd space, counting deliveries in transit.
      local head = (herd and num(herd.head) or 0) + pending_head(b)
      local bc   = (ah.buildings and ah.buildings[b]) or {}
      -- Desired floor: an explicit per-building target, else a small
      -- breeding base (`keep`, capped by the building). Server-side breeding
      -- grows the herd the rest of the way.
      local target  = (num(bc.target) > 0) and num(bc.target) or nil
      local desired = target or math.min(cap, math.max(1, num(ah.keep)))
      if head < desired and head < cap then
        local species = BLDG_SPECIES[b]
        local m = best_listing(ah, species, budget, nil, nil)
        if m then
          local cmd = buy_cmd(m)
          if cmd then
            return { kind = "buy", cmd = cmd,
              why = string.format("stock %s: buy %s x%d into %s (%d/%d) for %dd",
                species, (m.breed ~= "" and m.breed) or "?", num(m.count), b,
                head, desired, lot_cost(m)) }, nil
          end
        else
          ah.status = string.format(
            "want to stock %s but no affordable %s for sale - run 'vlivestock market'",
            b, species)
        end
      end
    end
  end

  -- --- 3. Crossbreed refresh: fresh blood for inbred/sterile/old herds. --
  -- LEGACY:289.
  if ah.crossbreed and budget > 0 then
    for _, b in ipairs(owned) do
      local herd = S.herds and S.herds[b]
      local cap  = cap_for(b, bldg_tier(b))
      -- Access checks 3 + 4.
      if herd and num(herd.head) > 0 and (num(herd.head) + pending_head(b)) < cap then
        local thresh = (num(ah.gen_refresh) > 0) and num(ah.gen_refresh)
                        or inbreed_threshold(herd)
        local age_thresh = (num(ah.age_refresh) > 0) and num(ah.age_refresh) or nil
        -- FIELD-NAME CORRECTION to LEGACY, and the one that matters:
        -- LEGACY:298 reads `herd.generation`, the name ITS OWN MIP parser
        -- used. handlers/livestock.lua's write_herds stores the field as
        -- `gen`, which is the key the server's _v_herds() builder emits
        -- (client.h). Porting LEGACY's line literally would read nil here,
        -- fall back to 0, and `0 >= thresh` is false for every positive
        -- threshold -- so crossbreed would silently never fire on
        -- generation, only on sterility and age, and half this branch would
        -- be dead while the module still looked alive. Verified against
        -- handlers/livestock.lua's write_herds field list: age_ticks, breed,
        -- con, head and sterile match LEGACY exactly; `generation` -> `gen`
        -- is the only rename.
        local needs_blood = num(herd.gen) >= thresh
          or num(herd.sterile) > 0
          or (age_thresh and num(herd.age_ticks) >= age_thresh)
        if needs_blood then
          local species = BLDG_SPECIES[b]
          local m = best_listing(ah, species, budget, herd.breed, nil)
          if m then
            local cmd = buy_cmd(m)
            if cmd then
              local age_note = (age_thresh and num(herd.age_ticks) >= age_thresh)
                and string.format(", age %d", num(herd.age_ticks)) or ""
              return { kind = "buy", cmd = cmd,
                why = string.format("crossbreed %s: +%s into %s (gen %d, %d sterile%s) for %dd",
                  species, (m.breed ~= "" and m.breed) or "?", b, num(herd.gen),
                  num(herd.sterile), age_note, lot_cost(m)) }, nil
            end
          end
        end
      end
    end
  end

  -- --- 4. Quality buy-in: pull a herd's weighted average up. LEGACY:320. -
  if ah.buy_quality and budget > 0 then
    for _, b in ipairs(owned) do
      local herd = S.herds and S.herds[b]
      local cap  = cap_for(b, bldg_tier(b))
      -- Access checks 3 + 4. (LEGACY does not require head > 0 in this
      -- branch, unlike branch 3 -- ported as written.)
      if herd and (num(herd.head) + pending_head(b)) < cap then
        local species = BLDG_SPECIES[b]
        -- Only buy if a listing beats the herd's weighted average by the
        -- configured margin -- best_listing's min_score does the rejecting.
        local floor = score_stats(herd, w) + num(ah.quality_margin)
        local m = best_listing(ah, species, budget, nil, floor)
        if m then
          local cmd = buy_cmd(m)
          if cmd then
            return { kind = "buy", cmd = cmd,
              why = string.format("quality buy %s %s into %s for %dd",
                species, (m.breed ~= "" and m.breed) or "?", b, lot_cost(m)) }, nil
          end
        end
      end
    end
  end

  -- LEGACY:355 (`if ah.status ~= "" then return nil, ah.status end`). The
  -- one shape change the task brief requires of the port: a recorded
  -- shortfall/blocked-stock status now surfaces as an explicit
  -- { kind = "warn", cmd = nil } action so callers can distinguish "nothing
  -- to do" from "you should know about this", instead of LEGACY's bare
  -- `nil, status`. It still carries NO command.
  if ah.status ~= "" then
    return { kind = "warn", cmd = nil, why = ah.status }, ah.status
  end

  -- If we own a livestock building but have neither herd nor market data,
  -- there is simply nothing to plan against yet. LEGACY's own trailing hint
  -- read "enable: vtoggle mip_livestock"; REWORDED here, not ported
  -- byte-for-byte -- see the header's Adaptations note. Guild.Livestock is a
  -- GMCP package, so there is no toggle for a user to enable and no
  -- `vtoggle` command in this client at all; telling them to run one would
  -- send them chasing a command that does not exist. pages/livestock.lua
  -- dropped the same half of the same hint in Task 2 for the same reason.
  local any_data = false
  each_listing(function() any_data = true end)
  if not any_data then
    for _, b in ipairs(owned) do
      local h = S.herds and S.herds[b]
      if h and num(h.head) > 0 then any_data = true break end
    end
  end
  if not any_data then
    return nil, "no livestock data yet - buy stock via 'vlivestock market'"
  end
  return nil, "herds steady - nothing to do"
end

-- LEGACY:366 (ah_sm). Paced executor state: each vlivestock action is a
-- single atomic command, so M.tick sends one and then waits for the feed to
-- confirm that herds/market/daler actually changed before planning again --
-- which is what stops it double-buying a stale listing.
local ah_sm = { phase = "idle", next_at = 0, deadline = 0, sig = "" }

-- LEGACY:368 (ah_state_sig). Three field adaptations: `h.generation` ->
-- `h.gen` (see the crossbreed note above), `state.butchery_queue` ->
-- `S.bqueue` (handlers/livestock.lua's write_bqueue), and LEGACY's
-- `#state.livestock_market` -> a count through each_listing, since S.lmarket
-- is a lineage-keyed table whose `#` is 0.
local function ah_state_sig()
  local parts = {}
  parts[#parts + 1] = "d" .. tostring(num(S.daler))
  for _, b in ipairs(LIVE_BLDGS) do
    local h = S.herds and S.herds[b]
    if h then
      parts[#parts + 1] = b .. ":" .. num(h.head) .. "/" .. num(h.gen)
                            .. "/" .. num(h.sterile)
    end
  end
  local q = 0
  for _ in pairs(S.bqueue or {}) do q = q + 1 end
  parts[#parts + 1] = "q" .. q
  local mcount = 0
  each_listing(function() mcount = mcount + 1 end)
  parts[#parts + 1] = "m" .. mcount
  return table.concat(parts, ",")
end

-- LEGACY:386-436 (auto_herd_tick; closing `end` at 436). Called from
-- notify.lua's countdown_tick tail, LAST of the auto-modules -- LEGACY's own
-- order at guild_viking.lua:3232-3240 is trade, raid, voyage, vfind, herd
-- (this plugin has no auto-vfind, so herd simply follows voyage).
--
-- THE MASTER-TOGGLE GATE. LEGACY:387 is a bare `page_opts.auto_herd` read.
-- In this codebase page_opts keeps its values in a private closure, so
-- `page_opts.auto_herd` is permanently nil (falsy) while
-- page_opts.get("auto_herd") returns the real boolean -- copying LEGACY's
-- line literally would make M.tick() return early forever and Auto-Herd
-- would never run even when the user enabled it. The gate below is
-- page_opts.get("auto_herd"), the same translation Task 3 applied in
-- M.config and menu_pick, and the tick-gate cases at the bottom of
-- tests/guild_viking_autoherd_test.lua assert BOTH states (off: many ticks
-- send nothing; on: the same state sends exactly one buy) precisely because
-- a dead gate would otherwise ship green.
function M.tick()
  if not page_opts.get("auto_herd") then
    ah_sm.phase = "idle"
    return
  end
  if not mud.connected() then
    local ah = M.settings(); ah.status = "not connected"
    return
  end
  local now = os.time()

  -- Reconnect settling hold, the same gate autotrader/plan.lua:287 applies to
  -- cart dispatch. init.lua's M.on_connect sets S.at_hold_until on every
  -- connect, and state.reset_connection() deliberately PRESERVES guild data,
  -- so S.herds, S.lmarket, S.buildings and S.daler all survive a disconnect
  -- and the data gate below is satisfied instantly by stale city data. Without
  -- this the first tick after reconnect plans against last session's market
  -- pool and buys at an index the server has since rebuilt -- a different
  -- species, stats and price than the listing it scored -- and on confirm can
  -- chain further buys every 2s while Guild.Livestock's slow cadence has
  -- refreshed nothing.
  if S.at_hold_until and now < S.at_hold_until then
    local ah = M.settings()
    ah.status = string.format("settling after reconnect (%ds)",
      S.at_hold_until - now)
    return
  end

  -- Data gate: do nothing until the city feed has arrived, since every
  -- access check below depends on S.buildings.
  if not S.buildings or not next(S.buildings) then
    -- LEGACY:399 said "(vtoggle mip_city)"; reworded for the same reason as
    -- the livestock hint above -- Guild.City is GMCP-only here.
    local ah = M.settings(); ah.status = "waiting for city data"
    return
  end

  if ah_sm.phase == "confirming" then
    if ah_state_sig() ~= ah_sm.sig then
      ah_sm.phase, ah_sm.next_at = "idle", now + 2
    elseif now >= ah_sm.deadline then
      ah_sm.phase, ah_sm.next_at = "cooldown", now + AH_COOLDOWN
      note("FF0000", "[Auto-Herd] no confirmation for last action; pausing briefly")
    end
    return
  end
  if ah_sm.phase == "cooldown" then
    if now < ah_sm.next_at then return end
    ah_sm.phase = "idle"
  end
  if now < ah_sm.next_at then return end

  local ah = M.settings()
  ah.last = now
  local action, status = M.plan()
  -- `action.kind == "buy" and action.cmd` is belt-and-braces: M.plan only
  -- ever returns kind "buy" with a non-nil cmd (buy_cmd's nil result is
  -- filtered inside every branch). Checked anyway -- this is the one line in
  -- the module that spends money.
  if action and action.kind == "buy" and action.cmd then
    ah.status = nil                 -- LEGACY:422, overwritten two lines down
    ah_sm.sig = ah_state_sig()
    mud.send(action.cmd)
    log_action(ah, action.why)
    ah.status = "last: " .. action.why
    note("FFA500", "[Auto-Herd] " .. action.why)
    if ah.debug then note("808080", "[Auto-Herd] cmd: " .. action.cmd) end
    ah_sm.phase, ah_sm.deadline = "confirming", now + AH_CONFIRM_TIMEOUT
    save()   -- persist the log/status only when we actually acted
  else
    -- A "warn" action sends NOTHING; it only notes. Everything else is an
    -- ordinary idle tick.
    if action and action.kind == "warn" then
      note("FF0000", "[Auto-Herd] " .. tostring(action.why or ""))
    end
    ah.status = status or "idle"
    if ah.debug then note("808080", "[Auto-Herd] idle tick -- " .. tostring(status)) end
    ah_sm.next_at = now + AH_INTERVAL
  end
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

-- /vik herd [<sub>] dispatch (init.lua). Bare (rest == "") opens the
-- settings menu; anything else goes through M.config. Same two-line shape as
-- autoraid.lua's own M.raid_command -- LEGACY reached these through its
-- `aherd` alias (guild_viking_husbandry.lua's AddAlias tail), which has no
-- equivalent here.
function M.herd_command(rest)
  rest = rest or ""
  if rest == "" then
    M.open_menu()
    return
  end
  M.config(rest)
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
