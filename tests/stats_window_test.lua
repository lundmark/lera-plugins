package.path = "3scapes/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- ---- stubs -----------------------------------------------------------
local stored = nil
store = {
  load = function() end,
  get = function() return stored end,
  set = function(d) stored = d end,
  save = function() end,
}
local function make_rect(x, y, w, h)
  return {
    x = function() return x end, y = function() return y end,
    w = function() return w end, h = function() return h end,
  }
end
ui = {
  rect = function(x, y, w, h) return make_rect(x, y, w, h) end,
  text = function() end,
  text_ansi = function() end,
  box = function() end,
  shrink = function(r, n) return make_rect(r:x()+n, r:y()+n, r:w()-2*n, r:h()-2*n) end,
  dirty = function() end,
}
lera = { time = function() return 0 end }

-- plugin.get is the seam under test: serve controllable guild plugins
local live_plugins = {}
plugin = { get = function(name) return live_plugins[name] end }

-- stats_window registers a command and may add triggers/timers at load
local command_stub = { register = function() return 1 end, unregister = function() return true end }
local real_require = require
require = function(name)
  if name == "command" then return command_stub end
  return real_require(name)
end
trigger = { add = function() return 1 end, remove = function() end }
timer = { every = function() return 1 end, remove = function() end }
mip = { on = function() return 1 end, off = function() end }

local M = dofile("3scapes/stats_window.lua")
if M.on_load then M.on_load() end

-- a guild plugin double that records render calls
local function guild_double()
  local d = { calls = 0 }
  d.has_data = function() return true end
  d.render_guild_stats = function() d.calls = d.calls + 1; return 1 end
  return d
end

-- ---- cases -------------------------------------------------------------
check("register_guild validates", M.register_guild(nil) == false and M.register_guild("") == false)
check("register_guild accepts", M.register_guild("guild_viking") == true)
check("register_guild idempotent", M.register_guild("guild_viking") == true)

-- druid stays first in the probe: with both live, druid wins
local druid, viking = guild_double(), guild_double()
live_plugins.guild_druid = druid
live_plugins.guild_viking = viking
M.render(make_rect(0, 0, 40, 20), {})
check("druid probed first when both live", druid.calls > 0 and viking.calls == 0,
  druid.calls .. "/" .. viking.calls)

-- with only viking live, the probe finds it (fresh probe after registration)
live_plugins.guild_druid = nil
check("register resets cached probe", M.register_guild("guild_viking") == true)
local before = viking.calls
M.render(make_rect(0, 0, 40, 20), {})
check("viking probed when druid absent", viking.calls > before, viking.calls)

