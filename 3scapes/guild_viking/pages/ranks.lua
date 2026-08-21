-- Ranks page: LEGACY's draw_page9
-- (/home/simon/code/3s_scripts_old/lua/guild_viking.lua:12832-13212). Pure
-- builder: lines(width) -> array of ANSI strings, reading state.lua's S and
-- page_opts.lua only.
--
-- Section order/gates, read from the source top to bottom:
--   Lineage Standings (show_ranks_standings, 12855-12923) -- relative
--     standing (score/label) with every other lineage, own lineage always
--     sorted first then by score descending.
--   Village Trade Reputation (show_ranks_village_rep AND
--     next(state.village_rep), 12925-12979) -- per-village trade rank with
--     a progress bar toward the next rank (or MAX).
--
-- DISCREPANCY vs the task brief's landmark list ("lineage standings, village
-- reps, grudges, diplo"): draw_page9, read in full, contains ONLY the two
-- sections above. "Reprisal Grudges" (state.grudges) is drawn by
-- draw_page2's city/heat block (gated show_city_heat) -- pages/city.lua,
-- Task 4. "Great Houses" diplomacy (state.diplomacy) is drawn by
-- draw_page_war (gated show_war_houses) -- pages/war.lua, Task 9. Neither
-- section is reachable from draw_page9. Source wins per the plan's Global
-- Constraints; this page ports exactly what draw_page9 draws.
--
-- Disclosed simplifications:
--   - LEGACY draws the Lineage Standings relation as a zero-centered bar
--     (hostile fill grows left from a center tick, friendly fill grows
--     right). pagelib.bar only supports a single left-to-right fill, so this
--     port normalizes score from [-500, 500] to [0, 1000] and renders one
--     ordinary pagelib.bar -- same information (more negative = less filled,
--     more positive = more filled), different shape. `SCORE_THRESHOLDS`
--     (guild_viking.lua:12841, the label cutoffs) is a documentary constant
--     never read by draw_page9 itself (the server already resolves each
--     standing's `label`) -- not ported, same disposition as `TICK_W` in
--     pages/bonds.lua.
--   - MUSHclient colors in this source range are 0xBBGGRR (guild_viking.lua
--     line 301); every mapping below was decoded byte-by-byte first.
--     LABEL_COLORS decodes cleanly onto pagelib.C (Allied/Friendly ->
--     green family, Neutral -> yellow, Cool/Hostile/Feud -> red family --
--     matching the source's own comment names). RANK_COLORS mostly decodes
--     to match its comment's named roles (muted/white/yellow/green/higreen/
--     himagenta), with two exceptions disclosed inline where the LITERAL
--     hex disagrees with the comment's documented intent: rank 5 reuses
--     rank 2's exact hex (0x00FFFF, decoding to yellow) despite the comment
--     calling it "hicyan" -- a LEGACY copy-paste bug -- and rank 7's
--     0x8B4513 is the well-known CSS "saddlebrown" RGB triple used AS IF it
--     were plain RGB, so decoding it via this table's own BGR convention
--     yields a dark blue, not brown. Both follow the documented intent
--     (hicyan / brown) rather than the literal decode, same precedent as
--     pages/people.lua's role-effect color note. pagelib.C has neither a
--     true cyan-vs-yellow-safe slot nor brown, so rank 5 maps to
--     bright_cyan and rank 7 to red (nearest available warm hue).
local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")

local S = state.S
local C = pagelib.C

local M = {}

-- ---------------------------------------------------------------------------
-- Lineage Standings (guild_viking.lua:12839-12923, gated show_ranks_standings)
-- ---------------------------------------------------------------------------

-- guild_viking.lua:12839-12846.
local LABEL_COLORS = {
  Allied = C.bright_green, Friendly = C.green, Neutral = C.yellow,
  Cool = C.red, Hostile = C.bright_red, Feud = C.bright_red,
}

local BAR_MAX, BAR_MIN = 500, -500

local function standing_row(width, s)
  local lbl = s.label or "Neutral"
  local lbl_col = LABEL_COLORS[lbl] or C.dim
  local score = s.score or 0

  local marker = s.is_own and (C.yellow .. "* " .. pagelib.RESET) or "  "
  -- Own lineage: gold-ish name (0x00CCFF decodes to (R=CC,G=CC,B=00), a
  -- yellow-gold); others: light grey (0xCCCCCC) -- guild_viking.lua:12893-12898.
  local name_col = s.is_own and C.yellow or C.white
  local left = marker .. name_col .. (s.name or "?") .. pagelib.RESET

  -- Zero-centered relation normalized to a single left-to-right fill -- see
  -- the module header's disclosed simplification.
  local bar = pagelib.bar(18, score - BAR_MIN, BAR_MAX - BAR_MIN, lbl_col)
  local score_str = (score >= 0 and "+" or "") .. tostring(score)
  local mid = left .. "  " .. bar .. "  " .. lbl_col .. score_str .. pagelib.RESET

  local label_part = lbl_col .. lbl .. pagelib.RESET
  local pad = width - pagelib.visible_width(mid) - pagelib.visible_width(label_part)
  if pad < 1 then pad = 1 end
  return pagelib.trunc(mid .. string.rep(" ", pad) .. label_part, width)
end

local function standings_lines(add, width)
  add(pagelib.header(width, "Lineage Standings"))
  if not next(S.standings or {}) then
    add(pagelib.trunc(C.dim .. "No standings data yet" .. pagelib.RESET, width))
    return
  end

  -- Own lineage first, then by score descending (guild_viking.lua:12866-12871).
  local sorted = {}
  for _, s in pairs(S.standings) do sorted[#sorted + 1] = s end
  table.sort(sorted, function(a, b)
    if a.is_own ~= b.is_own then return a.is_own end
    return (a.score or 0) > (b.score or 0)
  end)

  for _, s in ipairs(sorted) do
    add(standing_row(width, s))
  end
end

-- ---------------------------------------------------------------------------
-- Village Trade Reputation (guild_viking.lua:12925-12979, gated
-- show_ranks_village_rep AND a non-empty state.village_rep)
-- ---------------------------------------------------------------------------

-- guild_viking.lua:12930-12931 -- see the module header's disclosed hex/
-- comment mismatches for ranks 5 and 7.
local RANK_NAMES = { [0] = "Framandi", [1] = "Gestur", [2] = "Kaupmadur", [3] = "Vinur",
  [4] = "Arsmadur", [5] = "Felagi", [6] = "Hofdingi", [7] = "Jarl" }
local RANK_COLORS = { [0] = C.dim, [1] = C.white, [2] = C.yellow, [3] = C.green,
  [4] = C.bright_green, [5] = C.bright_cyan, [6] = C.magenta, [7] = C.red }

local function vrep_row(width, vr)
  local rn = RANK_NAMES[vr.rank] or "Framandi"
  local rc = RANK_COLORS[vr.rank] or C.dim
  local left = rc .. (vr.name or "?") .. pagelib.RESET .. "  " .. rc .. rn .. pagelib.RESET

  if (vr.next_at or 0) > 0 then
    local range = (vr.next_at or 0) - (vr.start_at or 0)
    local progress = (vr.rep or 0) - (vr.start_at or 0)
    if progress < 0 then progress = 0 end
    if range > 0 and progress > range then progress = range end
    local bar = pagelib.bar(16, progress, range > 0 and range or 1, C.green)
    return pagelib.trunc(left .. "  " .. bar .. " " .. progress .. "/" .. range, width)
  end

  -- Max rank: full bar, "MAX" (guild_viking.lua:12968-12971).
  return pagelib.trunc(left .. "  " .. pagelib.bar(16, 1, 1, C.green) ..
    " " .. C.bright_green .. "MAX" .. pagelib.RESET, width)
end

local function village_rep_lines(add, width)
  add(pagelib.header(width, "Village Trade Reputation"))

  -- Sorted by lineage id ascending (guild_viking.lua:12939-12940).
  local ids = {}
  for lid, _ in pairs(S.village_rep) do ids[#ids + 1] = lid end
  table.sort(ids)

  for _, lid in ipairs(ids) do
    add(vrep_row(width, S.village_rep[lid]))
  end
end

function M.lines(width)
  width = width or 80
  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  if page_opts.get("show_ranks_standings") then
    standings_lines(add, width)
  end

  if page_opts.get("show_ranks_village_rep") and next(S.village_rep or {}) then
    village_rep_lines(add, width)
  end

  return lines
end

return M
