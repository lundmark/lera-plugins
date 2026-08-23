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
local command_id = nil

-- Cross-plugin kill feed (the Portal killtrigger.monster_died event).
-- Listeners are registration-ordered and die with this plugin's unload;
-- consumers re-register in their on_setup.
local kill_listeners = {}
local next_listener_id = 1

-- require("command") is optional: a profile that never required 'commands' has
-- no registry, and the kill triggers themselves still work.
local command
do
  local ok, mod = pcall(require, "command")
  if ok then command = mod end
end

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

local function save_data()
  store.set({
    killers = data.killers,
    commands = data.commands,
    other_commands = data.other_commands,
    enabled = data.enabled,
  })
  store.save()
end

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

  -- Dispatch over a snapshot: a listener may unsubscribe (itself or another)
  -- from inside its callback, and table.remove during iteration would shift
  -- later entries down and silently skip one for this kill. Registrations
  -- and removals apply to future dispatches; this one runs on the set it
  -- started with.
  local listener_snapshot = {}
  for i, entry in ipairs(kill_listeners) do listener_snapshot[i] = entry end
  for _, entry in ipairs(listener_snapshot) do
    local ok, err = pcall(entry.cb, killer, victim)
    if not ok then print("[kill_trigger] listener error: " .. tostring(err)) end
  end

  -- Check if we should execute commands
  if not data.enabled then
    last_kill.was_our_kill = false
    return
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
  end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Enable/disable the trigger system
function M.enable()
  data.enabled = true
  save_data()
  print("[killers] Enabled")
end

function M.disable()
  data.enabled = false
  save_data()
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
  save_data()
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
  save_data()
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
  save_data()
  print("[killers] Added command: " .. cmd)
end

function M.remove_command(index)
  if index < 1 or index > #data.commands then
    print("[killers] Index out of range")
    return false
  end
  local removed = table.remove(data.commands, index)
  save_data()
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
  local a, b = data.commands[idx1], data.commands[idx2]
  data.commands[idx1], data.commands[idx2] = b, a
  save_data()
  print("[killers] Swapped " .. a .. " with " .. b)
  return true
end

-- Other command management (for non-killer kills)
function M.add_other_command(cmd)
  table.insert(data.other_commands, cmd)
  save_data()
  print("[killers] Added other-command: " .. cmd)
end

function M.remove_other_command(index)
  if index < 1 or index > #data.other_commands then
    print("[killers] Index out of range")
    return false
  end
  local removed = table.remove(data.other_commands, index)
  save_data()
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
  local a, b = data.other_commands[idx1], data.other_commands[idx2]
  data.other_commands[idx1], data.other_commands[idx2] = b, a
  save_data()
  print("[killers] Swapped " .. a .. " with " .. b)
  return true
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
  save_data()
  print("[killers] Reset to defaults")
end

-- Check if plugin has meaningful data to display
function M.has_data()
  return true  -- Always has data (enabled state, killers list)
end

