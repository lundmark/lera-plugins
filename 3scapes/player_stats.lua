-- Player Stats Plugin for Lera
-- Extracts player stats from MIP FFF (composite) messages
-- Provides API for UI plugins to access player HP, SP, GP, and combat info

local M = {}
M.name = "player_stats"
M.version = "1.0"
M.priority = 40  -- Run early to parse MIP data

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local player = {
  -- HP
  hp = 0,
  hp_max = 0,
  hp_percent = 0,

  -- SP (Spell Points)
  sp = 0,
  sp_max = 0,
  sp_percent = 0,

  -- GP1 (Guild Points 1)
  gp1 = 0,
  gp1_max = 0,
  gp1_percent = 0,
  gp1_label = "GP1",

  -- GP2 (Guild Points 2)
  gp2 = 0,
  gp2_max = 0,
  gp2_percent = 0,
  gp2_label = "GP2",

  -- Guild info lines
  gline1 = "",
  gline2 = "",

  -- Combat info
  attacker = "",        -- Name of monster being fought
  attacker_hp = 0,      -- % HP of attacker
  attacker_image = "",  -- Image file for attacker

  -- Deltas
  hp_delta = 0,
  sp_delta = 0,
  gp1_delta = 0,
  gp2_delta = 0,

  -- Previous values for delta
  prev_hp = 0,
  prev_sp = 0,
  prev_gp1 = 0,
  prev_gp2 = 0,

  -- Timestamp
  last_update = 0,
}

-- Label masks
local hp_label = "HP"
local sp_label = "SP"

-- MIP handler ref
local mip_handlers = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function calc_percent(current, max)
  if max <= 0 then return 0 end
  return math.floor((current / max) * 100)
end

-- Color based on percentage
local function get_percent_color(pct)
  if pct > 90 then
    return "19ff25"  -- Bright green
  elseif pct > 75 then
    return "1e7523"  -- Dark green
  elseif pct > 50 then
    return "f2e935"  -- Yellow
  elseif pct > 25 then
    return "ab0000"  -- Dark red
  else
    return "ff0000"  -- Bright red
  end
end

--------------------------------------------------------------------------------
-- MIP Handlers
--------------------------------------------------------------------------------

-- FFF - Composite stats (HP, SP, GP, attacker info)
-- Format: CODE~VALUE~CODE~VALUE~... (tilde-separated pairs)
local function handle_fff(key, code, data)
  -- Debug: see raw MIP data (comment out when done debugging)
  -- print("[player_stats] FFF data: " .. data)

  -- Store previous values
  player.prev_hp = player.hp
  player.prev_sp = player.sp
  player.prev_gp1 = player.gp1
  player.prev_gp2 = player.gp2

  -- Split by tilde
  local parts = {}
  for part in (data .. "~"):gmatch("([^~]*)~") do
    table.insert(parts, part)
  end

  -- Parse pairs: CODE, VALUE, CODE, VALUE, ...
  local i = 1
  while i < #parts do
    local field_code = parts[i]
    local value = parts[i + 1] or ""
    i = i + 2

    -- Handle each code
    if field_code == "A" then
      player.hp = tonumber(value) or 0
    elseif field_code == "B" then
      player.hp_max = tonumber(value) or 0
    elseif field_code == "C" then
      player.sp = tonumber(value) or 0
    elseif field_code == "D" then
      player.sp_max = tonumber(value) or 0
    elseif field_code == "E" then
      player.gp1 = tonumber(value) or 0
    elseif field_code == "F" then
      player.gp1_max = tonumber(value) or 0
    elseif field_code == "G" then
      player.gp2 = tonumber(value) or 0
    elseif field_code == "H" then
      player.gp2_max = tonumber(value) or 0
    elseif field_code == "I" then
      player.gline1 = value
    elseif field_code == "J" then
      player.gline2 = value
    elseif field_code == "K" then
      player.attacker = value
    elseif field_code == "L" then
      player.attacker_hp = tonumber(value) or 0
    elseif field_code == "M" then
      player.attacker_image = value
    end
  end

  -- Calculate percentages
  player.hp_percent = calc_percent(player.hp, player.hp_max)
  player.sp_percent = calc_percent(player.sp, player.sp_max)
  player.gp1_percent = calc_percent(player.gp1, player.gp1_max)
  player.gp2_percent = calc_percent(player.gp2, player.gp2_max)

  -- Calculate deltas
  player.hp_delta = player.hp - player.prev_hp
  player.sp_delta = player.sp - player.prev_sp
  player.gp1_delta = player.gp1 - player.prev_gp1
  player.gp2_delta = player.gp2 - player.prev_gp2

  player.last_update = lera.time()
