-- Army page: LEGACY's draw_page_army
-- (/home/simon/code/3s_scripts_old/lua/guild_viking.lua:13305-13351). Pure
-- builder: lines(width) -> array of ANSI strings, reading state.lua's S and
-- page_opts.lua only.
--
-- Section order/gates, read from the source top to bottom -- the ACTUAL
-- function body (not the task brief's landmark list -- see below):
--   A top-level "No army data" fallback (13308-13312, UNGATED) replaces the
--     ENTIRE page when state.army is nil (before mip_kingdom/varmy has ever
--     populated it).
--   Levy (show_army_levy, 13313-13315) -- one line: conscript count.
--   Units (show_army_units, 13316-13350) -- a "(used / cap)" header, then
--     one block per trained unit (type xN + ready/training status; "led by"
--     + a veterancy bar; an optional earned-traits line), or a
--     "(no units -- varmy train ...)" fallback when the list is empty.
--
-- DISCREPANCY vs. the task brief, disclosed up front: the brief's landmark
-- list said "army units/upkeep, patrol detail, garrison detail, varangians,
-- battle-damage summaries." Read `draw_page_army` in full (46 lines, not the
-- ~755 the plan's line-range estimate implied -- that range runs into the
-- battle-grid/hotspot menu machinery that sits between this function and
-- `draw_page_war`, none of which belongs to `draw_page_army` itself). None
-- of patrol/garrison/varangians/battle-damage is drawn here:
--   - Biome Patrol and Garrison (incl. Varangian Guards) are drawn by
--     `draw_page5` and already ported to `pages/people.lua` (Task 6).
--   - Battle-damage summaries (BDMG) are drawn by `draw_page4` and already
--     ported to `pages/builds.lua` (Task 5).
--   - "Upkeep" does not appear in `draw_page_army` at all; conscript/unit
--     upkeep costs are not part of this function's output.
-- Grepped both terms plus `bdmg`/`varang`/`patrol` across the whole LEGACY
-- file to confirm each lands in its already-ported home, not here -- same
-- discipline as Task 7's ranks-page discovery that "grudges, diplo" wasn't
-- in `draw_page9` either. This page therefore ports exactly the two
-- sections above -- a floor AND a ceiling, since the source has nothing
-- left over.
--
-- BGR color decoding (guild_viking.lua line 301, 0xBBGGRR): every literal
-- below decoded byte-by-byte before choosing a pagelib.C entry.
--   - ready status 0x40FF40 -> (R=40,G=FF,B=40) bright green -> C.bright_green;
--     LEGACY's own comment/usage calls this "ready", no discrepancy.
--   - training status 0x0088CC -> (R=CC,G=88,B=00) orange. pagelib.C has no
--     orange; unlike `pagelib.pct_color`'s own precedent of folding its
--     "orange" tier into red, here that would make "training" (a neutral,
--     in-progress state) read as an alarm alongside "wounded"-style reds
--     elsewhere in the pane. Mapped to C.yellow instead -- a deliberate,
--     disclosed departure from the red-for-orange precedent, chosen for
--     in-page distinctness (ready=green vs training=yellow) rather than
--     hex proximity.
--   - "led by" label 0x888888 -> mid grey -> C.dim.
--   - veterancy bar fill 0x4488CC -> (R=CC,G=88,B=44) orange-brown. LEGACY
--     draws it as a flat single-color fill; ported as a `pagelib.pct_color`
--     gradient instead (same precedent as builds.lua/people.lua's progress
--     bars) so the bar's color also carries the veterancy magnitude in text
--     mode, which a single flat color cannot.
--   - traits line 0x00CCCC -> (R=CC,G=CC,B=00) yellow -> C.yellow. LEGACY's
--     own comment above this line says "green honours / red scars are all
--     sent as-is," but the code draws the WHOLE traits line in this one
--     color -- no per-trait green/red split exists in the executed code.
--     Source-that-executes wins (same precedent as Task 8's `vrep_header`
--     dead-code finding): ported as a single yellow line, comment note
--     disclosed rather than invented.
--   - "No army data" / "(no units ...)" fallbacks, both 0x666666/0x888888
--     -> grey -> C.dim.
local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local cc = require("pages.city_common")

local S = state.S
local C = pagelib.C

local M = {}

-- ---------------------------------------------------------------------------
-- Units (guild_viking.lua:13316-13350, gated show_army_units)
-- ---------------------------------------------------------------------------

-- Fixed columns. Both rows previously concatenated variable-width values with
-- literal gaps, so nothing lined up between units: the status slid with the
-- unit type and its size digits, and -- the visible one -- the veterancy bar
-- slid with the length of each leader's name, so the bars never stacked.
local UNIT_TYPE_W   = 14
local UNIT_SIZE_W   = 6    -- "x1000"
local UNIT_LEADER_W = 16

-- Unit types arrive lower-cased and underscored off the wire ("shieldwall",
-- "shield_maidens"), which reads as a raw field rather than a name. Title-case
-- each word; cc.cap_first only touches the first letter of the whole string,
-- so a compound type would still come out "Shield_maidens".
local function unit_label(t)
  t = tostring(t or "?"):gsub("_", " ")
  return (t:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b:lower() end))
end

