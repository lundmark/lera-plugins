-- Autostepper Plugin for Lera
-- Automatically walks routes, checking rooms and killing targets
-- Requires: speedwalk, roominfo plugins

local M = {}
M.name = "autostepper"
M.version = "1.0"
M.priority = 40  -- After roominfo (10), before speedwalk (50)

--------------------------------------------------------------------------------
-- Dependencies
--------------------------------------------------------------------------------

local sw = nil      -- speedwalk plugin (set in on_load)
local ri = nil      -- roominfo plugin (set in on_load)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local state = "idle"    -- idle, sent_glance, waiting_second, fighting
local prompt_count = 0  -- Count of prompts received
local enabled = false   -- Is autostepper active?
local prompt_trigger_id = nil  -- Trigger ID for prompt detection

-- Configuration
local config = {
  glance_cmd = "glance",      -- Command to look at room
  attack_cmd = "kill",        -- Command prefix for attacking (kill <target>)
  prompt_pattern = nil,       -- Pattern to detect prompts (set by user)
  auto_attack = true,         -- Attack valid targets automatically
  step_on_player = true,      -- Take step if player in room (don't fight)
  step_on_no_monster = true,  -- Take step if no monsters
  targets_only = false,       -- Only kill monsters in target list (-> mode)
}

-- Callbacks
local on_step_callbacks = {}      -- Called when a step is taken
local on_attack_callbacks = {}    -- Called when attacking
local on_complete_callbacks = {}  -- Called when route complete
local on_skip_callbacks = {}      -- Called when skipping a monster

--------------------------------------------------------------------------------
-- Internal Functions
--------------------------------------------------------------------------------

local function log(msg)
  print("[autostepper] " .. msg)
end

local function notify(callbacks, ...)
  for _, cb in ipairs(callbacks) do
    local ok, err = pcall(cb, ...)
    if not ok then
      log("Callback error: " .. tostring(err))
    end
  end
end

local function send_glance()
  state = "sent_glance"
  prompt_count = 0
  -- Send glance command followed by empty line
  mud.send(config.glance_cmd)
  mud.send("")
end

local function do_attack(monster)
  state = "fighting"
  local cmd = config.attack_cmd .. " " .. monster
  log("Attacking: " .. monster)
  notify(on_attack_callbacks, monster, cmd)
  mud.send(cmd)
  -- After attack, we'll get a prompt which will trigger next glance
end

local function do_step()
  local step = sw.take_step()
  if not step then
    -- Route complete
    log("Route complete!")
    enabled = false
    state = "idle"
    notify(on_complete_callbacks)
    return false
  end

  log("Step: " .. step.raw)
  notify(on_step_callbacks, step.raw, sw.step_info())

  -- Send all commands in this step
  for _, cmd in ipairs(step.commands) do
    mud.send(cmd)
  end

  -- After step, send glance to check new room
  -- Use a small delay to let room info come through
  timer.after(100, function()
    if enabled then
      send_glance()
    end
  end)

  return true
end

local function process_room()
  if not ri then
    log("Error: roominfo plugin not available")
    M.stop()
    return
  end

  local players = ri.players()
  local monsters = ri.monsters()
  local room = ri.room() or "unknown"

  -- Check if player in room
  if #players > 0 and config.step_on_player then
    log("Player in room (" .. room .. "), stepping...")
    do_step()
    return
  end

  -- Check if no monsters
  if #monsters == 0 and config.step_on_no_monster then
    log("No monsters in room (" .. room .. "), stepping...")
    do_step()
    return
  end

  -- Monsters present - decide whether to attack
  if #monsters > 0 then
    if config.targets_only then
      -- Only attack monsters in target list
      for _, monster in ipairs(monsters) do
        if sw.is_valid_target(monster) then
          if config.auto_attack then
            do_attack(monster)
            return
          else
            log("Valid target found but auto_attack disabled: " .. monster)
          end
        end
      end
      -- No valid targets - skip and step
      log("Monster not in target list (" .. monsters[1] .. "), stepping...")
      notify(on_skip_callbacks, monsters[1], room)
      do_step()
      return
    else
      -- Attack any monster (first one)
      if config.auto_attack then
        do_attack(monsters[1])
        return
      else
        log("Monster found but auto_attack disabled: " .. monsters[1])
      end
    end
  end

  -- Fallback - just step
  do_step()
end

local function on_prompt()
  if not enabled then return end

  prompt_count = prompt_count + 1

  if state == "sent_glance" then
    -- Got first prompt (from glance)
    state = "waiting_second"
  elseif state == "waiting_second" then
    -- Got second prompt (from empty line) - process room
    state = "idle"
    process_room()
  elseif state == "fighting" then
    -- Combat ended (or just another prompt) - continue stepping
    state = "idle"
    send_glance()
  end
end

--------------------------------------------------------------------------------
-- Aliases
--------------------------------------------------------------------------------

local alias_ids = {}  -- Store alias IDs for cleanup

local function show_help()
  log("Commands:")
  log("  -.              - Start stepping, kill any mob")
  log("  ->              - Start stepping, only kill targets")
  log("  -!              - Stop stepping")
  log("  -set status     - Show current status")
  log("  -set prompt <p> - Set prompt detection pattern")
  log("  -set attack [on|off] - Toggle auto-attack")
  log("  -set glance [cmd]    - Set/show glance command")
  log("  -set kill [cmd]      - Set/show attack command prefix")
  log("  -set config     - Show configuration")
end

local function register_aliases()
  -- "-" - show help
  alias_ids[#alias_ids + 1] = alias.add("^-$", function()
    show_help()
    return nil
  end)

  -- "-." - start stepping, kill any mob
  alias_ids[#alias_ids + 1] = alias.add("^-\\.$", function()
    M.start(false)
    return nil
  end)

  -- "->" - start stepping, only kill targets
  alias_ids[#alias_ids + 1] = alias.add("^->$", function()
    M.start(true)
    return nil
  end)

  -- "-!" - stop stepping
  alias_ids[#alias_ids + 1] = alias.add("^-!$", function()
    M.stop()
    return nil
  end)

  -- "-set status"
  alias_ids[#alias_ids + 1] = alias.add("^-set\\s+status$", function()
    M.status()
    return nil
  end)

  -- "-set prompt <pattern>"
  alias_ids[#alias_ids + 1] = alias.add("^-set\\s+prompt\\s+(.+)$", function(_, pattern)
    M.set_prompt_pattern(pattern)
    return nil
  end)

  -- "-set prompt" (no arg)
  alias_ids[#alias_ids + 1] = alias.add("^-set\\s+prompt$", function()
    log("Usage: -set prompt <pattern>")
    log("Current: " .. (config.prompt_pattern or "(not set)"))
    return nil
  end)

  -- "-set config"
  alias_ids[#alias_ids + 1] = alias.add("^-set\\s+config$", function()
    log("Configuration:")
    log("  glance_cmd: " .. config.glance_cmd)
    log("  attack_cmd: " .. config.attack_cmd)
    log("  prompt_pattern: " .. (config.prompt_pattern or "(not set)"))
    log("  auto_attack: " .. tostring(config.auto_attack))
    log("  targets_only: " .. tostring(config.targets_only))
    return nil
  end)

  -- "-set attack on/off"
  alias_ids[#alias_ids + 1] = alias.add("^-set\\s+attack\\s+(on|off)$", function(_, val)
    config.auto_attack = (val == "on")
    log("Auto-attack " .. (config.auto_attack and "enabled" or "disabled"))
    return nil
  end)

  -- "-set attack" (no arg)
  alias_ids[#alias_ids + 1] = alias.add("^-set\\s+attack$", function()
    log("Auto-attack: " .. (config.auto_attack and "on" or "off"))
    return nil
  end)

  -- "-set glance <cmd>"
  alias_ids[#alias_ids + 1] = alias.add("^-set\\s+glance\\s+(.+)$", function(_, cmd)
    config.glance_cmd = cmd
    log("Glance command set: " .. config.glance_cmd)
    return nil
  end)

  -- "-set glance" (no arg)
  alias_ids[#alias_ids + 1] = alias.add("^-set\\s+glance$", function()
    log("Glance command: " .. config.glance_cmd)
    return nil
  end)

  -- "-set kill <cmd>"
  alias_ids[#alias_ids + 1] = alias.add("^-set\\s+kill\\s+(.+)$", function(_, cmd)
    config.attack_cmd = cmd
    log("Attack command set: " .. config.attack_cmd)
    return nil
  end)

  -- "-set kill" (no arg)
  alias_ids[#alias_ids + 1] = alias.add("^-set\\s+kill$", function()
    log("Attack command: " .. config.attack_cmd)
    return nil
  end)

  -- "-set" or "-set help" - show help
  alias_ids[#alias_ids + 1] = alias.add("^-set$", function()
    show_help()
    return nil
  end)

  alias_ids[#alias_ids + 1] = alias.add("^-set\\s+help$", function()
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
-- Plugin Hooks
--------------------------------------------------------------------------------

function M.on_load()
  -- Try to get dependencies
  sw = plugin.get("speedwalk")
  ri = plugin.get("roominfo")

  if not sw then
    log("Warning: speedwalk plugin not loaded")
  end
  if not ri then
    log("Warning: roominfo plugin not loaded")
  end

  -- Register aliases
  register_aliases()

  log("Loaded (use -set help for commands)")
end

function M.on_unload()
  -- Unregister aliases
  unregister_aliases()

  M.stop()
  log("Unloaded")
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Set the prompt pattern and create trigger
function M.set_prompt_pattern(pattern)
  -- Remove old trigger if exists
  if prompt_trigger_id then
    trigger.remove(prompt_trigger_id)
    prompt_trigger_id = nil
  end

  config.prompt_pattern = pattern

  if pattern then
    prompt_trigger_id = trigger.add(pattern, function()
      on_prompt()
    end)

    if prompt_trigger_id then
      log("Prompt pattern set: " .. pattern)
    else
      log("Failed to compile prompt pattern")
      config.prompt_pattern = nil
    end
  end
end

-- Start autostepping at current place
-- targets_only: if true, only kill monsters in target list; if false, kill any monster
function M.start(targets_only)
  if not sw then
    sw = plugin.get("speedwalk")
    if not sw then
      log("Error: speedwalk plugin required")
      return false
    end
  end

  if not ri then
    ri = plugin.get("roominfo")
    if not ri then
      log("Error: roominfo plugin required")
      return false
    end
  end

  if not config.prompt_pattern then
    log("Error: prompt pattern not set (use -set prompt <pattern>)")
    return false
  end

  local place = sw.get_current_place()
  if not place then
    log("Error: current place not set (use .set <place>)")
    return false
  end

  -- Load step list from current place
  if not sw.load_steps() then
    log("Error: no steps configured for place '" .. place .. "'")
    log("Use speedwalk.configure_place('" .. place .. "', 'n|s|e|w', 'target1,target2')")
    return false
  end

  local info = sw.step_info()
  local targets = sw.get_targets()

  -- Set targets_only mode
  config.targets_only = targets_only or false

  local mode = config.targets_only and "targets only" or "any mob"
  log("Starting at '" .. place .. "': " .. info.total .. " steps (" .. mode .. ")")
  if config.targets_only and #targets > 0 then
    log("Targets: " .. table.concat(targets, ", "))
  end

  enabled = true
  state = "idle"
  prompt_count = 0

  -- Start by sending glance
  send_glance()

  return true
end

-- Stop autostepping
function M.stop()
  if enabled then
    log("Stopped")
  end
  enabled = false
  state = "idle"
  prompt_count = 0
end

-- Check if running
function M.is_running()
  return enabled
end

-- Get current state
function M.get_state()
  return state
end

-- Show status
function M.status()
  log("Status:")
  log("  Running: " .. (enabled and "yes" or "no"))
  log("  State: " .. state)
  log("  Mode: " .. (config.targets_only and "targets only (->)" or "any mob (-.))"))
  log("  Prompt count: " .. prompt_count)

  if sw then
    local info = sw.step_info()
    log("  Steps: " .. info.current .. "/" .. info.total ..
        " (" .. info.remaining .. " remaining)")
  end

  if ri then
    local room = ri.room()
    log("  Room: " .. (room or "(unknown)"))
    log("  Players: " .. ri.player_count())
    log("  Monsters: " .. ri.monster_count())
  end
end

-- Configuration setters
function M.set_glance_cmd(cmd)
  config.glance_cmd = cmd
end

function M.set_attack_cmd(cmd)
  config.attack_cmd = cmd
end

function M.set_auto_attack(enabled)
  config.auto_attack = enabled
end

-- Register callbacks
function M.on_step(callback)
  table.insert(on_step_callbacks, callback)
end

function M.on_attack(callback)
  table.insert(on_attack_callbacks, callback)
end

function M.on_complete(callback)
  table.insert(on_complete_callbacks, callback)
end

function M.on_skip(callback)
  table.insert(on_skip_callbacks, callback)
end

-- Manual trigger for prompt (if not using pattern trigger)
function M.prompt()
  on_prompt()
end

return M