end

-- BBA - GP1 label mask
local function handle_bba(key, code, data)
  if data and #data > 0 then
    player.gp1_label = data
  end
end

-- BBB - GP2 label mask
local function handle_bbb(key, code, data)
  if data and #data > 0 then
    player.gp2_label = data
  end
end

-- BBC - HP label mask
local function handle_bbc(key, code, data)
  if data and #data > 0 then
    hp_label = data
  end
end

-- BBD - SP label mask
local function handle_bbd(key, code, data)
  if data and #data > 0 then
    sp_label = data
  end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Get all stats as a table
function M.get_stats()
  return {
    hp = player.hp,
    hp_max = player.hp_max,
    hp_percent = player.hp_percent,
    hp_delta = player.hp_delta,
    hp_label = hp_label,

    sp = player.sp,
    sp_max = player.sp_max,
    sp_percent = player.sp_percent,
    sp_delta = player.sp_delta,
    sp_label = sp_label,

    gp1 = player.gp1,
    gp1_max = player.gp1_max,
    gp1_percent = player.gp1_percent,
    gp1_delta = player.gp1_delta,
    gp1_label = player.gp1_label,

    gp2 = player.gp2,
    gp2_max = player.gp2_max,
    gp2_percent = player.gp2_percent,
    gp2_delta = player.gp2_delta,
    gp2_label = player.gp2_label,

    gline1 = player.gline1,
    gline2 = player.gline2,

    attacker = player.attacker,
    attacker_hp = player.attacker_hp,
    attacker_image = player.attacker_image,

    last_update = player.last_update,
  }
end

-- Individual accessors
function M.hp() return player.hp, player.hp_max, player.hp_percent end
function M.hp_delta() return player.hp_delta end
function M.hp_label() return hp_label end

function M.sp() return player.sp, player.sp_max, player.sp_percent end
function M.sp_delta() return player.sp_delta end
function M.sp_label() return sp_label end

function M.gp1() return player.gp1, player.gp1_max, player.gp1_percent end
function M.gp1_delta() return player.gp1_delta end
function M.gp1_label() return player.gp1_label end

function M.gp2() return player.gp2, player.gp2_max, player.gp2_percent end
function M.gp2_delta() return player.gp2_delta end
function M.gp2_label() return player.gp2_label end

function M.gline1() return player.gline1 end
function M.gline2() return player.gline2 end

function M.attacker() return player.attacker, player.attacker_hp end
function M.attacker_image() return player.attacker_image end

function M.in_combat()
  return player.attacker and player.attacker ~= ""
end

-- Color helpers
function M.get_color(pct)
  return get_percent_color(pct)
end

function M.hp_color()
  return get_percent_color(player.hp_percent)
end

function M.sp_color()
  return get_percent_color(player.sp_percent)
end

function M.attacker_color()
  return get_percent_color(player.attacker_hp)
end

-- Check if we have data
function M.has_data()
  return player.last_update > 0
end

-- Clear attacker (useful when combat ends)
function M.clear_attacker()
  player.attacker = ""
  player.attacker_hp = 0
  player.attacker_image = ""
end

--------------------------------------------------------------------------------
-- Plugin lifecycle
--------------------------------------------------------------------------------

function M.on_load()
  -- Register MIP handlers
  table.insert(mip_handlers, mip.on("FFF", handle_fff))
  table.insert(mip_handlers, mip.on("BBA", handle_bba))
  table.insert(mip_handlers, mip.on("BBB", handle_bbb))
  table.insert(mip_handlers, mip.on("BBC", handle_bbc))
  table.insert(mip_handlers, mip.on("BBD", handle_bbd))
end

function M.on_unload()
  -- Unregister MIP handlers
  for _, handler_id in ipairs(mip_handlers) do
    mip.off(handler_id)
  end
  mip_handlers = {}
end

return M
