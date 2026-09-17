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
