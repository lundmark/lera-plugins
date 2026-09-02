-- guild_viking Guild.Livestock writers unit tests. Run from the lera-plugins
-- repo root with LERA_ROOT pointing at a built Lera checkout.
--
-- Every case asserts the writer's output against values written out literally
-- and names the state field its consumer reads, matching the framing of
-- guild_viking_gmcp_settlement_test.lua.
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

local S = require("state").S
local livestock = require("handlers.livestock")
local w = livestock._gmcp

-- ---- herds -----------------------------------------------------------------
w.HERDS({
  { bldg = "sheepfold", head = 12, quality = 61, gen = 3, sterile = 0,
    hard = 40, fert = 55, yield = 70, vigor = 66, con = 50,
    breed = "nordic", hv = 1, trait = "prolific", age_ticks = 12 },
  { bldg = "byre", head = 4, quality = 30, gen = 1, sterile = 0,
    hard = 10, fert = 12, yield = 14, vigor = 20, con = 18,
    breed = "", hv = 0, trait = "0", age_ticks = 41 },
})
check("herds keyed by bldg", S.herds and S.herds.sheepfold and S.herds.byre)
-- The spec's Corrections-to-LEGACY table requires Auto-Herd to gate on
-- "Guild.Livestock having arrived", replacing LEGACY's MIP gate. herds is one
-- of the keys gmcp.h says is ALWAYS sent, even empty, so its writer is the
-- arrival signal; state.reset_connection() clears the latch so it can never
-- outlive the connection that set it.
check("a herds frame latches S.livestock_seen", S.livestock_seen == true,
      tostring(S.livestock_seen))
check("herds numeric fields land", S.herds.sheepfold.head == 12
      and S.herds.sheepfold.yield == 70 and S.herds.sheepfold.con == 50)
check("herds real trait kept", S.herds.sheepfold.trait == "prolific")
-- The server sends "0", not "" or nil, for a herd with no trait. Left as "0"
-- it would be looked up as a trait id and render as an unknown trait.
check('herds trait "0" normalised to nil', S.herds.byre.trait == nil)
check("herds empty breed stays a string", S.herds.byre.breed == "")

-- A building with head <= 0 is omitted by the server entirely. A later frame
-- with fewer herds must not leave the vanished one behind.
w.HERDS({
  { bldg = "sheepfold", head = 12, quality = 61, gen = 3, sterile = 0,
    hard = 40, fert = 55, yield = 70, vigor = 66, con = 50,
    breed = "nordic", hv = 1, trait = "prolific", age_ticks = 12 },
})
check("herds replaced wholesale, byre gone", S.herds.byre == nil)

