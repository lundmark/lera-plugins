-- Deadmans Switch Plugin for Lera
-- Prevents automated sends (triggers/timers) when user has been idle too long.
-- Shows warning overlay when idle, blocks sends when deadmans is active.

local M = {}
M.name = "deadmans"
M.version = "1.0"
M.priority = 1  -- Run first to intercept automated sends

-- Configuration
local config = {
  warning_time = 10 * 60,  -- 10 minutes: start showing yellow warning
  block_time = 15 * 60,    -- 15 minutes: activate deadmans (block sends)
  overlay_width_pct = 0.80,  -- 80% of screen width
  overlay_height_pct = 0.40, -- 40% of screen height
}

-- require("command") is optional: a profile that never required 'commands' has
-- no registry, and the plugin's public API still works.
local command
do
  local ok, mod = pcall(require, "command")
  if ok then command = mod end
end

-- State
local last_user_input = 0  -- Timestamp of last user input
local blocked_count = 0     -- Number of sends blocked this session
local update_timer = nil    -- Timer for updating the display
local command_id = nil      -- Registered command ID for cleanup

-- ANSI 256 color palette indices
local colors = {
  red_bg = 196,      -- Bright red
  yellow_bg = 226,   -- Bright yellow
  black_fg = 16,     -- Black
  white_fg = 231,    -- White
}

-- Persist the thresholds. Called on every change rather than only at unload:
-- on_unload runs on a clean exit, so a killed process used to lose the setting.
local function save_config()
  store.set({
    config = {
      warning_time = config.warning_time,
      block_time = config.block_time,
    }
  })
  store.save()
end

-- Get current time in seconds
local function get_time()
  return lera.time()
end

-- Get idle time in seconds
local function get_idle_time()
  if last_user_input == 0 then
    return 0
  end
  return get_time() - last_user_input
end

-- Check if we're in warning state (yellow)
local function is_warning()
  local idle = get_idle_time()
  return idle >= config.warning_time and idle < config.block_time
end

-- Check if deadmans is active (blocking sends)
local function is_active()
  return get_idle_time() >= config.block_time
end

-- Format seconds as MM:SS or HH:MM:SS
local function format_time(seconds)
  local hours = math.floor(seconds / 3600)
  local mins = math.floor((seconds % 3600) / 60)
  local secs = seconds % 60

  if hours > 0 then
    return string.format("%d:%02d:%02d", hours, mins, secs)
  else
    return string.format("%d:%02d", mins, secs)
  end
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local function show_help()
  print("[deadmans] Commands:")
  print("  /deadmans               - Show status and help")
  print("  /deadmans status        - Show current status")
  print("  /deadmans reset         - Reset idle timer (re-enable sends)")
  print("  /deadmans warning <min> - Set warning time (minutes)")
  print("  /deadmans set <min>     - Set block time (minutes)")
end

local function show_status()
  local idle = get_idle_time()
  local state = "OK"
  if is_active() then
    state = "BLOCKING"
  elseif is_warning() then
    state = "WARNING"
  end

  print("[deadmans] Status: " .. state)
  print("[deadmans] Idle time: " .. format_time(idle))
  print("[deadmans] Warning at: " .. math.floor(config.warning_time / 60) .. " minutes")
  print("[deadmans] Blocking at: " .. math.floor(config.block_time / 60) .. " minutes")
  if blocked_count > 0 then
    print("[deadmans] Blocked sends: " .. blocked_count)
  end
end

-- The registry hands the handler everything after the command name, so the
-- subcommand split and its validation happen here rather than in a regex.
local function split_subcommand(args)
  local sub, rest = tostring(args or ""):match("^%s*(%S*)%s*(.-)%s*$")
  return sub:lower(), rest
end

-- The usage line echoes the subcommand the user typed, so "block" reports
-- itself rather than pointing at a name they did not use.
local function set_minutes(sub, rest)
  local minutes = tonumber(rest:match("^%d+$"))
  if not minutes then
    print("[deadmans] Usage: /deadmans " .. sub .. " <minutes>")
  elseif sub == "warning" then
    M.set_warning_time(minutes)
  else
    M.set_block_time(minutes)
  end
end

local function dispatch(args)
  local sub, rest = split_subcommand(args)

  if sub == "" then
    show_status()
    print("")
    show_help()
  elseif sub == "help" then
    show_help()
  elseif sub == "status" then
    show_status()
  elseif sub == "reset" then
    M.reset()
  elseif sub == "warning" or sub == "set" or sub == "block" then
    -- "block" predates "set" and stays accepted; only "set" is advertised.
    set_minutes(sub, rest)
  else
    print("[deadmans] Unknown subcommand: " .. sub)
    show_help()
  end
end

local function register_command()
  if not command then return end
  local id, err = command.register({
    name = "/deadmans",
    usage = "/deadmans [status|reset|warning <min>|set <min>]",
    summary = "Idle detection and automated-send blocking",
    description = "Tracks how long it has been since you last typed something. "
      .. "After the warning time an overlay appears; after the block time "
      .. "automated sends from triggers and timers are suppressed until you "
      .. "type again. 'set <minutes>' changes the block time and 'warning "
      .. "<minutes>' the warning time; both are saved as soon as they change. "
      .. "'reset' clears the idle timer by hand.",
    accepts_args = true,
    handler = dispatch,
  })
  if id then
    command_id = id
  else
    print("[deadmans] command registration failed: " .. tostring(err))
  end
