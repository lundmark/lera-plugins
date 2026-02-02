-- Guild Druid Plugin for Lera
-- Parses druid-specific stats from custom sethp format
-- Provides automation for spells, drench, totem, lifskraftla
-- Integrates with stats_window via render_guild_stats()

local M = {}
M.name = "guild_druid"
M.version = "1.0"
M.priority = 45  -- Run after player_stats (40) but before stats_window (100)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local druid = {
  -- Casting (Line 1)
  casting_spell = "",
  casting_duration = 0,
  spell_queue = "",

  -- Vitals (Line 2) - WP, pain, raud only (HP/SP from player_stats)
  wp = 0, wp_max = 0,
  pain = "Unbothered",
  raud = 0, raud_max = 0,

  -- Druid-specific (Line 3)
  cadaverous = 0, cadaverous_max = 0,  -- Cadaverous rebirth
  verdant = 0, verdant_max = 0,        -- Verdant communion points
  sickle_text = "dry",                 -- Raw sickle drench text
  drench = 0,                          -- Sickle drench level 0-10
  focus = 0, focus_max = 0,
  blood = 0,                           -- Blood reservoir

  -- GXP (Line 4)
  gxp = {0, 0, 0, 0, 0},
  gxp_prev = {0, 0, 0, 0, 0},
  session_gxp = {0, 0, 0, 0, 0},
  gtnl = 0,
  enemy_name = "",

  -- Lingering spells (Line 5)
  lingering = {},  -- Array of {spell=name, duration=secs, max_duration=secs}

  -- Combat state
  in_combat = false,
  hp_received = false,  -- Have we received at least one hp update?

  -- Timestamp
  last_update = 0,
}

--------------------------------------------------------------------------------
-- Automation Configuration
--------------------------------------------------------------------------------

local auto = {
  enabled = false,  -- Master toggle

  spells = {
    vern = { enabled = false },   -- Auto-renew vern buff
    vd = { enabled = false },     -- Verdant destruction
    vg = { enabled = false },     -- Verdant growth
    dhj = { enabled = false },    -- Divine healing journey
    ht = { enabled = false },     -- Heal trauma
    hr = { enabled = false },     -- Holy restoration
    fk = { enabled = false },     -- Focused kill
    skug = { enabled = false },   -- Blood attack
    krm = { enabled = false },    -- Karma
  },

  lifskraftla = false,  -- Cast near combat end

  drench = {
    enabled = false,
    threshold = 10,     -- Drench when below this
    min_hp = 4000,      -- Min HP to drench
    command = "bloodlet sickle with self",
  },

  totem = {
    enabled = false,
    drop_in_combat = true,
  },

  hvile_wp_threshold = 120000,  -- Cast hvile if WP below after combat

  -- Kill trigger integration
  sync_killers = true,  -- Sync killers on/off with dauto all
}

-- Track totem state
local totem_dropped = false

-- Trigger IDs for cleanup
local trigger_ids = {}

-- Alias IDs for cleanup
local alias_ids = {}

--------------------------------------------------------------------------------
-- Drench Color Scale
--------------------------------------------------------------------------------

local drench_colors = {
  [0] = "d3d3d3",   -- Dry: light gray
  [1] = "ffb3b3",   -- Faint: light pink
  [2] = "ff9999",
  [3] = "ff8080",
  [4] = "ff6666",
  [5] = "ff4d4d",   -- Half: medium red
  [6] = "ff3333",
  [7] = "ff1a1a",
  [8] = "e60000",
  [9] = "cc0000",
  [10] = "b30000",  -- Drenched: dark red
}

--------------------------------------------------------------------------------
-- ANSI Color Helpers
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

-- Convert hex RGB to ANSI 256 color escape
local function hex_to_ansi(hex)
  local r = tonumber(hex:sub(1, 2), 16) or 0
  local g = tonumber(hex:sub(3, 4), 16) or 0
  local b = tonumber(hex:sub(5, 6), 16) or 0

  local function to_cube(v) return math.floor(v / 51 + 0.5) end
  local cr, cg, cb = to_cube(r), to_cube(g), to_cube(b)
  local index = 16 + (36 * cr) + (6 * cg) + cb

  return "\027[38;5;" .. index .. "m"
end

