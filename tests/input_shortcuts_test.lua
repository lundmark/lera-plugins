local command, save, removed
local saved = {}
package.loaded.command = {
  register = function(spec) command = spec.handler; return 7 end,
  unregister = function(id) removed = id end,
}
store = {
  load = function() end, get = function() return saved end,
  set = function(value) saved = value end,
  save = function() save = true end,
}
speedwalk = {
  parse = function(syntax)
    if syntax == "3n2(ne)(open gate)" then
      return {{forward = "n", count = 3}, {forward = "ne", count = 2},
        {forward = "open gate", count = 1}}
    elseif syntax == "n" then
      return {{forward = "n", count = 1}}
    elseif syntax == "massive" then
      return {{forward = "n", count = 1025}}
    end
  end,
}
local plugin = dofile("generic/input_shortcuts.lua")
plugin.on_load()
assert(plugin.on_command("look;score") == nil)
assert(plugin.on_command("#n") == nil)

command("stack on")
command("walk on")
assert(save and saved.stack and saved.walk)
local a = plugin.on_command("say a;;b;look;")
assert(#a == 3 and a[1] == "say a;b" and a[2] == "look" and a[3] == "")
a = plugin.on_command(";say a;b")
assert(#a == 1 and a[1] == "say a;b")
a = plugin.on_command("look;#3 n 2(ne) (open gate);score")
assert(#a == 8 and a[1] == "look" and a[8] == "score")
assert(a[2].text == "north" and a[4].text == "north" and a[2].skip_aliases)
assert(a[5].text == "northeast" and a[6].text == "northeast")
assert(a[7].text == "open gate")
assert(plugin.on_command("#chaossea-home") == nil)
a = plugin.on_command("#chaossea-home;look")
assert(#a == 2 and a[1] == "#chaossea-home" and a[2] == "look")
assert(#plugin.on_command("#massive") == 0)
command("separator |")
command("prefix ##")
command("separator nope")
assert(saved.separator == "|" and saved.prefix == "##")
a = plugin.on_command("look|##n")
assert(#a == 2 and a[2].text == "north")
assert(plugin.on_command("#n") == nil)
plugin.on_unload()
assert(removed == 7)
plugin = dofile("generic/input_shortcuts.lua")
plugin.on_load()
assert(plugin.on_command("look|##n")[2].text == "north")
print("input shortcuts tests passed")
