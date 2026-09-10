-- Autostepper GMCP integration regressions: real plugins, simulated I/O and time.
package.path = "3scapes/autostepper/?.lua;3scapes/?.lua;generic/?.lua;" .. package.path

local function engine()
  for _, name in ipairs({"roominfo", "init", "explore.mode", "areas.chaossea"}) do
    package.loaded[name] = nil
  end
  local E = { sent = {}, logs = {}, requests = {}, now = 0 }
  local handlers, timers, triggers = {}, {}, {}
  local next_id = 0
  lera = { time = function() return E.now / 1000 end }
  mud = { send = function(cmd) E.sent[#E.sent + 1] = cmd end }
  buffer = { color_print = function(...)
    local parts = {}
    for i = 3, select("#", ...), 3 do parts[#parts + 1] = tostring(select(i, ...)) end
    E.logs[#E.logs + 1] = table.concat(parts)
  end }
  timer = {
    after = function(ms, fn)
      next_id = next_id + 1
      timers[next_id] = { at = E.now + ms, fn = fn }
      return next_id
    end,
    cancel = function(id) timers[id] = nil end,
  }
  function E.advance(ms)
    local finish = E.now + ms
    for _ = 1, 100 do
      local chosen, due
      for id, t in pairs(timers) do
        if t.at <= finish and (not due or t.at < due) then chosen, due = id, t.at end
      end
      if not chosen then E.now = finish; return end
      local t = timers[chosen]
      timers[chosen] = nil
      E.now = due
      t.fn()
    end
    error("timer loop")
  end
  trigger = {
    add = function(pattern, fn)
      next_id = next_id + 1
      triggers[next_id] = { pattern = pattern, fn = fn }
      return next_id
    end,
    remove = function(id) triggers[id] = nil end,
  }
  E.triggers = triggers
  function E.no_target(name)
    for _, t in pairs(triggers) do
      if t.pattern:find("There is no", 1, true) then t.fn(nil, name) end
    end
  end
  alias = { add = function() return 1 end, remove = function() end }
  gmcp = {
    on = function(pkg, fn) handlers[pkg] = fn; return pkg end,
    remove = function(pkg) handlers[pkg] = nil end,
    send = function(pkg, data)
      E.requests[#E.requests + 1] = { pkg = pkg, data = data }
      return true
    end,
  }
  function E.deliver(pkg, data) assert(handlers[pkg], pkg)(pkg, data) end
  local ri
  plugin = { get = function(name)
    if name == "roominfo" then return ri end
    if name == "speedwalk" then return {
      step_info = function() return {current = 0, total = 0, remaining = 0} end,
      get_current_place = function() return "test route" end,
      get_targets = function() return {} end,
      load_steps = function() return E.routes and #E.routes > 0 end,
      take_step = function() return table.remove(E.routes, 1) end,
    } end
  end }
  ri = require("roominfo")
  local output = print
  print = function() end
  ri.on_load()
  print = output
  E.ri, E.mode, E.as = ri, require("explore.mode"), require("init")
  E.as.on_load()
  function E.info(exits)
    E.deliver("Room.Info", {num = 0, name = "Layer one of the Sea of Chaos", exits = exits})
  end
  function E.contents(monsters, players, entry, items)
    local entries = {}
    for _, name in ipairs(monsters or {}) do
      entries[#entries + 1] = {name = name, type = "monster", count = 1}
    end
    for _, name in ipairs(players or {}) do
      entries[#entries + 1] = {name = name, type = "player", count = 1}
    end
    for _, name in ipairs(items or {}) do
      entries[#entries + 1] = {name = name, type = "item", count = 1}
    end
    E.deliver("Room.Contents", {full = 1, items = entries, entry = entry and 1 or nil})
  end
  function E.begin(exits, monsters, targets_only, players)
    E.info(exits); E.contents(monsters, players)
    assert(E.as.explore_start("chaossea"))
    assert(E.as.start(targets_only))
    E.info(exits); E.contents(monsters, players)
  end
  function E.blocked()
    for _, t in pairs(triggers) do
      if t.pattern:find("blocks your way", 1, true) then
        t.fn("A growing mutant being blocks your way!")
        return true
      end
    end
    return false
  end
  function E.pos()
    local s = E.mode.stats()
    return s.x .. "," .. s.y .. "," .. s.z
  end
  return E
end

local failures, checks = 0, 0
local function check(name, ok)
  checks = checks + 1
  if not ok then failures = failures + 1 end
  print("CASE " .. name .. ": " .. (ok and "PASS" or "FAIL"))
end

do
  local e = engine()
  check("prompt APIs are removed", e.as.prompt == nil and e.as.set_prompt_pattern == nil)
  e.begin({n = 0}, {})
  check("initial refresh completes without prompts or timers", e.sent[1] == "n")
  e.info({s = 0, e = 0})
  e.advance(1600)
  check("Info and elapsed settle delays cannot complete a move", #e.sent == 1 and e.pos() == "0,0,0")
  e.deliver("Room.Map", {w = 1, h = 1, rows = {"@"}})
  check("Map cannot complete a move", #e.sent == 1)
  e.contents({"A growing mutant being"}, nil, true)
  check("late contents attacks the mob in the arrived room", e.sent[2] == "kill mutant" and e.pos() == "0,1,0")
  e.advance(1600)
  check("no delayed arrival timer moves during combat", #e.sent == 2 and e.as.get_state() == "fighting")
end

do
  local e = engine()
  e.begin({n = 0, s = 0}, {})
  e.contents({}, nil, false)
  check("an unrelated refresh cannot acknowledge a move", #e.sent == 1 and e.pos() == "0,0,0")
  e.contents({}, nil, true)
  check("identical entry contents still commits exactly one room", #e.sent == 2 and e.pos() == "0,1,0")
  e.deliver("Room.Map", {w = 1, h = 1, rows = {"@"}})
  check("trailing Map cannot acknowledge the following move", #e.sent == 2 and e.pos() == "0,1,0")
end

do
  local e = engine()
  e.begin({n = 0}, {})
  e.info({s = 0})
  e.deliver("Room.Contents", {full = 1, entry = 1, page = 1, pages = 2,
    items = {{type = "item", name = "A rusty sword"}}})
  e.advance(1600)
  check("a partial contents list cannot complete arrival", #e.sent == 1 and e.pos() == "0,0,0")
  e.deliver("Room.Contents", {full = 1, entry = 1, page = 2, pages = 2,
    items = {{type = "monster", name = "A growing mutant being"}}})
  check("final contents page commits and attacks", e.sent[2] == "kill mutant" and e.pos() == "0,1,0")
  check("roominfo retains the entry marker across paging", e.ri.info().entry == true)
end

do
  local e = engine()
  e.begin({n = 0, s = 0}, {"A growing mutant being"}, false, {"OtherPlayer"})
  check("blocked response handler exists", e.blocked())
  e.advance(5000)
  check("blocked movement stops with confirmed coordinates", not e.as.is_running() and e.pos() == "0,0,0")
  e.advance(10000)
  e.contents({}, nil, false)
  check("blocked movement leaves no callbacks that resume walking", #e.sent == 1 and e.pos() == "0,0,0")
end

do
  local e = engine()
  e.begin({n = 0}, {})
  e.blocked() -- Chaossea warns even when a wizard is allowed to pass.
  e.info({s = 0})
  e.contents({"A growing mutant being"}, nil, true)
  check("successful wizard entry wins over the blocking warning", e.pos() == "0,1,0" and e.sent[2] == "kill mutant")
end

do
  local e = engine()
  e.begin({n = 0}, {})
  e.info({s = 0})
  e.deliver("Room.Contents", {full = 1, entry = 1, page = 1, pages = 2, items = {}})
  e.deliver("Room.Contents", {full = 1, page = 2, pages = 2, items = {}})
  check("mismatched entry markers cannot complete a paged arrival", #e.sent == 1 and e.pos() == "0,0,0")
end

do
  local e = engine()
  e.begin({n = 0}, {})
  e.advance(10000)
  check("missing arrival stops instead of advancing the map", not e.as.is_running() and e.pos() == "0,0,0" and #e.sent == 1)
  e.contents({}, nil, true)
  check("late entry cannot restart a timed-out run", #e.sent == 1 and not e.as.is_running())
end

do
  local e = engine()
  e.deliver("Char.Combat", {attacker = ""})
  e.begin({n = 0}, {"A growing mutant being"})
  e.advance(1600)
  check("starting a run cannot prune a target without combat events", #e.sent == 1 and e.sent[1] == "kill mutant" and #e.as.tracked_monsters() == 1)
  e.deliver("Char.Combat", {attacker = "A growing mutant being"})
  e.deliver("Char.Combat", {attacker = ""})
  e.contents({"A growing mutant being"}, nil, false)
  check("combat refresh reattacks a surviving monster", e.sent[2] == "kill mutant")
  e.deliver("Char.Combat", {attacker = "A growing mutant being"})
  e.deliver("Char.Combat", {attacker = ""})
  e.contents({}, nil, false)
  check("combat refresh confirming empty room permits movement", e.sent[3] == "n")
  check("combat refresh is not also a movement arrival", e.pos() == "0,0,0")
end

-- Refresh replies can arrive after the former one-second deadline. Keep
-- combat unresolved until a complete reply arrives, with bounded retries.
do
  local e = engine()
  e.begin({n = 0}, {"A growing mutant being"})
  local initial_requests = #e.requests
  e.deliver("Char.Combat", {attacker = ""})
  e.advance(1200)
  e.no_target("reason to 'dg'")
  check("a delayed refresh keeps the target and ignores unrelated no-target text",
    e.as.is_running() and #e.sent == 1 and #e.as.tracked_monsters() == 1)
  check("ordinary latency does not send a premature retry", #e.requests == initial_requests + 1)
  e.contents({}, nil, false)
  check("a reply after one second still permits exactly one move", #e.sent == 2 and e.sent[2] == "n" and e.pos() == "0,0,0")
end

do
  local e = engine()
  e.begin({n = 0}, {"A growing mutant being"})
  local initial_requests = #e.requests
  e.deliver("Char.Combat", {attacker = ""})
  e.advance(2999)
  check("combat refresh waits three seconds before retrying", e.as.is_running() and #e.requests == initial_requests + 1)
  e.advance(1)
  check("first timeout retries without moving or discarding the target",
    #e.requests == initial_requests + 2 and #e.sent == 1 and #e.as.tracked_monsters() == 1 and e.as.is_running())
  e.deliver("Char.Combat", {attacker = ""})
  check("duplicate combat-end frames do not add retries", #e.requests == initial_requests + 2)
  e.advance(3000)
  check("second timeout sends the final refresh attempt", #e.requests == initial_requests + 3 and e.as.is_running())
  for i = initial_requests + 1, #e.requests do
    local req = e.requests[i]
    check("refresh attempt " .. (i - initial_requests) .. " requests Contents only",
      req.pkg == "Room.Refresh" and #req.data.packages == 1 and req.data.packages[1] == "Room.Contents")
  end
  e.advance(3000)
  check("exhausted refresh attempts stop with the possible live target intact",
    not e.as.is_running() and #e.sent == 1 and #e.as.tracked_monsters() == 1 and e.pos() == "0,0,0")
  e.contents({}, nil, false)
  e.advance(30000)
  check("late replies cannot restart an exhausted refresh", not e.as.is_running() and #e.sent == 1 and #e.requests == initial_requests + 3)
end

do
  local e = engine()
  e.begin({n = 0}, {"A growing mutant being"})
  local initial_requests = #e.requests
  e.deliver("Char.Combat", {attacker = ""})
  e.advance(3000)
  e.contents({"A growing mutant being"}, nil, false)
  check("a retry reply reattacks a surviving monster", #e.sent == 2 and e.sent[2] == "kill mutant")
  e.advance(10000)
  check("an answered retry leaves no timer that interrupts the new fight", e.as.is_running() and #e.requests == initial_requests + 2 and #e.sent == 2)
  e.deliver("Char.Combat", {attacker = ""})
  e.advance(6000)
  check("the next combat gets a fresh retry budget", e.as.is_running() and #e.requests == initial_requests + 5)
  e.contents({}, nil, false)
  e.contents({}, nil, false)
  check("duplicate retry replies do not acknowledge the next movement", #e.sent == 3 and e.sent[3] == "n" and e.pos() == "0,0,0")
end

do
  local e = engine()
  e.begin({n = 0}, {"A growing mutant being"})
  local send, attempts = gmcp.send, 0
  gmcp.send = function(pkg, data)
    local sent = send(pkg, data)
    attempts = attempts + 1
    if attempts == 2 then e.contents({}, nil, false) end
    return sent
  end
  e.deliver("Char.Combat", {attacker = ""})
  e.advance(3000)
  check("a synchronous retry reply moves once", attempts == 2 and #e.sent == 2 and e.sent[2] == "n")
  e.info({s = 0}); e.contents({"A growing mutant being"}, nil, true)
  e.advance(10000)
  check("a synchronous reply cancels the retry timer before the next fight", e.as.is_running() and attempts == 2 and #e.sent == 3)
end

for _, action in ipairs({"stop", "on_disconnect", "on_unload"}) do
  local e = engine()
  e.begin({n = 0}, {"A growing mutant being"})
  e.deliver("Char.Combat", {attacker = ""})
  e.advance(3000)
  local requests = #e.requests
  e.as[action]()
  e.advance(30000)
  check(action .. " cancels pending refresh retries", not e.as.is_running() and #e.requests == requests and #e.sent == 1)
end

do
  local e = engine()
  e.begin({n = 0}, {"A growing mutant being"})
  e.deliver("Char.Combat", {attacker = ""})
  local retries = 0
  gmcp.send = function() retries = retries + 1; return false end
  e.advance(30000)
  check("a refused retry stops immediately and retains the target", retries == 1 and not e.as.is_running() and #e.sent == 1 and #e.as.tracked_monsters() == 1)
end

do
  local e = engine()
  e.begin({n = 0}, {"A growing mutant being"})
  e.deliver("Char.Combat", {attacker = ""})
  e.deliver("Room.Contents", {full = 1, page = 1, pages = 2, items = {}})
  e.advance(3000)
  check("a partial refresh cannot finish combat during retries", e.as.is_running() and #e.sent == 1 and #e.as.tracked_monsters() == 1)
  e.deliver("Room.Contents", {full = 1, page = 2, pages = 2, items = {}})
  check("the final page of a delayed refresh permits movement", #e.sent == 2 and e.sent[2] == "n")
end

do
  local e = engine()
  e.begin({n = 0}, {"A growing mutant being"})
  e.deliver("Char.Combat", {attacker = ""})
  e.advance(3000)
  local requests = #e.requests
  e.contents({}, nil, true)
  e.advance(30000)
  check("room entry during refresh retries stops instead of using another room", not e.as.is_running() and #e.requests == requests and #e.sent == 1 and e.pos() == "0,0,0")
end

do
  local e = engine()
  e.routes = {{raw = "2n", commands = {"n", "n"}}, {raw = "e", commands = {"e"}}}
  e.info({n = 0}); e.contents({})
  local callbacks = 0
  e.as.on_step(function() callbacks = callbacks + 1 end)
  e.as.start(false); e.contents({})
  check("compound route sends only its first movement", table.concat(e.sent, ",") == "n")
  e.deliver("Room.Info", {num = 1, name = "First route room", exits = {n = 0, s = 0}})
  e.contents({"A growing mutant being"}, nil, true)
  check("compound route fights before queuing another movement", table.concat(e.sent, ",") == "n,kill being")
  e.deliver("Char.Combat", {attacker = ""})
  e.contents({}, nil, false)
  check("compound route continues after combat refresh", table.concat(e.sent, ",") == "n,kill being,n")
  e.deliver("Room.Info", {num = 2, name = "Second route room", exits = {s = 0, e = 0}})
  e.contents({}, nil, true)
  check("next route segment waits for the final compound arrival", e.sent[4] == "e" and #e.sent == 4)
  check("compound route preserves one callback per authored segment", callbacks == 2)
end

do
  local e = engine()
  e.begin({n = 0, s = 0}, {})
  e.blocked()
  check("repeated start refuses an already running move", e.as.start(false) == false)
  e.contents({}, nil, false)
  check("repeated start cannot refresh a blocked move into success", e.pos() == "0,0,0" and #e.sent == 1)
end

do
  local e = engine()
  e.deliver("Room.Info", {num = 400, name = "Outside the Sea", exits = {}})
  e.contents({})
  e.as.chaossea_setup(0, "risky")
  check("setup sends its commands without a stale initial refresh", #e.sent == 5 and #e.requests == 0)
  e.deliver("Room.Info", {num = 401, name = "The portal shore", exits = {}})
  e.contents({}, nil, true)
  check("setup ignores intermediate entry outside the Sea", #e.sent == 5 and e.as.is_running())
  e.info({n = 0}); e.contents({"A growing mutant being"}, nil, false)
  check("setup ignores an unmarked snapshot of an old instance", #e.sent == 5)
  e.contents({"A growing mutant being"}, nil, true)
  check("setup starts fighting on the confirmed Sea entry", e.sent[6] == "kill mutant" and e.pos() == "0,0,0")
end

do
  local e = engine()
  local send = mud.send
  mud.send = function(cmd)
    send(cmd)
    if cmd == "n" then
      e.info({s = 0})
      e.contents({"A growing mutant being"}, nil, true)
    end
  end
  e.begin({n = 0}, {})
  check("movement wait is armed before sending its command", table.concat(e.sent, ",") == "n,kill mutant" and e.pos() == "0,1,0")
end

do
  local e = engine()
  e.routes = {{raw = "(open door)n", commands = {"open door", "n"}}}
  e.info({n = 0}); e.contents({})
  e.as.start(false); e.contents({})
  check("route sends preparatory commands before its movement", table.concat(e.sent, ",") == "open door,n")
  e.deliver("Room.Info", {num = 1, name = "Beyond the door", exits = {s = 0}})
  e.contents({"A growing mutant being"}, nil, true)
  check("mixed route processes the movement's actual contents", e.sent[3] == "kill being")
end

do
  local e = engine()
  e.routes = {{raw = "open door", commands = {"open door"}}, {raw = "n", commands = {"n"}}}
  e.info({n = 0}); e.contents({})
  e.as.start(false); e.contents({})
  check("a preparatory-only route segment does not wait for impossible entry", table.concat(e.sent, ",") == "open door,n")
end

do
  local e = engine()
  e.routes = {{raw = "(enter portal)n", commands = {"enter portal", "n"}}}
  e.info({n = 0}); e.contents({})
  e.as.start(false); e.contents({})
  check("unfamiliar custom commands require entry before another move", table.concat(e.sent, ",") == "enter portal")
end

-- The captured run reached these items, killed the boss, then walked away
-- because the origin still had unexplored exits. Completion must win before
-- the next frontier is selected, after a full contents list clears the room.
local cask = "A cask of chaotic energy (closed)"
local portal = "A glowing portal (swirling chaotically)"
local boss = "A whirling monstrosity with three tentacles"

do
  local e = engine()
  local completed = 0
  e.as.on_complete(function() completed = completed + 1 end)
  e.begin({n = 0, e = 0}, {})
  e.info({s = 0})
  e.contents({boss}, nil, true, {cask, portal})
  check("cask arrival fights its boss before completing", table.concat(e.sent, ",") == "n,kill mutant" and e.as.is_running() and completed == 0)
  e.deliver("Char.Combat", {attacker = ""})
  e.deliver("Room.Contents", {full = 1, page = 1, pages = 2,
    items = {{name = cask, type = "item", count = 1}}})
  check("cask on a partial combat refresh cannot complete the run", #e.sent == 2 and e.as.is_running() and completed == 0)
  e.deliver("Room.Contents", {full = 1, page = 2, pages = 2,
    items = {{name = boss, type = "monster", count = 1}}})
  check("a surviving boss beside the cask is fought again", e.sent[3] == "kill mutant" and e.as.is_running() and completed == 0)
  e.deliver("Char.Combat", {attacker = ""})
  e.contents({}, nil, false, {cask, portal})
  check("clearing the cask room stops before backtracking to other unexplored exits", not e.as.is_running() and not e.mode.active() and #e.sent == 3 and e.pos() == "0,1,0")
  check("cask completion notifies once", completed == 1)
  check("cask completion reports the destination instead of exhausted exits", table.concat(e.logs, "\n"):find("Chaos Sea complete: cask/portal reached", 1, true) ~= nil)
  e.contents({}, nil, false, {cask, portal})
  e.advance(10000)
  check("duplicate contents and old timers cannot resume a completed cask run", not e.as.is_running() and #e.sent == 3 and completed == 1)
end

for _, item in ipairs({cask, portal}) do
  local e = engine()
  e.begin({n = 0, e = 0}, {})
  e.info({s = 0, n = 0})
  e.contents({}, nil, true, {item})
  check(item .. " stops an empty destination room immediately", not e.as.is_running() and #e.sent == 1 and e.pos() == "0,1,0")
end

do
  local e = engine()
  e.info({n = 0}); e.contents({}, nil, false, {cask})
  assert(e.as.explore_start("chaossea"))
  assert(e.as.start(false))
  e.contents({}, nil, false, {cask})
  check("starting at the cleared cask completes without moving", not e.as.is_running() and #e.sent == 0)
end

for _, cancel in ipairs({false, true}) do
  local e = engine()
  e.deliver("Room.Info", {num = 400, name = "Outside the Sea", exits = {}})
  e.contents({})
  assert(e.as.chaossea_farm_start(5, "risky"))
  e.info({n = 0, e = 0}); e.contents({}, nil, true)
  e.info({s = 0}); e.contents({boss}, nil, true, {cask, portal})
  e.advance(1000)
  check("farm waits for the cask room's boss before restarting", #e.sent == 7 and e.sent[7] == "kill mutant" and e.as.is_running())
  e.deliver("Char.Combat", {attacker = ""})
  e.contents({}, nil, false, {cask, portal})
  check("farm completes at the cask with unexplored exits remaining", not e.as.is_running() and #e.sent == 7)
  e.contents({}, nil, false, {cask, portal})
  if cancel then e.as.stop() end
  e.advance(1000)
  if cancel then
    check("stop cancels the pending farm restart at the cask", not e.as.is_running() and #e.sent == 7)
  else
    check("farm schedules one next instance from the cask", #e.sent == 12 and table.concat(e.sent, ",", 8) == "open cask,enter portal,unsetsea,setsea 5 risky,enter sea" and e.as.is_running())
  end
end

-- The server may omit the boss when a crowded room hits its inventory cap.
-- Receiving every page of that truncated list does not establish a clear room.
for _, farm in ipairs({false, true}) do
  for _, after_combat in ipairs({false, true}) do
    local e = engine()
    local completed = 0
    e.as.on_complete(function() completed = completed + 1 end)
    if farm then
      e.deliver("Room.Info", {num = 400, name = "Outside the Sea", exits = {}})
      e.contents({})
      assert(e.as.chaossea_farm_start(5, "risky"))
      e.info({n = 0, e = 0}); e.contents({}, nil, true)
    else
      e.begin({n = 0, e = 0}, {})
    end
    e.info({s = 0})
    if after_combat then
      e.contents({boss}, nil, true, {cask})
      e.deliver("Char.Combat", {attacker = ""})
    end
    local sent = #e.sent
    local pages = {{}, {}}
    for i = 1, 64 do
      local page = i <= 32 and 1 or 2
      pages[page][#pages[page] + 1] = {
        name = i == 1 and cask or ("a trinket " .. i), type = "item", count = 1,
      }
    end
    local label = (farm and "farm" or "ordinary")
      .. (after_combat and " combat refresh" or " entry")
    e.deliver("Room.Contents", {full = 1, page = 1, pages = 2,
      entry = not after_combat and 1 or nil, truncated = 1, items = pages[1]})
    e.deliver("Room.Contents", {full = 1, page = 2, pages = 2,
      entry = not after_combat and 1 or nil, items = pages[2]})
    check(label .. ": truncated cask contents stop without completing", not e.as.is_running() and completed == 0 and #e.sent == sent)
    check(label .. ": truncated cask contents explain the stop", table.concat(e.logs, "\n"):find("contents are truncated", 1, true) ~= nil)
    e.advance(10000)
    check(label .. ": truncated cask contents cannot restart movement or farming", not e.as.is_running() and completed == 0 and #e.sent == sent)
  end
end

for _, farm in ipairs({false, true}) do
  local old_store = store
  store = {
    load = function() return true end,
    get = function() return {ignored_monsters = {["a gentle guide"] = true}} end,
  }
  local e = engine()
  store = old_store
  if farm then
    e.deliver("Room.Info", {num = 400, name = "Outside the Sea", exits = {}})
    e.contents({})
    assert(e.as.chaossea_farm_start(5, "risky"))
    e.info({n = 0, e = 0}); e.contents({}, nil, true)
  else
    e.begin({n = 0, e = 0}, {})
  end
  local sent = #e.sent
  e.info({s = 0})
  e.contents({"A gentle guide", boss}, nil, true, {cask})
  check("cask completion still fights a non-ignored boss", e.sent[sent + 1] == "kill mutant" and e.as.is_running())
  e.deliver("Char.Combat", {attacker = ""})
  e.contents({"A gentle guide"}, nil, false, {cask})
  check((farm and "farm" or "ordinary") .. " cask completion excludes ignored mobs", not e.as.is_running() and #e.sent == sent + 1)
  e.advance(1000)
  if farm then
    check("farm restarts when only ignored mobs remain beside the cask", #e.sent == sent + 6 and e.sent[sent + 2] == "open cask")
  else
    check("ordinary cask run stays stopped beside an ignored mob", #e.sent == sent + 1 and not e.as.is_running())
  end
end

print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
