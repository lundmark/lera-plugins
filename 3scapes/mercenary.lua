-- Mercenary Stats Plugin for Lera
-- Tracks mercenary statistics from MIP data and provides APIs for UI plugins
-- Based on MercenaryStats plugin for Portal client

local M = {}
M.name = "mercenary"
M.version = "1.0"
M.priority = 50

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local config = {
  auto_use_enabled = false,
  auto_use_ability = "none",
  auto_use_stamina_threshold = 80,  -- percentage
  auto_use_ap_threshold = 80,       -- percentage
  auto_use_cooldown_seconds = 4,    -- minimum seconds between auto-uses (2 rounds)
}

--------------------------------------------------------------------------------
-- Mercenary data
--------------------------------------------------------------------------------

local merc = {
  name = "No Mercenary",

  -- HP stats
  hp_current = 0,
  hp_max = 0,
  hp_percent = 0,

  -- Stamina stats
  stamina_current = 0,
  stamina_max = 0,
  stamina_percent = 0,
  stamina_regen = 0,

  -- AP stats
  ap_current = 0,
  ap_max = 0,
  ap_percent = 0,
  ap_regen = 0,

  -- PL (Permanent Level)
  pl_level = 0,
  pl_xp = 0,
  pl_needed = 0,
  pl_max_level = 150,

  -- IL (Instance Level)
  il_level = 0,
  il_xp = 0,
  il_needed = 0,
  il_max_level = 30,

  -- Combat info
  cost = 0,
  damage_type = "",
  following = false,

  -- Funds
  fund = 0,
  spent = 0,

  -- Target info
  target = "None",
  target_pct = 0,

  -- Abilities
  abilities = "",

  -- Previous values for delta calculation
  prev_hp = 0,
  prev_stamina = 0,
  prev_ap = 0,

  -- Deltas (change since last update)
  hp_delta = 0,
  stamina_delta = 0,
  ap_delta = 0,

  -- XP tracking for rate calculation
  pl_xp_start = 0,
  il_xp_start = 0,
  tracking_start_time = 0,
  pl_xp_per_hour = 0,
  il_xp_per_hour = 0,
  prev_pl_level = 0,
  prev_il_level = 0,

  -- Timestamp of last update
  last_update = 0,
}

-- Auto-use cooldown tracking
local auto_use_last_time = 0

-- MIP handler ref for cleanup
local mip_handler = nil

--------------------------------------------------------------------------------
-- Internal helpers
--------------------------------------------------------------------------------

local function parse_delimited(data, delim)
  local parts = {}
  local start = 1
  delim = delim or "~"
  while true do
    local pos = data:find(delim, start, true)
    if pos then
      table.insert(parts, data:sub(start, pos - 1))
      start = pos + 1
    else
      table.insert(parts, data:sub(start))
      break
    end
  end
  return parts
end

local function current_time()
  return lera.time()
end

-- Color coding based on percentage
-- Returns a color suitable for display (hex RGB string)
local function get_percent_color(current, max)
  local amount = (current or 0) / (max or 100)
  if amount > 0.9 then
    return "19ff25"  -- Bright green
  elseif amount > 0.75 then
    return "1e7523"  -- Dark green
  elseif amount > 0.5 then
    return "f2e935"  -- Yellow
  elseif amount > 0.25 then
    return "ab0000"  -- Dark red
  else
    return "ff0000"  -- Bright red
  end
end

-- Format large numbers (1000 -> 1.0K, 1000000 -> 1.0M)
local function format_number(num)
  if not num or num == 0 then return "0" end

  if num >= 1000000 then
    return string.format("%.1fM", num / 1000000)
  elseif num >= 1000 then
    return string.format("%.1fK", num / 1000)
  else
    return tostring(num)
  end
end

-- Check and execute auto-use ability
local function check_auto_use()
  if not config.auto_use_enabled or config.auto_use_ability == "none" then
    return
  end

  -- Don't try to use abilities if there's no target
  if not merc.target or merc.target == "None" or merc.target == "" then
    return
  end

  -- Check cooldown
  local now = current_time()
  if now - auto_use_last_time < config.auto_use_cooldown_seconds then
    return
  end

  -- Check if thresholds are met
  if merc.stamina_percent >= config.auto_use_stamina_threshold and
     merc.ap_percent >= config.auto_use_ap_threshold then
    -- Send the command
    mud.send("merc use " .. config.auto_use_ability)
    auto_use_last_time = now
  end
