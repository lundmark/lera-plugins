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

if failures > 0 then os.exit(1) end
print("ALL STATS_WINDOW TESTS PASSED")
