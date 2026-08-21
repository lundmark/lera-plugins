-- Stats page: LEGACY's inline "---- Page 1: Stats ----" block
-- (/home/simon/code/3s_scripts_old/lua/guild_viking.lua:7137-7394). Pure
-- builder: lines(width) -> array of ANSI strings, reading state.lua's S and
-- page_opts.lua only (no ui.* calls, no mutation, per the plan's page-purity
-- constraint).
--
-- Section order mirrors the LEGACY draw order top-to-bottom: daler, the
-- "Change" delta box (HP/Threk/Seid/Vig/Rad/Fury bars), Ledung, Chain/BSDepth,
-- the active-god quick view, Saga XP (gated show_stats_xp), then Active
-- Effects/STFX (gated show_stats_buffs). One section beyond that literal
-- window -- an Enemy block (en5/ens/rndz/estatus_pct/mob_name_full) -- is
-- added per the stage-2 task brief: LEGACY only ever printed those fields to
-- the scrolling console (guild_viking.lua:655-657, 881-886), never into the
-- Page 1 window itself, but the pane is the natural home for that summary
-- now that it exists, and the fields are already tracked in state.lua.
local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local combat = require("combat")

local S = state.S
local C = pagelib.C

local M = {}

-- Ported from LEGACY's fmt_time (guild_viking.lua:7431-7448): used here only
-- for the god-power "Next:" readout.
local function fmt_time(secs)
  secs = secs or 0
  if secs <= 0 then return "ready" end
  if secs < 60 then return secs .. "s" end
  if secs < 86400 then
    if secs < 3600 then
      local m = math.floor(secs / 60)
      local s = secs % 60
      return s > 0 and (m .. "m" .. s .. "s") or (m .. "m")
    end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    return m > 0 and (h .. "h" .. m .. "m") or (h .. "h")
  end
  local d = math.floor(secs / 86400)
  local h = math.floor((secs % 86400) / 3600)
  return h > 0 and (d .. "d" .. h .. "h") or (d .. "d")
end

-- Ported from LEGACY's inline session-elapsed formatting
-- (guild_viking.lua:7292-7301): distinct from fmt_time above (different
-- thresholds/format -- "Session: Xs"/"Session: XmYs"/"Session: XhYm").
local function fmt_session(elapsed)
  if elapsed < 60 then
    return string.format("Session: %ds", elapsed)
  elseif elapsed < 3600 then
    local m, s = math.floor(elapsed / 60), elapsed % 60
    return s > 0 and string.format("Session: %dm%ds", m, s) or string.format("Session: %dm", m)
  end
  local h = math.floor(elapsed / 3600)
  local m = math.floor((elapsed % 3600) / 60)
  return m > 0 and string.format("Session: %dh%dm", h, m) or string.format("Session: %dh", h)
end

-- LEGACY 7172-7176 (delta_text): "+N"/"-N" after a bar row; green for a
-- gain, blue-ish for a loss (mapped to pagelib.C.cyan -- no literal "blue"
-- in the shared palette), nothing when unchanged.
local function delta_text(val)
  if not val or val == 0 then return "" end
  local color = val > 0 and C.bright_green or C.cyan
  return " " .. color .. string.format("%+d", val) .. pagelib.RESET
end

-- One HP/Threk/Seid/Vig/Rad/Fury bar row: "Label  [####----] cur/max +delta".
local function bar_row(width, label, val, max, delta, color)
  local row = string.format("%-7s%s %d/%d%s",
    label, pagelib.bar(20, val, max, color), val, max, delta_text(delta))
  return pagelib.trunc(row, width)
end

-- Grouped colors for the Active Effects section, keyed by combat.lua's
-- exported STFX_CAT_ORDER categories. See combat.lua's comment on
-- STFX_CAT_ORDER/STFX_CAT_LABELS for why the LEGACY hex colors aren't
-- reused verbatim.
local STFX_CAT_ANSI = {
  Def  = C.cyan,
  Heal = C.green,
  Off  = C.magenta,
  Pwr  = C.bright_red,
  DoT  = C.red,
}

