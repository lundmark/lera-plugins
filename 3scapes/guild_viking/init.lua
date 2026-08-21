-- Guild Viking plugin: stage 1 foundation (protocol, state, notifications,
-- persistence, /vik). Window pages arrive in stage 2 and read this state.
local state_mod = require("state")
local protocol = require("protocol")
local command = require("command")

local trade = require("handlers.trade")
for key, fn in pairs(trade) do
  if key ~= "_market_seam" then protocol.handler(key, fn) end
end

-- Task 7: price history / demand metrics. LEGACY's MARKET branch never
-- calls record_price_history (only TGOODS does -- see market.lua's header
-- comment), so on_market is intentionally left unset.
local market = require("market")
trade._market_seam.on_tgoods = market.on_tgoods

local voyage = require("handlers.voyage")
for key, fn in pairs(voyage) do
  if key ~= "_patterns" then protocol.handler(key, fn) end
end
for _, p in ipairs(voyage._patterns or {}) do
  protocol.pattern_handler(p.pattern, p.fn)
end

local kingdom = require("handlers.kingdom")
for key, fn in pairs(kingdom) do
  if key ~= "_patterns" then protocol.handler(key, fn) end
end
for _, p in ipairs(kingdom._patterns or {}) do
  protocol.pattern_handler(p.pattern, p.fn)
end

local city = require("handlers.city")
for key, fn in pairs(city) do
  if key ~= "_patterns" then protocol.handler(key, fn) end
end
for _, p in ipairs(city._patterns or {}) do
  protocol.pattern_handler(p.pattern, p.fn)
end

-- Stage 2: page options + the tab bar / page shell (window.lua). Required
-- after the handlers so the state they populate is available to the pages
-- window.lua registers, even though no page reads it until Task 3+.
local page_opts = require("page_opts")
local window = require("window")
local stats_page = require("pages.stats")

-- Stage 3: named-popup registry + /vik pop. No popup registers here yet
-- (map/sea/voyage/cityplan/war arrive in Tasks 3-6) -- see popups.lua's
-- header comment.
local popups = require("popups")