-- Get color for percentage
local function pct_color(pct)
  if pct > 90 then return colors.bright_green
  elseif pct > 75 then return colors.green
  elseif pct > 50 then return colors.yellow
  elseif pct > 25 then return colors.red
  else return colors.bright_red
  end
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function format_num(n)
  if n >= 10000 then
    return string.format("%.0fk", n / 1000)
  elseif n >= 1000 then
    return string.format("%.1fk", n / 1000)
  else
    return tostring(n)
  end
end

-- Draw a mini bar for tight spaces: [|||...]
local function draw_mini_bar(current, max, width)
  if max <= 0 then max = 1 end
  local pct = math.floor((current / max) * 100)
  local filled = math.floor((current / max) * width + 0.5)
  if filled > width then filled = width end
  if filled < 0 then filled = 0 end

  local bar_color = pct_color(pct)
  local empty_color = colors.dim

  return bar_color .. string.rep("|", filled) ..
         empty_color .. string.rep(".", width - filled) .. colors.reset
end

-- Truncate string to width
local function trunc(s, w)
  if #s <= w then return s end
  return s:sub(1, w - 1) .. "~"
end

--------------------------------------------------------------------------------
-- Parse Lingering Spells
--------------------------------------------------------------------------------

-- Parse lingering spell string like "vern:[1/30/30] vg:15"
local function parse_lingering(str)
  local spells = {}
  if not str or str == "" then return spells end

  -- Match patterns like "spell:[cur/dur/max]" or "spell:dur"
  for spell, rest in str:gmatch("(%w+):(%S+)") do
    local cur, dur, max = rest:match("%[(%d+)/(%d+)/(%d+)%]")
    if cur and dur and max then
      table.insert(spells, {
        spell = spell,
        current = tonumber(cur),
        duration = tonumber(dur),
        max_duration = tonumber(max),
      })
    else
      -- Simple format: spell:duration
      local duration = tonumber(rest)
      if duration then
        table.insert(spells, {
          spell = spell,
          duration = duration,
          current = duration,
          max_duration = duration,
        })
      end
    end
  end

  return spells
end

--------------------------------------------------------------------------------
-- Automation Logic
--------------------------------------------------------------------------------

local function check_automation()
  if not auto.enabled then return end
  if not druid.hp_received then return end

  -- Get player_stats for HP info
  local player_stats = plugin.get("player_stats")
  if not player_stats then return end

  local stats = player_stats.get_stats()
  local in_combat = stats.attacker and stats.attacker ~= ""

  -- Update combat state
  local was_in_combat = druid.in_combat
  druid.in_combat = in_combat

  -- Combat just started
  if in_combat and not was_in_combat then
    totem_dropped = false
  end

  -- Drop totem at combat start
  if auto.totem.enabled and auto.totem.drop_in_combat and in_combat and not totem_dropped then
    mud.send("drop totem")
    totem_dropped = true
  end

  -- Combat just ended
  if was_in_combat and not in_combat then
    -- Cast hvile if WP is low
    if druid.wp < auto.hvile_wp_threshold and druid.wp_max > 0 then
      mud.send("hvile")
    end
  end

  -- Check drench automation
  if auto.drench.enabled and in_combat then
    if druid.drench < auto.drench.threshold and stats.hp >= auto.drench.min_hp then
      mud.send(auto.drench.command)
    end
  end

  -- Check spell automation (only cast if not already lingering)
  for spell_name, spell_config in pairs(auto.spells) do
    if spell_config.enabled then
      -- Check if spell is already active
      local is_active = false
      for _, ling in ipairs(druid.lingering) do
        if ling.spell == spell_name then
          is_active = true
          break
        end
      end

      -- Check if spell is in queue
      local in_queue = druid.spell_queue:find(spell_name) ~= nil

      -- Cast if not active and not queued
      if not is_active and not in_queue and druid.casting_spell ~= spell_name then
        mud.send(spell_name)
      end
    end
  end

  -- Lifskraftla near end of combat
  if auto.lifskraftla and in_combat and stats.attacker_hp <= 15 then
    mud.send("lifskraftla")
  end
end

--------------------------------------------------------------------------------
-- HP Bar Rendering (matches original plugin format)
--------------------------------------------------------------------------------

-- Get color for percentage (returns hex RGB)
local function pct_to_hex(pct)
  if pct > 90 then return "19ff25"      -- Bright green
  elseif pct > 75 then return "1e7523"  -- Dark green
  elseif pct > 50 then return "f2e935"  -- Yellow
  elseif pct > 25 then return "ffa500"  -- Orange
  else return "ff0000"                   -- Red
  end
end

