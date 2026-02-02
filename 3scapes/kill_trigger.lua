-- Kill Trigger Plugin for Lera
-- Executes commands when specific "killers" deal killing blows
-- Provides /killers command interface for configuration

local M = {}
M.name = "kill_trigger"
M.version = "1.0"
M.priority = 50

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local data = {
  -- Set of killer names (lowercase) -> true
  killers = {
    tapir = true,
    skuggo = true,
  },

  -- Commands to execute when a killer kills
  commands = { "sl", "dg", "wrap" },

  -- Commands to execute when a non-killer kills
  other_commands = {},

  -- Is the trigger system enabled?
  enabled = true,

  -- Use command queue (if available) vs send immediately
  use_queue = true,
}

-- Last kill info for other plugins
local last_kill = {
  killer = "",
  victim = "",
  timestamp = 0,
  was_our_kill = false,  -- Was it one of our killers?
}

-- Trigger and alias IDs for cleanup
local trigger_ids = {}
local alias_ids = {}

--------------------------------------------------------------------------------
-- ANSI Colors
--------------------------------------------------------------------------------

local colors = {
  reset = "\027[0m",
  bold = "\027[1m",
  dim = "\027[2m",
  red = "\027[31m",
  green = "\027[32m",
  yellow = "\027[33m",
  blue = "\027[34m",
  magenta = "\027[35m",
  cyan = "\027[36m",
  white = "\027[37m",
  bright_red = "\027[91m",
  bright_green = "\027[92m",
  bright_yellow = "\027[93m",
  bright_cyan = "\027[96m",
  bright_white = "\027[97m",
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function print_colored(...)
  local parts = {...}
  local text = ""
  for i = 1, #parts, 2 do
    local color = parts[i] or ""
    local str = parts[i + 1] or ""
    text = text .. color .. str
  end
  text = text .. colors.reset
  print(text)
end

local function format_time()
  local t = os.date("*t")
  return string.format("[%02d:%02d:%02d]", t.hour, t.min, t.sec)
end

--------------------------------------------------------------------------------
-- Command Execution
--------------------------------------------------------------------------------

local function send_command(cmd)
  -- For now, just use mud.send directly
  -- Could integrate with a command queue plugin later
  mud.send(cmd)
end

local function send_all_commands()
  for _, cmd in ipairs(data.commands) do
    send_command(cmd)
  end
end

local function send_all_other_commands()
  for _, cmd in ipairs(data.other_commands) do
    send_command(cmd)
  end
end

--------------------------------------------------------------------------------
-- Trigger Handler
--------------------------------------------------------------------------------

local function on_killing_blow(line, killer, victim)
  -- Store kill info
  killer = killer:match("^%s*(.-)%s*$") or killer  -- trim
  victim = victim:match("^%s*(.-)%s*$") or victim  -- trim

  last_kill.killer = killer
  last_kill.victim = victim
  last_kill.timestamp = lera.time()

  -- Print formatted kill message (replaces the gagged line)
  local time_str = format_time()
  print_colored(
    colors.white, time_str .. " ",
    colors.cyan, killer,
    colors.red, " dealt the killing blow to ",
    colors.yellow, victim
  )

  -- Check if we should execute commands
  if not data.enabled then
    last_kill.was_our_kill = false
    return nil  -- Gag original line
  end

  local killer_lower = killer:lower()
  local victim_lower = victim:lower()

  -- Check if killer is in our killers list
  -- Also check for "self" killer (when killer == victim, e.g., poison)
  local is_our_killer = data.killers[killer_lower] or
                        (data.killers["self"] and killer_lower == victim_lower)

  last_kill.was_our_kill = is_our_killer

  if is_our_killer then
    send_all_commands()
  else
    send_all_other_commands()
    -- Could add push notification here for non-killer kills
  end

  return nil  -- Gag original line
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Enable/disable the trigger system
function M.enable()
  data.enabled = true
  print("[killers] Enabled")
end

function M.disable()
  data.enabled = false
  print("[killers] Disabled")
end

function M.is_enabled()
  return data.enabled
end

function M.toggle()
  if data.enabled then
    M.disable()
  else
    M.enable()
  end
  return data.enabled
end

-- Killer management
function M.add_killer(name)
  local lower = name:lower()
  if data.killers[lower] then
    print("[killers] '" .. name .. "' already in list")
    return false
  end
  data.killers[lower] = true
  print("[killers] Added '" .. lower .. "'")
  return true
end

function M.remove_killer(name)
  local lower = name:lower()
  if not data.killers[lower] then
    print("[killers] '" .. name .. "' not in list")
    return false
  end
  data.killers[lower] = nil
  print("[killers] Removed '" .. lower .. "'")
  return true
end

function M.has_killer(name)
  return data.killers[name:lower()] == true
end

function M.get_killers()
  local list = {}
  for name, _ in pairs(data.killers) do
    table.insert(list, name)
  end
  table.sort(list)
  return list
end

-- Command management
function M.add_command(cmd)
  table.insert(data.commands, cmd)
  print("[killers] Added command: " .. cmd)
end

function M.remove_command(index)
  if index < 1 or index > #data.commands then
    print("[killers] Index out of range")
    return false
  end
  local removed = table.remove(data.commands, index)
  print("[killers] Removed command: " .. removed)
  return true
end

function M.get_commands()
  return data.commands
end

function M.swap_commands(idx1, idx2)
  if idx1 < 1 or idx1 > #data.commands or idx2 < 1 or idx2 > #data.commands then
    print("[killers] Index out of range")
    return false
  end
  data.commands[idx1], data.commands[idx2] = data.commands[idx2], data.commands[idx1]
  print("[killers] Swapped " .. data.commands[idx2] .. " with " .. data.commands[idx1])
  return true
end

-- Other command management (for non-killer kills)
function M.add_other_command(cmd)
  table.insert(data.other_commands, cmd)
  print("[killers] Added other-command: " .. cmd)
end

function M.remove_other_command(index)
  if index < 1 or index > #data.other_commands then
    print("[killers] Index out of range")
    return false
  end
  local removed = table.remove(data.other_commands, index)
  print("[killers] Removed other-command: " .. removed)
  return true
end

function M.get_other_commands()
  return data.other_commands
end

function M.swap_other_commands(idx1, idx2)
  if idx1 < 1 or idx1 > #data.other_commands or idx2 < 1 or idx2 > #data.other_commands then
    print("[killers] Index out of range")
    return false
  end
  data.other_commands[idx1], data.other_commands[idx2] = data.other_commands[idx2], data.other_commands[idx1]
  return true
end

-- Queue mode
function M.set_queue_mode(enabled)
  data.use_queue = enabled
  print("[killers] Queue mode: " .. (enabled and "ON" or "OFF"))
end

function M.get_queue_mode()
  return data.use_queue
end

-- Last kill info
function M.get_last_kill()
  return {
    killer = last_kill.killer,
    victim = last_kill.victim,
    timestamp = last_kill.timestamp,
    was_our_kill = last_kill.was_our_kill,
  }
end

-- Reset to defaults
function M.clear()
  data.killers = { tapir = true, skuggo = true }
  data.commands = { "sl", "dg", "wrap" }
  data.other_commands = {}
  data.enabled = true
  data.use_queue = true
  print("[killers] Reset to defaults")
end

-- Check if plugin has meaningful data to display
function M.has_data()
  return true  -- Always has data (enabled state, killers list)
end

--------------------------------------------------------------------------------
-- Stats Window Rendering
--------------------------------------------------------------------------------

-- Truncate string to width
local function trunc(s, w)
  if #s <= w then return s end
  return s:sub(1, w - 1) .. "~"
end

-- Render kill trigger stats for stats_window
function M.render_stats(rect, opts)
  opts = opts or {}

  local x, y, w, h
  if type(rect.x) == "function" then
    x, y, w, h = rect:x(), rect:y(), rect:w(), rect:h()
  else
    x, y, w, h = rect.x, rect.y, rect.w, rect.h
  end

  if w <= 0 or h <= 0 then return 0 end

  local lines = {}

  -- Status line: "Killers: ON" or "Killers: OFF"
  local status_color = data.enabled and colors.bright_green or colors.bright_red
  local status_text = string.format("%sKillers%s: %s%s%s",
    colors.cyan, colors.reset,
    status_color, data.enabled and "ON" or "OFF", colors.reset)
  table.insert(lines, status_text)

  -- Killers list (compact)
  local killers = M.get_killers()
  if #killers > 0 then
    local killers_str = table.concat(killers, ", ")
    -- Truncate if too long
    if #killers_str > w - 3 then
      killers_str = killers_str:sub(1, w - 4) .. "~"
    end
    local killers_text = string.format("%s->%s %s",
      colors.dim, colors.reset, killers_str)
    table.insert(lines, killers_text)
  end

  -- Command queue
  if #data.commands > 0 then
    local cmds_str = table.concat(data.commands, " > ")
    -- Truncate if too long
    if #cmds_str > w - 5 then
      cmds_str = cmds_str:sub(1, w - 6) .. "~"
    end
    local cmds_text = string.format("%sCmd%s: %s%s%s",
      colors.yellow, colors.reset,
      colors.dim, cmds_str, colors.reset)
    table.insert(lines, cmds_text)
  end

  -- Last kill (if recent - within 60 seconds)
  local now = lera.time()
  if last_kill.timestamp > 0 and (now - last_kill.timestamp) < 60 then
    local kill_color = last_kill.was_our_kill and colors.green or colors.red
    local victim_trunc = trunc(last_kill.victim, w - 8)
    local kill_text = string.format("%sLast%s: %s%s%s",
      colors.dim, colors.reset,
      kill_color, victim_trunc, colors.reset)
    table.insert(lines, kill_text)
  end

  -- Render lines
  local lines_rendered = 0
  for i, line in ipairs(lines) do
    if i <= h then
      ui.text_ansi(ui.rect(x, y + i - 1, w, 1), line)
      lines_rendered = lines_rendered + 1
    end
  end

  return lines_rendered
end

--------------------------------------------------------------------------------
-- Aliases
--------------------------------------------------------------------------------

local function show_help()
  print("[killers] Commands:")
  print("  /killers              - Show status and help")
  print("  /killers on           - Enable triggers")
  print("  /killers off          - Disable triggers")
  print("  /killers list         - List killers")
  print("  /killers add <name>   - Add a killer")
  print("  /killers del <name>   - Remove a killer")
  print("  /killers listcmd      - List commands")
  print("  /killers addcmd <cmd> - Add a command")
  print("  /killers delcmd <#>   - Remove command by index")
  print("  /killers swapcmd <#> <#> - Swap command order")
  print("  /killers listocmd     - List other-commands")
  print("  /killers addocmd <cmd> - Add other-command")
  print("  /killers delocmd <#>  - Remove other-command")
  print("  /killers swapocmd <#> <#> - Swap other-command order")
  print("  /killers queue on/off - Toggle queue mode")
  print("  /killers clear        - Reset to defaults")
end

local function show_status()
  print("[killers] Status: " .. (data.enabled and "ENABLED" or "DISABLED"))
  print("[killers] Queue mode: " .. (data.use_queue and "ON" or "OFF"))

  -- List killers
  local killers = M.get_killers()
  if #killers > 0 then
    print("[killers] Killers: " .. table.concat(killers, ", "))
  else
    print("[killers] Killers: (none)")
  end

  -- List commands
  if #data.commands > 0 then
    print("[killers] Commands:")
    for i, cmd in ipairs(data.commands) do
      print("  " .. i .. ": " .. cmd)
    end
  else
    print("[killers] Commands: (none)")
  end

  -- List other commands
  if #data.other_commands > 0 then
    print("[killers] Other-commands (non-killer kills):")
    for i, cmd in ipairs(data.other_commands) do
      print("  " .. i .. ": " .. cmd)
    end
  end
end

local function register_aliases()
  -- Main /killers command
  alias_ids[#alias_ids + 1] = alias.add("^/killers$", function()
    show_status()
    print("")
    show_help()
    return nil
  end)

  -- /killers on
  alias_ids[#alias_ids + 1] = alias.add("^/killers\\s+on$", function()
    M.enable()
    return nil
  end)

  -- /killers off
  alias_ids[#alias_ids + 1] = alias.add("^/killers\\s+off$", function()
    M.disable()
    return nil
  end)

  -- /killers list
  alias_ids[#alias_ids + 1] = alias.add("^/killers\\s+list$", function()
    local killers = M.get_killers()
    print("[killers] Killers:")
    for _, name in ipairs(killers) do
      print("  " .. name)
    end
    return nil
  end)

  -- /killers add <name>
  alias_ids[#alias_ids + 1] = alias.add("^/killers\\s+add\\s+(.+)$", function(_, name)
    M.add_killer(name)
    return nil
  end)

  -- /killers del <name>
  alias_ids[#alias_ids + 1] = alias.add("^/killers\\s+del\\s+(.+)$", function(_, name)
    M.remove_killer(name)
    return nil
  end)

  -- /killers listcmd
  alias_ids[#alias_ids + 1] = alias.add("^/killers\\s+listcmd$", function()
    print("[killers] Commands:")
    for i, cmd in ipairs(data.commands) do
      print("  " .. i .. ": " .. cmd)
    end
    return nil
  end)

  -- /killers addcmd <cmd>
  alias_ids[#alias_ids + 1] = alias.add("^/killers\\s+addcmd\\s+(.+)$", function(_, cmd)
    M.add_command(cmd)
    return nil
  end)

  -- /killers delcmd <index>
  alias_ids[#alias_ids + 1] = alias.add("^/killers\\s+delcmd\\s+(\\d+)$", function(_, idx)
    M.remove_command(tonumber(idx))
    return nil
  end)

  -- /killers swapcmd <idx1> <idx2>
  alias_ids[#alias_ids + 1] = alias.add("^/killers\\s+swapcmd\\s+(\\d+)\\s+(\\d+)$", function(_, idx1, idx2)
    M.swap_commands(tonumber(idx1), tonumber(idx2))
    return nil
  end)

  -- /killers listocmd
  alias_ids[#alias_ids + 1] = alias.add("^/killers\\s+listocmd$", function()
    print("[killers] Other-commands (non-killer kills):")
    for i, cmd in ipairs(data.other_commands) do
      print("  " .. i .. ": " .. cmd)
    end
    if #data.other_commands == 0 then
      print("  (none)")
    end
    return nil
  end)

  -- /killers addocmd <cmd>
  alias_ids[#alias_ids + 1] = alias.add("^/killers\\s+addocmd\\s+(.+)$", function(_, cmd)
    M.add_other_command(cmd)
    return nil
  end)

  -- /killers delocmd <index>
  alias_ids[#alias_ids + 1] = alias.add("^/killers\\s+delocmd\\s+(\\d+)$", function(_, idx)
    M.remove_other_command(tonumber(idx))
    return nil
  end)

  -- /killers swapocmd <idx1> <idx2>
  alias_ids[#alias_ids + 1] = alias.add("^/killers\\s+swapocmd\\s+(\\d+)\\s+(\\d+)$", function(_, idx1, idx2)
    M.swap_other_commands(tonumber(idx1), tonumber(idx2))
    return nil
  end)

  -- /killers queue on/off
  alias_ids[#alias_ids + 1] = alias.add("^/killers\\s+queue\\s+(on|off)$", function(_, mode)
    M.set_queue_mode(mode == "on")
    return nil
  end)

  -- /killers clear
  alias_ids[#alias_ids + 1] = alias.add("^/killers\\s+clear$", function()
    M.clear()
    return nil
  end)

  -- /killers help
  alias_ids[#alias_ids + 1] = alias.add("^/killers\\s+help$", function()
    show_help()
    return nil
  end)
end

local function unregister_aliases()
  for _, id in ipairs(alias_ids) do
    if id then alias.remove(id) end
  end
  alias_ids = {}
end

--------------------------------------------------------------------------------
-- Triggers
--------------------------------------------------------------------------------

local function register_triggers()
  -- "X dealt the killing blow to Y."
  trigger_ids[#trigger_ids + 1] = trigger.add(
    "^(.+) dealt the killing blow to (.+)\\.$",
    on_killing_blow,
    { omit_from_output = true }
  )
end

local function unregister_triggers()
  for _, id in ipairs(trigger_ids) do
    if id then trigger.remove(id) end
  end
  trigger_ids = {}
end

--------------------------------------------------------------------------------
-- Plugin Lifecycle
--------------------------------------------------------------------------------

function M.on_load()
  -- Load saved data
  store.load()
  local saved = store.get()
  if saved then
    if saved.killers then
      data.killers = saved.killers
    end
    if saved.commands then
      data.commands = saved.commands
    end
    if saved.other_commands then
      data.other_commands = saved.other_commands
    end
    if saved.enabled ~= nil then
      data.enabled = saved.enabled
    end
    if saved.use_queue ~= nil then
      data.use_queue = saved.use_queue
    end
  end

  register_triggers()
  register_aliases()

  print("[killers] Loaded - " .. (data.enabled and "ENABLED" or "DISABLED") .. " - type '/killers' for help")
end

function M.on_unload()
  unregister_triggers()
  unregister_aliases()

  -- Save data
  store.set({
    killers = data.killers,
    commands = data.commands,
    other_commands = data.other_commands,
    enabled = data.enabled,
    use_queue = data.use_queue,
  })
  store.save()
end

return M
