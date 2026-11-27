-- generic/command_stack.lua: stacking on an ordinary alias, no core hook.
-- Lera's alias dispatch is simulated: the first matching alias wins; a string
-- return is sent, nil suppresses; no match sends the line as typed.
local handler, removed
package.loaded.command = {
  register = function(spec) handler = spec.handler; return 7 end,
  unregister = function(id) removed = id end,
}
local saved = {}
store = { load = function() end, get = function() return saved end,
          set = function(v) saved = v end, save = function() end }
local printed = {}
print = function(s) printed[#printed + 1] = s end

local aliases, next_id = {}, 1
alias = {
  add = function(pattern, fn)
    local id = next_id; next_id = next_id + 1
    aliases[#aliases + 1] = { id = id, pattern = pattern, fn = fn }
    return id
  end,
  remove = function(id)
    for i, a in ipairs(aliases) do if a.id == id then table.remove(aliases, i) end end
  end,
}
-- The stack alias is "^.*<sep>.*$": it matches any line holding <sep>.
local function matches(a, line)
  if a.lua then return line:find(a.lua) ~= nil end
  local sep = a.pattern:match("^%^%.%*\\?(.)%.%*%$$")
  return sep ~= nil and line:find(sep, 1, true) ~= nil
end
local sent = {}
mud = {}
function mud.execute(line)
  for _, a in ipairs(aliases) do
    if matches(a, line) then
      local r = a.fn(line)
      if type(r) == "string" then sent[#sent + 1] = r end
      return true
    end
  end
  sent[#sent + 1] = line
  return true
end

local fails = 0
local function check(name, ok, detail)
  if ok then io.write("CASE " .. name .. ": PASS\n")
  else fails = fails + 1; io.write("CASE " .. name .. ": FAIL " .. tostring(detail) .. "\n") end
end
local function run(line) sent = {}; mud.execute(line); return sent end

local plugin = dofile("generic/command_stack.lua")
plugin.on_load()
check("off by default: no alias registered", #aliases == 0)
check("off by default: a stacked line is sent as typed",
  run("look;score")[1] == "look;score" and #sent == 1)

handler("on")
check("on: saved per profile", saved.enabled == true)
check("on: one alias, no core hook", #aliases == 1)
-- A user alias added after the plugin, to show each part still reaches aliases.
aliases[#aliases + 1] = { id = 99, lua = "^k$", fn = function() return "kill rat" end }

local out = run("look;score")
check("look;score runs two commands", #out == 2 and out[1] == "look" and out[2] == "score",
  table.concat(out, "|"))
out = run("k;look")
check("each part goes through aliases", out[1] == "kill rat" and out[2] == "look",
  table.concat(out, "|"))
out = run("say a;;b;look")
check("a doubled separator is a literal one", #out == 2 and out[1] == "say a;b"
  and out[2] == "look", table.concat(out, "|"))
out = run(";say a;b")
check("a leading separator sends the rest as one command", #out == 1 and out[1] == "say a;b",
  table.concat(out, "|"))
out = run("look")
check("a line without the separator is untouched", #out == 1 and out[1] == "look")

local big = {}
for i = 1, 257 do big[i] = "n" end
out = run(table.concat(big, ";"))
check("over 256 commands sends nothing and says so", #out == 0
  and tostring(printed[#printed]):find("256", 1, true), printed[#printed])

handler("separator |")
check("separator change re-registers one alias", #aliases == 2 and saved.separator == "|")
out = run("look|score")
check("the new separator splits", #out == 2 and out[1] == "look")
out = run("say a;b")
check("the old separator is plain text again", #out == 1 and out[1] == "say a;b")
handler("separator .")
check("the speedwalk prefix '.' is refused as a separator", saved.separator == "|")

check("split: trailing separator gives an empty last part",
  #plugin.split("look;", ";") == 2 and plugin.split("look;", ";")[2] == "")

handler("off")
check("off removes the alias", #aliases == 1 and aliases[1].id == 99)
plugin.on_unload()
check("unload unregisters the command", removed == 7)

if fails > 0 then io.write(fails .. " FAILED\n"); os.exit(1) end
io.write("ALL COMMAND STACK TESTS PASSED\n")
