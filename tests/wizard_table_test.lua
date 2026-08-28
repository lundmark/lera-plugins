-- wizard command table and completion decision. Run from the lera-plugins repo
-- root with LERA_ROOT pointing at a built Lera checkout.
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

local DIRS = { "archive", "areas" }
local FILES = { "arena.c", "arena.h", "notes.txt" }

local function names(cands)
  local out = {}
  for i = 1, #cands do out[i] = cands[i].name end
  table.sort(out)
  return table.concat(out, ",")
end

-- ---- rule -----------------------------------------------------------------

check("rule: cd is dir", complete.rule("cd").kind == "dir")
check("rule: more is file", complete.rule("more").kind == "file")
check("rule: load is lpc", complete.rule("load").kind == "lpc")
check("rule: ul is lpc", complete.rule("ul").kind == "lpc")
check("rule: cc is lpc", complete.rule("cc").kind == "lpc")
check("rule: update is lpc", complete.rule("update").kind == "lpc")
check("rule: lpc offers nothing", complete.rule("lpc").kind == "none")
check("rule: cp is any", complete.rule("cp").kind == "any")
check("rule: unlisted falls back to any",
      complete.rule("frobnicate").kind == "any",
      "the table narrows or corrects; it is never a gate")
check("rule: nil command falls back to any", complete.rule(nil).kind == "any")
check("rule: grep's first path argument is 2",
      complete.rule("grep").from_arg == 2,
      "grep's argument 1 is a search term")
check("rule: everything else starts at argument 1",
      complete.rule("cp").from_arg == 1 and complete.rule("frobnicate").from_arg == 1)

-- ---- candidates -----------------------------------------------------------

check("candidates: dir kind offers directories only",
      names(complete.candidates(DIRS, FILES, "ar", "dir")) == "archive,areas")

check("candidates: file kind still offers directories",
      names(complete.candidates(DIRS, FILES, "ar", "file")) == "archive,arena.c,arena.h,areas",
      "a files-only command must still be able to descend")

check("candidates: lpc kind offers .c files and directories",
      names(complete.candidates(DIRS, FILES, "ar", "lpc")) == "archive,arena.c,areas",
      "arena.h is not a loadable object")

check("candidates: none kind offers nothing",
      #complete.candidates(DIRS, FILES, "ar", "none") == 0)

check("candidates: any kind offers everything matching",
      names(complete.candidates(DIRS, FILES, "ar", "any")) == "archive,arena.c,arena.h,areas")

check("candidates: an empty prefix matches all",
      #complete.candidates(DIRS, FILES, "", "any") == 5)

check("candidates: a non-matching prefix matches none",
      #complete.candidates(DIRS, FILES, "zz", "any") == 0)

do
  local cands = complete.candidates(DIRS, FILES, "archi", "any")
  check("candidates: directories are flagged as such",
        #cands == 1 and cands[1].is_dir == true)
end

do
  local cands = complete.candidates(DIRS, FILES, "notes", "any")
  check("candidates: files are not flagged as directories",
        #cands == 1 and cands[1].is_dir == false)
end

-- ---- common_prefix --------------------------------------------------------

check("common_prefix: shared stem",
      complete.common_prefix({ "arena.c", "arena.h" }) == "arena.")
check("common_prefix: single entry is itself",
      complete.common_prefix({ "archive" }) == "archive")
check("common_prefix: nothing shared", complete.common_prefix({ "ab", "cd" }) == "")
check("common_prefix: empty list", complete.common_prefix({}) == "")

-- ---- decide ---------------------------------------------------------------

check("decide: no candidates does nothing",
      complete.decide({}, "zz") == nil)

do
  local d = complete.decide(complete.candidates(DIRS, FILES, "archi", "any"), "archi")
  check("decide: a lone directory inserts with a trailing slash",
        d ~= nil and d.action == "insert" and d.text == "archive/",
        d and d.text)
end

do
  local d = complete.decide(complete.candidates(DIRS, FILES, "notes", "any"), "notes")
  check("decide: a lone file inserts with no slash",
        d ~= nil and d.action == "insert" and d.text == "notes.txt",
        d and d.text)
end

do
  local d = complete.decide(complete.candidates(DIRS, FILES, "aren", "any"), "aren")
  check("decide: an ambiguous match extends to the common prefix",
        d ~= nil and d.action == "insert" and d.text == "arena.",
        d and d.text)
end

do
  -- "ar" is already the common prefix of archive/areas/arena.*, so there is
  -- nothing to insert and the menu is the only useful answer.
  local d = complete.decide(complete.candidates(DIRS, FILES, "ar", "any"), "ar")
  check("decide: a common prefix that adds nothing opens the menu",
        d ~= nil and d.action == "menu", d and d.action)
  check("decide: the menu lists every candidate",
        d ~= nil and d.items ~= nil and #d.items == 4,
        d and d.items and #d.items)
end

do
  local d = complete.decide(complete.candidates(DIRS, FILES, "ar", "any"), "ar")
  local labels = {}
  for i = 1, #d.items do labels[i] = d.items[i].label end
  table.sort(labels)
  check("decide: menu labels mark directories with a slash",
        table.concat(labels, ",") == "archive/,arena.c,arena.h,areas/",
        table.concat(labels, ","))
  local values = {}
  for i = 1, #d.items do values[d.items[i].label] = d.items[i].value end
  check("decide: a menu value is the text to insert",
        values["archive/"] == "archive/" and values["arena.c"] == "arena.c")
end

print(failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
