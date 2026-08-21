-- Cross-session persistence: the rolling price history (market.lua), the
-- transport source mode (protocol.lua), and (stage 2) the page options and
-- current page (page_opts.lua / window.lua), mirroring LEGACY's
-- SetVariable("popt_"..k) + SetVariable("page", ...)
-- (/home/simon/code/3s_scripts_old/lua/guild_viking.lua:3025-3040). Everything
-- else in state.lua is per-connection/session data (combat, carts in
-- transit, etc.) that would be stale on the next load, so it is deliberately
-- NOT persisted here.
local market = require("market")
local protocol = require("protocol")
local page_opts = require("page_opts")
local window = require("window")

local M = {}

function M.save()
  local opts = {}
  for _, o in ipairs(page_opts.all()) do opts[o.key] = o.value end

  store.set({
    settings = { source = protocol.source() },
    price_history = market.snapshot().price_history,
    page_opts = opts,
    page = window.current_page(),
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

  if data.page_opts then
    for k, v in pairs(data.page_opts) do page_opts.set(k, v) end
  end
  if data.page then
    window.set_page(data.page)
  end
end

return M
