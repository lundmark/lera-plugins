-- guild_viking /vik map (Territory Map popup) unit tests. Run from the
-- lera-plugins repo root with LERA_ROOT pointing at a built Lera checkout.
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

-- ---- lera API stubs ---------------------------------------------------------
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

-- ---- wm.popup facade stub (identical to guild_viking_popups_test.lua's) ----
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

local pagelib = require("pagelib")
local maplib = require("maplib")
local state = require("state")
local page_opts = require("page_opts")
local popups = require("popups")
local map = require("popups.map")

local S = state.S
local C, RESET = pagelib.C, pagelib.RESET

-- BGR-decode workbook cross-check: same nearest-hue mapping map.lua's own
-- header comment documents (0xBBGGRR: leftmost=Blue, middle=Green,
-- rightmost=Red), re-derived here independently so a test typo in map.lua's
-- table can't also typo the same way in the test.
local EXPECT_COLOR = {
  p = C.bright_green, -- 0x00CC00 -> R=00,G=CC,B=00
  h = C.yellow,        -- 0x00CCCC -> R=CC,G=CC,B=00
  ["."] = C.dim,        -- 0x222222 -> R=22,G=22,B=22
  A = C.red,            -- 0x0000CC -> R=CC,G=00,B=00
  f = C.green,          -- 0x009900 -> R=00,G=99,B=00
  W = C.cyan,           -- 0xAA3300 -> R=00,G=33,B=AA (no blue in pagelib.C)
  M = C.bright_red,     -- 0x0000DD -> R=DD,G=00,B=00
  X = C.white,          -- 0xFFFFFF
}

local function reset_vmap()
  S.vmap_w, S.vmap_h = 0, 0
  S.vmap_px, S.vmap_py = -1, -1
  S.vmap_rows = {}
  S.vmap_east_edges = {}
  S.vmap_south_edges = {}
  S.vmap_pois = {}
end

-- =============================================================================
-- no-data fallback
-- =============================================================================
reset_vmap()
page_opts.set("show_map_towns", true)
local nodata_lines = map.lines(76)
local nodata_found = false
for _, l in ipairs(nodata_lines) do
  if l:find("No data %- enable with: vtoggle mip_map", 1, false) or
     l:find("No data - enable with: vtoggle mip_map", 1, true) then
    nodata_found = true
  end
end
check("no-data fallback prints the vtoggle mip_map hint", nodata_found)
check("no-data fallback has a Territory Map header",
  nodata_lines[1]:find("Territory Map", 1, true) ~= nil, nodata_lines[1])

-- =============================================================================
-- grid: seeded rows render exact glyph/color fields (BGR workbook)
-- =============================================================================
reset_vmap()
S.vmap_w, S.vmap_h = 3, 2
S.vmap_rows = { [0] = "ph.", [1] = "AfW" }

local width = 76
local offset = map.grid_line_offset(width)
local lines = map.lines(width)

local row0 = EXPECT_COLOR.p .. "p " .. RESET .. " " ..
             EXPECT_COLOR.h .. "h " .. RESET .. " " ..
             EXPECT_COLOR["."] .. ". " .. RESET .. " "
local row1 = EXPECT_COLOR.A .. "A " .. RESET .. " " ..
             EXPECT_COLOR.f .. "f " .. RESET .. " " ..
             EXPECT_COLOR.W .. "W " .. RESET .. " "

check("grid row0 (p/h/.) renders exact glyph+color fields",
  lines[offset + 1] == row0, lines[offset + 1])
check("grid row1 (A/f/W) renders exact glyph+color fields",
  lines[offset + 2] == row1, lines[offset + 2])

-- =============================================================================
-- POI overlay overrides terrain glyph/color
-- =============================================================================
reset_vmap()
S.vmap_w, S.vmap_h = 3, 2
S.vmap_rows = { [0] = "ph.", [1] = "AfW" }
S.vmap_pois = { { type = "capital", name = "uppsala", x = 1, y = 0, owner = "" } }

offset = map.grid_line_offset(width)
lines = map.lines(width)
local row0_poi = EXPECT_COLOR.p .. "p " .. RESET .. " " ..
                  EXPECT_COLOR.M .. "M " .. RESET .. " " ..
                  EXPECT_COLOR["."] .. ". " .. RESET .. " "
check("POI at (1,0) overrides the terrain glyph/color with its symbol",
  lines[offset + 1] == row0_poi, lines[offset + 1])

-- =============================================================================
-- player position marker overrides both terrain and a co-located POI
-- =============================================================================
reset_vmap()
S.vmap_w, S.vmap_h = 3, 2
S.vmap_rows = { [0] = "ph.", [1] = "AfW" }
S.vmap_px, S.vmap_py = 2, 1
S.vmap_pois = { { type = "ruins", name = "old fort", x = 2, y = 1, owner = "" } }

offset = map.grid_line_offset(width)
lines = map.lines(width)
local row1_player = EXPECT_COLOR.A .. "A " .. RESET .. " " ..
                     EXPECT_COLOR.f .. "f " .. RESET .. " " ..
                     EXPECT_COLOR.X .. "X " .. RESET .. " "
check("player position (2,1) wins over a co-located POI and terrain",
  lines[offset + 2] == row1_player, lines[offset + 2])

local pos_line_found = false
for _, l in ipairs(lines) do
  if l:find("%(2, 1%)") then pos_line_found = true end
end
check("header shows the player's position", pos_line_found)

-- =============================================================================
-- east/south edge overlays
-- =============================================================================
reset_vmap()
S.vmap_w, S.vmap_h = 2, 2
S.vmap_rows = { [0] = "pp", [1] = "pp" }
S.vmap_east_edges = { [0] = "01" } -- col0 wall, col1 clear, row1 unspecified
S.vmap_south_edges = { [0] = "10" } -- col0 clear, col1 wall, row1 unspecified

offset = map.grid_line_offset(width)
lines = map.lines(width)
local field = EXPECT_COLOR.p .. "p " .. RESET
check("east edge: wall right of (0,0)",
  lines[offset + 1] == field .. "|" .. field .. " ", lines[offset + 1])
check("south edge row (interleaved): wall under (1,0), none under (0,0)",
  lines[offset + 2] == "  " .. " " .. "__" .. " ", lines[offset + 2])

-- no south-edge data at all -> no interleaved edge rows (grid stays h lines,
-- not 2h): total = pre-grid lines + h grid rows + 1 hover line (no towns
-- seeded).
reset_vmap()
S.vmap_w, S.vmap_h = 2, 2
S.vmap_rows = { [0] = "pp", [1] = "pp" }
offset = map.grid_line_offset(width)
lines = map.lines(width)
check("with no south-edge data at all, the grid section is exactly h lines "
  .. "(no interleaved edge rows)",
  #lines == offset + S.vmap_h + 1, #lines)
local plain_row = EXPECT_COLOR.p .. "p " .. RESET .. " " .. EXPECT_COLOR.p .. "p " .. RESET .. " "
check("grid row0 with no edge data has no wall marks",
  lines[offset + 1] == plain_row, lines[offset + 1])
check("grid row1 with no edge data has no wall marks",
  lines[offset + 2] == plain_row, lines[offset + 2])

-- =============================================================================
-- towns list + show_map_towns gate
-- =============================================================================
reset_vmap()
S.vmap_w, S.vmap_h = 3, 2
S.vmap_rows = { [0] = "...", [1] = "..." }
S.vmap_pois = {
  { type = "capital", name = "asgard", x = 0, y = 0, owner = "" },
  { type = "farm", name = "hearthstead", x = 1, y = 0, owner = "bjorn" },
}

page_opts.set("show_map_towns", true)
lines = map.lines(width)
local towns_header_found, asgard_found, hearthstead_found = false, false, false
for _, l in ipairs(lines) do
  if l:find("Map Locations", 1, true) then towns_header_found = true end
  if l:find("Asgard", 1, true) then asgard_found = true end
  if l:find("Hearthstead", 1, true) and l:find("Bjorn", 1, true) then
    hearthstead_found = true
  end
end
check("towns list header present when gated on", towns_header_found)
check("towns list shows a capitalized POI name", asgard_found)
check("towns list shows owner in parens for an owned POI", hearthstead_found)

page_opts.set("show_map_towns", false)
lines = map.lines(width)
towns_header_found = false
for _, l in ipairs(lines) do
  if l:find("Map Locations", 1, true) then towns_header_found = true end
end
check("towns list hidden when show_map_towns is off", not towns_header_found)
page_opts.set("show_map_towns", true)

-- =============================================================================
-- width discipline at popup-inner 76 cols
-- =============================================================================
reset_vmap()
S.vmap_w, S.vmap_h = 8, 4
local wide_rows = {}
for r = 0, 3 do
  local chars = {}
  for c = 0, 7 do chars[#chars + 1] = ({ "p", "h", "A", "f", "W", ".", "+", "=" })[(c + r) % 8 + 1] end
  wide_rows[r] = table.concat(chars)
end
S.vmap_rows = wide_rows
S.vmap_pois = {
  { type = "capital", name = "asgard", x = 0, y = 0, owner = "" },
  { type = "lineage", name = "midgard hall", x = 1, y = 1, owner = "" },
}
lines = map.lines(76)
local over_width = 0
for _, l in ipairs(lines) do
  if pagelib.visible_width(l) > 76 then over_width = over_width + 1 end
end
check("no rendered line exceeds 76 visible columns", over_width == 0, over_width)

-- =============================================================================
-- pointer: hover info line (direct unit test with a stubbed ctx)
-- =============================================================================
reset_vmap()
S.vmap_w, S.vmap_h = 3, 2
S.vmap_rows = { [0] = "ph.", [1] = "AfW" }
S.vmap_px, S.vmap_py = -1, -1
S.vmap_pois = { { type = "seer", name = "vala", x = 1, y = 0, owner = "ivar" } }

local function fixed_ctx(c, r)
  return { cell_from_xy = function() return c, r end,
           close = function() end }
end

send_calls = {}
local ok_move = map.on_pointer({ kind = "move", x = 0, y = 0, inside = true }, fixed_ctx(0, 1))
check("on_pointer(move) over terrain does not consume the event", ok_move == nil or ok_move == false)
lines = map.lines(width)
local hover_terrain_found = false
for _, l in ipairs(lines) do
  if l:find("%(0,1%)") and l:find("Mountains", 1, true) then hover_terrain_found = true end
end
check("hover over terrain cell (0,1) shows its terrain label", hover_terrain_found)
check("hovering never sends anything to the MUD", #send_calls == 0)

map.on_pointer({ kind = "move", x = 0, y = 0, inside = true }, fixed_ctx(1, 0))
lines = map.lines(width)
local hover_poi_found = false
for _, l in ipairs(lines) do
  if l:find("%(1,0%)") and l:find("Seer", 1, true) and l:find("Vala", 1, true)
     and l:find("Owner", 1, true) and l:find("Ivar", 1, true) then
    hover_poi_found = true
  end
end
check("hover over a POI cell shows its type/name/owner", hover_poi_found)

S.vmap_px, S.vmap_py = 2, 1
map.on_pointer({ kind = "move", x = 0, y = 0, inside = true }, fixed_ctx(2, 1))
lines = map.lines(width)
local hover_player_found = false
for _, l in ipairs(lines) do
  if l:find("%(2,1%)") and l:find("You", 1, true) then hover_player_found = true end
end
check("hover over the player's own cell shows 'You'", hover_player_found)

-- out-of-grid click no-ops: hover text must be unchanged
local before_lines = map.lines(width)
local before_hover
for _, l in ipairs(before_lines) do
  if l:find("You", 1, true) then before_hover = l end
end
local ok_oob = map.on_pointer({ kind = "down", x = -5, y = -5, inside = false },
  { cell_from_xy = function() return nil end, close = function() end })
check("out-of-grid click returns a non-true, non-blocking result", ok_oob ~= true)
lines = map.lines(width)
local after_hover
for _, l in ipairs(lines) do
  if l:find("You", 1, true) then after_hover = l end
end
check("out-of-grid click leaves the hover line unchanged", after_hover == before_hover)
check("out-of-grid click never sends anything to the MUD", #send_calls == 0)

-- =============================================================================
-- ctx.cell_from_xy wiring through the real popups.lua wrapper (stubbed
-- wm.popup) -- the contract Tasks 4-6 reuse.
-- =============================================================================
reset_vmap()
S.vmap_w, S.vmap_h = 2, 3
S.vmap_rows = { [0] = "pp", [1] = "hh", [2] = "AA" }

is_open_flag = false
opens = {}
close_count = 0
check("popups.toggle('map') opens (map self-registers in popups.lua)",
  popups.toggle("map") == true)
local renderer = opens[#opens].renderer
check("wrapper exposes on_pointer for the map module",
  type(renderer.on_pointer) == "function")

-- Prime last_width/last_count via a real render pass. Rect height (6) is
-- deliberately SHORTER than the full content (pre-grid + 3 grid rows + 1
-- hover line = 7 lines here) so scroll(1) below actually moves the
-- scroller's offset instead of clamping back to 0 (max offset = 7-6 = 1) --
-- and tall enough that grid row 2 is still on-screen both before and after
-- that one-line scroll.
local rect_h = 6
reset_drawn()
renderer.render(make_rect(0, 0, width, rect_h), { title = "Territory Map" })

local pre_offset = map.grid_line_offset(width)
-- wrapper_y for grid row r (0-based, no south edges => 1 line per row) at
-- zero scroll: wrapper_y = pre_offset + r (see popups.lua's ctx.cell_from_xy
-- doc comment: gy = y + scroll_offset - grid_line_offset).
local wrapper_y_row2 = pre_offset + 2
check("row 2 is within the visible rect at zero scroll", wrapper_y_row2 < rect_h,
  wrapper_y_row2)
renderer.on_pointer({ kind = "move", x = 0, y = wrapper_y_row2, inside = true })
lines = map.lines(width)
local wired_hover_found = false
for _, l in ipairs(lines) do
  if l:find("%(0,2%)") and l:find("Mountains", 1, true) then wired_hover_found = true end
end
check("wrapper's ctx.cell_from_xy maps wrapper-local (x, y) to grid cell (0,2) at zero scroll",
  wired_hover_found)

-- Now scroll the wrapper down by 1 (well within its clamp: 7 total lines,
-- 5-row rect -> max offset 2) and re-check the SAME target cell (0,2) at
-- its NEW wrapper-local y (one row higher on screen), confirming the
-- offset math tracks scroll.
renderer.scroll(1)
reset_drawn()
renderer.render(make_rect(0, 0, width, rect_h), { title = "Territory Map" })
local wrapper_y_row2_scrolled = wrapper_y_row2 - 1
renderer.on_pointer({ kind = "move", x = 0, y = wrapper_y_row2_scrolled, inside = true })
lines = map.lines(width)
wired_hover_found = false
for _, l in ipairs(lines) do
  if l:find("%(0,2%)") and l:find("Mountains", 1, true) then wired_hover_found = true end
end
check("wrapper's ctx.cell_from_xy still maps to (0,2) after scrolling by 1",
  wired_hover_found)

-- an out-of-grid wrapper coordinate (well past the grid's bottom) resolves
-- to nil and does not touch mud.send
send_calls = {}
local ok_wired_oob = renderer.on_pointer({ kind = "down", x = 0, y = 1000, inside = false })
check("an out-of-grid wrapper coordinate does not send to the MUD", #send_calls == 0)

if is_open_flag then package.loaded["wm"].popup.close() end

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING POPUP MAP TESTS PASSED")
