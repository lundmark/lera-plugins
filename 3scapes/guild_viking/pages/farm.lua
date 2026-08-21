-- Farm page: LEGACY's draw_page3
-- (/home/simon/code/3s_scripts_old/lua/guild_viking.lua:9115-9370). Pure
-- builder: lines(width) -> array of ANSI strings, reading state.lua's S and
-- page_opts.lua only.
--
-- Section order mirrors LEGACY: Weather (gated show_farm_weather, AND only
-- when state.season is known -- guild_viking.lua:9123), Mushroom Farm (gated
-- show_farm_plots -- weather growth modifier, the plot grid, and the
-- Water/Fertilizer reserves line, all nested inside the SAME `if` in LEGACY
-- so all three disappear together when the opt is off), Blot Grove (gated
-- show_farm_blot -- status/trees, a fill-progress bar, and a reset countdown
-- shown only when > 0).
local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local cc = require("pages.city_common")

local S = state.S
local C = pagelib.C

local M = {}

-- ---------------------------------------------------------------------------
-- Weather & Season (guild_viking.lua:9122-9144)
-- ---------------------------------------------------------------------------

-- KEEP AND DISCLOSE (semantic exception, final BGR sweep -- same style as
-- pages/army.lua's "training status" note): summer/autumn/storm/blizzard/
-- rain here, and the negative-growth branch in farm_plots_lines below, are
-- kept exactly as currently mapped rather than mechanically re-decoded.
-- Season/weather color is chosen for its semantic association -- warm
-- yellow for summer, falling-leaf red for autumn, alarm red for storm and
-- blizzard, cool cyan for rain, red for a negative growth modifier -- not
-- for hue proximity to whatever LEGACY's literal happens to decode to.
local SEASON_ANSI = { spring = C.green, summer = C.yellow, autumn = C.red, winter = C.white }
local WEATHER_ANSI = {
  clear = C.green, overcast = C.dim, rain = C.cyan, storm = C.bright_red,
  fog = C.dim, snow = C.white, blizzard = C.bright_red,
}
local WEATHER_STR_LABELS = { [1] = "Light", [2] = "Moderate", [3] = "Heavy" }

local function cap1(s)
  s = tostring(s or "")
  return (s:gsub("^%l", string.upper))
end

local function weather_lines(add, width)
  add(pagelib.header(width, "Weather"))
  add(pagelib.kv(width, "Season:", cap1(S.season), SEASON_ANSI[S.season] or C.white))
  local str_label = WEATHER_STR_LABELS[S.weather_str] or ""
  add(pagelib.trunc(string.format("%s%s%s  %s%s%s",
    WEATHER_ANSI[S.weather] or C.white, cap1(S.weather), pagelib.RESET,
    C.dim, str_label, pagelib.RESET), width))
end

-- ---------------------------------------------------------------------------
-- Mushroom Farm plot grid (guild_viking.lua:9146-9328, gated show_farm_plots)
-- ---------------------------------------------------------------------------

-- Ported from LEGACY's shroom_id_to_name (guild_viking.lua:7451-7469):
-- strip a "_tN" tier suffix, underscores -> spaces, title-case, then a small
-- set of special-case renames matching the server's shroom_display_name.
local SHROOM_SPECIALS = {
  ["Lions Mane"] = "Lion's Mane",
  ["Witches Hat"] = "Witches' Hat",
  ["Witches Butter"] = "Witches' Butter",
  ["Dyers Polypore"] = "Dyer's Polypore",
  ["Dryads Saddle"] = "Dryad's Saddle",
  ["Hedgehog"] = "Hedgehog Mushroom",
  ["Inky Cap"] = "Inkcap",
}

local function shroom_name(id)
  id = id or ""
  local base = id:gsub("_t%d+$", "")
  local name = base:gsub("_", " "):gsub("(%a)([%a']*)", function(f, r)
    return f:upper() .. r
  end)
  return SHROOM_SPECIALS[name] or name
end

-- Ported from LEGACY's status3/cell_parts color logic (guild_viking.lua:
-- 9166-9248), collapsed to one status string + one color (content fidelity,
-- not the pixel-exact "wilting soon vs already wilted" two-tone split).
local function plot_status(fp)
  local secs = fp.time_left
  local wilt = fp.wilt_left
  local fert = fp.fertilized and fp.fertilized > 0
  if secs == nil then return "...", C.dim end
  if secs < 0 then return "~~~", C.dim end
  if secs == 0 then
    if wilt and wilt == 0 then return "WLT", C.bright_red end
    if wilt and wilt > 0 then
      local soon = wilt < 7200  -- LEGACY's "wilting soon" cutoff
      return "WLT:" .. cc.fmt_time(wilt), soon and C.yellow or C.bright_green
    end
    return "RDY", C.bright_green
  end
  return cc.fmt_time(secs), fert and C.cyan or C.dim
