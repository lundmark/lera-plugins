-- kill_trigger unit tests. Run from the lera-plugins repo root with LERA_ROOT
-- pointing at a built Lera checkout.
--
-- /killers used to be eighteen alias patterns, each validating its own
-- arguments in PCRE ("^/killers\s+delcmd\s+(\d+)$"). It is one registered
-- command with hand-written dispatch now, so these cases cover the index and
-- text argument checks that regex used to do.
package.path = "3scapes/?.lua;" .. package.path

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

lera = { time = function() return 1000 end }

local sent = {}
mud = { send = function(cmd) sent[#sent + 1] = cmd end }

local triggers = {}
trigger = {
  add = function(pattern, fn, opts)
    triggers[#triggers + 1] = { pattern = pattern, fn = fn, opts = opts }
    return #triggers
  end,
  remove = function() end,
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

-- Raw aliases must not come back: the whole surface is /killers now.
alias = {
  add = function() error("kill_trigger must not register raw aliases", 0) end,
  remove = function() end,
}

local printed = {}
local real_print = print
local capture_print = function(text) printed[#printed + 1] = tostring(text) end

print = capture_print
local kt = require("kill_trigger")
kt.on_load()
print = real_print

local function spec_for(name)
  for _, spec in ipairs(registered) do
    if spec.name == name then return spec end
  end
  return nil
end

local spec = spec_for("/killers")

-- Everything after "/killers", the way the registry passes it.
local function run(args)
  printed = {}
  print = capture_print
  spec.handler(args)
  print = real_print
  return table.concat(printed, "\n")
end

local function has(list, value)
  for _, item in ipairs(list) do
    if item == value then return true end
  end
  return false
end

-- ---- registration -----------------------------------------------------------
check("registers_command", spec ~= nil)
check("takes_args", spec and spec.accepts_args == true)
check("has_summary", spec and type(spec.summary) == "string" and #spec.summary > 0)

-- ---- status and help --------------------------------------------------------
local out = run("")
check("bare_shows_status", out:find("[killers]", 1, true) ~= nil, out)
check("bare_shows_help", out:find("/killers addcmd", 1, true) ~= nil, out)

out = run("help")
check("help_shows_help", out:find("/killers swapocmd", 1, true) ~= nil, out)

-- ---- enable and disable -----------------------------------------------------
run("off")
check("off_disables", kt.is_enabled() == false)
run("on")
check("on_enables", kt.is_enabled() == true)

-- ---- killer list ------------------------------------------------------------
run("add Gorbag")
check("add_stores_killer", kt.has_killer("gorbag"))

out = run("list")
check("list_shows_killer", out:find("gorbag", 1, true) ~= nil, out)

run("del Gorbag")
check("del_removes_killer", not kt.has_killer("gorbag"))

out = run("add")
check("add_without_name_prints_usage", out:find("Usage: /killers add <name>", 1, true) ~= nil, out)

-- A killer name may contain spaces; the old "(.+)" capture allowed it.
run("add dark rider")
check("add_accepts_multiword_name", kt.has_killer("dark rider"))
run("del dark rider")

-- ---- command list -----------------------------------------------------------
run("addcmd testcmd")
check("addcmd_appends", has(kt.get_commands(), "testcmd"))

out = run("listcmd")
check("listcmd_lists", out:find("testcmd", 1, true) ~= nil, out)

out = run("addcmd")
check("addcmd_without_value_prints_usage",
      out:find("Usage: /killers addcmd <cmd>", 1, true) ~= nil, out)

local before = #kt.get_commands()
out = run("delcmd abc")
check("delcmd_rejects_non_numeric", out:find("Usage: /killers delcmd <#>", 1, true) ~= nil, out)
check("delcmd_rejects_non_numeric_keeps_list", #kt.get_commands() == before)

out = run("delcmd")
check("delcmd_without_index_prints_usage",
      out:find("Usage: /killers delcmd <#>", 1, true) ~= nil, out)

run("delcmd " .. #kt.get_commands())
check("delcmd_removes", not has(kt.get_commands(), "testcmd"))

-- ---- swaps ------------------------------------------------------------------
local first, second = kt.get_commands()[1], kt.get_commands()[2]
check("swap_fixture_present", first ~= nil and second ~= nil)
run("swapcmd 1 2")
check("swapcmd_swaps", kt.get_commands()[1] == second and kt.get_commands()[2] == first,
      table.concat(kt.get_commands(), ","))

out = run("swapcmd 1")
check("swapcmd_with_one_index_prints_usage",
      out:find("Usage: /killers swapcmd <#> <#>", 1, true) ~= nil, out)

out = run("swapcmd 1 x")
check("swapcmd_rejects_non_numeric",
      out:find("Usage: /killers swapcmd <#> <#>", 1, true) ~= nil, out)

-- ---- other-command list -----------------------------------------------------
out = run("listocmd")
check("listocmd_reports_empty", out:find("(none)", 1, true) ~= nil, out)

run("addocmd othercmd")
check("addocmd_appends", has(kt.get_other_commands(), "othercmd"))

out = run("delocmd abc")
check("delocmd_rejects_non_numeric",
      out:find("Usage: /killers delocmd <#>", 1, true) ~= nil, out)

run("delocmd 1")
check("delocmd_removes", not has(kt.get_other_commands(), "othercmd"))

-- ---- unknown ----------------------------------------------------------------
out = run("nonsense")
check("unknown_subcommand_reported",
      out:find("Unknown subcommand: nonsense", 1, true) ~= nil, out)

-- ---- cross-plugin kill listeners --------------------------------------
local heard = {}
local id1 = kt.on_monster_died(function(killer, victim)
  heard[#heard + 1] = { who = killer, what = victim, order = 1 }
end)
local id2 = kt.on_monster_died(function(killer, victim)
  heard[#heard + 1] = { who = killer, what = victim, order = 2 }
end)
check("listener ids distinct", id1 ~= nil and id2 ~= nil and id1 ~= id2)
check("non-function rejected", kt.on_monster_died("nope") == nil)

local blow = nil
for _, t in ipairs(triggers) do
  if t.pattern:find("killing blow", 1, true) then blow = t.fn end
end
check("killing blow trigger found", blow ~= nil)

heard = {}
blow("Simon dealt the killing blow to a rat.", "Simon", "a rat")
check("both listeners fired in order", #heard == 2
      and heard[1].order == 1 and heard[2].order == 2)
check("listener args", heard[1].who == "Simon" and heard[1].what == "a rat")

-- an erroring listener does not stop the rest
kt.on_monster_died(function() error("boom") end)
local id4 = kt.on_monster_died(function() heard[#heard + 1] = { order = 4 } end)
heard = {}
blow("Simon dealt the killing blow to a rat.", "Simon", "a rat")
check("error does not stop dispatch", heard[#heard] and heard[#heard].order == 4)

-- listeners observe every kill regardless of the command-execution enable flag
run("off")
check("enable flag off for this check", kt.is_enabled() == false)
heard = {}
blow("Simon dealt the killing blow to a rat.", "Simon", "a rat")
check("listeners fire while command execution is disabled", #heard > 0)
run("on")

-- removal
check("remove known id", kt.remove_kill_listener(id1) == true)
check("remove unknown id", kt.remove_kill_listener(9999) == false)
heard = {}
blow("Simon dealt the killing blow to a rat.", "Simon", "a rat")
local saw_first = false
for _, h in ipairs(heard) do if h.order == 1 then saw_first = true end end
check("removed listener silent", not saw_first)

-- self-removal from inside a callback must not skip the next listener in
-- the same dispatch (dispatch runs over a snapshot of the registration set)
local self_removal_heard = {}
local idA, idB
idA = kt.on_monster_died(function()
  self_removal_heard[#self_removal_heard + 1] = "A"
  kt.remove_kill_listener(idA)
end)
idB = kt.on_monster_died(function()
  self_removal_heard[#self_removal_heard + 1] = "B"
end)
blow("Simon dealt the killing blow to a rat.", "Simon", "a rat")
check("both fire on the dispatch where one self-removes",
      #self_removal_heard == 2 and self_removal_heard[1] == "A" and self_removal_heard[2] == "B",
      table.concat(self_removal_heard, ","))

self_removal_heard = {}
blow("Simon dealt the killing blow to a rat.", "Simon", "a rat")
check("self-removed listener silent next time, other still fires",
      #self_removal_heard == 1 and self_removal_heard[1] == "B",
      table.concat(self_removal_heard, ","))

-- ---- unload -----------------------------------------------------------------
print = capture_print
kt.on_unload()
print = real_print
check("unload_unregisters_command", #unregistered == 1, tostring(#unregistered))

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
