-- Guild Viking plugin: stage 1 foundation (protocol, state, notifications,
-- persistence, /vik). Window pages arrive in stage 2 and read this state.
local state_mod = require("state")

local M = {}
M.name = "guild_viking"
M.version = "0.1"

function M.state()
  return state_mod.S
end

function M.on_load() end
function M.on_unload() end
function M.on_connect() end

function M.on_disconnect()
  state_mod.reset_connection()
end

return M
