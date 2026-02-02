-- Example MIP plugin for Lera
-- Shows how to use the mip module to handle MIP protocol messages
local M = {}

M.name = "mip_example"
M.version = "1.0"

-- MIP code handlers - add your own here
local handlers = {}

-- Example: Handle "STA" (status) messages
handlers.STA = function(key, data)
  print("[MIP] Status update: " .. data)
end

-- Example: Handle "MAP" (map) messages
handlers.MAP = function(key, data)
  print("[MIP] Map data received (" .. #data .. " bytes)")
end

-- Example: Handle "HPB" (health bar) messages
handlers.HPB = function(key, data)
  -- Parse HP data if needed
  print("[MIP] Health bar: " .. data)
end

function M.on_load()
  -- Enable MIP when plugin loads
  mip.enable()
  print("[mip_example] MIP enabled, client ID: " .. (mip.client_id() or "unknown"))

  -- Register handlers for each code
  for code, handler in pairs(handlers) do
    mip.on(code, function(key, c, data)
      handler(key, data)
    end)
  end
end

function M.on_unload()
  mip.disable()
  print("[mip_example] MIP disabled")
end

-- Allow other plugins to register MIP handlers
function M.register(code, handler)
  mip.on(code, function(key, c, data)
    handler(key, data)
  end)
end

return M
