-- speedwalk unit tests: M.match_target and M.is_valid_target (Task T, Part 1).
-- Run from the lera-plugins repo root with LERA_ROOT pointing at a built Lera
-- checkout.
--
-- is_valid_target used to answer only a boolean, discarding which keyword
-- matched. autostepper needs the keyword itself to attack by -- monsters do
-- not answer to their full display name -- so match_target now owns the one
-- matching rule (comma-split step_targets, trimmed, lowercased, plain
-- substring) and is_valid_target delegates to it rather than carrying a
-- second copy that could drift.
package.path = "3scapes/?.lua;generic/?.lua;" .. package.path

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
-- speedwalk.lua's graph is a C-extension userdata (speedwalk.graph_create);
-- only the methods on_load and configure_place call on it are needed here.
-- speedwalk.parse/flatten are left undefined on purpose -- parse_steps falls
-- back to raw segments when the C API is absent, which is fine since these
-- cases never execute a step, only read the target list.
local fake_graph = {
  add_place = function() end,
  place_count = function() return 0 end,
  edge_count = function() return 0 end,
}
speedwalk = { graph_create = function() return fake_graph end }

lera = { frame_reset = function() end }

local stored = nil
store = {
  load = function() end,
  get = function() return stored end,
  set = function(d) stored = d end,
  save = function() end,
  path = function() return "/tmp" end,
}

alias = {
  add = function() return 1 end,
  remove = function() return true end,
}

mud = { send = function() end }

local real_print = print
print = function() end
local sw = require("speedwalk")
sw.on_load()
print = real_print

-- ---- helpers ------------------------------------------------------------------

-- Configure a place with a target list and make it current, the way a
-- profile's speedwalks.lua plus '.place' normally would. Steps are a
-- throwaway single direction; only the target list under test matters here.
local function set_targets(targets)
  print = function() end
  sw.configure_place("t", "n", targets)
  sw.set_current_place("t")
  print = real_print
end

-- ---- before any place is configured: no targets configured, nothing matches -
check("match_target is nil with no configured place",
  sw.match_target("a scrawny orc") == nil)
check("is_valid_target is false with no configured place",
  sw.is_valid_target("a scrawny orc") == false)

-- ---- matched case: the keyword is returned, not the display name -----------
set_targets("blob,Troll, Fire Ant")
check("match_target returns the matched keyword, not the display name",
  sw.match_target("A large TROLL guardian") == "Troll",
  tostring(sw.match_target("A large TROLL guardian")))
check("the match is case-insensitive against the monster name",
  sw.match_target("a slimy blob") == "blob",
  tostring(sw.match_target("a slimy blob")))
check("a trimmed multi-word target still matches",
  sw.match_target("You see a Fire Ant here") == "Fire Ant",
  tostring(sw.match_target("You see a Fire Ant here")))

-- ---- authored case is preserved, not the lowercased comparison copy --------
check("match_target preserves the target's authored case, not the comparison copy",
  sw.match_target("a lurking troll") == "Troll",
  tostring(sw.match_target("a lurking troll")))

-- ---- the first matching keyword in list order wins, not the last -----------
set_targets("rat,large rat")
check("the first matching keyword wins when several match",
  sw.match_target("a large rat") == "rat",
  tostring(sw.match_target("a large rat")))

-- ---- no match: nil, never a guess --------------------------------------------
set_targets("blob,troll")
check("match_target returns nil when nothing matches",
  sw.match_target("a swift deer") == nil,
  tostring(sw.match_target("a swift deer")))
check("is_valid_target returns false when nothing matches",
  sw.is_valid_target("a swift deer") == false)

-- ---- is_valid_target still answers exactly as before, via delegation -------
set_targets("orc,troll")
check("is_valid_target agrees with match_target for a matching name",
  sw.is_valid_target("a scrawny orc") == true
    and (sw.match_target("a scrawny orc") ~= nil))
check("is_valid_target agrees with match_target for a non-matching name",
  sw.is_valid_target("a swift deer") == false
    and (sw.match_target("a swift deer") == nil))

-- ---- guard: a non-string/nil argument is refused, never a crash ------------
-- pcall'd deliberately: a reimplementation that dropped the guard would raise
-- inside these calls, and an unguarded call here would abort the whole suite
-- rather than reddening this one case.
local ok_nil, nil_result = pcall(sw.match_target, nil)
check("match_target does not error on nil and returns nil",
  ok_nil and nil_result == nil, tostring(ok_nil) .. "/" .. tostring(nil_result))

local ok_num, num_result = pcall(sw.match_target, 42)
check("match_target does not error on a non-string and returns nil",
  ok_num and num_result == nil, tostring(ok_num) .. "/" .. tostring(num_result))

local ok_valid_nil, valid_nil_result = pcall(sw.is_valid_target, nil)
check("is_valid_target does not error on nil and returns false",
  ok_valid_nil and valid_nil_result == false,
  tostring(ok_valid_nil) .. "/" .. tostring(valid_nil_result))

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
