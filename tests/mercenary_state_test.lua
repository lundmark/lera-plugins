-- mercenary state projections. Run from the lera-plugins repo root with
-- LERA_ROOT pointing at a built Lera checkout.
package.path = "3scapes/mercenary/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

local clock = 1000
lera = { time = function() return clock end }

local state = require("state")

local function reset()
  clock = 1000
  state.reset()
end

-- ---- Vitals ---------------------------------------------------------------
-- Kills: reading the wire names straight through. The public record has always
-- used hp_current/stamina_*/ap_*, and stats_window reads those names.
reset()
state.apply("Vitals", {
  hp = 412, hp_max = 500, stam = 61, stam_max = 90, stam_regen = 3,
  ap = 40, ap_max = 50, ap_regen = 2, target = "Orc", target_hp = 42,
  abils = "[bandage,mend]", dormant = 0,
}, "kaziar", false)
local s = state.get()
check("Vitals projects onto the historical public names",
  s.hp_current == 412 and s.hp_max == 500 and s.stamina_current == 61
    and s.stamina_regen == 3 and s.ap_current == 40 and s.ap_regen == 2
    and s.target == "Orc" and s.target_pct == 42
    and s.abilities == "[bandage,mend]")

-- Kills: dividing without a zero guard, and integer-truncating the wrong way.
check("percentages are floored integers",
  s.hp_percent == 82 and s.stamina_percent == 67 and s.ap_percent == 80,
  "hp=" .. s.hp_percent .. " st=" .. s.stamina_percent .. " ap=" .. s.ap_percent)

-- Kills: capitalizing nothing. The attribution carries the raw stored name
-- (query_merc_name()); the mudlib capitalizes at each display site, and the
-- pane header renders this value directly.
check("the display name is capitalized, the identity is not",
  s.name == "Kaziar" and s.merc_name == "kaziar")

-- ---- Info -----------------------------------------------------------------
-- Kills: hardcoding the caps at 150/30 the way the old MIP plugin did. They are
-- server-sent now (Info.perm_cap / Info.inst_cap) and stats_window's level line
-- keys off them. The fixture deliberately uses 200/40 rather than 150/30: those
-- are state.lua's own fallback defaults, so a fixture at the defaults would be
-- satisfied by a hardcode and would pin nothing.
reset()
state.apply("Info", {
  class = "offensive", theme = "wolf", gender = 1, status = 1, dtype = "Edged",
  cost = 12, follow = 1, perm_level = 12, perm_cap = 200,
  inst_level = 4, inst_cap = 40, eff_level = 16,
}, "kaziar", false)
s = state.get()
check("Info projects identity, caps and effective level",
  s.class == "offensive" and s.pl_level == 12 and s.pl_max_level == 200
    and s.il_max_level == 40 and s.eff_level == 16 and s.cost == 12)

-- Kills: leaving `follow` as the wire's 0/1 int. The public field is a boolean
-- and callers branch on it directly.
check("follow becomes a boolean", s.following == true)

-- Kills: guessing the gender legend. 0 neutral, 1 male, 2 female
-- (mercenary_base.c:100). The raw int is kept alongside the name so a caller
-- never has to re-derive it.
check("gender exposes the raw int and its name",
  s.gender == 1 and s.gender_name == "male")

-- Kills: mapping an unknown status to nil, which forces every renderer to
-- nil-check a field that should always read.
reset()
state.apply("Info", { status = 99 }, "kaziar", false)
check("an unrecognized status reads as unknown",
  state.get().status_name == "unknown")

-- Kills: deriving dormancy from the countdown instead of the status. The
-- countdown reaches 0 on the tick recovery completes, and `status` is the
-- field that bypasses the Merc.Info throttle precisely so the two move
-- together -- keying off `dormant > 0` flickers the pane out a tick early.
reset()
state.apply("Info", { status = 5 }, "kaziar", false)
state.apply("Vitals", { dormant = 0 }, "kaziar", false)
check("is_dormant follows status, not the countdown",
  state.get().is_dormant == true)
reset()
state.apply("Info", { status = 1 }, "kaziar", false)
state.apply("Vitals", { dormant = 298 }, "kaziar", false)
check("a countdown without dormant status does not set the flag",
  state.get().is_dormant == false and state.get().dormant == 298)

