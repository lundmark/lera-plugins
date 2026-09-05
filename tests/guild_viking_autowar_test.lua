-- Focused Auto-War adapter tests. Run from the lera plugins directory.
package.path = "3scapes/guild_viking/?.lua;" .. package.path

ui = { dirty = function() end }
buffer = { color_print = function() end }
local sent = {}
mud = { connected = function() return true end,
        send = function(command) sent[#sent + 1] = command end }
store = { load = function() end, get = function() return nil end,
          set = function() end, save = function() end }

local opts = require("page_opts")
local S = require("state").S
local aw = require("autowar")

assert(opts.get("auto_battle") == false)
aw.tick()
assert(#sent == 0, "disabled Auto-War sent a command")

opts.set("auto_battle", true)
S.battle = {
  phase = "deploy", mode = "field", budget = 10, spent = 0,
  width = 8, height = 8, dz = 2, units = {},
  reserve = {{ label = "Shieldwall", size = 20, uid = 7, cost = 3 }},
}
aw.tick()
assert(sent[1] == "vbattle deploy 7 D2", "unexpected deploy: " .. tostring(sent[1]))

opts.set("auto_battle", false)
S.battle = nil
print("guild_viking_autowar_test: PASS")
