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
lera = { time = function() return 1000 end, version = function() return "test" end,
         render_pass = function() return "local" end }
-- Captures each color_print call's text segments (positions 3, 6, 9, ... of
-- its bg/fg/text triplets), joined, as one entry -- lets later cases (the
-- Task 2 "/vik opts" dispatch) assert on printed content instead of just
-- that a call happened without erroring.
local printed = {}
buffer = {
  color_print = function(...)
    local args = { ... }
    local parts = {}
    for i = 3, #args, 3 do
      parts[#parts + 1] = tostring(args[i])
    end
    printed[#printed + 1] = table.concat(parts)
  end,
}
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
-- Fix 1 regression: capture every timer.every registration (interval, fn) so
-- the sweep timer's callback can be fired directly with realistic
-- millisecond-scale lera.time() values, the same way mip/gmcp stubs above
-- capture their callbacks for wiring tests.
local timer_regs = {}
timer = {
  every = function(interval, fn)
    timer_regs[#timer_regs + 1] = { interval = interval, fn = fn }
    return #timer_regs
  end,
  remove = function() end,
}
-- Task 10: capture the ^resetvikxp$ registration so later cases can fire it
-- directly, the same way mip/gmcp stubs above capture their callbacks.
local registered_resetvikxp = nil
alias = {
  add = function(pattern, fn)
    registered_resetvikxp = { pattern = pattern, fn = fn }
    return 1
  end,
  remove = function() end,
}
plugin = { get = function() return nil end }
local real_require = require
-- Task 10: capture the spec passed to command.register so later cases can
-- dispatch through the registered /vik handler directly.
local registered_vik = nil
require = function(name)
  if name == "command" then
    return { register = function(spec) registered_vik = spec; return 1 end,
             unregister = function() return true end,
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
check("state hp default", S.hp == 0)
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

-- Fix 3: an empty or garbage GMCP message (no ^^-delimited pairs) must NOT
-- latch -- only a real message should flip auto mode over to gmcp, so mip
-- keeps flowing until genuine Viking GMCP traffic actually arrives.
check("not latched before any gmcp message", protocol.stats().latched == false)
protocol.on_gmcp("Viking", "")
check("empty gmcp message does not latch", protocol.stats().latched == false)
protocol.on_gmcp("Viking", "no delimiters here")
check("delimiter-less gmcp message does not latch", protocol.stats().latched == false)
seen = {}
protocol.on_bbe("TESTKEY^^stillmip^^")
check("mip still flows after empty/garbage gmcp messages", seen[1] == "stillmip")

seen = {}
protocol.on_gmcp("Viking", "TESTKEY^^viagmcp^^")
check("gmcp latches and ingests", seen[1] == "viagmcp" and protocol.stats().latched)
protocol.on_bbe("TESTKEY^^viamip^^")
check("mip suppressed after latch", #seen == 1 and protocol.stats().suppressed >= 1)
protocol.source("mip")
protocol.on_bbe("TESTKEY^^mipforced^^")
check("forced mip overrides latch", seen[#seen] == "mipforced")
protocol.source("auto")

-- Forced gmcp direction: source("gmcp") suppresses BBE unconditionally, with
-- no latch involved at all (the forced-mode branch in active_source() never
-- consults gmcp_latched).
protocol.source("gmcp")
local latched_before_forced = protocol.stats().latched
seen = {}
local suppressed_before_forced = protocol.stats().suppressed
protocol.on_bbe("TESTKEY^^shouldnotarrive^^")
check("forced gmcp suppresses bbe", #seen == 0
      and protocol.stats().suppressed == suppressed_before_forced + 1)
check("forced gmcp direction does not touch the latch",
      protocol.stats().latched == latched_before_forced)
-- Restore a clean, unlatched source state for the tests below: source("mip")
-- clears gmcp_latched explicitly, then source("auto") returns to auto mode
-- without re-touching it (mirrors the existing reset further down this file).
protocol.source("mip")
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

-- Fix 1 regression: init.lua's sweep timer must divide lera.time()'s
-- milliseconds down to seconds before calling protocol.sweep, so a known-total
-- batch gets the full ~2s grace period LEGACY intends, not ~2ms. Drive the
-- captured sweep callback directly (it takes no arguments -- it reads
-- lera.time() itself, exactly as init.lua wires it), controlling the
-- millisecond-scale wall clock it sees via the lera.time stub.
local sweep_reg
for _, r in ipairs(timer_regs) do
  if r.interval == 100 then sweep_reg = r end
end
check("sweep timer registered at 100ms", sweep_reg ~= nil)

local real_lera_time = lera.time
protocol.source("mip")   -- force mip: an earlier gmcp wiring test may have re-latched gmcp
seen = {}
lera.time = function() return 100000 end          -- simulated wall clock: 100.000s
protocol.on_bbe("TESTKEY_2of3^^x^^")               -- incomplete known-total batch arrives
sweep_reg.fn()
check("fresh known-total batch survives first sweep", protocol.stats().batches_pending == 1)
lera.time = function() return 100100 end          -- +100ms of real time
sweep_reg.fn()
check("known-total batch NOT dropped after 100ms of real time",
      protocol.stats().batches_pending == 1 and #seen == 0)
lera.time = function() return 103000 end          -- +3s of real time
sweep_reg.fn()
check("known-total batch dropped after >2s of real time",
      protocol.stats().batches_pending == 0 and #seen == 0)
lera.time = real_lera_time
protocol.source("auto")

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
-- `wildcards[1] or "Voyage paused"`). Defensive/unreachable in practice: the
-- trigger pattern's capture group is `(.*)`, which always participates in a
-- real match (at worst as an empty string, which is truthy in Lua), so the
-- real trigger engine can never hand this fn a nil c1. Calling fn() directly
-- with no second argument, as below, is the only way to exercise this branch.
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

-- ---- persist: price_history + source survive save/load (Task 10) -----------
local persist = require("persist")
-- Task 2: page_opts.lua and window.lua, required here for the persistence
-- round-trip extension below (page_opts + current page).
local page_opts = require("page_opts")
local window = require("window")

S.price_history = { [1] = { fish = { { t = 100, b = 2, s = 3 } } } }
protocol.source("gmcp")
-- Task 2 extension: flip a page option and switch pages before saving, so
-- the round-trip below also covers persist's new page_opts/page fields
-- (mirrors LEGACY's SetVariable("popt_"..k) + SetVariable("page", ...)).
page_opts.set("show_stats_buffs", false)
window.set_page("goods")
persist.save()
S.price_history = {}
protocol.source("auto")
page_opts.set("show_stats_buffs", true)   -- flip back so load is what restores it
window.set_page("stats")
persist.load()
check("history restored", S.price_history[1] and S.price_history[1].fish[1].b == 2)
check("source restored", protocol.source() == "gmcp")
check("page_opts restored", page_opts.get("show_stats_buffs") == false)
check("page restored", window.current_page() == "goods")
protocol.source("mip")
protocol.source("auto")
page_opts.set("show_stats_buffs", true)
window.set_page("stats")

-- ---- /vik registration + dispatch (Task 10) ---------------------------------
-- M.on_load() ran once already (above); it registered the real /vik command
-- and resetvikxp alias, captured by the stubs upgraded at the top of this file.
check("vik registered", registered_vik ~= nil and registered_vik.name == "/vik")
check("vik accepts args", registered_vik.accepts_args == true)

local ok_status = pcall(registered_vik.handler, "status", "/vik")
check("vik status dispatches without error", ok_status)

registered_vik.handler("source gmcp", "/vik")
check("source set via command", protocol.source() == "gmcp")
registered_vik.handler("source auto", "/vik")
check("source reset via command", protocol.source() == "auto")

local ok_badsource = pcall(registered_vik.handler, "source bogus", "/vik")
check("vik source with bad mode does not error", ok_badsource and protocol.source() == "auto")

local ok_empty = pcall(registered_vik.handler, "", "/vik")
check("vik empty args falls back to usage without error", ok_empty)

local ok_unknown = pcall(registered_vik.handler, "bogus", "/vik")
check("vik unknown subcommand falls back to usage without error", ok_unknown)

-- ---- /vik: stage-2 page switching + page options (Task 2) ------------------
window.set_page("city")   -- somewhere other than stats, so the dispatch below
                          -- proves it actually switches rather than no-op'ing
registered_vik.handler("stats", "/vik")
check("/vik stats switches page", window.current_page() == "stats")

check("page_opts.set rejects an unknown key directly", page_opts.set("no_such_opt", true) == false)

check("show_stats_xp defaults to true", page_opts.get("show_stats_xp") == true)
registered_vik.handler("set show_stats_xp off", "/vik")
check("/vik set show_stats_xp off flips it", page_opts.get("show_stats_xp") == false)

printed = {}
registered_vik.handler("opts", "/vik")
local opts_text = table.concat(printed, "\n")
check("/vik opts output contains the flipped option",
      opts_text:find("show_stats_xp = off", 1, true) ~= nil, opts_text)

local before_unknown_opt = page_opts.get("show_stats_xp")
local ok_set_unknown = pcall(registered_vik.handler, "set no_such_opt on", "/vik")
check("/vik set with an unknown opt does not error", ok_set_unknown)
check("unknown opt refused, nothing else disturbed",
      page_opts.get("show_stats_xp") == before_unknown_opt)

registered_vik.handler("set show_stats_xp on", "/vik")   -- restore for later tests

-- ---- /vik resetxp: session counters reset (XML alias body, lines 175-186) --
S.vis_session, S.kap_session, S.soe_session, S.aud_session = 10, 20, 30, 40
S.xp_session_start = 12345
registered_vik.handler("resetxp", "/vik")
check("resetxp clears sessions", S.vis_session == 0 and S.kap_session == 0
      and S.soe_session == 0 and S.aud_session == 0)
check("resetxp clears session start", S.xp_session_start == nil)

-- ---- resetvikxp alias: same reset path --------------------------------------
check("resetvikxp alias registered", registered_resetvikxp ~= nil
      and registered_resetvikxp.pattern == "^resetvikxp$")
S.vis_session = 99
registered_resetvikxp.fn()
check("resetvikxp alias resets sessions", S.vis_session == 0)

-- ---- /vik trace: toggles protocol.trace, off by default, silent otherwise --
check("trace off by default", protocol.trace() == false)
registered_vik.handler("trace on", "/vik")
check("trace on via /vik", protocol.trace() == true)
local ok_trace_ingest = pcall(protocol.ingest, "TESTKEY", "traced")
check("ingest with trace on does not error", ok_trace_ingest)
registered_vik.handler("trace off", "/vik")
check("trace off via /vik", protocol.trace() == false)

-- ---- /vik save: delegates to persist.save -----------------------------------
S.price_history[2] = { wool = { { t = 200, b = 5, s = 6 } } }
local ok_save = pcall(registered_vik.handler, "save", "/vik")
check("vik save dispatches without error", ok_save)

-- ---- stats_window contract: has_data / render_guild_stats -------------------
check("has_data is a function", type(M.has_data) == "function")
check("render_guild_stats is a function", type(M.render_guild_stats) == "function")
check("has_data true after ingestion", M.has_data() == true)

ui.rect = function(x, y, w, h) return { x = x, y = y, w = w, h = h } end
ui.text = function() end

S.vis, S.vis_session, S.kap, S.kap_session = 100, 5, 200, 10
S.soe, S.soe_session, S.aud, S.aud_session = 300, 15, 400, 20
S.ldng, S.mldng = 3, 4

local used_clipped = M.render_guild_stats({ x = 0, y = 0, w = 40, h = 2 }, {})
check("render_guild_stats clips to rect height", used_clipped == 2, used_clipped)

local used_full = M.render_guild_stats({ x = 0, y = 0, w = 40, h = 10 }, {})
check("render_guild_stats returns lines used", used_full == 3, used_full)

check("render_guild_stats zero height returns 0",
      M.render_guild_stats({ x = 0, y = 0, w = 40, h = 0 }, {}) == 0)

-- ---- on_unload: full cleanup, must not error (Task 10; call LAST) ----------
local ok_unload = pcall(M.on_unload)
check("on_unload does not error", ok_unload)

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING TESTS PASSED")
