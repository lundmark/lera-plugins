-- Stats Window Plugin for Lera
-- Renders player and mercenary stats in a compact sidebar panel

local M = {}
M.name = "stats_window"
M.version = "1.0"
M.priority = 100  -- Run late so other plugins have updated stats

--------------------------------------------------------------------------------
-- Dependencies (loaded on demand)
--------------------------------------------------------------------------------

local player_stats = nil
local mercenary = nil
local guild_plugin = nil
local kill_trigger = nil

local guild_names = { "guild_druid" }

-- Let a guild plugin volunteer itself for the guild-stats section (stage-0
-- API; guild_viking registers from on_setup). Resets the cached probe so the
-- next render sees the newcomer.
function M.register_guild(name)
  if type(name) ~= "string" or name == "" then return false end
  guild_plugin = nil
  for _, existing in ipairs(guild_names) do
    if existing == name then return true end
  end
  guild_names[#guild_names + 1] = name
  return true
end

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local config = {
  show_player = true,
  show_mercenary = true,
  show_guild = true,
  show_killers = true,
  show_deltas = true,
  bar_width = 10,  -- Width of progress bars in characters
}

--------------------------------------------------------------------------------
-- ANSI color helpers
--------------------------------------------------------------------------------

local colors = {
  reset = "\027[0m",
  bold = "\027[1m",
  dim = "\027[2m",

  -- Basic colors
  black = "\027[30m",
  red = "\027[31m",
  green = "\027[32m",
  yellow = "\027[33m",
  blue = "\027[34m",
  magenta = "\027[35m",
  cyan = "\027[36m",
  white = "\027[37m",

  -- Bright colors
  bright_red = "\027[91m",
  bright_green = "\027[92m",
  bright_yellow = "\027[93m",
  bright_blue = "\027[94m",
  bright_magenta = "\027[95m",
  bright_cyan = "\027[96m",
  bright_white = "\027[97m",

  -- Background
  bg_black = "\027[40m",
  bg_red = "\027[41m",
  bg_green = "\027[42m",
  bg_yellow = "\027[43m",
  bg_blue = "\027[44m",
}

-- Convert hex RGB to ANSI 256 color (approximate)
local function hex_to_ansi(hex)
  local r = tonumber(hex:sub(1, 2), 16) or 0
  local g = tonumber(hex:sub(3, 4), 16) or 0
  local b = tonumber(hex:sub(5, 6), 16) or 0

  -- Use 256-color mode for better color matching
  -- Convert to 6x6x6 color cube
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

-- Get color for percentage (background)
local function pct_bg_color(pct)
  if pct > 90 then return "\027[48;5;28m"   -- Dark green
  elseif pct > 75 then return "\027[48;5;22m"  -- Darker green
  elseif pct > 50 then return "\027[48;5;136m" -- Dark yellow
  elseif pct > 25 then return "\027[48;5;124m" -- Dark red
  else return "\027[48;5;160m"  -- Bright red bg
  end
end

--------------------------------------------------------------------------------
-- Drawing helpers
--------------------------------------------------------------------------------

-- Draw a compact progress bar: [####----] 75%
local function draw_bar(current, max, width)
  if max <= 0 then max = 1 end
  local pct = math.floor((current / max) * 100)
  local filled = math.floor((current / max) * width + 0.5)
  if filled > width then filled = width end
  if filled < 0 then filled = 0 end

  local bar_color = pct_color(pct)
  local bar = string.rep("#", filled) .. string.rep("-", width - filled)

  return bar_color .. "[" .. bar .. "]" .. colors.reset
end

-- Draw a mini bar for tight spaces: [###]
local function draw_mini_bar(current, max, width, dim)
  if max <= 0 then max = 1 end
  local pct = math.floor((current / max) * 100)
  local filled = math.floor((current / max) * width + 0.5)
  if filled > width then filled = width end
  if filled < 0 then filled = 0 end

  -- A dormant mercenary's pools are frozen for the whole recovery. Drawing
  -- them in their percentage colour makes a stalled bar look live.
  local bar_color = dim and colors.dim or pct_color(pct)
  local empty_color = colors.dim

  return bar_color .. string.rep("|", filled) ..
         empty_color .. string.rep(".", width - filled) .. colors.reset
end

-- Format delta with color
local function format_delta(delta)
  if delta == 0 then return "" end
  if delta > 0 then
    return colors.green .. "+" .. delta .. colors.reset
  else
    return colors.red .. delta .. colors.reset
  end
end

-- Format number compactly (1500 -> 1.5k)
local function format_num(n)
  if n >= 10000 then
    return string.format("%.0fk", n / 1000)
  elseif n >= 1000 then
    return string.format("%.1fk", n / 1000)
  else
    return tostring(n)
  end
end

-- Truncate string to width
local function trunc(s, w)
  if #s <= w then return s end
  return s:sub(1, w - 1) .. "~"
end

--------------------------------------------------------------------------------
-- Render functions
--------------------------------------------------------------------------------

local function player_stat_lines(w)
  if not player_stats then return {} end
  if not player_stats.has_data() then return {} end

  local stats = player_stats.get_stats()
  local lines = {}

  -- HP line
  local hp_label = colors.cyan .. (stats.hp_label or "HP") .. colors.reset
  local hp_text
  if stats.hp_max > 0 then
    local hp_bar = draw_mini_bar(stats.hp, stats.hp_max, 10)
    hp_text = string.format("%s %s %s/%s", hp_label, hp_bar,
      format_num(stats.hp), format_num(stats.hp_max))
  else
    hp_text = string.format("%s %s", hp_label, format_num(stats.hp))
  end
  if config.show_deltas and stats.hp_delta ~= 0 then
    hp_text = hp_text .. " " .. format_delta(stats.hp_delta)
  end
  table.insert(lines, hp_text)

  -- SP line (separate)
  if stats.sp_max > 0 then
    local sp_bar = draw_mini_bar(stats.sp, stats.sp_max, 10)
    local sp_text = string.format("%s %s %s/%s",
      colors.magenta .. (stats.sp_label or "SP") .. colors.reset,
      sp_bar,
      format_num(stats.sp),
      format_num(stats.sp_max))
    if config.show_deltas and stats.sp_delta ~= 0 then
      sp_text = sp_text .. " " .. format_delta(stats.sp_delta)
    end
    table.insert(lines, sp_text)
  elseif stats.sp > 0 then
    local sp_text = string.format("%s %s",
      colors.magenta .. (stats.sp_label or "SP") .. colors.reset,
      format_num(stats.sp))
    table.insert(lines, sp_text)
  end

  -- Monster/Attacker line (always show)
  local mon_label = colors.red .. "MON" .. colors.reset
  if stats.attacker and stats.attacker ~= "" then
    local mon_bar = draw_mini_bar(stats.attacker_hp, 100, 10)
    -- Truncate name to fit
    local max_name_len = w - 20
    if max_name_len < 5 then max_name_len = 5 end
    local atk_name = trunc(stats.attacker, max_name_len)
    local atk_text = string.format("%s %s %s%s%s",
      mon_label, mon_bar,
      colors.bright_white, atk_name, colors.reset)
    table.insert(lines, atk_text)
  else
    local atk_text = string.format("%s %s--%s",
      mon_label, colors.dim, colors.reset)
    table.insert(lines, atk_text)
  end

  return lines
end

local function mercenary_stat_lines(w)
  if not mercenary then return {} end
  if not mercenary.has_data() then return {} end

  local stats = mercenary.get_stats()
  local lines = {}

  local dim = stats.is_dormant == true

  -- Merc name header
  local name = trunc(stats.name or "Mercenary", w - 2)
  table.insert(lines, colors.bright_cyan .. name .. colors.reset)

  -- HP line
  local hp_bar = draw_mini_bar(stats.hp_current, stats.hp_max, 6, dim)
  local hp_text = string.format("%s %s %s/%s",
    colors.cyan .. "HP" .. colors.reset,
    hp_bar,
    format_num(stats.hp_current),
    format_num(stats.hp_max))

  if config.show_deltas and stats.hp_delta ~= 0 then
    hp_text = hp_text .. " " .. format_delta(stats.hp_delta)
  end
  table.insert(lines, hp_text)

  -- Stamina line
  local st_bar = draw_mini_bar(stats.stamina_current, stats.stamina_max, 6, dim)
  local st_text = string.format("%s %s %s/%s",
    colors.yellow .. "ST" .. colors.reset,
    st_bar,
    format_num(stats.stamina_current),
    format_num(stats.stamina_max))

  if stats.stamina_regen > 0 then
    st_text = st_text .. colors.dim .. "+" .. stats.stamina_regen .. colors.reset
  end
  table.insert(lines, st_text)

  -- AP line
  local ap_bar = draw_mini_bar(stats.ap_current, stats.ap_max, 6, dim)
  local ap_text = string.format("%s %s %s/%s",
    colors.magenta .. "AP" .. colors.reset,
    ap_bar,
    format_num(stats.ap_current),
    format_num(stats.ap_max))

  if stats.ap_regen > 0 then
    ap_text = ap_text .. colors.dim .. "+" .. stats.ap_regen .. colors.reset
  end
  table.insert(lines, ap_text)

  -- Dormancy takes the target line: query_attack() is cleared on collapse, so
  -- the line is always free while dormant and the countdown costs no rows.
  if dim then
    local secs = stats.dormant or 0
    local mins = math.floor(secs / 60)
    table.insert(lines, string.format("%sDORMANT %d:%02d%s",
      colors.bright_red, mins, secs - mins * 60, colors.reset))
  elseif stats.target and stats.target ~= "None" and stats.target ~= "" then
    local tgt_color = pct_color(stats.target_pct)
    local tgt_name = trunc(stats.target, w - 10)
    local tgt_text = string.format("%s->%s%s %s%d%%%s",
      colors.dim, colors.bright_white, tgt_name,
      tgt_color, stats.target_pct, colors.reset)
    table.insert(lines, tgt_text)
  end

  -- PL/IL line (compact)
  local pl_pct = stats.pl_needed > 0 and math.floor(stats.pl_xp / stats.pl_needed * 100) or 100
  local il_pct = stats.il_needed > 0 and math.floor(stats.il_xp / stats.il_needed * 100) or 100
  if stats.pl_level < (stats.pl_max_level or 150)
     or stats.il_level < (stats.il_max_level or 30) then
    local lvl_text = string.format("%sPL%s%d %s%d%% %sIL%s%d %s%d%%",
      colors.cyan, colors.reset, stats.pl_level,
      colors.dim, pl_pct,
      colors.yellow, colors.reset, stats.il_level,
      colors.dim, il_pct)
    table.insert(lines, lvl_text)
  end

  return lines
end

--------------------------------------------------------------------------------
-- Main render function
--------------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Scrolling
--
-- This pane could not scroll at all before: the module exported no `scroll`,
-- so wm.assign captured none, wm.scrollable("stats") was false, and the mouse
-- wheel silently did nothing over it while every other pane responded.
--
-- The fix is to assemble the whole pane into ONE line list and draw a window
-- of it, instead of letting each section draw itself at an absolute y. Offset
-- is TOP-anchored (0 == showing the first line), because this is a dashboard
-- read downward -- the same convention guild_viking's pane pages use, and the
-- opposite of wm.make_scroller's tail-anchored chat/log semantics.
--
-- The guild and killers blocks belong to OTHER plugins. A plugin offering a
-- lines accessor (`guild_stats_lines(w)` / `stats_lines(w)`) joins the
-- scrollable list. One offering only the older draw-into-a-rect contract
-- (`render_guild_stats` / `render_stats`) still renders -- below the windowed
-- block, in whatever space is left, exactly as it did before -- but cannot be
-- scrolled, because a host cannot window content it never sees. Such a plugin
-- gains scrolling for free the day it adds the accessor.
-- ---------------------------------------------------------------------------
local scroll_offset = 0
local last_total, last_height = 0, 1

local function clamp_offset()
  local max = last_total - last_height
  if max < 0 then max = 0 end
  if scroll_offset > max then scroll_offset = max end
  if scroll_offset < 0 then scroll_offset = 0 end
end

-- delta < 0 scrolls up (toward the first line), > 0 down -- CLAUDE.md's
-- pane-scrolling sign convention.
function M.scroll(delta)
  if type(delta) ~= "number" then return false end
  scroll_offset = scroll_offset + delta
  clamp_offset()
  ui.dirty()
  return true
end

function M.scroll_to_bottom()
  scroll_offset = last_total - last_height
  clamp_offset()
  ui.dirty()
  return true
end

-- "At rest" for a top-anchored dashboard is the TOP, so this reports whether
-- the pane is showing its first line. Same wm.assign contract name, opposite
-- physical direction from a tail-anchored log pane -- see the note above.
function M.following_tail()
  clamp_offset()
  return scroll_offset == 0
end

local function separator(w)
  return string.rep("-", w)
end

-- Collects every section that can hand over lines, in the established order,
-- with the same separators the drawing version placed between them.
local function collect_lines(w)
  local out = {}
  local function add_all(lines)
    if #lines == 0 then return end
    if #out > 0 then out[#out + 1] = separator(w) end
    for _, l in ipairs(lines) do out[#out + 1] = l end
  end

  if config.show_player and player_stats then add_all(player_stat_lines(w)) end
  if config.show_mercenary and mercenary then add_all(mercenary_stat_lines(w)) end

  local guild_draw_only, killers_draw_only = nil, nil

  if config.show_guild then
    if not guild_plugin then
      for _, name in ipairs(guild_names) do
        guild_plugin = plugin.get(name)
        if guild_plugin then break end
      end
    end
    if guild_plugin and guild_plugin.has_data and guild_plugin.has_data() then
      if guild_plugin.guild_stats_lines then
        add_all(guild_plugin.guild_stats_lines(w) or {})
      elseif guild_plugin.render_guild_stats then
        guild_draw_only = guild_plugin
      end
    end
  end

  if config.show_killers then
    if not kill_trigger then kill_trigger = plugin.get("kill_trigger") end
    if kill_trigger and kill_trigger.has_data and kill_trigger.has_data() then
      if kill_trigger.stats_lines then
        add_all(kill_trigger.stats_lines(w) or {})
      elseif kill_trigger.render_stats then
        killers_draw_only = kill_trigger
      end
    end
  end

  return out, guild_draw_only, killers_draw_only
end

function M.render(rect, opts)
  opts = opts or {}
  local show_border = opts.show_border ~= false
  local title = opts.title or "Stats"

  local x, y, w, h
  if type(rect.x) == "function" then
    x, y, w, h = rect:x(), rect:y(), rect:w(), rect:h()
  else
    x, y, w, h = rect.x, rect.y, rect.w, rect.h
  end

  if show_border then
    ui.box(rect, "single", title)
    x, y, w, h = x + 1, y + 1, w - 2, h - 2
  end

  if w <= 0 or h <= 0 then return end

  -- Try to load dependencies if not loaded
  if not player_stats then
    player_stats = plugin.get("player_stats")
  end
  if not mercenary then
    mercenary = plugin.get("mercenary")
  end

  local lines, guild_draw_only, killers_draw_only = collect_lines(w)

  last_total, last_height = #lines, h
  clamp_offset()

  local drawn = 0
  for i = scroll_offset + 1, math.min(#lines, scroll_offset + h) do
    ui.text_ansi(ui.rect(x, y + drawn, w, 1), lines[i])
    drawn = drawn + 1
  end

  -- Draw-contract-only sections render below the windowed block, in whatever
  -- space is left (their pre-scrolling behavior). They are deliberately NOT
  -- part of `lines`, so they are excluded from the scroll range -- see the
  -- note above the scrolling block.
  local current_y = y + drawn
  local remaining_h = h - drawn

  if guild_draw_only and remaining_h > 0 then
    if drawn > 0 then
      ui.text(ui.rect(x, current_y, w, 1), separator(w))
      current_y = current_y + 1
      remaining_h = remaining_h - 1
    end
    if remaining_h > 0 then
      local used = guild_draw_only.render_guild_stats(
        ui.rect(x, current_y, w, remaining_h), {}) or 0
      current_y = current_y + used
      remaining_h = remaining_h - used
    end
  end

  if killers_draw_only and remaining_h > 0 then
    if current_y > y then
      ui.text(ui.rect(x, current_y, w, 1), separator(w))
      current_y = current_y + 1
      remaining_h = remaining_h - 1
    end
    if remaining_h > 0 then
      killers_draw_only.render_stats(ui.rect(x, current_y, w, remaining_h), {})
    end
  end
end

--------------------------------------------------------------------------------
-- Configuration API
--------------------------------------------------------------------------------

function M.show_player(enabled)
  if enabled == nil then return config.show_player end
  config.show_player = enabled
end

function M.show_mercenary(enabled)
  if enabled == nil then return config.show_mercenary end
  config.show_mercenary = enabled
end

function M.show_deltas(enabled)
  if enabled == nil then return config.show_deltas end
  config.show_deltas = enabled
end

function M.show_guild(enabled)
  if enabled == nil then return config.show_guild end
  config.show_guild = enabled
end

function M.show_killers(enabled)
  if enabled == nil then return config.show_killers end
  config.show_killers = enabled
end

--------------------------------------------------------------------------------
-- Plugin lifecycle
--------------------------------------------------------------------------------

function M.on_load()
  -- Try to get dependencies
  player_stats = plugin.get("player_stats")
  mercenary = plugin.get("mercenary")
  for _, name in ipairs(guild_names) do
    guild_plugin = plugin.get(name)
    if guild_plugin then break end
  end
  kill_trigger = plugin.get("kill_trigger")
end

function M.on_unload()
  player_stats = nil
  mercenary = nil
  guild_plugin = nil
  kill_trigger = nil
end

return M
