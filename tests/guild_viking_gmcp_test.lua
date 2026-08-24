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

-- ---- key routing -----------------------------------------------------------
-- Kills: routing the raw lowercase key, which matches no handler, or failing to
-- strip the envelope so `guild` is treated as data.
reset()
frame("Guild.Settlement", { guild = "Vikings", settlers = { a = 1 } })
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
frame("Guild.Settlement", { guild = "Vikings", nosuchkey = { a = 1 } })
check("unhandled key counted", protocol.gmcp_stats().unknown.NOSUCHKEY == 1,
  protocol.gmcp_stats().unknown.NOSUCHKEY)

-- Kills: not marking the screen dirty, so a pane fed only by GMCP never
-- repaints until unrelated output arrives.
reset()
local before = dirty_count
frame("Guild.Settlement", { guild = "Vikings", settlers = { a = 1 } })
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
frame("Guild.State", { guild = "Vikings", hp = { cur = 5, max = 10 } })
check("Guild.State hp not applied", protocol.gmcp_stats().applied.HP == nil)
check("Guild.State hp counted unknown", protocol.gmcp_stats().unknown.HP == 1,
  protocol.gmcp_stats().unknown.HP)

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
