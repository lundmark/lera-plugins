-- guild_viking /vik war (War popup: campaign map + battle board composite)
-- unit tests. Run from the lera-plugins repo root with LERA_ROOT pointing
-- at a built Lera checkout.
package.path = "3scapes/guild_viking/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

local function find_plain(lines, needle)
  for _, l in ipairs(lines) do
    if l:find(needle, 1, true) then return true end
  end
  return false
end

-- ---- lera API stubs (same shape as guild_viking_popup_cityplan_test.lua) --
local function make_rect(x, y, w, h)
  return {
    x = function() return x end, y = function() return y end,
    w = function() return w end, h = function() return h end,
  }
end

local drawn
local function reset_drawn() drawn = { ansi = {} } end
reset_drawn()

local dirty_count = 0
ui = {
  dirty = function() dirty_count = dirty_count + 1 end,
  rect = function(x, y, w, h) return make_rect(x, y, w, h) end,
  text_ansi = function(r, s) drawn.ansi[#drawn.ansi + 1] = { x = r:x(), y = r:y(), s = s } end,
}

local render_pass = "local"
lera = { render_pass = function() return render_pass end, time = function() return 1000 end,
         version = function() return "test" end }

local send_calls = {}
mud = { send = function(s) send_calls[#send_calls + 1] = s end }

local printed = {}
buffer = {
  color_print = function(...)
    local args = { ... }
    local parts = {}
    for i = 3, #args, 3 do
      parts[#parts + 1] = tostring(args[i])
    end
    printed[#printed + 1] = table.concat(parts)
  end,
}

-- ---- wm.popup facade stub ---------------------------------------------------
local is_open_flag = false
local current_open = nil
local opens = {}
local close_count = 0
local function finish_popup()
  local old = current_open
  current_open = nil
  is_open_flag = false
  close_count = close_count + 1
  if old and old.opts and old.opts.on_close then old.opts.on_close() end
end
package.loaded["wm"] = {
  popup = {
    open = function(renderer, opts)
      if is_open_flag then finish_popup() end
      current_open = { renderer = renderer, opts = opts }
      is_open_flag = true
      opens[#opens + 1] = current_open
      return true
    end,
    close = function()
      if not is_open_flag then return false end
      finish_popup()
      return true
    end,
    is_open = function() return is_open_flag end,
  },
}

-- ---- menu stub (require("menu") facade) ------------------------------------
local last_menu_open = nil
local menu_close_count = 0
package.loaded["menu"] = {
  open = function(opts) last_menu_open = opts end,
  close = function() menu_close_count = menu_close_count + 1; last_menu_open = nil end,
  is_open = function() return last_menu_open ~= nil end,
}
local function menu_item_labels(opts)
  local labels = {}
  for _, it in ipairs(opts.items or {}) do
    labels[#labels + 1] = it.label
  end
  return labels
end
local function menu_has_label(opts, substr)
  for _, l in ipairs(menu_item_labels(opts)) do
    if tostring(l):find(substr, 1, true) then return true end
  end
  return false
end
local function menu_select(opts, label_substr)
  for _, it in ipairs(opts.items or {}) do
    if tostring(it.label):find(label_substr, 1, true) then
      opts.on_select(it.value)
      return true
    end
  end
  return false
end

local pagelib = require("pagelib")
local maplib = require("maplib")
local state = require("state")
local popups = require("popups")
local war_campaign = require("popups.war_campaign")
local war_battle = require("popups.war_battle")
local war = require("popups.war")

-- ---- real ingestion pipeline (protocol.ingest -> handlers.kingdom) -- the
-- standing lesson: fixtures MUST route through protocol.ingest + the real
-- handlers, never direct S. pokes.
local protocol = require("protocol")
local kingdom = require("handlers.kingdom")
for key, fn in pairs(kingdom) do
  if key ~= "_patterns" then protocol.handler(key, fn) end
end
for _, p in ipairs(kingdom._patterns or {}) do
  protocol.pattern_handler(p.pattern, p.fn)
end

local S = state.S
local C, RESET = pagelib.C, pagelib.RESET
local REV_ON, REV_OFF = "\27[7m", "\27[27m"
local WIDTH = 76

-- Seeds a full WMAP/WMR%02d/WMO/WMEND burst via the real handlers (WMU/
-- WSPOIL optional). `rows`/`units` are the natural fixture shapes; `units`
-- entries omit a trailing comma+facing when `f` is absent (WMO's own
-- pattern makes the facing group optional either way).
local function seed_wmap(t)
  protocol.ingest("WMAP", table.concat({
    (t.active ~= false) and 1 or 0, t.dim or 0, t.turn or 0, t.mode or "offense",
    t.pending or 0, t.town or "", t.works_budget or 0, t.march_eta or 0,
  }, "|"))
  if t.upkeep then
    local u = t.upkeep
    protocol.ingest("WMU", table.concat({ u.food or 0, u.mead or 0, u.tools or 0, u.iron or 0, u.daler or 0 }, "|"))
  end
  if t.spoils then
    local s = t.spoils
    protocol.ingest("WSPOIL", table.concat({ s.daler or 0, s.renown or 0, s.deeds or 0 }, "|"))
  end
  for wire_row, row in ipairs(t.rows or {}) do
    protocol.ingest(string.format("WMR%02d", wire_row - 1), row)
  end
  if t.units and #t.units > 0 then
    local parts = {}
    for _, u in ipairs(t.units) do
      local entry = u.id .. ":" .. (u.c or 0) .. "," .. (u.r or 0) .. "," .. (u.size or 0)
      if u.f and u.f ~= "" then entry = entry .. "," .. u.f end
      parts[#parts + 1] = entry
    end
    protocol.ingest("WMO", table.concat(parts, ";"))
  end
  protocol.ingest("WMEND", tostring(#(t.rows or {})))
end

-- Seeds a BATTLE burst via the real handler. `units` entries: side "R" for
-- a reserve unit (label/size/uid/cost/leader), any other side for a
-- fielded one ("Y" -> S.battle.units[].side == "you", ported as-is by
-- handlers/kingdom.lua). `terrain_rows`/`works_rows` are 1-indexed arrays
-- in WIRE row order (row 1 first), concatenated row-major exactly as the
-- wire format requires.
local function seed_battle(t)
  local units_parts = {}
  for _, u in ipairs(t.units or {}) do
    if u.side == "R" then
      units_parts[#units_parts + 1] = table.concat(
        { "R", u.label or "", u.size or 0, u.uid or 0, u.cost or 0, u.leader or "" }, ",")
    else
      units_parts[#units_parts + 1] = table.concat({
        u.side or "Y", u.label or "", u.size or 0, u.coord or "", u.morale or 0,
        u.utype or "", u.leader or "", u.bid or 0, u.ord or 0,
      }, ",")
    end
  end
  local wh = string.format("%d:%d:%d", t.width or 8, t.height or 8, t.dz or 2)
  local budg = string.format("%d:%d", t.budget or 0, t.spent or 0)
  local terrain = table.concat(t.terrain_rows or {}, "")
  local works = table.concat(t.works_rows or {}, "")
  protocol.ingest("BATTLE", table.concat({
    (t.active ~= false) and 1 or 0,
    t.phase or "deploy", t.turn or 0, t.war_points or 0, t.mode or "field", t.target or "",
    budg, wh, terrain, works, table.concat(units_parts, ";"),
  }, "|"))
end

local function reset_all()
  S.war_map, S.wm_pending, S.battle, S.war_points = nil, nil, nil, 0
  send_calls, last_menu_open, menu_close_count = {}, nil, 0
end

-- Exact-field helper for grid assertions, same idiom as
-- guild_viking_popup_cityplan_test.lua's `field()`.
local function field(color, glyph)
  return color .. glyph .. " " .. RESET
end
local function field_sel(color, glyph)
  return color .. REV_ON .. glyph .. " " .. REV_OFF .. RESET
end

-- =============================================================================
-- war_campaign: no-data fallback
-- =============================================================================
reset_all()
local nodata = war_campaign.lines(WIDTH)
check("no war_map: header only", nodata[1] == pagelib.header(WIDTH, "Campaign Map"), nodata[1])
check("no war_map: exactly one line", #nodata == 1, #nodata)
check("no war_map: geometry nil", war_campaign.geometry(WIDTH) == nil)
check("no war_map: grid_line_offset is 1", war_campaign.grid_line_offset(WIDTH) == 1)

reset_all()
seed_wmap({ active = false, dim = 3, rows = { "...", "...", "..." } })
check("war_map inactive: geometry nil", war_campaign.geometry(WIDTH) == nil)

-- =============================================================================
-- war_campaign: grid terrain glyphs/colors (BGR workbook) + unit/dugout
-- overlays. dim=3: rows[0]="f.w" rows[1]="H.." rows[2]="..." (0,0)='f' and
-- (1,1)='.' are left as pure terrain (no overlay) for the terrain-only
-- check; every other cell carries an overlay marker.
-- =============================================================================
reset_all()
seed_wmap({
  dim = 3, turn = 7, town = "Jorvik",
  rows = { "f.w", "H..", "..." },
  units = {
    { id = "A", c = 0, r = 2, size = 10, f = "N" },
    { id = "F", c = 1, r = 2, size = 5 },
    { id = "*", c = 2, r = 0, size = 0 },
    { id = "3", c = 2, r = 1, size = 20 },
    { id = "P1", c = 0, r = 1, size = 0 },
    { id = "P9", c = 1, r = 0, size = 0 },
    { id = "u", c = 2, r = 2, size = 1 },
  },
})
check("war_map committed", S.war_map ~= nil and #S.war_map.rows == 3)

local offset = war_campaign.grid_line_offset(WIDTH)
local glines = war_campaign.lines(WIDTH)
local geom = war_campaign.geometry(WIDTH)
check("geometry non-nil once committed", geom ~= nil)

local function grid_line(gr) return glines[offset + gr + 1] end

-- row0 = "f.w": col0 'f' is pure terrain (unoverlaid, green); col1 '.' is
-- overridden by the P9 waystone landmark (white 'w'); col2 'w' is
-- overridden by the '*' objective (yellow), matching LEGACY's own
-- "objective glyph wins" overlay order (13840-13851 draws the marker on
-- top of whatever terrain/dugout occupies the cell).
check("row0: 'f'(0,0)=green woods (unoverlaid), 'w'(1,0)=white waystone (P9), '*'(2,0)=yellow objective",
  grid_line(0) == field(C.green, "f") .. " " .. field(C.white, "w") .. " " ..
    field(C.yellow, "*") .. " ", grid_line(0))
check("row1: 'w'(0,1)=dim landmark taken(P1), '.'(1,1)=dim plain (unoverlaid), '3'(2,1)=red enemy army",
  grid_line(1) == field(C.dim, "w") .. " " .. field(C.dim, ".") .. " " ..
    field(C.bright_red, "3") .. " ", grid_line(1))
check("row2: 'A'(0,2)=bright_green host, 'F'(1,2)=bright_cyan ally, 'u'(2,2)=white dugout",
  grid_line(2) == field(C.bright_green, "A") .. " " .. field(C.bright_cyan, "F") .. " " ..
    field(C.white, "u") .. " ", grid_line(2))

-- =============================================================================
-- war_campaign: hint text variants (pending battle / marching / holding)
-- =============================================================================
reset_all()
seed_wmap({ dim = 1, rows = { "." }, pending = 1 })
check("hint: battle awaits", find_plain(war_campaign.lines(WIDTH), "A battle awaits -- 'vcampaign fight'"))

reset_all()
seed_wmap({ dim = 1, rows = { "." }, march_eta = 125 })
check("hint: on the march (2m)", find_plain(war_campaign.lines(WIDTH), "On the march -- next tile in 2m"))

reset_all()
seed_wmap({ dim = 1, rows = { "." } })
check("hint: holding", find_plain(war_campaign.lines(WIDTH), "Holding -- 'vcampaign move <sq>'"))

-- =============================================================================
-- war_campaign: upkeep + spoils lines
-- =============================================================================
reset_all()
seed_wmap({
  dim = 1, rows = { "." },
  upkeep = { food = 10, mead = 5, tools = 2, iron = 1, daler = 50 },
  spoils = { daler = 200, renown = 15, deeds = 2 },
})
check("upkeep line", find_plain(war_campaign.lines(WIDTH),
  "Upkeep/tile: 10 food  5 mead  2 tools  1 iron  50d"))
check("spoils line", find_plain(war_campaign.lines(WIDTH),
  "Spoils if you win: 200 daler, 15 renown  (2 deeds)"))

-- =============================================================================
-- war_campaign: width discipline at 76 (a wider dim + long town name)
-- =============================================================================
reset_all()
local wide_rows = {}
for r = 0, 11 do
  local chars = {}
  for c = 0, 11 do chars[#chars + 1] = ({ "f", "H", "w", "." })[(c + r) % 4 + 1] end
  wide_rows[r + 1] = table.concat(chars)
end
seed_wmap({
  dim = 12, town = "A Very Long Settlement Name Indeed", rows = wide_rows,
  upkeep = { food = 999, mead = 999, tools = 999, iron = 999, daler = 99999 },
})
local wlines = war_campaign.lines(76)
local over_width = 0
for _, l in ipairs(wlines) do
  if pagelib.visible_width(l) > 76 then over_width = over_width + 1 end
end
check("war_campaign: no rendered line exceeds 76 visible columns", over_width == 0, over_width)

-- =============================================================================
-- war_campaign: select -> queue -> send flow (exact command strings),
-- deselect/clear semantics, out-of-grid/no-ctx safety, non-left no-op,
-- unconsumed "down" (bcamp_* wires no MouseDown).
-- =============================================================================
local function fixed_ctx(c, r)
  return { cell_from_xy = function() return c, r end, close = function() end }
end

reset_all()
seed_wmap({
  dim = 3, town = "Jorvik", rows = { "...", "...", "..." },
  units = { { id = "A", c = 0, r = 2, size = 10, f = "N" } },
})

local ok_down = war_campaign.on_pointer({ kind = "down", x = 0, y = 0, inside = true }, fixed_ctx(0, 2))
check("down on a bcamp cell is NOT consumed (LEGACY wires no MouseDown)", ok_down == nil, ok_down)
check("down never sends", #send_calls == 0)

local ok_move = war_campaign.on_pointer({ kind = "move", x = 0, y = 0, inside = true }, fixed_ctx(0, 2))
check("move does not consume", ok_move == nil)
check("move over own stack shows hover with 'host (you)'",
  find_plain(war_campaign.lines(WIDTH), "host (you)"))

-- Click own stack at (0,2) -> selects "A" (sq A3), no send yet.
local ok_select = war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" },
  fixed_ctx(0, 2))
check("left-up on own stack consumes", ok_select == true)
check("selecting a stack never sends", #send_calls == 0)
check("selected-but-no-queue status line", find_plain(war_campaign.lines(WIDTH),
  "Selected A -- click a cell to queue a move, its own tile to hold & clear"))

-- Queue waypoint 1: (2,1) -> sq "C2".
send_calls = {}
war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(2, 1))
check("queuing waypoint 1 sends the exact command", #send_calls == 1 and send_calls[1] == "vcampaign queue A C2",
  send_calls[1])

-- Queue waypoint 2: (1,0) -> sq "B1".
war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(1, 0))
check("queuing waypoint 2 sends the exact command", #send_calls == 2 and send_calls[2] == "vcampaign queue A B1",
  send_calls[2])
check("queue status line lists both waypoints in order",
  find_plain(war_campaign.lines(WIDTH), "Queued for A: C2 -> B1"))

-- Click the selected stack's OWN (still unmoved) tile (0,2) -> deselect,
-- clear the queue, send "vcampaign hold".
send_calls = {}
war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(0, 2))
check("clicking own tile sends 'vcampaign hold'", #send_calls == 1 and send_calls[1] == "vcampaign hold",
  send_calls[1])
check("deselect clears the queue status line",
  not find_plain(war_campaign.lines(WIDTH), "Selected A") and not find_plain(war_campaign.lines(WIDTH), "Queued for A"))

-- Right-click (non-left) consumes but never acts.
send_calls = {}
local ok_right = war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "right" },
  fixed_ctx(0, 2))
check("right-up consumes the cell", ok_right == true)
check("right-up never sends nor selects", #send_calls == 0
  and not find_plain(war_campaign.lines(WIDTH), "Selected"))

-- Clicking an empty/enemy-free tile with nothing selected is a no-op.
send_calls = {}
war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(1, 1))
check("clicking empty ground with no selection never sends", #send_calls == 0)
check("clicking empty ground with no selection selects nothing",
  not find_plain(war_campaign.lines(WIDTH), "Selected"))

-- Stale-selection revalidation: re-seed a war_map where "A" no longer
-- exists; selecting it first via a fresh seed, then re-seeding without it,
-- then clicking must clear the stale selection instead of crashing.
reset_all()
seed_wmap({ dim = 2, rows = { "..", ".." }, units = { { id = "A", c = 0, r = 0, size = 10 } } })
war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(0, 0))
check("selected A ahead of the revalidation check", find_plain(war_campaign.lines(WIDTH), "Selected A"))
reset_all()
seed_wmap({ dim = 2, rows = { "..", ".." }, units = { { id = "F", c = 1, r = 1, size = 5 } } })
send_calls = {}
war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(0, 0))
check("stale 'A' selection is revalidated away (no crash, no stray send)", #send_calls == 0)
check("stale selection no longer shown", not find_plain(war_campaign.lines(WIDTH), "Selected A"))

-- out-of-grid / missing ctx safety
check("on_pointer with no ctx.cell_from_xy is a safe no-op",
  war_campaign.on_pointer({ kind = "down" }, {}) == nil)
local ok_oob = war_campaign.on_pointer({ kind = "up", button = "left" },
  { cell_from_xy = function() return nil end })
check("an out-of-grid ctx coordinate does not consume", ok_oob == nil)

-- =============================================================================
-- war_battle: no-battle fallback
-- =============================================================================
reset_all()
local nb = war_battle.lines(WIDTH)
check("no battle: header + 'No battle underway.'",
  nb[1] == pagelib.header(WIDTH, "Battle Board") and find_plain(nb, "No battle underway."))
check("no battle: geometry nil", war_battle.geometry(WIDTH) == nil)

-- =============================================================================
-- war_battle: deploy-phase grid content (BGR workbook), works overlay,
-- deploy-zone tint, unit-ordinal digit override.
--   width=3 height=2 dz=1 -- row_game 1 (bottom, in the deploy zone) holds
--   the works overlay; row_game 2 (top) is pure terrain plus a "you" unit
--   at A2 and a duplicated-ordinal enemy unit at C2.
-- =============================================================================
reset_all()
seed_battle({
  phase = "deploy", target = "Fjordvik", mode = "field", width = 3, height = 2, dz = 1,
  budget = 100, spent = 20, war_points = 15,
  terrain_rows = { "..#", "^*w" }, -- row1 (bottom) then row2 (top)
  works_rows = { "v.u", "..." },
  units = {
    { side = "Y", label = "Huscarl Guard", size = 8, coord = "A2", morale = 80,
      utype = "huscarls", bid = 101 },
    { side = "N", label = "Raider Warband", size = 6, coord = "C2", morale = 60,
      utype = "foe_raiders", ord = 2 },
    { side = "R", label = "Reserve Skirm", size = 5, uid = 55, cost = 10, leader = "Bjorn" },
  },
})
check("battle deploy committed", S.battle ~= nil and S.battle.phase == "deploy")

local boffset = war_battle.grid_line_offset(WIDTH)
local blines = war_battle.lines(WIDTH)
local bgeom = war_battle.geometry(WIDTH)
check("battle geometry non-nil", bgeom ~= nil)

local function bgrid_line(gr) return blines[boffset + gr + 1] end

-- gr=0 (top, row_game=2): A2 = you-unit override (huscarls "H", bright_green);
-- B2 = forest '*' green; C2 = enemy ordinal-2 override ("2", bright_red).
check("top row: A2 unit override, B2 forest, C2 ordinal-2 enemy override",
  bgrid_line(0) == field(C.bright_green, "H") .. " " .. field(C.green, "*") .. " " ..
    field(C.bright_red, "2") .. " ", bgrid_line(0))

-- gr=1 (bottom, row_game=1, in deploy zone): A1 = stakes 'v' yellow;
-- B1 = empty in-dz cell '+' bright_cyan; C1 = dugout 'u' white.
check("bottom row: A1 stakes, B1 deploy-zone '+', C1 dugout",
  bgrid_line(1) == field(C.yellow, "v") .. " " .. field(C.bright_cyan, "+") .. " " ..
    field(C.white, "u") .. " ", bgrid_line(1))

check("legend: side colours + deploy hint present",
  find_plain(blines, "green = you") and find_plain(blines, "red = foe") and find_plain(blines, "+ deploy"))
check("legend: unit-type key letters present", find_plain(blines, "huscarl") and find_plain(blines, "raiders"))
check("legend: terrain key present", find_plain(blines, "fjord") and find_plain(blines, "rampart"))
check("command/fraegd line", find_plain(blines, "Command 20/100") and find_plain(blines, "Fraegd 15"))
check("actions line (deploy phase)", find_plain(blines, "[Actions] Begin Battle | Abandon"))

-- =============================================================================
-- war_battle: deploy-phase right-click menus (own unit / empty in-dz with
-- reserve / not-your-deploy-zone), left-click closes without sending.
-- =============================================================================
local function bfixed_ctx(gc, gr)
  return { cell_from_xy = function() return gc, gr end, line_from_y = function(y) return y end }
end

-- Right-click own unit at A2 (gc=0, gr=0) -> "Undeploy Huscarl Guard".
send_calls = {}
last_menu_open = nil
local ok_undeploy = war_battle.on_pointer({ kind = "up", button = "right" }, bfixed_ctx(0, 0))
check("right-up on own unit consumes", ok_undeploy == true)
check("undeploy menu offers exactly 2 items (Undeploy + Cancel)",
  last_menu_open ~= nil and #last_menu_open.items == 2, last_menu_open and #last_menu_open.items)
check("undeploy item label", menu_has_label(last_menu_open, "Undeploy Huscarl Guard"))
menu_select(last_menu_open, "Undeploy Huscarl Guard")
check("selecting Undeploy sends the exact command",
  #send_calls == 1 and send_calls[1] == "vbattle undeploy 101", send_calls[1])

-- Right-click empty in-dz cell B1 (gc=1, gr=1) -> reserve deploy + fortify + cancel.
send_calls = {}
last_menu_open = nil
war_battle.on_pointer({ kind = "up", button = "right" }, bfixed_ctx(1, 1))
check("in-dz empty-cell menu offers 4 items (1 reserve + 2 fortify + cancel)",
  last_menu_open ~= nil and #last_menu_open.items == 4, last_menu_open and #last_menu_open.items)
check("reserve deploy item text", menu_has_label(last_menu_open, "Deploy 5x Reserve Skirm (10 pts)"))
menu_select(last_menu_open, "Deploy 5x Reserve Skirm")
check("selecting the reserve item sends the exact deploy command",
  #send_calls == 1 and send_calls[1] == "vbattle deploy 55 B1", send_calls[1])

send_calls = {}
last_menu_open = nil
war_battle.on_pointer({ kind = "up", button = "right" }, bfixed_ctx(1, 1))
menu_select(last_menu_open, "Fortify: Stakes")
check("Fortify: Stakes sends the exact command",
  #send_calls == 1 and send_calls[1] == "vbattle fortify stakes B1", send_calls[1])
send_calls = {}
war_battle.on_pointer({ kind = "up", button = "right" }, bfixed_ctx(1, 1))
menu_select(last_menu_open, "Fortify: Dugout")
check("Fortify: Dugout sends the exact command",
  #send_calls == 1 and send_calls[1] == "vbattle fortify dugout B1", send_calls[1])

-- Right-click the enemy-occupied, non-dz cell C2 (gc=2, gr=0) -> "Not your
-- deploy zone" + Cancel (LEGACY ignores the occupant here -- ported as-is).
last_menu_open = nil
war_battle.on_pointer({ kind = "up", button = "right" }, bfixed_ctx(2, 0))
check("non-dz cell menu offers 'Not your deploy zone' + Cancel",
  last_menu_open ~= nil and #last_menu_open.items == 2
  and menu_has_label(last_menu_open, "Not your deploy zone") and menu_has_label(last_menu_open, "Cancel"),
  last_menu_open and table.concat(menu_item_labels(last_menu_open), " | "))
send_calls = {}
menu_select(last_menu_open, "Not your deploy zone")
check("the decorative item never sends", #send_calls == 0)

-- Left-click anywhere on the deploy board just closes any open menu.
last_menu_open = { items = { { label = "x", value = false } }, on_select = function() end }
menu_close_count = 0
send_calls = {}
local ok_left_close = war_battle.on_pointer({ kind = "up", button = "left" }, bfixed_ctx(1, 1))
check("left-up in deploy phase consumes", ok_left_close == true)
check("left-up closes any open menu", menu_close_count == 1)
check("left-up never sends", #send_calls == 0)

-- =============================================================================
-- war_battle: turn-phase select -> move-order flow (exact command strings),
-- same-tile deselect, right-click cancels selection.
-- width=2 height=2: "you" unit at A1 (gc=0,gr=1), enemy at B2 (gc=1,gr=0).
-- =============================================================================
reset_all()
seed_battle({
  phase = "turn", turn = 4, target = "Fjordvik", width = 2, height = 2, dz = 1,
  budget = 100, spent = 40, war_points = 22,
  terrain_rows = { "..", ".." },
  units = {
    { side = "Y", label = "Shieldwall", size = 10, coord = "A1", morale = 70,
      utype = "shieldwall", bid = 201 },
    { side = "N", label = "Levy Rabble", size = 12, coord = "B2", morale = 40,
      utype = "foe_levy" },
  },
})
check("battle turn-phase committed", S.battle ~= nil and S.battle.phase == "turn")

send_calls = {}
local ok_pick = war_battle.on_pointer({ kind = "up", button = "left" }, bfixed_ctx(0, 1))
check("left-up on own unit (turn phase) consumes", ok_pick == true)
check("selecting a unit never sends", #send_calls == 0)

war_battle.on_pointer({ kind = "up", button = "left" }, bfixed_ctx(1, 0))
check("left-up on a different cell sends the exact order command",
  #send_calls == 1 and send_calls[1] == "vbattle order 201 B2", send_calls[1])

-- Re-select, then click the SAME cell -> deselect, no send.
war_battle.on_pointer({ kind = "up", button = "left" }, bfixed_ctx(0, 1))
send_calls = {}
war_battle.on_pointer({ kind = "up", button = "left" }, bfixed_ctx(0, 1))
check("clicking the same cell twice deselects without sending", #send_calls == 0)

-- Re-select, then right-click -> cancels selection and closes any menu.
war_battle.on_pointer({ kind = "up", button = "left" }, bfixed_ctx(0, 1))
menu_close_count = 0
send_calls = {}
war_battle.on_pointer({ kind = "up", button = "right" }, bfixed_ctx(0, 1))
check("right-up cancels the selection", menu_close_count == 1)
check("right-up never sends", #send_calls == 0)
-- Confirm the cancel actually cleared selection: clicking a bare cell next
-- with nothing selected and no own unit there must not send an order.
war_battle.on_pointer({ kind = "up", button = "left" }, bfixed_ctx(1, 0))
check("post-cancel click on the enemy cell does not order a move (nothing was selected)",
  #send_calls == 0)

-- Hover text on move.
war_battle.on_pointer({ kind = "move", x = 0, y = 0 }, bfixed_ctx(0, 1))
check("hover over own unit shows name/side/size/morale",
  find_plain(war_battle.lines(WIDTH), "Shieldwall (yours)") and find_plain(war_battle.lines(WIDTH), "10 men")
  and find_plain(war_battle.lines(WIDTH), "morale 70"))

-- =============================================================================
-- war_battle: actions line (turn phase: Advance Turn + Abandon)
-- =============================================================================
local idx = war_battle.actions_line_index(WIDTH)
check("actions_line_index is non-nil while a battle is active", idx ~= nil)
last_menu_open = nil
war_battle.on_pointer({ kind = "down", y = 0 }, { line_from_y = function(y) return y end })
-- y=0 maps (via the identity line_from_y stub) to line index 0, which is
-- never the actions line -- confirms a down elsewhere does NOT open it.
check("a down elsewhere on the board does not open the actions menu", last_menu_open == nil)

war_battle.on_pointer({ kind = "down" }, { line_from_y = function() return idx end })
check("a down on the actions line opens the actions menu", last_menu_open ~= nil)
check("turn-phase actions menu offers Advance Turn + Abandon",
  menu_has_label(last_menu_open, "Advance Turn") and menu_has_label(last_menu_open, "Abandon"))
send_calls = {}
menu_select(last_menu_open, "Advance Turn")
check("selecting Advance Turn sends 'vbattle go'", #send_calls == 1 and send_calls[1] == "vbattle go", send_calls[1])

war_battle.on_pointer({ kind = "down" }, { line_from_y = function() return idx end })
send_calls = {}
menu_select(last_menu_open, "Abandon")
check("selecting Abandon sends 'vbattle abandon'",
  #send_calls == 1 and send_calls[1] == "vbattle abandon", send_calls[1])

-- =============================================================================
-- war_battle: width discipline at 76 (a bigger board + long labels)
-- =============================================================================
reset_all()
local function repeat_row(ch, n) return string.rep(ch, n) end
seed_battle({
  phase = "turn", target = "A Very Long Enemy Settlement Name", width = 10, height = 4, dz = 2,
  budget = 999, spent = 999, war_points = 9999,
  terrain_rows = { repeat_row(".", 10), repeat_row("^", 10), repeat_row("*", 10), repeat_row("=", 10) },
  works_rows = { repeat_row(".", 10), repeat_row(".", 10), repeat_row(".", 10), repeat_row(".", 10) },
  units = {
    { side = "Y", label = "A Very Long Unit Label Indeed", size = 99, coord = "A1", morale = 100,
      utype = "moose", bid = 1 },
  },
})
local blines_wide = war_battle.lines(76)
local bover = 0
for _, l in ipairs(blines_wide) do
  if pagelib.visible_width(l) > 76 then bover = bover + 1 end
end
check("war_battle: no rendered line exceeds 76 visible columns", bover == 0, bover)

-- =============================================================================
-- war (composite): mode follows state -- battle takes priority, campaign
-- otherwise, "nothing to show" when neither is active.
-- =============================================================================
reset_all()
seed_wmap({
  dim = 2, town = "Havn", rows = { "..", ".." },
  units = { { id = "A", c = 0, r = 0, size = 10 } },
})
seed_battle({
  phase = "deploy", target = "Havn", width = 2, height = 2, dz = 1,
  terrain_rows = { "..", ".." }, works_rows = { "..", ".." },
})
check("both war_map.active and battle present: composite delegates to war_battle",
  table.concat(war.lines(WIDTH), "\n") == table.concat(war_battle.lines(WIDTH), "\n"))
check("composite geometry delegates to war_battle",
  war.geometry(WIDTH) ~= nil and war.grid_line_offset(WIDTH) == war_battle.grid_line_offset(WIDTH))

-- End the battle: composite falls back to the campaign map.
S.battle = nil
check("battle cleared, war_map still active: composite delegates to war_campaign",
  table.concat(war.lines(WIDTH), "\n") == table.concat(war_campaign.lines(WIDTH), "\n"))
check("composite grid_line_offset delegates to war_campaign",
  war.grid_line_offset(WIDTH) == war_campaign.grid_line_offset(WIDTH))

-- Neither active: a plain fallback line.
S.war_map = nil
local neither = war.lines(WIDTH)
check("neither active: single fallback line", #neither == 1
  and find_plain(neither, "No campaign or battle underway."), neither[1])
check("neither active: on_pointer/geometry are safe no-ops",
  war.on_pointer({ kind = "down" }, {}) == nil and war.geometry(WIDTH) == nil
  and war.grid_line_offset(WIDTH) == 0)

-- on_pointer delegation, end to end: re-seed campaign-only, select via the
-- COMPOSITE's on_pointer, confirm the underlying war_campaign module state
-- actually changed (shared module singleton).
reset_all()
seed_wmap({
  dim = 2, rows = { "..", ".." },
  units = { { id = "A", c = 0, r = 0, size = 10 } },
})
send_calls = {}
war.on_pointer({ kind = "up", button = "left" }, fixed_ctx(0, 0))
check("composite on_pointer delegates the select to war_campaign",
  find_plain(war_campaign.lines(WIDTH), "Selected A"))
war.on_pointer({ kind = "up", button = "left" }, fixed_ctx(1, 1))
check("composite on_pointer delegates the queue-and-send to war_campaign",
  #send_calls == 1 and send_calls[1] == "vcampaign queue A B2", send_calls[1])

-- Clean up war_campaign's module-local selection (it's a shared singleton
-- across this whole test file) before the next section re-seeds a fresh
-- war_map with a unit at the same coordinates -- otherwise that section's
-- first click would DESELECT (this leftover selection's stack is still at
-- (0,0)) instead of selecting fresh, exactly the semantics being tested.
war.on_pointer({ kind = "up", button = "left" }, fixed_ctx(0, 0))
check("cleanup click deselects", not find_plain(war_campaign.lines(WIDTH), "Selected A"))

-- =============================================================================
-- popups.lua registration: /vik war opens the composite, titled "War", and
-- the wrapper's ctx.cell_from_xy plumbing works end to end.
-- =============================================================================
reset_all()
seed_wmap({
  dim = 2, rows = { "..", ".." },
  units = { { id = "A", c = 0, r = 0, size = 10 } },
})

is_open_flag = false
opens = {}
close_count = 0
check("popups.toggle('war') opens (war self-registers in popups.lua)", popups.toggle("war") == true)
local renderer = opens[#opens].renderer
check("wrapper is titled 'War' from the composite module", opens[#opens].opts.title == "War")
check("wrapper exposes on_pointer for the war composite", type(renderer.on_pointer) == "function")

local rect_h = 10
reset_drawn()
renderer.render(make_rect(0, 0, WIDTH, rect_h), { title = "War" })

local pre_offset = war_campaign.grid_line_offset(WIDTH)
local wrapper_y_row0 = pre_offset
check("row 0 is within the visible rect at zero scroll", wrapper_y_row0 < rect_h, wrapper_y_row0)
send_calls = {}
renderer.on_pointer({ kind = "up", x = 0, y = wrapper_y_row0, inside = true, button = "left" })
check("wrapper's ctx.cell_from_xy maps wrapper-local (x,y) to grid cell (0,0), selecting the host",
  find_plain(war_campaign.lines(WIDTH), "Selected A"))

send_calls = {}
local ok_wired_oob = renderer.on_pointer({ kind = "up", x = 0, y = 1000, inside = false, button = "left" })
check("an out-of-grid wrapper coordinate does not send to the MUD", #send_calls == 0)

if is_open_flag then package.loaded["wm"].popup.close() end

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING POPUP WAR TESTS PASSED")
