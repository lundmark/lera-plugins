-- autostepper unit tests. Run from the lera-plugins repo root with LERA_ROOT
-- pointing at a built Lera checkout.
--
-- The plugin used to re-read roominfo after every fight, which worked while
-- roominfo was scraping the '=M=' line a 'glance' re-emitted. The GMCP Room.*
-- packages fire on room entry only, so that snapshot cannot change while the
-- player stands in the room: re-reading it makes the plugin attack a corpse
-- forever against a live server. These cases pin the local per-room view that
-- replaced it.
package.path = "3scapes/autostepper/?.lua;3scapes/?.lua;generic/?.lua;" .. package.path

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
local next_timer_id = 0
timer = {
  after = function(_, fn)
    next_timer_id = next_timer_id + 1
    timers[next_timer_id] = fn
    return next_timer_id
  end,
  cancel = function(id)
    if id and timers[id] then timers[id] = nil return true end
    return false
  end,
}

-- Run every timer callback queued so far, in id order.
local function run_timers()
  local queued = timers
  timers = {}
  local ids = {}
  for id in pairs(queued) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do queued[id]() end
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

local ri_frame_cbs = {}
fake_roominfo.on_room_info = function(fn)
  ri_frame_cbs[#ri_frame_cbs + 1] = fn
  return #ri_frame_cbs
end
fake_roominfo.off_room_info = function(id)
  if ri_frame_cbs[id] then ri_frame_cbs[id] = nil return true end
  return false
end
fake_roominfo.info = function()
  return { room = ri_state.room, room_id = ri_state.room_id,
           exits = ri_state.exits or {} }
end

-- Deliver a Room.Info frame the way roominfo would.
local function deliver_frame()
  for _, fn in pairs(ri_frame_cbs) do fn(fake_roominfo.info()) end
end

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

local as = require("init")
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

-- One prompt is a whole arrival now. Kept under its original name so the eight
-- existing call sites (lines 183, 197, 210, 216, 234, 256, 268, 273) read the
-- same; it simply no longer manufactures a second prompt. It deliberately does
-- NOT drain timers -- the original did not either, and several call sites call
-- run_timers() themselves.
local function prompt_cycle()
  quiet(as.prompt)
end

-- One prompt is now a whole arrival: the glance and its manufactured second
-- prompt are gone. Step 4 collapses prompt_cycle to a single prompt too; this
-- one additionally drains the timer queue, which Task 5's settle timer needs.
local function arrival_prompt()
  quiet(as.prompt)
  run_timers()
end

-- count_sent is a PREFIX match, so count_sent("") equals #sent and would
-- silently assert "nothing was sent at all" rather than "no empty line was
-- sent" -- passing even if an empty line were the only thing sent. Exact
-- comparison is what the empty-line cases actually need.
local function exact_sent(want)
  local n = 0
  for _, cmd in ipairs(sent) do
    if cmd == want then n = n + 1 end
  end
  return n
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

sent = {}
prompt_cycle()
check("attacks the monster in the room", last_sent() == "kill a scrawny orc",
  table.concat(sent, "|"))
check("tracked view holds the monster", #tracked() == 1,
  #tracked())

-- Combat ends: one prompt in the fighting state. It no longer re-glances --
-- the glance never refreshed Room.Contents, which is exactly why the tracked
-- view exists -- so the next decision is made straight from the pruned view
-- and the step goes out immediately.
sent = {}
quiet(as.prompt)
check("no glance after combat", exact_sent("glance") == 0, table.concat(sent, "|"))
check("steps straight from the pruned view", sent[1] == "n",
  table.concat(sent, "|"))
check("finished target left the tracked view", #tracked() == 0,
  table.concat(tracked(), ","))

sent = {}
prompt_cycle()
check("steps instead of attacking again", count_sent("kill") == 0,
  table.concat(sent, "|"))
check("the following step is sent", sent[1] == "e", table.concat(sent, "|"))
check("roominfo still lists the dead monster",
  #fake_roominfo.monsters() == 1, #fake_roominfo.monsters())

-- ---- entering a new room reseeds the view -----------------------------------
-- Kills: seeding the view once and never again. A step into a new room must
-- pick up that room's occupants.
run_timers()  -- drain any pending timer
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
quiet(function() as.start(false) end)
sent = {}
local kills, steps, guard = 0, 0, 0
while as.is_running() and guard < 50 do
  guard = guard + 1
  local before = #sent
  prompt_cycle()
  if as.get_state() == "fighting" then
    quiet(as.prompt)  -- combat ends
  else
    steps = steps + 1
    run_timers()
  end
  -- Counted after the whole iteration, not just after prompt_cycle(): a kill
  -- on the second (or later) monster in a room now lands during the
  -- "combat ends" follow-up prompt above, which is still part of this same
  -- iteration's arrival -- narrowing the window to prompt_cycle() alone would
  -- silently drop it.
  for i = before + 1, #sent do
    if sent[i]:sub(1, 4) == "kill" then kills = kills + 1 end
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

-- ---- glance-free step cycle --------------------------------------------------
run_timers()
sw_steps = { { raw = "n", commands = { "n" } }, { raw = "e", commands = { "e" } } }
sw_taken = {}
arrive(200, "A quiet lane", {}, {})
sent = {}
quiet(function() as.start(false) end)
check("start does not send a glance",
  count_sent("glance") == 0, table.concat(sent, "|"))
check("start does not send a bare empty line",
  exact_sent("") == 0, table.concat(sent, "|"))

-- start() leaves us awaiting arrival in the room we are standing in, so one
-- prompt is enough to make the first decision and take the first step.
sent = {}
arrival_prompt()
check("one prompt is a whole arrival", last_sent() == "n", table.concat(sent, "|"))
check("state after a step is stepping", as.get_state() == "stepping", as.get_state())

sent = {}
arrive(201, "A quiet lane", {}, {})
arrival_prompt()
check("second arrival takes the second step",
  last_sent() == "e", table.concat(sent, "|"))
check("still no glance anywhere in the cycle",
  count_sent("glance") == 0, table.concat(sent, "|"))

-- ---- glance escape hatch -----------------------------------------------------
-- Restoring the glance restores the old two-prompt cycle for that user,
-- including its fragility. It exists for brief-mode players who lose the room
-- description otherwise.
quiet(as.stop)
as.set_glance_cmd("glance")
sw_steps = { { raw = "s", commands = { "s" } }, { raw = "w", commands = { "w" } } }
sw_taken = {}
arrive(202, "A dim hall", {}, {})
sent = {}
quiet(function() as.start(false) end)
check("hatch on: start sends the glance", exact_sent("glance") == 1,
  table.concat(sent, "|"))
sent = {}
arrival_prompt()
check("hatch on: one prompt is not yet an arrival", #sent == 0,
  table.concat(sent, "|"))
arrival_prompt()
check("hatch on: the second prompt completes the arrival", sent[1] == "s",
  table.concat(sent, "|"))
check("hatch on: a glance follows the step", sent[2] == "glance",
  table.concat(sent, "|"))
as.set_glance_cmd("")
quiet(as.stop)

-- ---- arrival without a prompt ------------------------------------------------
-- A frame completes the arrival too, so a drifted or unset prompt pattern no
-- longer wedges the cycle.
--
-- THREE steps, not two: a spurious extra arrival has to have something left to
-- send, or the bug it would reveal looks identical to a completed route.
--
-- as.on_load() is called again on purpose. There is a quiet(as.on_unload) earlier
-- in this file, which tears down the Room.Info subscription -- so without this,
-- deliver_frame() below reaches an empty callback table and the two cases fail
-- with `sent` staying empty forever, which reads like a production bug and is
-- not one. Re-subscribing here also makes this block self-contained rather than
-- dependent on how much of the file ran before it. (The blocks added by the
-- previous task also sit after that on_unload, and work only because they need
-- no subscription: as.start re-acquires its plugin dependencies itself.)
quiet(as.on_load)
quiet(as.stop)
sw_steps = { { raw = "n", commands = { "n" } }, { raw = "s", commands = { "s" } },
             { raw = "w", commands = { "w" } } }
sw_taken = {}
arrive(300, "A cold cell", {}, {})
sent = {}
quiet(function() as.start(false) end)
deliver_frame()
check("a frame alone does not arrive before the burst settles",
  #sent == 0, table.concat(sent, "|"))
run_timers()
check("the settled burst completes the arrival",
  last_sent() == "n", table.concat(sent, "|"))

-- A prompt landing first wins, and must cancel the settle timer it raced --
-- otherwise that stale timer arrives a second time and takes another step.
sent = {}
arrive(301, "A cold cell", {}, {})
deliver_frame()
quiet(as.prompt)
check("prompt wins when it lands first", last_sent() == "s", table.concat(sent, "|"))
sent = {}
run_timers()
check("the raced settle timer does not fire a second arrival",
  #sent == 0, table.concat(sent, "|"))

-- A raced settle timer must not survive into combat, and this is the ONLY case
-- that exercises either of the two overlapping protections against a stale
-- settle: complete_arrival's own cancel_settle(), and the `state ~= "stepping"`
-- guard. It exercises them JOINTLY, because each alone masks the other --
-- with cancel_settle intact the stale timer never fires, and with the guard
-- intact its firing is swallowed. Deleting both lets the stale timer re-enter
-- process_room mid-fight and attack the same monster a second time.
--
-- The route's third step is deliberately left untaken so the run is still live
-- here; an exhausted route would send nothing either way.
sent = {}
arrive(302, "A cold cell", { "a scrawny orc" }, {})
deliver_frame()
quiet(as.prompt)
check("a raced timer in combat: the attack goes out once",
  count_sent("kill") == 1, table.concat(sent, "|"))
sent = {}
run_timers()
check("a raced settle timer does not re-attack",
  count_sent("kill") == 0, table.concat(sent, "|"))

quiet(as.stop)

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
