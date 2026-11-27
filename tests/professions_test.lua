local dispatch
package.loaded.command = {
  register = function(spec) dispatch = spec.handler; return 1 end,
  unregister = function() end,
}
local saved = { enabled = { mystic = true } }
store = {
  load = function() end,
  get = function() return saved end,
  set = function(data) saved = data end,
  save = function() end,
}
buffer = { color_print = function() end }
local trigger_count = 0
trigger = {
  add = function() trigger_count = trigger_count + 1; return trigger_count end,
  remove = function() end,
}

local professions = dofile("3scapes/professions.lua")
local mystic_start = "Your Mystic's Orb begins to glow brightly!"
local mystic_stop = "The glow from your Mystic's Orb dissipates."
local shared_start = "The marionette strings spring to life as the hooks search for a puppet!"
local ordinary = "\27[36mNormal output.\27[0m"

professions.on_load()
assert(professions.on_line("\27[36m" .. mystic_start .. "\27[0m") == "\27[38;2;0;255;255m>> mystic\27[0m")
assert(professions.on_line(mystic_stop) == "\27[38;2;51;204;204m<< mystic\27[0m")
assert(professions.on_line(ordinary) == ordinary)
dispatch("add puppeteer")
dispatch("add puppet_master")
assert(professions.on_line(shared_start) ~= shared_start)
dispatch("remove puppeteer")
assert(professions.on_line(shared_start) == "\27[38;2;0;255;255m>> puppet_master\27[0m")
dispatch("remove mystic")
assert(professions.on_line(mystic_start) == mystic_start)
professions.on_unload()
assert(professions.on_line(shared_start) == shared_start)
print("professions_test: PASS")
