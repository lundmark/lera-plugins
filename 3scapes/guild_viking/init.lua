-- Guild Viking plugin: stage 1 foundation (protocol, state, notifications,
-- persistence, /vik). Window pages arrive in stage 2 and read this state.
local state_mod = require("state")
local protocol = require("protocol")

local trade = require("handlers.trade")
for key, fn in pairs(trade) do
  if key ~= "_market_seam" then protocol.handler(key, fn) end
end

-- Task 7: price history / demand metrics. LEGACY's MARKET branch never
-- calls record_price_history (only TGOODS does -- see market.lua's header
-- comment), so on_market is intentionally left unset.
local market = require("market")
trade._market_seam.on_tgoods = market.on_tgoods

local voyage = require("handlers.voyage")
for key, fn in pairs(voyage) do
  if key ~= "_patterns" then protocol.handler(key, fn) end
end
for _, p in ipairs(voyage._patterns or {}) do
  protocol.pattern_handler(p.pattern, p.fn)
end

local kingdom = require("handlers.kingdom")
for key, fn in pairs(kingdom) do
  if key ~= "_patterns" then protocol.handler(key, fn) end
end
for _, p in ipairs(kingdom._patterns or {}) do
  protocol.pattern_handler(p.pattern, p.fn)
end

local city = require("handlers.city")
for key, fn in pairs(city) do
  if key ~= "_patterns" then protocol.handler(key, fn) end
end
for _, p in ipairs(city._patterns or {}) do
  protocol.pattern_handler(p.pattern, p.fn)
end

-- Task 8: combat composite + hp-bar triggers. FFF is a separate MIP composite
-- from BBE (not routed through protocol.lua's key/value dispatch), so it gets
-- its own mip.on registration. The callback is 3-arg (key, code, data); data
-- is the third argument, not the second -- binding the wrong one was a past
-- Critical here.
local combat = require("combat")

-- Task 9: push notifications + the per-second countdown timer. `pushn` is
-- looked up in on_setup (plugins load before on_setup runs, per CLAUDE.md's
-- Push API producer pattern) and handed to notify.set_push; it stays nil,
-- and every trigger fn is a safe no-op, if push_notify isn't loaded.
local notify = require("notify")

local M = {}
M.name = "guild_viking"
M.version = "0.1"

function M.state()
  return state_mod.S
end

local mip_id, fff_id, gmcp_id, sweep_id, countdown_id
local combat_trigger_ids = {}
local notify_trigger_ids = {}

function M.on_load()
  mip_id = mip.on("BBE", function(key, code, data) protocol.on_bbe(data) end)
  fff_id = mip.on("FFF", function(key, code, data) combat.on_composite(data) end)
  gmcp_id = gmcp.on("Viking", function(pkg, data) protocol.on_gmcp(pkg, data) end)
  sweep_id = timer.every(100, function() protocol.sweep(lera.time()) end)
  for _, t in ipairs(combat.triggers) do
    combat_trigger_ids[#combat_trigger_ids + 1] = trigger.add(t.pattern, t.fn)
  end
  for _, t in ipairs(notify.triggers) do
    notify_trigger_ids[#notify_trigger_ids + 1] = trigger.add(t.pattern, t.fn)
  end
  countdown_id = timer.every(1000, function() notify.countdown_tick() end)
end

function M.on_setup()
  local pushn = plugin.get("push_notify")
  if pushn then
    pushn.register_channel("viking", { priority = 0 })
    notify.set_push(pushn)
  end
end

function M.on_unload()
  mip.off(mip_id)
  mip.off(fff_id)
  gmcp.remove(gmcp_id)
  timer.remove(sweep_id)
  timer.remove(countdown_id)
  for _, id in ipairs(combat_trigger_ids) do
    trigger.remove(id)
  end
  combat_trigger_ids = {}
  for _, id in ipairs(notify_trigger_ids) do
    trigger.remove(id)
  end
  notify_trigger_ids = {}
end

function M.on_connect() end

function M.on_disconnect()
  state_mod.reset_connection()
end

return M
