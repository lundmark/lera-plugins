-- guild_viking GMCP frame handling. Run from the lera-plugins repo root with
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

-- ---- lera API stubs (same shape as guild_viking_city_test.lua) -------------
local dirty_count = 0
ui = { dirty = function() dirty_count = dirty_count + 1 end }
local stored = nil
store = {
  load = function() end,
  get = function() return stored end,
  set = function(d) stored = d end,
  save = function() end,
}
lera = { time = function() return 1000 end, version = function() return "test" end }
buffer = { color_print = function() end }
mud = { send = function() end }

local protocol = require("protocol")

-- Record what each registered writer received.
local got = {}
local function recorder(name)
  return function(rec) got[name] = rec end
end

protocol.gmcp_handler("SETTLERS", recorder("SETTLERS"))

local function frame(pkg, data) protocol.on_gmcp(pkg, data) end

local function reset()
  got = {}
  protocol.reset_connection()
end

-- ---- guild filtering -------------------------------------------------------
-- Kills: applying a frame without checking whose guild sent it. Another guild's
-- push would write straight into Viking state.
reset()
frame("Guild.Settlement", { guild = "Elves", settlers = { a = 1 } })
check("foreign guild frame dropped", got.SETTLERS == nil)
check("foreign frame counted", protocol.gmcp_stats().foreign == 1,
  protocol.gmcp_stats().foreign)

-- Kills: a missing guild key treated as ours.
reset()
frame("Guild.Settlement", { settlers = { a = 1 } })
check("frame with no guild key dropped", got.SETTLERS == nil)

-- Kills: comparing against the wrong literal. The mudlib's set_guild call
-- for this guild (players/viking/room/gatehouse.c:254) uses a lowercase,
-- singular value, and query_guild() returns it unnormalized. A constant
-- shared between the implementation and its test proves nothing on its own,
-- so these exercise the actual server value and a casing variant of it, not
-- the literal the code happens to compare against.
reset()
frame("Guild.Settlement", { guild = "viking", settlers = { a = 1 } })
check("the server's actual lowercase value routes",
  got.SETTLERS ~= nil and got.SETTLERS.a == 1)

reset()
frame("Guild.Settlement", { guild = "Viking", settlers = { a = 1 } })
check("a differently-cased variant still routes",
  got.SETTLERS ~= nil and got.SETTLERS.a == 1)

-- Kills: matching too loosely (e.g. any string, or a substring match) instead
-- of comparing against this guild specifically. "druid" is another guild's
-- real set_guild(...) value, not an invented name.
reset()
frame("Guild.Settlement", { guild = "druid", settlers = { a = 1 } })
check("another real guild ('druid') dropped", got.SETTLERS == nil)
check("another real guild counted foreign", protocol.gmcp_stats().foreign == 1,
  protocol.gmcp_stats().foreign)

-- ---- key routing -----------------------------------------------------------
-- Kills: routing the raw lowercase key, which matches no handler, or failing to
-- strip the envelope so `guild` is treated as data.
reset()
frame("Guild.Settlement", { guild = "viking", settlers = { a = 1 } })
check("registered key applied", got.SETTLERS ~= nil and got.SETTLERS.a == 1,
  got.SETTLERS and got.SETTLERS.a)
-- Kills: not stripping the envelope, so `guild` is routed as data. Nothing
-- registers a writer for it, so the observable effect is an unknown count.
check("envelope key not routed",
  protocol.gmcp_stats().unknown.GUILD == nil and
  protocol.gmcp_stats().unknown.guild == nil)
check("applied counted", protocol.gmcp_stats().applied.SETTLERS == 1,
  protocol.gmcp_stats().applied.SETTLERS)

-- Kills: silently dropping a key nothing handles. A key the guild starts
-- sending must be distinguishable from one it never sent.
reset()
frame("Guild.Settlement", { guild = "viking", nosuchkey = { a = 1 } })
check("unhandled key counted", protocol.gmcp_stats().unknown.nosuchkey == 1,
  protocol.gmcp_stats().unknown.nosuchkey)

