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

local state = "idle"    -- idle, stepping, fighting
local prompt_count = 0  -- Count of prompts received (diagnostic only)
local pending_prompts = 0  -- prompts still owed before the current step arrives
local enabled = false   -- Is autostepper active?
local prompt_trigger_id = nil  -- Trigger ID for prompt detection

-- Per-room view of what the room held on arrival.
--
-- The GMCP Room.* packages fire on room entry only: nothing re-emits when a mob
-- dies or a player leaves, and there is no client-initiated refresh. So
-- roominfo.monsters() still lists the mob we just killed for as long as we stand
-- in the room, and a decision loop that re-read it would attack the corpse
-- forever. (The old '=M=' scraper refreshed on every 'glance', which is why this
-- was not needed before.) Instead: seed once per room from roominfo, then prune
-- locally as each target is finished. Every fight removes exactly one monster,
-- so a room is always emptied in a bounded number of fights.
local room_key = nil        -- identity of the room the view below describes
local room_monsters = {}    -- monster names still believed to be standing
local room_players = {}     -- player names seen on arrival
local current_target = nil  -- monster do_attack() is working on

-- Configuration
local config = {
  -- Disabled by default. Under GMCP a glance buys nothing -- Room.* fires on
  -- room entry only and is not re-emitted for one, which is why the local
  -- monster view below exists -- so it survived purely to manufacture a second
  -- prompt for the state machine, and that pair was the cause of the stall
  -- where the stepper sat silent waiting for a prompt that never came.
  -- Set it back to "glance" for a brief-mode player who wants the room text.
  glance_cmd = "",
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

local function copy_names(list)
  local out = {}
  for i, n in ipairs(list or {}) do out[i] = n end
  return out
end

-- roominfo's identity for the room we are standing in. Falls back to the room
-- name, and then to a constant, so an unsynced roominfo seeds the view once
-- rather than on every decision.
local function roominfo_room_key()
  if not ri then return "?" end
  local rid = ri.room_id and ri.room_id()
  if rid then return "id:" .. tostring(rid) end
  local name = ri.room and ri.room()
  if name and name ~= "" then return "name:" .. name end
  return "?"
end

-- Reseed the local view when roominfo says we are somewhere new. Reading
-- roominfo here rather than from its on_room_change callback is deliberate:
-- Room.Info fires that notification before the new room's Room.Contents has
-- been handled, so a callback would seed the previous room's occupants.
local function sync_room_view()
  local key = roominfo_room_key()
  if key == room_key then return end
  room_key = key
  room_monsters = copy_names(ri and ri.monsters and ri.monsters())
  room_players = copy_names(ri and ri.players and ri.players())
  current_target = nil
end

-- Strike one occurrence of a finished target from the local view.
local function forget_monster(name)
  if not name then return end
  for i, n in ipairs(room_monsters) do
    if n == name then
      table.remove(room_monsters, i)
      return
    end
  end
end

local process_room  -- forward declaration: on_prompt calls it, it calls do_step

-- Begin waiting for the room we just moved into. One prompt is a whole arrival;
-- the escape-hatch glance adds a second command and therefore a second prompt.
local function begin_arrival_wait()
  state = "stepping"
  pending_prompts = 1
  if config.glance_cmd and config.glance_cmd ~= "" then
    mud.send(config.glance_cmd)
    pending_prompts = pending_prompts + 1
  end
end

local function do_attack(monster)
  state = "fighting"
  current_target = monster
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

  begin_arrival_wait()

  return true
end

function process_room()
  if not ri then
    log("Error: roominfo plugin not available")
    M.stop()
    return
  end

  -- Decisions come from the local per-room view, not from a fresh roominfo
  -- read: the snapshot cannot change while we stand in the room.
  sync_room_view()
  local players = room_players
  local monsters = room_monsters
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

  if state == "stepping" then
    pending_prompts = pending_prompts - 1
    if pending_prompts <= 0 then
      state = "idle"
      process_room()
    end
  elseif state == "fighting" then
    -- Combat ended (or just another prompt). The target is struck from the local
    -- view here because nothing else will: Room.Contents is not re-sent for a
    -- mob that died, so without this the next decision would attack the corpse.
    --
    -- It no longer re-glances. The glance never refreshed anything -- that is
    -- the whole reason this local view exists -- so the decision is made
    -- straight from the pruned view.
    forget_monster(current_target)
    current_target = nil
    state = "idle"
    process_room()
  end
end

--------------------------------------------------------------------------------
-- Aliases
--------------------------------------------------------------------------------

local alias_ids = {}  -- Store alias IDs for the movement shorthands
local command_id = nil

-- require("command") is optional: a profile that never required 'commands' has
-- no registry, and the "-" shorthands still work.
local command
do
  local ok, mod = pcall(require, "command")
  if ok then command = mod end
end

local function show_help()
  log("Commands:")
  log("  -.                     - Start stepping, kill any mob")
  log("  ->                     - Start stepping, only kill targets")
  log("  -!                     - Stop stepping")
  log("  /step status           - Show current status")
  log("  /step set prompt <p>   - Set prompt detection pattern")
  log("  /step set attack [on|off] - Toggle auto-attack")
  log("  /step set glance [cmd]    - Set/show glance command")
  log("  /step set kill [cmd]      - Set/show attack command prefix")
  log("  /step set config       - Show configuration")
end

-- The movement shorthands stay raw aliases: "-", "-.", "->" and "-!" are input
-- syntax, not slash tokens the command registry can express. Everything
-- word-shaped moved to /step.
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
end

local function unregister_aliases()
  for _, id in ipairs(alias_ids) do
    if id then alias.remove(id) end
  end
  alias_ids = {}
end

--------------------------------------------------------------------------------
-- Command
--------------------------------------------------------------------------------

local function show_config()
  log("Configuration:")
  log("  glance_cmd: " .. config.glance_cmd)
  log("  attack_cmd: " .. config.attack_cmd)
  log("  prompt_pattern: " .. (config.prompt_pattern or "(not set)"))
  log("  auto_attack: " .. tostring(config.auto_attack))
  log("  targets_only: " .. tostring(config.targets_only))
end

-- "set" takes a key and an optional value; with no value each key reports what
-- it currently holds, which is what the bare "-set <key>" aliases used to do.
local function dispatch_set(rest)
  local key, value = rest:match("^(%S*)%s*(.-)%s*$")
  key = key:lower()

  if key == "" or key == "help" then
    show_help()
  elseif key == "status" then
    M.status()
  elseif key == "config" then
    show_config()
  elseif key == "prompt" then
    if value == "" then
      log("Usage: /step set prompt <pattern>")
      log("Current: " .. (config.prompt_pattern or "(not set)"))
    else
      M.set_prompt_pattern(value)
    end
  elseif key == "attack" then
    if value == "" then
      log("Auto-attack: " .. (config.auto_attack and "on" or "off"))
    elseif value == "on" or value == "off" then
      config.auto_attack = (value == "on")
      log("Auto-attack " .. (config.auto_attack and "enabled" or "disabled"))
    else
      log("Usage: /step set attack [on|off]")
    end
  elseif key == "glance" then
    if value == "" then
      local shown = (config.glance_cmd == "" or config.glance_cmd == nil)
        and "(disabled)" or config.glance_cmd
      log("glance_cmd: " .. shown)
    else
      config.glance_cmd = value
      log("Glance command set: " .. config.glance_cmd)
    end
  elseif key == "kill" then
    if value == "" then
      log("Attack command: " .. config.attack_cmd)
    else
      config.attack_cmd = value
      log("Attack command set: " .. config.attack_cmd)
    end
  else
    log("Unknown setting: " .. key)
    show_help()
  end
end

local function dispatch(args)
  local sub, rest = tostring(args or ""):match("^%s*(%S*)%s*(.-)%s*$")
  sub = sub:lower()

  if sub == "" or sub == "help" then
    show_help()
  elseif sub == "set" then
    dispatch_set(rest)
  elseif sub == "status" then
    M.status()
  elseif sub == "start" then
    M.start(false)
  elseif sub == "targets" then
    M.start(true)
  elseif sub == "stop" then
    M.stop()
  else
    log("Unknown subcommand: " .. sub)
    show_help()
  end
end

local function register_command()
  if not command then return end
  local id, err = command.register({
    name = "/step",
    aliases = { "/autostepper" },
    usage = "/step [start|targets|stop|status|set <key> [value]]",
    summary = "Automatic speedwalk stepping with optional combat",
    description = "Walks a stored step path one room at a time, optionally "
      .. "glancing and attacking on the way. The shorthands are '-.' to start "
      .. "on any mob, '->' to start on targets only, '-!' to stop, and '-' for "
      .. "help. Settings: status, config, prompt, attack, glance, kill.",
    accepts_args = true,
    handler = dispatch,
  })
  if id then
    command_id = id
  else
    log("command registration failed: " .. tostring(err))
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

  -- Register the movement shorthands and the /step command
  register_aliases()
  register_command()

  log("Loaded (use /step help for commands)")
end

function M.on_unload()
  unregister_aliases()
  unregister_command()

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
  -- Forget any stale view so the room we are standing in is seeded afresh.
  room_key = nil
  current_target = nil

  -- We are standing in a room already, so wait for the next prompt and decide
  -- from it rather than manufacturing one.
  begin_arrival_wait()

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
  pending_prompts = 0
  current_target = nil
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
  log("  Pending prompts: " .. pending_prompts)
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
    -- Two numbers, deliberately: roominfo's is the entry-time snapshot, which
    -- never shrinks while we stand here, and the tracked one is what the
    -- stepping decisions are actually made from.
    log("  Monsters: " .. ri.monster_count() .. " on entry, "
        .. #room_monsters .. " tracked")
    log("  Target: " .. (current_target or "(none)"))
  end
end

-- The per-room monster view stepping decisions are made from. Unlike
-- roominfo.monsters(), it shrinks as targets are finished.
function M.tracked_monsters()
  return copy_names(room_monsters)
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
