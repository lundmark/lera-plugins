-- autostepper areas/chaossea.lua unit tests. Run from the lera-plugins repo
-- root with LERA_ROOT pointing at a built Lera checkout.
package.path = "3scapes/autostepper/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

local cs = require("areas.chaossea")

-- ---- in_area -----------------------------------------------------------------
check("in_area recognises a sea room",
  cs.in_area("Layer one of the Sea of Chaos") == true)
check("in_area recognises a deeper layer",
  cs.in_area("Layer eight of the Sea of Chaos") == true)
check("in_area rejects an ordinary room", cs.in_area("A dusty crossroads") == false)
check("in_area tolerates a nil name", cs.in_area(nil) == false)

-- ---- layer_of ----------------------------------------------------------------
-- The mudlib renders the layer with number_switch(query_z()+1), so "one" is
-- z = 0. Floors are min(8, 3 + diff/20), so eight words is the whole range.
check("layer one is z 0", cs.layer_of("Layer one of the Sea of Chaos") == 0,
  tostring(cs.layer_of("Layer one of the Sea of Chaos")))
check("layer two is z 1", cs.layer_of("Layer two of the Sea of Chaos") == 1,
  tostring(cs.layer_of("Layer two of the Sea of Chaos")))
check("layer eight is z 7", cs.layer_of("Layer eight of the Sea of Chaos") == 7,
  tostring(cs.layer_of("Layer eight of the Sea of Chaos")))
-- Confirmed against a live capture: a room named "Layer six of the Sea of Chaos"
-- has the virtual file name vr:48,21,5,... -- z is 5.
check("layer six is z 5", cs.layer_of("Layer six of the Sea of Chaos") == 5,
  tostring(cs.layer_of("Layer six of the Sea of Chaos")))
check("an unparseable name yields nil",
  cs.layer_of("A dusty crossroads") == nil,
  tostring(cs.layer_of("A dusty crossroads")))
check("an unknown number word yields nil",
  cs.layer_of("Layer ninety of the Sea of Chaos") == nil,
  tostring(cs.layer_of("Layer ninety of the Sea of Chaos")))
check("layer_of tolerates a nil name", cs.layer_of(nil) == nil)

-- ---- exclusions --------------------------------------------------------------
-- 'out' is the exit back to the real world; the entry room's Room.Info carries
-- it with a real destination (266 in the capture) while every maze exit is 0.
check("out is excluded", cs.exclude_exits.out == true)
check("enter is excluded", cs.exclude_exits.enter == true)
check("in is excluded", cs.exclude_exits["in"] == true)
check("no compass direction is excluded",
  cs.exclude_exits.n == nil and cs.exclude_exits.d == nil and cs.exclude_exits.u == nil)

