-- deadmans unit tests. Run from the lera-plugins repo root with LERA_ROOT
-- pointing at a built Lera checkout.
--
-- The subcommand parsing used to live in alias regexes ("^deadmans\s+warning
-- \s+(\d+)$"); it is hand-written Lua now, so the argument validation is what
-- these cases are really about.
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
lera = {
  time = function() return now end,
  dirty = function() end,
}

timer = {
  every = function() return 1 end,
  cancel = function() end,
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

-- ---- registration -----------------------------------------------------------
check("registers_command", spec ~= nil)
check("takes_args", spec and spec.accepts_args == true)
check("has_summary", spec and type(spec.summary) == "string" and #spec.summary > 0)
check("usage_is_slash_form", spec and spec.usage:sub(1, 9) == "/deadmans", spec and spec.usage)

-- ---- bare and status --------------------------------------------------------
local out = run("")
check("bare_shows_status", out:find("Status", 1, true) ~= nil, out)
check("bare_shows_help", out:find("/deadmans reset", 1, true) ~= nil, out)

out = run("status")
check("status_shows_status", out:find("Status", 1, true) ~= nil, out)
check("status_omits_help", out:find("/deadmans reset", 1, true) == nil, out)

out = run("help")
check("help_shows_help", out:find("/deadmans block", 1, true) ~= nil, out)

-- ---- whitespace and case ----------------------------------------------------
out = run("   status   ")
check("trims_whitespace", out:find("Status", 1, true) ~= nil, out)

out = run("STATUS")
check("subcommand_is_case_insensitive", out:find("Status", 1, true) ~= nil, out)

-- ---- numeric arguments ------------------------------------------------------
run("warning 5")
check("warning_sets_time", dm.get_config().warning_time == 5 * 60,
      dm.get_config().warning_time)

run("block 20")
check("block_sets_time", dm.get_config().block_time == 20 * 60,
      dm.get_config().block_time)

out = run("warning")
check("warning_without_value_prints_usage", out:find("Usage: /deadmans warning", 1, true) ~= nil, out)
check("warning_without_value_keeps_config", dm.get_config().warning_time == 5 * 60)

out = run("block abc")
check("block_rejects_non_numeric", out:find("Usage: /deadmans block", 1, true) ~= nil, out)
check("block_rejects_non_numeric_keeps_config", dm.get_config().block_time == 20 * 60)

out = run("warning 5 7")
check("warning_rejects_extra_argument", out:find("Usage: /deadmans warning", 1, true) ~= nil, out)

-- ---- reset ------------------------------------------------------------------
now = 5000
out = run("reset")
check("reset_reports", out:find("reset", 1, true) ~= nil, out)
check("reset_clears_idle", dm.get_idle_time() == 0, dm.get_idle_time())

-- ---- unknown ----------------------------------------------------------------
out = run("nonsense")
check("unknown_subcommand_reported", out:find("Unknown subcommand: nonsense", 1, true) ~= nil, out)
check("unknown_subcommand_shows_help", out:find("/deadmans status", 1, true) ~= nil, out)

-- ---- unload -----------------------------------------------------------------
print = capture_print
dm.on_unload()
print = real_print
check("unload_unregisters_command", #unregistered == 1, tostring(#unregistered))
check("unload_persists_config", stored_data and stored_data.config
      and stored_data.config.warning_time == 5 * 60)

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
