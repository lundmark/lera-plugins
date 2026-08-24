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
check("unhandled key counted", protocol.gmcp_stats().unknown.NOSUCHKEY == 1,
  protocol.gmcp_stats().unknown.NOSUCHKEY)

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

-- ---- Guild.Info / Guild.State are counted, never consumed ------------------
-- Kills: consuming Guild.State's hp. combat.on_composite owns S.hp off the MIP
-- FFF channel; two transports writing the vitals through different code paths
-- is the regression this pins.
reset()
frame("Guild.State", { guild = "viking", hp = { cur = 5, max = 10 } })
check("Guild.State hp not applied", protocol.gmcp_stats().applied.HP == nil)
check("Guild.State hp counted unknown", protocol.gmcp_stats().unknown.HP == 1,
  protocol.gmcp_stats().unknown.HP)

-- ---- a raising gmcp writer is countable and does not block its siblings --
-- Kills: routing a writer error into the MIP-scoped stats/print path instead
-- of gmcp_stats (an observability hole: /vik source reads gmcp_stats(), which
-- would then never show a GMCP write failure). Kills: one raising writer
-- aborting the whole frame instead of just that key -- BOOMKEY and SETTLERS
-- are unrelated keys in the same frame.
protocol.gmcp_handler("BOOMKEY", function() error("boom") end)
reset()
frame("Guild.Settlement", { guild = "viking", boomkey = "x", settlers = { a = 2 } })
check("raising gmcp writer counted in gmcp_stats().errors",
  protocol.gmcp_stats().errors.BOOMKEY == 1, protocol.gmcp_stats().errors.BOOMKEY)
check("raising gmcp writer not counted as applied",
  protocol.gmcp_stats().applied.BOOMKEY == nil)
check("sibling key in the same frame still applied",
  got.SETTLERS ~= nil and got.SETTLERS.a == 2)

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
protocol.gmcp_handler("SIBLING", recorder("SIBLING"))
reset()
local malformed_before = protocol.gmcp_stats().malformed or 0
frame("Guild.Settlement", { guild = "viking", page = 1, pages = 2,
                            settlers = { "a" } })
frame("Guild.Settlement", { guild = "viking", page = 2, pages = 2,
                            settlers = { x = 1 }, sibling = "ok" })
check("type-mismatched repeat is last-value-wins, not concatenated",
  got.SETTLERS ~= nil and got.SETTLERS.x == 1 and got.SETTLERS[1] == nil,
  got.SETTLERS)
check("type mismatch counted malformed exactly once",
  (protocol.gmcp_stats().malformed or 0) == malformed_before + 1,
  protocol.gmcp_stats().malformed)
check("sibling key in the same run still applied",
  got.SIBLING == "ok", got.SIBLING)

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