end

--------------------------------------------------------------------------------
-- MIP Handler
--------------------------------------------------------------------------------

local function handle_mrc(key, code, data)
  -- Parse tilde-delimited data
  local d = parse_delimited(data)

  -- Expecting 23 elements
  if #d < 23 then
    return
  end

  -- Store previous values for deltas
  merc.prev_hp = merc.hp_current
  merc.prev_stamina = merc.stamina_current
  merc.prev_ap = merc.ap_current
  local prev_pl_level = merc.pl_level
  local prev_il_level = merc.il_level

  -- Parse array data
  merc.hp_current = tonumber(d[1]) or 0
  merc.hp_max = tonumber(d[2]) or 1
  merc.stamina_current = tonumber(d[3]) or 0
  merc.stamina_max = tonumber(d[4]) or 1
  merc.ap_current = tonumber(d[5]) or 0
  merc.ap_max = tonumber(d[6]) or 1
  merc.name = d[7] or "Unknown"

  local target_pct = tonumber(d[8]) or 0
  merc.target_pct = target_pct

  merc.stamina_regen = tonumber(d[9]) or 0
  merc.ap_regen = tonumber(d[10]) or 0
  merc.pl_level = tonumber(d[11]) or 0
  merc.pl_xp = tonumber(d[12]) or 0
  merc.pl_needed = tonumber(d[13]) or 0
  merc.il_level = tonumber(d[14]) or 0
  merc.il_xp = tonumber(d[15]) or 0
  merc.il_needed = tonumber(d[16]) or 0
  merc.cost = tonumber(d[17]) or 0
  merc.damage_type = d[18] or ""
  merc.following = (tonumber(d[19]) == 1)
  merc.fund = tonumber(d[20]) or 0
  merc.spent = tonumber(d[21]) or 0
  merc.target = d[22] or "None"
  merc.abilities = d[23] or ""

  -- Calculate percentages
  if merc.hp_max > 0 then
    merc.hp_percent = math.floor((merc.hp_current / merc.hp_max) * 100)
  else
    merc.hp_percent = 0
  end
  if merc.stamina_max > 0 then
    merc.stamina_percent = math.floor((merc.stamina_current / merc.stamina_max) * 100)
  else
    merc.stamina_percent = 0
  end
  if merc.ap_max > 0 then
    merc.ap_percent = math.floor((merc.ap_current / merc.ap_max) * 100)
  else
    merc.ap_percent = 0
  end

  -- Calculate deltas
  merc.hp_delta = merc.hp_current - merc.prev_hp
  merc.stamina_delta = merc.stamina_current - merc.prev_stamina
  merc.ap_delta = merc.ap_current - merc.prev_ap

  -- Store previous levels
  merc.prev_pl_level = prev_pl_level
  merc.prev_il_level = prev_il_level

  -- Update XP tracking (reset on level up or first run)
  local now = current_time()
  if merc.tracking_start_time == 0 or
     prev_pl_level ~= merc.pl_level or
     prev_il_level ~= merc.il_level then
    merc.tracking_start_time = now
    merc.pl_xp_start = merc.pl_xp
    merc.il_xp_start = merc.il_xp
    merc.pl_xp_per_hour = 0
    merc.il_xp_per_hour = 0
  else
    local elapsed_seconds = now - merc.tracking_start_time
    if elapsed_seconds > 0 then
      local pl_xp_gained = merc.pl_xp - merc.pl_xp_start
      local il_xp_gained = merc.il_xp - merc.il_xp_start

      merc.pl_xp_per_hour = (pl_xp_gained / elapsed_seconds) * 3600
      merc.il_xp_per_hour = (il_xp_gained / elapsed_seconds) * 3600
    end
  end

  merc.last_update = now

  -- Check auto-use ability conditions
  check_auto_use()
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Get all mercenary stats as a table (read-only copy)
function M.get_stats()
  return {
    name = merc.name,

    hp_current = merc.hp_current,
    hp_max = merc.hp_max,
    hp_percent = merc.hp_percent,
    hp_delta = merc.hp_delta,

    stamina_current = merc.stamina_current,
    stamina_max = merc.stamina_max,
    stamina_percent = merc.stamina_percent,
    stamina_regen = merc.stamina_regen,
    stamina_delta = merc.stamina_delta,

    ap_current = merc.ap_current,
    ap_max = merc.ap_max,
    ap_percent = merc.ap_percent,
    ap_regen = merc.ap_regen,
    ap_delta = merc.ap_delta,

    pl_level = merc.pl_level,
    pl_xp = merc.pl_xp,
    pl_needed = merc.pl_needed,
    pl_xp_per_hour = merc.pl_xp_per_hour,
    pl_max_level = merc.pl_max_level,

    il_level = merc.il_level,
    il_xp = merc.il_xp,
    il_needed = merc.il_needed,
    il_xp_per_hour = merc.il_xp_per_hour,
    il_max_level = merc.il_max_level,

    cost = merc.cost,
    damage_type = merc.damage_type,
    following = merc.following,

    fund = merc.fund,
    spent = merc.spent,

    target = merc.target,
    target_pct = merc.target_pct,

    abilities = merc.abilities,

    last_update = merc.last_update,
  }
