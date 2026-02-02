-- Test plugin for Lera plugin system
local M = {}

M.name = "test_plugin"
M.version = "1.0"

-- Track state for testing
M.load_count = 0
M.line_count = 0
M.send_count = 0
M.connected = false

function M.on_load()
  M.load_count = M.load_count + 1
  print("[test_plugin] loaded (count: " .. M.load_count .. ")")
end

function M.on_unload()
  print("[test_plugin] unloaded")
end

function M.on_line(line)
  M.line_count = M.line_count + 1
  -- Return the line unchanged (pass through)
  return line
end

function M.on_send(text)
  M.send_count = M.send_count + 1
  -- Return the text unchanged (pass through)
  return text
end

function M.on_connect()
  M.connected = true
  print("[test_plugin] connected to MUD")
end

function M.on_disconnect()
  M.connected = false
  print("[test_plugin] disconnected from MUD")
end

-- Public API
function M.get_stats()
  return {
    load_count = M.load_count,
    line_count = M.line_count,
    send_count = M.send_count,
    connected = M.connected
  }
end

return M
