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

local function log(msg)
  print("[autostepper] " .. msg)
end

local sw = nil      -- speedwalk plugin (set in on_load)
local ri = nil      -- roominfo plugin (set in on_load)
local explore = require("explore.mode")

-- Area profiles, by name. A profile is data plus four predicates; no engine
-- logic lives in one.
local AREAS = {
  chaossea = "areas.chaossea",
}
local area_cache = {}

local function load_area(name)
  if area_cache[name] then return area_cache[name] end
  local path = AREAS[name]
  if not path then return nil end
  local ok, mod = pcall(require, path)
  if not ok then
    log("area '" .. name .. "' failed to load: " .. tostring(mod))
    return nil
  end
  area_cache[name] = mod
  return mod
end

-- Test seam: swap the explore module for a stand-in.
function M.debug_set_explore(stub)
  explore = stub or require("explore.mode")
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local state = "idle"    -- idle, stepping, fighting
local prompt_count = 0  -- Count of prompts received (diagnostic only)
local pending_prompts = 0  -- prompts still owed before the current step arrives
local enabled = false   -- Is autostepper active?
local prompt_trigger_id = nil  -- Trigger ID for prompt detection

-- A Room.Info frame is the semantically exact arrival signal, and it lands
-- before the room text and therefore before the prompt. It is not acted on
-- directly, though: Room.Contents arrives AFTER Room.Info in the same burst, so
-- a decision made in the frame callback would read the previous room's
-- monsters. Settling for a moment lets the whole burst -- including a paged
-- Room.Contents -- land first.
local BURST_SETTLE_MS = 150
local settle_timer = nil
local room_info_sub = nil

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
  explore_policy = "clear",  -- "clear" | "dive"; see explore/map.lua
}

-- Callbacks
local on_step_callbacks = {}      -- Called when a step is taken
local on_attack_callbacks = {}    -- Called when attacking
local on_complete_callbacks = {}  -- Called when route complete
local on_skip_callbacks = {}      -- Called when skipping a monster

--------------------------------------------------------------------------------
-- Internal Functions
--------------------------------------------------------------------------------

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
  -- While exploring, the coordinate is the only usable identity. roominfo's is
  -- not: an area with no room ids reports nil, and its name is the same for a
  -- whole layer, so the key would never change and the local monster view would
  -- never reseed between rooms.
  if explore and explore.active() then
    local key = explore.room_key()
    if key then return key end
  end
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

local function cancel_settle()
  if settle_timer then
    timer.cancel(settle_timer)
    settle_timer = nil
  end
end

-- The single place an arrival is committed, from either signal. Idempotent:
-- whichever lands second finds state ~= "stepping" and does nothing.
local function complete_arrival()
  if not enabled or state ~= "stepping" then return end
  cancel_settle()
  pending_prompts = 0
  state = "idle"
  if explore and explore.active() then explore.on_arrival() end
  process_room()
end

-- Two separate jobs, deliberately gated separately. Feeding the explorer is
-- information: a frame describes the room we are standing in whether or not a
-- step is outstanding, and the frames that arrive while the stepper is idle are
-- the ones that matter most -- the entry room's, seen when the player walks into
-- the area before explore mode is even started. Arming the arrival settle timer
-- is the other job, and that only means anything while a step is outstanding.
local function on_room_info_frame()
  if explore and explore.active() and explore.on_frame and ri and ri.info then
    explore.on_frame(ri.info())
  end
  if not enabled or state ~= "stepping" then return end
  if settle_timer then return end
  settle_timer = timer.after(BURST_SETTLE_MS, function()
    settle_timer = nil
    complete_arrival()
  end)
end

-- Begin waiting for the room we just moved into. One prompt is a whole arrival;
-- the escape-hatch glance adds a second command and therefore a second prompt.
local function begin_arrival_wait()
  cancel_settle()
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
  -- After attack, a prompt ends the fight and the next decision follows
  -- straight from the pruned view -- there is no glance any more.
end

