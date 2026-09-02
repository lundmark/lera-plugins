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
-- Task 4 adds M.tick(), which gates on mud.connected() and sends through
-- mud.send() -- the same two-function stub guild_viking_autoraid_test.lua
-- carries for the identical reason. `sent` is captured by the closure, so
-- reassigning it below (sent = {}) resets the recorder in place.
local mud_connected = true
local sent = {}
mud = {
  send = function(cmd) sent[#sent + 1] = cmd end,
  connected = function() return mud_connected end,
}
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

-- ---- planner ---------------------------------------------------------------
-- Reset to defaults for the planner cases.
S.autoherd = nil
local s2 = ah.settings()
S.daler = 100000
S.lpending = {}

-- No owned husbandry building: the planner must refuse, with a reason.
S.buildings = {}
S.herds = {}
local act, why = ah.plan()
check("no buildings -> no action", act == nil)
check("no buildings -> reason given", type(why) == "string" and #why > 0)

-- Owned but disabled: still no action.
S.buildings = { sheepfold = 2 }
ah.config("bldg sheepfold off")
act = ah.plan()
check("disabled building -> no action", act == nil)
ah.config("bldg sheepfold on")

-- Empty owned building with restock on and an affordable listing -> one buy.
S.herds = {}
S.lmarket = {
  [1] = { { lin = 1, idx = 0, species = "sheep", breed = "nordic", count = 1,
            price = 400, hard = 30, fert = 40, yield = 50, vigor = 45,
            con = 35, trait = "0" } },
}
act = ah.plan()
check("restock plans a buy", act ~= nil and act.kind == "buy")
check("buy command shape and 1-based id",
      act and act.cmd == "vlivestock buy lodbrok 1",
      act and act.cmd)

-- Below reserve: nothing may be bought.
S.daler = 100
act = ah.plan()
check("below reserve -> no buy", act == nil or act.kind ~= "buy")
S.daler = 100000

-- At building cap: no restock buy.
S.herds = {
  sheepfold = { bldg = "sheepfold", head = 14, quality = 61, gen = 1,
                sterile = 0, hard = 40, fert = 55, yield = 70, vigor = 66,
                con = 50, breed = "nordic", hv = 1, trait = nil,
                age_ticks = 1 },
}
act = ah.plan()
check("at cap -> no restock buy", act == nil or act.kind ~= "buy")

-- Feed shortfall with feed_guard on: a warning, never a command.
S.lfeed = { grain = 0, water = 0, head = 14 }
act = ah.plan()
check("feed shortfall warns", act ~= nil and act.kind == "warn")
check("a warning carries no command", act and act.cmd == nil)

-- The planner never emits more than one action per cycle.
check("plan returns a single action, not a list",
      act == nil or act.kind ~= nil)

-- Slaughter must never be emitted, under any settings.
S.lfeed = { grain = 9999, water = 9999, head = 1 }
for _ = 1, 5 do
  local a = ah.plan()
  check("never emits slaughter",
        a == nil or a.cmd == nil or a.cmd:find("slaughter", 1, true) == nil)
end

-- ---- feed guard: the source of the grain figure ----------------------------
-- Added beyond the brief. The brief said to compare the herds' per-tick draw
-- against S.lfeed.grain, but S.lfeed.grain is itself a per-tick NEED (the
-- server's _v_lfeed(), client.h:4202, fills it from
-- query_livestock_feed_needs(), query.h:2464, and vlivestock.c:608 renders
-- it as "Feed per tick: N grain"). Comparing a need against need *
-- feed_ticks is true for every positive head, which would make the feed
-- guard fire forever. LEGACY:233 compares the WAREHOUSE stock, which is what
-- this port does -- assert that a stocked warehouse actually clears the
-- warning, since S.lfeed.grain stays 0 throughout.
S.autoherd = nil
ah.settings()
S.daler = 100000
S.lpending = {}
S.buildings = { sheepfold = 2 }
S.herds = {
  sheepfold = { bldg = "sheepfold", head = 14, gen = 1, sterile = 0,
                hard = 40, fert = 55, yield = 70, vigor = 66, con = 50,
                breed = "nordic", hv = 1, age_ticks = 1 },
}
S.lfeed = { grain = 0, water = 0, head = 14 }
S.wstock, S.wstock_by_good = nil, nil
act = ah.plan()
check("empty warehouse -> feed guard warns", act ~= nil and act.kind == "warn")
S.wstock_by_good = { grain = { good = "grain", amount = 9999 } }
S.wstock = { { good = "grain", amount = 9999 } }
act, why = ah.plan()
check("stocked warehouse -> feed guard silent (herd at cap, so still no buy)",
      act == nil, act and act.why)
check("stocked warehouse -> a reason is still returned",
      type(why) == "string" and #why > 0)

-- ---- crossbreed: the generation threshold ----------------------------------
-- Added beyond the brief. LEGACY's planner reads `herd.generation`
-- (husbandry.lua:298); handlers/livestock.lua stores that field as `gen`,
-- the key the server's _v_herds() builder emits. A literal port reads nil,
-- falls back to 0, and `0 >= thresh` is false for every positive threshold,
-- so crossbreed would silently never fire on generation -- it would still
-- fire on sterility and age, so the module would look alive with half this
-- branch dead. These two cases pin the generation path on its own: quality
-- buy-ins are off and the age threshold is 0 (off), so a buy here can only
-- have come from the generation comparison.
S.autoherd = nil
ah.settings()
ah.config("quality off")
ah.config("age 0")
S.daler = 100000
S.lpending = {}
S.buildings = { sheepfold = 2 }         -- tier 2 -> cap 14
S.lfeed = { grain = 0, water = 0, head = 4 }
S.wstock_by_good = { grain = { good = "grain", amount = 9999 } }
S.wstock = { { good = "grain", amount = 9999 } }
-- Two listings: the same breed as the herd, and a different one. Crossbreed
-- must pick the DIFFERENT breed (idx 1 -> wire id 2).
S.lmarket = {
  [1] = {
    { lin = 1, idx = 0, species = "sheep", breed = "nordic", count = 1,
      price = 400, hard = 99, fert = 99, yield = 99, vigor = 99, con = 99 },
    { lin = 1, idx = 1, species = "sheep", breed = "highland", count = 1,
      price = 400, hard = 30, fert = 40, yield = 50, vigor = 45, con = 35 },
  },
}
-- head 4 == the restock floor (keep = 4), so restock cannot fire; con 50
-- makes the auto (gen_refresh = 0) threshold floor(50/20) + 5 = 7.
local function set_herd(gen)
  S.herds = {
    sheepfold = { bldg = "sheepfold", head = 4, quality = 60, gen = gen,
                  sterile = 0, hard = 40, fert = 55, yield = 70, vigor = 66,
                  con = 50, breed = "nordic", hv = 0, age_ticks = 1 },
  }
end

set_herd(0)
act = ah.plan()
check("generation under the auto threshold -> no crossbreed buy",
      act == nil or act.kind ~= "buy", act and act.cmd)

set_herd(8)
act = ah.plan()
check("generation over the auto threshold -> a crossbreed buy",
      act ~= nil and act.kind == "buy", act and act.why)
check("crossbreed prefers a different breed (idx 1 -> 1-based id 2)",
      act and act.cmd == "vlivestock buy lodbrok 2", act and act.cmd)

-- An explicit gen threshold overrides the Con-derived one, and 0 means
-- "auto via Con" -- not "always fire" and not "never fire".
ah.config("gen 20")
set_herd(8)
act = ah.plan()
check("an explicit gen threshold above the herd's gen blocks the buy",
      act == nil or act.kind ~= "buy", act and act.cmd)
ah.config("gen auto")
act = ah.plan()
check("gen auto restores the Con-derived threshold and the buy returns",
      act ~= nil and act.kind == "buy", act and act.why)

-- The other two crossbreed triggers, each isolated: generation stays under
-- the threshold in all three cases below, so only sterility or age can be
-- responsible for a buy.
set_herd(0)
S.herds.sheepfold.sterile = 2
act = ah.plan()
check("a sterile head triggers a crossbreed with gen under the threshold",
      act ~= nil and act.kind == "buy", act and act.why)

set_herd(0)
S.herds.sheepfold.age_ticks = 50
act = ah.plan()
check("age alone does not trigger while age_refresh is 0 (off)",
      act == nil or act.kind ~= "buy", act and act.cmd)
ah.config("age 40")                       -- LEGACY's own default
act = ah.plan()
check("age at or over age_refresh triggers a crossbreed",
      act ~= nil and act.kind == "buy", act and act.why)
ah.config("age 0")

-- Restore the fixture the pending-delivery cases below expect.
set_herd(8)

-- ---- pending deliveries block a re-buy -------------------------------------
-- Added beyond the brief (LEGACY:131's whole purpose: "so the planner
-- doesn't keep re-buying while deliveries are on the road"). Deleting the
-- `+ pending_head(b)` from any branch is otherwise invisible -- no case in
-- the brief ever puts anything in S.lpending.
--
-- Crossbreed first, reusing the fixture above (gen 8 over the Con threshold
-- 7, cap 14, head 4): 10 head already in transit fills the building, so the
-- buy that fired a moment ago must not fire now.
S.lpending = { { bldg = "sheepfold", species = "sheep", breed = "nordic",
                 count = 10, secs = 300 } }
act = ah.plan()
check("crossbreed: deliveries in transit fill the cap -> no buy",
      act == nil or act.kind ~= "buy", act and act.cmd)
S.lpending = { { bldg = "byre", species = "cow", breed = "nordic",
                 count = 10, secs = 300 } }
act = ah.plan()
check("crossbreed: a delivery to a DIFFERENT building does not block it",
      act ~= nil and act.kind == "buy", act and act.why)

-- Restock next: an empty building whose breeding floor is already on the
-- road must not be stocked twice.
S.herds = {}
ah.config("gen auto")
S.lpending = { { bldg = "sheepfold", species = "sheep", breed = "nordic",
                 count = 4, secs = 300 } }
act = ah.plan()
check("restock: a delivery already covering the floor -> no buy",
      act == nil or act.kind ~= "buy", act and act.cmd)
S.lpending = {}
act = ah.plan()
check("restock: with nothing in transit the same state buys",
      act ~= nil and act.kind == "buy", act and act.why)

-- ---- the reserve is the only brake -----------------------------------------
-- Added beyond the brief. The brief's own "below reserve" case uses
-- daler = 100 against a 2000 reserve, which is so far under that dropping
-- the `- reserve` term entirely still leaves budget = 100 < the 400 price --
-- the case passes either way. These pin the actual boundary, since `reserve`
-- is documented in this module's header as the ONLY thing stopping the
-- planner spending every daler above it.
S.autoherd = nil
ah.settings()                             -- reserve back to its 2000 default
S.lpending = {}
S.herds = {}
S.buildings = { sheepfold = 2 }
S.lfeed = { grain = 0, water = 0, head = 0 }
S.wstock_by_good = { grain = { good = "grain", amount = 9999 } }
S.wstock = { { good = "grain", amount = 9999 } }
S.lmarket = {
  [1] = { { lin = 1, idx = 0, species = "sheep", breed = "nordic", count = 1,
            price = 400, hard = 30, fert = 40, yield = 50, vigor = 45,
            con = 35 } },
}
S.daler = 2399                            -- reserve 2000 -> budget 399 < 400
act = ah.plan()
check("one daler short of reserve + price -> no buy",
      act == nil or act.kind ~= "buy", act and act.cmd)
S.daler = 2400                            -- budget exactly 400
act = ah.plan()
check("reserve + price exactly -> the buy is allowed",
      act ~= nil and act.kind == "buy", act and act.why)

-- ---- the server's precondition is price * count, not price ----------------
-- The record's `price` is ALREADY the lot total (livestock_daemon.c:310
-- stores `price * count`), and vlivestock.c's do_buy then defaults
-- `buy_count = lot_count` and requires `total_cost = price * buy_count` --
-- so a lot of 3 costs three times what the record's `price` field reads.
-- Every other fixture in this file uses count = 1, the one value where the
-- two figures agree, which is exactly why gating on `price` alone shipped
-- green. Gating on the wrong figure is not a harmless refusal: the command
-- goes out, the server rejects it, no state changes, and the phase machine
-- re-picks the same listing forever.
S.autoherd = nil
ah.settings()                             -- reserve back to its 2000 default
S.lpending = {}
S.herds = {}
S.buildings = { sheepfold = 2 }
S.lfeed = { grain = 0, water = 0, head = 0 }
S.wstock_by_good = { grain = { good = "grain", amount = 9999 } }
S.wstock = { { good = "grain", amount = 9999 } }
S.lmarket = {
  [1] = { { lin = 1, idx = 0, species = "sheep", breed = "nordic", count = 3,
            price = 400, hard = 30, fert = 40, yield = 50, vigor = 45,
            con = 35 } },
}
S.daler = 2400                            -- budget 400: covers price, not 1200
act = ah.plan()
check("a lot of 3 the budget cannot cover in full is not planned",
      act == nil or act.kind ~= "buy", act and act.cmd)
S.daler = 3199                            -- budget 1199, one under the lot
act = ah.plan()
check("one daler short of the whole lot -> still no buy",
      act == nil or act.kind ~= "buy", act and act.cmd)
S.daler = 3200                            -- budget exactly 1200
act = ah.plan()
check("budget covering the whole lot -> the buy is allowed",
      act ~= nil and act.kind == "buy", act and act.why)
check("the note quotes the lot total the server actually charges",
      act and act.why and act.why:find("1200d", 1, true) ~= nil, act and act.why)
S.daler = 100000

-- ---- quality buy-in: the margin, and its own cap check ---------------------
-- Added beyond the brief, which never exercises branch 4 at all. Crossbreed
-- and restock are both silenced here (cross off; head == the keep floor), so
-- any buy below can only be a quality buy-in. Goal is the default "yield"
-- (weights hard 1, fert 1, yield 4, vigor 1, con 2), so the herd below
-- scores 40 + 55 + 280 + 66 + 100 = 541 and the default margin of 5 puts the
-- acceptance floor at 546.
S.autoherd = nil
ah.settings()
ah.config("cross off")
S.daler = 100000
S.lpending = {}
S.buildings = { sheepfold = 2 }
S.lfeed = { grain = 0, water = 0, head = 4 }
S.herds = {
  sheepfold = { bldg = "sheepfold", head = 4, quality = 60, gen = 0,
                sterile = 0, hard = 40, fert = 55, yield = 70, vigor = 66,
                con = 50, breed = "nordic", hv = 0, age_ticks = 1 },
}
-- Scores 40 + 55 + 284 + 66 + 100 = 545, one under the floor.
S.lmarket = {
  [1] = { { lin = 1, idx = 0, species = "sheep", breed = "nordic", count = 1,
            price = 400, hard = 40, fert = 55, yield = 71, vigor = 66,
            con = 50 } },
}
act = ah.plan()
check("a listing one point under the quality margin -> no buy",
      act == nil or act.kind ~= "buy", act and act.cmd)
-- Scores 40 + 55 + 320 + 66 + 100 = 581, clear of the floor.
S.lmarket[1][1].yield = 80
act = ah.plan()
check("a listing clear of the quality margin -> a buy",
      act ~= nil and act.kind == "buy", act and act.why)
check("the quality buy uses the one command form",
      act and act.cmd == "vlivestock buy lodbrok 1", act and act.cmd)
-- The quality branch runs its own cap/pending check too.
S.lpending = { { bldg = "sheepfold", species = "sheep", breed = "nordic",
                 count = 10, secs = 300 } }
act = ah.plan()
check("quality buy: deliveries in transit fill the cap -> no buy",
      act == nil or act.kind ~= "buy", act and act.cmd)
S.lpending = {}

-- ---- three narrower guards -------------------------------------------------
-- All three added beyond the brief, each because deleting the line it covers
-- otherwise changes nothing observable (found by mutating this file's
-- planner, not by guessing -- see the task-4 report's mutant table).

-- (a) The building cap wins over an over-ambitious per-building target.
-- `head < desired AND head < cap` looks redundant, because `desired` is
-- min(cap, keep) when no target is set -- it is reachable only through an
-- explicit target above the cap, which is exactly the case that would
-- otherwise buy animals a building cannot house.
S.autoherd = nil
ah.settings()
S.daler = 100000
S.lpending = {}
S.buildings = { sheepfold = 2 }           -- cap 14
S.lfeed = { grain = 0, water = 0, head = 14 }
S.wstock_by_good = { grain = { good = "grain", amount = 9999 } }
S.wstock = { { good = "grain", amount = 9999 } }
S.lmarket = {
  [1] = { { lin = 1, idx = 0, species = "sheep", breed = "nordic", count = 1,
            price = 400, hard = 30, fert = 40, yield = 50, vigor = 45,
            con = 35 } },
}
S.herds = {
  sheepfold = { bldg = "sheepfold", head = 14, quality = 60, gen = 0,
                sterile = 0, hard = 40, fert = 55, yield = 70, vigor = 66,
                con = 50, breed = "nordic", hv = 0, age_ticks = 1 },
}
ah.config("bldg sheepfold target 20")     -- above the tier-2 cap of 14
act = ah.plan()
check("a per-building target above the cap does not buy past the cap",
      act == nil or act.kind ~= "buy", act and act.cmd)
ah.config("bldg sheepfold target 0")

-- (b) The feed draw is per-head-batch (ceil(head / 8)), not per head. With
-- 8 head and a 4-tick buffer the need is 4 grain, so 4 in the warehouse is
-- exactly enough and must NOT warn. (The market is emptied so no branch can
-- return a buy and mask the result.)
S.autoherd = nil
ah.settings()
S.daler = 100000
S.lpending = {}
S.lmarket = {}
S.lfeed = { grain = 0, water = 0, head = 8 }
S.wstock_by_good = { grain = { good = "grain", amount = 4 } }
S.wstock = { { good = "grain", amount = 4 } }
S.herds = {
  sheepfold = { bldg = "sheepfold", head = 8, quality = 60, gen = 0,
                sterile = 0, hard = 40, fert = 55, yield = 70, vigor = 66,
                con = 50, breed = "nordic", hv = 0, age_ticks = 1 },
}
act, why = ah.plan()
check("8 head with 4 grain and a 4-tick buffer does not warn",
      act == nil, act and act.why)
S.wstock_by_good = { grain = { good = "grain", amount = 3 } }
S.wstock = { { good = "grain", amount = 3 } }
act = ah.plan()
check("8 head with 3 grain does warn", act ~= nil and act.kind == "warn")
-- ...and once the server HAS sent its own per-tick figure, that figure wins
-- over the ceil(head / 8) fallback (it accounts for the fesetr feed-saving
-- skill and the per-building minimum, neither of which a client can see).
-- 5 grain/tick over a 4-tick buffer needs 20: 19 in the warehouse warns, 20
-- does not. Under the fallback the need would be 4 and both would go silent,
-- which is exactly the drift this shares its implementation with
-- pages/livestock.lua to prevent.
S.lfeed = { grain = 5, water = 5, head = 8 }
S.wstock_by_good = { grain = { good = "grain", amount = 19 } }
S.wstock = { { good = "grain", amount = 19 } }
act = ah.plan()
check("the server's per-tick figure drives the buffer (19 < 5 * 4)",
      act ~= nil and act.kind == "warn", act and act.why)
S.wstock_by_good = { grain = { good = "grain", amount = 20 } }
S.wstock = { { good = "grain", amount = 20 } }
act = ah.plan()
check("the server's per-tick figure drives the buffer (20 >= 5 * 4)",
      act == nil, act and act.why)

-- (c) A listing whose lineage id has no token yields no command at all,
-- rather than a half-built one. lin 99 is not in the server's lmap.
S.autoherd = nil
ah.settings()
S.daler = 100000
S.lpending = {}
S.herds = {}
S.lfeed = { grain = 0, water = 0, head = 0 }
S.wstock_by_good = { grain = { good = "grain", amount = 9999 } }
S.wstock = { { good = "grain", amount = 9999 } }
S.lmarket = {
  [99] = { { lin = 99, idx = 0, species = "sheep", breed = "nordic",
             count = 1, price = 400, hard = 30, fert = 40, yield = 50,
             vigor = 45, con = 35 } },
}
act = ah.plan()
check("an unknown lineage id produces no command",
      act == nil or act.kind ~= "buy", act and act.cmd)

-- ---- tick gate -------------------------------------------------------------
-- Added beyond the brief, deliberately. LEGACY's own gate (husbandry.lua:387)
-- is a bare `page_opts.auto_herd` read, which is PERMANENTLY nil here
-- (page_opts keeps its values in a private closure), so a literal port makes
-- M.tick() return early forever -- Auto-Herd would never run even with the
-- toggle on, and every planner case above would still pass. Nothing else in
-- this plan's tests would catch that, so both states are asserted here: with
-- the toggle off, many ticks over rich state must send nothing; with it on,
-- that same state must actually plan and send.
S.autoherd = nil
ah.settings()
S.daler = 100000
S.lpending = {}
S.herds = {}
S.buildings = { sheepfold = 2 }
S.lfeed = { grain = 0, water = 0, head = 0 }
S.wstock_by_good = { grain = { good = "grain", amount = 9999 } }
S.wstock = { { good = "grain", amount = 9999 } }
S.lmarket = {
  [1] = { { lin = 1, idx = 0, species = "sheep", breed = "nordic", count = 1,
            price = 400, hard = 30, fert = 40, yield = 50, vigor = 45,
            con = 35, trait = "0" } },
}

check("tick-gate setup: the master toggle is still off",
      page_opts.get("auto_herd") == false)
sent = {}
for _ = 1, 5 do ah.tick() end
check("tick with the master toggle OFF sends nothing", #sent == 0, #sent)

-- Not-connected gate, proven to block on its own before the toggle is
-- credited with anything.
mud_connected = false
page_opts.set("auto_herd", true)
ah.tick()
check("tick with the toggle on but not connected sends nothing", #sent == 0, #sent)
mud_connected = true

-- The Guild.Livestock arrival gate the spec's Corrections-to-LEGACY table
-- mandates ("Gate on `Guild.Livestock` having arrived", replacing LEGACY's
-- mip_livestock gate). Guild.City and Guild.Livestock are separate
-- slow-cadence panels in a round-robin, so City routinely lands first and the
-- S.buildings gate below is satisfied while every herd still reads empty --
-- the planner would then believe every building is empty and stock all five.
-- The fixture here is the one that buys three lines down, so only the gate can
-- account for the silence.
S.livestock_seen = false
ah.tick()
check("tick before Guild.Livestock has arrived sends nothing", #sent == 0, #sent)
check("tick before Guild.Livestock has arrived says why",
      (ah.settings().status or ""):find("livestock", 1, true) ~= nil,
      ah.settings().status)
S.livestock_seen = true

-- The reconnect settling hold. init.lua's M.on_connect sets S.at_hold_until
-- on every connect and state.reset_connection() deliberately PRESERVES guild
-- data, so S.herds/S.lmarket/S.buildings/S.daler all survive a disconnect and
-- the first tick after reconnect would otherwise plan against last session's
-- market pool -- at an index the server has since rebuilt, buying a different
-- animal than the one it scored. The fixture below is the same one that buys
-- two lines down, so only the hold can be responsible for the silence.
S.at_hold_until = os.time() + 60
ah.tick()
check("tick inside the reconnect settling hold sends nothing", #sent == 0, #sent)
check("tick inside the settling hold says why",
      (ah.settings().status or ""):find("settling", 1, true) ~= nil,
      ah.settings().status)
-- An ELAPSED hold (a real past timestamp, not nil) must not block anything:
-- the toggle-ON case immediately below runs with this set and is the
-- assertion that it does not.
S.at_hold_until = os.time() - 1

-- The toggle ON, all else unchanged: the planner must actually run and act.
ah.tick()
check("tick with the master toggle ON plans and sends exactly one command",
      #sent == 1, #sent)
check("tick sends the one command form the planner builds",
      sent[1] == "vlivestock buy lodbrok 1", sent[1])
check("tick never sends slaughter",
      sent[1] and sent[1]:find("slaughter", 1, true) == nil)

-- Flipping it back off must stop it again.
S.at_hold_until = nil
page_opts.set("auto_herd", false)
sent = {}
for _ = 1, 5 do ah.tick() end
check("flipping the master toggle back OFF stops sends", #sent == 0, #sent)

-- ---- the confirm-timeout retry loop ---------------------------------------
-- A buy the server refuses (already purchased, or -- before the lot-total fix
-- above -- unaffordable) changes NO state, so the phase machine waits out its
-- confirm timeout, cools down, replans, picks the same listing and repeats
-- forever. Nothing in the client ever noticed. The timeout transition now
-- evicts the attempted listing from S.lmarket and refuses to re-emit an
-- identical command on the next cycle.
S.autoherd = nil
ah.settings()
page_opts.set("auto_herd", true)
S.livestock_seen = true
S.at_hold_until = nil
mud_connected = true
S.daler = 100000
S.lpending = {}
S.herds = {}
S.buildings = { sheepfold = 2 }
S.lfeed = { grain = 0, water = 0, head = 0 }
S.wstock_by_good = { grain = { good = "grain", amount = 9999 } }
S.wstock = { { good = "grain", amount = 9999 } }
local function one_listing()
  return {
    [1] = { { lin = 1, idx = 0, species = "sheep", breed = "nordic",
              count = 1, price = 400, hard = 30, fert = 40, yield = 50,
              vigor = 45, con = 35 } },
  }
end
S.lmarket = one_listing()
sent = {}
ah.tick()
check("retry-loop setup: the first tick sends the buy", #sent == 1, #sent)

-- The server refused: no herd, no daler and no market change, so the state
-- signature is unchanged and the confirm deadline expires. os.time is stubbed
-- rather than slept on, the same idiom guild_viking_test.lua's hold-window
-- case uses.
local real_time = os.time
os.time = function() return real_time() + 100 end
ah.tick()
check("confirm timeout evicts the attempted listing from S.lmarket",
      #(S.lmarket[1] or {}) == 0, S.lmarket[1] and #S.lmarket[1])

sent = {}
os.time = function() return real_time() + 200 end
ah.tick()
check("after the eviction there is nothing left to re-buy", #sent == 0, sent[1])

-- Even when the server resends the identical listing, the refused command is
-- not repeated on the very next cycle -- that is what caps the loop for a
-- refusal the eviction cannot explain (an unaffordable lot, say).
S.lmarket = one_listing()
os.time = function() return real_time() + 300 end
ah.tick()
check("a re-arrived identical listing is not bought again immediately",
      #sent == 0, sent[1])

-- The refusal is one-shot, not a permanent blacklist: a listing that really
-- is back on the market must eventually be buyable again.
os.time = function() return real_time() + 400 end
ah.tick()
check("the refusal is one-shot, not a permanent blacklist", #sent == 1, #sent)
os.time = real_time
page_opts.set("auto_herd", false)

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("all autoherd cases passed")