end

-- Get individual stat values
function M.name() return merc.name end

function M.hp() return merc.hp_current, merc.hp_max, merc.hp_percent end
function M.hp_delta() return merc.hp_delta end

function M.stamina() return merc.stamina_current, merc.stamina_max, merc.stamina_percent end
function M.stamina_regen() return merc.stamina_regen end
function M.stamina_delta() return merc.stamina_delta end

function M.ap() return merc.ap_current, merc.ap_max, merc.ap_percent end
function M.ap_regen() return merc.ap_regen end
function M.ap_delta() return merc.ap_delta end

function M.pl() return merc.pl_level, merc.pl_xp, merc.pl_needed end
function M.pl_rate() return merc.pl_xp_per_hour end

function M.il() return merc.il_level, merc.il_xp, merc.il_needed end
function M.il_rate() return merc.il_xp_per_hour end

function M.cost() return merc.cost end
function M.damage_type() return merc.damage_type end
function M.following() return merc.following end

function M.fund() return merc.fund end
function M.spent() return merc.spent end

function M.target() return merc.target, merc.target_pct end

function M.abilities() return merc.abilities end
function M.abilities_list()
  -- Parse abilities from format "[ability1,ability2,...]"
  local abilities_match = merc.abilities:match("%[(.+)%]")
  if not abilities_match then
    return {}
  end
  local list = {}
  for ability in abilities_match:gmatch("[^,]+") do
    table.insert(list, ability:match("^%s*(.-)%s*$"))  -- trim whitespace
  end
  return list
end

-- Get color for a percentage value (useful for UI rendering)
function M.get_color(current, max)
  return get_percent_color(current, max)
end

-- Get color for target health
function M.target_color()
  return get_percent_color(merc.target_pct, 100)
end

-- Format a number for display (1000 -> 1.0K, etc.)
function M.format_number(num)
  return format_number(num)
end

-- Calculate estimated time to level
-- Returns hours remaining, or nil if not tracking or at max level
function M.pl_time_to_level()
  if merc.pl_level >= merc.pl_max_level then return nil end
  if merc.pl_xp_per_hour <= 0 then return nil end
  local xp_remaining = merc.pl_needed - merc.pl_xp
  return xp_remaining / merc.pl_xp_per_hour
end

function M.il_time_to_level()
  if merc.il_level >= merc.il_max_level then return nil end
  if merc.il_xp_per_hour <= 0 then return nil end
  local xp_remaining = merc.il_needed - merc.il_xp
  return xp_remaining / merc.il_xp_per_hour
end

-- Reset XP tracking (restarts rate calculation)
function M.reset_xp_tracking()
  merc.tracking_start_time = current_time()
  merc.pl_xp_start = merc.pl_xp
  merc.il_xp_start = merc.il_xp
  merc.pl_xp_per_hour = 0
  merc.il_xp_per_hour = 0
