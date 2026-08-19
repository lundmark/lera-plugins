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
mip = { on = function() return 1 end, off = function() end, enabled = function() return true end }
gmcp = { on = function() return 1 end, remove = function() end, enabled = function() return false end }
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

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING TESTS PASSED")
