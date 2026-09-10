-- crafting: refinery row parsing + the Refinery page.
-- Run from the lera-plugins repo root:
--   LERA_ROOT=/path/to/lera $LERA_ROOT/external/luajit/src/luajit \
--     tests/crafting_refinery_test.lua
package.path = "3scapes/crafting/?.lua;" .. package.path

local emit = print
local failures = 0
local function check(name, ok, detail)
  if ok then
    emit("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    emit("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- Only the real lera surface is stubbed (see guild_shaman's suite for why
-- inventing host functions makes a test suite worthless).
ui = { dirty = function() end }
buffer = { color_print = function() end }
lera = { time = function() return 1000 end }

local state = require("state")
local refinery = require("pages.refinery")
local buildings = require("pages.buildings")

-- Craft.Buildings arrives as pipe-delimited flat strings; feed the real
-- ingest path rather than poking state, so the parser is under test too.
local function ingest(rows)
  -- "Buildings" is the APPLY key (the GMCP sub-package name); the payload
  -- carries owned buildings and refinery rows together.
  state.apply("Buildings", { bldgs = { "Rift Foundry|3" }, refineries = rows })
end

-- ---------------------------------------------------------------------------
-- Wide rows: building|stage|material|percent|bldg_tier|max_tier
-- (min_rank is derived client-side from the fixed stage ladder)
-- ---------------------------------------------------------------------------
ingest({
  "Rift Foundry|1|Void Iron|60|3|6",
  "Rift Foundry|2|Entropy Shards|40|3|6",
  "Rift Foundry|3|Warp Glass|0|3|6",
  "Rift Foundry|7|Blood Crystal|0|3|6",
  "Grove Mill|1|Ironwood Timber|0|0|0",
})

local s = state.get()
check("wide rows parsed", #s.refineries == 5, #s.refineries)
local r1 = s.refineries[1]
check("wide row fields",
      r1.building == "Rift Foundry" and r1.tier == 1
      and r1.material == "Void Iron" and r1.percent == 60
      and r1.bldg_tier == 3 and r1.max_tier == 6 and r1.min_rank == 1,
      r1.material .. "/" .. tostring(r1.max_tier))

local lines = refinery.lines(80)
local body = table.concat(lines, "\n")
check("page renders", #lines > 0, #lines)
check("page lists a built refinery with its tier",
      body:find("Rift Foundry") ~= nil and body:find("stages 1%-6") ~= nil)
check("page shows allocated stages", body:find("60%%") ~= nil and body:find("40%%") ~= nil)
check("page totals the allocation", body:find("allocated 100%%") ~= nil, body:sub(1, 200))
check("page marks a stage past max_tier as locked", body:find("locked") ~= nil)
check("page shows min rank", body:find("R67") ~= nil)
check("page shows an unbuilt refinery as not built",
      body:find("Grove Mill") ~= nil and body:find("not built") ~= nil)
-- An unbuilt refinery must not also print a stage table.
local gm = body:match("Grove Mill.*")
check("unbuilt refinery prints no stage rows",
      gm and gm:find("Ironwood") == nil, gm and gm:sub(1, 80))

-- ---------------------------------------------------------------------------
-- Over/under allocation is called out
-- ---------------------------------------------------------------------------
ingest({ "Rift Foundry|1|Void Iron|30|3|6" })
check("under-allocation reported", refinery.lines(80)[2]:find("allocated 30%%") ~= nil,
      refinery.lines(80)[2])

ingest({ "Rift Foundry|1|Void Iron|70|3|6",
         "Rift Foundry|2|Entropy Shards|60|3|6" })
check("over-allocation reported",
      table.concat(refinery.lines(80), "\n"):find("allocated 130%%") ~= nil)

-- ---------------------------------------------------------------------------
-- Legacy 4-field rows still parse (older server, narrower payload)
-- ---------------------------------------------------------------------------
ingest({ "Rift Foundry|1|Void Iron|55", "Rift Foundry|2|Entropy Shards|45" })
s = state.get()
check("legacy rows parsed", #s.refineries == 2, #s.refineries)
check("legacy rows carry no lock info",
      s.refineries[1].max_tier == nil and s.refineries[1].bldg_tier == nil)
local legacy_body = table.concat(refinery.lines(80), "\n")
check("legacy rows still render their allocations",
      legacy_body:find("55%%") ~= nil and legacy_body:find("45%%") ~= nil)
-- Without max_tier the lock state is unknown, so nothing may be greyed out as
-- locked -- silently mislabelling every stage would be worse than omitting it.
check("legacy rows are never shown as locked", legacy_body:find("locked") == nil)

-- ---------------------------------------------------------------------------
-- Empty state
-- ---------------------------------------------------------------------------
ingest({})
check("empty refinery list renders a placeholder, not an error",
      #refinery.lines(80) > 0
      and table.concat(refinery.lines(80), "\n"):find("received yet") ~= nil)

-- ---------------------------------------------------------------------------
-- Buildings page no longer duplicates the full chain
-- ---------------------------------------------------------------------------
ingest({
  "Rift Foundry|1|Void Iron|60|3|6",
  "Rift Foundry|2|Entropy Shards|0|3|6",
  "Rift Foundry|3|Warp Glass|0|3|6",
})
local bbody = table.concat(buildings.lines(80), "\n")
check("buildings page summarises instead of listing every stage",
      bbody:find("see the Refinery tab") ~= nil, bbody:sub(-160))
check("buildings page does not reprint the chain",
      bbody:find("Warp Glass") == nil)
check("buildings page counts only allocated stages",
      bbody:find("1 allocated stage") ~= nil, bbody:sub(-160))

-- ---------------------------------------------------------------------------
-- Row WIDTH handling. The parser must dispatch on field count, never on a
-- chain of anchored patterns.
--
-- The bug this guards: `^(.-)|(%d+)|(.-)|(%d+)$` (the four-field legacy form)
-- matches a SEVEN-field row perfectly, because `.-` spans delimiters. A client
-- running against a server whose payload width had not been updated in
-- lockstep silently produced material names like "Fantasy Essence|0|0|0" and
-- invented allocations, instead of failing visibly.
-- ---------------------------------------------------------------------------
ingest({
  "Distilling Font|1|Fantasy Essence|0|0|0|1",   -- 7 fields (server sends rank)
  "Rift Foundry|2|Void Iron|40|5|10",            -- 6 fields (rank derived)
  "Legacy Mill|4|Old Thing|15",                  -- 4 fields (allocations only)
  "Malformed|row",                               -- 2 fields: must be rejected
  "Also|bad|three",                              -- 3 fields: must be rejected
})
s = state.get()
check("only well-formed widths are accepted", #s.refineries == 3, #s.refineries)

local by_b = {}
for _, r in ipairs(s.refineries) do by_b[r.building] = r end

check("7-field row keeps a clean material name",
      by_b["Distilling Font"].material == "Fantasy Essence",
      by_b["Distilling Font"].material)
check("7-field row does not invent a percent",
      by_b["Distilling Font"].percent == 0, by_b["Distilling Font"].percent)
check("7-field row uses the server's own rank",
      by_b["Distilling Font"].min_rank == 1, by_b["Distilling Font"].min_rank)

check("6-field row parses and derives its rank",
      by_b["Rift Foundry"].material == "Void Iron"
      and by_b["Rift Foundry"].percent == 40
      and by_b["Rift Foundry"].min_rank == 12,
      by_b["Rift Foundry"].min_rank)

check("4-field row parses with no lock info",
      by_b["Legacy Mill"].material == "Old Thing"
      and by_b["Legacy Mill"].percent == 15
      and by_b["Legacy Mill"].max_tier == nil)

-- No parsed material may ever contain the delimiter -- that is the signature
-- of the mis-match this guards against.
local clean = true
for _, r in ipairs(s.refineries) do
  if tostring(r.material):find("|", 1, true) then clean = false end
end
check("no material name contains a delimiter", clean)

-- ---------------------------------------------------------------------------
-- A FULL payload, delivered the way the server actually chunks it.
--
-- The bug this guards: six refineries x ten stages is 60 rows, and the server
-- splits them across "refineries", "refineries_1", "refineries_2", ... . An
-- earlier version chunked at 12 and the client received only fragments, so the
-- tab showed a few stages instead of T1-T10. Feeding one big array would never
-- have caught that -- the chunk KEYS have to be exercised.
-- ---------------------------------------------------------------------------
local REFS = { "Fleshworks", "Rift Foundry", "Grove Mill",
               "Crystal Refinery", "Alloy Works", "Reactor Core" }
local CHUNK = 4   -- CRAFT_GMCP_REFINERY_CHUNK

local all_rows = {}
for _, b in ipairs(REFS) do
  for stage = 1, 10 do
    all_rows[#all_rows + 1] = string.format("%s|%d|Material %d|%d|5|10",
      b, stage, stage, stage == 1 and 100 or 0)
  end
end
check("fixture is a full six-refinery payload", #all_rows == 60, #all_rows)

-- Rebuild the mirror the way protocol.lua accumulates chunk keys, then apply.
local mirror = { bldgs = { "Rift Foundry|5" } }
for i = 1, #all_rows, CHUNK do
  local part = {}
  for j = i, math.min(i + CHUNK - 1, #all_rows) do part[#part + 1] = all_rows[j] end
  local idx = (i - 1) / CHUNK
  mirror[idx == 0 and "refineries" or ("refineries_" .. idx)] = part
end
state.apply("Buildings", mirror)

s = state.get()
check("all 60 rows survive chunked delivery", #s.refineries == 60, #s.refineries)

-- Every refinery must show all ten stages, in order.
local per = {}
for _, r in ipairs(s.refineries) do
  per[r.building] = (per[r.building] or 0) + 1
end
local complete = true
for _, b in ipairs(REFS) do
  if per[b] ~= 10 then complete = false end
end
check("every refinery has all ten stages", complete,
      table.concat({ per[REFS[1]] or 0, per[REFS[6]] or 0 }, "/"))

local full_body = table.concat(refinery.lines(100), "\n")
for _, b in ipairs(REFS) do
  check("page renders " .. b, full_body:find(b, 1, true) ~= nil)
end
check("page renders stage T10", full_body:find("T10") ~= nil)
check("page renders every stage T1..T10 for a refinery", (function()
  for stage = 1, 10 do
    if not full_body:find("T" .. stage) then return false end
  end
  return true
end)())
-- min_rank is derived client-side now; stage 10 must still read R100.
check("derived min_rank ladder reaches R100", full_body:find("R100") ~= nil)
check("derived min_rank ladder starts at R1", full_body:find("R1%f[%D]") ~= nil)

-- ---------------------------------------------------------------------------
-- The tab is registered
-- ---------------------------------------------------------------------------
local window = require("window")
local found = nil
for _, p in ipairs(window.PAGES) do
  if p.key == "refinery" then found = p end
end
check("Refinery tab registered", found ~= nil and found.label == "Refinery",
      found and found.label)
check("Refinery tab sits next to Buildings", (function()
  for i, p in ipairs(window.PAGES) do
    if p.key == "refinery" then return window.PAGES[i - 1].key == "buildings" end
  end
  return false
end)())

-- ---------------------------------------------------------------------------
-- Recipe scroll auctions (Craft.Market's scroll_auctions / scroll_outbox)
-- ---------------------------------------------------------------------------
local market = require("pages.market")

state.apply("Market", {
  orders = {}, material_orders = {}, exchanges = {}, auctions = {},
  scroll_auctions = {
    { id = 7, seller = "runa", recipe = "refine-black-blood",
      recipe_name = "Refine Black Blood", high_bid = 250, reserve = 400,
      closes = os.time() + 120 },
  },
  scroll_outbox = { "Refine Void Tar", "Refine Ember Seeds" },
})
s = state.get()
check("scroll auctions ingested", #s.scroll_auctions == 1, #s.scroll_auctions)
check("scroll outbox ingested", #s.scroll_outbox == 2, #s.scroll_outbox)

local mbody = table.concat(market.lines(90), "\n")
check("market page has a scroll auction section",
      mbody:find("Recipe Scroll Auctions") ~= nil)
check("market page shows the resolved recipe name",
      mbody:find("Refine Black Blood") ~= nil)
check("market page shows the bid", mbody:find("250") ~= nil)
check("market page surfaces the collect prompt",
      mbody:find("cmarket scroll collect") ~= nil, mbody:sub(-200))
check("market page lists each waiting scroll",
      mbody:find("Refine Void Tar") ~= nil and mbody:find("Refine Ember Seeds") ~= nil)

-- Empty book must render a placeholder, not vanish or error.
state.apply("Market", { orders = {}, material_orders = {}, exchanges = {},
                        auctions = {}, scroll_auctions = {}, scroll_outbox = {} })
local empty = table.concat(market.lines(90), "\n")
check("empty scroll book still renders its section",
      empty:find("Recipe Scroll Auctions") ~= nil)
check("empty scroll outbox shows no collect prompt",
      empty:find("cmarket scroll collect") == nil)

-- A server that predates the scroll book sends neither key.
state.apply("Market", { orders = {}, material_orders = {}, exchanges = {}, auctions = {} })
check("missing scroll keys default to empty, not nil",
      #state.get().scroll_auctions == 0 and #state.get().scroll_outbox == 0)
check("market page still renders against a pre-scroll server",
      (function() local ok = pcall(market.lines, 90) return ok end)())

emit(string.format("\n%d failures (final)", failures))
os.exit(failures == 0 and 0 or 1)
