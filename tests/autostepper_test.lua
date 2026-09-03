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

local function queued_timers()
  local n = 0
  for _ in pairs(timers) do n = n + 1 end
  return n
end

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

-- gmcp stand-in. gmcp_send_result lets a case simulate a dropped request
-- (not connected / GMCP off); gmcp_sent records every Room.Refresh call so a
-- case can pin exactly what was asked for.
local gmcp_handlers = {}
local gmcp_removed = {}
local gmcp_sent = {}
local gmcp_send_result = true
gmcp = {
  on = function(pkg, fn) gmcp_handlers[pkg] = fn; return pkg end,
  remove = function(id) gmcp_removed[id] = true; return true end,
  send = function(pkg, data)
    gmcp_sent[#gmcp_sent + 1] = { pkg = pkg, data = data }
    return gmcp_send_result
  end,
}

-- Deliver a Char.Combat frame the way the C dispatcher does.
local function deliver_combat(data)
  local fn = gmcp_handlers["Char.Combat"]
  if not fn then return false end
  fn("Char.Combat", data)
  return true
end

alias = {
  add = function() return 1 end,
  remove = function() return true end,
}

-- The registry hands the spec straight back, so the /step handler the plugin
-- actually registered is callable from here. That is the only way to reach
-- dispatch(), which is a local.
local step_cmd = nil
local command_stub = {
  register = function(spec) step_cmd = spec return 1 end,
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

local ri_contents_cbs = {}
fake_roominfo.on_room_contents = function(fn)
  ri_contents_cbs[#ri_contents_cbs + 1] = fn
  return #ri_contents_cbs
end
fake_roominfo.off_room_contents = function(id)
  if ri_contents_cbs[id] then ri_contents_cbs[id] = nil return true end
  return false
end

-- Deliver a COMPLETE Room.Contents list the way roominfo's on_room_contents
-- would, AFTER ri_state.monsters/players already reflect the server's answer
-- -- exactly like real roominfo, which updates its own state before firing.
local function deliver_contents_frame()
  for _, fn in pairs(ri_contents_cbs) do fn(fake_roominfo.info()) end
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

-- Like quiet(), but hands back the lines the plugin logged. The /step reporting
-- subcommands have no return value; what they print IS their output.
local function capture(fn, ...)
  local lines = {}
  print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    lines[#lines + 1] = table.concat(parts, " ")
  end
  local ok, err = pcall(fn, ...)
  print = real_print
  if not ok then error(err, 0) end
  return lines
end

local function has_line(lines, want)
  for _, line in ipairs(lines) do
    if line:find(want, 1, true) then return true end
  end
  return false
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

-- ---- M.start no longer refuses without a prompt pattern (task-12 supp. 2) ---
-- Task 5 made a settled Room.Info burst complete an arrival on its own, so a
-- prompt is no longer load-bearing for starting a run. Nothing in the area
-- profile itself sets a pattern, so a refusal here made explore runs
-- impossible to start with the default configuration.
run_timers()
as.set_prompt_pattern(nil)
sw_steps = { { raw = "n", commands = { "n" } } }
sw_taken = {}
arrive(303, "A cold cell", {}, {})
sent = {}
local no_prompt_started = nil
quiet(function() no_prompt_started = as.start(false) end)
check("start succeeds with no prompt pattern configured",
  no_prompt_started == true, tostring(no_prompt_started))
sent = {}
deliver_frame()
run_timers()
check("the first step arrives via the frame path with no prompt pattern set",
  last_sent() == "n", table.concat(sent, "|"))
as.set_prompt_pattern("^H:")
quiet(as.stop)

-- ---- M.start asks the MUD for the current room (Item 1) ---------------------
-- mode.start's cached-roominfo seed was the fix for a review finding at a
-- time when nothing could force a re-read; Room.Refresh makes ASKING
-- possible, and the cache is only the FALLBACK for when gmcp.send fails.
-- Route mode gets the same ask: it reads roominfo for its first decision
-- too, and with the glance gone nothing else forces a re-read, so '-.' in a
-- long-occupied room would otherwise decide on stale contents. Explore mode's
-- own copy of this same property is covered further down, once the stub
-- explore module is wired in (see "starting an explore run also asks the MUD
-- for the current room").
run_timers()
gmcp_sent = {}
sw_steps = { { raw = "n", commands = { "n" } } }
sw_taken = {}
arrive(800, "A muddy field", {}, {})
sent = {}
local route_started = nil
quiet(function() route_started = as.start(false) end)
check("starting a route run also asks the MUD for the current room",
  route_started == true and #gmcp_sent == 1, tostring(#gmcp_sent))
check("the refresh asks for Room.Info and Room.Contents",
  gmcp_sent[1] and gmcp_sent[1].pkg == "Room.Refresh"
    and type(gmcp_sent[1].data) == "table"
    and #gmcp_sent[1].data.packages == 2
    and gmcp_sent[1].data.packages[1] == "Room.Info"
    and gmcp_sent[1].data.packages[2] == "Room.Contents",
  gmcp_sent[1] and (gmcp_sent[1].pkg .. ":" .. table.concat(gmcp_sent[1].data.packages or {}, ",")))

-- Taking a further step must not send a second refresh: the request is
-- per-start, not per-step.
sent = {}
arrival_prompt()
check("a further step is taken normally", last_sent() == "n",
  table.concat(sent, "|"))
check("the request is sent once per start, not per step",
  #gmcp_sent == 1, tostring(#gmcp_sent))
quiet(as.stop)

-- gmcp.send returning false (not connected, or GMCP not negotiated) must not
-- stop the run from starting -- mode.start's cached-roominfo seed is exactly
-- the fallback for this case.
run_timers()
gmcp_send_result = false
gmcp_sent = {}
sw_steps = { { raw = "n", commands = { "n" } } }
sw_taken = {}
arrive(801, "A muddy field", {}, {})
sent = {}
local refused_started = nil
quiet(function() refused_started = as.start(false) end)
check("gmcp.send is still attempted even though it will fail",
  #gmcp_sent == 1, tostring(#gmcp_sent))
check("a gmcp.send that returns false still starts the run",
  refused_started == true, tostring(refused_started))
gmcp_send_result = true
quiet(as.stop)

-- ---- explore mode wiring -----------------------------------------------------
-- A stand-in explore module: the real one has its own suite, and this pins only
-- the wiring -- that do_step asks it instead of speedwalk, that exhaustion stops
-- the run, and that an exhausted explore run never falls through to the route.
local explore_steps = {}
local explore_taken = {}
local explore_state = { active = false, arrivals = 0, coord = 0, frames = 0,
                        stops = 0, resets = 0, reset_reason = nil,
                        leaves = 0, leave_result = true, stop_reason = nil,
                        leaving = false,
                        start_policy = nil, attached = nil }
as.debug_set_explore({
  active = function() return explore_state.active end,
  next_step = function()
    local dir = table.remove(explore_steps, 1)
    if not dir then return nil end
    explore_taken[#explore_taken + 1] = dir
    return { raw = dir, commands = { dir } }
  end,
  -- The real module commits the emitted direction HERE -- on_arrival is the one
  -- place position moves -- so the coordinate, and therefore the room key,
  -- advances on arrival and not on next_step. Getting that backwards makes the
  -- key advance before process_room is called under either ordering, which
  -- silently hides whether on_arrival runs first.
  on_arrival = function()
    explore_state.arrivals = explore_state.arrivals + 1
    explore_state.coord = explore_state.coord + 1
  end,
  on_frame = function(info)
    explore_state.frames = explore_state.frames + 1
    explore_state.last_frame = info
  end,
  -- The key MUST advance as the explorer moves. A constant would make the
  -- reseed case below unpassable, and it is the whole property under test:
  -- roominfo's key cannot change inside a sea layer (id nil, one name per
  -- layer), so the only thing that can drive a reseed is this coordinate.
  room_key = function() return "xyz:" .. explore_state.coord .. ",0,0" end,
  attach = function(mod) explore_state.attached = mod end,
  start = function(prof, pol)
    explore_state.start_prof = prof
    explore_state.start_policy = pol
    explore_state.active = true
    return true
  end,
  stop = function()
    explore_state.active = false
    explore_state.stops = explore_state.stops + 1
  end,
  reset = function(reason)
    explore_state.resets = explore_state.resets + 1
    explore_state.reset_reason = reason
  end,
  leave = function()
    explore_state.leaves = explore_state.leaves + 1
    return explore_state.leave_result
  end,
  stop_reason = function() return explore_state.stop_reason or "exhausted" end,
  -- No real public "is a leave in progress" accessor exists (mode.lua keeps
  -- pending_leave_path private) -- this exists only so the "skip process_room
  -- while a path is pending" mutant (applied directly to init.lua, never to
  -- this file) has something to consult.
  leaving = function() return explore_state.leaving end,
  policy = function() return explore_state.policy or "clear" end,
  set_policy = function(name) explore_state.policy = name return true end,
  stats = function()
    return { rooms = 1, x = explore_state.coord, y = 0, z = 0,
             policy = explore_state.policy or "clear" }
  end,
})

-- A frame arriving while no step is outstanding must still reach the explorer.
-- On the real path the entry room's Room.Info arrives when the player WALKS
-- INTO the area -- before the explore command runs and before any step is
-- outstanding -- and an identical payload is never resent, so a frame dropped
-- here is a room whose exits the explorer never learns. It must NOT arm the
-- arrival settle timer, though: nothing has been asked to move, so there is no
-- arrival to commit.
quiet(as.stop)
run_timers()
explore_state.active = true
explore_state.frames = 0
arrive(399, "Layer one of the Sea of Chaos", {}, {})
deliver_frame()
check("a frame arriving outside a step still reaches the explorer",
  explore_state.frames == 1, tostring(explore_state.frames))
check("a frame arriving outside a step arms no arrival timer",
  queued_timers() == 0, tostring(queued_timers()))

quiet(as.stop)
explore_state.active = true
explore_steps = { "n", "e" }
explore_taken = {}
explore_state.coord = 0
sw_steps = { { raw = "SHOULD-NOT-RUN", commands = { "SHOULD-NOT-RUN" } } }
arrive(400, "Layer one of the Sea of Chaos", {}, {})
sent = {}
gmcp_sent = {}
quiet(function() as.start(false) end)
-- Item 1: both modes get the ask, not just route mode -- this is the explore
-- side of the "starting a route run also asks the MUD" case above. Checked
-- here (an explore run) rather than only in route mode so a mutant that
-- gates the send behind explore.active() still has a case in EACH direction
-- to redden.
check("starting an explore run also asks the MUD for the current room, exactly once",
  #gmcp_sent == 1, tostring(#gmcp_sent))
check("the explore-mode refresh asks for Room.Info and Room.Contents",
  gmcp_sent[1] and gmcp_sent[1].pkg == "Room.Refresh"
    and type(gmcp_sent[1].data) == "table"
    and #gmcp_sent[1].data.packages == 2
    and gmcp_sent[1].data.packages[1] == "Room.Info"
    and gmcp_sent[1].data.packages[2] == "Room.Contents",
  gmcp_sent[1] and (gmcp_sent[1].pkg .. ":" .. table.concat(gmcp_sent[1].data.packages or {}, ",")))
arrival_prompt()
check("explore mode supplies the step", last_sent() == "n", table.concat(sent, "|"))
check("explore mode is told about the arrival",
  explore_state.arrivals >= 1, tostring(explore_state.arrivals))

sent = {}
arrive(401, "Layer one of the Sea of Chaos", {}, {})
arrival_prompt()
check("explore mode supplies the second step",
  last_sent() == "e", table.concat(sent, "|"))

-- Frontier exhausted: the run ends. It must NOT fall through to the stored
-- route, or the stepper silently starts walking a speedwalk path from wherever
-- it is standing in the maze.
sent = {}
arrive(402, "Layer one of the Sea of Chaos", {}, {})
arrival_prompt()
check("an exhausted explore run stops the stepper", as.is_running() == false,
  tostring(as.is_running()))
check("an exhausted explore run never takes a route step",
  count_sent("SHOULD-NOT-RUN") == 0, table.concat(sent, "|"))
-- Exhaustion ends the RUN (6.5), not just the stepping. Left active, the next
-- "-." re-enters explore mode, instantly re-exhausts the same map, and route
-- mode is unreachable for the rest of the session.
check("an exhausted explore run deactivates explore mode",
  explore_state.active == false, tostring(explore_state.active))

-- The room key comes from the explorer's own coordinate while it is active.
-- roominfo's key is useless in the sea: the id is nil and the name is the same
-- for a whole layer, so the local monster view would never reseed between rooms.
explore_state.active = true
explore_steps = { "n", "s" }
explore_taken = {}
explore_state.coord = 0
arrive(403, "Layer one of the Sea of Chaos", { "a small mutant organism" }, {})
sent = {}
quiet(function() as.start(false) end)
arrival_prompt()
check("a monster in the first sea room is attacked",
  last_sent() == "kill a small mutant organism", table.concat(sent, "|"))
sent = {}
quiet(as.prompt)     -- combat ends; the mob is struck from the local view
arrive(403, "Layer one of the Sea of Chaos", { "a second organism" }, {})
arrival_prompt()
check("a monster in the NEXT sea room is attacked despite the same room name",
  last_sent() == "kill a second organism", table.concat(sent, "|"))
quiet(as.stop)

-- ---- run_mode is fixed at start, not decided per step (task-12 supp. 3) -----
-- do_step used to branch on explore.active() every step. The moment the mode
-- deactivates itself mid-run (the in_area check, once wired), the next
-- do_step would take the route branch and call sw.take_step() -- walking a
-- stored speedwalk path from wherever the player now stands, outside the
-- area. Fixing run_mode at M.start closes that door.
run_timers()
explore_state.active = true
explore_steps = { "n" }
explore_taken = {}
explore_state.coord = 0
explore_state.stops = 0
sw_steps = { { raw = "SHOULD-NOT-RUN", commands = { "SHOULD-NOT-RUN" } } }
sw_taken = {}
arrive(700, "Layer one of the Sea of Chaos", {}, {})
sent = {}
quiet(function() as.start(false) end)
arrival_prompt()
check("run_mode setup: explore mode supplies the first step",
  last_sent() == "n", table.concat(sent, "|"))

-- Self-deactivate mid-run, the way the in_area check will: explore.active()
-- goes false with no explore.stop() call from autostepper's own side.
explore_state.active = false
sent = {}
arrive(701, "A dusty crossroads", {}, {})
arrival_prompt()
check("a self-deactivated explore run stops rather than falling through",
  as.is_running() == false, tostring(as.is_running()))
check("a self-deactivated explore run never takes a route step",
  count_sent("SHOULD-NOT-RUN") == 0, table.concat(sent, "|"))
quiet(as.stop)

-- A route run is unaffected: run_mode is fixed to "route" when explore is not
-- active at start, and do_step keeps taking route steps regardless of what
-- explore.active() reports afterward.
run_timers()
explore_state.active = false
sw_steps = { { raw = "n", commands = { "n" } }, { raw = "e", commands = { "e" } } }
sw_taken = {}
arrive(702, "A dusty crossroads", {}, {})
sent = {}
quiet(function() as.start(false) end)
arrival_prompt()
check("a route run still takes its first step when explore is inactive at start",
  last_sent() == "n", table.concat(sent, "|"))
sent = {}
arrive(703, "A dusty crossroads", {}, {})
arrival_prompt()
check("a route run takes its second step", last_sent() == "e",
  table.concat(sent, "|"))
quiet(as.stop)

-- ---- the area profile defaults the policy ------------------------------------
-- Spec 5.3: the policy is defaulted by the AREA PROFILE and only overridden by
-- the user. So init must pass nothing until "/step set dive" has been used --
-- a config value that is never nil makes mode.lua's
-- `initial_policy or prof.default_policy` unreachable and silently ignores the
-- field every area profile declares.
package.preload["areas.chaossea"] = function()
  return {
    name = "chaossea-stub",
    default_policy = "dive",
    exclude_exits = {},
    dive_dirs = { "d" },
    defer_dirs = { "u" },
    in_area = function() return true end,
    layer_of = function() return 0 end,
    complete = function() return false end,
  }
end

explore_state.active = false
explore_state.policy = nil
local dive_lines = capture(step_cmd.handler, "set dive")
check("bare 'set dive' reports the profile default before the user picks one",
  has_line(dive_lines, "dive: profile default"), table.concat(dive_lines, "|"))

explore_state.start_policy = "sentinel"
explore_state.attached = nil
local ex_ok = nil
quiet(function() ex_ok = as.explore_start("chaossea") end)
check("explore_start loads the area and starts the mode", ex_ok == true,
  tostring(ex_ok))
check("explore_start passes no policy of its own, so the profile's default wins",
  explore_state.start_policy == nil, tostring(explore_state.start_policy))
-- attach is what lets mode.start seed itself from the room the player is
-- standing in; without it the explorer has no roominfo to read.
check("explore_start attaches roominfo to the explorer",
  explore_state.attached == fake_roominfo, tostring(explore_state.attached))

-- With a run live, "effective" means the run's own policy. The config is still
-- nil here, so a report built from the config alone would say "off" about a run
-- that is diving.
explore_state.policy = "dive"
dive_lines = capture(step_cmd.handler, "set dive")
check("bare 'set dive' reports the live run's policy, not the unset config",
  has_line(dive_lines, "dive: on"), table.concat(dive_lines, "|"))

explore_state.policy = "clear"
quiet(step_cmd.handler, "set dive on")
check("'set dive on' reaches the live run", explore_state.policy == "dive",
  tostring(explore_state.policy))
explore_state.active = false
dive_lines = capture(step_cmd.handler, "set dive")
check("bare 'set dive' reports the user's choice once no run is live",
  has_line(dive_lines, "dive: on"), table.concat(dive_lines, "|"))

-- ---- /step explore reset (Item 2) --------------------------------------------
-- Mid-run is exactly when the map turns out to be wrong (a desync reset that
-- lands on the wrong layer, a frame missed before the plugin loaded). Reset
-- corrects the map in place; it must not stop the run.
quiet(as.stop)
explore_state.active = true
explore_state.resets = 0
gmcp_sent = {}
quiet(function() as.start(false) end)
check("explore reset setup: the run is live and stepping before the reset",
  as.is_running() == true and as.get_state() == "stepping", as.get_state())

explore_state.resets = 0
gmcp_sent = {}
quiet(function() step_cmd.handler("explore reset") end)
check("'/step explore reset' calls mode.reset exactly once",
  explore_state.resets == 1, tostring(explore_state.resets))
check("'/step explore reset' asks the MUD again",
  #gmcp_sent == 1
    and gmcp_sent[1].pkg == "Room.Refresh"
    and type(gmcp_sent[1].data) == "table"
    and #gmcp_sent[1].data.packages == 2
    and gmcp_sent[1].data.packages[1] == "Room.Info"
    and gmcp_sent[1].data.packages[2] == "Room.Contents",
  gmcp_sent[1] and (gmcp_sent[1].pkg .. ":" .. table.concat(gmcp_sent[1].data.packages or {}, ",")))
check("'/step explore reset' leaves the run active",
  as.is_running() == true, tostring(as.is_running()))
check("'/step explore reset' leaves the run stepping, not stopped",
  as.get_state() == "stepping", as.get_state())
quiet(as.stop)

-- Refuse with a message, and change nothing, when explore mode is not active.
explore_state.active = false
explore_state.resets = 0
gmcp_sent = {}
local inactive_lines = capture(step_cmd.handler, "explore reset")
check("'/step explore reset' with explore inactive reports a message",
  #inactive_lines > 0, tostring(#inactive_lines))
check("'/step explore reset' with explore inactive does not call mode.reset",
  explore_state.resets == 0, tostring(explore_state.resets))
check("'/step explore reset' with explore inactive does not ask the MUD",
  #gmcp_sent == 0, tostring(#gmcp_sent))

-- ---- /step explore leave (Item 4) --------------------------------------------
-- M.explore_leave is a thin wrapper: the real routing/precedence/one-hop
-- logic lives in mode.lua and is pinned in autostepper_explore_test.lua.
-- This only checks the wiring: the command reaches explore.leave().
quiet(as.stop)
explore_state.active = true
explore_state.leaves = 0
explore_state.leave_result = true
quiet(function() step_cmd.handler("explore leave") end)
check("'/step explore leave' calls explore.leave exactly once",
  explore_state.leaves == 1, tostring(explore_state.leaves))
explore_state.active = false

-- do_step must report the RIGHT reason once next_step() runs dry: a
-- completed leave is "back at the origin", exhausted frontier search is "no
-- unvisited exits remain" -- do_step's explore.stop_reason() branch is what
-- tells them apart, so both sides of that branch need a case.
quiet(as.stop)
explore_state.active = true
explore_steps = {}  -- next_step() returns nil immediately either way
explore_state.stop_reason = "at origin"
sw_steps = { { raw = "SHOULD-NOT-RUN", commands = { "SHOULD-NOT-RUN" } } }
arrive(950, "A muddy field", {}, {})
sent = {}
quiet(function() as.start(false) end)
local origin_lines = capture(as.prompt)
check("do_step reports 'back at the origin' when explore.stop_reason() says so",
  has_line(origin_lines, "back at the origin"), table.concat(origin_lines, "|"))
check("completing a leave stops the run", as.is_running() == false,
  tostring(as.is_running()))

explore_state.active = true
explore_steps = {}
explore_state.stop_reason = "exhausted"
arrive(951, "A muddy field", {}, {})
sent = {}
quiet(function() as.start(false) end)
local exhausted_lines = capture(as.prompt)
check("do_step still reports 'no unvisited exits remain' for a genuine exhaustion",
  has_line(exhausted_lines, "no unvisited exits remain"),
  table.concat(exhausted_lines, "|"))
quiet(as.stop)

-- A monster met on the way out is still attacked: arrival always runs
-- process_room() unconditionally, so fighting must not be skippable by any
-- "mid-leave" signal. There is no real public accessor for "is a leave in
-- progress" (mode.lua keeps pending_leave_path private) -- explore.leaving()
-- exists only on this stub, to give the mutant below (applied directly to
-- init.lua's process_room, never to this file) something to consult.
explore_state.active = true
explore_steps = { "n" }
explore_taken = {}
explore_state.leaving = false
sw_steps = { { raw = "SHOULD-NOT-RUN", commands = { "SHOULD-NOT-RUN" } } }
arrive(960, "A muddy field", { "a stray wolf" }, {})
sent = {}
quiet(function() as.start(false) end)
explore_state.leaving = true
sent = {}
arrival_prompt()
check("a monster met on the way out is still attacked",
  last_sent() == "kill a stray wolf", table.concat(sent, "|"))
explore_state.leaving = false
quiet(as.stop)

-- ---- stopping the stepper stops the explorer ---------------------------------
-- Explore mode is dead reckoned: it believes it knows where it is only because
-- it emitted every move itself. Left active across a stop, the next "-."
-- resumes that reckoning -- and the combat that goes with it -- wherever the
-- player is now standing, which after walking out of the area is anywhere.
explore_state.active = true
quiet(as.stop)
check("stopping the stepper deactivates explore mode",
  explore_state.active == false, tostring(explore_state.active))

explore_state.active = false
as.debug_set_explore(nil)

-- ---- Char.Combat drives the combat cycle -------------------------------------
-- Char.Combat says when a fight ends; Room.Refresh then asks the server what
-- is actually in the room, so a mob that survives its round is re-attacked
-- instead of abandoned (the headline fix this task exists for). These cases
-- pin the cycle end to end, using the fake roominfo/gmcp stubs above.
quiet(as.stop)
run_timers()
gmcp_sent = {}
gmcp_send_result = true
sw_steps = { { raw = "n", commands = { "n" } } }
sw_taken = {}
arrive(500, "A muddy field", { "an orc" }, {})
sent = {}
quiet(function() as.start(false) end)
-- Item 1 makes M.start itself send one Room.Refresh; reset here so the
-- checks below (which pin the ABSENCE of a refresh mid-fight) are not
-- reading that start-time send instead of a real regression.
gmcp_sent = {}
sent = {}
prompt_cycle()
check("gmcp cycle: attacks the monster", last_sent() == "kill an orc",
  table.concat(sent, "|"))

-- A Char.Combat frame WITH an attacker just says the fight continues. It must
-- latch the source (so the prompt path stands down) without ending anything
-- and without asking for a refresh.
sent = {}
quiet(function()
  deliver_combat({ attacker = "an orc", attacker_hp = 80, rounds = 1, target = "you" })
end)
check("an in-progress Char.Combat frame does not end the fight",
  #sent == 0, table.concat(sent, "|"))
check("an in-progress frame does not request a refresh",
  #gmcp_sent == 0, tostring(#gmcp_sent))

-- Kills: removing the latch check from the prompt path. With the source
-- latched, an ordinary prompt arriving mid-fight (the round's own output, or
-- anything matching the prompt pattern) must not end the fight, and must not
-- go around Char.Combat to ask for a refresh either.
sent = {}
gmcp_sent = {}
quiet(as.prompt)
check("with the latch set, a prompt mid-fight does not end the fight",
  #sent == 0, table.concat(sent, "|"))
check("a plain prompt does not trigger a Room.Refresh",
  #gmcp_sent == 0, tostring(#gmcp_sent))
check("the tracked view is unchanged while the latch stands the prompt down",
  #tracked() == 1 and tracked()[1] == "an orc", table.concat(tracked(), ","))

-- Combat actually ends: attacker absent. Kills: sending on every prompt
-- instead, or asking for more than Room.Contents.
gmcp_sent = {}
quiet(function() deliver_combat({ attacker = "", attacker_hp = 0, rounds = 0 }) end)
check("combat end sends exactly one Room.Refresh", #gmcp_sent == 1, tostring(#gmcp_sent))
check("the refresh asks only for Room.Contents",
  gmcp_sent[1] and gmcp_sent[1].pkg == "Room.Refresh"
    and type(gmcp_sent[1].data) == "table"
    and #gmcp_sent[1].data.packages == 1
    and gmcp_sent[1].data.packages[1] == "Room.Contents",
  gmcp_sent[1] and (gmcp_sent[1].pkg .. ":" .. table.concat(gmcp_sent[1].data.packages or {}, ",")))
check("a timer is armed while awaiting the answer", queued_timers() == 1,
  tostring(queued_timers()))

-- Kills: deciding from the pruned view instead of the answer. roominfo still
-- lists the orc (it survived its round), so the fresh answer must re-attack
-- it rather than stepping past it.
sent = {}
quiet(deliver_contents_frame)
check("an answer still listing the monster re-attacks it",
  last_sent() == "kill an orc", table.concat(sent, "|"))
check("the refresh timer is disarmed once answered", queued_timers() == 0,
  tostring(queued_timers()))

-- Second fight on the same orc, this time it dies: roominfo's answer no
-- longer lists it, so the decision must step.
gmcp_sent = {}
quiet(function() deliver_combat({ attacker = nil }) end)
check("a second combat end also sends exactly one Room.Refresh",
  #gmcp_sent == 1, tostring(#gmcp_sent))
ri_state.monsters = {}
sent = {}
quiet(deliver_contents_frame)
check("an answer no longer listing it steps", last_sent() == "n",
  table.concat(sent, "|"))

-- ---- handle_combat_end is guarded against re-entry (task-12 supplement 1) ---
-- A second no-attacker Char.Combat frame arriving before the first
-- Room.Refresh answers or times out must not send a second refresh: doing so
-- overwrites refresh_timeout_id and orphans the first timer with no
-- cancel_refresh_wait() ever run on it. The mudlib's "zero snapshot sent
-- once" guarantee is not load-bearing here -- gmcp_send_combat(1) is forced
-- from the reconnect/ready path and the subscription-transition path, and a
-- forced send bypasses the delta cache -- so this is a reachable duplicate,
-- not a hypothetical one.
run_timers()
gmcp_sent = {}
sw_steps = { { raw = "n", commands = { "n" } } }
sw_taken = {}
arrive(600, "A foggy marsh", { "a bog wraith" }, {})
sent = {}
quiet(function() as.start(false) end)
sent = {}
prompt_cycle()
check("reentrancy setup: attacks the monster", last_sent() == "kill a bog wraith",
  table.concat(sent, "|"))

gmcp_sent = {}
quiet(function() deliver_combat({ attacker = nil }) end)
check("first no-attacker frame sends exactly one Room.Refresh",
  #gmcp_sent == 1, tostring(#gmcp_sent))
check("one timer is queued after the first frame", queued_timers() == 1,
  tostring(queued_timers()))

-- A second no-attacker frame arrives before the first answers or times out.
quiet(function() deliver_combat({ attacker = nil }) end)
check("a second back-to-back no-attacker frame sends no additional refresh",
  #gmcp_sent == 1, tostring(#gmcp_sent))
check("exactly one timer remains queued, not two",
  queued_timers() == 1, tostring(queued_timers()))

-- The answer arrives: it must cancel the (only) outstanding timer, leaving
-- none behind to later fire prune_and_decide() during an unrelated fight.
ri_state.monsters = {}
sent = {}
quiet(deliver_contents_frame)
check("the answer steps once the room is empty", last_sent() == "n",
  table.concat(sent, "|"))
check("no timer remains after the answer", queued_timers() == 0,
  tostring(queued_timers()))

-- ---- gmcp.send returning false falls back immediately -----------------------
-- Kills: dropping the return-value check. Waiting out the timeout for a
-- request that was never sent is a stall with no cause to find later.
run_timers()
sw_steps = { { raw = "e", commands = { "e" } } }
sw_taken = {}
arrive(501, "A dry wash", { "a jackal" }, {})
sent = {}
quiet(function() as.start(false) end)
sent = {}
prompt_cycle()
check("send-false scenario: attacks the monster", last_sent() == "kill a jackal",
  table.concat(sent, "|"))

gmcp_send_result = false
gmcp_sent = {}
sent = {}
quiet(function() deliver_combat({ attacker = "" }) end)
check("gmcp.send is still attempted", #gmcp_sent == 1, tostring(#gmcp_sent))
check("gmcp.send returning false falls back immediately",
  sent[1] == "e", table.concat(sent, "|"))
check("no timer is left waiting for a request that was never sent",
  queued_timers() == 0, tostring(queued_timers()))
gmcp_send_result = true

-- ---- no answer within the timeout falls back -----------------------------
-- Kills: dropping the timeout. Over-budget refreshes are dropped silently
-- with no error payload, so a run that waited forever would be worse than one
-- that occasionally guesses wrong.
run_timers()
sw_steps = { { raw = "s", commands = { "s" } } }
sw_taken = {}
arrive(502, "A stone bridge", { "a troll" }, {})
sent = {}
quiet(function() as.start(false) end)
sent = {}
prompt_cycle()
check("timeout scenario: attacks the monster", last_sent() == "kill a troll",
  table.concat(sent, "|"))

gmcp_sent = {}
quiet(function() deliver_combat({ attacker = nil }) end)
check("timeout scenario: exactly one Room.Refresh sent",
  #gmcp_sent == 1, tostring(#gmcp_sent))
check("a timer is armed while waiting for the answer",
  queued_timers() == 1, tostring(queued_timers()))

sent = {}
run_timers()  -- fire the ~1s timeout; no Room.Contents answer ever arrives
check("no answer within the timeout falls back to prune-and-decide",
  sent[1] == "s", table.concat(sent, "|"))

quiet(as.stop)

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