end

local function unregister_command()
  -- The loader drops a plugin's commands on unload; unregistering here keeps a
  -- manual reload from colliding with its own leftover record.
  if command and command_id then
    pcall(command.unregister, command_id)
    command_id = nil
  end
end

--------------------------------------------------------------------------------
-- Plugin Hooks
--------------------------------------------------------------------------------

function M.on_input(text)
  -- Reset the idle timer on any user input (even empty)
  local was_active = is_active()
  last_user_input = get_time()

  if was_active then
    print("[deadmans] Resumed - automation re-enabled")
    if blocked_count > 0 then
      print("[deadmans] Blocked " .. blocked_count .. " automated send(s) while idle")
      blocked_count = 0
    end
  end
  -- Return the text unchanged to allow it through
  return text
end

function M.on_send(text)
  -- Block automated sends if deadmans is active
  if is_active() then
    blocked_count = blocked_count + 1
    -- Return nil to block the send
    return nil
  end

  -- Allow the send (return unchanged)
  return text
end

function M.on_render()
  -- Only show overlay if in warning or blocking state
  if not is_warning() and not is_active() then
    return
  end

  local root = ui.root()
  local screen_w, screen_h = root:w(), root:h()

  -- Calculate overlay size (percentage-based)
  local box_w = math.floor(screen_w * config.overlay_width_pct)
  local box_h = math.floor(screen_h * config.overlay_height_pct)

  -- Minimum size
  if box_w < 20 then box_w = 20 end
  if box_h < 5 then box_h = 5 end

  -- Calculate overlay position (centered)
  local box_x = math.floor((screen_w - box_w) / 2)
  local box_y = math.floor((screen_h - box_h) / 2)

  local rect = ui.rect(box_x, box_y, box_w, box_h)

  -- Choose colors based on state
  local bg_color, status_text
  if is_active() then
    bg_color = colors.red_bg
    status_text = "SENDS BLOCKED"
  else
    bg_color = colors.yellow_bg
    status_text = "WARNING"
  end

  -- Fill entire rectangle with background color
  ui.fill(rect, " ", bg_color, colors.black_fg)

  -- Helper to center text within width
  local function center_text(text, width)
    local text_len = #text
    local pad = math.floor((width - text_len) / 2)
    if pad < 0 then pad = 0 end
    return string.rep(" ", pad) .. text
  end

  -- Calculate vertical center
  local center_y = box_y + math.floor(box_h / 2)

  -- Format idle time
  local time_str = format_time(get_idle_time())

  -- Draw content centered in the box
  -- Line 1: "DEADMANS" title (above center)
  local title = "DEADMANS"
  ui.text(ui.rect(box_x + math.floor((box_w - #title) / 2), center_y - 2, #title, 1), title)

  -- Line 2: Idle time (at center - 1)
  local idle_str = "IDLE: " .. time_str
  ui.text(ui.rect(box_x + math.floor((box_w - #idle_str) / 2), center_y, #idle_str, 1), idle_str)

  -- Line 3: Status (below center)
  ui.text(ui.rect(box_x + math.floor((box_w - #status_text) / 2), center_y + 2, #status_text, 1), status_text)
end

-- Timer callback to refresh display when idle
local function update_display()
  if is_warning() or is_active() then
    -- Force screen redraw to update the overlay
    lera.dirty()
  end
end

function M.on_load()
  -- Initialize timestamp
  last_user_input = get_time()

  -- Load saved config
  store.load()
  local data = store.get()
  if data and data.config then
    if data.config.warning_time then config.warning_time = data.config.warning_time end
    if data.config.block_time then config.block_time = data.config.block_time end
  end

  register_command()

  -- Start update timer (every second when warning/active)
  update_timer = timer.every(1000, update_display)

  print("[deadmans] Loaded - warning at " .. math.floor(config.warning_time / 60) ..
        "m, blocking at " .. math.floor(config.block_time / 60) .. "m")
  print("[deadmans] Type '/deadmans' for commands")
end

function M.on_unload()
  unregister_command()

  -- Stop update timer
  if update_timer then
    timer.cancel(update_timer)
    update_timer = nil
  end

  save_config()
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Set warning time (in minutes)
function M.set_warning_time(minutes)
  config.warning_time = minutes * 60
  save_config()
  print("[deadmans] Warning time set to " .. minutes .. " minutes")
end

-- Set block time (in minutes)
function M.set_block_time(minutes)
  config.block_time = minutes * 60
  save_config()
  print("[deadmans] Block time set to " .. minutes .. " minutes")
end

-- Get current idle time in seconds
function M.get_idle_time()
  return get_idle_time()
end

-- Check if deadmans is currently active (blocking)
function M.is_active()
  return is_active()
end

-- Check if in warning state
function M.is_warning()
  return is_warning()
end

-- Reset the idle timer (as if user just pressed enter)
function M.reset()
  last_user_input = get_time()
  blocked_count = 0
  print("[deadmans] Timer reset")
end

-- Get number of blocked sends
function M.blocked_count()
  return blocked_count
end

-- Get current config
function M.get_config()
  return {
    warning_time = config.warning_time,
    block_time = config.block_time,
  }
end

return M
