-- autostepper arrival-signal regression test. Run from the lera-plugins repo
-- root with LERA_ROOT pointing at a built Lera checkout.
--
-- Reproduces the live stall an owner's explore run hit: two consecutive rooms
-- sharing the same name, exits and Room.Info `num` -- so a real server
-- suppresses the second Room.Info as an identical resend -- differing only in
-- Room.Contents (the first room held a monster/player, the second did not, or
-- vice versa). With no prompt pattern configured, arrival used to be armed
-- from Room.Info alone (roominfo.on_room_info), so the second room's arrival
-- never completed: the run sat in state "stepping" forever.
--
-- This exercises the REAL roominfo.lua and the REAL autostepper/init.lua
-- together, not stand-ins for either, so it also proves Part 1
-- (roominfo.on_room_frame) and Part 2 (arming the settle timer from it) work
-- as integrated, not just each in isolation.
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
local clock = 1000
lera = { time = function() return clock end }

local sent = {}
mud = { send = function(cmd) sent[#sent + 1] = tostring(cmd) end }

-- Timer stand-in. A callback scheduled DURING run_timers() lands in a fresh
-- `timers` table (queued is swapped out before anything runs) and is not
-- fired until the NEXT explicit run_timers() call, so this can never recurse
-- or spin -- there is no way for a test bug here to turn into an actual hang.
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
local function run_timers()
  local queued = timers
  timers = {}
  local ids = {}
  for id in pairs(queued) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do queued[id]() end
end

local triggers = {}
trigger = {
  add = function(pattern, fn)
    triggers[#triggers + 1] = { pattern = pattern, fn = fn }
    return #triggers
  end,
  remove = function(id)
    if id and triggers[id] then triggers[id] = nil return true end
    return false
  end,
}

alias = {
  add = function() return 1 end,
  remove = function() return true end,
}

-- gmcp stand-in, shared by roominfo (Room.Info/Contents/Map) and autostepper
-- (Char.Combat) -- the same pattern roominfo_test.lua uses, since both
-- modules register under distinct package names.
local gmcp_handlers = {}
gmcp = {
  on = function(pkg, fn) gmcp_handlers[pkg] = fn; return pkg end,
  remove = function() return true end,
  send = function() return true end,
}

local function deliver(pkg, data)
  local fn = gmcp_handlers[pkg]
  if not fn then return false end
  fn(pkg, data)
  return true
end

-- plugin.get: the real roominfo module for "roominfo" (set below, once
-- required); a bare truthy table for "speedwalk" -- autostepper's M.start
-- only touches it in the route-mode branch, which this test's explore run
-- never takes.
local ri  -- assigned below; referenced here as an upvalue
plugin = {
  get = function(name)
    if name == "roominfo" then return ri end
    if name == "speedwalk" then return {} end
    return nil
  end,
}

local printed = {}
local print_real = print
local function quiet(fn, ...)
  print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    printed[#printed + 1] = table.concat(parts, " ")
  end
  local ok, err = pcall(fn, ...)
  print = print_real
  if not ok then error(err, 0) end
end

-- ---- load the real modules ---------------------------------------------------
ri = require("roominfo")
quiet(ri.on_load)

local explore = require("explore.mode")
local as = require("init")
quiet(as.on_load)

-- ---- a minimal area profile --------------------------------------------------
-- Same shape as the one in autostepper_explore_test.lua's engine-tier cases;
-- declared here rather than required so this suite does not depend on
-- areas/chaossea.lua, which is real area DATA, not part of this engine
-- behaviour.
local profile = {
  name = "test-suppressed",
  exclude_exits = { out = true },
  dive_dirs = {},
  defer_dirs = {},
  default_policy = "clear",
  in_area = function(name)
    return type(name) == "string" and name:lower():find("sea of chaos", 1, true) ~= nil
  end,
  layer_of = function() return 2 end,
  targets = {},
}

-- ---- room A: the origin -------------------------------------------------------
-- Empty room (no players, no monsters). num 60494 is the Chaos Sea's
-- per-character constant -- every room in the area reports it -- which is
-- exactly what makes two different rooms' Room.Info payloads identical.
local ROOM_INFO = { num = 60494, area = "Unknown",
  name = "Layer two of the Sea of Chaos", exits = { s = 60494 } }
deliver("Room.Info", ROOM_INFO)
deliver("Room.Contents", { full = 1, items = {} })

explore.attach(ri)
check("explore starts", explore.start(profile, "clear") == true)

quiet(as.start)
check("run starts stepping", as.get_state() == "stepping", tostring(as.get_state()))

-- M.start() re-asks the MUD for the room it is already standing in (a forced
-- Room.Refresh); answer it exactly like room A above -- both packages arrive,
-- so this first arrival is the ordinary case, not yet the stall.
deliver("Room.Info", ROOM_INFO)
deliver("Room.Contents", { full = 1, items = {} })
run_timers()
check("origin arrival completes and takes the first step",
  as.get_state() == "stepping" and #sent == 1,
  tostring(as.get_state()) .. "/" .. #sent)
check("first step is south", sent[1] == "s", tostring(sent[1]))

-- ---- room B: the stall ---------------------------------------------------------
-- Same name, same exits, same num as room A -- so a real server suppresses
-- this Room.Info as an identical resend. No Room.Info is delivered at all,
-- simulating exactly that. The only signal for this room is Room.Contents,
-- which differs (a player has appeared) and is therefore sent.
deliver("Room.Contents", { full = 1, items = {
  { name = "Bob", type = "player", count = 1 },
} })

-- Old behaviour: roominfo.on_room_info was the only thing that armed the
-- settle timer, and it never fires for this room, so nothing is ever queued
-- and the run sits in "stepping" forever -- the owner's exact stall. This is
-- a bounded drain, not a `while state == "stepping" do ... end` poll: under
-- the old bug nothing here can make further progress, so an unbounded loop
-- would hang this suite exactly as the real session hung. Capped at 3 rounds,
-- generously more than the single round one settle timer ever needs.
local ARRIVAL_CAP = 3
for _ = 1, ARRIVAL_CAP do
  if #sent >= 2 then break end
  run_timers()
end

check("the suppressed-Info room's arrival still completes and a second step is taken",
  #sent == 2, tostring(#sent))
check("second step is south again", sent[2] == "s", tostring(sent[2]))
check("state is stepping again, not stuck idle-less in the old stall",
  as.get_state() == "stepping", tostring(as.get_state()))

-- ---- room C: Info AND Contents both suppressed, only Room.Map differs -------
-- Same name/exits/num as room B (Info suppressed again) and the same occupant
-- list as room B (Contents suppressed too -- still just Bob, so nothing new
-- to send). Room.Map is '@'-centred and changes on virtually every move, so
-- it is the one package still delivered.
deliver("Room.Map", {
  kind = "los", w = 3, h = 1, rows = { "O-@" }, legend = {},
  up = 0, down = 0, enter = 0,
})

for _ = 1, ARRIVAL_CAP do
  if #sent >= 3 then break end
  run_timers()
end

check("a Room.Map-only arrival (Info and Contents both suppressed) still completes",
  #sent == 3, tostring(#sent))
check("third step is south again", sent[3] == "s", tostring(sent[3]))

-- ---- explore.on_frame is fed from Room.Info alone, never the generic signal ---
-- The subtlety Part 2 calls out by name: only settle ARMING should move to
-- on_room_frame. explore.on_frame must keep receiving exits from Room.Info
-- alone -- if it also ran on Contents/Map, a Contents-only arrival (Info
-- suppressed) would re-record exits at the new coordinate from a call that
-- was never told about this room. In THIS suite's own maze that call happens
-- to carry the same (correct, suppression-implied) value, so the scenario
-- above cannot distinguish the two wirings by VALUE. This checks it directly
-- by COUNT instead, with a spy standing in for explore.
quiet(as.stop)
run_timers()

local on_frame_calls = 0
local spy_active = true
local spy = {
  active = function() return spy_active end,
  on_frame = function() on_frame_calls = on_frame_calls + 1 end,
  on_arrival = function() end,
  next_step = function() return { raw = "s", commands = { "s" } } end,
  room_key = function() return "spy" end,
  stats = function() return { policy = "clear" } end,
  stop = function() spy_active = false end,
  stop_reason = function() return "exhausted" end,
}
as.debug_set_explore(spy)

quiet(as.start)
check("no on_frame call yet: M.start() only waits, it does not feed a frame",
  on_frame_calls == 0, tostring(on_frame_calls))

-- The origin's forced Room.Refresh answer: one Info, one Contents, both for
-- the same room.
deliver("Room.Info", ROOM_INFO)
deliver("Room.Contents", { full = 1, items = {} })
run_timers()
check("spy sees exactly one on_frame call for the origin's Info",
  on_frame_calls == 1, tostring(on_frame_calls))

-- The suppressed-Info room again, this time observed through the spy:
-- Contents only, no Info at all.
deliver("Room.Contents", { full = 1, items = {
  { name = "Bob", type = "player", count = 1 },
} })
run_timers()
check("a Contents-only arrival does not add a second on_frame call",
  on_frame_calls == 1, tostring(on_frame_calls))

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
