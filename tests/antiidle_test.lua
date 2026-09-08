package.path = "generic/?.lua;" .. package.path
local now, tick, handler, saved = 1000
local connected, sends = true, 0
lera = { time = function() return now end, dirty = function() end }
store = { load = function() end, get = function() return saved end,
  set = function(v) saved = v end, save = function() end }
timer = { every = function(_, fn) tick = fn return 1 end, cancel = function() end }
package.preload.command = function() return {
  register = function(s) handler = s.handler return 1 end,
  unregister = function() end,
} end
mud = { state = function() return connected and "connected" or "disconnected" end,
  send_raw = function(text) assert(text == ""); sends = sends + 1; return true end }
local dm = require("deadmans")
dm.on_load()
now = 2000; tick(); assert(sends == 0, "off by default")
handler("antiidle on")
now = 2299; tick(); assert(sends == 0)
now = 2300; tick(); assert(sends == 1)
assert(dm.is_active(), "keepalive must not reset deadmans")
assert(dm.on_send("attack") == nil, "automation stays blocked")
now = 9999; tick(); assert(sends == 2, "no catch-up burst")
dm.on_disconnect(); now = 11000; tick(); assert(sends == 2)
connected = false; handler("antiidle on"); connected = true
now = 12000; tick(); assert(sends == 2, "cannot arm offline")
handler("antiidle 0"); handler("antiidle 61")
handler("antiidle 2"); assert(saved.config.antiidle_time == 120)
handler("antiidle on"); now = 12119; tick(); assert(sends == 2)
now = 12120; tick(); assert(sends == 3)
dm.on_user_input(""); now = 12200; tick(); assert(sends == 3)
handler("antiidle off"); now = 14000; tick(); assert(sends == 3)
dm.on_unload()
print("antiidle tests: PASS")
