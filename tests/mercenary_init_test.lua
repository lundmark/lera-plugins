-- mercenary lifecycle, auto-use and accessors. Run from the lera-plugins repo
-- root with LERA_ROOT pointing at a built Lera checkout.
package.path = "3scapes/mercenary/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- ---- stubs ----------------------------------------------------------------
local clock = 1000
lera = { time = function() return clock end }

local sent = {}
mud = { send = function(text) sent[#sent + 1] = tostring(text) end }

buffer = { color_print = function() end }

local added_triggers = {}
local removed_triggers = {}
trigger = {
  add = function(pattern, fn, opts)
    local id = #added_triggers + 1
    added_triggers[#added_triggers + 1] = { id = id, pattern = pattern, fn = fn, opts = opts }
    return id
  end,
  remove = function(id) removed_triggers[#removed_triggers + 1] = id; return true end,
}

-- The wrapped-line handling arms a one_shot trigger and a disarm timer.
local timers, cancelled_timers = {}, {}
timer = {
  after = function(secs, fn)
    timers[#timers + 1] = { secs = secs, fn = fn }
    return #timers
  end,
  cancel = function(id) cancelled_timers[#cancelled_timers + 1] = id; return true end,
}

local saved
store = {
  load = function() end,
  get = function() return nil end,
  set = function(data) saved = data end,
  save = function() end,
}

gmcp = {
  on = function() return 1 end,
  remove = function() return true end,
  enabled = function() return true end,
}

-- `command` is a sandbox whitelist name, so command_ui reaches the registry
-- through require("command"). Intercept it: the registry is not what this suite
-- is about, and mercenary_command_test.lua already covers the rendering.
local real_require = require
require = function(name)
  if name == "command" then
    return {
      register = function() return 7 end,
      unregister = function() return true end,
    }
  end
  return real_require(name)
end

local protocol = require("protocol")
local state = require("state")
local M = require("init")

M.on_load()

-- Every case drives the real wiring: protocol.on_gmcp -> the on_apply callback
-- installed by on_load -> state.apply, and check_auto_use on a Vitals frame.
-- Nothing calls state.apply directly.
local function reset()
  sent = {}
  protocol.reset_connection()
  state.reset()
  M.set_auto_use_enabled(false)
  M.set_auto_use_ability("none")
  M.set_auto_use_cooldown(4)
  M.set_auto_use_stamina_threshold(80)
  M.set_auto_use_ap_threshold(80)
end

-- A Vitals frame with a live target and both pools above the default
-- thresholds: everything auto-use needs except the configuration.
local function ready_vitals(merc)
  return { merc = merc or "kaziar", hp = 400, hp_max = 500,
           stam = 90, stam_max = 100, ap = 85, ap_max = 100,
           target = "Orc", target_hp = 60 }
end

-- ---- legacy status omission -----------------------------------------------
check("legacy mercenary status lines are omitted by default",
  #added_triggers == 3
    and added_triggers[1].opts.omit_from_output == true
    and added_triggers[1].pattern:find("HP:", 1, true) ~= nil,
  "triggers=" .. #added_triggers)
M.set_omit_status_lines(false)
check("disabling omission unregisters every status trigger",
  #removed_triggers == 3, "removed=" .. #removed_triggers)
M.set_omit_status_lines(true)
check("enabling omission restores all three status triggers",
  #added_triggers == 6, "triggers=" .. #added_triggers)

-- ---- wrapped status lines --------------------------------------------------
-- The MUD wraps these lines to the reader's width (fmt_lib), which can split
-- one mid-token: "... AP:2605/6270(41%)+" then "21" on its own line. The head
-- patterns must not demand the tail, and the orphaned tail must be hidden too.
local head = added_triggers[4]
check("the HP head pattern does not demand the rest of the line",
  head.pattern:find("HP:", 1, true) ~= nil
    and head.pattern:find("AP:", 1, true) == nil, head.pattern)

local before_add, before_cancel = #added_triggers, #cancelled_timers
head.fn("[Bosse] HP:33500/33500(100%) Stam:6946/12562(55%)+39 AP:2605/6270(41%)+")
local tail = added_triggers[#added_triggers]
check("a matched status line arms one trigger for the continuation",
  #added_triggers == before_add + 1, "added=" .. (#added_triggers - before_add))
check("the continuation trigger hides its line and fires once only",
  tail.opts.omit_from_output == true and tail.opts.one_shot == true)
check("a disarm timer is scheduled in case the line did not wrap",
  #timers == 1 and timers[1].secs == 1, #timers)

tail.fn("21")
check("the continuation firing cancels the disarm timer",
  #cancelled_timers == before_cancel + 1, #cancelled_timers)

-- With an ability running the bar ends in " Abilities [Rend(4)]", so it can
-- wrap onto a SECOND line ("22" then "Abilities [Rend(4)]"). A hidden
-- continuation re-arms for one more line -- and only one more.
check("the continuation pattern knows the abilities segment",
  tail.pattern:find("Abilities", 1, true) ~= nil, tail.pattern)
-- The wrap can also fall between "Abilities" and its bracket, leaving
-- "[Rend(7)]" alone on the next line -- the list form must be there too, and
-- it must open with a letter so a bare damage number like "[0]" is left alone.
check("the continuation pattern takes a bracketed list on its own line",
  tail.pattern:find("|\\[[A-Za-z][", 1, true) ~= nil, tail.pattern)
local second = added_triggers[#added_triggers]
check("a hidden continuation arms one more for the line after it",
  second ~= tail and second.pattern == tail.pattern
    and second.opts.omit_from_output == true and second.opts.one_shot == true)
local before_third = #added_triggers
second.fn("Abilities [Rend(4)]")
check("the second continuation does not arm a third",
  #added_triggers == before_third, "added=" .. (#added_triggers - before_third))

-- Arming twice in a row must not leak the first trigger.
head.fn("[Bosse] HP:1/1(100%) Stam:1/1(100%)+0 AP:1/1(100%)+")
local leaked = #removed_triggers
head.fn("[Bosse] HP:1/1(100%) Stam:1/1(100%)+0 AP:1/1(100%)+")
check("re-arming removes the previous continuation trigger",
  #removed_triggers == leaked + 1, #removed_triggers - leaked)

-- ---- auto-use -------------------------------------------------------------
-- Kills: dropping the auto_use_enabled guard. The ability is deliberately set
-- to a real one here -- with the default "none" the second half of that guard
-- would block the send on its own and the mutant would be invisible.
reset()
M.set_auto_use_ability("bandage")
clock = 2000
protocol.on_gmcp("Merc.Vitals", ready_vitals())
check("auto-use does not fire while disabled",
  #sent == 0, table.concat(sent, "|"))

-- Kills: never sending at all, and sending the wrong command. The mudlib verb
-- is `merc use <ability>`; anything else is silently swallowed by the MUD.
reset()
M.set_auto_use_enabled(true)
M.set_auto_use_ability("bandage")
clock = 2100
protocol.on_gmcp("Merc.Vitals", ready_vitals())
check("auto-use fires once the thresholds are met",
  #sent == 1 and sent[1] == "merc use bandage", table.concat(sent, "|"))

-- Kills: deleting `if s.is_dormant then return end`. The frame carries a live
-- target and both pools above threshold, so the dormancy guard is the only
-- thing that can block this send. A collapsed mercenary cannot act, and the
-- mudlib clearing query_attack() is not something to lean on: the pane would
-- otherwise spend a 300 second recovery firing an ability every cooldown.
reset()
M.set_auto_use_enabled(true)
M.set_auto_use_ability("bandage")
clock = 2200
protocol.on_gmcp("Merc.Info", { merc = "kaziar", status = 5 })
protocol.on_gmcp("Merc.Vitals", ready_vitals())
check("auto-use is suppressed while dormant",
  #sent == 0 and state.get().is_dormant == true,
  "sent=" .. table.concat(sent, "|") .. " dormant=" .. tostring(state.get().is_dormant))

-- Kills: dropping the target guard, which would fire an ability at nothing on
-- every idle tick. "" is what the wire sends with no target.
reset()
M.set_auto_use_enabled(true)
M.set_auto_use_ability("bandage")
clock = 2300
local idle = ready_vitals()
idle.target = ""
idle.target_hp = 0
protocol.on_gmcp("Merc.Vitals", idle)
check("auto-use does not fire with no target",
  #sent == 0, table.concat(sent, "|"))

-- Kills: dropping the threshold comparison, or inverting it. Stamina is under
-- the threshold and ap is over, so a mutant that reads either pool alone, or
-- ORs the two, still fires.
reset()
M.set_auto_use_enabled(true)
M.set_auto_use_ability("bandage")
clock = 2400
local low = ready_vitals()
low.stam = 40
protocol.on_gmcp("Merc.Vitals", low)
check("auto-use does not fire below a threshold",
  #sent == 0 and state.get().stamina_percent == 40 and state.get().ap_percent == 85,
  "sent=" .. table.concat(sent, "|"))

-- Kills: dropping the cooldown, which turns the per-tick Vitals cadence into
-- an ability spam. The window is 4 seconds; the second frame is 3 seconds after
-- the first and the third is 5.
reset()
M.set_auto_use_enabled(true)
M.set_auto_use_ability("mend")
clock = 3000
protocol.on_gmcp("Merc.Vitals", ready_vitals())
clock = 3003
protocol.on_gmcp("Merc.Vitals", ready_vitals())
local inside = #sent
clock = 3005
protocol.on_gmcp("Merc.Vitals", ready_vitals())
check("the cooldown suppresses a send inside the window and allows one after it",
  inside == 1 and #sent == 2 and sent[2] == "merc use mend",
  "inside=" .. inside .. " total=" .. #sent)

-- ---- the two meanings of "abilities" --------------------------------------
-- Kills: collapsing the pair. Vitals.abils is the active-abilities string
-- M.abilities() has always returned; Stats.abilities is a lifetime counter
-- reached through get_stats().abilities_used. One frame of each, with values
-- that cannot be confused, so a projection that overwrote either is visible.
reset()
clock = 4000
protocol.on_gmcp("Merc.Vitals", { merc = "kaziar", abils = "[bandage,mend]" })
protocol.on_gmcp("Merc.Stats", { merc = "kaziar", abilities = 7 })
check("M.abilities() is the Vitals string and abilities_used is the Stats counter",
  M.abilities() == "[bandage,mend]" and M.get_stats().abilities_used == 7,
  "abilities=" .. tostring(M.abilities())
    .. " used=" .. tostring(M.get_stats().abilities_used))

-- Kills: abilities_list() splitting the raw string, brackets and all. Callers
-- get names they can compare against the configured ability.
check("abilities_list splits the bracketed string into names",
  #M.abilities_list() == 2 and M.abilities_list()[1] == "bandage"
    and M.abilities_list()[2] == "mend",
  table.concat(M.abilities_list(), "|"))

-- ---- disconnect -----------------------------------------------------------
-- Kills: on_disconnect resetting only the protocol mirrors. The server clears
-- its whole namespace cache on disconnect, so a retained projection would
-- render a stale mercenary against a session that has none -- and has_data()
-- is what every renderer gates on.
reset()
clock = 5000
protocol.on_gmcp("Merc.Vitals", ready_vitals())
local had = M.has_data()
M.on_disconnect()
check("on_disconnect clears the projected record",
  had == true and M.has_data() == false and protocol.mirror("Vitals") == nil,
  "had=" .. tostring(had) .. " now=" .. tostring(M.has_data()))

require = real_require

if failures > 0 then
  print("FAILURES: " .. failures)
  os.exit(1)
end
print("mercenary_init_test: all cases passed")
