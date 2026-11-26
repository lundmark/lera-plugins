-- Plain Lua stubs: regex strings are asserted separately from callback routing.
local real_print, messages = print, {}
print = function(s) messages[#messages + 1] = s end
local configure, removed_command, saved, saves = nil, nil, {}, 0
package.loaded.command = {
  register = function(spec)
    assert(spec.name == "/input-shortcuts" and spec.accepts_args)
    configure = spec.handler
    return 7
  end,
  unregister = function(id) removed_command = id end,
}
store = {
  load = function() end, get = function() return saved end,
  set = function(value)
    saved = {}
    for k, v in pairs(value) do saved[k] = v end
  end,
  save = function() saves = saves + 1 end,
}
local aliases, next_id, removed = {}, 0, {}
local fail_regex
alias = {
  add = function(regex, callback, ...)
    assert(select("#", ...) == 0)
    if regex == fail_regex then return nil, "alias cap reached" end
    next_id = next_id + 1
    aliases[next_id] = {regex = regex, callback = callback}
    return next_id
  end,
  remove = function(id) assert(aliases[id]); aliases[id] = nil; removed[id] = true end,
}

-- Mirrors src/script/speedwalk.c and api_speedwalk.c: parse returns step
-- tables (not flattened strings), or nil,error. Counts clamp to 255; zero
-- means one; bare diagonals are two steps; parentheses support forward/back.
local reverse = {n="s", s="n", e="w", w="e", u="d", d="u",
  ne="sw", sw="ne", nw="se", se="nw"}
speedwalk = {}
function speedwalk.parse(s)
  local path, i = {}, 1
  while i <= #s do
    local digits = s:sub(i):match("^%d*")
    local count = tonumber(digits) or 1
    if count == 0 then count = 1 end
    count = math.min(count, 255)
    i = i + #digits
    if i > #s then break end
    local forward, backward, pf, pb
    local c = s:sub(i, i)
    if c == "(" then
      local last = s:find(")", i + 1, true)
      if not last then return nil, "unclosed parenthesis" end
      local content = s:sub(i + 1, last - 1)
      forward, backward = content:match("^(.-)/(.*)$")
      forward = forward or content
      backward = backward or reverse[forward] or forward
      pf, pb = forward == ".pause", backward == ".pause"
      if pf then forward = "" end
      if pb then backward = "" end
      i = last + 1
    elseif c:match("[nsewud]") then
      forward, backward, pf, pb = c, reverse[c], false, false
      i = i + 1
    else
      return nil, "invalid character in path"
    end
    path[#path + 1] = {forward=forward, backward=backward, count=count,
      pause_forward=pf, pause_backward=pb}
  end
  return path
end
-- flatten is deliberately unused: its empty pause commands differ from the
-- reference plugin's policy of skipping pauses and empty forward commands.

local sent, executions, intercept = {}, 0
local stack_regex = "^[\\s\\S]*\\;[\\s\\S]*\\z"
-- Exact PCRE2 strings are pinned below; plain LuaJIT routing is only a stub.
-- Verified with a real PCRE2 engine: #3n 2e, #(open gate), #2(ne) match;
-- #chaossea-home, #foo, #3 3n, #n2 do not match.
local walk_regex = "^\\#[ \\t]*(?:[0-9]*[ \\t]*(?:[nsewud]|\\([^()\\r\\n]*\\))[ \\t]*)+\\z"
local function walk_candidate(text)
  local prefix = saved.prefix or "#"
  if text:sub(1, #prefix) ~= prefix then return false end
  local s = text:sub(#prefix + 1):gsub("%([^()\r\n]*%)", "n")
  -- Test-only approximation for dispatch. Exact PCRE checked outside Lua.
  return s:find("[nsewud]") and not s:find("[^0-9nsewud \t]")
    and not s:find("%d[ \t]+%d") and not s:find("%d[ \t]*$")
end
mud = {}
function mud.execute(text)
  executions = executions + 1
  assert(executions < 3000, "unbounded recursion")
  if intercept and intercept(text) then return end
  for id = 1, next_id do
    local a = aliases[id]
    if a then
      local stack = a.regex:sub(1, 3) == "^[\\"
      if (stack and text:find(saved.separator or ";", 1, true))
          or (not stack and walk_candidate(text)) then
        local result = a.callback(text)
        if type(result) == "string" then sent[#sent + 1] = result end
        return
      end
    end
  end
  sent[#sent + 1] = text
end
local checks = 0
local function check(ok) assert(ok); checks = checks + 1 end
local function run(text, expected)
  sent, executions = {}, 0
  mud.execute(text)
  check(table.concat(sent, "|") == expected)
end
local function alias_count()
  local n = 0
  for _ in pairs(aliases) do n = n + 1 end
  return n
end
local plugin = dofile("generic/input_shortcuts.lua")
plugin.on_load()
check(alias_count() == 0 and plugin.on_command == nil and plugin.on_input == nil)
run("look;#n", "look;#n")
configure("stack on")
check(alias_count() == 1)
check(aliases[next_id].regex == stack_regex)
local old = next_id
configure("walk on")
check(removed[old] and alias_count() == 2)
check(aliases[next_id - 1].regex == stack_regex)
check(aliases[next_id].regex == walk_regex)
check(saved.stack and saved.walk and saves == 2)
run("look;score", "look|score")
run("say a;;b;look;", "say a;b|look")
run("say a;;;;b", "say a;;b")
run(";say a;b", "say a;b")
run(";;look", ";look")
run(";", "")
check(#sent == 0)
run("look; ;score", "look| |score")
run(";#2n", "#2n")
run("#3n 2e", "north|north|north|east|east")
run("#3 n 2(ne) (open gate)", "north|north|north|northeast|northeast|open gate")
run("#ne", "north|east")
run("#(nw)(se)(sw)udsw", "northwest|southeast|southwest|up|down|south|west")
run("#(open gate/close gate)(.pause)()0n", "open gate|north")
run("#2n;look", "north|north|look")
run("#chaossea-home", "#chaossea-home")
run("#arbitrary text", "#arbitrary text")
run("#1 2n", "#1 2n")
local walk = aliases[next_id].callback
check(walk("#invalid") == "#invalid")
check(walk("#1 2n") == "#1 2n")
local parse = speedwalk.parse
speedwalk.parse = function() return nil, "no frame arena" end
check(walk("#2n") == "#2n")
speedwalk.parse = parse
run("#999n", table.concat((function()
  local t = {}; for i = 1, 255 do t[i] = "north" end; return t
end)(), "|"))
sent, executions = {}, 0
mud.execute("#" .. string.rep("n", 1024))
check(#sent == 1024)
run("#" .. string.rep("n", 1025), "")
check(messages[#messages]:find("1024", 1, true))
run(string.rep("look;", 1025), "")
-- Shared budget counts intermediate dispatches too; no second oversized walk.
sent, executions = {}, 0
mud.execute("look;#" .. string.rep("n", 1022))
check(#sent == 1023 and executions == 1025)
run("look;#" .. string.rep("n", 1023), "look")
check(messages[#messages]:find("1024", 1, true))
sent, executions = {}, 0
mud.execute("#" .. string.rep("n", 600) .. ";#" .. string.rep("n", 600))
check(#sent == 600 and messages[#messages]:find("1024", 1, true))
sent, executions = {}, 0
mud.execute("#" .. string.rep("n", 600) .. string.rep(";look", 500))
check(#sent == 1023 and executions == 1025)
check(messages[#messages]:find("1024", 1, true))
-- Another alias can feed a walk back into itself. Depth and budget survive it.
intercept = function(text)
  if text == "loop" then mud.execute("#(loop)"); return true end
end
run("#(loop)", "")
check(messages[#messages]:find("depth 8", 1, true))
intercept = nil
run("#n", "north")
-- Exceptions cannot leave a stale passthrough marker or active depth/budget.
intercept = function() error("filter failure") end
check(not pcall(aliases[next_id - 1].callback, "say a;;b"))
intercept = nil
run("say a;b", "say a|b")
configure("separator |")
check(aliases[next_id - 1].regex == "^[\\s\\S]*\\|[\\s\\S]*\\z")
configure("prefix .+")
check(aliases[next_id].regex:sub(1, 5) == "^\\.\\+")
run("look|.+n", "look|north")
run("say a||b|look", "say a|b|look")
local count = saves
configure("separator nope"); configure("prefix"); configure("")
check(saves == count and saved.separator == "|" and saved.prefix == ".+")
plugin.on_unload()
check(alias_count() == 0 and removed_command == 7)
plugin = dofile("generic/input_shortcuts.lua")
plugin.on_load()
check(alias_count() == 2)
run("look|.+n", "look|north")
configure("stack off"); check(alias_count() == 1)
configure("walk off"); check(alias_count() == 0)
plugin.on_unload()
-- Failed registration reports the error and still tracks later successful IDs.
saved = {stack = true, walk = true}
fail_regex = stack_regex
plugin = dofile("generic/input_shortcuts.lua")
plugin.on_load()
check(alias_count() == 1 and aliases[next_id].regex == walk_regex)
check(messages[#messages] == "[input_shortcuts] could not register stack alias: alias cap reached")
plugin.on_unload()
check(alias_count() == 0)
fail_regex = walk_regex
plugin.on_load()
check(alias_count() == 1 and aliases[next_id].regex == stack_regex)
check(messages[#messages] == "[input_shortcuts] could not register walk alias: alias cap reached")
plugin.on_unload()
check(alias_count() == 0)
fail_regex = nil
local f = assert(io.open("generic/input_shortcuts.md", "r"))
local docs = f:read("*a"); f:close()
check(docs:find(".n;s", 1, true) and docs:find("loaded first", 1, true)
  and docs:find("end of the alias order", 1, true))
print = real_print
print("input shortcuts tests passed (" .. checks .. " checks)")
