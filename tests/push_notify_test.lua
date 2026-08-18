-- push_notify unit tests. Run from the lera-plugins repo root with LERA_ROOT
-- pointing at a built Lera checkout.
--
-- push_notify is a pure consumer: producers call M.notify(channel, text) and
-- this plugin owns credentials, per-channel enable/priority, the grace period
-- and rate limiting. It must NOT listen to MUD output lines.
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
local stored_data = nil
store = {
  load = function() end,
  get = function() return stored_data end,
  set = function(d) stored_data = d end,
  save = function() end,
}

local now = 1000
lera = { time = function() return now end }

local sent = {}          -- push.send calls: { msg = ..., opts = ... }
local limited = {}       -- channel ids currently rate limited
local recorded = {}      -- record_send calls
local push_on = true
push = {
  init = function() end,
  enable = function() push_on = true end,
  disable = function() push_on = false end,
  enabled = function() return push_on end,
  pending = function() return 0 end,
  send = function(msg, opts) sent[#sent + 1] = { msg = msg, opts = opts or {} } return #sent end,
  alert = function() end,
  set_rate_limit = function() end,
  is_rate_limited = function(id) return limited[id] == true end,
  record_send = function(id) recorded[#recorded + 1] = id end,
}

-- Command registry stub. The real registry (scripts/default/command.lua)
-- installs "^/name(?:\s+(.*))?$" and hands the handler everything after the
-- command name, so a test drives the handler with that remainder directly.
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

-- Raw aliases must not come back: this plugin's whole surface is /pushn now.
alias = {
  add = function() error("push_notify must not register raw aliases", 0) end,
  remove = function() end,
}

local function spec_for(name)
  for _, spec in ipairs(registered) do
    if spec.name == name then return spec end
  end
  return nil
end

-- Everything after "/pushn", the way the registry passes it.
local function dispatch(args)
  local spec = spec_for("/pushn")
  if not spec then return false end
  spec.handler(args)
  return true
end

local printed = {}
local real_print = print
local capture_print = function(text) printed[#printed + 1] = tostring(text) end

-- Simulate a previous session: credentials saved, tells channel enabled.
stored_data = {
  app_token = "tok",
  user_key = "key",
  config = {
    channels = { tells = { enabled = true, priority = 1 } },
  },
}

print = capture_print
local pushn = require("push_notify")
pushn.on_load()
print = real_print

local function run(args)
  printed = {}
  print = capture_print
  local matched = dispatch(args)
  print = real_print
  return matched, table.concat(printed, "\n")
end

local function quiet(fn, ...)
  print = capture_print
  local r = fn(...)
  print = real_print
  return r
end

-- ---- command registration -------------------------------------------------------
local pushn_spec = spec_for("/pushn")
check("registers_pushn_command", pushn_spec ~= nil)
check("pushn_takes_args", pushn_spec and pushn_spec.accepts_args == true)
check("pushn_has_summary", pushn_spec and type(pushn_spec.summary) == "string"
      and #pushn_spec.summary > 0)

-- ---- no MUD line listening -----------------------------------------------------
check("no_on_line_hook", pushn.on_line == nil)
local _, filter_out = run("filter")
check("filter_command_gone", filter_out:find("Unknown subcommand", 1, true) ~= nil, filter_out)

-- ---- stored channel state survives re-registration ------------------------------
quiet(pushn.register_channel, "tells", { priority = 1 })
check("stored_enabled_state_restored", quiet(pushn.notify, "tells", "Bob tells you: hi"))
check("notify_sends", #sent == 1 and sent[1].msg == "Bob tells you: hi", sent[1] and sent[1].msg)
check("notify_uses_channel_priority", sent[1] and sent[1].opts.priority == 1,
      sent[1] and tostring(sent[1].opts.priority))
check("notify_records_rate_limit", recorded[1] == "tells", recorded[1])

-- ---- unregistered channel: auto-register disabled, visible in toggle list -------
sent = {}
check("unregistered_channel_blocked", not quiet(pushn.notify, "gossip", "[gossip] hi"))
check("unregistered_channel_no_send", #sent == 0)
local _, out = run("toggle")
check("auto_registered_listed", out:find("gossip", 1, true) ~= nil, out)

-- ---- toggle enables an auto-registered channel ----------------------------------
run("toggle gossip")
check("toggled_channel_notifies", quiet(pushn.notify, "gossip", "[gossip] hi") and #sent == 1)

-- ---- disabled push blocks -------------------------------------------------------
sent = {}
push_on = false
check("disabled_push_blocks", not quiet(pushn.notify, "tells", "x") and #sent == 0)
push_on = true

-- ---- grace period: recent user input blocks -------------------------------------
sent = {}
pushn.on_input("look")            -- user active at now=1000
now = 1030
check("grace_period_blocks", not quiet(pushn.notify, "tells", "x") and #sent == 0)
now = 1061
check("grace_period_expires", quiet(pushn.notify, "tells", "x") and #sent == 1)

-- ---- rate limit blocks -----------------------------------------------------------
sent = {}
limited.tells = true
check("rate_limited_blocks", not quiet(pushn.notify, "tells", "x") and #sent == 0)
limited.tells = nil

-- ---- long messages truncated ------------------------------------------------------
sent = {}
quiet(pushn.notify, "tells", string.rep("a", 300))
check("long_message_truncated", sent[1] and #sent[1].msg == 200 and sent[1].msg:sub(-3) == "...",
      sent[1] and #sent[1].msg)

-- ---- commands ---------------------------------------------------------------------
local matched
matched, out = run("")
check("bare_pushn_matches", matched)
check("bare_pushn_shows_status", out:find("Status", 1, true) ~= nil, out)

matched, out = run("   ")
check("pushn_whitespace_only_is_bare", matched and out:find("Status", 1, true) ~= nil, out)

matched, out = run("toggle")
check("toggle_lists_channels", matched and out:find("tells", 1, true) ~= nil, out)

matched, out = run("toggle tells")
check("toggle_disables", out:find("'tells' disabled", 1, true) ~= nil, out)
sent = {}
check("disabled_channel_blocked", not quiet(pushn.notify, "tells", "x") and #sent == 0)
run("toggle tells")

-- ---- unload persists channel state -------------------------------------------------
quiet(pushn.on_unload)
local saved = stored_data.config.channels
check("unload_saves_channels", saved and saved.tells and saved.tells.enabled == true
      and saved.gossip and saved.gossip.enabled == true,
      saved and "tells=" .. tostring(saved.tells and saved.tells.enabled)
            .. " gossip=" .. tostring(saved.gossip and saved.gossip.enabled))
check("unload_saves_no_keywords", stored_data.config.keywords == nil)
check("unload_unregisters_command", #unregistered == 1, tostring(#unregistered))

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
