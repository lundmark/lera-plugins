-- Cross-session persistence: the rolling price history (market.lua) and the
-- transport source mode (protocol.lua). Everything else in state.lua is
-- per-connection/session data (combat, carts in transit, etc.) that would be
-- stale on the next load, so it is deliberately NOT persisted here.
local market = require("market")
local protocol = require("protocol")

local M = {}

function M.save()
  store.set({
    settings = { source = protocol.source() },
    price_history = market.snapshot().price_history,
  })
  store.save()
end

function M.load()
  store.load()
  local data = store.get()
  if not data then return end

  if data.price_history then
    market.restore({ price_history = data.price_history })
  end

  local source = data.settings and data.settings.source
  if source then protocol.source(source) end
end

return M