end

-- Check if mercenary data has been received
function M.has_data()
  return merc.last_update > 0
end

-- Get tracking duration in seconds
function M.tracking_duration()
  if merc.tracking_start_time == 0 then return 0 end
  return current_time() - merc.tracking_start_time
end

--------------------------------------------------------------------------------
-- Auto-use ability configuration
--------------------------------------------------------------------------------

-- Valid abilities for auto-use
local valid_abilities = {
  "none", "bandage", "mend", "sustain", "fortify", "amplify",
  "critical", "frenzy", "rend", "combo", "aegis", "hamstring",
  "intervene", "cover"
}

function M.auto_use_enabled()
  return config.auto_use_enabled
end

function M.set_auto_use_enabled(enabled)
  config.auto_use_enabled = enabled
end

function M.toggle_auto_use()
  config.auto_use_enabled = not config.auto_use_enabled
  return config.auto_use_enabled
end

function M.auto_use_ability()
  return config.auto_use_ability
end

function M.set_auto_use_ability(ability)
  -- Validate ability name
  for _, valid in ipairs(valid_abilities) do
    if ability == valid then
      config.auto_use_ability = ability
      return true
    end
  end
  return false
end

function M.list_auto_use_abilities()
  return valid_abilities
end

function M.auto_use_stamina_threshold()
  return config.auto_use_stamina_threshold
end

function M.set_auto_use_stamina_threshold(threshold)
  if threshold >= 0 and threshold <= 100 then
    config.auto_use_stamina_threshold = threshold
    return true
  end
  return false
end

function M.auto_use_ap_threshold()
  return config.auto_use_ap_threshold
end

function M.set_auto_use_ap_threshold(threshold)
  if threshold >= 0 and threshold <= 100 then
    config.auto_use_ap_threshold = threshold
    return true
  end
  return false
end

function M.auto_use_cooldown()
  return config.auto_use_cooldown_seconds
end

function M.set_auto_use_cooldown(seconds)
  if seconds >= 0 then
    config.auto_use_cooldown_seconds = seconds
    return true
  end
  return false
end

-- Get full auto-use config
function M.get_auto_use_config()
  return {
    enabled = config.auto_use_enabled,
    ability = config.auto_use_ability,
    stamina_threshold = config.auto_use_stamina_threshold,
    ap_threshold = config.auto_use_ap_threshold,
    cooldown_seconds = config.auto_use_cooldown_seconds,
  }
end

--------------------------------------------------------------------------------
-- Plugin lifecycle
--------------------------------------------------------------------------------

function M.on_load()
  -- Load saved config from disk
  store.load()
  local data = store.get()
  if data then
    if data.auto_use_enabled ~= nil then
      config.auto_use_enabled = data.auto_use_enabled
    end
    if data.auto_use_ability then
      -- Validate stored ability
      local valid = false
      for _, ab in ipairs(valid_abilities) do
        if data.auto_use_ability == ab then
          valid = true
          break
        end
      end
      if valid then
        config.auto_use_ability = data.auto_use_ability
      end
    end
    if data.auto_use_stamina_threshold then
      config.auto_use_stamina_threshold = data.auto_use_stamina_threshold
    end
    if data.auto_use_ap_threshold then
      config.auto_use_ap_threshold = data.auto_use_ap_threshold
    end
    if data.auto_use_cooldown_seconds then
      config.auto_use_cooldown_seconds = data.auto_use_cooldown_seconds
    end
  end

  -- Register MIP handler for mercenary data
  mip_handler = mip.on("MRC", handle_mrc)
end

function M.on_unload()
  -- Unregister MIP handler
  if mip_handler then
    mip.off(mip_handler)
    mip_handler = nil
  end

  -- Save config to disk
  store.set({
    auto_use_enabled = config.auto_use_enabled,
    auto_use_ability = config.auto_use_ability,
    auto_use_stamina_threshold = config.auto_use_stamina_threshold,
    auto_use_ap_threshold = config.auto_use_ap_threshold,
    auto_use_cooldown_seconds = config.auto_use_cooldown_seconds,
  })
  store.save()
end

return M
