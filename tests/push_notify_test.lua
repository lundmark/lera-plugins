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

-- Alias registry mirroring the C engine (src/script/alias.c): aliases are
-- tried in registration order, the first match wins, and the callback gets
-- the full match followed by the capture groups.
local aliases = {}
alias = {
  add = function(pattern, fn)
    aliases[#aliases + 1] = { pattern = pattern, fn = fn }
    return #aliases
  end,
  remove = function() end,
}

local function pcre_to_lua(pattern)
  return (pattern:gsub("\\([sSd])", "%%%1"))
end

local function dispatch(input)
  for _, a in ipairs(aliases) do
    local captures = { input:match(pcre_to_lua(a.pattern)) }
    if captures[1] then
      local full = input:match("(" .. pcre_to_lua(a.pattern) .. ")")
      a.fn(full, unpack(captures))
      return true
    end
  end
  return false
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

local function run(input)
  printed = {}
  print = capture_print
  local matched = dispatch(input)
  print = real_print
  return matched, table.concat(printed, "\n")
end

local function quiet(fn, ...)
  print = capture_print
  local r = fn(...)
  print = real_print
  return r
end

-- ---- no MUD line listening -----------------------------------------------------
check("no_on_line_hook", pushn.on_line == nil)
check("filter_command_gone", not dispatch("pushn filter"))

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
local _, out = run("pushn toggle")
check("auto_registered_listed", out:find("gossip", 1, true) ~= nil, out)

-- ---- toggle enables an auto-registered channel ----------------------------------
run("pushn toggle gossip")
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
matched, out = run("pushn")
check("bare_pushn_matches", matched)
check("bare_pushn_shows_status", out:find("Status", 1, true) ~= nil, out)

matched, out = run("pushn ")
check("pushn_trailing_space_matches", matched)

matched, out = run("pushn toggle")
check("toggle_lists_channels", matched and out:find("tells", 1, true) ~= nil, out)

matched, out = run("pushn toggle tells")
check("toggle_disables", out:find("'tells' disabled", 1, true) ~= nil, out)
sent = {}
check("disabled_channel_blocked", not quiet(pushn.notify, "tells", "x") and #sent == 0)
run("pushn toggle tells")

-- ---- unload persists channel state -------------------------------------------------
quiet(pushn.on_unload)
local saved = stored_data.config.channels
check("unload_saves_channels", saved and saved.tells and saved.tells.enabled == true
      and saved.gossip and saved.gossip.enabled == true,
      saved and "tells=" .. tostring(saved.tells and saved.tells.enabled)
            .. " gossip=" .. tostring(saved.gossip and saved.gossip.enabled))
check("unload_saves_no_keywords", stored_data.config.keywords == nil)

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
