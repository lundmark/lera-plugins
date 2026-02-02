-- Input Echo Plugin for Lera
-- Echoes player input to the output buffer with configurable color and toggle.

local M = {}
M.name = "input_echo"
M.version = "1.0"

-- Configuration
local config = {
  enabled = false,        -- Off by default
  color = 6,              -- Cyan (ANSI palette)
  prefix = "> ",          -- Prefix before echoed text
  prefix_color = 8,       -- Gray for prefix
}

--------------------------------------------------------------------------------
-- Plugin Hooks
--------------------------------------------------------------------------------

-- Hook: Echo input before sending to MUD
function M.on_input(text)
  -- Don't echo if server has ECHO enabled (e.g., password prompts)
  if config.enabled and text and #text > 0 and not mud.server_echo() then
    buffer.color_print(
      nil, config.prefix_color, config.prefix,
      nil, config.color, text
    )
  end
  return text  -- Pass through unchanged
end

function M.on_load()
  store.load()
  local data = store.get()
  if data then
    if data.enabled ~= nil then config.enabled = data.enabled end
    if data.color then config.color = data.color end
    if data.prefix then config.prefix = data.prefix end
    if data.prefix_color then config.prefix_color = data.prefix_color end
  end
end

function M.on_unload()
  store.set(config)
  store.save()
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Enable input echo
function M.enable()
  config.enabled = true
end

-- Disable input echo
function M.disable()
  config.enabled = false
end

-- Toggle input echo on/off, returns new state
function M.toggle()
  config.enabled = not config.enabled
  return config.enabled
end

-- Check if input echo is enabled
function M.is_enabled()
  return config.enabled
end

-- Set echo color (ANSI palette 0-255 or "RRGGBB" hex)
function M.set_color(color)
  config.color = color
end

-- Set prefix text (appears before echoed input)
function M.set_prefix(prefix)
  config.prefix = prefix or ""
end

-- Set prefix color (ANSI palette 0-255 or "RRGGBB" hex)
function M.set_prefix_color(color)
  config.prefix_color = color
end

-- Get current configuration
function M.get_config()
  return {
    enabled = config.enabled,
    color = config.color,
    prefix = config.prefix,
    prefix_color = config.prefix_color,
  }
end

return M