function M.lines(width)
  width = width or 80
  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  -- ---- Daler treasury (7154-7159) -------------------------------------
  if S.daler and S.daler >= 0 then
    add(pagelib.kv(width, "Daler:", pagelib.fmt_num(S.daler), C.bright_cyan))
  end

  -- ---- Vitals: HP/Threk/Seid/Vig/Rad/Fury bars (7161-7231) ------------
  add(pagelib.header(width, "Vitals"))
  add(bar_row(width, "HP:", S.hp, S.mhp, S.hp_delta, pagelib.pct_color(S.hp, S.mhp)))
  -- Threk is a pending-damage pool, not a resource to keep full: red while
  -- building up, green when empty (7188).
  add(bar_row(width, "Threk:", S.threk, math.max(S.mthrek, 1), S.threk_delta,
    S.threk > 0 and C.red or C.bright_green))
  add(bar_row(width, "Seid:", S.seid, math.max(S.mseid, 1), S.seid_delta,
    pagelib.pct_color(S.seid, S.mseid)))
  add(bar_row(width, "Vig:", S.vig, math.max(S.mvig, 1), S.vig_delta,
    pagelib.pct_color(S.vig, S.mvig)))
  add(bar_row(width, "Rad:", S.rad, math.max(S.mrad, 1), S.rad_delta,
    pagelib.pct_color(S.rad, S.mrad)))

  -- Fury: derived from the raw "[***-------]" token (7223-7231) -- count of
  -- '*' vs total inner chars, no delta.
  do
    local fury_raw = (S.fury and S.fury ~= "") and S.fury or "[----------]"
    local fury_inner = fury_raw:match("^%[(.-)%]$") or fury_raw
    local fury_filled = select(2, fury_inner:gsub("%*", ""))
    local fury_total = #fury_inner
    add(bar_row(width, "Fury:", fury_filled, fury_total > 0 and fury_total or 1, nil, C.cyan))
  end

  -- ---- Ledung / Chain / BSDepth (7233-7256) ---------------------------
  add(pagelib.header(width, "Ledung / Chain"))
  local ldng_val
  if S.lrst and S.lrst > 0 then
    ldng_val = string.format("%d/%d (+%d%%)", S.ldng, S.mldng, S.lrst)
  else
    ldng_val = string.format("%d/%d", S.ldng, S.mldng)
  end
  add(pagelib.trunc(
    string.format("%-7s%s %s", "Ledng:", pagelib.bar(20, S.ldng, S.mldng > 0 and S.mldng or 1, C.cyan), ldng_val),
    width))
  add(pagelib.trunc(string.format("Chain:%d  BSDp:%d", S.chain or 0, S.bsdepth or 0), width))

  -- ---- Active god quick view (7258-7283) ------------------------------
  do
    local has_god = S.god_power_name and S.god_power_name ~= ""
    local gname = has_god and S.god_power_name or "--"
    local gtxt
    if S.god_power_next and S.god_power_next > 0 then
      gtxt = fmt_time(S.god_power_next)
    elseif has_god then
      gtxt = "now"
    else
      gtxt = "--"
    end
    add(pagelib.header(width, "God"))
    add(pagelib.trunc(string.format("God: %s   Next: %s", gname, gtxt), width))
  end

  -- ---- Saga XP (7285-7347, gated show_stats_xp) -----------------------
  if page_opts.get("show_stats_xp") then
    add(pagelib.header(width, "Saga XP"))
    if S.xp_session_start then
      local elapsed = os.time() - S.xp_session_start
      add(pagelib.trunc(fmt_session(elapsed), width))
    end

    local half = math.floor(width / 2)
    local xp_data = {
      { label = "Vis:", val = S.vis, gain = S.vis_gain },
      { label = "Kap:", val = S.kap, gain = S.kap_gain },
      { label = "Soe:", val = S.soe, gain = S.soe_gain },
      { label = "Aud:", val = S.aud, gain = S.aud_gain },
    }
    for i = 1, #xp_data, 2 do
      local function cell(d)
        local s = string.format("%s%d", d.label, d.val)
        if d.gain and d.gain > 0 then
          s = s .. string.format(" (+%d)", d.gain)
        end
        return s
      end
      local left = pagelib.trunc(cell(xp_data[i]), half)
      local right = xp_data[i + 1] and cell(xp_data[i + 1]) or ""
      add(pagelib.trunc(left .. " " .. right, width))
    end

    add(pagelib.trunc(C.dim .. "Session gained:" .. pagelib.RESET, width))
    local sess_data = {
      { label = "Vis:", val = S.vis_session },
      { label = "Kap:", val = S.kap_session },
      { label = "Soe:", val = S.soe_session },
      { label = "Aud:", val = S.aud_session },
    }
    for i = 1, #sess_data, 2 do
      local left = pagelib.trunc(
        string.format("%s%d", sess_data[i].label, sess_data[i].val), half)
      local right_d = sess_data[i + 1]
      local right = right_d and string.format("%s%d", right_d.label, right_d.val) or ""
      add(pagelib.trunc(left .. " " .. right, width))
    end
  end

  -- ---- Enemy (see module comment: not a literal Page-1 window section, --
  -- added per the stage-2 brief since the fields exist and have no other --
  -- home in the pane yet) ------------------------------------------------
  add(pagelib.header(width, "Enemy"))
  local enemy_name = (S.mob_name_full and S.mob_name_full ~= "None") and S.mob_name_full
    or ((S.en5 and S.en5 ~= "None") and S.en5 or "None")
  add(pagelib.kv(width, "Target:", enemy_name, S.combat and C.bright_red or C.dim))
  add(pagelib.trunc(string.format(
    "En:%s Status:%s Rounds:%d Est:%d%%",
    S.en5 or "None", (S.ens and S.ens ~= "") and S.ens or "-", S.rndz or 0, S.estatus_pct or 0),
    width))

  -- ---- Active effects / STFX (7349-7382, gated show_stats_buffs) ------
  if S.stfx and #S.stfx > 0 and page_opts.get("show_stats_buffs") then
    add(pagelib.header(width, "Active Effects"))
    local by_cat = {}
    for _, fx in ipairs(S.stfx) do
      local cat = fx.cat or "DoT"
      by_cat[cat] = by_cat[cat] or {}
      by_cat[cat][#by_cat[cat] + 1] = fx
    end
    for _, cat in ipairs(combat.STFX_CAT_ORDER) do
      local fxlist = by_cat[cat]
      if fxlist and #fxlist > 0 then
        local parts = {}
        for _, fx in ipairs(fxlist) do
          parts[#parts + 1] = string.format("%s:%s", fx.name, fx.val)
        end
        add(pagelib.kv(width, combat.STFX_CAT_LABELS[cat] .. ":",
          table.concat(parts, "  "), STFX_CAT_ANSI[cat]))
      end
    end
  end

  return lines
end

return M
