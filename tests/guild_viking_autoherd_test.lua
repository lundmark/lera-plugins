-- guild_viking Auto-Herd tests. Run from the lera-plugins repo root with
-- LERA_ROOT pointing at a built Lera checkout.
package.path = "3scapes/guild_viking/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

ui = { dirty = function() end }
lera = { time = function() return 1000 end }
buffer = { color_print = function() end }
-- Task-3-brief correction #2 (beyond the page_opts.auto_herd fix): the
-- brief's own test content omits a `store` stub. autoherd.lua's M.config
-- persists through the same mechanism autoraid.lua uses -- M.config calls a
-- local save() that requires("persist").save(), and persist.lua's M.save()
-- calls store.set()/store.save() unconditionally. Without this stub the
-- very first ah.config() call below errors ("attempt to index a nil value
-- (global 'store')"). guild_viking_autoraid_test.lua already carries this
-- exact stub for the identical reason -- mirrored verbatim here rather than
-- inventing a new shape.
local stored = nil
store = {
  load = function() end,
  get = function() return stored end,
  set = function(d) stored = d end,
  save = function() end,
}

local S = require("state").S
local page_opts = require("page_opts")
local ah = require("autoherd")

-- ---- defaults --------------------------------------------------------------
-- LEGACY's defaults are preserved deliberately, including the three spending
-- actions defaulting ON: the master page_opts.auto_herd toggle is the gate.
local s = ah.settings()
check("goal default", s.goal == "yield")
check("reserve default", s.reserve == 2000)
check("keep default", s.keep == 4)
check("gen_refresh default", s.gen_refresh == 0)
check("age_refresh default", s.age_refresh == 40)
check("restock on by default", s.restock == true)
check("crossbreed on by default", s.crossbreed == true)
check("buy_quality on by default", s.buy_quality == true)
check("feed_guard on by default", s.feed_guard == true)
check("feed_ticks default", s.feed_ticks == 4)
check("quality_margin default", s.quality_margin == 5)
check("trait_pref default", s.trait_pref == "any")
-- Task-3-brief correction #1 (explicitly given): page_opts keeps its values
-- in a private closure, so page_opts.auto_herd is nil -- page_opts.get(key)
-- is the only correct read API (page_opts.set(key, v) the only write API),
-- matching every existing page/test in this plugin.
check("master toggle off by default", page_opts.get("auto_herd") == false)
check("interval is 20s", ah.AH_INTERVAL == 20)

-- ---- config surface --------------------------------------------------------
ah.config("reserve 500")
check("config reserve", ah.settings().reserve == 500)
ah.config("cross off")
check("config cross off", ah.settings().crossbreed == false)
ah.config("goal balanced")
check("config goal", ah.settings().goal == "balanced")
ah.config("trait hardy")
check("config trait", ah.settings().trait_pref == "hardy")
ah.config("bldg byre target 10")
check("config per-building target",
      ah.settings().buildings.byre and ah.settings().buildings.byre.target == 10)
ah.config("bldg byre off")
check("config per-building disable",
      ah.settings().buildings.byre.enabled == false)

-- An unknown directive must not silently succeed.
local before = ah.settings().reserve
ah.config("nonsense 12")
check("unknown config directive leaves settings alone",
      ah.settings().reserve == before)

-- ---- menu ------------------------------------------------------------------
local items = ah.menu_items()
check("menu lists items", type(items) == "table" and #items > 0)
local ids = {}
for _, it in ipairs(items) do if it.id then ids[it.id] = true end end
check("menu exposes the four action toggles",
      ids.feed and ids.restock and ids.cross and ids.quality)

-- Review-round fix 4: S.buildings is {} up to this point (state.lua's own
-- default), so owns() has been false for all five buildings throughout the
-- run above -- the per-building rows and the "_none" fallback they gate
-- were previously untested. Assert both states explicitly.
check("no buildings owned: the fallback row appears", ids._none == true)
check("no buildings owned: no per-building row appears",
      not (ids.bldg_sheepfold or ids.bldg_henhouse or ids.bldg_piggery
           or ids.bldg_byre or ids.bldg_stable))

S.buildings = { sheepfold = 2, byre = 1 }
local items2 = ah.menu_items()
local ids2 = {}
for _, it in ipairs(items2) do if it.id then ids2[it.id] = true end end
check("owning sheepfold+byre: their rows appear",
      ids2.bldg_sheepfold and ids2.bldg_byre)
check("owning sheepfold+byre: an unowned building produces no row",
      not (ids2.bldg_henhouse or ids2.bldg_piggery or ids2.bldg_stable))
check("owning any building: the fallback row vanishes", ids2._none == nil)

-- status_line()'s "owned: ..." branch (only reachable when owns(b) is true
-- for at least one building) is exercised the same way -- via M.config's
-- blank/"status" directive -- so it isn't left at zero coverage either.
-- note() is a stub, so this only asserts the call does not error.
local ok_status = pcall(ah.config, "status")
check("config status with an owned building does not error", ok_status)

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("all autoherd cases passed")