local function do_step()
  local step
  if explore and explore.active() then
    step = explore.next_step()
    if not step then
      -- Every reachable exit leads somewhere already mapped. The area is fully
      -- explored and nothing completed the run. It must NOT fall through to
      -- sw.take_step(): the stepper would silently start walking a stored
      -- speedwalk path from wherever it happens to be standing in the maze.
      log("Explored: no unvisited exits remain")
      enabled = false
      state = "idle"
      cancel_settle()
      -- Exhaustion ends the RUN, not just the stepping (6.5). Left active, the
      -- next "-." would re-enter explore mode, instantly re-exhaust the same
      -- map and never reach route mode at all.
      if explore.stop then explore.stop() end
      notify(on_complete_callbacks)
      return false
    end
  else
    step = sw.take_step()
    if not step then
      log("Route complete!")
      enabled = false
      state = "idle"
      cancel_settle()
      notify(on_complete_callbacks)
      return false
    end
  end

  log("Step: " .. step.raw)
  notify(on_step_callbacks, step.raw, sw and sw.step_info and sw.step_info())

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
      complete_arrival()
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
  log("  /step explore [area]   - Start explore mode in an area (default: chaossea)")
  log("  /step explore off      - Stop explore mode")
  log("  /step set prompt <p>   - Set prompt detection pattern")
  log("  /step set attack [on|off] - Toggle auto-attack")
  log("  /step set glance [cmd]    - Set/show glance command")
  log("  /step set kill [cmd]      - Set/show attack command prefix")
  log("  /step set dive [on|off]   - Toggle explore dive policy")
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
  elseif key == "dive" then
    if value == "" then
      log("dive: " .. (config.explore_policy == "dive" and "on" or "off"))
    else
      config.explore_policy = (value == "on") and "dive" or "clear"
      if explore and explore.active() then explore.set_policy(config.explore_policy) end
      log("dive: " .. (config.explore_policy == "dive" and "on" or "off"))
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
  elseif sub == "explore" then
    local arg = rest:match("^(%S*)")
    if arg == "off" then
      M.explore_stop()
    else
      local area = (arg ~= "" and arg) or "chaossea"
      if M.explore_start(area) then M.start(config.targets_only) end
    end
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
    usage = "/step [start|targets|stop|explore [area]|explore off|status|set <key> [value]]",
    summary = "Automatic speedwalk stepping with optional combat",
    description = "Walks a stored step path one room at a time, optionally "
      .. "glancing and attacking on the way. Or, with 'explore [area]', maps an "
      .. "unmapped area room by room, stopping automatically once every reachable "
      .. "exit leads somewhere already mapped; 'explore off' stops it early. The "
      .. "shorthands are '-.' to start on any mob, '->' to start on targets only, "
      .. "'-!' to stop, and '-' for help. Settings: status, config, prompt, "
      .. "attack, glance, kill, dive.",
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

  if ri and ri.on_room_info then
    room_info_sub = ri.on_room_info(on_room_info_frame)
  end

  -- Register the movement shorthands and the /step command
  register_aliases()
  register_command()

  log("Loaded (use /step help for commands)")
end

function M.on_unload()
  unregister_aliases()
  unregister_command()

  if room_info_sub and ri and ri.off_room_info then
    ri.off_room_info(room_info_sub)
  end
  room_info_sub = nil

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

  local exploring = explore and explore.active()

  if not exploring then
    local place = sw.get_current_place()
    if not place then
      log("Error: current place not set (use .set <place>)")
      return false
    end

    if not sw.load_steps() then
      log("Error: no steps configured for place '" .. place .. "'")
      log("Use speedwalk.configure_place('" .. place .. "', 'n|s|e|w', 'target1,target2')")
      return false
    end

    local info = sw.step_info()
    local targets = sw.get_targets()
    config.targets_only = targets_only or false
    local mode_label = config.targets_only and "targets only" or "any mob"
    log("Starting at '" .. place .. "': " .. info.total .. " steps (" .. mode_label .. ")")
    if config.targets_only and #targets > 0 then
      log("Targets: " .. table.concat(targets, ", "))
    end
  else
    config.targets_only = targets_only or false
    log("Starting explore run (" .. (explore.stats().policy or "clear") .. ")")
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
  cancel_settle()
  enabled = false
  state = "idle"
  prompt_count = 0
  pending_prompts = 0
  current_target = nil
  -- Explore mode does not outlive the stepper. It is dead reckoned: it believes
  -- it knows where it is only because it emitted every move itself. Left active
  -- across a stop, the next "-." resumes that reckoning -- and the combat that
  -- goes with it -- wherever the player is now standing, which after walking
  -- out of the area is anywhere at all.
  if explore and explore.active() and explore.stop then explore.stop() end
end

function M.explore_start(area_name)
  local prof = load_area(area_name)
  if not prof then
    log("Unknown area '" .. tostring(area_name) .. "'")
    return false
  end
  explore.attach(ri)
  if not explore.start(prof, config.explore_policy) then
    log("Explore mode failed to start")
    return false
  end
  log("Explore mode active: " .. prof.name)
  return true
end

function M.explore_stop()
  if explore and explore.active() then
    explore.stop()
    log("Explore mode off")
  end
  M.stop()
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

  if explore and explore.active() then
    local s = explore.stats()
    log("  Explore: " .. (s.policy or "clear") .. ", " .. s.rooms .. " rooms, "
        .. "at " .. s.x .. "," .. s.y .. "," .. s.z
        .. (s.layer and (" (layer " .. s.layer .. ")") or ""))
    log("  Desyncs: " .. tostring(explore.desyncs and explore.desyncs() or 0))
  end

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