-- Pain colors from original plugin
local pain_colors = {
  Unbothered = "19ff25",
  Uncomfortable = "19ff25",
  Disturbed = "ffa500",
  Lashes = "ffa500",
  Aches = "f2e935",
  Ripples = "f2e935",
  Pulsating = "1e7523",
  Visions = "1e7523",
  Consumed = "ff0000",
  Bliss = "ff0000",
}

-- Render HP bar to buffer (similar to original plugin format)
local function render_hpbar()
  -- Get player HP/SP from player_stats plugin
  local player_stats = plugin.get("player_stats")
  local hp, hp_max, sp, sp_max = 0, 0, 0, 0
  local attacker, attacker_hp = "", 0

  if player_stats and player_stats.has_data() then
    local stats = player_stats.get_stats()
    hp = stats.hp or 0
    hp_max = stats.hp_max or 0
    sp = stats.sp or 0
    sp_max = stats.sp_max or 0
    attacker = stats.attacker or ""
    attacker_hp = stats.attacker_hp or 0
  end

  -- Drench color
  local drench_col = drench_colors[druid.drench] or drench_colors[0]
  local pain_col = pain_colors[druid.pain] or "b4bd51"

  -- Print casting line first if casting
  if druid.casting_spell ~= "" then
    buffer.color_print(
      nil, "b4bd51", "Casting: ",
      nil, "328da8", druid.casting_spell,
      nil, "b4bd51", "(",
      nil, "328da8", tostring(druid.casting_duration),
      nil, "b4bd51", ") [",
      nil, "328da8", druid.spell_queue,
      nil, "b4bd51", "]"
    )
  end

  -- Main HP line: HP[hp|max(cad/mcad|blood)] PP[sp|max] W[wp|max] P[pain] R[raud|mraud] S[sickle:level]
  buffer.color_print(
    nil, "b4bd51", "HP[",
    nil, pct_to_hex(hp_max > 0 and hp * 100 / hp_max or 100), tostring(hp),
    nil, "b4bd51", "|",
    nil, "328da8", tostring(hp_max),
    nil, "b4bd51", "(",
    nil, "328da8", tostring(druid.cadaverous),
    nil, "b4bd51", "/",
    nil, "328da8", tostring(druid.cadaverous_max),
    nil, "b4bd51", "|",
    nil, "328da8", tostring(druid.blood),
    nil, "b4bd51", ")] PP[",
    nil, pct_to_hex(sp_max > 0 and sp * 100 / sp_max or 100), tostring(sp),
    nil, "b4bd51", "|",
    nil, "328da8", tostring(sp_max),
    nil, "b4bd51", "] W[",
    nil, pct_to_hex(druid.wp_max > 0 and druid.wp * 100 / druid.wp_max or 100), tostring(druid.wp),
    nil, "b4bd51", "|",
    nil, "328da8", tostring(druid.wp_max),
    nil, "b4bd51", "] P[",
    nil, pain_col, druid.pain,
    nil, "b4bd51", "] R[",
    nil, "328da8", tostring(druid.raud),
    nil, "b4bd51", "|",
    nil, "328da8", tostring(druid.raud_max),
    nil, "b4bd51", "] S[",
    nil, drench_col, druid.sickle_text or "dry",
    nil, "b4bd51", ":",
    nil, drench_col, tostring(druid.drench),
    nil, "b4bd51", "]"
  )

  -- GXP line: GXP[g1(+)|g2(+)|...] G2[gtnl] E[enemy:pct] T[session]
  local total_session = 0
  for i = 1, 5 do
    total_session = total_session + druid.session_gxp[i]
  end

  local enemy_str = attacker ~= "" and attacker or "None"
  local enemy_pct = attacker ~= "" and attacker_hp or 0

  buffer.color_print(
    nil, "b4bd51", "GXP[",
    nil, "328da8", tostring(druid.gxp[1]),
    nil, "b4bd51", "|",
    nil, "328da8", tostring(druid.gxp[2]),
    nil, "b4bd51", "|",
    nil, "328da8", tostring(druid.gxp[3]),
    nil, "b4bd51", "|",
    nil, "328da8", tostring(druid.gxp[4]),
    nil, "b4bd51", "|",
    nil, "328da8", tostring(druid.gxp[5]),
    nil, "b4bd51", "] G2[",
    nil, "328da8", tostring(druid.gtnl),
    nil, "b4bd51", "] E[",
    nil, "328da8", enemy_str:sub(1, 10),
    nil, "b4bd51", ":",
    nil, pct_to_hex(enemy_pct), tostring(enemy_pct),
    nil, "b4bd51", "] T[",
    nil, "19ff25", tostring(total_session),
    nil, "b4bd51", "]"
  )

  -- Lingering spells line: LI[ spell[dur] spell dur ]
  if #druid.lingering > 0 then
    local parts = { nil, "b4bd51", "LI[ " }
    for _, l in ipairs(druid.lingering) do
      table.insert(parts, nil)
      table.insert(parts, "19ff25")
      table.insert(parts, l.spell)
      table.insert(parts, nil)
      table.insert(parts, "328da8")
      if l.spell ~= "vern" then
        table.insert(parts, string.format("[%s] ", tostring(l.duration)))
      else
        table.insert(parts, string.format(" %s ", tostring(l.duration)))
      end
    end
    table.insert(parts, nil)
    table.insert(parts, "b4bd51")
    table.insert(parts, "]")
    buffer.color_print(unpack(parts))
  end