-- Kills: not marking the screen dirty, so a pane fed only by GMCP never
-- repaints until unrelated output arrives.
reset()
local before = dirty_count
frame("Guild.Settlement", { guild = "viking", settlers = { a = 1 } })
check("applying a key marks ui dirty", dirty_count > before)

-- ---- malformed -------------------------------------------------------------
-- Kills: trusting the payload. lera delivers data == nil for undecodable JSON.
reset()
frame("Guild.Settlement", nil)
check("nil payload is a no-op", got.SETTLERS == nil)
frame("Guild.Settlement", "a string")
check("non-table payload is a no-op", got.SETTLERS == nil)

-- ---- Guild.State's vitals route to the VITALS writer ----------------------
-- This file registers no handler modules, so VITALS has no writer here and the
-- key is counted unknown under its COMPOSITE name -- which is the point worth
-- pinning at this layer: `hp` must no longer be counted under its own GMCP
-- name, because that is what "no writer is mapped for it" looks like.
--
-- The writer's behaviour is guild_viking_gmcp_vitals_test.lua's subject.
reset()
frame("Guild.State", { guild = "viking", hp = { cur = 5, max = 10 } })
check("Guild.State hp is no longer counted under its own name",
  protocol.gmcp_stats().unknown.hp == nil, protocol.gmcp_stats().unknown.hp)
check("Guild.State hp is gathered into the VITALS composite",
  protocol.gmcp_stats().unknown.VITALS == 1, protocol.gmcp_stats().unknown.VITALS)

-- ---- a raising gmcp writer is countable and does not block its siblings --
-- Kills: routing a writer error into the MIP-scoped stats/print path instead
-- of gmcp_stats (an observability hole: /vik source reads gmcp_stats(), which
-- would then never show a GMCP write failure). Kills: one raising writer
-- aborting the whole frame instead of just that key -- CIDLE and SETTLERS
-- are unrelated keys in the same frame.
-- (CIDLE, not the "boomkey" this case used to send: that name only routed
-- because of the uppercase derivation this task removes, and is not in the
-- key map. cidle/CIDLE is a real mapped key, unused elsewhere in this suite.)
protocol.gmcp_handler("CIDLE", function() error("boom") end)
reset()
frame("Guild.Settlement", { guild = "viking", cidle = "x", settlers = { a = 2 } })
check("raising gmcp writer counted in gmcp_stats().errors",
  protocol.gmcp_stats().errors.CIDLE == 1, protocol.gmcp_stats().errors.CIDLE)
check("raising gmcp writer not counted as applied",
  protocol.gmcp_stats().applied.CIDLE == nil)
check("sibling key in the same frame still applied",
  got.SETTLERS ~= nil and got.SETTLERS.a == 2)

-- Kills: latching a key on the mere fact that a writer was invoked, rather
-- than on the writer succeeding. Latch-on-success is the safety property of
-- the whole per-key design: a GMCP writer that raises has written nothing, so
-- suppressing that key's MIP twin would take the field dark for the rest of
-- the connection with no error the user can see on the page. Only the
-- unknown-key path was covered before; this is the raising-writer path.
check("raising gmcp writer does not latch its key",
  protocol.gmcp_keys().CIDLE == nil)
local cidle_from_mip
protocol.handler("CIDLE", function(val) cidle_from_mip = val end)
protocol.ingest("CIDLE", "from-mip")
check("the MIP twin of a raising gmcp writer is still accepted",
  cidle_from_mip == "from-mip", tostring(cidle_from_mip))

-- ---- paging ----------------------------------------------------------------
-- Kills: applying each page independently. The server slices an oversized array
-- key across pages, repeating the key, so independent application truncates a
-- long list to its final slice.
reset()
frame("Guild.Settlement", { guild = "viking", page = 1, pages = 2,
                            settlers = { "a", "b" } })
