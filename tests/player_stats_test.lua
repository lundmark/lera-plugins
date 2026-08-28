-- player_stats unit tests. Run from the lera-plugins repo root with LERA_ROOT
-- pointing at a built Lera checkout.
--
-- player_stats is GMCP-fed: Char.Vitals carries hp/sp (plus encumbrance, the
-- morgue-coffin counts and the player's guild) and Char.Combat carries the
-- attacker block. It used to parse MIP FFF/BBA-BBD; no `mip` global is defined
-- anywhere in this file, so any surviving MIP call fails the suite outright
-- rather than quietly doing nothing.
package.path = "3scapes/?.lua;" .. package.path

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
local handlers = {}       -- package -> callback
local removed = {}
gmcp = {
  on = function(pkg, fn) handlers[pkg] = fn; return pkg end,
  remove = function(id) removed[#removed + 1] = id; return true end,
  enabled = function() return true end,
}
ui = { dirty = function() end }
lera = { dirty = function() end, time = function() return 0 end }
plugin = { get = function() return nil end }
store = {
  load = function() end, get = function() return nil end,
  set = function() end, save = function() end,
}

local ps = require("player_stats")

local function vitals(t) 
  local fn = handlers["Char.Vitals"]
  if fn then fn("Char.Vitals", t) end
end
local function combat(t)
  local fn = handlers["Char.Combat"]
  if fn then fn("Char.Combat", t) end
end

-- ---- subscriptions ----------------------------------------------------------
if ps.on_load then ps.on_load() end

check("subscribes to Char.Vitals", handlers["Char.Vitals"] ~= nil)
check("subscribes to Char.Combat", handlers["Char.Combat"] ~= nil)
check("has_data is false before any frame", ps.has_data() == false)

-- ---- Char.Vitals mapping ----------------------------------------------------
vitals({ hp = 73, maxhp = 100, sp = 41, maxsp = 80,
         enc = 30, coffin = 2, coffin_max = 5, guild = "viking" })

local s = ps.get_stats()
check("hp maps from Char.Vitals hp", s.hp == 73, s.hp)
check("hp_max maps from maxhp", s.hp_max == 100, s.hp_max)
check("sp maps from Char.Vitals sp", s.sp == 41, s.sp)
check("sp_max maps from maxsp", s.sp_max == 80, s.sp_max)
check("hp_percent is derived", s.hp_percent == 73, s.hp_percent)
check("sp_percent is derived", s.sp_percent == 51, s.sp_percent)
check("encumbrance is carried", s.enc == 30, s.enc)
check("coffin counts are carried", s.coffin == 2 and s.coffin_max == 5,
      tostring(s.coffin) .. "/" .. tostring(s.coffin_max))
check("guild is carried", s.guild == "viking", s.guild)
check("guild() accessor agrees", ps.guild() == "viking", ps.guild())
check("has_data is true after a vitals frame", ps.has_data() == true)
-- The first frame has no baseline to subtract from, so it must report no
-- change rather than the full value as a phantom gain.
check("the first frame reports a zero delta, not a phantom gain",
      s.hp_delta == 0 and s.sp_delta == 0,
      tostring(s.hp_delta) .. "/" .. tostring(s.sp_delta))

-- ---- deltas -----------------------------------------------------------------
vitals({ hp = 60, maxhp = 100, sp = 45, maxsp = 80,
         enc = 30, coffin = 2, coffin_max = 5, guild = "viking" })
s = ps.get_stats()
check("hp_delta is the signed change", s.hp_delta == -13, s.hp_delta)
check("sp_delta is the signed change", s.sp_delta == 4, s.sp_delta)
check("hp_delta() accessor agrees", ps.hp_delta() == -13, ps.hp_delta())

-- ---- a zero maximum must not divide by zero ---------------------------------
vitals({ hp = 0, maxhp = 0, sp = 0, maxsp = 0,
         enc = 0, coffin = 0, coffin_max = 0, guild = "" })
s = ps.get_stats()
check("a zero maximum yields a zero percent, not a crash",
      s.hp_percent == 0 and s.sp_percent == 0,
      tostring(s.hp_percent) .. "/" .. tostring(s.sp_percent))

-- ---- Char.Combat mapping ----------------------------------------------------
combat({ attacker = "a large troll", attacker_hp = 64, rounds = 3 })
s = ps.get_stats()
check("attacker maps from Char.Combat", s.attacker == "a large troll", s.attacker)
check("attacker_hp maps from Char.Combat", s.attacker_hp == 64, s.attacker_hp)
check("rounds are carried", s.rounds == 3, s.rounds)
check("in_combat is true with a named attacker", ps.in_combat() == true)

local atk, atk_hp = ps.attacker()
check("attacker() returns name and hp", atk == "a large troll" and atk_hp == 64)

combat({ attacker = "", attacker_hp = 0, rounds = 0 })
check("an empty attacker ends combat", ps.in_combat() == false)

combat({ attacker = "a kobold", attacker_hp = 90, rounds = 1 })
ps.clear_attacker()
check("clear_attacker ends combat", ps.in_combat() == false)
check("clear_attacker blanks the name", ps.get_stats().attacker == "")

-- ---- the fields stats_window's player block actually reads -------------------
vitals({ hp = 50, maxhp = 100, sp = 20, maxsp = 40,
         enc = 10, coffin = 0, coffin_max = 0, guild = "druid" })
combat({ attacker = "a rat", attacker_hp = 12, rounds = 1 })
s = ps.get_stats()
local required = { "hp", "hp_max", "hp_label", "hp_delta",
                   "sp", "sp_max", "sp_label", "sp_delta",
                   "attacker", "attacker_hp" }
local missing = {}
for _, k in ipairs(required) do
  if s[k] == nil then missing[#missing + 1] = k end
end
check("get_stats carries every field stats_window's player block reads",
      #missing == 0, table.concat(missing, ","))
check("a guild change is reflected", s.guild == "druid", s.guild)

-- ---- teardown ---------------------------------------------------------------
if ps.on_unload then ps.on_unload() end
check("on_unload removes both subscriptions", #removed == 2, #removed)

print(failures == 0 and "ALL PASS" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