end

--------------------------------------------------------------------------------
-- Trigger Handlers
--------------------------------------------------------------------------------

-- Line 1: Casting info
-- Format: "C: vern(2): sl dg" or "C: (0): " when not casting
local function handle_casting(line, spell, duration, queue)
  -- Trim whitespace from spell name
  spell = spell and spell:match("^%s*(.-)%s*$") or ""
  druid.casting_spell = spell
  druid.casting_duration = tonumber(duration) or 0
  druid.spell_queue = queue and queue:match("^%s*(.-)%s*$") or ""
  return nil  -- Gag the line
end

-- Line 2: Vitals
-- H[1234/1500] S[800/900] W[100/150] P[Unbothered] R[50/100]
local function handle_vitals(line, hp, mhp, sp, msp, wp, mwp, pain, raud, mraud)
  -- HP/SP handled by player_stats, we only care about WP, pain, raud
  druid.wp = tonumber(wp) or 0
  druid.wp_max = tonumber(mwp) or 0
  druid.pain = pain or "Unbothered"
  druid.raud = tonumber(raud) or 0
  druid.raud_max = tonumber(mraud) or 0
  return nil  -- Gag the line
end

-- Convert drench text to number (0-10)
-- Sickle drench levels from original plugin
local drench_text_to_num = {
  ["dry"] = 0,
  ["faint"] = 1,
  ["specks"] = 2,
  ["streaks"] = 3,
  ["stained"] = 4,
  ["clings"] = 5,
  ["wetly"] = 6,
  ["thick"] = 7,
  ["caked"] = 8,
  ["sodden"] = 9,
  ["drenched"] = 10,
}

local function parse_drench(val)
  -- Try as number first
  local num = tonumber(val)
  if num then return num end
  -- Try as text
  local lower = val:lower()
  return drench_text_to_num[lower] or 0
end

-- Line 3: Druid stats
-- CD[0/30867] BR[0/55686] S[dry] F[33/33] B[0]
local function handle_druid_stats(line, cd, cdm, vcp, vcpm, drench_val, foc, focm, blood)
  druid.cadaverous = tonumber(cd) or 0
  druid.cadaverous_max = tonumber(cdm) or 0
  druid.verdant = tonumber(vcp) or 0
  druid.verdant_max = tonumber(vcpm) or 0
  druid.sickle_text = drench_val  -- Store raw text for display
  druid.drench = parse_drench(drench_val)
  druid.focus = tonumber(foc) or 0
  druid.focus_max = tonumber(focm) or 0
  druid.blood = tonumber(blood) or 0

  druid.hp_received = true
  druid.last_update = lera.time()

  -- Run automation check after all stats received
  check_automation()

  return nil  -- Gag the line
end

-- Line 4: GXP
-- G: 1234 5678 9012 3456 7890 [12345] EN: giant troll
local function handle_gxp(line, g1, g2, g3, g4, g5, gtnl, enemy)
  -- Store previous values for session tracking
  for i = 1, 5 do
    druid.gxp_prev[i] = druid.gxp[i]
  end

  druid.gxp[1] = tonumber(g1) or 0
  druid.gxp[2] = tonumber(g2) or 0
  druid.gxp[3] = tonumber(g3) or 0
  druid.gxp[4] = tonumber(g4) or 0
  druid.gxp[5] = tonumber(g5) or 0
  druid.gtnl = tonumber(gtnl) or 0
  druid.enemy_name = enemy or ""

  -- Update session GXP (accumulate gains)
  for i = 1, 5 do
    local delta = druid.gxp[i] - druid.gxp_prev[i]
    if delta > 0 then
      druid.session_gxp[i] = druid.session_gxp[i] + delta
    end
  end

  return nil  -- Gag the line
