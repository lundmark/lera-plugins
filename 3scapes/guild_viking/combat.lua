-- Combat status parsers: the FFF MIP composite (attacker/hp/status ticks) and
-- the 8 hp-bar screen-scrape triggers, ported verbatim from LEGACY
-- guild_viking.lua (github.com/.../3s_scripts_old, read-only reference).
--
-- Display calls (ColourNote) and viking_window.update() calls are dropped --
-- the window arrives in stage 2 and will read this state directly. LEGACY
-- gated its window repaint per-body (sometimes unconditionally, sometimes on
-- a "did anything visibly change" computation, e.g. hp_bar_3's stfx name
-- diff); the simplest faithful equivalent here is to call ui.dirty()
-- unconditionally at the end of every trigger fn and of on_composite.
local S = require("state").S
local util = require("util")

local M = {}

-- LEGACY guild_viking.lua:302-335 (STFX_META / STFX_DEFAULT): tag -> visual
-- metadata for the STFX effects bar. The colors are unconsumed without a
-- window in stage 1, but every write LEGACY made to a stfx entry (including
-- cat/cs/ci) is preserved verbatim per the porting rule -- stage 2 reads
-- them back rather than re-deriving from the tag name.
local STFX_META = {
  aeg  = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  sev  = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  skad = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  vkj  = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  ram  = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  gul  = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  tvi  = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  nau  = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  valg = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  gisl = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  gjal = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  bif  = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  ein  = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  bvorn= { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  hrei = { cat="Heal", cs="#33CC33", ci=0x33CC33 },
  bles = { cat="Heal", cs="#33CC33", ci=0x33CC33 },
  gro  = { cat="Heal", cs="#33CC33", ci=0x33CC33 },
  jor  = { cat="Heal", cs="#33CC33", ci=0x33CC33 },
  van  = { cat="Heal", cs="#33CC33", ci=0x33CC33 },
  frey = { cat="Heal", cs="#33CC33", ci=0x33CC33 },
  gald = { cat="Off",  cs="#DD44DD", ci=0xDD44DD },
  veth = { cat="Off",  cs="#DD44DD", ci=0xDD44DD },
  hug  = { cat="Off",  cs="#DD44DD", ci=0xDD44DD },
  bolv = { cat="Off",  cs="#DD44DD", ci=0xDD44DD },
  rune = { cat="Off",  cs="#DD44DD", ci=0xDD44DD },
  valhr= { cat="Pwr",  cs="#FF3333", ci=0x3333FF },
}
local STFX_DEFAULT = { cat="DoT", cs="#FF5555", ci=0x5555FF }

-- LEGACY guild_viking.lua:335-337 (STFX_CAT_ORDER/STFX_CAT_LABELS): category
-- grouping order and display labels for the Stats page's active-effects
-- section (pages/stats.lua). Exported (not duplicated) per the plan's
-- preference -- the page reads the same metadata combat.lua already derives
-- stfx entries' `cat` field from, so the two can never drift apart. Colors
-- are NOT exported: LEGACY's STFX_CAT_COLORS/per-effect `ci` are BGR pixel
-- hex, which has no faithful ANSI equivalent worth the complexity (Global
-- Constraints: "exact hex fidelity is NOT required") -- pages/stats.lua maps
-- each category to a pagelib.C name instead.
M.STFX_CAT_ORDER  = { "Def", "Heal", "Off", "Pwr", "DoT" }
M.STFX_CAT_LABELS = { Def="Def", Heal="Heal", Off="Off", Pwr="Pwr", DoT="DoT" }

-- ---------------------------------------------------------------------------
-- FFF composite: a `~`-separated tag stream from send_mip_city()'s combat
-- leg. LEGACY 868-905 (guild.events.mip_info).
-- ---------------------------------------------------------------------------
function M.on_composite(text)
  local data = util.split(text, "~")
  local index = 1
  local event_type = data[index]
  while event_type do
    if event_type == "A" then
      -- Current HP
      S.hp = tonumber(data[index + 1]) or S.hp
    elseif event_type == "B" then
      -- Max HP
      S.mhp = tonumber(data[index + 1]) or S.mhp
    elseif event_type == "K" then
      local attacker = data[index + 1]
      S.mob_name_full = (attacker and attacker ~= "") and attacker or "None"
      if S.mob_name_full ~= "None" then
        S.combat = true
      end
    elseif event_type == "L" then
      S.estatus_pct = tonumber(data[index + 1]) or 0
    elseif event_type == "M" then
      -- LEGACY quirk, ported verbatim: "M" carries no value slot of its own,
      -- so back the index up by one before the usual +2 stride advances it,
      -- resyncing on the very next token instead of skipping it.
      index = index - 1
    elseif event_type == "N" then
      S.combat_rounds = tonumber(data[index + 1]) or 0
    end
    index = index + 2
    event_type = data[index]
  end

  if S.mob_name_full == "None" or S.mob_name_full == "" then
    S.combat = false
  end

  ui.dirty()
end

-- ---------------------------------------------------------------------------
-- Hp-bar screen-scrape triggers. LEGACY 501-776; regexes from
-- guild_viking.xml:24-71 (Portal wildcards[n] -> the (n+1)-th callback arg).
-- ---------------------------------------------------------------------------

-- Line 1: H[hp|mhp(threk|mthrek)] S[seid|mseid] V[vig|mvig] R[rad|mrad] F[fury] C[chain/bsdepth]
-- F[...] C[...] are optional and the pattern is not end-anchored, so the core
-- stats (H/S/V/R) still capture when the MUD hard-wraps the prompt inside F[...].
local hp_bar_1_pattern =
  "^H\\[(\\d+)\\|(\\d+)\\((\\d+)\\|(\\d+)\\)\\] S\\[(\\d+)\\|(\\d+)\\] V\\[(\\d+)\\|(\\d+)\\] R\\[(\\d+)\\|(\\d+)\\]" ..
  "(?: F(\\[[^\\]]*\\]) C\\[(\\d+)/(\\d+)\\])?"

local function hp_bar_1(line, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13)
  local new_hp = tonumber(c1) or 0
  if S.hp_prev == 0 then
    S.hp_prev = new_hp
  else
    S.hp_delta = new_hp - S.hp_prev
    S.hp_prev  = new_hp
  end
  S.hp      = new_hp
  S.mhp     = tonumber(c2)  or 0
  local new_threk = tonumber(c3) or 0
  S.threk_delta = S.threk_prev ~= 0 and (new_threk - S.threk_prev) or 0
  S.threk_prev  = new_threk
  S.threk   = new_threk
  S.mthrek  = tonumber(c4)  or 0
  local new_seid = tonumber(c5) or 0
  S.seid_delta = S.seid_prev ~= 0 and (new_seid - S.seid_prev) or 0
  S.seid_prev  = new_seid
  S.seid    = new_seid
  S.mseid   = tonumber(c6)  or 0
  local new_vig = tonumber(c7) or 0
  S.vig_delta = S.vig_prev ~= 0 and (new_vig - S.vig_prev) or 0
  S.vig_prev  = new_vig
  S.vig     = new_vig
  S.mvig    = tonumber(c8)  or 0
  local new_rad = tonumber(c9) or 0
  S.rad_delta = S.rad_prev ~= 0 and (new_rad - S.rad_prev) or 0
  S.rad_prev  = new_rad
  S.rad     = new_rad
  S.mrad    = tonumber(c10) or 0
  -- F[fury] and C[chain/bsdepth] can wrap onto the next physical line during
  -- big fights; when that happens these captures are nil/empty, so keep the
  -- last-known values rather than resetting them (hp_bar_1_cont refreshes
  -- chain/bsdepth from the continuation line).
  if c11 and c11 ~= "" then S.fury = c11 end
  if c12 and c12 ~= "" then S.chain = tonumber(c12) or S.chain end
  if c13 and c13 ~= "" then S.bsdepth = tonumber(c13) or S.bsdepth end
  S.fury    = S.fury or ""
  S.chain   = S.chain or 0
  S.bsdepth = S.bsdepth or 0

  ui.dirty()
end

-- Continuation of a wrapped Line 1: "<fury-tail>] C[chain/bsdepth]"
local hp_bar_1_cont_pattern = "^[-*]*\\] C\\[(\\d+)/(\\d+)\\]\\s*$"

local function hp_bar_1_cont(line, c1, c2)
  S.chain   = tonumber(c1) or S.chain or 0
  S.bsdepth = tonumber(c2) or S.bsdepth or 0

  ui.dirty()
end

-- Line 2 (extended G[] format): G[vis(vkxp)|kap(bkxp)|soe(hkxp)|aud(buxp)] L[ldng|mldng(lrst%)] E[en5|ens|rndz]
-- The |rndz part is optional so the trigger still matches when the MUD hard-
-- wraps the line after the second | in E[name|status| (rndz lands on the next line).
local hp_bar_2_pattern =
  "^G\\[(\\d+)\\((\\d+)\\)\\|(\\d+)\\((\\d+)\\)\\|(\\d+)\\((\\d+)\\)\\|(\\d+)\\((\\d+)\\)\\] " ..
  "L\\[(\\d*)\\|(\\d*)\\((\\d*)%\\)\\] E\\[([^|]*)\\|([^|]*)(?:\\|(\\d*))?\\]?"

local function hp_bar_2(line, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14)
  S.vis      = tonumber(c1)  or 0
  S.vis_gain = tonumber(c2)  or 0
  S.kap      = tonumber(c3)  or 0
  S.kap_gain = tonumber(c4)  or 0
  S.soe      = tonumber(c5)  or 0
  S.soe_gain = tonumber(c6)  or 0
  S.aud      = tonumber(c7)  or 0
  S.aud_gain = tonumber(c8)  or 0
  S.ldng     = tonumber(c9)  or 0
  S.mldng    = tonumber(c10) or 0
  S.lrst     = tonumber(c11) or 0
  S.en5      = c12 or "None"
  S.ens      = c13 or ""
  S.rndz     = tonumber(c14) or 0

  -- Combat state from E field
  S.combat = (S.en5 ~= "None" and S.en5 ~= "")

  -- Accumulate session totals
  local round_total = S.vis_gain + S.kap_gain + S.soe_gain + S.aud_gain
  if round_total > 0 then
    S.vis_session = S.vis_session + S.vis_gain
    S.kap_session = S.kap_session + S.kap_gain
    S.soe_session = S.soe_session + S.soe_gain
    S.aud_session = S.aud_session + S.aud_gain
    if not S.xp_session_start then
      S.xp_session_start = os.time()
    end
  end

  ui.dirty()
end

-- Continuation of a wrapped Line 2: picks up "19]" when the E[name|status|rndz]
-- field hard-wraps after the second |, sending rndz to the next line.
local hp_bar_2_cont_pattern = "^(\\d+)\\]\\s*$"

local function hp_bar_2_cont(line, c1)
  S.rndz = tonumber(c1) or 0

  ui.dirty()
end

-- Line 2 (Vis: label format): Vis:12399  Kap:16168  Soe:495  Aud:14507  L[1|4] E[None]
local hp_bar_2_vis_pattern =
  "^Vis:(\\d+)\\s+Kap:(\\d+)\\s+Soe:(\\d+)\\s+Aud:(\\d+)\\s+L\\[(\\d+)\\|(\\d+)\\]\\s+E\\[([^\\]]*)\\]?"

local function hp_bar_2_vis(line, c1, c2, c3, c4, c5, c6, c7)
  S.vis      = tonumber(c1) or 0
  S.kap      = tonumber(c2) or 0
  S.soe      = tonumber(c3) or 0
  S.aud      = tonumber(c4) or 0
  S.ldng     = tonumber(c5) or 0
  S.mldng    = tonumber(c6) or 0
  S.en5      = c7 or "None"
  S.vis_gain = 0
  S.kap_gain = 0
  S.soe_gain = 0
  S.aud_gain = 0
  S.lrst     = 0
  S.rndz     = 0
  S.ens      = ""

  S.combat = (S.en5 ~= "None" and S.en5 ~= "")

  ui.dirty()
end

-- Line 3 (STFX effects bar): [ein:54 bvorn:91 bles:34] or [] when none active.
-- Shared by the immediate-match trigger and the wrap-reassembly path below.
local function apply_stfx(inner)
  local new_stfx = {}
  for k, v in (inner or ""):gmatch("(%a+):([%d/]+)") do
    local meta = STFX_META[k] or STFX_DEFAULT
    new_stfx[#new_stfx + 1] = { name = k, val = v, cat = meta.cat, cs = meta.cs, ci = meta.ci }
  end
  S.stfx = new_stfx
end

local hp_bar_3_pattern = "^\\[(\\s*(?:[a-z]+:[0-9/]+\\s*)*)\\]\\s*$"

local function hp_bar_3(line, c1)
  apply_stfx(c1)

  ui.dirty()
end

-- Wrapped STFX: buffer the opening fragment (starts with "[", no closing "]" yet).
local hp_bar_3_open_pattern = "^\\[(\\s*(?:[a-z]+:[0-9/]+\\s*)+)$"

local _stfx_buffer, _stfx_pending

local function hp_bar_3_open(line, c1)
  _stfx_buffer  = c1 or ""
  _stfx_pending = true

  ui.dirty()
end

-- Continuation ending in "]": if a wrapped STFX is pending, stitch it back
-- together and parse the full effect list. Also silently swallows the lone
-- "]" left behind when a G[]/Vis line wraps at its closing bracket (pending = false).
local hp_bar_3_cont_pattern = "^((?:[a-z]+:[0-9/]+\\s*)*)\\]\\s*$"

local function hp_bar_3_cont(line, c1)
  if not _stfx_pending then
    ui.dirty()
    return
  end
  local combined = (_stfx_buffer or "") .. " " .. (c1 or "")
  _stfx_pending = false
  _stfx_buffer  = nil
  apply_stfx(combined)

  ui.dirty()
end

-- ---------------------------------------------------------------------------
-- GMCP Char.Combat.
--
-- The hp-bar triggers above are protocol-independent -- they parse the MUD's
-- rendered prompt -- so almost everything on the Stats page survives with MIP
-- off. Exactly three fields did not: the ones FFF's K, L and N tags owned.
--
-- Char.Combat is the purpose-built replacement for that attacker block. Its own
-- header says it "mirrors the MIP composite's attacker block", and it carries
-- all three: attacker, attacker_hp and rounds. Guild.State's target/encounter
-- groups overlap it but omit the hp percent, so this is the better source and
-- the only one mapped -- two GMCP sources writing the same fields would be the
-- collision that cost the housing totals their meaning.
--
--   { attacker = "", attacker_hp = 0, rounds = 0, target = "" }
--
-- is the canonical idle snapshot (secure/protocol/char_combat_impl.h). Note the
-- empty attacker string where FFF's K tag used the literal "None" -- the
-- consumer at pages/stats.lua:246 tests for "None", so translate rather than
-- passing "" through.
--
-- `target` (who the attacker is attacking, "you" when that is this player) has
-- no field on the Stats page and is deliberately not mapped.
function M.on_gmcp_combat(data)
  if type(data) ~= "table" then return end

  if type(data.attacker) == "string" then
    S.mob_name_full = data.attacker ~= "" and data.attacker or "None"
  end
  if data.attacker_hp ~= nil then
    S.estatus_pct = tonumber(data.attacker_hp) or 0
  end
  if data.rounds ~= nil then
    S.combat_rounds = tonumber(data.rounds) or 0
  end

  ui.dirty()
end

M.triggers = {
  { name = "hp_bar_1",      pattern = hp_bar_1_pattern,      fn = hp_bar_1 },
  { name = "hp_bar_1_cont", pattern = hp_bar_1_cont_pattern, fn = hp_bar_1_cont },
  { name = "hp_bar_2",      pattern = hp_bar_2_pattern,      fn = hp_bar_2 },
  { name = "hp_bar_2_cont", pattern = hp_bar_2_cont_pattern, fn = hp_bar_2_cont },
  { name = "hp_bar_2_vis",  pattern = hp_bar_2_vis_pattern,  fn = hp_bar_2_vis },
  { name = "hp_bar_3",      pattern = hp_bar_3_pattern,      fn = hp_bar_3 },
  { name = "hp_bar_3_open", pattern = hp_bar_3_open_pattern, fn = hp_bar_3_open },
  { name = "hp_bar_3_cont", pattern = hp_bar_3_cont_pattern, fn = hp_bar_3_cont },
}

return M