local function unit_lines(add, width, u)
  local ready = u.ready
  local status_text = ready and "ready" or "training"
  local status_color = ready and C.bright_green or C.yellow

  add(pagelib.trunc(
    pagelib.trunc(C.white .. unit_label(u.type) .. pagelib.RESET, UNIT_TYPE_W)
    .. string.format("%-" .. UNIT_SIZE_W .. "s", "x" .. tostring(u.size or 0))
    .. status_color .. status_text .. pagelib.RESET, width))

  add(pagelib.trunc(
    "  " .. C.dim .. "led by " .. pagelib.RESET
    .. pagelib.trunc(C.dim .. (u.leader or "-") .. pagelib.RESET, UNIT_LEADER_W)
    .. pagelib.bar(20, u.vet or 0, 100, pagelib.pct_color(u.vet or 0, 100))
    .. string.format(" %3d%%", u.vet or 0), width))

  if u.traits and #u.traits > 0 then
    add(pagelib.trunc("  " .. C.yellow .. table.concat(u.traits, "  ") .. pagelib.RESET, width))
  end
end

local function units_lines(add, width, a)
  add(pagelib.header(width, string.format("Units  (%d / %d)", a.used or 0, a.cap or 0)))
  local units = a.units or {}
  if #units > 0 then
    for _, u in ipairs(units) do
      unit_lines(add, width, u)
    end
  else
    add(pagelib.trunc(C.dim .. "(no units -- varmy train <type> <n> <leader>)" .. pagelib.RESET, width))
  end
end

-- ---------------------------------------------------------------------------

local GOOD_ORDER = { "timber", "iron", "tools" }

-- Siege park. Not in LEGACY's draw_page_army: the engine park only ever
-- appeared as a single "Siege engines: n/n" line on the War page, which
-- cannot distinguish a park that is empty from one with engines on order.
-- The server sends the full record (gmcp.h:321-340) and warns about exactly
-- that conflation, so it is rendered here beside the rest of the army --
-- engines are built from a city building (Siege Workshop) like any other
-- production line.
local function siege_lines(add, width, sg)
  if not sg then return end
  if (sg.cap or 0) <= 0 and (sg.ordered or 0) <= 0 and (sg.forging or 0) <= 0 then return end

  add(pagelib.header(width, string.format("Siege Engines  (%d / %d held)",
    sg.engines or 0, sg.cap or 0)))

  if (sg.forging or 0) > 0 then
    add(pagelib.trunc(string.format("  %sForging:%s %d / %d on the line",
      C.yellow, pagelib.RESET, sg.forging or 0, sg.queue_max or 0), width))

    -- One row per engine on the line, drawn the way builds.lua draws a
    -- building under construction: a label column, the ETA, and a progress
    -- bar underneath from elapsed = total - eta. Falls back to the count
    -- alone if the server sent no per-engine clocks.
    for _, e in ipairs(sg.queue or {}) do
      local eta   = e.eta or 0
      local total = e.total or sg.build_secs or 0
      add(pagelib.trunc(
        "    " .. pagelib.trunc(C.dim .. "Engine " .. tostring(e.slot or "?")
                                .. pagelib.RESET, 12)
        .. (eta <= 0 and (C.bright_green .. "Finalizing...")
                     or (C.white .. cc.fmt_time(eta))) .. pagelib.RESET, width))
      if total > 0 and eta > 0 then
        local elapsed = total - eta
        if elapsed < 0 then elapsed = 0 end
        local pct = math.floor(elapsed / total * 100 + 0.5)
        add(pagelib.trunc("    "
          .. pagelib.bar(width - 12, elapsed, total, C.bright_cyan)
          .. " " .. pct .. "%", width))
      end
    end
  end

  if (sg.ordered or 0) > 0 then
    add(pagelib.trunc(string.format("  %sOn order:%s %d / %d -- waiting on materials",
      C.yellow, pagelib.RESET, sg.ordered or 0, sg.order_max or 0), width))

    -- next_needs is the shortfall on the NEXT engine only; zero means that
    -- good is already covered, so only the gaps are worth showing.
    local short = {}
    for _, g in ipairs(GOOD_ORDER) do
      local n = (sg.next_needs or {})[g] or 0
      -- Same palette and labels as every other tab: this printed the raw
      -- wire id ("timber"), so the same good read three ways across the
      -- client -- plain here, white on the War page, coloured and
      -- title-cased on City/Goods/Trade.
      if n > 0 then
        short[#short + 1] = n .. " " .. cc.good_color(g) .. cc.good_label(g) .. pagelib.RESET
      end
    end
    if #short > 0 then
      add(pagelib.trunc("    " .. C.red .. "Next engine still needs: " .. pagelib.RESET
        .. table.concat(short, ", "), width))
    else
      add(pagelib.trunc("    " .. C.bright_green .. "Materials ready" .. pagelib.RESET
        .. C.dim .. " -- starts on the next tick" .. pagelib.RESET, width))
    end

    -- daler_each is taken when an engine STARTS and is deliberately not
    -- reserved (gmcp.h:335), so a coin-poor order simply waits: worth saying.
    if (sg.daler_each or 0) > 0 then
      add(pagelib.trunc("    " .. C.dim .. string.format(
        "%d daler each, taken when it starts (not reserved)", sg.daler_each) .. pagelib.RESET,
        width))
    end
  end

  if (sg.engines or 0) <= 0 and (sg.forging or 0) <= 0 and (sg.ordered or 0) <= 0 then
    add(pagelib.trunc(C.dim .. "  (park empty -- 'vsiege build')" .. pagelib.RESET, width))
  end
end

function M.lines(width)
  width = width or 80
  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  local a = S.army
  if not a then
    add(pagelib.trunc(C.dim .. "No army data yet -- run 'varmy' to populate it" .. pagelib.RESET,
      width))
    return lines
  end

  if page_opts.get("show_army_levy") then
    add(pagelib.header(width, string.format("Levy  --  %d conscripts", a.conscripts or 0)))
  end

  if page_opts.get("show_army_units") then
    units_lines(add, width, a)
  end

  if page_opts.get("show_army_siege") then
    siege_lines(add, width, S.siege)
  end

  return lines
end

return M
