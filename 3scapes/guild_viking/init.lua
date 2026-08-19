-- Guild Viking plugin: stage 1 foundation (protocol, state, notifications,
-- persistence, /vik). Window pages arrive in stage 2 and read this state.
local state_mod = require("state")
local protocol = require("protocol")

local M = {}
M.name = "guild_viking"
M.version = "0.1"

function M.state()
  return state_mod.S
end

local mip_id, gmcp_id, sweep_id

function M.on_load()
  mip_id = mip.on("BBE", function(key, code, data) protocol.on_bbe(data) end)
  gmcp_id = gmcp.on("Viking", function(pkg, data) protocol.on_gmcp(pkg, data) end)
  sweep_id = timer.every(100, function() protocol.sweep(lera.time()) end)
end

function M.on_unload()
  mip.off(mip_id)
  gmcp.remove(gmcp_id)
  timer.remove(sweep_id)
end

function M.on_connect() end

function M.on_disconnect()
  state_mod.reset_connection()
end

return M