-- ---- bqueue (sibling split) ------------------------------------------------
w.BQUEUE({
  bqueue_used = 2, bqueue_max = 6,
  bqueue = { { slot = 1, species = "pig", meat = "pork", qty = 8,
               secs = 120, trait = "0" } },
})
check("bqueue used/max", S.bqueue_used == 2 and S.bqueue_max == 6)
check("bqueue slots", #S.bqueue == 1 and S.bqueue[1].meat == "pork")
check('bqueue trait "0" normalised', S.bqueue[1].trait == nil)

-- ---- lfeed (the only mapping key) ------------------------------------------
w.LFEED({ grain = 800, water = 200, head = 30 })
check("lfeed is a mapping, not positional",
      S.lfeed.grain == 800 and S.lfeed.water == 200 and S.lfeed.head == 30)

-- ---- lpending --------------------------------------------------------------
w.LPENDING({ { bldg = "byre", species = "cow", breed = "nordic",
               count = 2, secs = 300 } })
check("lpending", #S.lpending == 1 and S.lpending[1].secs == 300)

-- ---- lfind (three-part composite) ------------------------------------------
w.LFIND({
  lfind_posts = { { id = 7, species = "sheep", min_quality = 50,
                    max_price = 900, bldg = "sheepfold", tier = 2,
                    trait = "0", state = "open" } },
  lfind_offers = { { id = 9, species = "sheep", breed = "nordic", count = 3,
                     quality = 70, price = 850, hard = 40, fert = 50,
                     yield = 60, vigor = 55, con = 45, secs = 600,
                     trait = "hardy" } },
  lfind_auctions = { { id = 11, species = "cow", breed = "aurochs",
                       quality = 80, reserve = 1200, my_bid = 0,
                       secs = 900, trait = "0" } },
})
check("lfind three sub-arrays", #S.lfind.posts == 1 and #S.lfind.offers == 1
      and #S.lfind.auctions == 1)
check("lfind offer fields", S.lfind.offers[1].price == 850
      and S.lfind.offers[1].trait == "hardy")

-- ---- lmarket (variable-arity composite, merged per lineage) ----------------
-- The server sends one key per lineage and OMITS a lineage with no pool, so
-- this composite can never assume a fixed part count.
w.LMARKET({
  lmarket_1 = { { lin = 1, idx = 0, species = "sheep", breed = "nordic",
                  count = 2, price = 400, hard = 30, fert = 40, yield = 50,
                  vigor = 45, con = 35, trait = "0" } },
  lmarket_5 = { { lin = 5, idx = 0, species = "cow", breed = "aurochs",
                  count = 1, price = 900, hard = 50, fert = 30, yield = 60,
                  vigor = 40, con = 55, trait = "bountiful" } },
})
check("lmarket keyed by numeric lineage", S.lmarket[1] and S.lmarket[5])
check("lmarket record fields", S.lmarket[5][1].price == 900
      and S.lmarket[5][1].trait == "bountiful")

-- A delta carrying ONE lineage must not wipe the others.
w.LMARKET({
  lmarket_5 = { { lin = 5, idx = 0, species = "cow", breed = "aurochs",
                  count = 1, price = 999, hard = 50, fert = 30, yield = 60,
                  vigor = 40, con = 55, trait = "bountiful" } },
})
check("lmarket delta preserves other lineages", S.lmarket[1] ~= nil)
check("lmarket delta updates its own lineage", S.lmarket[5][1].price == 999)

-- A FULL resend replaces instead of merging. The server omits lmarket_<lid>
-- entirely when a pool empties, and on a shrinking key set it sets full=1 and
-- repeats the complete current key set -- so a lineage absent from a full
-- frame is gone, not unchanged. Merging one leaves phantom listings standing
-- forever, and Auto-Herd then scores a sold animal, re-emits a buy the server
-- refuses, and wedges (a stale TRAIT listing carries a +1000 score bonus and
-- would win permanently).
w.LMARKET({
  lmarket_5 = { { lin = 5, idx = 0, species = "cow", breed = "aurochs",
                  count = 1, price = 777, hard = 50, fert = 30, yield = 60,
                  vigor = 40, con = 55, trait = "bountiful" } },
}, true)
check("a full frame omitting a lineage evicts it", S.lmarket[1] == nil,
      S.lmarket[1] and #S.lmarket[1])
check("a full frame keeps the lineages it does carry", S.lmarket[5]
      and S.lmarket[5][1].price == 777)

-- ...and a delta must still merge, which is the behaviour the two cases above
-- this one pin.
w.LMARKET({
  lmarket_1 = { { lin = 1, idx = 0, species = "sheep", breed = "nordic",
                  count = 2, price = 400, hard = 30, fert = 40, yield = 50,
                  vigor = 45, con = 35, trait = "0" } },
})
check("a delta after a full frame merges, not replaces",
      S.lmarket[1] ~= nil and S.lmarket[5] ~= nil)

-- ---- lneeds ----------------------------------------------------------------
w.LNEEDS({ { species = "sheep", current = 2, cap = 14 } })
check("lneeds", #S.lneeds == 1 and S.lneeds[1].cap == 14)

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("all livestock writer cases passed")