check("page 1 of 2 not applied yet", got.SETTLERS == nil)
frame("Guild.Settlement", { guild = "viking", page = 2, pages = 2,
                            settlers = { "c" } })
check("sliced key rejoined, not truncated",
  got.SETTLERS and #got.SETTLERS == 3 and got.SETTLERS[3] == "c",
  got.SETTLERS and #got.SETTLERS)

-- Kills: rejoining a key that was not sliced. A key carried once in a paged run
-- must be applied as-is, not wrapped or concatenated with itself.
reset()
frame("Guild.Settlement", { guild = "viking", page = 1, pages = 2,
                            settlers = { a = 1 } })
frame("Guild.Settlement", { guild = "viking", page = 2, pages = 2 })
check("unsliced key in a paged run applied whole",
  got.SETTLERS ~= nil and got.SETTLERS.a == 1, got.SETTLERS and got.SETTLERS.a)

-- Kills: an accumulator that survives a restarted run, merging two different
-- snapshots into one.
reset()
frame("Guild.Settlement", { guild = "viking", page = 1, pages = 2,
                            settlers = { "stale" } })
frame("Guild.Settlement", { guild = "viking", page = 1, pages = 2,
                            settlers = { "fresh" } })
frame("Guild.Settlement", { guild = "viking", page = 2, pages = 2 })
check("restarted run drops the abandoned page",
  got.SETTLERS and #got.SETTLERS == 1 and got.SETTLERS[1] == "fresh",
  got.SETTLERS and got.SETTLERS[1])

-- Kills: applying an out-of-order run partially.
reset()
frame("Guild.Settlement", { guild = "viking", page = 2, pages = 2,
                            settlers = { "orphan" } })
check("orphan page not applied", got.SETTLERS == nil)
-- Kills: an orphan leaving the accumulator wedged so later frames are ignored.
frame("Guild.Settlement", { guild = "viking", settlers = { a = 9 } })
check("handler recovers after an orphan page",
  got.SETTLERS ~= nil and got.SETTLERS.a == 9, got.SETTLERS and got.SETTLERS.a)

-- Kills: paging state shared across packages. Two panels can page at once.
reset()
frame("Guild.Settlement", { guild = "viking", page = 1, pages = 2,
                            settlers = { "s1" } })
frame("Guild.Trade", { guild = "viking", page = 1, pages = 2, settlers = { "t1" } })
frame("Guild.Settlement", { guild = "viking", page = 2, pages = 2,
                            settlers = { "s2" } })
check("per-package paging state",
  got.SETTLERS and #got.SETTLERS == 2 and got.SETTLERS[1] == "s1",
  got.SETTLERS and got.SETTLERS[1])

-- Kills: skipping the malformed counter, or dropping the whole run, when a
-- key repeats across pages with mismatched shapes. Only arrays are ever
-- sliced server-side; a repeated non-array is last-value-wins, not
-- concatenated, and must not discard the rest of the run.
-- (sconsume/SCONSUME, not the "sibling" key this case used to send: that name
-- only routed because of the uppercase derivation this task removes, and is
-- not in the key map. sconsume/SCONSUME is a real mapped key, unused
-- elsewhere in this suite.)
protocol.gmcp_handler("SCONSUME", recorder("SCONSUME"))
reset()
local malformed_before = protocol.gmcp_stats().malformed or 0
frame("Guild.Settlement", { guild = "viking", page = 1, pages = 2,
                            settlers = { "a" } })
frame("Guild.Settlement", { guild = "viking", page = 2, pages = 2,
                            settlers = { x = 1 }, sconsume = "ok" })
check("type-mismatched repeat is last-value-wins, not concatenated",
  got.SETTLERS ~= nil and got.SETTLERS.x == 1 and got.SETTLERS[1] == nil,
  got.SETTLERS)
check("type mismatch counted malformed exactly once",
  (protocol.gmcp_stats().malformed or 0) == malformed_before + 1,
  protocol.gmcp_stats().malformed)
check("sibling key in the same run still applied",
  got.SCONSUME == "ok", got.SCONSUME)

-- ---- per-key latch ---------------------------------------------------------
-- SETTLERS already has a gmcp_handler registered above (line 37); reused here
-- rather than re-registered, since protocol.gmcp_handler errors on a dup key.
local ingested = {}
protocol.handler("SETTLERS", function(val) ingested.SETTLERS = val end)
protocol.handler("MIPONLY", function(val) ingested.MIPONLY = val end)

-- Kills: suppressing MIP wholesale once any GMCP frame arrives. Keys GMCP does
-- not push must keep flowing, or the voyage and war pages go dark.
reset()
ingested = {}
protocol.source("auto")
frame("Guild.Settlement", { guild = "viking", settlers = { a = 1 } })
protocol.ingest("SETTLERS", "from-mip")
protocol.ingest("MIPONLY", "from-mip")
check("latched key ignores MIP", ingested.SETTLERS == nil)
check("unlatched sibling still accepts MIP", ingested.MIPONLY == "from-mip",
  tostring(ingested.MIPONLY))
check("latched key listed", protocol.gmcp_keys().SETTLERS == true)
check("unlatched key not listed", protocol.gmcp_keys().MIPONLY == nil)

-- Kills: latching before a writer ran. A key counted unknown has not been fed
-- by GMCP and must not suppress its MIP twin.
reset()
ingested = {}
frame("Guild.Settlement", { guild = "viking", nosuchkey = { a = 1 } })
protocol.ingest("MIPONLY", "from-mip")
check("unknown gmcp key does not latch", protocol.gmcp_keys().NOSUCHKEY == nil)
check("unknown gmcp key does not suppress MIP", ingested.MIPONLY == "from-mip")

-- ---- source_mode overrides -------------------------------------------------
-- Kills: honouring GMCP frames under `source mip`, which is the override you
-- reach for precisely to rule GMCP out while debugging.
reset()
ingested = {}
protocol.source("mip")
frame("Guild.Settlement", { guild = "viking", settlers = { a = 1 } })
check("source mip drops gmcp frames", got.SETTLERS == nil)
protocol.ingest("SETTLERS", "from-mip")
check("source mip keeps MIP flowing", ingested.SETTLERS == "from-mip",
  tostring(ingested.SETTLERS))

-- Kills: `source gmcp` still letting an unlatched MIP key through.
reset()
ingested = {}
protocol.source("gmcp")
protocol.ingest("MIPONLY", "from-mip")
check("source gmcp suppresses every MIP key", ingested.MIPONLY == nil)
protocol.source("auto")

-- ---- reset -----------------------------------------------------------------
-- Kills: a latch surviving a disconnect. The next session may not negotiate
-- GMCP at all, and a stale latch would silence MIP forever.
reset()
ingested = {}
frame("Guild.Settlement", { guild = "viking", settlers = { a = 1 } })
protocol.reset_connection()
protocol.ingest("SETTLERS", "from-mip")
check("latch clears on disconnect", ingested.SETTLERS == "from-mip",
  tostring(ingested.SETTLERS))

-- ---- key map ---------------------------------------------------------------
local gmcp_map = require("gmcp_map")

-- Kills: deriving the MIP key by uppercasing. Three keys break that rule.
check("identity mapping", gmcp_map.mip_key("settlers") == "SETTLERS",
  gmcp_map.mip_key("settlers"))
check("queue renames to TQUEUE", gmcp_map.mip_key("queue") == "TQUEUE",
  gmcp_map.mip_key("queue"))
check("monuments_cap maps to MONUMENTS",
  gmcp_map.mip_key("monuments_cap") == "MONUMENTS",
  gmcp_map.mip_key("monuments_cap"))
check("sroles_meta maps to SROLES",
  gmcp_map.mip_key("sroles_meta") == "SROLES",
  gmcp_map.mip_key("sroles_meta"))

-- Kills: mapping a key the guild sends but nothing consumes. These must stay
-- unmapped so they are counted rather than routed.
--
-- cart_legs, queue_legs and refinery_grades were on this list and are not any
-- more. They were listed on the grounds that nothing renders them, which was
-- wrong: MIP packed each one inside its parent key, and the Trade pages read a
-- cart's `legs`, the trade queue's `legs` and a refinery's `grades`. They are
-- composite halves now -- see gmcp_map.COMPOSITE -- and the cases further down
-- assert they reach their parent's writer.
for _, k in ipairs({ "crpr", "gneeds", "rneeds" }) do
  check("unmatched key " .. k .. " is unmapped", gmcp_map.mip_key(k) == nil,
    gmcp_map.mip_key(k))
end

-- ---- shared decoder --------------------------------------------------------
-- Kills: a decoder that returns fields positionally instead of named, which
-- would make the MIP and GMCP paths disagree on shape.
local recs = gmcp_map.zip({ "a", "b", "c" }, "1|2|3")
check("zip one record", #recs == 1 and recs[1].a == "1" and recs[1].c == "3",
  #recs)

-- Kills: treating the whole value as one record. `;` separates records.
recs = gmcp_map.zip({ "a", "b" }, "1|2;3|4")
check("zip record list", #recs == 2 and recs[2].a == "3" and recs[2].b == "4",
  #recs)

-- Kills: dropping a trailing empty field. MIP sends empty strings for absent
-- values, and a writer's `tonumber(x) or 0` depends on the field being present.
recs = gmcp_map.zip({ "a", "b", "c" }, "1||")
check("zip keeps empty fields",
  #recs == 1 and recs[1].b == "" and recs[1].c == "", recs[1] and recs[1].c)

-- Kills: an empty value producing a phantom record.
check("zip of empty string is empty", #gmcp_map.zip({ "a" }, "") == 0)

-- Kills: a trailing ";" producing a phantom empty-record, distinct from an
-- entirely empty value above. util.split(";"-separated) preserves a trailing
-- empty chunk; a record list decoder must drop it, the same way LEGACY's
-- val:gmatch("[^;]+") never yielded one.
recs = gmcp_map.zip({ "a", "b" }, "1|2;")
check("zip drops a phantom record from a trailing ';'", #recs == 1 and recs[1].a == "1",
  #recs)

-- Kills: a doubled ";;" mid-string producing a phantom empty-record between
-- two real ones.
recs = gmcp_map.zip({ "a", "b" }, "1|2;;3|4")
check("zip drops a phantom record from a doubled ';;' mid-string",
  #recs == 2 and recs[1].a == "1" and recs[2].a == "3", #recs)

-- Re-assertion: dropping empty *records* must not touch empty *fields* --
-- "1||" is one record with two empty fields, not a record to drop.
recs = gmcp_map.zip({ "a", "b", "c" }, "1||")
check("zip still keeps empty fields after the empty-record fix",
  #recs == 1 and recs[1].b == "" and recs[1].c == "", recs[1] and recs[1].c)

-- ---- routing through the map -----------------------------------------------
-- Kills: apply_gmcp_key still uppercasing rather than consulting the map.
-- `queue` -> TQUEUE is the only key in the map whose MIP name is not simply its
-- own uppercase, so it is the one that can catch a derivation. It is also a
-- composite half now, so the writer receives the gathered table rather than the
-- value on its own -- which is what the second assertion pins.
reset()
protocol.gmcp_handler("TQUEUE", recorder("TQUEUE"))
frame("Guild.Trade", { guild = "viking", queue = { a = 1 } })
check("renamed key routes to its writer", got.TQUEUE ~= nil,
  got.TQUEUE)
check("a composite half arrives keyed by its own gmcp name",
  got.TQUEUE ~= nil and got.TQUEUE.queue ~= nil and got.TQUEUE.queue.a == 1,
  got.TQUEUE and got.TQUEUE.queue)

-- Kills: an unmapped key counted under its own name rather than being visible
-- as the GMCP key the guild actually sent.
reset()
frame("Guild.Trade", { guild = "viking", crpr = { a = 1 } })
check("unmapped key counted by its gmcp name",
  protocol.gmcp_stats().unknown.crpr == 1,
  protocol.gmcp_stats().unknown.crpr)

-- ---- deterministic key order ----------------------------------------------
-- Kills: applying a frame's keys in pairs() order. pairs() follows the table's
-- internal hashing, not the frame, so two writers touching a common state
-- field land in an arbitrary order -- and since frames are deltas, either key
-- may also arrive alone. The symptom is a pane value flickering between two
-- answers with no underlying state change, which is close to undebuggable
-- from a bug report. That collision is designed out today (SETTLERX owns the
-- housing totals outright), but a later plan adds ~20 more keys, so the order
-- itself is pinned here.
--
-- The four keys below are real, mapped, otherwise-unused Guild.City keys,
-- chosen because LuaJIT's pairs() walks them raid, heat, bdmg, cdtime -- a
-- different order from the sorted MIP order this asserts, and from the order
-- they are written in the frame literal. Nothing about the frame can produce
-- BDMG, CDTIME, HEAT, RAID by accident.
local applied_order = {}
for _, k in ipairs({ "BDMG", "CDTIME", "HEAT", "RAID" }) do
  protocol.gmcp_handler(k, function() applied_order[#applied_order + 1] = k end)
end

reset()
applied_order = {}
frame("Guild.City", { guild = "viking", raid = "1", heat = "2", bdmg = "3",
                      cdtime = "4" })
check("frame keys applied in a declared, stable order",
  table.concat(applied_order, ",") == "BDMG,CDTIME,HEAT,RAID",
  table.concat(applied_order, ","))

-- The de-paged branch rebuilds its own table (merge_page -> run.keys) before
-- applying, so it gets the same pin -- it is the call site most likely to rot.
reset()
applied_order = {}
frame("Guild.City", { guild = "viking", page = 1, pages = 2,
                      raid = "1", heat = "2" })
frame("Guild.City", { guild = "viking", page = 2, pages = 2,
                      bdmg = "3", cdtime = "4" })
check("de-paged run applies keys in the same declared order",
  table.concat(applied_order, ",") == "BDMG,CDTIME,HEAT,RAID",
  table.concat(applied_order, ","))

-- ---- composite plumbing (SROLES: two GMCP keys, one MIP key) ---------------
-- Exercises apply_gmcp_frame/composite_of directly through protocol.on_gmcp,
-- rather than through city._gmcp.SROLES (which the settlement suite calls
-- directly, bypassing this plumbing entirely). Before this fix, both
-- on_gmcp branches called protocol.apply_gmcp_key once per GMCP key, and
-- apply_gmcp_key resolves "sroles" and "sroles_meta" to the SAME mip_key
-- (SROLES) -- so the writer would have been invoked twice, once per raw
-- half, never with a table carrying both `.sroles` and `.sroles_meta`.
local sroles_calls = 0
protocol.gmcp_handler("SROLES", function(rec)
  sroles_calls = sroles_calls + 1
  got.SROLES = rec
end)

-- Kills: calling the writer once per GMCP key instead of gathering both
-- composite halves of one frame into a single call.
reset()
sroles_calls = 0
frame("Guild.Settlement", { guild = "viking",
  sroles = { { role = "smidir" } },
  sroles_meta = { commoner = "5", identity = "X" } })
check("composite frame with both halves reaches the writer exactly once",
  sroles_calls == 1, sroles_calls)
check("composite frame with both halves carries both keys in one call",
  got.SROLES ~= nil and got.SROLES.sroles ~= nil and got.SROLES.sroles_meta ~= nil,
  got.SROLES)

-- Kills: composite gathering requiring both halves to be present, silently
-- dropping (or erroring on) a delta frame that carries only one.
reset()
sroles_calls = 0
frame("Guild.Settlement", { guild = "viking", sroles = { { role = "boendr" } } })
check("delta frame with only sroles reaches the writer exactly once",
  sroles_calls == 1, sroles_calls)
check("delta frame with only sroles omits sroles_meta from the call",
  got.SROLES ~= nil and got.SROLES.sroles ~= nil and got.SROLES.sroles_meta == nil,
  got.SROLES)

-- Kills: the de-paged branch (merge_page -> run.keys, applied once page ==
-- pages) failing to gather composite halves the same way the unpaged branch
-- does -- this call site is the one most likely to rot, since nothing else
-- here exercises it.
reset()
sroles_calls = 0
frame("Guild.Settlement", { guild = "viking", page = 1, pages = 2,
                            sroles = { { role = "smidir" } } })
check("paged run not applied before the final page", sroles_calls == 0, sroles_calls)
frame("Guild.Settlement", { guild = "viking", page = 2, pages = 2,
                            sroles_meta = { commoner = "9", identity = "Y" } })
check("paged run gathers both halves into one call",
  sroles_calls == 1, sroles_calls)
check("paged run's single call carries both keys",
  got.SROLES ~= nil and got.SROLES.sroles ~= nil and got.SROLES.sroles_meta ~= nil,
  got.SROLES)

-- Kills: a composite key with no registered writer (MONUMENTS, pending a
-- later plan) raising instead of being counted like any other unknown key.
reset()
local ok, err = pcall(frame, "Guild.City", { guild = "viking",
  monuments_cap = "3", monuments_list = { "a", "b" } })
check("composite key with no writer does not raise", ok, err)
check("composite key with no writer is counted unknown",
  protocol.gmcp_stats().unknown.MONUMENTS == 1,
  protocol.gmcp_stats().unknown.MONUMENTS)

-- ---- Guild.State's vitals all resolve to one writer -----------------------
-- Kills: routing a vitals group anywhere but VITALS -- to its own writer, or
-- to a second one. The whole block has to reach ONE writer: they share the
-- S.vitals_gmcp latch and the "absent means unchanged" handling, and a delta
-- frame can carry any subset of them.
for _, k in ipairs({ "hp", "sp", "points", "chain", "gxp", "tox", "fx",
                     "encounter", "target", "ledung", "bars" }) do
  check("Guild.State " .. k .. " routes to VITALS", gmcp_map.mip_key(k) == "VITALS",
    tostring(gmcp_map.mip_key(k)))
end

-- Char.Combat keeps the attacker fields. It carries the enemy hp percent that
-- Guild.State's target group omits, so it stays the source for those three --
-- and the two writers must not land on a shared field. `target`/`encounter`
-- write en5/ens/rndz/combat; Char.Combat writes mob_name_full/estatus_pct/
-- combat_rounds. Disjoint, and this is the check that keeps them so.
do
  local combat = require("combat")
  local S2 = require("state").S
  S2.mob_name_full, S2.estatus_pct, S2.combat_rounds = "SENTINEL", 4242, 4242
  frame("Guild.State", { guild = "viking",
                         target = { name = "Ice Troll", name5 = "Ice T",
                                    hp_status = "low" },
                         encounter = { active = 1, rounds = 3 } })
  check("a Guild.State frame does not touch Char.Combat's attacker fields",
    S2.mob_name_full == "SENTINEL" and S2.estatus_pct == 4242
      and S2.combat_rounds == 4242,
    S2.mob_name_full .. "/" .. S2.estatus_pct .. "/" .. S2.combat_rounds)

  S2.en5, S2.ens, S2.rndz = "SENTINEL", "SENTINEL", 4242
  combat.on_gmcp_combat({ attacker = "Ice Troll", attacker_hp = 40, rounds = 9 })
  check("a Char.Combat frame does not touch the vitals writer's target fields",
    S2.en5 == "SENTINEL" and S2.ens == "SENTINEL" and S2.rndz == 4242,
    S2.en5 .. "/" .. S2.ens .. "/" .. S2.rndz)
end

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
