-- Player Stats Plugin for Lera
--
-- GMCP-fed. Char.Vitals carries hp/sp with their maxima, encumbrance, the
-- morgue-coffin counts and the player's guild; Char.Combat carries the attacker
-- block. Provides an API for UI plugins (stats_window's player block,
-- guild_druid's HP bar) to read player state.
--
-- This plugin used to parse MIP FFF/BBA/BBB/BBC/BBD and had no GMCP path at
-- all, which is why it was dropped from every MIP-free profile. Two fields did
-- not survive the move and were removed rather than faked:
--
--   gp1/gp2 + gline1/gline2  MIP FFF and the GLINE keys. There is no generic
--                            GMCP source: guild points are guild-specific, and
--                            the only emitter is the Viking guild's Guild.State
--                            (bars.gp1/gp2), which guild_viking already owns.
--   attacker_image           MIP-only; nothing in this tree ever read it.
--
-- Nothing in the repo consumed any of them.

local M = {}
M.name = "player_stats"
M.version = "2.0"
M.priority = 40  -- Run early so UI plugins see fresh state

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local player = {
  hp = 0, hp_max = 0, hp_percent = 0,
  sp = 0, sp_max = 0, sp_percent = 0,

  -- Char.Vitals extras. Carried because the payload already has them and a
  -- consumer would otherwise have to subscribe to Char.Vitals separately.
  enc = 0,
  coffin = 0,
  coffin_max = 0,
  guild = "",

  -- Char.Combat
  attacker = "",
  attacker_hp = 0,
  rounds = 0,

  hp_delta = 0,
  sp_delta = 0,
  prev_hp = 0,
  prev_sp = 0,

  last_update = 0,
}

-- Label masks. Kept as module state (not payload-driven) because GMCP carries
-- no label for either pool; stats_window reads them through get_stats().
local hp_label = "HP"
local sp_label = "SP"

local handler_ids = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function calc_percent(current, max)
  if max <= 0 then return 0 end
  return math.floor((current / max) * 100)
end

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

local function num(value, fallback)
  return tonumber(value) or fallback or 0
end

--------------------------------------------------------------------------------
-- GMCP handlers
--------------------------------------------------------------------------------

-- Char.Vitals: { hp, maxhp, sp, maxsp, enc, coffin, coffin_max, guild }.
-- The server sends a complete snapshot (its delta step decides *whether* to
-- send, never *what* to send), so every field is read on every frame rather
-- than merged -- unlike the Merc.* and Guild.* namespaces, which page deltas.
local function on_vitals(_, data)
  if type(data) ~= "table" then return end

  player.prev_hp = player.hp
  player.prev_sp = player.sp

  player.hp = num(data.hp)
  player.hp_max = num(data.maxhp)
  player.sp = num(data.sp)
  player.sp_max = num(data.maxsp)
  player.enc = num(data.enc)
  player.coffin = num(data.coffin)
  player.coffin_max = num(data.coffin_max)
  if type(data.guild) == "string" then player.guild = data.guild end

  player.hp_percent = calc_percent(player.hp, player.hp_max)
  player.sp_percent = calc_percent(player.sp, player.sp_max)

  -- Deltas are meaningless against a never-populated baseline, so the first
  -- frame reports zero rather than the full value as a gain.
  if player.last_update > 0 then
    player.hp_delta = player.hp - player.prev_hp
    player.sp_delta = player.sp - player.prev_sp
  else
    player.hp_delta = 0
    player.sp_delta = 0
  end

  player.last_update = os.time()
  ui.dirty()
end

-- Char.Combat: { attacker, attacker_hp, rounds }. Field names match this
-- plugin's own, which is why no renaming happens here.
local function on_combat(_, data)
  if type(data) ~= "table" then return end

  if type(data.attacker) == "string" then player.attacker = data.attacker end
  if data.attacker_hp ~= nil then player.attacker_hp = num(data.attacker_hp) end
  if data.rounds ~= nil then player.rounds = num(data.rounds) end

  ui.dirty()
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

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

    enc = player.enc,
    coffin = player.coffin,
    coffin_max = player.coffin_max,
    guild = player.guild,

    attacker = player.attacker,
    attacker_hp = player.attacker_hp,
    rounds = player.rounds,

    last_update = player.last_update,
  }
end

function M.hp() return player.hp, player.hp_max, player.hp_percent end
function M.hp_delta() return player.hp_delta end
function M.hp_label() return hp_label end

function M.sp() return player.sp, player.sp_max, player.sp_percent end
function M.sp_delta() return player.sp_delta end
function M.sp_label() return sp_label end

function M.enc() return player.enc end
function M.coffin() return player.coffin, player.coffin_max end
function M.guild() return player.guild end

function M.attacker() return player.attacker, player.attacker_hp end
function M.rounds() return player.rounds end

function M.in_combat()
  return player.attacker ~= nil and player.attacker ~= ""
end

function M.get_color(pct) return get_percent_color(pct) end
function M.hp_color() return get_percent_color(player.hp_percent) end
function M.sp_color() return get_percent_color(player.sp_percent) end
function M.attacker_color() return get_percent_color(player.attacker_hp) end

function M.has_data()
  return player.last_update > 0
end

-- Combat end is not always announced, so consumers that detect it themselves
-- (guild_druid does) can clear the block.
function M.clear_attacker()
  player.attacker = ""
  player.attacker_hp = 0
  player.rounds = 0
end

--------------------------------------------------------------------------------
-- Plugin lifecycle
--------------------------------------------------------------------------------

function M.on_load()
  handler_ids[#handler_ids + 1] = gmcp.on("Char.Vitals", on_vitals)
  handler_ids[#handler_ids + 1] = gmcp.on("Char.Combat", on_combat)
end

function M.on_unload()
  for _, id in ipairs(handler_ids) do
    gmcp.remove(id)
  end
  handler_ids = {}
end

return M
