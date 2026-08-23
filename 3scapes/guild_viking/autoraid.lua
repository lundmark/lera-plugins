-- Auto-Raid: client-side longship raid dispatcher. Sends idle docked ships
-- (never held/voyage ships) to a chosen target, solo or as a convoy. Ported
-- verbatim from LEGACY guild_viking.lua:4137-4303 plus
-- MAIN:11386-11434/11544-11667 (the settings mini-window menu + its target
-- picker):
--   AR_INTERVAL                4141      -> M.AR_INTERVAL (test-visible)
--   ar_settings                4143-4148 -> M.settings
--   ar_merged_ships            4152-4197 -> M.merged_ships
--   ar_available_ships         4201-4207 -> M.available_ships
--   DOCK_FLEET / ar_max_ships  4211-4224 -> DOCK_FLEET (local) / M.max_ships
--   auto_raid_tick             4226-4266 -> M.tick        -- gate at 4227,
--                                              AR_INTERVAL at 4232, mx =
--                                              ar_max_ships() at 4237
--   ar_config + vk_araid_handler   4269-4297 -> M.config
--   araid_menu_build            11397-11408 -> menu_items (local)
--   viking_show_araid_menu       11410-11434 -> M.open_menu
--   ar_cycle_ships               11545-11551 -> cycle_ships (local)
--   viking_araid_menu_pick       11553-11575 -> menu_pick (local)
--   viking_show_araid_target_menu/viking_araid_target_pick
--                                11579-11667 -> M.open_target_menu / target_pick
--                                              (local) -- see the TARGET
--                                              PICKER adaptation note below
--
-- Reached via `/vik raid [<sub>]` (init.lua); notify.lua calls M.tick()
-- itself from countdown_tick's tail, SECOND (LEGACY guild_viking.lua:
-- 2885-2890's own trade/raid/voyage order), so init.lua only needs this
-- module for the command surface, same division of labour as
-- autotrader/tick.lua and autovoyage.lua.
--
-- OFF BY DEFAULT: page_opts.get("auto_raid") is false until a user opts in
-- (page_opts.lua's own default, LEGACY:254's `auto_raid=false` ported
-- unchanged in stage 2), and M.tick()'s very first line (mirroring
-- LEGACY:4227 exactly) is that gate -- nothing below it runs, and nothing is
-- ever sent, until it is flipped on. Every send in this module goes through
-- mud.send(), so the deadmans plugin's on_send governance applies for free
-- (see CLAUDE.md's Push/deadmans section) -- this module needs no
-- deadmans-specific code.
--
-- Adaptations (all mechanical except the target picker, which is disclosed
-- separately below):
--   * LEGACY's implicit global `state` -> `S` (require("state").S), same
--     idiom as every other module in this plugin.
--   * `page_opts.auto_raid` (LEGACY's bare table field) -> page_opts.get/set
--     -- the key already exists in page_opts.lua's defaults (LEGACY:254,
--     ported in stage 2), default false, so no page_opts.lua change is
--     needed here.
--   * IsConnected() -> mud.connected(); Send(cmd) -> mud.send(cmd);
--     os.time()/os.date() are unchanged (both are in the plugin sandbox's
--     safe os.* whitelist per CLAUDE.md's Plugin Sandbox section).
--   * ColourNote(name, "", text) -> a local note(hex, text) that calls
--     buffer.color_print(nil, hex, text). The two named colours LEGACY uses
--     here (orange/red) are mapped to their standard HTML/CSS hex
--     equivalents, the same values autovoyage.lua's header already used for
--     the identical named colours (not a new choice made here):
--     orange=FFA500, red=FF0000.
--   * OnPluginSaveState() -> a local save() helper that calls
--     require("persist").save() (see the comment on that helper, just above
--     M's declaration, for why the require is deferred rather than a
--     top-level `local persist = require("persist")` like tick.lua's and
--     autovoyage.lua's own -- this module is required from pages/city.lua,
--     which persist.lua's own require("window") chain would otherwise
--     circle back through at module-load time).
--   * M.config replaces ar_config + vk_araid_handler: LEGACY's alias
--     dispatch (`AddAlias("vk_araid", ...)`, LEGACY:4300-4302) has no
--     equivalent -- `/vik raid <sub>` (init.lua) calls M.config(rest)
--     directly, matching the plan brief's explicit command mapping (the
--     same fold tick.lua and autovoyage.lua already use for their own
--     config handlers). Every response STRING, including the literal word
--     "araid" in the usage line (LEGACY's own alias name, now stale under
--     /vik raid but kept byte-for-byte per the plan's verbatim-string
--     rule), is unchanged.
--   * `local string, table, math, tonumber, tostring, pairs, ipairs, type =
--     libs()` (LEGACY:4270, a MUSHclient sandbox-local-alias idiom) is
--     dropped; those are ordinary globals here -- same disposition
--     autotrader/tick.lua's header discloses for the identical idiom.
--   * M.open_menu/menu_pick replace viking_show_araid_menu/
--     viking_araid_menu_pick: LEGACY's bespoke WindowCreate/AddHotspot
--     popup (11410-11434) becomes a require("menu") menu (5 items, LEGACY's
--     own id/label/val order from araid_menu_build, 11397-11408); per-item
--     colours have no equivalent in menu.lua's plain-label rows and are
--     dropped (content fidelity, not pixel fidelity -- the same ruling
--     autotrader/tick.lua's and autovoyage.lua's own menu ports already
--     apply). Selecting "on"/"convoy"/"log"/"ships" performs the exact same
--     toggle/cycle LEGACY's pick handler did, saves, then reopens the menu
--     in place (LEGACY did the same at 11572); `viking_window.update()`
--     (11573/11665) is dropped, same disposition as every other
--     viking_window.* call cut from this port (stage 2's own ruling).
--     Bare `/vik raid` (no subcommand) opens this menu -- LEGACY's own
--     `araid` alias with no argument just printed the trailing status line
--     (the menu was reachable only from a right-click page-context item
--     with no alias equivalent, guild_viking.lua:11228-11233, item.action
--     == "araid_config"); lera has no such right-click page chrome (dropped
--     in stage 2/3), and the task brief assigns the bare form to the menu
--     explicitly, matching the exact disposition autotrader/tick.lua's and
--     autovoyage.lua's own headers disclose for their bare forms.
--
--   * TARGET PICKER (disclosed separately -- this is the one place this
--     module reshapes behavior, not just syntax): LEGACY's target picker is
--     a second bespoke mini-window (viking_show_araid_target_menu,
--     11579-11640) with two scrollable, mouse-wheel-driven columns
--     (Lineage Cities | Other Targets), each entry showing the target name
--     PLUS its two raid goods in per-good colours (11610-11622). Selecting
--     "Target" in the settings menu here instead opens a SECOND
--     require("menu") (M.open_target_menu) built from the same
--     S.raid_targets_lin/S.raid_targets_hist data (flat list, a "Lineage
--     Cities:"/"Other Targets:" header row per group -- the same "_hdr,
--     no-op" idiom autovoyage.lua's own mission-priority header already
--     uses). The per-target goods hint and its colours have no equivalent
--     in menu.lua's plain-label rows and are dropped -- names only. This
--     avoids growing a new hotspot/scroll surface for a picker that is a
--     read-only city-data browse, not a new automated-send interaction
--     (the plan's Interaction Fidelity bar governs NEW send-capable pointer
--     surfaces; this one is not that -- it only feeds the SAME M.config-
--     shaped target string ar_config's "target <name>" grammar already
--     accepts).
--
--     A genuine LEGACY quirk is ported verbatim here, not fixed: selecting
--     "Target" in viking_araid_menu_pick (11563-11567) `return true`s
--     immediately, BEFORE the OnPluginSaveState() + menu-reopen every other
--     item falls through to (11569-1574) -- and viking_araid_target_pick
--     itself (11651-11667) never calls OnPluginSaveState() either. So,
--     unlike every other item in this menu (and unlike the Auto-Trade/
--     Auto-Voyage menus' own pick handlers, both of which DO save on every
--     selection), picking a raid target does NOT persist immediately -- it
--     only takes effect for the current session unless a later action
--     (toggling on/off, cycling ships, etc.) saves it as a side effect.
--     Reproduced here: menu_pick("target") calls M.open_target_menu() and
--     returns without persist.save() or reopening the settings menu (LEGACY
--     leaves its settings WindowCreate window visible underneath, since it
--     was never closed -- our require("menu") settings menu WAS already
--     torn down when "Target" was selected, so target_pick reopens it
--     afterward, matching LEGACY's own 11663-11664 reopen, but likewise
--     without a save call). An empty target list (LEGACY:11582-11584)
--     prints the exact same message and reopens the settings menu instead
--     of opening a broken empty picker (require("menu")'s own open()
--     refuses an empty items list).
local S = require("state").S
local page_opts = require("page_opts")

local M = {}

-- persist.lua requires("window"), and window.lua requires("pages.city"),
-- which requires this module (for M.max_ships(), the real ar_max_ships()
-- port used by the City page's Raids section) -- so a top-level
-- require("persist") here would be circular at MODULE-LOAD time (persist
-- loading window loading pages.city loading this file loading persist,
-- before persist has returned anything to cache). Deferred into a local
-- helper, called only from M.config/menu_pick at COMMAND-DISPATCH time
-- (long after every module has finished loading) -- the same
-- lazy-require idiom popups.lua already uses for require("wm").
local function save()
  require("persist").save()
end

-- LEGACY:4141.
local AR_INTERVAL = 20   -- seconds between auto-raid checks
M.AR_INTERVAL = AR_INTERVAL

local function note(hex, text)
  buffer.color_print(nil, hex, text)
end

-- LEGACY:4143-4148 (ar_settings).
function M.settings()
  if not S.autoraid then
    S.autoraid = { convoy = false, ships = 2, target = "", last = 0, last_dispatch = nil }
  end
  return S.autoraid
end

-- LEGACY:4150-4197 (ar_merged_ships). Build merged ship list from both data
-- sources (like the Sea page does). voyage_longships has ship_id and
-- detailed state; ships has convoy info AND the `held` flag -- note that a
-- ship present in BOTH feeds keeps whatever `.held` its voyage_longships
-- record had (always nil/false: the LONGSHIP wire packet has no held
-- field, see handlers/voyage.lua's M.LONGSHIP) because this merge, exactly
-- like LEGACY's own, never copies `sh.held` onto an already-found `vsh`.
-- Only a ship absent from voyage_longships (found solely via S.ships) keeps
-- its own `.held` intact. Ported as-is: not this module's place to "fix" a
-- LEGACY merge that happens to drop a field.
function M.merged_ships()
  local merged = {}
  local seen = {}
  if S.voyage_longships then
    for _, sh in ipairs(S.voyage_longships) do
      local sid = sh.ship_id or ("name:" .. (sh.name or "unknown"))
      merged[sid] = sh
      seen[sid] = true
    end
  end
  if S.ships then
    for _, sh in ipairs(S.ships) do
      local name = sh.name or "unknown"
      local found = false
      for sid, vsh in pairs(merged) do
        if vsh.name == name then
          found = true
          if sh.convoy and sh.convoy ~= 0 and (not vsh.convoy or vsh.convoy == 0) then
            vsh.convoy = sh.convoy
            vsh.convoy_size = sh.convoy_size
            vsh.convoy_bonus = sh.convoy_bonus
          end
          vsh.durability = sh.durability
          if sh.state and sh.state ~= "" then
            vsh.state = sh.state
          end
          if sh.return_in then
            vsh.return_in = sh.return_in
          end
          break
        end
      end
      if not found then
        local sid = "name:" .. name
        merged[sid] = sh
        seen[sid] = true
      end
    end
  end
  local arr = {}
  for _, sh in pairs(merged) do arr[#arr + 1] = sh end
  return arr
end

-- LEGACY:4199-4207 (ar_available_ships). Docked, un-held ships available to
-- raid (held ships are the reserved/voyage ships the player keeps back).
function M.available_ships()
  local avail = {}
  for _, sh in ipairs(M.merged_ships()) do
    if sh.state == "docked" and not sh.held then avail[#avail + 1] = sh end
  end
  return avail
end

-- LEGACY:4209-4211 (DOCK_FLEET). Most ships you could send: the Dock fleet
-- cap (tier 1-5 = 2/4/6/8/10).
local DOCK_FLEET = { [1] = 2, [2] = 4, [3] = 6, [4] = 8, [5] = 10 }

-- LEGACY:4212-4224 (ar_max_ships). Further capped by how many ships you
-- actually own that aren't held.
function M.max_ships()
  local dt = (S.buildings and S.buildings.dock) or 1
  local cap = DOCK_FLEET[dt] or (dt >= 5 and 10) or 2
  local owned, held = 0, 0
  for _, sh in ipairs(M.merged_ships()) do
    owned = owned + 1
    if sh.held then held = held + 1 end
  end
  local nonheld = owned - held
  -- `nonheld < cap`, strictly: at nonheld == cap the clamp is a no-op
  -- either way (cap = nonheld = cap), so `<` vs `<=` here is
  -- observationally identical for every input -- not a meaningful
  -- mutation target (see the task report's mutant table). Ported exactly
  -- as LEGACY:4221 wrote it regardless.
  if nonheld >= 1 and nonheld < cap then cap = nonheld end
  -- `cap < 1` is unreachable: DOCK_FLEET's minimum entry is 2 and the
  -- clamp above only ever sets cap to nonheld when nonheld >= 1, so cap
  -- can never go below 1 through either path. Ported verbatim regardless
  -- (LEGACY:4222), same disposition as the tick's own redundant guards.
  if cap < 1 then cap = 1 end
  return cap
end

-- LEGACY:4226-4266 (auto_raid_tick). See the module header and task report
-- for the enumerated gates. Every branch ends in an early `return` (or
-- falls out the bottom having sent everything for this tick), so at most
-- one raid-dispatch action happens per M.tick() call.
--
-- REDUNDANT GUARDS, disclosed (found via mutation testing, not assumed):
-- `#avail == 0` just below and `target_n < 1` further down are each
-- independently reachable and DO fire in the normal (unmutated) flow -- but
-- deleting either one, alone, produces no observable difference: with
-- avail == 0 (or target_n < 1, which forces `ar.convoy and target_n >= 2` to
-- fail and land in the solo branch below), `n = math.min(#avail, target_n)`
-- always computes to <= 0, and the solo branch's OWN `n < 1` check (or the
-- convoy branch's `n < 2`) catches the identical case a few lines later. So
-- no test can prove "removing this gate alone produces a send" for these
-- two -- there is provably no fixture where it could, unlike every other
-- gate here. Ported verbatim regardless: LEGACY wrote both checks, and it is
-- not this module's place to remove either one just because a later line
-- happens to duplicate its effect (the same principle autotrader/tick.lua's
-- header applies to its own `not cmd` defensive guard, LEGACY:836).
function M.tick()
  if not page_opts.get("auto_raid") then return end
  if not mud.connected() then return end
  local ar = M.settings()
  if not ar.target or ar.target == "" then return end
  local now = os.time()
  if ar.last and (now - ar.last) < AR_INTERVAL then return end
  ar.last = now

  local avail = M.available_ships()
  if #avail == 0 then return end   -- redundant with the n<1/n<2 checks below; see note above
  local mx = M.max_ships()
  local want = ar.ships or 2
  -- The number the player wants per dispatch, clamped to the dock/fleet cap.
  local target_n = (want == "all") and mx or math.min(tonumber(want) or 2, mx)
  if target_n < 1 then return end   -- also redundant with the n<1/n<2 checks below
  local tgt = ar.target
  local n, convoy

  if ar.convoy and target_n >= 2 then
    -- Convoy: a convoy sails together, so wait until the full set is docked.
    -- ("all" has no fixed size, so just take whatever is available now.)
    if want ~= "all" and #avail < target_n then return end  -- not enough yet; wait
    n = math.min(#avail, target_n)
    if n < 2 then return end               -- a convoy needs at least 2
    convoy = true
    mud.send(string.format("vlongship convoy %d %s", n, tgt))
  else
    -- Solo: send whatever is available now, up to the target count. Ships
    -- that are still out get sent on a later tick when they return. This
    -- `n < 1` check is the backstop that makes the two guards above
    -- redundant (see the note on M.tick's own header) -- it is otherwise
    -- unreachable on its own, since avail >= 1 and target_n >= 1 (both
    -- already enforced above) make n = math.min(avail, target_n) >= 1
    -- unconditionally.
    n = math.min(#avail, target_n)
    if n < 1 then return end
    convoy = false
    for i = 1, n do
      mud.send(string.format("vlongship raid %s %s", avail[i].name, tgt))
    end
  end
  ar.last_dispatch = { t = os.date("%H:%M"), target = tgt, n = n, convoy = convoy }
  note("FFA500", string.format("[Auto-Raid] sent %d ship%s to %s%s",
    n, n == 1 and "" or "s", tgt, convoy and " (convoy)" or ""))
end

-- ---------------------------------------------------------------------------
-- Control surface: /vik raid <sub> (LEGACY:4269-4297, ar_config +
-- vk_araid_handler) and the settings menu + target picker (LEGACY
-- guild_viking.lua:11386-11434, 11544-11667). See module header for all
-- three adaptations.
-- ---------------------------------------------------------------------------

-- LEGACY:4269-4293 (ar_config).
function M.config(rest)
  local ar = M.settings()
  rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local low = rest:lower()
  if low == "on" then
    page_opts.set("auto_raid", true); note("FFA500", "[Auto-Raid] ON.")
  elseif low == "off" then
    page_opts.set("auto_raid", false); note("FFA500", "[Auto-Raid] OFF.")
  elseif low == "convoy on" then
    ar.convoy = true; note("FFA500", "[Auto-Raid] convoy ON.")
  elseif low == "convoy off" then
    ar.convoy = false; note("FFA500", "[Auto-Raid] convoy OFF.")
  elseif low == "all" then
    ar.ships = "all"; note("FFA500", "[Auto-Raid] ships = all.")
  else
    local key, val = low:match("^(%a+)%s+(%d+)$")
    if key == "ships" then
      ar.ships = tonumber(val)
    elseif rest:match("^target%s+") then
      ar.target = rest:gsub("^%S+%s+", ""); note("FFA500", "[Auto-Raid] target = " .. ar.target)
    elseif rest ~= "" and low ~= "status" then
      note("FF0000", "[Auto-Raid] usage: araid on|off | convoy on|off | ships <n>|all | target <name>")
      return
    end
  end
  save()   -- persist auto_raid on/off + settings immediately
  note("FFA500", string.format("[Auto-Raid] %s | ships %s | convoy %s | target %s",
    page_opts.get("auto_raid") and "ON" or "OFF", tostring(ar.ships or 2),
    ar.convoy and "yes" or "no", (ar.target ~= "" and ar.target) or "(none)"))
end

-- LEGACY:11397-11408 (araid_menu_build). Item order, labels and values are
-- verbatim; per-item colours dropped (see module header).
local function menu_items()
  local ar = M.settings()
  local on = page_opts.get("auto_raid")
  return {
    { label = "Auto-Raid: " .. (on and "ON" or "off"), value = "on" },
    { label = "Convoy: " .. (ar.convoy and "yes" or "no"), value = "convoy" },
    { label = "Ships to send (max " .. M.max_ships() .. "): "
        .. ((ar.ships == "all") and "all" or tostring(math.min(tonumber(ar.ships) or 2, M.max_ships()))),
      value = "ships" },
    { label = "Target: " .. ((ar.target ~= "" and ar.target) or "(pick)"), value = "target" },
    { label = "Show raid log: " .. (page_opts.get("show_city_raidlog") and "yes" or "no"), value = "log" },
  }
end

-- LEGACY:11544-11551 (ar_cycle_ships). Cycle 1, 2, ... up to the dock/fleet
-- cap, then "all", then back to 1.
local function cycle_ships(ar)
  local mx = M.max_ships()
  if ar.ships == "all" then ar.ships = 1; return end
  local cur = math.min(tonumber(ar.ships) or 1, mx)
  if cur >= mx then ar.ships = "all" else ar.ships = cur + 1 end
end

-- LEGACY:11579-11667. Flat require("menu") replacement for the two-column
-- WindowCreate target picker -- see module header's TARGET PICKER note.
local function target_menu_items()
  local lin = S.raid_targets_lin or {}
  local hist = S.raid_targets_hist or {}
  local items = {}
  if #lin > 0 then
    items[#items + 1] = { label = "Lineage Cities:", value = "_hdr" }
    for i, e in ipairs(lin) do
      items[#items + 1] = { label = "  " .. (e.name or "?"), value = "lin_" .. i }
    end
  end
  if #hist > 0 then
    items[#items + 1] = { label = "Other Targets:", value = "_hdr" }
    for i, e in ipairs(hist) do
      items[#items + 1] = { label = "  " .. (e.name or "?"), value = "hist_" .. i }
    end
  end
  return items
end

-- LEGACY:11651-11667 (viking_araid_target_pick). No persist.save() here --
-- see module header's TARGET PICKER quirk note.
local function target_pick(value)
  if value == "_hdr" then
    M.open_target_menu()   -- header row, no action; reopen the picker
    return
  end
  local grp, idx = value:match("^(%a+)_(%d+)$")
  idx = tonumber(idx)
  local e
  if grp == "lin" then e = (S.raid_targets_lin or {})[idx]
  elseif grp == "hist" then e = (S.raid_targets_hist or {})[idx] end
  if e and e.name then
    M.settings().target = e.name
    note("FFA500", "[Auto-Raid] target = " .. e.name)
  end
  M.open_menu()
end

-- LEGACY:11579-11585 (viking_show_araid_target_menu's empty-list guard).
function M.open_target_menu()
  local items = target_menu_items()
  if #items == 0 then
    note("FFA500", "[Auto-Raid] No target list yet - wait for a city update.")
    M.open_menu()
    return
  end
  require("menu").open({
    items = items,
    title = "Pick Raid Target",
    on_select = function(value) target_pick(value) end,
    on_cancel = function() M.open_menu() end,
  })
end

-- LEGACY:11553-11575 (viking_araid_menu_pick).
local function menu_pick(id)
  local ar = M.settings()
  if id == "on" then
    page_opts.set("auto_raid", not page_opts.get("auto_raid"))
  elseif id == "convoy" then
    ar.convoy = not ar.convoy
  elseif id == "log" then
    page_opts.set("show_city_raidlog", not page_opts.get("show_city_raidlog"))
  elseif id == "ships" then
    cycle_ships(ar)
  elseif id == "target" then
    -- Early return, same as LEGACY:11566-11567 -- no persist.save(), no
    -- settings-menu reopen here (see module header's quirk note).
    M.open_target_menu()
    return
  end
  save()
  -- Rebuild in place so the new value shows immediately -- LEGACY did the
  -- same (viking_show_araid_menu(mx, my), LEGACY:11572).
  M.open_menu()
end

-- LEGACY:11410-11434 (viking_show_araid_menu), opened by bare `/vik raid` --
-- see module header for the bare-form adaptation.
function M.open_menu()
  require("menu").open({
    items = menu_items(),
    title = "Auto-Raid Settings",
    on_select = function(value) menu_pick(value) end,
  })
end

-- /vik raid <sub> dispatch (init.lua). Bare (rest == "") opens the menu;
-- anything else goes through M.config.
function M.raid_command(rest)
  rest = rest or ""
  if rest == "" then
    M.open_menu()
    return
  end
  M.config(rest)
end

return M
