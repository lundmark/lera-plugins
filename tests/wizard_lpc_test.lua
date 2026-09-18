-- LPC highlighting: the lexer, and the view filter that feeds it.
--
-- Run from the lera-plugins repo root with LERA_ROOT pointing at a built Lera
-- checkout.
--
-- The cases that matter are the ones a gsub-based highlighter gets wrong: a
-- comment introducer inside a string, a quote inside a comment, an escaped
-- quote, and a block comment spanning lines. Each has its own case below.
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

local sent = {}
mud = { send = function(t) sent[#sent + 1] = t end }
local triggers = {}
trigger = {
  add = function(pattern, fn) triggers[#triggers + 1] = { pattern = pattern, fn = fn }
                              return #triggers end,
  remove = function() end,
}
ui = { dirty = function() end }
gmcp = { on = function() return 1 end, send = function() return true end,
         enabled = function() return true end }

local lpc = require("lpc")
local C = lpc.COLORS
local RESET = "\27[0m"

local function plain(s) return (s:gsub("\27%[[%d;]*m", "")) end

-- Colour codes contain '[', so they are never Lua patterns here: every search
-- for one is a plain find.
local function count(s, needle)
  local n, pos = 0, 1
  while true do
    local at = s:find(needle, pos, true)
    if not at then return n end
    n, pos = n + 1, at + #needle
  end
end

-- ---- the lexer -------------------------------------------------------------

local function one(text)
  local painted = lpc.line(text)
  return painted
end

check("lexer: text survives painting unchanged",
      plain(one('int x = foo("bar"); // note')) == 'int x = foo("bar"); // note',
      plain(one('int x = foo("bar"); // note')))

check("lexer: a type is painted as a type",
      one("int x;"):find(C.type .. "int" .. RESET, 1, true) == 1,
      one("int x;"))

check("lexer: control flow is a keyword, not a type",
      one("return x;"):find(C.keyword .. "return" .. RESET, 1, true) == 1,
      one("return x;"))

check("lexer: a line comment runs to end of line",
      one("x; // int string") == "x; " .. C.comment .. "// int string" .. RESET,
      one("x; // int string"))

-- Kills a highlighter that scans for keywords before it scans for comments:
-- the words inside the comment above must NOT be painted as types.
check("lexer: keywords inside a comment stay comment-coloured",
      count(one("x; // int string"), C.type) == 0,
      one("x; // int string"))

check("lexer: a string is one run",
      one('s = "hello";'):find(C.string .. '"hello"' .. RESET, 1, true) ~= nil,
      one('s = "hello";'))

-- The case a naive implementation always gets wrong.
check("lexer: a comment introducer inside a string is not a comment",
      count(one('s = "a // b";'), C.comment) == 0,
      one('s = "a // b";'))
check("lexer: a block opener inside a string is not a comment",
      count(one('s = "a /* b";'), C.comment) == 0,
      one('s = "a /* b";'))
check("lexer: an escaped quote does not end the string",
      plain(one('s = "a \\" // still string";')) == 's = "a \\" // still string";',
      one('s = "a \\" // still string";'))

check("lexer: a decimal number is a number",
      one("x = 42;"):find(C.number .. "42" .. RESET, 1, true) ~= nil, one("x = 42;"))
check("lexer: hex is one number, not 0 then x1f",
      one("x = 0x1f;"):find(C.number .. "0x1f" .. RESET, 1, true) ~= nil, one("x = 0x1f;"))
check("lexer: a digit inside an identifier is not a number",
      count(one("foo2 = bar;"), C.number) == 0, one("foo2 = bar;"))

-- Most of a mudlib file is calls and macros; a highlighter that paints only
-- keywords leaves an area file nearly plain, which is what these cover.
check("lexer: an identifier being called is a call",
      one("set_name(x);"):find(C.func .. "set_name" .. RESET, 1, true) == 1,
      one("set_name(x);"))
check("lexer: a bare identifier is not",
      count(one("foo = 1;"), C.func) == 0, one("foo = 1;"))
check("lexer: a call through :: is still a call",
      one("::create();"):find(C.func .. "create" .. RESET, 1, true) ~= nil,
      one("::create();"))
check("lexer: whitespace before the paren does not hide a call",
      one("set_name ();"):find(C.func, 1, true) ~= nil, one("set_name ();"))
check("lexer: ALL_CAPS is a macro",
      one("inherit ANGPATH_MONSTER_INHERIT;"):find(C.macro .. "ANGPATH_MONSTER_INHERIT" .. RESET,
                                                   1, true) ~= nil,
      one("inherit ANGPATH_MONSTER_INHERIT;"))
check("lexer: a macro wins over the call colour when it is called",
      one("SETMINE(x);"):find(C.macro .. "SETMINE" .. RESET, 1, true) == 1,
      one("SETMINE(x);"))
-- $N$ in a combat message is not a macro, and neither is a single capital.
check("lexer: one capital letter is not a macro",
      count(one("x = N;"), C.macro) == 0, one("x = N;"))
check("lexer: a keyword still beats both",
      one("return foo();"):find(C.keyword .. "return" .. RESET, 1, true) == 1,
      one("return foo();"))

check("lexer: a preprocessor directive is painted",
      one("#include <files.h>"):find(C.preproc .. "#include" .. RESET, 1, true) == 1,
      one("#include <files.h>"))
check("lexer: a leading-space directive still counts",
      one("  #define X 1"):find(C.preproc, 1, true) ~= nil, one("  #define X 1"))

-- ---- block comments across lines -------------------------------------------

do
  local state = lpc.new_state()
  local l1, l2, l3
  l1, state = lpc.line("/*", state)
  check("block: an unterminated opener leaves the state in a comment",
        state.in_comment == true)
  l2, state = lpc.line(' * int x = "not a string";', state)
  check("block: the body is all comment, types and strings included",
        count(l2, C.type) == 0 and count(l2, C.string) == 0, l2)
  l3, state = lpc.line(" */ int after;", state)
  check("block: the closer ends it and code after it is painted again",
        state.in_comment == false and l3:find(C.type .. "int" .. RESET, 1, true) ~= nil, l3)
  check("block: nothing is lost across the three lines",
        plain(l1) == "/*" and plain(l3) == " */ int after;", plain(l3))
end

do
  local _, state = lpc.line("int x; /* here */ int y;")
  check("block: an opener and closer on ONE line does not arm the state",
        state.in_comment == false)
end

-- ---- applies ---------------------------------------------------------------

check("applies: .c and .h are LPC", lpc.applies("/players/x/foo.c") and lpc.applies("bar.h"))
check("applies: a save file is not", lpc.applies("gather_daemon.o") == false)
check("applies: an extensionless file is not", lpc.applies("Makefile") == false)

-- ---- the view filter -------------------------------------------------------

local actions = require("actions")
actions.install()   -- registers the uall-prompt trigger the cases below fire

sent = {}
actions.view("/players/shaman/include/daemon_helper.h")
check("view: pages the file with more", sent[1] == "more /players/shaman/include/daemon_helper.h",
      tostring(sent[1]))
check("view: and marks the view as running",
      actions.viewing() == "/players/shaman/include/daemon_helper.h", tostring(actions.viewing()))

check("view: file lines come back painted",
      actions.on_line("int x;"):find(C.type, 1, true) ~= nil,
      actions.on_line("int x;"))

check("view: the pager's own status line is never painted",
      actions.on_line("More: [x] Line: [1/26] Cmds: [u/d/q]") ==
      "More: [x] Line: [1/26] Cmds: [u/d/q]")

-- `more` writes its status without a newline, so the next page's first line
-- arrives JOINED to it. Treating the whole line as furniture left the first
-- line of every page after the first unpainted.
do
  local joined = actions.on_line(
    "More: [x.c] Line: [48/48] Cmds: [u/d/q] #pragma strict_types")
  check("view: content sharing the status line is still painted",
        joined:find(C.preproc .. "#pragma" .. RESET, 1, true) ~= nil, joined)
  check("view: and the status itself is left plain",
        joined:find("More: [x.c] Line: [48/48] Cmds: [u/d/q] ", 1, true) == 1, joined)
end

-- Same shape, but the page ended: the tail is the last of the file and is
-- worth colouring before the filter stops.
do
  local tail = actions.on_line("More: [x.c] Line: [48/48] Cmds: [u/d/q] EOF")
  check("view: an EOF status ends the view", actions.viewing() == nil, tail)
  actions.view("/x/foo.c")
  local last = actions.on_line("More: [x.c] Line: [48/48] Cmds: [u/d/q] EOF int x;")
  check("view: content after EOF on the same line is painted too",
        last:find(C.type .. "int" .. RESET, 1, true) ~= nil, last)
  check("view: and the view still ends there", actions.viewing() == nil)
  actions.view("/players/shaman/include/daemon_helper.h")
end

-- A line that already carries colour belongs to something else.
check("view: an already-coloured line is passed through untouched",
      actions.on_line("\27[31malready red\27[0m") == "\27[31malready red\27[0m")

check("view: EOF ends it", (function()
  actions.on_line("More: [x] Line: [26/26] Cmds: [u/d/q] EOF")
  return actions.viewing() == nil
end)())
check("view: and ordinary output afterwards is left alone",
      actions.on_line("int x;") == "int x;",
      "the filter must not still be painting the room description")

-- Paging keeps it running; anything else does not.
actions.view("/players/x/foo.c")
actions.on_input("d")
check("view: a pager key keeps the view running", actions.viewing() ~= nil)
actions.on_input("look")
check("view: any other input ends it", actions.viewing() == nil,
      "otherwise a q that never came would leave the filter armed over normal output")

-- A file with nothing to highlight is still tracked (so q/EOF work) but is
-- never painted.
actions.view("/players/x/data.o")
check("view: a non-LPC file is passed through unpainted",
      actions.on_line("int x;") == "int x;" and actions.viewing() ~= nil,
      actions.on_line("int x;"))

actions.reset()
check("view: reset tears the filter down", actions.viewing() == nil)

if failures > 0 then os.exit(1) end
print("ALL WIZARD LPC TESTS PASSED")

-- ---- recursive uall/lall ---------------------------------------------------
--
-- Neither command recurses on the MUD (uall.c walks get_dir(path + "*"), lall.c
-- get_dir(path + "*.c"), and neither descends), so the walk happens here: one
-- ordinary command per directory, found through the pane's own listing.

local protocol = require("protocol")
protocol.reset()
protocol.set_available(true)
protocol.set_cwd("/a")
protocol.store("/a",     { dirs = { "b", "c" }, files = {}, complete = true })
protocol.store("/a/b",   { dirs = { "d" },      files = {}, complete = true })
protocol.store("/a/b/d", { dirs = {},           files = {}, complete = true })
protocol.store("/a/c",   { dirs = {},           files = {}, complete = true })

sent = {}
actions.run_recursive("lall", "/a")
check("recursive: every directory under the root gets its own command",
      #sent == 4, #sent .. ": " .. table.concat(sent, " | "))
check("recursive: the root goes first, then depth-first",
      sent[1] == "lall /a" and sent[2] == "lall /a/b" and
      sent[3] == "lall /a/b/d" and sent[4] == "lall /a/c",
      table.concat(sent, " | "))
check("recursive: the walk is over once the tree is exhausted",
      actions.walking() == nil)

-- uall prompts once per directory outside /players, so the auto-answer has to
-- count rather than hold a single path.
sent = {}
actions.run_recursive("uall", "/a")
check("recursive: one armed answer per directory", actions.pending_count() == 4,
      actions.pending_count())

local answered = 0
for i = 1, 4 do
  local before = #sent
  triggers[#triggers].fn("You are about to update all the files in the directory:")
  if #sent > before and sent[#sent] == "y" then answered = answered + 1 end
end
check("recursive: each prompt is answered exactly once", answered == 4, answered)
check("recursive: and the arm is spent afterwards", actions.pending_count() == 0,
      actions.pending_count())

local before = #sent
triggers[#triggers].fn("You are about to update all the files in the directory:")
check("recursive: a fifth prompt is not ours to answer", #sent == before)

-- A second walk while one is running would interleave two sets of commands.
protocol.store("/a", { dirs = { "b", "c" }, files = {}, complete = true })
check("recursive: refuses to start a walk on top of nothing is fine",
      actions.run_recursive("lall", "") == false)

-- ---- ferry entries ---------------------------------------------------------
--
-- The plugin sandbox has no disk and no shell, so ferry runs in a bridge
-- process (github.com/skuggo/ferry-bridge) reached over ipc. The rule that
-- matters here is that a wizard with no bridge running sees no ferry entries
-- at all: an entry
-- that cannot work should not invite the click.

local overlay = require("overlay")

local function ferry_rows()
  local n = 0
  for _, it in ipairs(overlay.items() or {}) do
    if tostring(it.value):find("^ferry%-") then n = n + 1 end
  end
  return n
end

-- No ipc at all: the sandbox of a client built without it, or a session that
-- never initialised one.
ipc = nil
actions.file_menu("/players/x/foo.c", { x = 0, y = 0 })
check("ferry: no ipc means no ferry entries", ferry_rows() == 0, ferry_rows())
check("ferry: and the MUD commands are still all there",
      #overlay.items() == 10, #overlay.items())
overlay.close()

-- ipc present, but nothing listening.
local listed = {}
message_cb = nil
ipc = {
  init = function() return true end,
  on_message = function(f) message_cb = f end,
  list = function() return listed end,
  connect = function() return 0 end,
  send = function() return true end,
  disconnect = function() end,
}
package.loaded["ferry"] = nil
package.loaded["actions"] = nil
actions = require("actions")

actions.file_menu("/players/x/foo.c", { x = 0, y = 0 })
check("ferry: no bridge listening means no ferry entries", ferry_rows() == 0, ferry_rows())
overlay.close()

-- A bridge appears.
listed = { "some-other-session", "ferry-bridge" }
actions.file_menu("/players/x/foo.c", { x = 0, y = 0 })
check("ferry: a listening bridge adds pull/push/cc", ferry_rows() == 3, ferry_rows())
do
  local labels = {}
  for _, it in ipairs(overlay.items()) do labels[it.value] = it end
  check("ferry: pull is offered and is not marked dangerous",
        labels["ferry-pull"] ~= nil and labels["ferry-pull"].kind == nil)
  check("ferry: push IS marked dangerous -- it overwrites the MUD",
        labels["ferry-push"] ~= nil and labels["ferry-push"].kind == "danger")
end

-- Choosing pull sends one framed request; choosing push asks first.
do
  local sent_msgs = {}
  ipc.send = function(peer, msg) sent_msgs[#sent_msgs + 1] = msg; return true end

  local items = overlay.items()
  local function pick(value)
    for i, it in ipairs(items) do
      if it.value == value then
        local rect = overlay.layout(60, 20)
        overlay.on_click(rect.x + 1, rect.y + (rect.bordered and 1 or 0) + i - 1, 60, 20)
        return
      end
    end
  end

  -- Both transfers ask first: a pull overwrites what is on disk, a push
  -- overwrites what is on the MUD.
  pick("ferry-pull")
  check("ferry: pull asks before overwriting local files",
        #sent_msgs == 0 and overlay.active(), #sent_msgs)

  items = overlay.items()
  pick("yes")
  check("ferry: and goes out as one request once confirmed",
        #sent_msgs == 1 and sent_msgs[1].op == "pull"
        and sent_msgs[1].path == "/players/x/foo.c",
        sent_msgs[1] and sent_msgs[1].op)

  actions.file_menu("/players/x/foo.c", { x = 0, y = 0 })
  items = overlay.items()
  pick("ferry-push")
  check("ferry: push asks before overwriting the MUD",
        #sent_msgs == 1 and overlay.active(), #sent_msgs)
end

-- The bridge is a process the wizard starts by hand, so "not running" is a
-- normal state. It has to be visible: three rows quietly missing from a menu
-- looks exactly like something being broken.
do
  local ferry = require("ferry")

  listed = {}
  check("ferry: says so when no bridge is running",
        ferry.status_line():find("no bridge", 1, true) ~= nil, ferry.status_line())

  listed = { "ferry-bridge" }
  check("ferry: says so when one is",
        ferry.status_line():find("ready", 1, true) ~= nil, ferry.status_line())

  local saved = ipc
  ipc = nil
  check("ferry: and says when the client has no ipc at all",
        ferry.status_line():find("unavailable", 1, true) ~= nil, ferry.status_line())
  ipc = saved
end

-- ---- progress --------------------------------------------------------------
--
-- A directory transfer is the case that needed this: ferry reports one line
-- per file, and collecting them until the process ends means silence for the
-- length of the transfer and then everything at once. The bridge streams them,
-- and these are the two things the client must get right -- show each one with
-- a percentage, and not print the whole transfer a second time at the end.

do
  local ferry = require("ferry")
  listed = { "ferry-bridge" }

  local said = {}
  local real_print = print
  print = function(line) said[#said + 1] = tostring(line) end

  ferry.available()
  ferry.run("push", "/players/x")
  local function feed(msg) message_cb("ferry-bridge", msg) end
  feed({ progress = true, op = "push", done = 1, total = 4, line = "pushed a.c" })
  feed({ progress = true, op = "push", done = 3, total = 4, line = "pushed c.c" })
  feed({ id = 1, ok = true, op = "push", path = "/players/x",
         output = "pushed a.c\nerror: b.c was skipped" })
  print = real_print

  local joined = table.concat(said, "\n")
  check("progress: each file is reported with a percentage",
        joined:find("1/4 (25%)", 1, true) ~= nil
        and joined:find("3/4 (75%)", 1, true) ~= nil, joined)
  check("progress: the finish is announced", joined:find("done", 1, true) ~= nil, joined)
  check("progress: a line already shown is not repeated in the summary",
        select(2, joined:gsub("pushed a%.c", "")) == 1, joined)
  check("progress: but anything NOT already shown is",
        joined:find("b.c was skipped", 1, true) ~= nil, joined)
end

-- ---- abort, and asking first ----------------------------------------------

do
  -- pane pulls in wm for its scroller; this suite has no screen, so stub it
  -- the way the pane suite does.
  package.loaded["wm"] = package.loaded["wm"] or {
    make_scroller = function(opts)
      return {
        offset = function() return 0 end,
        scroll = function() end,
        scroll_to_bottom = function() end,
        following_tail = function() return true end,
        count = opts.count,
      }
    end,
  }
  ui.rect = ui.rect or function(x, y, w, h) return { x = x, y = y, w = w, h = h } end
  ui.text_ansi = ui.text_ansi or function() end
  ui.box = ui.box or function() end

  local ferry = require("ferry")
  local pane = require("pane")
  local overlay = require("overlay")
  listed = { "ferry-bridge" }

  local sent_msgs = {}
  ipc.send = function(_, msg) sent_msgs[#sent_msgs + 1] = msg; return true end

  -- Nothing running: a right-click is a menu, not an abort.
  check("abort: nothing to abort when nothing runs", ferry.running() == nil)

  ferry.run("pull", "/players/x")
  check("abort: a running command is visible to the pane",
        (ferry.running() or ""):find("pull", 1, true) ~= nil, tostring(ferry.running()))

  overlay.close()
  local consumed = pane.on_pointer({ kind = "down", button = "right", x = 1, y = 2,
                                     inside = true, width = 30, height = 16 })
  check("abort: a right-click anywhere sends cancel, and opens no menu",
        consumed == true and not overlay.active()
        and sent_msgs[#sent_msgs].op == "cancel",
        tostring(sent_msgs[#sent_msgs] and sent_msgs[#sent_msgs].op))
  check("abort: and the pane stops offering it", ferry.running() == nil)

  -- Both transfers ask first now: a pull overwrites what is on disk just as a
  -- push overwrites what is on the MUD.
  local function confirms(list, key)
    for _, spec in ipairs(list) do
      if spec.key == key then return spec.confirm == true end
    end
    return nil
  end
  check("abort: pull asks before overwriting local files",
        confirms(actions.FERRY_ACTIONS, "ferry-pull") == true)
  check("abort: push asks too", confirms(actions.FERRY_ACTIONS, "ferry-push") == true)
  check("abort: cc does not -- it changes nothing",
        confirms(actions.FERRY_ACTIONS, "ferry-cc") == false)

  -- A directory push says that its scope is narrowed, and by what.
  check("abort: the directory push confirmation names the exclusions",
        (actions.FERRY_DIR_SCOPE.push or ""):find("data/", 1, true) ~= nil,
        actions.FERRY_DIR_SCOPE.push)
end

-- ---- silence ---------------------------------------------------------------
--
-- A directory that turns out to need no transfer makes ferry print NOTHING,
-- for as long as the scan takes -- measured at 47 seconds on a real tree. The
-- client used to show that as a long nothing followed by "done", which reads
-- as "did that work?". Two frames fix it: a heartbeat while it runs, and an
-- explicit answer at the end.

do
  local ferry = require("ferry")
  listed = { "ferry-bridge" }

  local said = {}
  local real_print = print
  print = function(line) said[#said + 1] = tostring(line) end

  ferry.available()
  ferry.run("pull", "/players/x")
  message_cb("ferry-bridge", { progress = true, op = "pull", waiting = true })
  check("silence: a heartbeat says it is still working",
        (said[#said] or ""):find("still working", 1, true) ~= nil, said[#said])
  check("silence: and repeats how to stop it",
        (said[#said] or ""):find("abort", 1, true) ~= nil, said[#said])

  message_cb("ferry-bridge", { id = 1, ok = true, op = "pull", path = "/players/x",
                               output = "", nothing_to_do = true })
  print = real_print
  check("silence: an in-sync tree says so, rather than a bare done",
        (said[#said] or ""):find("already in sync", 1, true) ~= nil, said[#said])
  check("silence: and the job is over", ferry.running() == nil)
end

-- The pane names a running command, so the state the abort gesture depends on
-- is visible rather than implied. If this row is missing, right-click will not
-- fire either -- which is exactly the confusion it exists to prevent.
do
  local ferry = require("ferry")
  local pane = require("pane")
  local drawn = {}
  local real = ui.text_ansi
  ui.text_ansi = function(rect, text) drawn[#drawn + 1] = text end

  ferry.run("push", "/players/x")
  pane.render({ x = 0, y = 0, w = 60, h = 12 }, {})
  ui.text_ansi = real

  local joined = table.concat(drawn, "\n"):gsub("\27%[[%d;]*m", "")
  check("silence: the pane shows what is running",
        joined:find("push /players/x", 1, true) ~= nil, joined:sub(1, 120))
  check("silence: and that right-click aborts it",
        joined:find("right%-click to abort") ~= nil, joined:sub(1, 120))
  ferry.reset()
end