-- Task 8: combat composite + hp-bar triggers. FFF is a separate MIP composite
-- from BBE (not routed through protocol.lua's key/value dispatch), so it gets
-- its own mip.on registration. The callback is 3-arg (key, code, data); data
-- is the third argument, not the second -- binding the wrong one was a past
-- Critical here.
local combat = require("combat")

-- Task 9: push notifications + the per-second countdown timer. `pushn` is
-- looked up in on_setup (plugins load before on_setup runs, per CLAUDE.md's
-- Push API producer pattern) and handed to notify.set_push; it stays nil,
-- and every trigger fn is a safe no-op, if push_notify isn't loaded.
local notify = require("notify")

-- Task 10: cross-session persistence (price history + transport source).
local persist = require("persist")

local S = state_mod.S

local M = {}
M.name = "guild_viking"
M.version = "0.1"

function M.state()
  return state_mod.S
end

local mip_id, fff_id, gmcp_id, sweep_id, countdown_id
local combat_trigger_ids = {}
local notify_trigger_ids = {}
local vik_command_id, resetvikxp_id, kill_listener_id

-- LEGACY plugins/guild_viking.xml:175-186 (`resetvikxp` alias), also reached
-- via `/vik resetxp`. viking_window.update() is dropped -- stage 2 territory.
local function do_resetxp()
  S.vis_session = 0
  S.kap_session = 0
  S.soe_session = 0
  S.aud_session = 0
  S.xp_session_start = nil
  buffer.color_print(nil, "DAA520", "Viking XP session counter reset.")
  ui.dirty()
end

-- Hp-bar gagging (stage-1 ruling, landed here per Task 3): the 8 combat/
-- hp-bar triggers (combat.triggers) go into the main output buffer raw
-- unless gagged -- LEGACY never printed them there either (they only ever
-- fed its detached window), and now that the Stats page (pages/stats.lua)
-- shows the same data in the pane, gagging keeps lera's main output as quiet
-- as LEGACY's was. `page_opts.get("gag_status_lines")` is read fresh each
-- time this registers, so a later re-registration (below) picks up a
-- changed setting without a reconnect/reload.
local function combat_trigger_opts()
  if page_opts.get("gag_status_lines") then
    return { omit_from_output = true }
  end
  return nil
end

local function register_combat_triggers()
  local opts = combat_trigger_opts()
  for _, t in ipairs(combat.triggers) do
    combat_trigger_ids[#combat_trigger_ids + 1] = trigger.add(t.pattern, t.fn, opts)
  end
end

local function unregister_combat_triggers()
  for _, tid in ipairs(combat_trigger_ids) do
    trigger.remove(tid)
  end
  combat_trigger_ids = {}
end

-- `/vik set gag_status_lines on|off` needs the new setting to take effect
-- immediately rather than only on the next reconnect: simplest fix is to
-- tear the 8 triggers down and re-add them reading the option fresh. Called
-- once from on_load (via register_combat_triggers directly, since there's
-- nothing to tear down yet) and again from set_opt below whenever that one
-- option changes.
local function reregister_combat_triggers()
  unregister_combat_triggers()
  register_combat_triggers()
end

local function print_status()
  local st = protocol.stats()
  buffer.color_print(nil, "DAA520", string.format(
    "Viking: source=%s latch=%s ingested=%d suppressed=%d pending_batches=%d",
    st.source, tostring(st.latched), st.ingested, st.suppressed, st.batches_pending))

  local unknown = {}
  for k, n in pairs(st.unknown) do unknown[#unknown + 1] = { key = k, n = n } end
  table.sort(unknown, function(a, b) return a.n > b.n end)
  if #unknown > 0 then
    local parts = {}
    for i = 1, math.min(5, #unknown) do
      parts[#parts + 1] = unknown[i].key .. "=" .. unknown[i].n
    end
    buffer.color_print(nil, "DAA520", "  unknown: " .. table.concat(parts, " "))
  else
    buffer.color_print(nil, "DAA520", "  unknown: none")
  end

  local err_total, err_keys = 0, 0
  for _, n in pairs(st.errors) do
    err_total = err_total + n
    err_keys = err_keys + 1
  end
  buffer.color_print(nil, "DAA520", string.format(
    "  parser errors: %d (%d key%s)", err_total, err_keys, err_keys == 1 and "" or "s"))
end

-- `/vik opts`: list every page option with its current value.
local function print_opts()
  local lines = {}
  for _, o in ipairs(page_opts.all()) do
    lines[#lines + 1] = o.key .. " = " .. (o.value and "on" or "off")
  end
  buffer.color_print(nil, "DAA520", table.concat(lines, "\n"))
end

-- `/vik set <opt> on|off|toggle`: validated flip of one page option.
local function set_opt(rest)
  local opt, mode = rest:match("^(%S+)%s+(%S+)$")
  if not opt then
    buffer.color_print(nil, "DAA520", "Usage: /vik set <opt> on|off|toggle")
    return
  end
  local current = page_opts.get(opt)
  if current == nil then
    buffer.color_print(nil, "DAA520", "Viking: unknown page option '" .. opt .. "'")
    return
  end
  local new_val
  if mode == "on" then new_val = true
  elseif mode == "off" then new_val = false
  elseif mode == "toggle" then new_val = not current
  end
  if new_val == nil then
    buffer.color_print(nil, "DAA520", "Usage: /vik set <opt> on|off|toggle")
    return
  end
  page_opts.set(opt, new_val)
  if opt == "gag_status_lines" then
    reregister_combat_triggers()
  end
  buffer.color_print(nil, "DAA520", "Viking: " .. opt .. " = " .. (new_val and "on" or "off"))
end

-- The five named popups /vik toggles (map/sea/voyage/cityplan/war). "war"
-- also names a pane page (window.PAGES) -- the binding ruling (plan Task 1)
-- is that the bare key toggles the POPUP; `/vik page war` reaches the pane.
local POPUP_NAMES = { map = true, sea = true, voyage = true, cityplan = true, war = true }

-- Dispatches /vik's subcommands. `args` is everything after "/vik " (may be
-- ""); an unknown or empty subcommand prints usage. A bare arg matching one
-- of window.PAGES' keys (case-insensitively) switches the pane's current
-- page, same as clicking its tab -- EXCEPT "war", which the bare form routes
-- to its popup instead (see POPUP_NAMES above); `/vik page war` is the
-- explicit pane route for it.
function M.vik_command(args)
  args = args or ""
  local sub, rest = args:match("^%s*(%S*)%s*(.-)%s*$")
  sub = sub or ""
  local sub_lower = sub:lower()

  if sub == "status" then
    print_status()
  elseif sub == "trace" then
    local want
    if rest == "on" then want = true
    elseif rest == "off" then want = false end
    local now = protocol.trace(want)
    buffer.color_print(nil, "DAA520", "Viking protocol trace: " .. (now and "on" or "off"))
  elseif sub == "save" then
    persist.save()
    buffer.color_print(nil, "DAA520", "Viking guild data saved.")
  elseif sub == "source" then
    if rest == "mip" or rest == "gmcp" or rest == "auto" then
      protocol.source(rest)
      buffer.color_print(nil, "DAA520", "Viking transport source set to " .. rest .. ".")
    else
      buffer.color_print(nil, "DAA520", "Usage: /vik source mip|gmcp|auto")
    end
  elseif sub == "resetxp" then
    do_resetxp()
  elseif sub == "opts" then
    print_opts()
  elseif sub == "set" then
    set_opt(rest)
  elseif POPUP_NAMES[sub_lower] then
    popups.toggle(sub_lower)
  elseif sub_lower == "page" then
    local key = rest:lower()
    if key ~= "" and window.set_page(key) then
      buffer.color_print(nil, "DAA520", "Viking page: " .. key)
    else
      buffer.color_print(nil, "DAA520", "Usage: /vik page <page>")
    end
  elseif sub_lower == "pop" then
    local key = rest:lower()
    if key == "" then
      buffer.color_print(nil, "DAA520", "Usage: /vik pop <page>")
    else
      popups.open_page(key)
    end
  elseif sub ~= "" and window.set_page(sub_lower) then
    buffer.color_print(nil, "DAA520", "Viking page: " .. sub_lower)
  else
    buffer.color_print(nil, "DAA520",
      "Usage: /vik [status | trace | save | source mip|gmcp|auto | resetxp | "
      .. "map | sea | voyage | cityplan | war | page <page> | pop <page> | "
      .. "<page> | opts | set <opt> on|off|toggle]")
  end
end

function M.on_load()
  mip_id = mip.on("BBE", function(key, code, data) protocol.on_bbe(data) end)
  fff_id = mip.on("FFF", function(key, code, data) combat.on_composite(data) end)
  gmcp_id = gmcp.on("Viking", function(pkg, data) protocol.on_gmcp(pkg, data) end)
  -- protocol.sweep's grace period is measured in seconds (LEGACY parity, see
  -- protocol.lua's sweep comment); lera.time() is milliseconds, so it must be
  -- divided down here at the call site rather than changing sweep()'s contract.
  sweep_id = timer.every(100, function() protocol.sweep(lera.time() / 1000) end)

  -- Fix 1: persist.load() must run BEFORE the initial combat-trigger
  -- registration, not after. register_combat_triggers() reads
  -- page_opts.get("gag_status_lines") fresh at call time (see its comment
  -- above), so a persisted gag_status_lines=false has to already be applied
  -- by the time this first registration happens -- otherwise every session
  -- silently re-gags the 8 hp-bar triggers regardless of what the user last
  -- saved, and only a subsequent /vik set flip would notice. persist.load
  -- depends only on market/protocol/page_opts/window, all required above
  -- this point, so moving it earlier has no ordering hazard of its own.
  persist.load()

  register_combat_triggers()
  for _, t in ipairs(notify.triggers) do
    notify_trigger_ids[#notify_trigger_ids + 1] = trigger.add(t.pattern, t.fn)
  end
  countdown_id = timer.every(1000, function() notify.countdown_tick() end)

  local id, err = command.register({
    name = "/vik",
    usage = "/vik [status | trace | save | source mip|gmcp|auto | resetxp | "
      .. "map | sea | voyage | cityplan | war | page <page> | pop <page> | "
      .. "<page> | opts | set <opt> on|off|toggle]",
    summary = "Viking guild data, pane, and controls",
    description = "Ingestion status and counters (status), message tracing "
      .. "(trace), explicit save (save), transport selection (source), the "
      .. "saga-XP session reset (resetxp; the bare 'resetvikxp' alias does "
      .. "the same), toggling a named popup open or closed -- map, sea, "
      .. "voyage, cityplan, or war -- (map/sea/voyage/cityplan arrive in "
      .. "later stages; toggling one before then reports it unavailable), "
      .. "opening any pane page as a detached popup (pop <page>), "
      .. "switching the pane to a page by key -- stats, city, farm, "
      .. "builds, people, goods, bonds, ranks, court, army, war, or trade "
      .. "-- (page <page>; a bare <page> does the same, same as clicking "
      .. "its tab, EXCEPT 'war', whose bare form toggles the popup instead "
      .. "-- use 'page war' for the pane), listing every page option with "
      .. "its current value (opts), and flipping one page option (set).",
    accepts_args = true,
    handler = function(args) M.vik_command(args or "") end,
  })
  if id then
    vik_command_id = id
  else
    print("[vik] /vik registration failed: " .. tostring(err))
  end

  resetvikxp_id = alias.add("^resetvikxp$", function() do_resetxp() end)
end

function M.on_setup()
  local sw = plugin.get("stats_window")
  if sw and sw.register_guild then
    sw.register_guild("guild_viking")
  end

  local kt = plugin.get("kill_trigger")
  if kt and kt.on_monster_died then
    -- Ported from LEGACY guild_viking.lua:2676-2682
    -- (guild.events.on_monster_died): clear the combat display fields and
    -- re-poll the hp-bar prompt so the UI reflects "no longer fighting"
    -- immediately rather than waiting for the next server update.
    kill_listener_id = kt.on_monster_died(function(killer, victim)
      S.combat = false
      S.combat_rounds = 0
      S.estatus_pct = 0
      S.mob_name_full = "None"
      mud.send("!hp")
      ui.dirty()
    end)
  end

  local pushn = plugin.get("push_notify")
  if pushn then
    pushn.register_channel("viking", { priority = 0 })
    notify.set_push(pushn)
  end
end

function M.on_unload()
  persist.save()

  mip.off(mip_id)
  mip.off(fff_id)
  gmcp.remove(gmcp_id)
  timer.remove(sweep_id)
  timer.remove(countdown_id)
  unregister_combat_triggers()
  for _, tid in ipairs(notify_trigger_ids) do
    trigger.remove(tid)
  end
  notify_trigger_ids = {}

  if vik_command_id then
    command.unregister(vik_command_id)
    vik_command_id = nil
  end
  if resetvikxp_id then
    alias.remove(resetvikxp_id)
    resetvikxp_id = nil
  end

  if kill_listener_id then
    local kt = plugin.get("kill_trigger")
    if kt and kt.remove_kill_listener then
      kt.remove_kill_listener(kill_listener_id)
    end
    kill_listener_id = nil
  end
end

function M.on_connect() end

function M.on_disconnect()
  persist.save()
  state_mod.reset_connection()
end

-- ---------------------------------------------------------------------------
-- stats_window contract (CLAUDE.md "Plugins" section, stats_window.lua
-- ~374-400): has_data() gates whether render_guild_stats is called at all.
-- Stage 2: the SAME builder the Stats pane page uses (pages/stats.lua),
-- truncated to the widget's rect -- not a separate, narrower summary.
-- ---------------------------------------------------------------------------

function M.has_data()
  return protocol.stats().ingested > 0
end

local function rect_dims(rect)
  if type(rect.x) == "function" then
    return rect:x(), rect:y(), rect:w(), rect:h()
  end
  return rect.x, rect.y, rect.w, rect.h
end

function M.render_guild_stats(rect, opts)
  opts = opts or {}
  local x, y, w, h = rect_dims(rect)
  if w <= 0 or h <= 0 then return 0 end

  local lines = stats_page.lines(w)
  local n = math.min(#lines, h)
  for i = 1, n do
    ui.text_ansi(ui.rect(x, y + i - 1, w, 1), lines[i])
  end
  return n
end

-- ---------------------------------------------------------------------------
-- wm.assign renderer contract (CLAUDE.md "Pane Pointer Input" / "Pane
-- Scrolling"): a profile can `wm.assign("viking", plugin_table)` directly --
-- wm auto-discovers render/on_pointer/scroll/scroll_to_bottom/following_tail
-- on the assigned table, and every one of these just delegates to window.lua.
-- ---------------------------------------------------------------------------

function M.render(rect, opts)
  return window.render(rect, opts)
end

function M.on_pointer(event)
  return window.on_pointer(event)
end

function M.scroll(delta)
  return window.scroll(delta)
end

function M.scroll_to_bottom()
  return window.scroll_to_bottom()
end

function M.following_tail()
  return window.following_tail()
end

return M
