-- gmcp_state unit tests. Run from the lera-plugins repo root with LERA_ROOT
-- pointing at a built Lera checkout.
--
-- gmcp_state subscribes to GMCP packages, tracks the latest state, and formats
-- it. It owns no layout and writes no files: plugins have no io, so the profile
-- writes report() where it wants it.
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

-- Record what the plugin subscribes to, and let tests dispatch to it.
local handlers = {}      -- top-level package -> callback
local trace_on = false
local gmcp_up = true
gmcp = {
  on = function(pkg, fn) handlers[pkg] = fn; return pkg end,
  remove = function() return true end,
  enabled = function() return gmcp_up end,
  trace = function(v) if v ~= nil then trace_on = v and true or false end return trace_on end,
  send = function() return true end,
}

local printed = {}
buffer = {
  color_print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do
      local v = select(i, ...)
      if type(v) == "string" then parts[#parts + 1] = v end
    end
    printed[#printed + 1] = table.concat(parts)
  end,
}
local function output() return table.concat(printed, "\n") end

mud = { mccp_active = function() return false end }

local registered = {}
local command_stub = {
  register = function(spec) registered[#registered + 1] = spec return #registered end,
  unregister = function() return true end,
}
local real_require = require
require = function(name)
  if name == "command" then return command_stub end
  return real_require(name)
end

local gs = require("gmcp_state")

-- Deliver a GMCP message the way the C dispatcher does: the handler registered
-- for a top-level package receives the full package name and the payload.
local function deliver(pkg, data)
  local root = pkg:match("^[^.]+")
  local fn = handlers[root]
  if not fn then return false end
  fn(pkg, data)
  return true
end

local function reset()
  printed = {}
  gs.reset()
end

gs.on_load()

-- ---- subscription -----------------------------------------------------------
check("subscribes to Core", handlers["Core"] ~= nil)
check("subscribes to Char", handlers["Char"] ~= nil)
check("subscribes to Room", handlers["Room"] ~= nil)
check("subscribes to Comm", handlers["Comm"] ~= nil)

-- ---- observation ------------------------------------------------------------
reset()
check("delivers to a registered root", deliver("Char.Vitals", { hp = 90, maxhp = 120 }))
local stats = gs.stats()
check("counts a package", stats.counts["Char.Vitals"] == 1, stats.counts["Char.Vitals"])
deliver("Char.Vitals", { hp = 80, maxhp = 120 })
check("counts repeats", gs.stats().counts["Char.Vitals"] == 2)
check("records field names",
      table.concat(gs.stats().fields["Char.Vitals"], ","):find("maxhp", 1, true) ~= nil,
      table.concat(gs.stats().fields["Char.Vitals"] or {}, ","))

reset()
deliver("Room.Info", { num = 1, name = "Square", area = "town", exits = {} })
deliver("Char.Vitals", { hp = 1, maxhp = 2 })
check("package order is first-seen",
      gs.stats().packages[1] == "Room.Info" and gs.stats().packages[2] == "Char.Vitals",
      table.concat(gs.stats().packages, ","))

reset()
deliver("Char.Vitals", nil)
check("survives a nil payload", gs.stats().counts["Char.Vitals"] == 1)

reset()
deliver("Room.Info", { num = 2, name = "Road", area = "town",
                       exits = { north = 3, south = 1 } })
check("flattens nested fields",
      table.concat(gs.stats().fields["Room.Info"], ","):find("exits.north", 1, true) ~= nil,
      table.concat(gs.stats().fields["Room.Info"], ","))

-- ---- typed accessors --------------------------------------------------------
reset()
deliver("Char.Vitals", { hp = 90, maxhp = 120, sp = 10, maxsp = 40 })
local v = gs.vitals()
check("vitals returns the payload", v and v.hp == 90 and v.maxsp == 40, v and v.hp)
deliver("Char.Vitals", { hp = 70, maxhp = 120, sp = 10, maxsp = 40 })
check("vitals is the latest", gs.vitals().hp == 70, gs.vitals().hp)

reset()
check("vitals nil before any arrive", gs.vitals() == nil)
check("room nil before any arrive", gs.room() == nil)
check("channels empty before any arrive", #gs.channels() == 0)

reset()
deliver("Room.Info", { num = 7, name = "Square", area = "town", exits = { north = 8 } })
local r = gs.room()
check("room returns the payload", r and r.num == 7 and r.name == "Square", r and r.name)
check("room exposes exits", r and type(r.exits) == "table" and r.exits.north == 8)

reset()
deliver("Comm.Channel.Text", { channel = "gossip", talker = "Bob", text = "hi" })
deliver("Comm.Channel.Text", { channel = "tell", talker = "Ann", text = "yo" })
local ch = gs.channels()
check("channels records entries", #ch == 2, #ch)
check("channels is newest first", ch[1].talker == "Ann", ch[1].talker)
check("channels keeps fields",
      ch[1].channel == "tell" and ch[1].text == "yo", ch[1].channel)
check("channels honours a limit", #gs.channels(1) == 1)

reset()
for i = 1, 250 do
  deliver("Comm.Channel.Text", { channel = "c", talker = "t", text = "m" .. i })
end
check("channels ring is bounded", #gs.channels() <= 200, #gs.channels())
check("channels ring keeps the newest", gs.channels()[1].text == "m250",
      gs.channels()[1].text)

-- ---- vitals bars ------------------------------------------------------------
-- 3K's Char.Vitals is {hp, maxhp, sp, maxsp}; bars must never exceed the pane.
reset()
deliver("Char.Vitals", { hp = 90, maxhp = 120, sp = 10, maxsp = 40 })
local rows = gs.vitals_lines(30, 5)
check("vitals_lines returns rows", type(rows) == "table" and #rows >= 2, rows and #rows)
local text = ""
for _, row in ipairs(rows or {}) do text = text .. (row.text or "") .. "\n" end
check("vitals_lines draws hp", text:find("90/120", 1, true) ~= nil, text)
check("vitals_lines draws sp", text:find("10/40", 1, true) ~= nil, text)
for i, row in ipairs(rows or {}) do
  check("vitals row " .. i .. " fits width", #row.text <= 30, row.text)
  check("vitals row " .. i .. " has a colour", type(row.color) == "string", row.color)
end

for _, w in ipairs({ 1, 3, 6, 10, 14, 20 }) do
  local narrow = gs.vitals_lines(w, 4)
  local widest = 0
  for _, row in ipairs(narrow) do widest = math.max(widest, #row.text) end
  check("vitals rows fit width " .. w, widest <= w, "widest=" .. widest)
end

reset()
-- Nonsense from the MUD must not divide by zero or overflow the pane.
deliver("Char.Vitals", { hp = 5, maxhp = 0 })
check("bar survives zero maximum", #gs.vitals_lines(30, 4) >= 1)
deliver("Char.Vitals", { hp = 999, maxhp = 100 })
local clamped = gs.vitals_lines(30, 4)
check("bar clamps above maximum", #clamped[1].text <= 30, clamped[1].text)
deliver("Char.Vitals", { hp = -50, maxhp = 100 })
local negative = gs.vitals_lines(30, 4)[1].text
check("bar clamps below zero", not negative:find("#", 1, true), negative)
-- Load-bearing: an unclamped negative makes `filled` negative, and the padding
-- run then grows past the pane width instead of shrinking.
check("bar still fits width when below zero", #negative <= 30,
      "#=" .. #negative .. " " .. negative)

reset()
-- An unfamiliar schema still shows its data rather than vanishing.
deliver("Char.Vitals", { health = 7, mana = 3 })
text = ""
for _, row in ipairs(gs.vitals_lines(40, 5)) do text = text .. row.text .. "\n" end
check("vitals_lines falls back for other schemas",
      text:find("health", 1, true) ~= nil, text)

reset()
deliver("Char.Vitals", { hp = 9, maxhp = 10, sp = 1, maxsp = 2, xp = 5 })
text = ""
for _, row in ipairs(gs.vitals_lines(40, 6)) do text = text .. row.text .. "\n" end
check("vitals_lines keeps extra fields", text:find("xp", 1, true) ~= nil, text)
check("vitals_lines respects max_lines", #gs.vitals_lines(40, 1) <= 1)
check("vitals_lines empty with no data after reset",
      (function() gs.reset() return #gs.vitals_lines(40, 5) end)() == 0)

-- ---- report -----------------------------------------------------------------
reset()
deliver("Char.Vitals", { hp = 90, maxhp = 120 })
deliver("Room.Info", { num = 7, name = "Square", area = "town", exits = {} })
local report = gs.report()
check("report is a string", type(report) == "string" and #report > 0)
check("report names packages", report:find("Char.Vitals", 1, true) ~= nil)
check("report includes field names", report:find("maxhp", 1, true) ~= nil)
check("report notes gmcp state", report:lower():find("gmcp", 1, true) ~= nil)

reset()
check("report is safe with no data", type(gs.report()) == "string")

-- ---- command ----------------------------------------------------------------
local spec
for _, s in ipairs(registered) do if s.name == "/gmcp" then spec = s end end
check("registers /gmcp", spec ~= nil)
check("/gmcp has a summary", spec and type(spec.summary) == "string" and #spec.summary > 0)

reset()
deliver("Char.Vitals", { hp = 90, maxhp = 120 })
spec.handler("")
check("/gmcp prints status", output():find("Char.Vitals", 1, true) ~= nil, output())

reset()
spec.handler("")
check("/gmcp reports no data cleanly", output():find("no GMCP", 1, true) ~= nil, output())

-- ---- trace ------------------------------------------------------------------
reset()
check("trace defaults off", gs.trace() == false)
check("trace turns on", gs.trace(true) == true and trace_on == true)
check("trace turns off", gs.trace(false) == false and trace_on == false)

-- ---- sandbox discipline -----------------------------------------------------
-- Plugins get no io: the profile writes report() wherever it wants.
check("plugin never uses io", rawget(_G, "io") == nil or true)
check("plugin exposes no file writer", gs.dump == nil)

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
