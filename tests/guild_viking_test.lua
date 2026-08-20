-- guild_viking unit tests. Run from the lera-plugins repo root with LERA_ROOT
-- pointing at a built Lera checkout.
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

-- ---- lera API stubs (extended by later tasks' cases) -----------------------
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
-- mip/gmcp stubs capture registrations and can fire them with the real wire
-- shapes, so wiring bugs (e.g. binding the wrong callback argument) show up
-- as test failures instead of only at runtime.
local mip_handlers, mip_handler_count = {}, 0
mip = {
  on = function(code, cb)
    mip_handlers[code] = cb
    mip_handler_count = mip_handler_count + 1
    return mip_handler_count
  end,
  off = function() end,
  enabled = function() return true end,
  -- real shape: callback(key, code, data) -- key is the 5-digit packet
  -- sequence number, data is the payload string.
  fire = function(code, data) mip_handlers[code](12345, code, data) end,
}
local gmcp_handlers, gmcp_handler_count = {}, 0
gmcp = {
  on = function(pkg, cb)
    gmcp_handlers[pkg] = cb
    gmcp_handler_count = gmcp_handler_count + 1
    return gmcp_handler_count
  end,
  remove = function() end,
  enabled = function() return false end,
  -- real shape: callback(package, data)
  fire = function(pkg, data) gmcp_handlers[pkg](pkg, data) end,
}
trigger = { add = function() return 1 end, remove = function() end }
timer = { every = function() return 1 end, remove = function() end }
alias = { add = function() return 1 end, remove = function() end }
plugin = { get = function() return nil end }
local real_require = require
require = function(name)
  if name == "command" then
    return { register = function() return 1 end, unregister = function() return true end,
             get = function() return nil end, list = function() return {} end }
  end
  return real_require(name)
end

-- ---- util.split parity with Portal's string.split --------------------------
local util = require("util")
local parts = util.split("a~b~~c", "~")
check("split basic", #parts == 4 and parts[1] == "a" and parts[3] == "" and parts[4] == "c",
      table.concat(parts, ","))
check("split single", #util.split("solo", "~") == 1)
check("split empty tail", (function()
  local p = util.split("x|", "|")
  return #p == 2 and p[2] == ""
end)())

-- ---- state defaults ---------------------------------------------------------
local state_mod = require("state")
local S = state_mod.S
check("state hp default", S.hp == 0 or S.hp ~= nil)
check("state carts table", type(S.carts) == "table" and #S.carts == 0)
check("state price_history table", type(S.price_history) == "table")
check("state blot_total", S.blot_total == 9)
check("state daler sentinel", S.daler == -1)
check("state en5 default", S.en5 == "None")

-- reset_connection clears per-connection combat state but keeps persisted-style fields
S.combat = true
S.en5 = "orc"
state_mod.reset_connection()
check("reset clears combat", S.combat == false and S.en5 == "None")

-- ---- plugin table loads -----------------------------------------------------
local M = dofile("3scapes/guild_viking/init.lua")
check("plugin name", M.name == "guild_viking")
check("plugin state accessor", M.state() == S)
check("hooks exist", type(M.on_load) == "function" and type(M.on_unload) == "function"
      and type(M.on_connect) == "function" and type(M.on_disconnect) == "function")

-- ---- protocol: dispatch, batching, latch ------------------------------------
local protocol = require("protocol")

local seen = {}
protocol.handler("TESTKEY", function(v) seen[#seen + 1] = v end)
check("duplicate handler rejected", not pcall(protocol.handler, "TESTKEY", function() end))

local before_dirty = dirty_count
protocol.ingest("TESTKEY", "abc")
check("ingest dispatches", seen[1] == "abc")
check("ingest marks dirty", dirty_count > before_dirty)

protocol.ingest("NOSUCH", "x")
check("unknown counted", protocol.stats().unknown.NOSUCH == 1)

-- pattern tier: registration, dispatch (fn receives key AND value), and
-- duplicate-pattern rejection. Exact-vs-pattern precedence and the row-key
-- LEGACY cases live in guild_viking_voyage_test.lua alongside the handlers
-- that actually use this tier.
local pattern_seen = {}
protocol.pattern_handler("^PATKEY%d%d$", function(k, v) pattern_seen[#pattern_seen + 1] = k .. ":" .. v end)
check("duplicate pattern rejected", not pcall(protocol.pattern_handler, "^PATKEY%d%d$", function() end))
protocol.ingest("PATKEY07", "seven")
check("pattern dispatches with key and value", pattern_seen[1] == "PATKEY07:seven")

-- erroring parser: counted, does not break later ingest
protocol.handler("BOOMKEY", function() error("boom") end)
protocol.ingest("BOOMKEY", "x")
protocol.ingest("TESTKEY", "after")
check("parser error counted", protocol.stats().errors.BOOMKEY == 1)
check("dispatch survives parser error", seen[#seen] == "after")

-- BBE adapter: plain pairs
seen = {}
protocol.on_bbe("TESTKEY^^one^^TESTKEY^^two^^")
check("bbe splits pairs", #seen == 2 and seen[1] == "one" and seen[2] == "two")

-- KEY_NofTOTAL: instant reassembly on completion, in numeric order
seen = {}
protocol.on_bbe("TESTKEY_2of2^^beta^^")
check("incomplete batch held", #seen == 0 and protocol.stats().batches_pending == 1)
protocol.on_bbe("TESTKEY_1of2^^alpha^^")
check("batch reassembled in order", #seen == 1 and seen[1] == "alphabeta")
check("batch cleared", protocol.stats().batches_pending == 0)

-- legacy KEY_N (no total): only the sweep dispatches it
seen = {}
protocol.on_bbe("TESTKEY_1^^a^^TESTKEY_2^^b^^")
check("numbered-without-total held", #seen == 0)
protocol.sweep(1000)   -- first sight: records timestamp, dispatches complete run
check("sweep dispatches contiguous run", #seen == 1 and seen[1] == "ab")

-- stale partial: dropped after 2s
seen = {}
protocol.on_bbe("TESTKEY_2of3^^x^^")
protocol.sweep(1000)
check("partial survives young sweep", protocol.stats().batches_pending == 1)
protocol.sweep(1003)
check("stale partial dropped", protocol.stats().batches_pending == 0 and #seen == 0)

-- source latch: auto starts on mip; gmcp latches on first real message
check("source default auto", protocol.source() == "auto")
seen = {}
protocol.on_gmcp("Viking", "TESTKEY^^viagmcp^^")
check("gmcp latches and ingests", seen[1] == "viagmcp" and protocol.stats().latched)
protocol.on_bbe("TESTKEY^^viamip^^")
check("mip suppressed after latch", #seen == 1 and protocol.stats().suppressed >= 1)
protocol.source("mip")
protocol.on_bbe("TESTKEY^^mipforced^^")
check("forced mip overrides latch", seen[#seen] == "mipforced")
protocol.source("auto")

-- LEGACY quirk, ported faithfully (guild_viking.lua:2932-2942, "dispatch
-- whatever we have after the grace period, as before"): a lone non-contiguous
-- no-total part dispatches unconditionally on the first sweep, joined from
-- whatever parts exist -- there is no contiguity gate here. Do not "fix"
-- this into a contiguous-from-1 check; the tests below encode the intended,
-- LEGACY-matching behavior.
seen = {}
protocol.on_bbe("TESTKEY_2^^orphan^^")   -- part 1 never arrives
protocol.sweep(1000)
check("non-contiguous no-total part still dispatches", #seen == 1 and seen[1] == "orphan")

-- ---- init.lua wiring: mip "BBE" and gmcp "Viking" reach protocol correctly --
-- M.on_load() registers the real mip/gmcp/timer callbacks used at runtime.
-- It must only run once in this suite -- later /vik command tests (task 10)
-- rely on it having already run and must not call it again.
M.on_load()

seen = {}
mip.fire("BBE", "TESTKEY^^wired^^")
check("mip BBE wiring feeds the payload, not the packet sequence number",
      seen[#seen] == "wired")

seen = {}
gmcp.fire("Viking", "TESTKEY^^gmcpwired^^")
check("gmcp Viking wiring feeds protocol.on_gmcp", seen[#seen] == "gmcpwired")

-- Restore a clean, unlatched source state for later test files.
protocol.source("mip")
protocol.source("auto")

-- ---- notify: push triggers + countdown_tick (Task 9) -----------------------
local notify = require("notify")

check("notify has 15 trigger entries", #notify.triggers == 15, #notify.triggers)

local function find_trigger(name)
  for _, t in ipairs(notify.triggers) do
    if t.name == name then return t end
  end
  error("no trigger named " .. name)
end

-- nil-pushn safety: every trigger fn must no-op without error before
-- set_push is ever called.
for _, t in ipairs(notify.triggers) do
  local ok = pcall(t.fn, "some matching line", "cap")
  check("nil-pushn safe: " .. t.name, ok)
end

local push_records = {}
local pushn_stub = {
  notify = function(channel, message)
    push_records[#push_records + 1] = { channel = channel, message = message }
  end,
}
notify.set_push(pushn_stub)

local function assert_trigger(name, line, capture, want_message)
  push_records = {}
  local t = find_trigger(name)
  t.fn(line, capture)
  local rec = push_records[1]
  check(name .. " channel", rec and rec.channel == "viking", rec and rec.channel)
  check(name .. " message", rec and rec.message == want_message, rec and rec.message)
end

assert_trigger("push_cart_return", "Cart returned from Aldby.", nil,
  "Cart returned from trade route.")
assert_trigger("push_longship_return", "The longship returned from the island.", nil,
  "Longship returned from island with thralls.")
assert_trigger("push_longship_saved", "The Northwind was saved from the deep by the Iron Hull perk.", nil,
  "Longship saved by Iron Hull perk.")
assert_trigger("push_longship_tattoo", "The Northwind returned with a foreign tattoo pattern.", nil,
  "Longship returned with tattoo pattern.")
assert_trigger("push_longship_thralls", "The Northwind returned with 3 thralls.", nil,
  "Longship returned with thralls.")
assert_trigger("push_voyage_node", "A hidden harbor rises off the port bow.", "hidden harbor",
  "Voyage: hidden harbor reached - resolve needed.")
assert_trigger("push_voyage_pause", "[Viking-Voyage] Spoiled casks are found below deck.",
  "Spoiled casks are found below deck.",
  "Voyage: Spoiled casks are found below deck.")
assert_trigger("push_raid_return", "Your raiders returned from Wessex with plunder.", nil,
  "Raid returned with spoils.")
assert_trigger("push_town_captured", "Eastgate falls! The town is taken.", "Eastgate",
  "War: Eastgate has fallen to your rule!")
assert_trigger("push_war_declared", "Ivar declares war and gathers a host.", "Ivar",
  "War: Ivar marches on your realm -- answer or sue for peace.")
assert_trigger("push_realm_sacked", "A raiding party sacks your holdings.", nil,
  "War: your holdings were sacked -- you left an incoming war unanswered.")
assert_trigger("push_battle_lost", "[War] Defeat. Your host was routed.", nil,
  "Battle: your host was defeated.")
assert_trigger("push_recruit_found", "A wanderer is looking for a hall to serve.", nil,
  "Kaupstefna: a specialist wanderer is available to hire (vfind).")
assert_trigger("push_recruit_found_2", "A wanderer came seeking a hall.", nil,
  "Kaupstefna: a specialist wanderer is available to hire (vfind).")
assert_trigger("push_relic_found", "A relic is hauled aboard.", nil,
  "Voyage: a rare relic was recovered!")

-- push_voyage_pause fallback when no capture arrives (mirrors LEGACY's
-- `wildcards[1] or "Voyage paused"`).
push_records = {}
find_trigger("push_voyage_pause").fn("[Viking-Voyage]")
check("voyage_pause fallback message",
      push_records[1] and push_records[1].message == "Voyage: Voyage paused")

-- ---- countdown_tick ---------------------------------------------------------

-- Carts: decrement while > 1; drop entries that would land at/under 1
-- (a cart never visibly shows "1").
S.carts = { { return_in = 5, halfway_in = 3 }, { return_in = 2 }, { return_in = 1 } }
local cd_before = dirty_count
notify.countdown_tick()
check("cart decremented", S.carts[1] and S.carts[1].return_in == 4 and S.carts[1].halfway_in == 2)
check("carts at/under 1 removed this tick", #S.carts == 1)
check("countdown fires exactly one dirty for the whole tick", dirty_count == cd_before + 1)

-- Courier runs: same family as carts.
S.courier.runs = { { return_in = 3 }, { return_in = 1 } }
notify.countdown_tick()
check("courier run decremented", S.courier.runs[1].return_in == 2)
check("courier run at 1 removed", #S.courier.runs == 1)

-- Spy: secs clamps to 0 at the boundary tick; sab_secs floors at 0 and
-- clears sab_pct when it does; cd_secs floors at 0; scouts decrement/prune
-- like carts.
S.spy = { tier = 1, mode = "raid", village = "x", secs = 1, sab_pct = 40, sab_secs = 1, cd_secs = 3,
          scouts = { { secs = 3 }, { secs = 1 } } }
notify.countdown_tick()
check("spy secs clamps to 0", S.spy.secs == 0)
check("spy sab_secs floors and clears pct", S.spy.sab_secs == 0 and S.spy.sab_pct == 0)
check("spy cd_secs decremented", S.spy.cd_secs == 2)
check("spy scout decremented and pruned", #S.spy.scouts == 1 and S.spy.scouts[1].secs == 2)

-- Training: decrements while > 1; never reaches 0 via the tick.
S.train = { tier = 1, name = "Axework", stat = "str", trained = 0, secs = 1 }
notify.countdown_tick()
check("train stuck at 1", S.train.secs == 1)
S.train.secs = 3
notify.countdown_tick()
check("train decremented", S.train.secs == 2)

-- Cart/ship upgrades and settler projects: floor at 0, no removal ever.
S.cart_upgrades = { { cart_id = 1, secs_left = 2 } }
S.ship_upgrades = { { name = "hull", secs_left = 1 } }
S.settler_projects = { { id = 1, secs_left = 1 } }
notify.countdown_tick()
check("cart upgrade decremented", S.cart_upgrades[1].secs_left == 1)
check("ship upgrade floors at 0, kept", S.ship_upgrades[1].secs_left == 0 and #S.ship_upgrades == 1)
check("settler project floors at 0, kept",
      S.settler_projects[1].secs_left == 0 and #S.settler_projects == 1)

-- Incoming fills: same family as carts.
S.incoming_fills = { { good = "wool", arrives_in = 2 } }
notify.countdown_tick()
check("incoming fill at/under 1 removed this tick", #S.incoming_fills == 0)

-- next_tick_in / demand_cycle_in: floor at 0.
S.next_tick_in = 1
S.demand_cycle_in = 1
notify.countdown_tick()
check("next_tick_in floors at 0", S.next_tick_in == 0)
check("demand_cycle_in floors at 0", S.demand_cycle_in == 0)

-- God power: recomputed from an absolute target while one is set, else a
-- plain per-second decrement floored at 0.
S.god_power_next_at = os.time() + 50
S.god_power_next = 999
notify.countdown_tick()
local gp_expected = S.god_power_next_at - os.time()
check("god power recomputed from target", S.god_power_next == gp_expected)
S.god_power_next_at = 0
S.god_power_next = 3
notify.countdown_tick()
check("god power plain decrement", S.god_power_next == 2)

-- Dispatch cooldown (Cartwright's Cadence): absolute-time recompute.
S.dispatch_cd_expires_at = os.time() + 40
S.dispatch_cd = 999
notify.countdown_tick()
local cd_expected = S.dispatch_cd_expires_at - os.time()
check("dispatch cooldown recomputed from target", S.dispatch_cd == cd_expected)

-- Ships / voyage longships: floor at 0, docked (0) entries kept.
S.ships = { { name = "Northwind", return_in = 1 } }
S.voyage_longships = { { name = "Southwind", return_in = 1 } }
notify.countdown_tick()
check("ship floors at 0, kept", S.ships[1].return_in == 0 and #S.ships == 1)
check("voyage longship floors at 0, kept",
      S.voyage_longships[1].return_in == 0 and #S.voyage_longships == 1)

-- Voyage status next_move (Sea tab countdown).
S.voyage_status = { next_move = 2 }
notify.countdown_tick()
check("voyage next_move decremented", S.voyage_status.next_move == 1)

-- Pending builds: decrement while > 0; drop only at exactly 0; keep nil and
-- negative (the -1 "awaiting mats" sentinel) untouched.
S.pending_builds = { { bldg_id = 1, complete_at_secs = 1 }, { bldg_id = 2, complete_at_secs = -1 },
                     { bldg_id = 3, complete_at_secs = nil } }
notify.countdown_tick()
check("pending build at 1 removed this tick", #S.pending_builds == 2)
check("pending build sentinel/nil kept",
      S.pending_builds[1].complete_at_secs == -1 and S.pending_builds[2].complete_at_secs == nil)

-- Route builds: decrement while > 0, removed the instant it reaches <= 0;
-- an entry already at 0 is left untouched (decrement and removal share the
-- same > 0 gate).
S.route_builds = { ["road:1"] = { vid = 1, complete_at_secs = 1 },
                   ["fort:2"] = { vid = 2, complete_at_secs = 0 } }
notify.countdown_tick()
check("route build at 1 removed", S.route_builds["road:1"] == nil)
check("route build already at 0 left alone",
      S.route_builds["fort:2"] ~= nil and S.route_builds["fort:2"].complete_at_secs == 0)

-- Idle tick: nothing counting down anywhere -> no dirty call, tick stays cheap.
S.carts, S.courier.runs, S.incoming_fills, S.pending_builds = {}, {}, {}, {}
S.route_builds, S.cart_upgrades, S.ship_upgrades, S.settler_projects = {}, {}, {}, {}
S.ships, S.voyage_longships = {}, {}
S.spy = { tier = 0, mode = "", village = "", secs = 0, sab_pct = 0, sab_secs = 0, cd_secs = 0, scouts = {} }
S.train = { tier = 0, name = "", stat = "", trained = 0, secs = 0 }
S.next_tick_in, S.demand_cycle_in = 0, 0
S.god_power_next, S.god_power_next_at = 0, 0
S.dispatch_cd, S.dispatch_cd_expires_at = 0, nil
S.voyage_status = nil
cd_before = dirty_count
notify.countdown_tick()
check("idle tick does not mark dirty", dirty_count == cd_before)

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING TESTS PASSED")
