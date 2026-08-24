-- guild_viking Guild.Settlement transport equivalence: the MIP string form and
-- the GMCP structured form of the same data must leave S.* identical.
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
store = { load = function() end, get = function() return nil end,
          set = function() end, save = function() end }
lera = { time = function() return 1000 end, version = function() return "test" end }
buffer = { color_print = function() end }
mud = { send = function() end }

local S = require("state").S
local city = require("handlers.city")
local gmcp_map = require("gmcp_map")

-- Deep compare, so a nested record or list difference is caught rather than
-- two tables comparing unequal by identity.
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

-- Snapshot only the fields a key owns, so an unrelated field cannot mask a
-- difference or cause a false one.
local function snapshot(fields)
  local out = {}
  for _, f in ipairs(fields) do out[f] = S[f] end
  return out
end

local function clear(fields)
  for _, f in ipairs(fields) do S[f] = nil end
end

-- Feed the MIP string, snapshot; clear; feed a LITERAL GMCP structure carrying
-- the same data, snapshot; compare.
--
-- The GMCP form is written out by hand rather than produced by
-- gmcp_map.zip(order, val). It used to be zipped, which made these cases
-- unfalsifiable: city.lua defines M.<KEY> as write_<key>(zip(<KEY>_ORDER, val)),
-- so both sides of the comparison evaluated the same expression and asserted
-- f(x) == f(x). Only the test's private copy of the order list could ever
-- differ. A literal keeps the field names independent of city.lua, so a drifted
-- <KEY>_ORDER now shows up as the two transports disagreeing -- which is the
-- failure these cases claim to catch.
local function equivalent(name, mip_key, val, gmcp_form, fields)
  clear(fields)
  city[mip_key](val)
  local via_mip = snapshot(fields)

  clear(fields)
  city._gmcp[mip_key](gmcp_form)
  local via_gmcp = snapshot(fields)

  check(name .. " transport equivalence", same(via_mip, via_gmcp),
    "mip vs gmcp differ")
end

-- ---- the seven _v_join keys ------------------------------------------------
-- Kills, for every case below: a writer that drifted from its decoder (or a
-- decoder whose declared field order drifted), so the same data renders
-- differently depending on which transport won.

equivalent("settlers", "SETTLERS",
  "42|75|10|3|7",
  { settlers = "42", mood = "75", tax_rate = "10", water = "3", fert = "7" },
  { "settlers", "settler_mood", "settler_tax", "city_water", "city_fert" })

equivalent("sactions", "SACTIONS",
  "60|0|120|0|0|30",
  { assembly = "60", watch = "0", crafts = "120", feast = "0", relief = "0",
    works = "30" },
  { "settler_actions" })

-- The housing cap/plots fields are in the snapshot deliberately: SHPLOTS owns
-- only settler_housing_plot_tiers now, so clear() nils those two and NEITHER
-- transport may put anything back. See write_shplots in handlers/city.lua.
equivalent("shplots", "SHPLOTS",
  "4|3|2|1|0",
  { h1 = "4", h2 = "3", h3 = "2", h4 = "1", h5 = "0" },
  { "settler_housing_cap", "settler_housing_plots", "settler_housing_plot_tiers" })
check("shplots writes neither housing total",
  S.settler_housing_cap == nil and S.settler_housing_plots == nil,
  "cap=" .. tostring(S.settler_housing_cap) ..
    " plots=" .. tostring(S.settler_housing_plots))

-- sconsume is the one exception: its MIP wire form predates `_v_join` (an
-- arbitrary, possibly-partial "good:amount" dict -- see write_sconsume's
-- header comment in city.lua, and city_test.lua's own "fish:20;grain:15"
-- case), not a fixed-order positional record, so it does not go through
-- gmcp_map.zip like the other six. A GMCP payload for this key is the same
-- dict shape (good name -> amount); this case checks the same values fed as
-- a MIP string and as a literal GMCP dict leave S.settler_consumption
-- identical.
do
  local fields = { "settler_consumption" }
  clear(fields)
  city.SCONSUME("fish:20;grain:15")
  local via_mip = snapshot(fields)

  clear(fields)
  city._gmcp.SCONSUME({ fish = "20", grain = "15" })
  local via_gmcp = snapshot(fields)

  check("sconsume transport equivalence", same(via_mip, via_gmcp), "mip vs gmcp differ")
