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

if failures > 0 then os.exit(1) end
print("ALL STATS_WINDOW TESTS PASSED")
