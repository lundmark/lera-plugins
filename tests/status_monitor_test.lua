package.path = "3scapes/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then print("CASE " .. name .. ": PASS") else failures = failures + 1; print("CASE " .. name .. ": FAIL " .. tostring(detail or "")) end
end

local saved, handler, registered, cancelled
store = { load = function() end, get = function() return saved end, set = function(v) saved = v end, save = function() end }
timer = { every = function(_, fn) return 91 end, cancel = function(id) cancelled = id end }
lera = { render_pass = function() return "local" end }
local rendered = {}
ui = { dirty = function() end, rect = function(x, y, w, h) return { x = function() return x end, y = function() return y end, w = function() return w end, h = function() return h end } end, text_ansi = function(_, text) rendered[#rendered + 1] = text end }
local plugins = {
  roominfo = { info = function() return { area = "Chaos Sea", room = "Storm Coast" } end },
  speedwalk = { step_info = function() return { place = "Sea Run", current = 2, total = 5, remaining = 3 } end },
  kill_trigger = { is_enabled = function() return true end, get_killers = function() return { "tapir", "skuggo" } end, get_commands = function() return { "sl", "wrap" } end },
  player_stats = { get_stats = function() return { attacker = "Huge Being", attacker_hp = 40, coffin = 5, coffin_max = 20 } end },
  mudstatus = { snapshot = function() return { uptime = 3600, reboot_left = 1800, lag = 32.5 } end, reboot_left = function() return 1800 end },
}
plugin = { get = function(name) return plugins[name] end }
local popup = {}
popup.open = function(window) popup.window = window; popup.opened = true end
popup.close = function() popup.opened = false; return true end
popup.is_open = function() return popup.opened end
local real_require = require
require = function(name)
  if name == "command" then return { register = function(spec) registered = spec; handler = spec.handler; return 12 end, unregister = function() return true end } end
  if name == "wm" then return { popup = popup } end
  return real_require(name)
end

local M = require("status_monitor")
M.on_load()
check("registers monitor command", registered and registered.name == "/monitor" and registered.aliases[1] == "/sm")
handler("overview")
rendered = {}
popup.window.render(ui.rect(0, 0, 80, 30))
local output = table.concat(rendered, "\n")
check("overview renders legacy-equivalent sources", output:find("Chaos Sea", 1, true) and output:find("Killers:", 1, true) and output:find("Target:", 1, true) and output:find("Reboot:", 1, true), output)
popup.window.on_pointer({ kind = "down", button = "left", x = 12, y = 0 })
rendered = {}
popup.window.render(ui.rect(0, 0, 80, 30))
popup.window.on_pointer({ kind = "down", button = "left", x = 1, y = 4 })
check("section click persists a visibility toggle", saved.sections.position == false)
M.on_unload()
check("unload cancels timer", cancelled == 91)
require = real_require
if failures > 0 then os.exit(1) end
print("status_monitor_test: all cases passed")
