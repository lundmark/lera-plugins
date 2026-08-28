-- wizard cwd tracking, GMCP wiring and the Tab entry point. Run from the
-- lera-plugins repo root with LERA_ROOT pointing at a built Lera checkout.
package.path = "3scapes/wizard/?.lua;" .. package.path

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

local gmcp_handlers = {}
local sent = {}
gmcp = {
  on = function(pkg, fn) gmcp_handlers[pkg] = fn; return pkg end,
  remove = function() return true end,
  send = function(pkg, data) sent[#sent + 1] = { pkg = pkg, data = data }; return true end,
  enabled = function() return true end,
}

local triggers = {}
trigger = {
  add = function(pattern, fn) triggers[#triggers + 1] = { pattern = pattern, fn = fn }; return #triggers end,
  remove = function() return true end,
}

local input_text, input_cursor = "", 1
input = {
  text = function() return input_text end,
  cursor = function() return input_cursor end,
  set_text = function(t) input_text = t end,
}

local menu_opened = nil
package.loaded["menu"] = {
  open = function(opts) menu_opened = opts end,
  close = function() end,
  is_open = function() return false end,
}
package.loaded["wm"] = {
  make_scroller = function()
    return { offset = function() return 0 end, scroll = function() end,
             scroll_to_bottom = function() end, following_tail = function() return true end,
             on_append = function() end, on_trim = function() end }
  end,
}
package.loaded["command"] = { register = function() return 1 end, unregister = function() return true end,
                              get = function() return nil end }

ui = { dirty = function() end, text = function() end, box = function() end }
lera = { time = function() return 0 end, dirty = function() end }
mud = { send = function() end }
store = { load = function() end, get = function() return nil end,
          set = function() end, save = function() end }
plugin = { get = function() return nil end }

local wizard = require("init")
local protocol = require("protocol")

-- gmcp.on, trigger.add and command.register all run in on_load, not at module
-- level, so nothing is registered until this call.
wizard.on_load()

-- ---- Core.Supported gating ------------------------------------------------

check("wiring: subscribes to Files.List", gmcp_handlers["Files.List"] ~= nil)
check("wiring: subscribes to Core.Supported", gmcp_handlers["Core.Supported"] ~= nil)

protocol.reset()
gmcp_handlers["Core.Supported"]("Core.Supported", { ["Char.Vitals"] = 1 })
check("gating: a mortal advertisement leaves Files.List unavailable",
      protocol.available() == false,
      "Files.List is omitted entirely for a mortal")

gmcp_handlers["Core.Supported"]("Core.Supported", { ["Files.List"] = 1 })
check("gating: a wizard advertisement makes it available",
      protocol.available() == true)

-- ---- cwd tracking ---------------------------------------------------------

-- Triggers are PCRE, not Lua patterns, so the capture cannot be produced with
-- string.match here. The pattern itself is asserted once below; these cases
-- drive the callback the way the engine would, with the capture supplied.
local function cd_line(path)
  for i = 1, #triggers do triggers[i].fn(path, path) end
end

check("wiring: the cd confirmation trigger is anchored PCRE",
      #triggers == 1 and triggers[1].pattern == "^(/\\S*)$",
      triggers[1] and triggers[1].pattern)

protocol.reset()
protocol.set_available(true)

-- A bare path line with no cd pending must be ignored.
cd_line("/players/simon")
check("cwd: a path line without a pending cd is ignored",
      protocol.cwd() == nil,
      "the pattern alone would match any output line that is a bare path")

wizard.on_input("cd /open")
cd_line("/open")
check("cwd: a cd confirmation sets the cwd", protocol.cwd() == "/open", tostring(protocol.cwd()))

-- The flag is one-shot: a second bare path line must not move us again.
cd_line("/elsewhere")
check("cwd: the pending flag is one-shot",
      protocol.cwd() == "/open",
      "got " .. tostring(protocol.cwd()))

for _, failure in ipairs({ "No such directory.",
                           "Illegal directory: /nope.",
                           "Invalid path with spaces in it." }) do
  protocol.reset()
  protocol.set_cwd("/open")
  wizard.on_input("cd /nope")
  wizard.on_line(failure)
  cd_line("/nope")
  check("cwd: '" .. failure .. "' disarms without moving",
        protocol.cwd() == "/open",
        "got " .. tostring(protocol.cwd()))
end

protocol.reset()
wizard.on_input("cdtest foo")
cd_line("/open")
check("cwd: a command merely starting with cd does not arm",
      protocol.cwd() == nil)

protocol.reset()
wizard.on_input("cd")
cd_line("/players/simon")
check("cwd: a bare cd arms the flag", protocol.cwd() == "/players/simon")

-- ---- disconnect -----------------------------------------------------------

protocol.set_available(true)
protocol.store("/open", { dirs = {}, files = {}, complete = true })
wizard.on_disconnect()
check("disconnect: clears the cache", protocol.lookup("/open") == nil)
check("disconnect: clears availability", protocol.available() == false)

-- ---- Tab completion -------------------------------------------------------

protocol.reset()
protocol.set_available(true)
protocol.set_cwd("/players/simon")
protocol.store("/players/simon", {
  dirs = { "archive", "areas" }, files = { "arena.c", "notes.txt" },
  complete = true, truncated = false,
})

input_text, input_cursor = "cd archi", 9
menu_opened = nil
wizard.complete()
check("tab: a unique directory completes with a trailing slash",
      input_text == "cd archive/", input_text)

input_text, input_cursor = "ar", 3
wizard.complete()
check("tab: a bare first word is left alone", input_text == "ar", input_text)

input_text, input_cursor = "cd ar", 6
menu_opened = nil
wizard.complete()
check("tab: an ambiguous cd opens the menu with directories only",
      menu_opened ~= nil and #menu_opened.items == 2,
      menu_opened and #menu_opened.items)

input_text, input_cursor = "more ar", 8
menu_opened = nil
wizard.complete()
check("tab: more offers files as well as directories",
      menu_opened ~= nil and #menu_opened.items == 3,
      menu_opened and #menu_opened.items)

-- Selecting from the menu rewrites the input line.
input_text = "more ar"
menu_opened.on_select("arena.c", 1)
check("tab: selecting a menu item inserts it",
      input_text == "more arena.c", input_text)

input_text, input_cursor = "lpc ar", 7
menu_opened = nil
wizard.complete()
check("tab: lpc completes nothing",
      input_text == "lpc ar" and menu_opened == nil, input_text)

-- A cache miss requests rather than completing.
sent = {}
input_text, input_cursor = "cd /unseen/x", 13
wizard.complete()
check("tab: a cache miss sends a request",
      #sent == 1 and sent[1].data.path == "/unseen",
      #sent .. " sent, path " .. tostring(sent[1] and sent[1].data.path))

-- An unavailable Files.List completes nothing and sends nothing.
protocol.set_available(false)
sent = {}
input_text, input_cursor = "cd archi", 9
wizard.complete()
check("tab: nothing happens when Files.List is unavailable",
      input_text == "cd archi" and #sent == 0,
      input_text .. " / " .. #sent)

print(failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