end

equivalent("settlerx", "SETTLERX",
  "feast|30|300|20|8|250|60|12|40|35|4|110|70|65|1|55|80|25|90|85|5|45|600|24",
  { edict = "feast", edict_left = "30", edict_cd = "300", housing_cap = "20",
    housing_plots = "8", housing_avg_tier_x100 = "250", housing_quality = "60",
    housing_upkeep = "12", jobs = "40", employed = "35",
    staffed_market_jobs = "4", mult_pct = "110", security = "70",
    dignity = "65", flourishing = "1", net = "55", tax_income = "80",
    comm_upkeep = "25", sustenance = "90", employment_score = "85",
    sentiment = "5", supply_next_secs = "45", pop_next_secs = "600",
    max_housing_plots = "24" },
  { "settler_edict", "settler_edict_left", "settler_edict_cd",
    "settler_housing_cap", "settler_housing_plots", "settler_housing_avg",
    "settler_housing_quality", "settler_housing_upkeep", "settler_jobs",
    "settler_employed", "settler_market_staffed", "settler_mult_pct",
    "settler_security", "settler_dignity", "settler_flourishing",
    "settler_community_net", "settler_community_upkeep", "settler_sustenance",
    "settler_emp_score", "settler_sentiment", "settler_supply_next",
    "settler_pop_next" })

-- Kills: a decoder that zips a short frame against the canonical 24-field
-- order regardless of length, which would silently misread every field from
-- LEGACY's retired 17-field layout onward (its position 17 is comm_upkeep,
-- not tax_income, so everything shifts). A 17-field frame is well short of
-- even the 23-field layout city_test.lua's own SETTLERX case sends (safe,
-- since positions 1-23 mean the same thing in both layouts -- see
-- write_settlerx's header comment), so the guard must reject this one.
do
  local fields = { "settler_edict", "settler_edict_left", "settler_edict_cd",
    "settler_housing_cap", "settler_housing_plots", "settler_housing_avg",
    "settler_housing_quality", "settler_housing_upkeep", "settler_jobs",
    "settler_employed", "settler_market_staffed", "settler_mult_pct",
    "settler_security", "settler_dignity", "settler_flourishing",
    "settler_community_net", "settler_community_upkeep", "settler_sustenance",
    "settler_emp_score", "settler_sentiment", "settler_supply_next",
    "settler_pop_next" }
  for _, f in ipairs(fields) do S[f] = "sentinel" end
  -- 17 pipe fields -- LEGACY's shortest retired tier.
  city.SETTLERX("feast|100|20|500|20|30|80|10|200|150|5|105|60|40|75|20|5")
  local all_unchanged = true
  for _, f in ipairs(fields) do
    if S[f] ~= "sentinel" then all_unchanged = false end
  end
  check("settlerx short frame writes nothing", all_unchanged)
end

equivalent("sproj", "SPROJ",
  "p1|build|A1|B2|300|timber:5|0|detail one|1;p2|raze|C3|D4|120||1|detail two|0",
  { { id = "p1", kind = "build", from = "A1", to = "B2", secs = "300",
      mats = "timber:5", done = "0", detail = "detail one", paid = "1" },
    { id = "p2", kind = "raze", from = "C3", to = "D4", secs = "120",
      mats = "", done = "1", detail = "detail two", paid = "0" } },
  { "settler_projects" })