end

local function plot_rows(width)
  local rows = {}
  for _, fp in ipairs(S.farm_plots or {}) do
    local status_text, status_color = plot_status(fp)
    local name = shroom_name(fp.shroom)
    if fp.fertilized and fp.fertilized > 0 then
      name = name .. "*"
    end
    rows[#rows + 1] = {
      fp.coord or "?",
      name,
      status_color .. status_text .. pagelib.RESET,
    }
  end
  return pagelib.columns(width, {
    { title = "Coord", w = 6 },
    { title = "Mushroom", w = 16 },
    { title = "Status", w = "*" },
  }, rows)
end

local function farm_plots_lines(add, width)
  add(pagelib.header(width, "Mushroom Farm"))

  if S.farm_wmod and S.farm_wmod ~= 0 then
    local wmod = S.farm_wmod
    local sign = wmod > 0 and "+" or ""
    add(pagelib.kv(width, "Growth:", sign .. wmod .. "% growth rate",
      wmod > 0 and C.green or C.bright_red))
  end

  if not S.farm_plots or #S.farm_plots == 0 then
    add(pagelib.trunc(C.dim .. "No active plots" .. pagelib.RESET, width))
  else
    for _, l in ipairs(plot_rows(width)) do add(l) end
  end

  add(pagelib.trunc(string.format("%sWater:%s %d   %sFertilizer:%s %d",
    C.cyan, pagelib.RESET, S.city_water or 0,
    C.yellow, pagelib.RESET, S.city_fert or 0), width))
end

-- ---------------------------------------------------------------------------
-- Blot Grove (guild_viking.lua:9343-9368, gated show_farm_blot)
-- ---------------------------------------------------------------------------

local BLOT_STATUS_ANSI = { open = C.yellow, complete = C.bright_green, rest = C.cyan }

local function blot_lines(add, width)
  add(pagelib.header(width, "Blot Grove"))
  local st = (S.blot_status and S.blot_status ~= "") and S.blot_status or "?"
  local scolor = BLOT_STATUS_ANSI[st] or C.dim
  add(pagelib.trunc(string.format("Status: %s%s%s   Trees: %d/%d",
    scolor, st, pagelib.RESET, S.blot_filled or 0, S.blot_total or 0), width))
  add(pagelib.bar(width, S.blot_filled or 0,
    (S.blot_total and S.blot_total > 0) and S.blot_total or 9, C.cyan))
  if (S.blot_reset_in or 0) > 0 then
    add(pagelib.kv(width, "Next reset:", cc.fmt_time(S.blot_reset_in), C.dim))
  end
end

function M.lines(width)
  width = width or 80
  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  -- LEGACY guards the whole Weather section on `state.season ~= ""` as well
  -- as the opt (9123).
  if page_opts.get("show_farm_weather") and S.season and S.season ~= "" then
    weather_lines(add, width)
  end

  if page_opts.get("show_farm_plots") then
    farm_plots_lines(add, width)
  end

  if page_opts.get("show_farm_blot") then
    blot_lines(add, width)
  end

  return lines
end

return M