end

-- Line 5: Lingering spells
-- LI(vern:[1/30/30] vg:15)ELI
local function handle_lingering(line, ling_str)
  druid.lingering = parse_lingering(ling_str or "")

  -- This is the last line of sethp output, so render the nice HP bar now
  render_hpbar()

  return nil  -- Gag the line
end

--------------------------------------------------------------------------------
-- Aliases
--------------------------------------------------------------------------------

-- Sync with kill_trigger plugin
local function sync_killers(enabled)
  if not auto.sync_killers then return end

  local kill_trigger = plugin.get("kill_trigger")
  if kill_trigger then
    if enabled then
      kill_trigger.enable()
    else
      kill_trigger.disable()
    end
  end
end

local function show_status()
  print("[druid] Druid Automation Status:")
  print(string.format("  Master: %s", auto.enabled and "ON" or "OFF"))

  -- Show kill_trigger sync status
  local kill_trigger = plugin.get("kill_trigger")
  if kill_trigger then
    print(string.format("  Killers sync: %s (killers: %s)",
      auto.sync_killers and "ON" or "OFF",
      kill_trigger.is_enabled() and "ON" or "OFF"))
  else
    print(string.format("  Killers sync: %s (plugin not loaded)",
      auto.sync_killers and "ON" or "OFF"))
  end
  print("")

  -- Show druid stats if available
  if druid.hp_received then
    print(string.format("  WP: %d/%d  Pain: %s  Raud: %d/%d",
      druid.wp, druid.wp_max, druid.pain, druid.raud, druid.raud_max))
    print(string.format("  Cadaverous: %d/%d  Verdant: %d/%d  Drench: %d/10",
      druid.cadaverous, druid.cadaverous_max, druid.verdant, druid.verdant_max, druid.drench))
    print(string.format("  Focus: %d/%d  Blood: %d",
      druid.focus, druid.focus_max, druid.blood))
    print(string.format("  GXP: %d %d %d %d %d  GTNL: %d",
      druid.gxp[1], druid.gxp[2], druid.gxp[3], druid.gxp[4], druid.gxp[5], druid.gtnl))
    if #druid.lingering > 0 then
      local ling_strs = {}
      for _, l in ipairs(druid.lingering) do
        table.insert(ling_strs, string.format("%s:%d", l.spell, l.duration))
      end
      print("  Lingering: " .. table.concat(ling_strs, " "))
    end
    print("")
  end

  print("  Spell toggles:")
  for spell, cfg in pairs(auto.spells) do
    print(string.format("    %s: %s", spell, cfg.enabled and "ON" or "OFF"))
  end
  print("")

  print(string.format("  Drench: %s (threshold: %d, min_hp: %d)",
    auto.drench.enabled and "ON" or "OFF",
    auto.drench.threshold, auto.drench.min_hp))
  print(string.format("  Totem: %s (drop in combat: %s)",
    auto.totem.enabled and "ON" or "OFF",
    auto.totem.drop_in_combat and "yes" or "no"))
  print(string.format("  Lifskraftla: %s", auto.lifskraftla and "ON" or "OFF"))
  print(string.format("  Hvile WP threshold: %d", auto.hvile_wp_threshold))
end

local function show_help()
  print("[druid] Commands:")
  print("  dauto           - Show status")
  print("  dauto all       - Toggle master automation (syncs killers)")
  print("  dauto <spell>   - Toggle spell auto (vern, vd, vg, dhj, ht, hr, fk, skug, krm)")
  print("  dauto drench    - Toggle drench automation")
  print("  dauto totem     - Toggle totem automation")
  print("  dauto lifsk     - Toggle lifskraftla timing")
  print("  dauto killers   - Toggle killers sync (on/off with dauto all)")
  print("  resetgxp        - Reset session GXP counters")
end

