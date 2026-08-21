-- Battle Board popup content (rendered by popups/war.lua's composite when a
-- battle is active -- see that module's mode-condition comment): the
-- tactical board inside LEGACY guild_viking.lua's `draw_page_war`
-- (~14084-14603) plus the shared battle-menu infrastructure above it
-- (`viking_close_battle_menu`/`viking_show_battle_menu`/
-- `viking_battle_menu_pick`, 13366-13420) and the cell/button handlers
-- (`viking_battle_down`/`viking_battle_button_click`/`viking_battle_click`,
-- 13422-13510). ASCII (text-view) branch only -- same
-- `page_opts.show_war_ascii` disclosure as popups/war_campaign.lua's header
-- comment: pixel/PNG rendering has no ANSI equivalent, so the ascii
-- glyph/colour pairs are the only ones ever reachable here regardless of
-- the opt.
--
-- `state.battle_selected` (LEGACY, order-phase click-to-move) is recreated
-- below as the module-local `selected` (`{ bid=, coord= }` | nil); `lines`
-- stays pure, only `on_pointer` ever assigns it.
--
-- Rosters (In reserve/Deployed for the deploy phase, Your host/Enemy for
-- the turn phase, 14540-14599) are DELIBERATELY NOT duplicated here --
-- pages/war.lua's `deploy_lines`/`turn_side_lines` already port them
-- verbatim as part of the pane's always-visible text overview, and every
-- name/cost/position/morale/leader they show is also surfaced through this
-- module's own interaction affordances (the deploy right-click menu lists
-- the reserve by name/cost/coord already; hover text gives a clicked
-- unit's name/side/size/morale). Duplicating the full roster list here
-- would be pure redundancy, not missing fidelity -- see the "prison panel
-- stays in the pane" ruling this task's brief already makes for the exact
-- same reason.
--
-- Grid: NO col_headers/row_headers, same disclosed simplification (and the
-- same latent maplib row_header_width mismatch it sidesteps) as
-- popups/war_campaign.lua's header comment explains. Hover text carries
-- the "A5"-style coord instead.
--
-- Coordinate mapping: LEGACY draws game row 1 at the BOTTOM of the board
-- and game row h at the TOP (`for ri = 1, h do local r = h - ri + 1 ...`,
-- 14177-14178) -- row 1 sits under your own deploy zone (`in_dz = r <= dz`,
-- 14184, dz counted from row 1). maplib's grid row is 0-based top-to-bottom
-- (row 0 = the first line render() emits), so the inverse here is
-- `r_game = h - gr` for maplib row `gr` (gr=0 -> r_game=h at the top,
-- gr=h-1 -> r_game=1 at the bottom) -- columns are NOT reversed
-- (`c_game_letter = string.char(65 + gc)`, same left-to-right order as the
-- campaign map). `coord(gc, gr) = string.char(65+gc) .. tostring(h - gr)`
-- is used everywhere below, both for rendering and for inverting a
-- ctx.cell_from_xy hit back into the "A5" string BATTLE's own `u.coord`
-- and this module's send commands both key on.
local pagelib = require("pagelib")
local maplib = require("maplib")
local state = require("state")

local S = state.S
local C = pagelib.C
local RESET = pagelib.RESET

local M = {}
M.title = "Battle Board"

-- state.battle_selected, recreated as a module-local (see header comment).
local selected = nil -- { bid=, coord= } | nil

-- Module-local hover/info line, same pattern as every other board popup.
local hover = ""

-- UGLYPH (guild_viking.lua:14101-14104), ported verbatim.
local UGLYPH = {
  skirmishers = "K", bogmenn = "A", shieldwall = "S", huscarls = "H",
  berserkir = "B", moose = "M", ally_levy = "G", siege = "T",
  foe_raiders = "R", foe_levy = "L", foe_hird = "G",
}

-- BTERR_NAME (guild_viking.lua:14157-14158), ported verbatim.
local BTERR_NAME = {
  ["."] = "plains", ["^"] = "hills", ["*"] = "forest",
  w = "marsh", ["="] = "fjord", x = "chokepoint", ["#"] = "rampart",
}

-- btile ASCII branch (guild_viking.lua:14126-14134), ported verbatim.
-- BGR decode workbook (0xBBGGRR):
--   ^ hills   0xFFFFFF -> white                                -> C.white
--   * forest  0x33CC33 -> R=33,G=CC,B=33 green                 -> C.green
--   w marsh   0xFF0000 -> R=00,G=00,B=FF blue, "@blue"; no blue
--       in pagelib.C -> folded to nearest (same "no blue -> cyan"
--       precedent every other module's workbook uses)            -> C.cyan
--   = fjord   0xFFFF00 -> R=00,G=FF,B=FF cyan, "@hicyan"        -> C.bright_cyan
--   x choke   0x3333FF -> R=FF,G=33,B=33 red, "@hired" (hi red) -> C.bright_red
--   # rampart 0x00FFFF -> R=FF,G=FF,B=00 yellow, "@yellow"      -> C.yellow
--   . plains  0x808080 -> grey, "@viking_muted (hiblack)"       -> C.dim
local BTILE_ASCII = {
  ["^"] = { glyph = "^", color = C.white },
  ["*"] = { glyph = "*", color = C.green },
  w     = { glyph = "~", color = C.cyan },
  ["="] = { glyph = "=", color = C.bright_cyan },
  x     = { glyph = "x", color = C.bright_red },
  ["#"] = { glyph = "#", color = C.yellow },
}
local BTILE_DEFAULT = { glyph = ".", color = C.dim }

local function terrain_glyph(ch)
  local t = BTILE_ASCII[ch] or BTILE_DEFAULT
  return t.glyph, t.color
end

local function coord_at(gc, gr, h)
  return string.char(65 + gc) .. tostring(h - gr)
end

local function unit_at(b, coord)
  for _, u in ipairs(b.units or {}) do
    if u.coord == coord then return u end
  end
  return nil
end

-- Field-works overlay + deploy-zone tint (guild_viking.lua:14263-14276's
-- ascii branch: 'v' stakes (0x00FFFF -> yellow, C.yellow), 'u' dugout
-- (0xFFFFFF -> white, C.white), else an empty deploy-zone cell shows '+'
-- (0xFFFF00 -> cyan, same literal/tag as the fjord glyph -> C.bright_cyan).
local function works_or_terrain_cell(ch, wch, in_dz)
  if wch == "v" then return { glyph = "v", color = C.yellow } end
  if wch == "u" then return { glyph = "u", color = C.white } end
  if in_dz and ch ~= "#" then return { glyph = "+", color = C.bright_cyan } end
  local glyph, color = terrain_glyph(ch)
  return { glyph = glyph, color = color }
end

-- Ported from guild_viking.lua:14113-14121/14193-14227's ascii branch: the
-- letter is the unit's type, the colour its side (you=bright_green,
-- foe=bright_red -- 0x00FF00/0x3333FF, same decode/tag pattern as
-- war_campaign's "A"/enemy-army markers); a duplicated type+side glyph
-- swaps the letter for its plain ordinal digit (`sup(n) = tostring(n)`,
-- 14110, 14201).
local function make_grid(b)
  local w, h = b.width or 8, b.height or 8
  local dz = b.dz or 2
  local deploying = (b.phase == "deploy")

  return {
    w = w, h = h,
    cell = function(gc, gr)
      local r_game = h - gr
      local coord = coord_at(gc, gr, h)
      local u = unit_at(b, coord)
      local cell
      if u then
        local g = UGLYPH[u.utype or ""] or "*"
        if (u.ord or 0) > 0 then g = tostring(u.ord) end
        cell = { glyph = g, color = (u.side == "you") and C.bright_green or C.bright_red }
      else
        local rowstr = (b.terrain_rows and b.terrain_rows[r_game]) or string.rep(".", w)
        local ch = rowstr:sub(gc + 1, gc + 1)
        if ch == "" then ch = "." end
        local wch = (b.works_rows and b.works_rows[r_game] and
          b.works_rows[r_game]:sub(gc + 1, gc + 1)) or "."
        local in_dz = deploying and (r_game <= dz)
        cell = works_or_terrain_cell(ch, wch, in_dz)
      end
      if selected and selected.coord == coord then cell.sel = true end
      return cell
    end,
  }
end

-- Legend (guild_viking.lua:14375-14449): "green = you"/"red = foe"/
-- "+ deploy" as plain coloured text (LEGACY draws these as words, not
-- glyph+label pairs, so they're built directly rather than through
-- maplib.legend); the unit-type-letter and terrain/works keys ARE
-- glyph+label pairs (14380-14384, 14421-14449) -- their key-letter colour
-- in LEGACY is a flat grey (0xCCCCCC) regardless of side or hue, matching
-- popups/sea.lua's own "0xCCCCCC -> light gray -> C.white" precedent.
local UNIT_LEGEND = {
  { glyph = "M", color = C.white, label = "moose" }, { glyph = "B", color = C.white, label = "berserk" },
  { glyph = "H", color = C.white, label = "huscarl" }, { glyph = "S", color = C.white, label = "wall" },
  { glyph = "K", color = C.white, label = "skirm" }, { glyph = "A", color = C.white, label = "bows" },
  { glyph = "R", color = C.white, label = "raiders" }, { glyph = "L", color = C.white, label = "levy" },
  { glyph = "G", color = C.white, label = "hird" },
}
local TERRAIN_LEGEND = {
  { glyph = "^", color = C.white, label = "hills" }, { glyph = "*", color = C.green, label = "forest" },
  { glyph = "=", color = C.bright_cyan, label = "fjord" }, { glyph = "~", color = C.cyan, label = "marsh" },
  { glyph = "#", color = C.yellow, label = "rampart" }, { glyph = "x", color = C.bright_red, label = "choke" },
  { glyph = ".", color = C.dim, label = "plains" },
  { glyph = "v", color = C.yellow, label = "stakes" }, { glyph = "u", color = C.white, label = "dugout" },
}

local function legend_lines(width, b)
  local deploying = (b.phase == "deploy")
  local out = {}
  local side_line = C.bright_green .. "green = you" .. RESET .. "  " .. C.bright_red .. "red = foe" .. RESET
  if deploying then side_line = side_line .. "  " .. C.bright_cyan .. "+ deploy" .. RESET end
  out[#out + 1] = pagelib.trunc(side_line, width)
  for _, l in ipairs(maplib.legend(width, UNIT_LEGEND)) do out[#out + 1] = l end
  for _, l in ipairs(maplib.legend(width, TERRAIN_LEGEND)) do out[#out + 1] = l end
  return out
end

-- The three one-shot action buttons (bbtn_begin/bbtn_go/bbtn_abandon,
-- guild_viking.lua:14470-14493) are not grid-shaped, so ctx.cell_from_xy
-- can't hit-test them -- ported LIVE the same way popups/sea.lua ports its
-- own pixel buttons: one "[Actions]" line, hit-tested via ctx.line_from_y,
-- opening require("menu") with exactly these commands.
local function actions_items(b)
  local items = {}
  if b.phase == "deploy" then
    items[#items + 1] = { label = "Begin Battle", value = "vbattle begin" }
  else
    items[#items + 1] = { label = "Advance Turn", value = "vbattle go" }
  end
  items[#items + 1] = { label = "Abandon", value = "vbattle abandon" }
  return items
end

local function actions_line_text(b)
  local labels = {}
  for _, it in ipairs(actions_items(b)) do labels[#labels + 1] = it.label end
  return C.yellow .. "[Actions] " .. table.concat(labels, " | ") .. RESET
end

local function open_actions_menu(b)
  require("menu").open({
    items = actions_items(b),
    title = "Battle Actions",
    on_select = function(value)
      if type(value) == "string" then mud.send(value) end
    end,
  })
end

-- Pre-grid lines (header + the "no battle" short-circuit), shared by
-- lines()/geometry()/grid_line_offset() so the three can never drift apart.
local function pre_grid_lines(width)
  local b = S.battle
  if not b then
    return {
      pagelib.header(width, "Battle Board"),
      pagelib.trunc(C.dim .. "No battle underway." .. RESET, width),
    }, false
  end
  local mode_lbl = (b.mode or "field"):gsub("siege_attack", "siege"):gsub("siege_defend", "defence")
  local hdr
  if b.phase == "deploy" then
    hdr = string.format("Deploying vs %s  (%s)", b.target or "?", mode_lbl)
  else
    hdr = string.format("Battle vs %s  --  turn %d", b.target or "?", b.turn or 0)
  end
  return { pagelib.header(width, hdr) }, true
end

-- Builds the full line array plus the 1-based index of the "[Actions]"
-- line (nil if unreachable), in lockstep by construction -- same
-- discipline popups/sea.lua's pre_chart_lines/actions_line_index follow.
local function build_lines(width)
  local out, has_grid = pre_grid_lines(width)
  if not has_grid then return out, nil end

  local b = S.battle
  for _, l in ipairs(maplib.render(make_grid(b), {})) do out[#out + 1] = l end
  out[#out + 1] = hover ~= "" and pagelib.trunc(hover, width) or ""
  for _, l in ipairs(legend_lines(width, b)) do out[#out + 1] = l end
  out[#out + 1] = pagelib.trunc(string.format(
    "%sCommand %d/%d%s   %sFraegd %d%s",
    C.yellow, b.spent or 0, b.budget or 0, RESET,
    C.bright_cyan, b.war_points or S.war_points or 0, RESET), width)
  out[#out + 1] = pagelib.trunc(actions_line_text(b), width)
  return out, #out
end

function M.lines(width)
  local out = build_lines(width)
  return out
end

-- Same "width-invariant in practice" reasoning as popups/sea.lua's own
-- ACTIONS_PROBE_WIDTH: nothing rendered before the actions line ever
-- reflows by width (pagelib.trunc/header/legend/maplib.render all emit a
-- fixed number of output lines regardless of width), so on_pointer below
-- can call this with a fixed representative width rather than needing the
-- wrapper's actual last-rendered width.
local ACTIONS_PROBE_WIDTH = 76
function M.actions_line_index(width)
  local _, idx = build_lines(width or ACTIONS_PROBE_WIDTH)
  return idx
end

function M.geometry(width)
  local _, has_grid = pre_grid_lines(width)
  if not has_grid then return nil end
  return maplib.geometry(make_grid(S.battle), {})
end

function M.grid_line_offset(width)
  local out = pre_grid_lines(width)
  return #out
end

-- viking_battle_click's tooltip (guild_viking.lua:14337-14359), flattened
-- to one line, "\r\n" collapsed to "  " like every other module's hover.
local function hover_text(b, gc, gr)
  local w, h = b.width or 8, b.height or 8
  local r_game = h - gr
  local coord = coord_at(gc, gr, h)
  local u = unit_at(b, coord)
  local rowstr = (b.terrain_rows and b.terrain_rows[r_game]) or string.rep(".", w)
  local ch = rowstr:sub(gc + 1, gc + 1)
  if ch == "" then ch = "." end
  local wch = (b.works_rows and b.works_rows[r_game] and
    b.works_rows[r_game]:sub(gc + 1, gc + 1)) or "."
  local deploying = (b.phase == "deploy")
  local dz = b.dz or 2
  local in_dz = deploying and (r_game <= dz)

  local tip
  if u then
    tip = coord .. "  " .. (u.label or "unit") .. (u.side == "you" and " (yours)" or " (enemy)")
    if u.size ~= nil then tip = tip .. string.format("  %d men", u.size) end
    if u.morale ~= nil then tip = tip .. string.format("  morale %d", u.morale) end
    tip = tip .. "  on " .. (BTERR_NAME[ch] or "plains")
  else
    tip = coord .. "  " .. (BTERR_NAME[ch] or "plains")
  end
  if wch == "v" then
    tip = tip .. "  stakes"
  elseif wch == "u" then
    tip = tip .. "  dugout"
  end
  if deploying then
    if not u and in_dz then tip = tip .. "  (deploy zone)" end
    tip = tip .. "  -- Right-click: deploy/undeploy/fortify"
  else
    tip = tip .. "  -- Click: select a unit, then click a square to move"
  end
  return tip
end

-- viking_show_battle_menu's deploy-phase item set (built inline by
-- viking_battle_click, 13453-13477), ported verbatim as label/value pairs.
-- `value` is the exact command string for an actionable row, or `false`
-- for a decorative one ("Nothing left in reserve", "Not your deploy zone",
-- "Cancel") -- on_select only ever mud.send()s a string, same convention
-- popups/cityplan.lua's context menu already uses.
local function open_deploy_menu(b, coord, u, r_game)
  local dz = b.dz or 2
  local in_dz = r_game <= dz
  local items = {}

  if u and u.side == "you" then
    items[#items + 1] = { label = "Undeploy " .. (u.label or "unit"),
      value = "vbattle undeploy " .. (u.bid or 0) }
  elseif in_dz then
    local res = b.reserve or {}
    if #res == 0 then
      items[#items + 1] = { label = "Nothing left in reserve", value = false }
    else
      for _, ru in ipairs(res) do
        items[#items + 1] = { label = string.format("Deploy %dx %s (%d pts)",
          ru.size or 0, ru.label or "?", ru.cost or 0),
          value = "vbattle deploy " .. (ru.uid or 0) .. " " .. coord }
      end
    end
    items[#items + 1] = { label = "Fortify: Stakes", value = "vbattle fortify stakes " .. coord }
    items[#items + 1] = { label = "Fortify: Dugout", value = "vbattle fortify dugout " .. coord }
  else
    items[#items + 1] = { label = "Not your deploy zone", value = false }
  end
  items[#items + 1] = { label = "Cancel", value = false }

  require("menu").open({
    items = items,
    title = coord .. (u and ("  " .. (u.label or "")) or "  empty tile"),
    on_select = function(value)
      if type(value) == "string" then mud.send(value) end
    end,
  })
end

-- viking_battle_click (guild_viking.lua:13435-13510), ported verbatim.
-- Deploy phase: any non-right click just closes any open menu and
-- consumes (left click does nothing on the board itself, deploy actions
-- are right-click-menu only); a right click opens open_deploy_menu.
-- Turn/order phase: a right click always cancels the current selection; a
-- non-right click selects your own unit, or -- when one is already
-- selected -- sends the move order (clicking the SAME cell deselects
-- instead, matching LEGACY's `info.coord == state.battle_selected.coord`
-- check exactly).
local function handle_click(b, gc, gr, button)
  local h = b.height or 8
  local r_game = h - gr
  local coord = coord_at(gc, gr, h)
  local u = unit_at(b, coord)
  local is_rh = (button == "right")

  if b.phase == "deploy" then
    if not is_rh then
      require("menu").close()
      return
    end
    open_deploy_menu(b, coord, u, r_game)
    return
  end

  if is_rh then
    selected = nil
    require("menu").close()
    return
  end

  if not selected then
    if u and u.side == "you" then
      selected = { bid = u.bid, coord = u.coord }
    end
  else
    if coord == selected.coord then
      selected = nil
    else
      mud.send("vbattle order " .. selected.bid .. " " .. coord)
      selected = nil
    end
  end
end

-- bcell_* hotspots wire BOTH a MouseDown (viking_battle_down, unconditional
-- `return true`) and a MouseUp (viking_battle_click) -- unlike
-- war_campaign's bcamp_* cells, a battle-board "down" IS consumed here.
function M.on_pointer(ev, ctx)
  local b = S.battle
  if not b then return nil end

  if ev.kind == "down" and ctx.line_from_y then
    local idx = M.actions_line_index()
    if idx and ctx.line_from_y(ev.y) == idx then
      open_actions_menu(b)
      return true
    end
  end

  if not ctx.cell_from_xy then return nil end

  if ev.kind == "move" then
    local gc, gr = ctx.cell_from_xy(ev.x, ev.y)
    if not gc then return nil end
    hover = hover_text(b, gc, gr)
    ui.dirty()
    return nil
  end

  if ev.kind == "down" then
    local gc, gr = ctx.cell_from_xy(ev.x, ev.y)
    if not gc then return nil end
    hover = hover_text(b, gc, gr)
    ui.dirty()
    return true
  end

  if ev.kind == "up" then
    local gc, gr = ctx.cell_from_xy(ev.x, ev.y)
    if not gc then return nil end
    handle_click(b, gc, gr, ev.button)
    ui.dirty()
    return true
  end

  return nil
end

return M
