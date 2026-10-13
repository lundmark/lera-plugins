-- Rounded button geometry, colors, switching, visibility and cleanup.
local failures = 0
local function check(name, ok)
  print("CASE " .. name .. ": " .. (ok and "PASS" or "FAIL"))
  if not ok then failures = failures + 1 end
end
local function rect(x, y, w, h)
  return { x=function() return x end, y=function() return y end,
           w=function() return w end, h=function() return h end }
end
local items, active, switched = {"Livsfara", "Skuggis"}, "Livsfara", nil
session = {
  list=function() return items end, active=function() return active end,
  switch=function(name) switched = name; active = name; return true end,
}
local boxes, labels, dirty = {}, {}, 0
ui = {
  rect=rect, dirty=function() dirty = dirty + 1 end,
  box=function(r, style) boxes[#boxes+1] = {r=r, style=style} end,
  text_ansi=function(r, label) labels[#labels+1] = {r=r, label=label} end,
}
local surface, command_spec, removed, closed
package.loaded.wm = {top_bar={
  open=function(renderer, height, visible)
    surface = {renderer=renderer, height=height, visible=visible}; return true
  end,
  close=function() closed = true end,
}}
package.loaded.command = {
  register=function(spec) command_spec = spec; return 17 end,
  unregister=function(id) removed = id end,
}
local buttons = dofile("generic/session_buttons.lua")
buttons.on_load()
check("three-row top bar, no layout API needed", surface.height == 3 and surface.visible())
buttons.render(rect(0, 0, 80, 3))
check("original rounded boxes", #boxes == 2 and boxes[1].style == "rounded"
      and boxes[1].r:w() == 12 and boxes[2].r:x() == 12 and boxes[2].r:h() == 3)
check("original active and inactive colors", labels[1].label == "\27[1;97m Livsfara \27[0m"
      and labels[2].label == "\27[2m Skuggis \27[0m")
check("left click switches by name", buttons.on_pointer({kind="down", button="left",
      inside=true, x=13, y=1}) and switched == "Skuggis")
switched = nil
buttons.on_pointer({kind="down", button="left", inside=true, x=13, y=0})
check("active tab does not switch again", switched == nil)
check("right click ignored", not buttons.on_pointer({kind="down", button="right",
      inside=true, x=1, y=1}))
check("outside click ignored", not buttons.on_pointer({kind="down", button="left",
      inside=false, x=1, y=1}))
boxes, labels = {}, {}
buttons.render(rect(0, 0, 12, 3))
check("narrow viewport clips whole tabs", #boxes == 1 and #labels == 1)
items = {"Livsfara"}
check("single connection hides bar", not surface.visible())
check("stale clicks after session closes ignored", not buttons.on_pointer({kind="down",
      button="left", inside=true, x=1, y=1}))
items = {"Livsfara", "Skuggis"}
command_spec.handler("off")
check("tabs off hides bar", not surface.visible())
command_spec.handler("on")
check("tabs on restores bar", surface.visible())
command_spec.handler("")
check("tabs toggles", not surface.visible())
command_spec.handler("on invalid")
check("invalid argument keeps state", not surface.visible())
buttons.on_unload()
check("unload clears bar and command", closed and removed == 17)
print(failures == 0 and "ALL PASS" or failures .. " FAILURES")
os.exit(failures == 0 and 0 or 1)
