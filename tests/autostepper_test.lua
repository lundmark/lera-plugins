-- autostepper unit tests. Run from the lera-plugins repo root with LERA_ROOT
-- pointing at a built Lera checkout.
--
-- The plugin used to re-read roominfo after every fight, which worked while
-- roominfo was scraping the '=M=' line a 'glance' re-emitted. The GMCP Room.*
-- packages fire on room entry only, so that snapshot cannot change while the
-- player stands in the room: re-reading it makes the plugin attack a corpse
-- forever against a live server. These cases pin the local per-room view that
-- replaced it.
package.path = "3scapes/?.lua;generic/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- ---- stubs ------------------------------------------------------------------
local sent = {}
mud = { send = function(cmd) sent[#sent + 1] = tostring(cmd) end }

local timers = {}
timer = {
  after = function(_, fn) timers[#timers + 1] = fn return #timers end,
}

-- Run every timer callback queued so far, in order.
local function run_timers()
  local queued = timers
  timers = {}
  for _, fn in ipairs(queued) do fn() end
end

trigger = {
  add = function() return 1 end,
  remove = function() return true end,
}

alias = {
  add = function() return 1 end,
  remove = function() return true end,
}

local command_stub = {
  register = function() return 1 end,
  unregister = function() return true end,
}
local real_require = require
require = function(name)
  if name == "command" then return command_stub end
  return real_require(name)
end

-- roominfo stand-in. Its state is what the server told us on room ENTRY; the
-- test never mutates it after a kill, which is exactly the server's behaviour.
local ri_state = { room = "A dusty crossroads", room_id = 100,
                   monsters = {}, players = {} }
local fake_roominfo = {
  room = function() return ri_state.room end,
  room_id = function() return ri_state.room_id end,
  monsters = function()
    local out = {}
    for i, n in ipairs(ri_state.monsters) do out[i] = n end
    return out
  end,
  players = function()
    local out = {}
    for i, n in ipairs(ri_state.players) do out[i] = n end
    return out
  end,
  monster_count = function() return #ri_state.monsters end,
  player_count = function() return #ri_state.players end,
}

-- speedwalk stand-in: a fixed list of steps the test can count down.
local sw_steps = {}
local sw_taken = {}
local fake_speedwalk = {
  get_current_place = function() return "test place" end,
  load_steps = function() return #sw_steps > 0 end,
  get_targets = function() return { "orc" } end,
  is_valid_target = function(name) return name:find("orc", 1, true) ~= nil end,
  step_info = function()
    return { current = #sw_taken, total = #sw_taken + #sw_steps,
             remaining = #sw_steps }
  end,
  take_step = function()
    local step = table.remove(sw_steps, 1)
    if not step then return nil end
    sw_taken[#sw_taken + 1] = step
    return step
  end,
}

plugin = {
  get = function(name)
    if name == "roominfo" then return fake_roominfo end
    if name == "speedwalk" then return fake_speedwalk end
    return nil
  end,
}

local printed = {}
local real_print = print
print = function(...)
  local parts = {}
  for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  printed[#printed + 1] = table.concat(parts, " ")
end

local as = require("autostepper")
as.on_load()
print = real_print

-- A prompt pattern is mandatory: M.start refuses without one.
print = function() end
as.set_prompt_pattern("^H:")
print = real_print

-- ---- helpers ----------------------------------------------------------------

local function quiet(fn, ...)
  print = function() end
  local ok, err = pcall(fn, ...)
  print = real_print
  if not ok then error(err, 0) end
end

-- Move the player: this is a room ENTRY, so roominfo's slice is replaced whole.
local function arrive(id, name, monsters, players)
  ri_state.room_id = id
  ri_state.room = name
  ri_state.monsters = monsters or {}
  ri_state.players = players or {}
end

-- One glance/prompt cycle: the plugin sends "glance" plus an empty line and
-- makes its decision on the second prompt.
local function prompt_cycle()
  quiet(as.prompt)
  quiet(as.prompt)
end

local function count_sent(prefix)
  local n = 0
  for _, cmd in ipairs(sent) do
    if cmd:sub(1, #prefix) == prefix then n = n + 1 end
  end
  return n
end

local function last_sent()
  return sent[#sent]
end

-- Tolerated as absent so the behavioural cases below still report a verdict
-- against a build that predates the local view rather than dying on a nil call.
local function tracked()
  if not as.tracked_monsters then return {} end
  return as.tracked_monsters()
end

-- ---- one monster, one kill, then step --------------------------------------
-- Kills: driving the "room cleared" decision off roominfo.monsters(). The
-- server does not re-send Room.Contents when a mob dies, so the fixture leaves
-- 'a scrawny orc' listed for the whole room; a plugin that re-reads it attacks
-- the corpse forever.
sw_steps = { { raw = "n", commands = { "n" } }, { raw = "e", commands = { "e" } } }
sw_taken = {}
arrive(100, "A dusty crossroads", { "a scrawny orc" }, {})
sent = {}
local started = nil
quiet(function() started = as.start(false) end)
check("start succeeds", started == true, tostring(started))
check("start glances", sent[1] == "glance" and sent[2] == "",
  table.concat(sent, "|"))

sent = {}
prompt_cycle()
check("attacks the monster in the room", last_sent() == "kill a scrawny orc",
  table.concat(sent, "|"))
check("tracked view holds the monster", #tracked() == 1,
  #tracked())

-- Combat ends: one prompt in the fighting state.
sent = {}
quiet(as.prompt)
check("re-glances after combat", sent[1] == "glance", table.concat(sent, "|"))
check("finished target left the tracked view", #tracked() == 0,
  table.concat(tracked(), ","))

sent = {}
prompt_cycle()
check("steps instead of attacking again", count_sent("kill") == 0,
  table.concat(sent, "|"))
check("step command sent", sent[1] == "n", table.concat(sent, "|"))
check("roominfo still lists the dead monster",
  #fake_roominfo.monsters() == 1, #fake_roominfo.monsters())

-- ---- entering a new room reseeds the view -----------------------------------
-- Kills: seeding the view once and never again. A step into a new room must
-- pick up that room's occupants.
run_timers()  -- the post-step glance
arrive(101, "A quiet lane", { "a large rat" }, {})
sent = {}
prompt_cycle()
check("new room's monster is attacked", last_sent() == "kill a large rat",
  table.concat(sent, "|"))

sent = {}
quiet(as.prompt)      -- combat over
prompt_cycle()
check("new room clears too", count_sent("kill") == 0, table.concat(sent, "|"))
check("second step taken", sw_taken[2] and sw_taken[2].raw == "e",
  sw_taken[2] and sw_taken[2].raw)

-- ---- the loop terminates ----------------------------------------------------
-- Kills: any pruning that can fail to shrink the view. Two monsters must cost
-- exactly two fights, and the route must run out rather than the plugin
-- spinning on a room it can never empty.
run_timers()
sw_steps = { { raw = "s", commands = { "s" } } }
sw_taken = {}
arrive(102, "A crowded pit", { "a scrawny orc", "a large rat" }, {})
sent = {}
local kills, steps, guard = 0, 0, 0
while as.is_running() and guard < 50 do
  guard = guard + 1
  local before = #sent
  prompt_cycle()
  for i = before + 1, #sent do
    if sent[i]:sub(1, 4) == "kill" then kills = kills + 1 end
  end
  if as.get_state() == "fighting" then
    quiet(as.prompt)  -- combat ends
  else
    steps = steps + 1
    run_timers()
  end
end
check("two monsters cost two fights", kills == 2, kills)
check("route completed rather than looping", not as.is_running(), guard)
check("terminated well inside the guard", guard < 10, guard)

-- ---- a player in the room still steps ---------------------------------------
sw_steps = { { raw = "w", commands = { "w" } } }
sw_taken = {}
arrive(103, "A busy square", { "a scrawny orc" }, { "Bob" })
sent = {}
quiet(function() as.start(false) end)
sent = {}
prompt_cycle()
check("player in room steps instead of fighting", count_sent("kill") == 0,
  table.concat(sent, "|"))

-- ---- targets-only mode ------------------------------------------------------
run_timers()
sw_steps = { { raw = "n", commands = { "n" } } }
sw_taken = {}
arrive(104, "A back alley", { "a harmless kitten", "a scrawny orc" }, {})
sent = {}
quiet(function() as.start(true) end)
sent = {}
prompt_cycle()
check("targets-only attacks the listed target",
  last_sent() == "kill a scrawny orc", table.concat(sent, "|"))
sent = {}
quiet(as.prompt)
prompt_cycle()
check("non-target left behind does not restart combat",
  count_sent("kill") == 0, table.concat(sent, "|"))

quiet(as.on_unload)

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
