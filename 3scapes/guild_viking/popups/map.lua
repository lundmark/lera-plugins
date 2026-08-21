-- Territory Map popup (/vik map): LEGACY guild_viking.lua's draw_page7
-- (12377-12755), TEXT-VIEW branch only (LEGACY's own `show_map_icons=false`
-- default -- the Wang-tile / building-icon branch is a graphical rendering
-- of the exact same cells and is NOT ported, per the plan's "PNG tiles and
-- pixel hotspots do not carry over" ruling). VMAP_SYM_COL (10990-11015) and
-- VMAP_TYPE_LABEL (11018-11029) below are ported verbatim.
--
-- Interaction fidelity: draw_page7's ONLY interactive hotspot family is
-- "vmp_<col>_<row>" (guild_viking.lua:12639-12655), and every one of them
-- is registered via WindowAddHotspot with all five callback slots
-- ("", "", "", "", "") empty -- a pure hover tooltip, no click behavior at
-- all. Ported below as a module-local `hover` info line, updated from
-- on_pointer through the ctx.cell_from_xy contract (see popups.lua's header
-- comment). draw_page7 also builds `vmap_poi_locations`
-- (guild_viking.lua:12695-12728) with a comment claiming a "right-click
-- lookup", but its only would-be reader, `viking_resolve_poi_at`
-- (guild_viking.lua:11770), is never called anywhere in the file -- dead
-- code, confirmed by grep -- so the town list below gets no click handler
-- either: there is nothing live to port.
--
-- Content decision worth disclosing: VMAP_SYM_COL's keys split cleanly into
-- TERRAIN glyphs (t/h/A/f/p/W/r/=/c/./+) and POI/player glyphs
-- (X/M/L/P/S/T/R/F/*/?) -- two disjoint sets. draw_page7 draws a single
-- glyph per cell straight from `state.vmap_rows`, which means the server's
-- feed already embeds POI/player letters into the row string at the right
-- position. This module instead treats `S.vmap_rows` as TERRAIN ONLY and
-- composites `S.vmap_pois` and the player position as two separate overlay
-- passes on top (player wins when both coincide) -- deliberately more
-- defensive than "trust the row string for everything," and an explicit
-- reading of the task brief's three separate bullets (grid / POI overlay /
-- player marker) rather than one combined glyph source.
local pagelib = require("pagelib")
local maplib = require("maplib")
local state = require("state")
local page_opts = require("page_opts")

local S = state.S
local C = pagelib.C
local RESET = pagelib.RESET

-- ---------------------------------------------------------------------------
-- VMAP_SYM_COL (guild_viking.lua:10990-11015), ported verbatim as the
-- symbol -> hex comment pairs; decoded into pagelib.C below.
--
-- BGR decode workbook (byte order 0xBBGGRR: leftmost byte = Blue, middle =
-- Green, rightmost = Red -- same convention as pages/city.lua's,
-- pages/goods.lua's and pages/army.lua's workbooks; this table's own header
-- comment explicitly says "BGR color table"). pagelib.C has ten hues where
-- LEGACY's territory palette effectively uses more, so several literals
-- fold onto the nearest available entry -- the same "orange folds to red"
-- precedent earlier pages set.
--
--   X 0xFFFFFF -> R=FF,G=FF,B=FF  white                -> C.white
--   M 0x0000DD -> R=DD,G=00,B=00  strong red            -> C.bright_red
--   L 0x0055FF -> R=FF,G=55,B=00  red-leaning orange    -> C.red (folded)
--   P 0x00DDFF -> R=FF,G=DD,B=00  yellow-leaning amber  -> C.yellow
--   S 0xFF00FF -> R=FF,G=00,B=FF  magenta               -> C.magenta
--   T 0x00FF66 -> R=66,G=FF,B=00  bright green          -> C.bright_green
--   R 0x8888BB -> R=BB,G=88,B=88  muted slate           -> C.dim (folded)
--   F 0x33BB33 -> R=33,G=BB,B=33  green                 -> C.green
--   * 0x00EEFF -> R=FF,G=EE,B=00  yellow -- see KEEP AND DISCLOSE below
--   ? 0xDDDDFF -> R=FF,G=DD,B=DD  pale pink/lavender    -> C.white (folded)
--   W 0xAA3300 -> R=00,G=33,B=AA  dark blue             -> C.cyan (folded;
--       pagelib.C has no blue)
--   r 0xDDDD44 -> R=44,G=DD,B=DD  light cyan            -> C.bright_cyan
--   = 0x00CCCC -> R=CC,G=CC,B=00  yellow                -> C.yellow
--   t 0x555555 -> R=55,G=55,B=55  dark gray             -> C.dim
--   h 0x00CCCC -> R=CC,G=CC,B=00  yellow (same literal as bridge)
--   A 0x0000CC -> R=CC,G=00,B=00  red                   -> C.red
--   f 0x009900 -> R=00,G=99,B=00  medium green          -> C.green
--   p 0x00CC00 -> R=00,G=CC,B=00  bright green          -> C.bright_green
--   c 0x884400 -> R=00,G=44,B=88  dark blue (same fold as W)
--   . 0x222222 -> R=22,G=22,B=22  near-black            -> C.dim
--   + 0x222222 -> R=22,G=22,B=22  near-black (same literal as road/empty)
--
-- KEEP AND DISCLOSE: "*" (mentor)'s own LEGACY inline comment says "cyan",
-- but the table's own header explicitly declares 0xBBGGRR, and 0x00EEFF
-- decodes to R=FF,G=EE,B=00 -- squarely yellow, not cyan. Treated as an
-- author-comment slip against the table's own declared convention (same
-- class of finding as pages/city.lua's raid-lost-color note) and decoded
-- mechanically: C.yellow.
--
-- Fallback: LEGACY's own default for an unmapped char is `0xFF00FF` (line
-- 12552, `VMAP_SYM_COL[ch] or 0xFF00FF`), which decodes to magenta -- so the
-- fallback below is C.magenta, not an arbitrary choice.
local VMAP_COLOR = {
  X = C.white, M = C.bright_red, L = C.red, P = C.yellow, S = C.magenta,
  T = C.bright_green, R = C.dim, F = C.green, ["*"] = C.yellow, ["?"] = C.white,
  W = C.cyan, r = C.bright_cyan, ["="] = C.yellow, t = C.dim, h = C.yellow,
  A = C.red, f = C.green, p = C.bright_green, c = C.cyan, ["."] = C.dim,
  ["+"] = C.dim,
}
local VMAP_COLOR_FALLBACK = C.magenta

-- Type -> label (guild_viking.lua:11018-11029), ported verbatim.
local VMAP_TYPE_LABEL = {
  capital    = "Capital",
  lineage    = "Lineage",
  player     = "Settlement",
  seer       = "Seer",
  blot       = "Blot",
  ruins      = "Ruins",
  farm       = "Farm",
  mentor_ber = "Mentor",
  mentor_see = "Mentor",
  mentor_jarl= "Mentor",
}

-- Reverse (symbol-keyed) map for VMAP_TYPE_LABEL's types. LEGACY never
-- needed this table itself (draw_page7 reads the symbol straight off
-- state.vmap_rows -- see the module doc comment above); it is a derived
-- table this port needs because it overlays POIs by type onto a
-- terrain-only grid.
local POI_TYPE_SYM = {
  capital = "M", lineage = "L", player = "P", seer = "S", blot = "T",
  ruins = "R", farm = "F",
  mentor_ber = "*", mentor_see = "*", mentor_jarl = "*",
}

-- Legend entries (guild_viking.lua:12406-12413), ported verbatim (glyph +
-- label text unchanged; color resolved through VMAP_COLOR above instead of
-- the raw hex, same as the grid itself).
local LEGEND = {
  { sym = "t", lbl = "Tund" }, { sym = "h", lbl = "Hill" }, { sym = "A", lbl = "Mtn" },
  { sym = "f", lbl = "Frst" }, { sym = "p", lbl = "Plns" }, { sym = "W", lbl = "Watr" },
  { sym = "=", lbl = "Brg" },  { sym = "+", lbl = "Road" },
  { sym = "M", lbl = "Cap" },  { sym = "L", lbl = "Lin" },  { sym = "P", lbl = "Set" },
  { sym = "X", lbl = "You" },  { sym = "S", lbl = "Seer" }, { sym = "T", lbl = "Blot" },
  { sym = "R", lbl = "Ruin" }, { sym = "F", lbl = "Farm" }, { sym = "*", lbl = "Ment" },
}

-- Hover-tooltip vocabulary (guild_viking.lua:12500-12505), ported verbatim.
local VMAP_TIP_TERR = {
  t = "Tundra", h = "Hills", A = "Mountains", f = "Forest",
  p = "Plains", ["."] = "Plains", W = "Open water", r = "River", c = "Coast",
  ["="] = "Bridge", ["+"] = "Road",
}
local VMAP_TIP_SYM = {
  M = "Capital", L = "Lineage hall", P = "Settlement",
  S = "Seer hut", T = "Blot grove", R = "Ruins", F = "Farm", ["*"] = "Mentor",
  X = "You", ["?"] = "Unknown settlement",
}

-- vmap_display_name (guild_viking.lua:11031-11034), ported verbatim.
local function display_name(name)
  if not name or name == "" then return "" end
  return (name:gsub("^%l", string.upper))
end

-- Town-list POI types (guild_viking.lua:12670-12672), sort order
-- (12676-12684) and column abbreviation/color (12697-12706), ported
-- verbatim (all ten types happen to be exactly VMAP_TYPE_LABEL's keys).
local TOWN_SORT_ORDER = {
  capital = 1, seer = 2, blot = 2, ruins = 2, farm = 2,
  mentor_ber = 2, mentor_see = 2, mentor_jarl = 2,
  lineage = 3, player = 4,
}
local TOWN_SHORT = {
  capital = "Cap", lineage = "Lin", player = "Set",
  seer = "Seer", blot = "Blot", ruins = "Ruin",
  farm = "Farm", mentor_ber = "Mentor", mentor_see = "Mentor", mentor_jarl = "Mentor",
}

local M = {}
M.title = "Territory Map"

-- Module-local hover/info line (the interaction-fidelity port of the
-- vmp_* tooltip -- see the pointer section below). Declared here, ahead of
-- every function that reads or writes it, so it is a proper upvalue rather
-- than an accidental global.
local hover = ""

-- ---------------------------------------------------------------------------
-- Grid construction
-- ---------------------------------------------------------------------------

local function terrain_glyph(r, c)
  local row = S.vmap_rows[r] or ""
  local ch = row:sub(c + 1, c + 1)
  if ch == "" then ch = "." end
  return ch
end

-- { y*w+x -> poi } lookup (mirrors draw_page7's own `poi_at`,
-- guild_viking.lua:12506-12513).
local function poi_lookup()
  local at = {}
  local w = S.vmap_w or 0
  for _, poi in ipairs(S.vmap_pois or {}) do
    if poi.x ~= nil and poi.y ~= nil and poi.x >= 0 and poi.y >= 0 then
      at[poi.y * w + poi.x] = poi
    end
  end
  return at
end

local function is_player_cell(c, r)
  return (S.vmap_px or -1) >= 0 and S.vmap_px == c and S.vmap_py == r
end

local function make_grid(poi_at)
  local w, h = S.vmap_w or 0, S.vmap_h or 0
  return {
    w = w, h = h,
    cell = function(c, r)
      if is_player_cell(c, r) then
        return { glyph = "X", color = VMAP_COLOR.X }
      end
      local poi = poi_at[r * w + c]
      if poi then
        local sym = POI_TYPE_SYM[poi.type] or "?"
        return { glyph = sym, color = VMAP_COLOR[sym] or VMAP_COLOR_FALLBACK }
      end
      local ch = terrain_glyph(r, c)
      return { glyph = ch, color = VMAP_COLOR[ch] or VMAP_COLOR_FALLBACK }
    end,
  }
end

-- Edge passability strings are "0" (blocked) / "1" (passable) per-column
-- characters, one string per 0-based row (state.lua's own documented
-- convention for both vmap_east_edges and vmap_south_edges). Only an
-- EXPLICIT "0" draws a wall; a missing row/char (no data for that edge)
-- draws nothing, rather than defaulting to "blocked" or "open" for data
-- that was simply never sent.
local function edge_blocked(edge_rows, r, c)
  local s = edge_rows[r]
  if not s then return false end
  return s:sub(c + 1, c + 1) == "0"
end

local function east_edge(c, r) return edge_blocked(S.vmap_east_edges or {}, r, c) end
local function south_edge(c, r) return edge_blocked(S.vmap_south_edges or {}, r, c) end

-- south_edge is passed to maplib only when there is at least one south-edge
-- row of data -- maplib's own doc calls vertical space "expensive," and
-- unconditionally doubling every grid's height for a field that is empty
-- for most of the game would waste it for nothing. east_edge has no such
-- cost (maplib always reserves the east slot's width regardless), so it is
-- always passed.
local function grid_opts()
  local opts = { east_edge = east_edge }
  if next(S.vmap_south_edges or {}) ~= nil then
    opts.south_edge = south_edge
  end
  return opts
end

-- ---------------------------------------------------------------------------
-- Pre-grid lines (header + position + legend) -- shared by lines(),
-- geometry() and grid_line_offset() so the three can never drift apart.
-- ---------------------------------------------------------------------------

local function legend_entries()
  local out = {}
  for _, e in ipairs(LEGEND) do
    out[#out + 1] = { glyph = e.sym, color = VMAP_COLOR[e.sym], label = e.lbl }
  end
  return out
end

local function pre_grid_lines(width)
  local out = { pagelib.header(width, "Territory Map") }
  if (S.vmap_px or -1) >= 0 then
    out[#out + 1] = pagelib.kv(width, "Position:",
      string.format("(%d, %d)", S.vmap_px, S.vmap_py))
  end
  for _, l in ipairs(maplib.legend(width, legend_entries())) do
    out[#out + 1] = l
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Town list (guild_viking.lua:12666-12750, gated show_map_towns). LEGACY
-- lays this out as a fixed-pixel 2-column scrolling area; ported here as a
-- 2-up text flow with the same sort order, abbreviation and per-type color.
-- ---------------------------------------------------------------------------

local function town_entry_text(poi)
  local prefix = (TOWN_SHORT[poi.type] or "?") .. " "
  local name = display_name(poi.name or "")
  if poi.owner and poi.owner ~= "" then
    name = name .. " (" .. display_name(poi.owner) .. ")"
  end
  local sym = POI_TYPE_SYM[poi.type]
  local color = (sym and VMAP_COLOR[sym]) or C.white
  return C.dim .. prefix .. RESET .. color .. name .. RESET
end

local function town_lines(width)
  local entries = {}
  for _, poi in ipairs(S.vmap_pois or {}) do
    if TOWN_SORT_ORDER[poi.type] then entries[#entries + 1] = poi end
  end
  if #entries == 0 then return {} end

  table.sort(entries, function(a, b)
    local oa = TOWN_SORT_ORDER[a.type] or 99
    local ob = TOWN_SORT_ORDER[b.type] or 99
    if oa ~= ob then return oa < ob end
    return display_name(a.name or ""):lower() < display_name(b.name or ""):lower()
  end)

  local out = { pagelib.header(width, "Map Locations") }
  local half = math.floor(width / 2)
  local col_w = { half, math.max(0, width - half - 1) }
  local i = 1
  while i <= #entries do
    local left = pagelib.trunc(town_entry_text(entries[i]), col_w[1])
    local right = ""
    if entries[i + 1] then
      right = pagelib.trunc(town_entry_text(entries[i + 1]), col_w[2])
    end
    out[#out + 1] = left .. " " .. right
    i = i + 2
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Public renderer contract (popups.lua)
-- ---------------------------------------------------------------------------

function M.lines(width)
  local out = pre_grid_lines(width)

  if (S.vmap_w or 0) == 0 then
    out[#out + 1] = pagelib.trunc(C.dim .. "No data - enable with: vtoggle mip_map" .. RESET, width)
    return out
  end

  local poi_at = poi_lookup()
  local grid = make_grid(poi_at)
  for _, l in ipairs(maplib.render(grid, grid_opts())) do
    out[#out + 1] = l
  end

  out[#out + 1] = hover ~= "" and pagelib.trunc(hover, width) or ""

  if page_opts.get("show_map_towns") then
    for _, l in ipairs(town_lines(width)) do out[#out + 1] = l end
  end

  return out
end

-- geometry()/grid_line_offset(): the ctx.cell_from_xy contract popups.lua
-- documents. nil when there is no grid to hit-test (no-data fallback).
function M.geometry(width)
  if (S.vmap_w or 0) == 0 then return nil end
  local grid = make_grid(poi_lookup())
  return maplib.geometry(grid, grid_opts())
end

function M.grid_line_offset(width)
  return #pre_grid_lines(width)
end

-- ---------------------------------------------------------------------------
-- Pointer: hover-only, per the interaction-fidelity finding above -- there
-- is no click action to port, so on_pointer only ever updates `hover` and
-- never returns true (never consumes the event) and never calls mud.send.
-- ---------------------------------------------------------------------------

local function cell_tip(poi_at, c, r)
  local tip
  if is_player_cell(c, r) then
    tip = VMAP_TIP_SYM.X
  else
    local poi = poi_at[r * (S.vmap_w or 0) + c]
    if poi then
      tip = (VMAP_TYPE_LABEL[poi.type] or "Location") .. ": " .. display_name(poi.name or "?")
      if poi.owner and poi.owner ~= "" then
        tip = tip .. "  Owner: " .. display_name(poi.owner)
      end
    else
      local ch = terrain_glyph(r, c)
      tip = VMAP_TIP_SYM[ch] or VMAP_TIP_TERR[ch] or "Terrain"
    end
  end
  return string.format("(%d,%d)  %s", c, r, tip)
end

function M.on_pointer(ev, ctx)
  if not ctx.cell_from_xy then return nil end
  if ev.kind ~= "move" and ev.kind ~= "down" then return nil end
  local c, r = ctx.cell_from_xy(ev.x, ev.y)
  if not c then return nil end
  hover = cell_tip(poi_lookup(), c, r)
  ui.dirty()
  return nil
end

return M
