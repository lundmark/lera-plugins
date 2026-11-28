package.path = "3scapes/crafting/?.lua;" .. package.path

local sent, printed, saved, dispatch = {}, {}, nil, nil
local drop = "Something glints among the remains -- a Ironwood Longbow recipe scroll!"
local delivered = "You tuck it away; it is bound to you."

mud = { send = function(command) sent[#sent + 1] = command; return true end }
buffer = { color_print = function(_, _, message) printed[#printed + 1] = message end }
store = {
  load = function() end,
  get = function() return saved end,
  set = function(data) saved = data; return true end,
  save = function() return true end,
}
timer = { every = function() return 1 end, cancel = function() end }
package.loaded.command = {
  register = function(spec) dispatch = spec.handler; return 1 end,
  unregister = function() end,
}
package.loaded.protocol = {
  on_apply = function() end,
  subscribe = function() end,
  unsubscribe = function() end,
  reset_connection = function() end,
}
package.loaded.wm = {}

local crafting = require("init")
crafting.on_load()

local function receive(text)
  assert(crafting.on_line(text) == text, "preserve the server's notice")
end

receive(drop .. " " .. delivered)
assert(#sent == 0, "off by default")
assert(printed[#printed]:find("read Ironwood Longbow scroll", 1, true))
dispatch("autoread on")
assert(saved.auto_read == true)

receive("\27[37m" .. drop .. " " .. delivered .. "\27[0m")
assert(#sent == 1 and sent[1] == "read Ironwood Longbow scroll")
receive("Something glints among the remains -- a Hellforged Plate")
receive("Two-Handed Sword recipe scroll! You tuck it away;")
assert(#sent == 1, "wait for the delivery confirmation")
receive("it is bound to you.")
assert(#sent == 2 and sent[2] == "read Hellforged Plate Two-Handed Sword scroll")

receive("Something glints among the")
receive("remains -- an Ironwood Longbow")
receive("recipe scroll! " .. delivered)
assert(#sent == 3 and sent[3] == "read Ironwood Longbow scroll")
receive("Darkness tells you: " .. drop .. " " .. delivered)
receive("Something glints among the remains -- a Foo; quit recipe scroll! " .. delivered)
receive(drop)
crafting.on_disconnect()
receive(delivered)
assert(#sent == 3, "reject unrelated, unsafe, or incomplete notices")

crafting.on_unload()
crafting.on_load()
receive(drop .. " " .. delivered)
assert(#sent == 4, "persist setting across plugin reloads")
dispatch("autoread off")
receive(drop .. " " .. delivered)
assert(#sent == 4 and saved.auto_read == false)
print("crafting_scroll_test: PASS")
