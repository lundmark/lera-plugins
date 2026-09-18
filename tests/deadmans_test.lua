-- Fixed 15-minute deadmans tests. Run with LuaJIT from plugins/.
package.path = "generic/?.lua;" .. package.path

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
local stored_data = { config = { warning_time = 60, block_time = 7200, antiidle_time = 60 } }
local initial_data = stored_data
local saves = 0
store = {
  load = function() end,
  get = function() return stored_data end,
  set = function(d) stored_data = d end,
  save = function() saves = saves + 1 end,
}

local now = 1000
lera = {
  time = function() return now end,
  dirty = function() end,
}

-- The one-second tick is where the push transitions are detected, so the test
-- has to be able to drive it by hand.
local tick_fn, cancelled
timer = {
  every = function(_, fn) tick_fn = fn return 1 end,
  cancel = function(id) cancelled = id end,
}

local mud_state = "connected"
local raw_sends = 0
mud = {
  state = function() return mud_state end,
  send_raw = function() raw_sends = raw_sends + 1 return true end,
}

-- Fake push_notify. Records what each channel was told, and which channels
-- were registered, so the cases can assert on both.
local pushed = {}
local push_channels = {}
local push_sink = {
  register_channel = function(name, opts)
    push_channels[name] = opts or {}
  end,
  notify = function(channel, text)
    pushed[#pushed + 1] = { channel = channel, text = text }
    return true
  end,
}
plugin = {
  get = function(name)
    if name == "push_notify" then return push_sink end
    return nil
  end,
}

local registered = {}
local unregistered = {}
local command_stub = {
  register = function(spec) registered[#registered + 1] = spec return #registered end,
  unregister = function(id) unregistered[#unregistered + 1] = id return true end,
}
local real_require = require
require = function(name)
  if name == "command" then return command_stub end
  return real_require(name)
end

-- Raw aliases must not come back: the whole surface is /deadmans now.
alias = {
  add = function() error("deadmans must not register raw aliases", 0) end,
  remove = function() end,
}

local printed = {}
local real_print = print
local capture_print = function(text) printed[#printed + 1] = tostring(text) end

print = capture_print
local dm = require("deadmans")
dm.on_load()
print = real_print

local function spec_for(name)
  for _, spec in ipairs(registered) do
    if spec.name == name then return spec end
  end
  return nil
end

local spec = spec_for("/deadmans")

-- Everything after "/deadmans", the way the registry passes it.
local function run(args)
  printed = {}
  print = capture_print
  spec.handler(args)
  print = real_print
  return table.concat(printed, "\n")
end

-- Read-only status and immutable thresholds, including stale saved settings.
check("registers_command", spec ~= nil)
check("takes_no_args", spec and spec.accepts_args == false)
check("usage_is_status_only", spec and spec.usage == "/deadmans", spec and spec.usage)
local out = run("")
check("bare_shows_status", out:find("Status", 1, true) ~= nil, out)
check("status_advertises_fixed_timeout", out:find("Blocking at: 15 minutes", 1, true) ~= nil, out)
check("no_setter_api", dm.set_warning_time == nil and dm.set_block_time == nil)
check("no_manual_reset_api", dm.reset == nil)
check("saved_thresholds_are_ignored", dm.get_config().warning_time == 600
      and dm.get_config().block_time == 900)
local config = dm.get_config()
config.warning_time, config.block_time = 0, 0
check("config_is_a_copy", dm.get_config().warning_time == 600 and dm.get_config().block_time == 900)

now = 1000 + 599
check("no_warning_before_ten_minutes", not dm.is_warning() and not dm.is_active())
check("automation_allowed_before_warning", dm.on_send("look") == "look")
now = 1000 + 600
check("warning_at_ten_minutes", dm.is_warning() and not dm.is_active())
now = 1000 + 899
check("automation_allowed_until_fifteen_minutes", dm.on_send("look") == "look")
now = 1000 + 900
check("blocks_at_exactly_fifteen_minutes", dm.is_active() and not dm.is_warning())
check("automation_blocked_at_fifteen_minutes", dm.on_send("look") == nil)
check("counts_blocked_sends", dm.blocked_count() == 1, dm.blocked_count())

-- Even direct handler calls cannot change thresholds or reset the timer.
for _, args in ipairs({ "set 120", "block 120", "warning 1", "reset", "antiidle on", "antiidle 1" }) do
  run(args)
  check("command_cannot_change_timeout_" .. args,
        dm.get_config().warning_time == 600 and dm.get_config().block_time == 900)
  check("command_cannot_reset_idle_" .. args, dm.get_idle_time() == 900)
end
now = 1000 + 3600
tick_fn()
check("never_sends_antiidle", raw_sends == 0, raw_sends)
check("status_does_not_reset_idle", run(""):find("BLOCKING", 1, true) ~= nil
      and dm.get_idle_time() == 3600)

print = capture_print
dm.on_user_input("/reconnect")
print = real_print
check("local_command_counts_as_activity", dm.get_idle_time() == 0)
check("input_resumes_automation", dm.on_send("look") == "look")
check("input_clears_blocked_count", dm.blocked_count() == 0)
now = now + 900
print = capture_print
dm.on_user_input("")
print = real_print
check("empty_enter_counts_as_activity", dm.get_idle_time() == 0)

print = capture_print
dm.on_unload()
print = real_print
check("unload_unregisters_command", #unregistered == 1, #unregistered)
check("unload_cancels_timer", cancelled == 1)
check("saved_config_is_untouched", saves == 0 and stored_data == initial_data
      and initial_data.config.block_time == 7200)

-- ---- push notifications -----------------------------------------------------
-- The overlay is only useful to someone looking at the window, which being
-- idle rules out. These cases are about the notification that goes out instead.
--
-- Reload starts a fresh idle period with the same fixed thresholds.
local BASE = 100000
now = BASE
print = capture_print
dm.on_load()
dm.on_setup()
print = real_print

check("push_registers_both_channels",
      push_channels.deadman_warning ~= nil and push_channels.deadman_triggered ~= nil)
-- Both HIGH, like push_notify's own disconnect alert: normal priority is
-- subject to quiet hours, which is precisely when an unattended client idles
-- out and you most need to be told.
check("push_both_channels_are_high_priority",
      push_channels.deadman_warning and push_channels.deadman_warning.priority == 1
      and push_channels.deadman_triggered and push_channels.deadman_triggered.priority == 1,
      (push_channels.deadman_warning and push_channels.deadman_warning.priority)
        .. "/" .. (push_channels.deadman_triggered and push_channels.deadman_triggered.priority))

local function idle_for(seconds)
  now = BASE + seconds
  tick_fn()
end

local function last_push()
  return pushed[#pushed]
end

pushed = {}
idle_for(9 * 60)
check("push_silent_before_the_warning", #pushed == 0, #pushed)

idle_for(10 * 60)
check("push_on_entering_warning", #pushed == 1 and last_push().channel == "deadman_warning",
      last_push() and last_push().channel)
check("warning_text_names_the_time_left",
      last_push() and last_push().text:find("automation stops in", 1, true) ~= nil, last_push() and last_push().text)

idle_for(10 * 60 + 240)
check("push_does_not_repeat_inside_the_interval", #pushed == 1, #pushed)

-- Crossing into blocked is a state change, so it notifies at once rather than
-- waiting out the warning channel's repeat clock.
pushed = {}
idle_for(15 * 60)
check("push_on_entering_blocked", #pushed == 1
      and last_push().channel == "deadman_triggered", last_push() and last_push().channel)
check("triggered_text_says_sends_are_blocked",
      last_push() and last_push().text:find("blocked", 1, true) ~= nil, last_push() and last_push().text)

idle_for(15 * 60 + 60)
check("blocked_push_does_not_repeat_inside_the_interval", #pushed == 1, #pushed)
idle_for(20 * 60)
check("blocked_push_repeats_after_five_minutes", #pushed == 2, #pushed)

-- Typing ends the episode. The next idle period must notify from scratch
-- rather than inheriting this one's repeat clock.
pushed = {}
now = BASE + 20 * 60
print = capture_print
dm.on_user_input("")
print = real_print
idle_for(20 * 60 + 10 * 60)
check("push_after_resume_starts_a_fresh_warning", #pushed == 1
      and last_push().channel == "deadman_warning", #pushed)

-- Disconnected: nothing is automating, so there is nothing to warn about, and
-- push_notify has its own disconnect alert.
pushed = {}
mud_state = "disconnected"
idle_for(20 * 60 + 15 * 60)
check("push_silent_while_disconnected", #pushed == 0, #pushed)
mud_state = "connected"

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