-- =============================================================================
-- Scrolling (the info pane could not scroll at all: no scroll export meant
-- wm.scrollable("stats") was false and the wheel did nothing over it, unlike
-- every other pane). The content is assembled into ONE line list and a
-- top-anchored offset windows it, so wm.assign auto-captures
-- scroll/scroll_to_bottom/following_tail off the module table.
--
-- The guild and killers blocks come from OTHER plugins. A plugin that offers
-- a lines accessor (guild_stats_lines / stats_lines) joins the scrollable
-- list; one that only offers the older draw contract (render_guild_stats /
-- render_stats) still renders, below the windowed block, and is excluded from
-- the scroll range -- that back-compat path is asserted too.
-- =============================================================================
local drawn_lines
ui.text_ansi = function(_, s) if drawn_lines then drawn_lines[#drawn_lines + 1] = s end end
ui.text = function(_, s) if drawn_lines then drawn_lines[#drawn_lines + 1] = s end end

local function render_capture(w, h)
  drawn_lines = {}
  M.render(make_rect(0, 0, w, h), { show_border = false })
  return drawn_lines
end

-- A guild double that speaks the NEW lines contract, with numbered rows so a
-- scroll offset is visible in the captured output.
local function guild_lines_double(n)
  local d = { calls = 0, lines_calls = 0 }
  d.has_data = function() return true end
  d.render_guild_stats = function() d.calls = d.calls + 1; return 1 end
  d.guild_stats_lines = function()
    d.lines_calls = d.lines_calls + 1
    local t = {}
    for i = 1, n do t[i] = "guild " .. i end
    return t
  end
  return d
end

live_plugins.guild_druid = nil
local gl = guild_lines_double(30)
live_plugins.guild_viking = gl
M.register_guild("guild_viking")
M.show_player(false)
M.show_mercenary(false)
M.show_killers(false)

check("the module exports scroll", type(M.scroll) == "function")
check("the module exports scroll_to_bottom", type(M.scroll_to_bottom) == "function")
check("the module exports following_tail", type(M.following_tail) == "function")

-- At rest: top-anchored, so the FIRST guild row is showing.
local out = render_capture(40, 10)
check("at rest the pane shows the first guild row", out[1] == "guild 1", out[1])
check("a lines-capable guild plugin is asked for lines, not drawn",
  gl.lines_calls > 0 and gl.calls == 0, gl.lines_calls .. "/" .. gl.calls)
check("at rest following_tail is true (offset 0)", M.following_tail() == true)

-- Scrolling down moves the window.
M.scroll(5)
out = render_capture(40, 10)
check("after scroll(5) the window starts 5 rows lower", out[1] == "guild 6", out[1])
check("after scrolling following_tail is false", M.following_tail() == false)

-- Scrolling up returns toward the top and clamps at 0.
M.scroll(-2)
out = render_capture(40, 10)
check("after scroll(-2) the window starts 3 rows lower", out[1] == "guild 4", out[1])
M.scroll(-99)
out = render_capture(40, 10)
check("scrolling far up clamps at the first row", out[1] == "guild 1", out[1])
check("clamped at the top, following_tail is true again", M.following_tail() == true)

-- Clamp at the bottom: 30 rows in a 10-row pane stops with the last row shown.
M.scroll(999)
out = render_capture(40, 10)
check("scrolling far down clamps to the last full window", out[1] == "guild 21", out[1])
check("the last row is the final guild row", out[#out] == "guild 30", out[#out])
M.scroll_to_bottom()
out = render_capture(40, 10)
check("scroll_to_bottom shows the final row", out[#out] == "guild 30", out[#out])

-- Content shorter than the pane cannot scroll away.
live_plugins.guild_viking = guild_lines_double(3)
M.register_guild("guild_viking")
M.scroll(50)
out = render_capture(40, 10)
check("content shorter than the pane stays put", out[1] == "guild 1", out[1])

-- Back-compat: a draw-only guild plugin still renders.
local old = guild_double()
live_plugins.guild_viking = old
M.register_guild("guild_viking")
out = render_capture(40, 10)
check("a draw-only guild plugin is still rendered", old.calls > 0, old.calls)

M.show_player(true)
M.show_mercenary(true)
M.show_killers(true)

-- ---- mercenary dormancy ---------------------------------------------------
-- Isolate the mercenary block: the guild and killers blocks come from other
-- plugins and would otherwise land in the same capture.
live_plugins.guild_druid = nil
live_plugins.guild_viking = nil
M.show_player(false)
M.show_guild(false)
M.show_killers(false)
M.show_mercenary(true)

local function merc_double(stats)
  return {
    has_data = function() return true end,
    get_stats = function() return stats end,
  }
end

local dormant_stats = {
  name = "Kaziar", hp_current = 118, hp_max = 500, hp_percent = 23,
  hp_delta = 0,
  stamina_current = 0, stamina_max = 90, stamina_percent = 0, stamina_regen = 0,
  ap_current = 0, ap_max = 50, ap_percent = 0, ap_regen = 0,
  target = "Orc", target_pct = 42,
  pl_level = 12, pl_xp = 900, pl_needed = 1500, pl_max_level = 150,
  il_level = 4, il_xp = 30, il_needed = 100, il_max_level = 30,
  is_dormant = true, dormant = 298,
}

live_plugins.mercenary = merc_double(dormant_stats)
local joined = table.concat(render_capture(40, 20), "\n")

-- A collapsed mercenary holds hp/stam/ap frozen for a 300 second recovery.
-- Kills: rendering it identically to a live mercenary, which is exactly the
-- frozen-HUD failure the mudlib added the Merc.* push to fix.
check("a dormant mercenary renders a countdown",
  joined:find("DORMANT", 1, true) ~= nil and joined:find("4:58", 1, true) ~= nil,
  joined)

-- Kills: leaving the bars in their percentage colour, which reads as live data
-- sitting next to a countdown. hp 118/500 over a 6-cell bar fills exactly one
-- cell, so a dimmed bar emits ESC[2m immediately followed by "|"; an undimmed
-- one emits the bright-red percentage colour there instead.
check("a dormant mercenary dims its bars",
  joined:find("\027%[2m|") ~= nil, joined)

-- Kills: keeping the target line while dormant. query_attack() is cleared on
-- collapse, so the line is free and the countdown must take it rather than
-- costing an extra row in a narrow sidebar.
check("the countdown replaces the target line",
  joined:find("->", 1, true) == nil, joined)

-- ---- server-sent level caps -----------------------------------------------
-- Kills: hardcoding the caps at 150/30 the way the old MIP plugin did. They
-- are server-sent now (Info.perm_cap / Info.inst_cap), and a mercenary at the
-- cap must not draw a level line implying progress it cannot make.
local capped_stats = {
  name = "Kaziar", hp_current = 400, hp_max = 500, hp_percent = 80,
  hp_delta = 0,
  stamina_current = 50, stamina_max = 90, stamina_percent = 55, stamina_regen = 1,
  ap_current = 30, ap_max = 50, ap_percent = 60, ap_regen = 1,
  target = "", target_pct = 0,
  pl_level = 20, pl_xp = 10, pl_needed = 100, pl_max_level = 20,
  il_level = 5, il_xp = 5, il_needed = 50, il_max_level = 5,
  is_dormant = false, dormant = 0,
}
-- render.render lazily caches the fetched mercenary plugin (`if not
-- mercenary then mercenary = plugin.get("mercenary") end`), so swapping the
-- live double requires forcing a refetch the same way M.register_guild does
-- for the guild probe. M.on_load() re-fetches unconditionally.
live_plugins.mercenary = merc_double(capped_stats)
M.on_load()
joined = table.concat(render_capture(40, 20), "\n")
check("a capped mercenary draws no level line",
  joined:find("PL", 1, true) == nil, joined)

-- Kills: reading the caps but inverting the test, which would hide the line
-- for every mercenary still levelling.
-- capped_stats is mutated in place rather than replaced: the double
-- stats_window cached at the M.on_load() above closes over this very table, so
-- the mutation is what the next render sees. Re-assigning live_plugins.mercenary
-- here would do nothing -- render.render only refetches on M.on_load().
capped_stats.pl_max_level = 150
capped_stats.il_max_level = 30
joined = table.concat(render_capture(40, 20), "\n")
check("a levelling mercenary still draws the level line",
  joined:find("PL", 1, true) ~= nil, joined)

live_plugins.mercenary = nil
M.show_mercenary(false)

if failures > 0 then os.exit(1) end
print("ALL STATS_WINDOW TESTS PASSED")
