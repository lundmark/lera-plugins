-- Offline combat notification tests: real producer and push consumer, fake
-- GMCP, clock, timers, storage and transport. No network or profile access.
package.path = "3scapes/?.lua;generic/?.lua;" .. package.path

local checks = 0
local function check(name, ok)
  assert(ok, name)
  checks = checks + 1
end

local now, connected, gmcp_enabled = 1000, true, true
local handlers, timers, commands = {}, {}, {}
local next_id = 0
local function id() next_id = next_id + 1; return next_id end
lera = { time = function() return now end }
mud = { connected = function() return connected end }
gmcp = {
  enabled = function() return gmcp_enabled end,
  on = function(pkg, fn)
    local key = id()
    handlers[key] = { pkg = pkg, fn = fn }
    return key
  end,
  remove = function(key) handlers[key] = nil end,
}
timer = {
  every = function(ms, fn)
    check("one-second heartbeat", ms == 1000)
    local key = id()
    timers[key] = fn
    return key
  end,
  cancel = function(key) timers[key] = nil end,
}
package.preload.command = function() return {
  register = function(spec)
    check("no duplicate commands", commands[spec.name] == nil)
    commands[spec.name] = spec
    return spec.name
  end,
  unregister = function(key) commands[key] = nil end,
} end

-- Lera gives each plugin its own store. Swap it only when invoking a consumer
-- operation that accesses storage; the producer always uses producer_store.
local producer_data, consumer_data, saves = nil, nil, 0
local producer_store = {
  load = function() end, get = function() return producer_data end,
  set = function(value) producer_data = value end,
  save = function() saves = saves + 1 end,
}
local consumer_store = {
  load = function() end, get = function() return consumer_data end,
  set = function(value) consumer_data = value end, save = function() end,
}
store = producer_store

