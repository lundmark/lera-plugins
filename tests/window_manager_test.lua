package.path = "3scapes/?.lua;" .. package.path
local failures = 0
local function check(name, ok) if ok then print("CASE " .. name .. ": PASS") else failures = failures + 1; print("CASE " .. name .. ": FAIL") end end
local registered, handler, opened = nil, nil, {}
local popup = {}
popup.open = function(window) popup.window = window; popup.visible = true end
popup.close = function() popup.visible = false; return true end
popup.is_open = function() return popup.visible end
ui = { dirty = function() end, box = function() end, shrink = function(rect) return rect end, rect = function(x,y,w,h) return {x=function() return x end,y=function() return y end,w=function() return w end,h=function() return h end} end, text_ansi = function() end }
lera = { render_pass = function() return "local" end }
local tools = {
  status_monitor = { window_launcher={label="Status Monitor",compact_label="Status",order=10} },
  xp_monitor = { window_launcher={label="XP Monitor",compact_label="XP",order=20} },
  damage_tracker = { window_launcher={label="Damage Tracker",compact_label="Damage",order=30} },
  crafting = { window_launcher={label="Crafting",compact_label="Craft",order=40} },
}
for name, value in pairs(tools) do
  value.is_open = function() return false end
  value.open = function() opened[name] = (opened[name] or 0) + 1 end
end
plugin = { list = function() return {{name="crafting"},{name="damage_tracker"},{name="xp_monitor"},{name="status_monitor"}} end, get = function(name) return tools[name] end }
local real_require = require
require = function(name) if name == "command" then return { register=function(spec) registered=spec; handler=spec.handler; return 4 end, unregister=function() end } end; if name == "wm" then return { popup=popup } end; return real_require(name) end
local M = require("window_manager")
M.on_load()
check("registers launcher command", registered.name == "/windows" and registered.aliases[1] == "/win")
handler("")
check("opens launcher", popup.visible == true)
popup.window.on_pointer({kind="down",button="left",x=1,y=2})
check("first button opens status monitor", opened.status_monitor == 1)
M.pane.render(ui.rect(0,0,40,4), {title="Windows"})
M.pane.on_pointer({kind="down",button="left",x=21,y=1})
check("compact pane opens XP monitor", opened.xp_monitor == 1)
M.pane.on_pointer({kind="down",button="left",x=2,y=2})
check("compact pane opens Damage Tracker", opened.damage_tracker == 1)
M.pane.on_pointer({kind="down",button="left",x=21,y=2})
check("discovered Crafting appears in compact pane", opened.crafting == 1)
M.on_unload()
require = real_require
if failures > 0 then os.exit(1) end
print("window_manager_test: all cases passed")