-- Cross-plugin kill feed
function M.on_monster_died(cb)
  if type(cb) ~= "function" then return nil end
  local id = next_listener_id
  next_listener_id = next_listener_id + 1
  kill_listeners[#kill_listeners + 1] = { id = id, cb = cb }
  return id
end

function M.remove_kill_listener(id)
  for i, entry in ipairs(kill_listeners) do
    if entry.id == id then
      table.remove(kill_listeners, i)
      return true
    end
  end
  return false
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
-- The killers block as a line list, for a host that windows it itself
-- (stats_window's scrollable info pane asks for these). render_stats below
-- keeps the older draw-into-a-rect contract for hosts that don't.
function M.stats_lines(w)
  if type(w) ~= "number" or w <= 0 then return {} end
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

  return lines
end

function M.render_stats(rect, opts)
  opts = opts or {}

  local x, y, w, h
  if type(rect.x) == "function" then
    x, y, w, h = rect:x(), rect:y(), rect:w(), rect:h()
  else
    x, y, w, h = rect.x, rect.y, rect.w, rect.h
  end

  if w <= 0 or h <= 0 then return 0 end

  local lines = M.stats_lines(w)
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
  print("  /killers clear        - Reset to defaults")
end

local function show_status()
  print("[killers] Status: " .. (data.enabled and "ENABLED" or "DISABLED"))

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

-- The registry hands the handler everything after the command name, so the
-- subcommand split and its validation happen here rather than in a regex.
local function split_subcommand(args)
  local sub, rest = tostring(args or ""):match("^%s*(%S*)%s*(.-)%s*$")
  return sub:lower(), rest
end

local function usage(form)
  print("[killers] Usage: /killers " .. form)
end

local function list_commands()
  print("[killers] Commands:")
  for i, cmd in ipairs(data.commands) do
    print("  " .. i .. ": " .. cmd)
  end
end

local function list_other_commands()
  print("[killers] Other-commands (non-killer kills):")
  for i, cmd in ipairs(data.other_commands) do
    print("  " .. i .. ": " .. cmd)
  end
  if #data.other_commands == 0 then
    print("  (none)")
  end
end

-- Index arguments were validated by \d+ in the old alias patterns; the checks
-- are explicit now so a bad index prints usage instead of reaching the API.
local function one_index(sub, rest)
  local index = tonumber(rest:match("^%d+$"))
  if not index then
    usage(sub .. " <#>")
    return nil
  end
  return index
end

local function two_indices(sub, rest)
  local first, second = rest:match("^(%d+)%s+(%d+)$")
  if not first then
    usage(sub .. " <#> <#>")
    return nil
  end
  return tonumber(first), tonumber(second)
end

local function dispatch(args)
  local sub, rest = split_subcommand(args)

  if sub == "" then
    show_status()
    print("")
    show_help()
  elseif sub == "help" then
    show_help()
  elseif sub == "on" then
    M.enable()
  elseif sub == "off" then
    M.disable()
  elseif sub == "list" then
    local killers = M.get_killers()
    print("[killers] Killers:")
    for _, name in ipairs(killers) do
      print("  " .. name)
    end
  elseif sub == "add" then
    if rest == "" then return usage("add <name>") end
    M.add_killer(rest)
  elseif sub == "del" then
    if rest == "" then return usage("del <name>") end
    M.remove_killer(rest)
  elseif sub == "listcmd" then
    list_commands()
  elseif sub == "addcmd" then
    if rest == "" then return usage("addcmd <cmd>") end
    M.add_command(rest)
  elseif sub == "delcmd" then
    local index = one_index(sub, rest)
    if index then M.remove_command(index) end
  elseif sub == "swapcmd" then
    local first, second = two_indices(sub, rest)
    if first then M.swap_commands(first, second) end
  elseif sub == "listocmd" then
    list_other_commands()
  elseif sub == "addocmd" then
    if rest == "" then return usage("addocmd <cmd>") end
    M.add_other_command(rest)
  elseif sub == "delocmd" then
    local index = one_index(sub, rest)
    if index then M.remove_other_command(index) end
  elseif sub == "swapocmd" then
    local first, second = two_indices(sub, rest)
    if first then M.swap_other_commands(first, second) end
  elseif sub == "clear" then
    M.clear()
  else
    print("[killers] Unknown subcommand: " .. sub)
    show_help()
  end
end

local function register_command()
  if not command then return end
  local id, err = command.register({
    name = "/killers",
    usage = "/killers [on|off|list|add <name>|del <name>|listcmd|addcmd <cmd>|clear]",
    summary = "Run commands when a named killer lands a killing blow",
    description = "Watches for killing-blow lines. When one of the configured "
      .. "killers lands it, the command list runs; any other killer runs the "
      .. "other-command list. 'addcmd'/'delcmd'/'swapcmd' edit the first list, "
      .. "the 'ocmd' variants the second.",
    accepts_args = true,
    handler = dispatch,
  })
  if id then
    command_id = id
  else
    print("[kill_trigger] command registration failed: " .. tostring(err))
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
-- Triggers
--------------------------------------------------------------------------------

local function register_triggers()
  -- "X dealt the killing blow to Y."
  trigger_ids[#trigger_ids + 1] = trigger.add(
    "^(.+?) dealt the killing blow to (.+)\\.$",
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
  end

  register_triggers()
  register_command()

  print("[killers] Loaded - " .. (data.enabled and "ENABLED" or "DISABLED") .. " - type '/killers' for help")
end

function M.on_unload()
  unregister_triggers()
  unregister_command()

  -- Save data
  save_data()
end

return M