-- sevents is also hand-encoded (players/viking/obj/include/client.h:
-- `out += r["ts"] + "|" + r["msg"]"), not _v_join -- msg is inserted raw and
-- may itself contain "|", so (like sconsume) it cannot go through
-- gmcp_map.zip: zip would split every "|" and truncate msg at the first one.
-- LEGACY's own decode (`entry:match("^([^|]+)|(.*)$")`) splits only the
-- first pipe, capturing the remainder greedily; city.SEVENTS keeps doing
-- exactly that. So, like sconsume, these cases construct the "GMCP form" as
-- a literal records list rather than via zip.
do
  local fields = { "settler_events" }
  clear(fields)
  city.SEVENTS("1000|first event;1001|second event")
  local via_mip = snapshot(fields)

  clear(fields)
  city._gmcp.SEVENTS({ { ts = "1000", msg = "first event" },
                        { ts = "1001", msg = "second event" } })
  local via_gmcp = snapshot(fields)

  check("sevents transport equivalence", same(via_mip, via_gmcp), "mip vs gmcp differ")
end

-- Kills: a decoder that splits msg on every "|" (e.g. zip against a
-- declared {ts, msg} order), which would truncate msg at the first embedded
-- pipe instead of keeping LEGACY's "capture the remainder greedily"
-- behavior. A real chat/event message can contain "|" (e.g. a copied
-- command or a channel name), so this is not a hypothetical.
do
  local fields = { "settler_events" }
  clear(fields)
  city.SEVENTS("1000|msg|with|pipe")
  local via_mip = snapshot(fields)

  clear(fields)
  city._gmcp.SEVENTS({ { ts = "1000", msg = "msg|with|pipe" } })
  local via_gmcp = snapshot(fields)

  check("sevents pipe-in-msg transport equivalence", same(via_mip, via_gmcp),
    "mip vs gmcp differ")
  check("sevents pipe-in-msg preserves the full message",
    via_mip.settler_events and via_mip.settler_events[1]
      and via_mip.settler_events[1].msg == "msg|with|pipe",
    via_mip.settler_events and via_mip.settler_events[1]
      and via_mip.settler_events[1].msg)
end

-- Kills: a writer that clears state it does not own, which would make a delta
-- frame for one key wipe another key's fields.
S.settler_events = { "sentinel" }
city._gmcp.SETTLERS({ settlers = "1", mood = "1", tax_rate = "1",
                      water = "1", fert = "1" })
check("writer touches only its own fields",
  S.settler_events ~= nil and S.settler_events[1] == "sentinel",
  S.settler_events and S.settler_events[1])

-- Kills: a registry that never exposed the writers, so protocol could not
-- route to them.
for _, k in ipairs({ "SETTLERS", "SETTLERX", "SACTIONS", "SHPLOTS", "SCONSUME",
                     "SPROJ", "SEVENTS" }) do
  check("gmcp writer registered for " .. k, type(city._gmcp[k]) == "function",
    type(city._gmcp[k]))
end

-- ---- scivics: `:` between fields, not `|` ---------------------------------
-- Kills: decoding scivics with the shared zip. Its MIP encoder is hand-written
-- as id .. ":" .. count, so the shared "|" decoder yields one field per record
-- and every count comes back nil.
--
-- S.settler_community_buildings is a { civic_id = tier } mapping, not an
-- array (state.lua's own comment, and pages/people.lua's sorted_keys(cb)
-- walk) -- confirmed while verifying this key's wire form against the
-- mudlib.
local function count_keys(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

local SCIVICS_FIELDS = { "settler_community_buildings" }
clear(SCIVICS_FIELDS)
city.SCIVICS("longhouse:2;forge:1")
local scivics_mip = snapshot(SCIVICS_FIELDS)
clear(SCIVICS_FIELDS)
city._gmcp.SCIVICS({ { id = "longhouse", count = "2" }, { id = "forge", count = "1" } })
-- This only pins that the MIP and GMCP paths agree -- both go through the
-- same write_scivics, so it cannot by itself tell a correct shape from a
-- wrong one both transports would share. It is still worth having as a
-- regression guard on the decoders themselves.
check("scivics transport equivalence", same(scivics_mip, snapshot(SCIVICS_FIELDS)),
  "mip vs gmcp differ")
-- pairs()-based counting is shape-blind: a 2-element ARRAY of {id,count}
-- records also has 2 pairs() entries, so a count alone cannot reject the
-- brief's flawed array-of-records sketch. `[1] == nil` is what actually
-- discriminates: only a mapping keyed by id passes it -- a sequence would
-- have [1] set to its first record.
check("scivics decoded two entries", count_keys(S.settler_community_buildings) == 2,
  count_keys(S.settler_community_buildings))
check("scivics keeps its mapping shape (not an array of records)",
  S.settler_community_buildings.longhouse == 2
    and S.settler_community_buildings.forge == 1
    and S.settler_community_buildings[1] == nil,
  "longhouse=" .. tostring(S.settler_community_buildings.longhouse) ..
    " forge=" .. tostring(S.settler_community_buildings.forge) ..
    " [1]=" .. tostring(S.settler_community_buildings[1]))

-- ---- sroles: one MIP key, two GMCP keys ----------------------------------
-- Kills: applying `sroles` without `sroles_meta`, which drops the commoner
-- count and identity that MIP packs into the first segment.
local SROLES_FIELDS = { "settler_roles", "settler_commoner", "settler_identity" }
clear(SROLES_FIELDS)
city.SROLES("meta|12|Freeholders;smidir:3:5:1:10;boendr:8:8:2:0")
local sroles_mip = snapshot(SROLES_FIELDS)

clear(SROLES_FIELDS)
city._gmcp.SROLES({
  sroles = {
    { role = "smidir", cur = "3", target = "5", work = "1", bonus = "10" },
    { role = "boendr", cur = "8", target = "8", work = "2", bonus = "0" },
  },
  sroles_meta = { commoner = "12", identity = "Freeholders",
                  identity_key = "freeholders" },
})
check("sroles transport equivalence", same(sroles_mip, snapshot(SROLES_FIELDS)),
  "mip vs gmcp differ")

-- Kills: dropping the label lookup on the GMCP path. `label` is derived from
-- the role key by a table the decoder owns, and the pane renders it.
check("sroles label derived on the gmcp path",
  S.settler_roles[1] and S.settler_roles[1].label == "Builders",
  S.settler_roles[1] and S.settler_roles[1].label)

-- Kills: GMCP's field names reaching state verbatim. It sends role/target
-- where the writer stores key/tgt.
check("sroles field names normalised",
  S.settler_roles[1].key == "smidir" and S.settler_roles[1].tgt == 5,
  S.settler_roles[1].tgt)

-- Kills: a composite applied on its first half, so a frame carrying only
-- `sroles` clobbers the meta fields the other half owns.
S.settler_commoner = 99
city._gmcp.SROLES({ sroles = { { role = "smidir", cur = "1", target = "1",
                                 work = "0", bonus = "0" } } })
check("sroles without meta leaves meta alone", S.settler_commoner == 99,
  S.settler_commoner)

-- Kills: COMPOSITE not naming both halves, so protocol cannot know to buffer
-- them.
check("COMPOSITE names sroles' halves",
  gmcp_map.COMPOSITE.SROLES and #gmcp_map.COMPOSITE.SROLES == 2,
  gmcp_map.COMPOSITE.SROLES and #gmcp_map.COMPOSITE.SROLES)

-- Kills: dropping LEGACY's unconditional reset of settler_commoner/identity
-- for malformed/degenerate MIP input. util.split(val, ";") always returns at
-- least one (possibly empty) string as its first element -- never nil -- so
-- the original "if segs[1] then" guard (and decode_sroles's equivalent) is
-- entered for every string input, meaning parts.sroles_meta is always built
-- and write_sroles always applies the commoner/identity reset. These two
-- cases pin that against genuinely malformed strings, not just the
-- well-formed one above.
clear(SROLES_FIELDS)
city.SROLES("")
check("sroles on empty input still resets commoner/identity",
  S.settler_commoner == 0 and S.settler_identity == "",
  "commoner=" .. tostring(S.settler_commoner) .. " identity=" .. tostring(S.settler_identity))

clear(SROLES_FIELDS)
city.SROLES("garbage-with-no-separators")
check("sroles on a header with no '|' still resets commoner/identity",
  S.settler_commoner == 0 and S.settler_identity == "",
  "commoner=" .. tostring(S.settler_commoner) .. " identity=" .. tostring(S.settler_identity))

-- ---- one frame, two writers, one state field ------------------------------
-- The per-key equivalence cases above are structurally blind to this: each
-- one clears and checks a single key in isolation, so two keys writing the
-- same field can never show up. That is exactly where the real bug was --
-- SETTLERX and SHPLOTS both wrote settler_housing_cap/settler_housing_plots.
-- Over MIP the server emits SETTLERX before SHPLOTS in one packet, so SHPLOTS'
-- stale per-tier arithmetic deterministically won; over GMCP frames are deltas
-- with no order at all.
--
-- Driven through protocol.on_gmcp rather than by calling the writers directly,
-- so the real frame path (key map, ordering, dispatch) is what is under test.
local protocol = require("protocol")
for key, fn in pairs(city._gmcp) do protocol.gmcp_handler(key, fn) end

local SETTLERX_GMCP = {
  edict = "feast", edict_left = "30", edict_cd = "300",
  housing_cap = "220", housing_plots = "20",
  housing_avg_tier_x100 = "250", housing_quality = "60", housing_upkeep = "12",
  jobs = "40", employed = "35", staffed_market_jobs = "4", mult_pct = "110",
  security = "70", dignity = "65", flourishing = "1", net = "55",
  tax_income = "80", comm_upkeep = "25", sustenance = "90",
  employment_score = "85", sentiment = "5", supply_next_secs = "45",
  pop_next_secs = "600", max_housing_plots = "24",
}
-- 4+3+2+1 = 10 plots over LEGACY's four tiers, and 20 over all five. Chosen so
-- every wrong answer is a different number from the right one: the removed
-- arithmetic would have produced plots 10 / cap 317 (4*18+3*30+2*45+1*65), and
-- a "just add tier 5" patch would have produced plots 20 / cap 967.
local SHPLOTS_GMCP = { h1 = "4", h2 = "3", h3 = "2", h4 = "1", h5 = "10" }

local HOUSING = { "settler_housing_cap", "settler_housing_plots",
                  "settler_housing_plot_tiers" }

clear(HOUSING)
protocol.on_gmcp("Guild.Settlement", { guild = "viking",
  settlerx = SETTLERX_GMCP, shplots = SHPLOTS_GMCP })
check("one frame carrying both settlerx and shplots: SETTLERX owns the totals",
  S.settler_housing_cap == 220 and S.settler_housing_plots == 20,
  "cap=" .. tostring(S.settler_housing_cap) ..
    " plots=" .. tostring(S.settler_housing_plots))
check("one frame carrying both settlerx and shplots: SHPLOTS owns the tiers",
  S.settler_housing_plot_tiers and S.settler_housing_plot_tiers.t1 == 4
    and S.settler_housing_plot_tiers.t5 == 10,
  S.settler_housing_plot_tiers and S.settler_housing_plot_tiers.t5)

-- The delta case: a later frame carrying only shplots must not move the
-- totals a previous settlerx established.
protocol.on_gmcp("Guild.Settlement", { guild = "viking",
  shplots = { h1 = "9", h2 = "0", h3 = "0", h4 = "0", h5 = "0" } })
check("a shplots-only delta leaves the housing totals where settlerx put them",
  S.settler_housing_cap == 220 and S.settler_housing_plots == 20,
  "cap=" .. tostring(S.settler_housing_cap) ..
    " plots=" .. tostring(S.settler_housing_plots))
check("a shplots-only delta does update the tiers",
  S.settler_housing_plot_tiers.t1 == 9 and S.settler_housing_plot_tiers.t5 == 0,
  S.settler_housing_plot_tiers.t1)

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