-- ---- policy hints ------------------------------------------------------------
-- set_level_exit_pairs((["down":"up"])) -- descending a floor is 'down', and the
-- portal sits on the deepest one.
check("dive follows down", cs.dive_dirs[1] == "d" and #cs.dive_dirs == 1)
check("up is deferred", cs.defer_dirs[1] == "u" and #cs.defer_dirs == 1)
check("the default policy is clear", cs.default_policy == "clear")

-- ---- complete ----------------------------------------------------------------
-- The portal is an object whose short is set in example/objs/portal.c, so it
-- reaches the client as a Room.Contents item.
-- The two item names below are verbatim from a live portal-room Room.Contents
-- capture, capitalisation and the cask's "(closed)" suffix included. Matching is
-- substring-on-lowercase precisely so the suffix and the leading capital cannot
-- break completion detection.
check("the portal completes a run",
  cs.complete({ items = { "A glowing portal (swirling chaotically)" } }) == true)
check("the cask completes a run",
  cs.complete({ items = { "A cask of chaotic energy (closed)" } }) == true)
check("matching is case-insensitive",
  cs.complete({ items = { "A Glowing Portal (Swirling Chaotically)" } }) == true)
-- The real capture also carries an unrelated item and a player entry; neither
-- may complete a run.
check("an unrelated item in the portal room does not complete a run",
  cs.complete({ items = {
    "A ritual scene depicting a whirling monstrosity with fifty-four tentacles, spread by the Blood Eagle",
  } }) == false)
check("matching tolerates surrounding text",
  cs.complete({ items = { "there is a glowing portal here somehow" } }) == true)
check("completion accepts Room.Contents item records",
  cs.complete({ items = { { name = "A glowing portal (swirling chaotically)" } } }) == true)
check("an ordinary room does not complete a run",
  cs.complete({ items = { "a rusty sword", "a small mutant organism" } }) == false)
check("an empty room does not complete a run", cs.complete({ items = {} }) == false)
check("a missing items list does not complete a run", cs.complete({}) == false)

-- ---- restart -----------------------------------------------------------------
-- Legacy's cycle, plus the difficulty word it never sent. setsea takes
-- '<level> <risky|alarming|deadly>' (rooms/seatest.c), and difficulty decides
-- whether diagonals and up/down exist at all -- so whether dive has anything to
-- dive through.
local cmds = cs.restart({ level = 12, difficulty = "deadly" })
check("restart opens the cask first", cmds[1] == "open cask", tostring(cmds[1]))
check("restart enters the portal", cmds[2] == "enter portal", tostring(cmds[2]))
check("restart unsets the sea", cmds[3] == "unsetsea", tostring(cmds[3]))
check("restart sets the level and difficulty",
  cmds[4] == "setsea 12 deadly", tostring(cmds[4]))
check("restart enters the sea", cmds[5] == "enter sea", tostring(cmds[5]))
check("restart is exactly five commands", #cmds == 5, tostring(#cmds))

local defaulted = cs.restart({ level = 3 })
check("difficulty defaults to risky",
  defaulted[4] == "setsea 3 risky", tostring(defaulted[4]))
local zeroed = cs.restart({})
check("a missing level defaults to 0",
  zeroed[4] == "setsea 0 risky", tostring(zeroed[4]))
local bogus = cs.restart({ level = 5, difficulty = "sideways" })
check("an unknown difficulty falls back to risky",
  bogus[4] == "setsea 5 risky", tostring(bogus[4]))

-- ---- target vocabulary -------------------------------------------------------
-- An explore run has no speedwalk place, so the profile's list is the only
-- vocabulary the stepper has: without it the attack falls back to the display
-- name's head noun, and the boss ("a whirling monstrosity with ...") has no
-- noun in common with the rest of the maze.
--
-- One word covers every mob in the sea. chaos_corr sets race "mutant" (:74)
-- and alias "mutant" (:115); chaos_dead (:96), chaos_down (:72) and
-- chaos_boss (:66) all carry the alias too, and obj/monster.c:538 id() matches
-- name, any alias, or race. Ordered deliberately: entry 1 is what the stepper
-- guesses when nothing in the list appears in a monster's short.
check("the profile carries a target vocabulary",
  type(cs.targets) == "table" and #cs.targets > 0,
  type(cs.targets) == "table" and tostring(#cs.targets) or type(cs.targets))
check("mutant is the first entry, so it is also the guess",
  cs.targets[1] == "mutant", tostring(cs.targets[1]))
check("every entry is a lowercase single word",
  (function()
     for _, t in ipairs(cs.targets or {}) do
       if type(t) ~= "string" or t:find("%s") or t ~= t:lower() then
         return false
       end
     end
     return true
   end)(), table.concat(cs.targets or {}, ","))

-- ---- instance_reset (Task RD) --------------------------------------------------
-- unsetsea, setsea <n> <diff> and enter sea start a NEW maze instance while
-- the sea's rooms stay virtual and reuse every room name -- init.lua's
-- on_input/on_send watch for these on their way out to invalidate a retained
-- explore map (see init.lua's check_instance_reset). Pinned here as data:
-- exactly the three commands that end an instance match, and nothing an
-- ordinary player types along the way -- including the two M.restart entries
-- ("open cask", "enter portal") that must NOT invalidate anything, since
-- entering the portal leaves the area, which the in_area discard already
-- handles by room name.
check("instance_reset declares exactly three patterns",
  type(cs.instance_reset) == "table" and #cs.instance_reset == 3,
  type(cs.instance_reset) == "table" and tostring(#cs.instance_reset) or type(cs.instance_reset))

local function matches_any(patterns, text)
  for _, pattern in ipairs(patterns or {}) do
    if text:find(pattern) then return true end
  end
  return false
end

for _, cmd in ipairs({ "unsetsea", "setsea 5 deadly", "setsea 0 risky", "enter sea" }) do
  check("instance_reset matches \"" .. cmd .. "\"",
    matches_any(cs.instance_reset, cmd), cmd)
end

for _, cmd in ipairs({ "enter portal", "open cask", "look", "settle" }) do
  check("instance_reset does not match \"" .. cmd .. "\"",
    not matches_any(cs.instance_reset, cmd), cmd)
end

-- setsea is anchored with a frontier, not a bare prefix, so a command that
-- merely STARTS WITH "setsea" followed by more letters (not whitespace or end
-- of string) must not match -- and neither should a line that only contains
-- "sea" or "setsea" somewhere other than the start.
check("instance_reset does not match \"setseasons change\"",
  not matches_any(cs.instance_reset, "setseasons change"))
check("instance_reset does not match \"reset seascape\"",
  not matches_any(cs.instance_reset, "reset seascape"))

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
