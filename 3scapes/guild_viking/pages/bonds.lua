-- Bonds page: LEGACY's draw_page8
-- (/home/simon/code/3s_scripts_old/lua/guild_viking.lua:12756-12831). Pure
-- builder: lines(width) -> array of ANSI strings, reading state.lua's S and
-- page_opts.lua only.
--
-- Section (read from source top to bottom): Fellowship Bonds
-- (show_bonds_list, the ENTIRE function -- there is no separate
-- standings/reputation section in draw_page8 itself; those live in
-- draw_page9, ported as pages/ranks.lua) -- a per-hirdmadr-pair tie strength,
-- shown as a name pair, a tier label (Strangers/Comrades/Shield-Brothers/
-- Blood-Sworn/Oathbound), and a progress bar toward the next tier's tick
-- threshold. "No bonds data yet" when state.bonds_list is empty.
--
-- Disclosed simplifications/discrepancies (Global Constraints: content
-- fidelity, not pixel fidelity):
--   - LEGACY's row-2 comment says "progress bar + tick count" but the code
--     under it only ever draws the DrawRect bar -- no WindowText call for a
--     tick count exists in the source (TICK_W is computed above via
--     WindowTextWidth and then never used). This port follows the ACTUAL
--     code, not the stale comment, but -- matching every other bar in this
--     codebase (e.g. pages/people.lua's metric_bar_line, which always pairs
--     a pagelib.bar with a "%d%%" readout) -- adds a percent-toward-next-tier
--     number next to the bar for text-mode legibility. That percent is
--     computed from the exact same tier floor/ceiling math LEGACY uses for
--     the pixel bar's fill width, so no new information is introduced.
--   - MUSHclient colors in this source range are 0xBBGGRR (guild_viking.lua
--     line 301); every mapping below was decoded byte-by-byte before
--     choosing a pagelib.C entry. Decoded: tier0 0x444444 -> gray(44,44,44),
--     tier1 0x888888 -> lighter gray(88,88,88), tier2 0x4488FF ->
--     orange(FF,88,44), tier3 0xFFCC00 -> cyan/sky-blue(00,CC,FF), tier4
--     0xFF4444 -> blue(44,44,FF). pagelib.C has no orange or true blue, so
--     tier2 maps to the nearest warm hue (red) and tier4 to the nearest
--     available cool/violet hue (magenta); tier3's decode lands almost
--     exactly on cyan, so that one is an honest match rather than an
--     approximation.
local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")

local S = state.S
local C = pagelib.C

local M = {}

-- guild_viking.lua:12759-12762 (TIER_NAMES/TIER_COLORS) -- see the module
-- header's BGR decode note for the color mapping.
local TIER_NAMES = { [0] = "Strangers", [1] = "Comrades", [2] = "Shield-Brothers",
  [3] = "Blood-Sworn", [4] = "Oathbound" }
local TIER_COLORS = { [0] = C.dim, [1] = C.white, [2] = C.red, [3] = C.cyan, [4] = C.magenta }
-- guild_viking.lua:12763-12764: ticks-within-tier floor/ceiling toward the
-- next tier. Tier 4 (max) has floor == ceiling, i.e. always shown as full.
local TIER_FLOOR = { [0] = 0, [1] = 50000, [2] = 200000, [3] = 600000, [4] = 2160000 }
local TIER_CEIL  = { [0] = 50000, [1] = 200000, [2] = 600000, [3] = 2160000, [4] = 2160000 }

-- Ported from LEGACY's inline abbrev (guild_viking.lua:12768-12775): "F.
-- Lastname" from a full "First Last" name; a single-word name (or none) is
-- returned unabbreviated.
local function abbrev(full)
  if not full or full == "" then return "?" end
  local first, rest = full:match("^(%S+)%s+(.+)$")
  if first and rest then
    return first:sub(1, 1) .. ". " .. rest
  end
  return full
end

local function bond_pct(b)
  local tier = b.tier or 0
  local tfloor = TIER_FLOOR[tier] or 0
  local tceil = TIER_CEIL[tier] or 1
  if tceil <= tfloor then return 100 end
  local pct = math.floor((((b.ticks or 0) - tfloor) / (tceil - tfloor)) * 100 + 0.5)
  if pct < 0 then pct = 0 end
  if pct > 100 then pct = 100 end
  return pct
end

-- Two rows per bond: name pair + right-aligned tier label, then a tier-
-- colored progress bar (guild_viking.lua:12800-12822).
local function bond_rows(add, width, b, id_to_name)
  local tier = b.tier or 0
  local tier_nm = TIER_NAMES[tier] or "?"
  local tier_col = TIER_COLORS[tier] or C.dim

  local hm_a, hm_b = id_to_name[b.id_a], id_to_name[b.id_b]
  local nm_a = (hm_a and abbrev(hm_a.name)) or ("#" .. tostring(b.id_a))
  local nm_b = (hm_b and abbrev(hm_b.name)) or ("#" .. tostring(b.id_b))

  local pair_part = C.white .. nm_a .. "  +  " .. nm_b .. pagelib.RESET
  local tier_part = tier_col .. tier_nm .. pagelib.RESET
  local pad = width - pagelib.visible_width(pair_part) - pagelib.visible_width(tier_part)
  if pad < 1 then pad = 1 end
  add(pagelib.trunc(pair_part .. string.rep(" ", pad) .. tier_part, width))

  local pct = bond_pct(b)
  add(pagelib.trunc("  " .. pagelib.bar(24, pct, 100, tier_col) .. " " .. pct .. "%", width))
end

local function bonds_lines(add, width)
  add(pagelib.header(width, "Fellowship Bonds"))
  local list = S.bonds_list or {}
  if #list == 0 then
    add(pagelib.trunc(C.dim .. "No bonds data yet" .. pagelib.RESET, width))
    return
  end

  -- Sort by ticks descending: strongest bonds first (guild_viking.lua:12782-12785).
  local sorted = {}
  for _, b in ipairs(list) do sorted[#sorted + 1] = b end
  table.sort(sorted, function(a, b) return (a.ticks or 0) > (b.ticks or 0) end)

  local id_to_name = S.hird_by_id or {}
  for _, b in ipairs(sorted) do
    bond_rows(add, width, b, id_to_name)
  end
end

function M.lines(width)
  width = width or 80
  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  if page_opts.get("show_bonds_list") then
    bonds_lines(add, width)
  end

  return lines
end

return M