local sent, recorded = {}, {}
local push_enabled, limited, queue_full = true, false, false
push = {
  init = function() end, set_rate_limit = function() end,
  enable = function() push_enabled = true end,
  disable = function() push_enabled = false end,
  enabled = function() return push_enabled end,
  pending = function() return 0 end,
  is_rate_limited = function() return limited end,
  record_send = function(channel) recorded[#recorded + 1] = channel end,
  send = function(message, opts)
    if queue_full then return nil, "queue full" end
    sent[#sent + 1] = { message = message, opts = opts }
    return #sent
  end,
}
local sink
plugin = { get = function(name)
  check("only resolves push_notify", name == "push_notify")
  return sink
end }

local real_print, output = print, {}
print = function(line) output[#output + 1] = tostring(line) end
local function run(name, args)
  local spec = commands[name]
  check("command registered: " .. name, spec ~= nil)
  output = {}
  spec.handler(args or "")
  return table.concat(output, "\n")
end
local function tick(seconds)
  now = now + (seconds or 0)
  for _, fn in pairs(timers) do fn() end
end
local function combat(value)
  for _, h in pairs(handlers) do
    if h.pkg == "Char.Combat" then h.fn(h.pkg, value) end
  end
end
local function load_consumer()
  store = consumer_store
  local loaded = dofile("generic/push_notify.lua")
  loaded.on_load()
  store = producer_store
  sink = loaded
  return loaded
end
local function unload_consumer()
  store = consumer_store
  sink.on_unload()
  store = producer_store
  sink = nil
end
local function credentials()
  store = consumer_store
  sink.set_credentials("test-token", "test-user")
  store = producer_store
end
local producer_path = "3scapes/combat_notify.lua"
local file = io.open(producer_path, "r")
check("combat_notify producer exists", file ~= nil)
file:close()
local producer = dofile(producer_path)
producer.on_load()
producer.on_setup()
check("subscribes to combat", next(handlers) ~= nil)
check("starts without assumed combat state", run("/combatnotify"):find("Waiting", 1, true))
check("default delay is five minutes", run("/combatnotify"):find("300s", 1, true))

local consumer = load_consumer()
tick()
check("late consumer registers disabled channel", run("/pushn", "toggle"):find("out_of_combat: off", 1, true))
credentials()
run("/pushn", "toggle out_of_combat")
tick(600)
check("unknown state cannot alert", #sent == 0)
combat(nil); combat("idle"); combat({}); combat({ attacker = false })
tick(600)
check("malformed packets cannot start idle", #sent == 0)

combat({ attacker = "" })
tick(299)
check("no alert before threshold", #sent == 0)
combat({ attacker = "" })
tick(1)
check("duplicate idle does not postpone exact threshold", #sent == 1)
check("notification describes actual elapsed time", sent[1].message == "You have been out of combat for 300 seconds.")
check("correct push channel", sent[1].opts.title == "OUT_OF_COMBAT" and recorded[1] == "out_of_combat")
check("status shows submission", run("/combatnotify", "status"):find("submitted", 1, true))
tick(600)
combat({ attacker = "" })
tick(600)
check("one notification per idle period", #sent == 1)

combat({ attacker = "a troll" })
check("status reports combat", run("/combatnotify"):find("In combat", 1, true))
combat({})
tick(600)
check("missing attacker cannot end combat", #sent == 1)
combat({ attacker = "" })
tick(299)
combat({ attacker = "a rat" })
tick(1)
check("combat cancels pending alert", #sent == 1)
combat({ attacker = "" })
tick(300)
check("next completed fight rearms alert", #sent == 2)

-- A due condition remains due while ordinary delivery gates suppress it.
combat({ attacker = "a rat" }); combat({ attacker = "" })
push_enabled = false
tick(300)
check("global disable suppresses", #sent == 2)
push_enabled = true
run("/pushn", "toggle out_of_combat")
tick()
check("disabled channel suppresses", #sent == 2)
run("/pushn", "toggle out_of_combat")
limited = true
tick()
check("rate limiting suppresses", #sent == 2)
limited = false
queue_full = true
tick()
check("queue rejection does not mark submitted", #sent == 2 and #recorded == 2)
queue_full = false
tick(1)
check("suppressed alert retries while still idle", #sent == 3)

combat({ attacker = "a rat" }); combat({ attacker = "" })
tick(270)
consumer.on_user_input("/local-command")
tick(30)
check("actual local input suppresses due alert", #sent == 3)
if consumer.on_input then consumer.on_input("scripted command") end
tick(30)
check("automation does not extend grace", #sent == 4)

combat({ attacker = "a rat" }); combat({ attacker = "" })
store = consumer_store
consumer.clear_credentials()
store = producer_store
tick(300)
check("missing credentials suppress", #sent == 4)
credentials()
tick()
check("credentials enable current due condition", #sent == 5)

-- Loading/replacing the consumer is safe, including after the alert was sent.
combat({ attacker = "a rat" }); combat({ attacker = "" })
unload_consumer()
tick(300)
check("missing consumer is safe", #sent == 5)
consumer = load_consumer()
tick()
check("replacement consumer receives still-due alert", #sent == 6)
unload_consumer()
consumer = load_consumer()
tick(300)
check("consumer reload cannot duplicate accepted alert", #sent == 6)

-- Settings save immediately; invalid input never mutates the configured delay.
producer_data = { unrelated = "preserve" }
local prior_saves = saves
run("/combatnotify", "delay 120")
check("delay saved immediately", producer_data.delay == 120 and saves == prior_saves + 1)
check("unrelated stored keys preserved", producer_data.unrelated == "preserve")
for _, value in ipairs({ "", "0", "-1", "1.5", "inf", "1e3", "86401", string.rep("9", 400), "2 junk" }) do
  check("invalid delay reports usage", run("/combatnotify", "delay " .. value):find("Usage", 1, true))
  check("invalid delay keeps setting", producer_data.delay == 120)
end
check("help explains opt-in", run("/combatnotify", "help"):find("/pushn toggle out_of_combat", 1, true))
check("unknown command reports usage", run("/combatnotify", "bogus"):find("Usage", 1, true))
tick(300)
check("delay change cannot repeat an accepted alert", #sent == 6)
combat({ attacker = "a rat" }); combat({ attacker = "" })
tick(30)
run("/combatnotify", "delay 60")
tick(29)
check("changing delay keeps elapsed time without early alert", #sent == 6)
tick(1)
check("changed delay applies to same idle interval", #sent == 7)
check("updated delay in message", sent[7].message == "You have been out of combat for 60 seconds.")

combat({ attacker = "a rat" }); combat({ attacker = "" })
tick(59)
connected = false
producer.on_disconnect()
tick(600)
check("disconnect cancels alert", #sent == 7)
connected = true
producer.on_connect()
tick(600)
check("reconnect waits for fresh state", #sent == 7)
combat({ attacker = "" })
tick(60)
check("first idle after reconnect rearms", #sent == 8)

combat({ attacker = "a rat" }); combat({ attacker = "" })
connected = false
tick(60)
connected = true
tick(60)
check("heartbeat rejects stale state even without disconnect hook", #sent == 8)
combat({ attacker = "" })
gmcp_enabled = false
tick(60)
gmcp_enabled = true
tick(60)
check("GMCP loss discards state", #sent == 8)
combat({ attacker = "" })
tick(60)
check("fresh GMCP idle restarts", #sent == 9)

combat({ attacker = "a rat" }); combat({ attacker = "" })
tick(59)
producer.on_unload()
check("unload removes timer and GMCP subscription", next(timers) == nil and next(handlers) == nil)
check("unload removes command", commands["/combatnotify"] == nil)
tick(600)
check("unload cancels pending alert", #sent == 9)
producer = dofile(producer_path)
producer.on_load(); producer.on_setup()
check("reload restores saved delay", run("/combatnotify"):find("60s", 1, true))
tick(600)
check("reload requires fresh state", #sent == 9)
combat({ attacker = "" })
tick(60)
check("reloaded producer works", #sent == 10)
producer.on_unload()

for _, bad in ipairs({ 0, -1, 1.5, 86401, "invalid", true, {} }) do
  producer_data = { delay = bad }
  producer = dofile(producer_path)
  producer.on_load()
  check("invalid saved delay falls back", run("/combatnotify"):find("300s", 1, true))
  producer.on_unload()
end

print = real_print
print(string.format("combat_notify: %d checks passed", checks))