-- ---- Stats ----------------------------------------------------------------
-- Kills: collapsing the two meanings of "abilities". Vitals.abils is the
-- active-abilities string the public API has always returned; Stats.abilities
-- is a lifetime counter. Projecting the counter over the string silently
-- replaces a display value with an integer.
reset()
state.apply("Vitals", { abils = "[bandage]" }, "kaziar", false)
state.apply("Stats", {
  perm_xp = 900, perm_xp_next = 1500, inst_xp = 40, inst_xp_next = 100,
  skill_points = 3, fund = 5000, spent_total = 800, spent_boot = 300,
  spent_skills = 400, spent_spec = 100, rounds = 12, dmg_out = 500,
  dmg_in = 200, healing = 60, abilities = 7,
  life_rounds = 900, life_dmg_out = 40000, life_dmg_in = 15000,
  life_healing = 3000, life_abilities = 400,
}, "kaziar", false)
s = state.get()
check("abils stays a string and abilities becomes a counter",
  s.abilities == "[bandage]" and s.abilities_used == 7)

check("Stats projects xp, economy and both counter sets",
  s.pl_xp == 900 and s.pl_needed == 1500 and s.il_needed == 100
    and s.fund == 5000 and s.spent == 800 and s.spent_skills == 400
    and s.rounds == 12 and s.life_dmg_out == 40000)

-- ---- Skills ---------------------------------------------------------------
-- Kills: keying the split off a hardcoded name list instead of type(v). Skills
-- mixes 13 per-skill records with three scalars (points, allocs, next_cost) at
-- the SAME level. `newfangled` is in the fixture precisely because it is in no
-- such list: a record/name-list split files it as a scalar and drops it, which
-- is how a skill the mudlib adds later would silently vanish.
reset()
state.apply("Skills", {
  max_stamina = { raw = 3, eff = 5 },
  bury = { raw = 0, eff = 2 },
  newfangled = { raw = 1, eff = 4 },
  points = 4, allocs = 6, next_cost = 900,
}, "kaziar", false)
s = state.get()
check("Skills splits records from scalars by value type",
  s.skills.max_stamina.raw == 3 and s.skills.max_stamina.eff == 5
    and s.skills.bury.eff == 2
    and s.skills.newfangled.eff == 4
    and s.skills.points == nil
    and s.skills_meta.points == 4 and s.skills_meta.next_cost == 900)

-- ---- Talents --------------------------------------------------------------
-- Kills: assuming a fixed ability list. register_class_abilities() fills the
-- payload with whichever five the class actually has, so the projection must
-- take what arrives.
reset()
state.apply("Talents", {
  bandage = { points = 2, eff = 3, min_level = 5 },
  frenzy = { points = 0, eff = 0, min_level = 20 },
  points = 1, allocs = 2, next_cost = 450,
}, "kaziar", false)
s = state.get()
check("Talents projects per-ability records and its own scalars",
  s.talents.bandage.points == 2 and s.talents.bandage.min_level == 5
    and s.talents.frenzy.eff == 0
    and s.talents_meta.points == 1 and s.talents_meta.allocs == 2)

-- Kills: a stale-merge that keeps an ability from a previous class. A slow
-- package always carries the complete set, so the projection replaces.
reset()
state.apply("Talents", { bandage = { points = 2, eff = 3, min_level = 5 } }, "kaziar", false)
state.apply("Talents", { frenzy = { points = 1, eff = 1, min_level = 20 } }, "kaziar", false)
check("a later Talents frame replaces the ability set",
  state.get().talents.bandage == nil and state.get().talents.frenzy ~= nil)

-- Kills: keying the split off the scalar names (points/allocs/next_cost). An
-- ability literally named "points" is expressible only as a table-valued
-- `points` key -- the ability and the scalar cannot coexist in one flat payload
-- -- and that is exactly what the server sends in that case. A name-list split
-- files it as a scalar, num()s the table to 0, and the ability disappears.
reset()
state.apply("Talents", {
  points = { points = 2, eff = 7, min_level = 5 },
  allocs = 3,
}, "kaziar", false)
s = state.get()
check("an ability named points is a record, not the scalar",
  s.talents.points ~= nil and s.talents.points.eff == 7
    and s.talents_meta.points == 0 and s.talents_meta.allocs == 3,
  "talents.points=" .. tostring(s.talents.points))

-- Kills: snapshot() handing out the live nested tables, letting a caller
-- mutate plugin state through a value it was told is a copy.
reset()
state.apply("Skills", { bury = { raw = 1, eff = 2 } }, "kaziar", false)
local snap = state.snapshot()
snap.skills.bury.raw = 999
check("snapshot deep-copies the nested records",
  state.get().skills.bury.raw == 1)

-- ---- summary --------------------------------------------------------------
if failures > 0 then
  print("FAILURES: " .. failures)
  os.exit(1)
end
print("mercenary_state_test: all cases passed")