local function register_aliases()
  -- "dauto" - show status and help
  alias_ids[#alias_ids + 1] = alias.add("^dauto$", function()
    show_status()
    print("")
    show_help()
    return nil
  end)

  -- "dauto help" - show help
  alias_ids[#alias_ids + 1] = alias.add("^dauto\\s+help$", function()
    show_help()
    return nil
  end)

  -- "dauto all" - master toggle
  alias_ids[#alias_ids + 1] = alias.add("^dauto\\s+all$", function()
    auto.enabled = not auto.enabled
    print("[druid] Master automation: " .. (auto.enabled and "ON" or "OFF"))
    sync_killers(auto.enabled)
    return nil
  end)

  -- "dauto drench" - toggle drench
  alias_ids[#alias_ids + 1] = alias.add("^dauto\\s+drench$", function()
    auto.drench.enabled = not auto.drench.enabled
    print("[druid] Drench automation: " .. (auto.drench.enabled and "ON" or "OFF"))
    return nil
  end)

  -- "dauto totem" - toggle totem
  alias_ids[#alias_ids + 1] = alias.add("^dauto\\s+totem$", function()
    auto.totem.enabled = not auto.totem.enabled
    print("[druid] Totem automation: " .. (auto.totem.enabled and "ON" or "OFF"))
    return nil
  end)

  -- "dauto lifsk" - toggle lifskraftla
  alias_ids[#alias_ids + 1] = alias.add("^dauto\\s+lifsk$", function()
    auto.lifskraftla = not auto.lifskraftla
    print("[druid] Lifskraftla: " .. (auto.lifskraftla and "ON" or "OFF"))
    return nil
  end)

  -- "dauto killers" - toggle killers sync
  alias_ids[#alias_ids + 1] = alias.add("^dauto\\s+killers$", function()
    auto.sync_killers = not auto.sync_killers
    print("[druid] Killers sync: " .. (auto.sync_killers and "ON" or "OFF"))
    return nil
  end)

  -- "dauto <spell>" - toggle specific spell
  alias_ids[#alias_ids + 1] = alias.add("^dauto\\s+(\\w+)$", function(_, spell)
    spell = spell:lower()
    if auto.spells[spell] then
      auto.spells[spell].enabled = not auto.spells[spell].enabled
      print("[druid] " .. spell .. " auto: " .. (auto.spells[spell].enabled and "ON" or "OFF"))
    else
      print("[druid] Unknown spell: " .. spell)
      print("[druid] Valid spells: vern, vd, vg, dhj, ht, hr, fk, skug, krm")
    end
    return nil
  end)

  -- "resetgxp" - reset session GXP
  alias_ids[#alias_ids + 1] = alias.add("^resetgxp$", function()
    for i = 1, 5 do
      druid.session_gxp[i] = 0
    end
    print("[druid] Session GXP reset")
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
-- Register Triggers
--------------------------------------------------------------------------------

local function register_triggers()
  -- Line 1: Casting info
  -- Format: C: spellname(duration): queue  (e.g., "C: vern(2): sl dg")
  -- When not casting: C: ():
  trigger_ids[#trigger_ids + 1] = trigger.add(
    "^C: ([^(]*)\\((\\d*)\\):\\s*(.*)$",
    handle_casting,
    { omit_from_output = true }
  )

  -- Line 2: Vitals
  -- H[1234/1500] S[800/900] W[100/150] P[Unbothered] R[50/100]
  trigger_ids[#trigger_ids + 1] = trigger.add(
    "^H\\[(\\d+)/(\\d+)\\] S\\[(\\d+)/(\\d+)\\] W\\[(\\d+)/(\\d+)\\] P\\[([^\\]]+)\\] R\\[(\\d+)/(\\d+)\\]",
    handle_vitals,
    { omit_from_output = true }
  )

  -- Line 3: Druid stats
  -- CD[0/30867] BR[0/55686] S[dry] F[33/33] B[0]
  trigger_ids[#trigger_ids + 1] = trigger.add(
    "^CD\\[(\\d+)/(\\d+)\\] BR\\[(\\d+)/(\\d+)\\] S\\[([^\\]]+)\\] F\\[(\\d+)/(\\d+)\\] B\\[(\\d+)\\]",
    handle_druid_stats,
    { omit_from_output = true }
  )

  -- Line 4: GXP
  -- G: 1234 5678 9012 3456 7890 [12345] EN: giant troll
  trigger_ids[#trigger_ids + 1] = trigger.add(
    "^G: (\\d+) (\\d+) (\\d+) (\\d+) (\\d+) \\[(\\d+)\\] EN: (.*)$",
    handle_gxp,
    { omit_from_output = true }
  )

  -- Line 5: Lingering spells
  -- LI(vern:[1/30/30] vg:15)ELI
  trigger_ids[#trigger_ids + 1] = trigger.add(
    "^LI\\((.*)\\)ELI$",
    handle_lingering,
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
-- Public API
--------------------------------------------------------------------------------

-- Get all stats as a table
function M.get_stats()
  return {
    casting_spell = druid.casting_spell,
    casting_duration = druid.casting_duration,
    spell_queue = druid.spell_queue,

    wp = druid.wp,
    wp_max = druid.wp_max,
    pain = druid.pain,
    raud = druid.raud,
    raud_max = druid.raud_max,

    cadaverous = druid.cadaverous,
    cadaverous_max = druid.cadaverous_max,
    verdant = druid.verdant,
    verdant_max = druid.verdant_max,
    drench = druid.drench,
    focus = druid.focus,
    focus_max = druid.focus_max,
    blood = druid.blood,

    gxp = druid.gxp,
    session_gxp = druid.session_gxp,
    gtnl = druid.gtnl,
    enemy_name = druid.enemy_name,

    lingering = druid.lingering,

    in_combat = druid.in_combat,
    last_update = druid.last_update,
  }
end

-- Check if we have data
function M.has_data()
  return druid.hp_received
end

-- Individual accessors
function M.wp()
  return druid.wp, druid.wp_max
end

function M.pain()
  return druid.pain
end

function M.drench_level()
  return druid.drench
end

function M.lingering()
  return druid.lingering
end

function M.in_combat()
  return druid.in_combat
end

-- Check if a specific spell is lingering
function M.has_lingering(spell)
  for _, ling in ipairs(druid.lingering) do
    if ling.spell == spell then
      return true, ling.duration
    end
  end
  return false, 0
end

-- Get drench color (hex RGB)
function M.drench_color()
  local level = druid.drench
  if level < 0 then level = 0 end
  if level > 10 then level = 10 end
  return drench_colors[level]
end

--------------------------------------------------------------------------------
-- Guild Stats Rendering
--------------------------------------------------------------------------------

-- Render druid stats section for stats_window
function M.render_guild_stats(rect, opts)
  opts = opts or {}

  local x, y, w, h
  if type(rect.x) == "function" then
    x, y, w, h = rect:x(), rect:y(), rect:w(), rect:h()
  else
    x, y, w, h = rect.x, rect.y, rect.w, rect.h
  end

  if w <= 0 or h <= 0 then return 0 end
  if not druid.hp_received then return 0 end

  local lines = {}

  -- WP line with bar and pain
  local wp_bar = draw_mini_bar(druid.wp, druid.wp_max, 6)
  local wp_text = string.format("%s %s %s/%s %sP:%s%s",
    colors.cyan .. "WP" .. colors.reset,
    wp_bar,
    format_num(druid.wp),
    format_num(druid.wp_max),
    colors.dim, colors.reset,
    druid.pain)
  table.insert(lines, wp_text)

  -- Raud line with bar
  if druid.raud_max > 0 then
    local raud_bar = draw_mini_bar(druid.raud, druid.raud_max, 6)
    local raud_text = string.format("%s %s %d/%d",
      colors.magenta .. "Rd" .. colors.reset,
      raud_bar,
      druid.raud,
      druid.raud_max)
    table.insert(lines, raud_text)
  end

  -- Cadaverous / Verdant line
  if druid.cadaverous_max > 0 or druid.verdant_max > 0 then
    local cd_vcp_text = string.format("%sCD%s %d/%d  %sVCP%s %d/%d",
      colors.yellow, colors.reset, druid.cadaverous, druid.cadaverous_max,
      colors.green, colors.reset, druid.verdant, druid.verdant_max)
    table.insert(lines, cd_vcp_text)
  end

  -- Drench line with color
  local drench_col = hex_to_ansi(drench_colors[druid.drench] or drench_colors[0])
  local drench_text = string.format("Drench: %s%d/10%s",
    drench_col, druid.drench, colors.reset)
  -- Add blood and focus on same line if space
  drench_text = drench_text .. string.format("  %sB%s:%d  %sF%s:%d/%d",
    colors.red, colors.reset, druid.blood,
    colors.blue, colors.reset, druid.focus, druid.focus_max)
  table.insert(lines, drench_text)

  -- GXP line
  local total_session = 0
  for i = 1, 5 do
    total_session = total_session + druid.session_gxp[i]
  end
  if total_session > 0 or druid.gtnl > 0 then
    local gxp_text = string.format("%sGXP%s +%s  %sTNL%s %s",
      colors.yellow, colors.reset, format_num(total_session),
      colors.dim, colors.reset, format_num(druid.gtnl))
    table.insert(lines, gxp_text)
  end

  -- Lingering spells line
  if #druid.lingering > 0 then
    local ling_parts = {}
    for _, l in ipairs(druid.lingering) do
      table.insert(ling_parts, string.format("%s%s%s:%d",
        colors.bright_cyan, l.spell, colors.reset, l.duration))
    end
    local ling_text = "LI: " .. table.concat(ling_parts, " ")
    -- Truncate if too long
    if #ling_text > w then
      ling_text = ling_text:sub(1, w - 1) .. "~"
    end
    table.insert(lines, ling_text)
  end

  -- Casting line
  if druid.casting_spell ~= "" then
    local cast_text = string.format("%sCast%s: %s (%ds)",
      colors.bright_yellow, colors.reset,
      druid.casting_spell, druid.casting_duration)
    if druid.spell_queue ~= "" then
      cast_text = cast_text .. string.format(" %s[%s]%s",
        colors.dim, druid.spell_queue, colors.reset)
    end
    table.insert(lines, cast_text)
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
-- Plugin Lifecycle
--------------------------------------------------------------------------------

function M.on_load()
  -- Load saved config
  store.load()
  local data = store.get()
  if data and data.auto then
    -- Merge saved automation settings
    if data.auto.enabled ~= nil then
      auto.enabled = data.auto.enabled
    end
    if data.auto.spells then
      for spell, cfg in pairs(data.auto.spells) do
        if auto.spells[spell] then
          auto.spells[spell].enabled = cfg.enabled or false
        end
      end
    end
    if data.auto.lifskraftla ~= nil then
      auto.lifskraftla = data.auto.lifskraftla
    end
    if data.auto.drench then
      if data.auto.drench.enabled ~= nil then
        auto.drench.enabled = data.auto.drench.enabled
      end
      if data.auto.drench.threshold then
        auto.drench.threshold = data.auto.drench.threshold
      end
      if data.auto.drench.min_hp then
        auto.drench.min_hp = data.auto.drench.min_hp
      end
    end
    if data.auto.totem then
      if data.auto.totem.enabled ~= nil then
        auto.totem.enabled = data.auto.totem.enabled
      end
      if data.auto.totem.drop_in_combat ~= nil then
        auto.totem.drop_in_combat = data.auto.totem.drop_in_combat
      end
    end
    if data.auto.hvile_wp_threshold then
      auto.hvile_wp_threshold = data.auto.hvile_wp_threshold
    end
    if data.auto.sync_killers ~= nil then
      auto.sync_killers = data.auto.sync_killers
    end
  end

  -- Register triggers and aliases
  register_triggers()
  register_aliases()

  print("[druid] Loaded - type 'dauto' for status and commands")
end

function M.on_unload()
  -- Unregister triggers and aliases
  unregister_triggers()
  unregister_aliases()

  -- Save config
  store.set({
    auto = {
      enabled = auto.enabled,
      spells = auto.spells,
      lifskraftla = auto.lifskraftla,
      drench = {
        enabled = auto.drench.enabled,
        threshold = auto.drench.threshold,
        min_hp = auto.drench.min_hp,
      },
      totem = {
        enabled = auto.totem.enabled,
        drop_in_combat = auto.totem.drop_in_combat,
      },
      hvile_wp_threshold = auto.hvile_wp_threshold,
      sync_killers = auto.sync_killers,
    }
  })
  store.save()
end

function M.on_connect()
  -- Reset state on new connection
  druid.hp_received = false
  druid.in_combat = false
  totem_dropped = false
end

-- Call this after login to configure sethp format
function M.setup()
  mud.send("sethp C: $CNAME$($CASTT$): $QUEUE$$NL$H[$HP$/$MHP$] S[$SP$/$MSP$] W[$WI$/$MWI$] P[$PP$] R[$RD$/$MRD$]$NL$CD[$CRB$/$CRBM$] BR[$VCP$/$VCPM$] S[$DRE$] F[$FOC$/$MFOC$] B[$BR$]$NL$G: $GXC$ $GXM$ $GXE$ $GXT$ $GXA$ [$GTNL$] EN: $ENN$$NL$LI($LIN$)ELI")
  mud.send("hp")
end

return M
