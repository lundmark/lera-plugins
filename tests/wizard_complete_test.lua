-- wizard completion context parsing. Run from the lera-plugins repo root with
-- LERA_ROOT pointing at a built Lera checkout.
--
-- complete.lua is pure: it touches no lera global. This file deliberately
-- defines no stubs, so any accidental dependency on gmcp/input/wm fails the
-- suite outright rather than quietly working.
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

local complete = require("complete")

-- ---- is_flag / is_path_shaped ---------------------------------------------

check("flag: -rf is a flag", complete.is_flag("-rf") == true)
check("flag: lone - is not a flag",
      complete.is_flag("-") == false,
      "cd - means the previous directory, so it is an argument")
check("flag: bare word is not a flag", complete.is_flag("ar") == false)

check("shape: absolute", complete.is_path_shaped("/players/si") == true)
check("shape: tilde", complete.is_path_shaped("~/ar") == true)
check("shape: dot", complete.is_path_shaped("./f") == true)
check("shape: contains slash", complete.is_path_shaped("players/si") == true)
check("shape: bare word is not path shaped", complete.is_path_shaped("ar") == false)

-- ---- context --------------------------------------------------------------

local function ctx(line, cursor)
  return complete.context(line, cursor or (#line + 1))
end

do
  local c = ctx("cd ar")
  check("context: cd ar -> word ar", c ~= nil and c.word == "ar", c and c.word)
  check("context: cd ar -> command cd", c ~= nil and c.command == "cd")
  check("context: cd ar -> arg_index 1", c ~= nil and c.arg_index == 1, c and c.arg_index)
  check("context: cd ar -> word span 4..5",
        c ~= nil and c.word_start == 4 and c.word_end == 5,
        c and (c.word_start .. ".." .. c.word_end))
end

check("context: bare word in first position does not complete",
      ctx("ar") == nil,
      "a bare first word is a command name")

check("context: path-shaped first word does complete",
      ctx("/players/si") ~= nil,
      "a path is a path in any position")

check("context: empty line does not complete", ctx("") == nil)

check("context: flag word does not complete",
      ctx("cp -rf") == nil,
      "-rf is a flag, not a path")

do
  local c = ctx("cp -rf sr")
  check("context: flags do not count as arguments",
        c ~= nil and c.arg_index == 1,
        "sr is argument 1; got " .. tostring(c and c.arg_index))
end

do
  local c = ctx("grep pattern fi")
  check("context: grep second argument is arg_index 2",
        c ~= nil and c.arg_index == 2,
        tostring(c and c.arg_index))
end

do
  local c = ctx("cd ")
  check("context: trailing space gives an empty word at arg 1",
        c ~= nil and c.word == "" and c.arg_index == 1,
        c and ("'" .. c.word .. "' " .. c.arg_index))
  check("context: empty word span is start=cursor, end=cursor-1",
        c ~= nil and c.word_start == 4 and c.word_end == 3,
        c and (c.word_start .. ".." .. c.word_end))
end

do
  -- The cursor is mid-line: only text to its left is the word.
  -- Byte 12 is "t": the cursor sits after the slash, so the word is
  -- "archive/". At byte 11 it would sit before the slash and the word would be
  -- "archive" -- the off-by-one worth pinning down, since both look plausible.
  local c = complete.context("cd archive/thing", 12)
  check("context: cursor mid-word truncates at the cursor",
        c ~= nil and c.word == "archive/",
        c and c.word)
end

-- ---- split ----------------------------------------------------------------

do
  local dir, prefix = complete.split("/players/si")
  check("split: absolute", dir == "/players/" and prefix == "si",
        tostring(dir) .. " | " .. tostring(prefix))
end

do
  local dir, prefix = complete.split("ar")
  check("split: bare word has empty dir", dir == "" and prefix == "ar",
        tostring(dir) .. " | " .. tostring(prefix))
end

do
  local dir, prefix = complete.split("archive/")
  check("split: trailing slash has empty prefix",
        dir == "archive/" and prefix == "",
        tostring(dir) .. " | " .. tostring(prefix))
end

-- ---- apply ----------------------------------------------------------------

do
  local c = ctx("cd ar")
  local line, cursor = complete.apply("cd ar", c, "ar", "archive/")
  check("apply: replaces the prefix only", line == "cd archive/", line)
  check("apply: cursor lands after the insertion", cursor == 12, tostring(cursor))
end

do
  local c = complete.context("cd ar there", 6)
  local line = complete.apply("cd ar there", c, "ar", "archive/")
  check("apply: preserves text after the cursor",
        line == "cd archive/ there", line)
end

do
  local c = ctx("more sub/fi")
  local line = complete.apply("more sub/fi", c, "fi", "file.c")
  check("apply: keeps the directory part of the word",
        line == "more sub/file.c", line)
end

print(failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
