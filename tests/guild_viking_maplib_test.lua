-- maplib unit tests. Pure module: no lera stubs needed. Run from the
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

local pagelib = require("pagelib")
local maplib = require("maplib")
local C, RESET = pagelib.C, pagelib.RESET
local REV_ON, REV_OFF = "\27[7m", "\27[27m"

-- ---- a 3x3 grid: mixed colors, one selected cell, one empty cell, one
-- 2-char glyph -------------------------------------------------------------
local grid3 = {
  w = 3, h = 3,
  cell = function(c, r)
    if r == 0 and c == 0 then return { glyph = "A", color = C.green } end
    if r == 0 and c == 1 then return { glyph = "B" } end
    if r == 0 and c == 2 then return nil end
    if r == 1 and c == 0 then return { glyph = "C", color = C.red, sel = true } end
    if r == 1 and c == 1 then return { glyph = "DD" } end
    if r == 1 and c == 2 then return { glyph = "E", color = C.yellow } end
    if r == 2 and c == 0 then return { glyph = "F" } end
    if r == 2 and c == 1 then return { glyph = "G" } end
    if r == 2 and c == 2 then return { glyph = "H", color = C.cyan } end
  end,
}

local lines3 = maplib.render(grid3, {})
check("3x3 no-headers renders 3 lines", #lines3 == 3, #lines3)

local row0 = C.green .. "A " .. RESET .. " " .. "B " .. " " .. "  " .. " "
check("3x3 row0: color + plain + empty cell", lines3[1] == row0)

local row1 = (C.red .. REV_ON .. "C " .. REV_OFF .. RESET) .. " " ..
  "DD" .. " " ..
  (C.yellow .. "E " .. RESET) .. " "
check("3x3 row1: selected cell (reverse-video) + 2-char glyph + colored", lines3[2] == row1)

local row2 = "F " .. " " .. "G " .. " " .. (C.cyan .. "H " .. RESET) .. " "
check("3x3 row2: plain cells + trailing colored cell", lines3[3] == row2)

-- ---- col + row headers + origin_label ------------------------------------
local lines3h = maplib.render(grid3, { col_headers = true, row_headers = true, origin_label = "XY" })
check("3x3 with headers renders 4 lines", #lines3h == 4, #lines3h)

local header_line = "X" .. " " .. "0 " .. " " .. "1 " .. " " .. "2 " .. " "
check("header line: truncated origin_label + col numbers", lines3h[1] == header_line)

local hrow0 = "0" .. " " .. row0
local hrow1 = "1" .. " " .. row1
local hrow2 = "2" .. " " .. row2
check("headered row0 has row-number prefix", lines3h[2] == hrow0)
check("headered row1 has row-number prefix", lines3h[3] == hrow1)
check("headered row2 has row-number prefix", lines3h[4] == hrow2)

for _, l in ipairs(lines3h) do
  check("every headered line has equal visible width",
    pagelib.visible_width(l) == pagelib.visible_width(lines3h[1]), l)
end

-- ---- east edges on two cells ---------------------------------------------
local grid2 = {
  w = 2, h = 2,
  cell = function(c, r)
    local letters = { [0] = { [0] = "a", [1] = "b" }, [1] = { [0] = "c", [1] = "d" } }
    return { glyph = letters[r][c] }
  end,
}
local east_edges = { ["0,0"] = true, ["1,1"] = true }
local lines_east = maplib.render(grid2, {
  east_edge = function(c, r) return east_edges[c .. "," .. r] end,
})
check("east edges renders 2 lines", #lines_east == 2)
check("east edge line0: wall right of (0,0), none right of (1,0)",
  lines_east[1] == "a " .. "|" .. "b " .. " ")
check("east edge line1: none right of (0,1), wall right of (1,1)",
  lines_east[2] == "c " .. " " .. "d " .. "|")

-- ---- south edges on one row ------------------------------------------------
local lines_south = maplib.render(grid2, {
  south_edge = function(c, r) return r == 0 end,
})
check("south edges renders 4 lines (edge row interleaved)", #lines_south == 4, #lines_south)
check("south edge cell row0", lines_south[1] == "a " .. " " .. "b " .. " ")
check("south edge row0's edge row: walls under both cells",
  lines_south[2] == "__" .. " " .. "__" .. " ")
check("south edge cell row1", lines_south[3] == "c " .. " " .. "d " .. " ")
check("south edge row1's edge row: no walls (south_edge false for r=1)",
  lines_south[4] == "  " .. " " .. "  " .. " ")

-- ---- cell_at round-trip: every cell's glyph position maps back to it,
-- plus header/separator/edge-slot/edge-row/out-of-bounds all report nil ----
local rt_grid = grid3
local rt_opts = {
  col_headers = true,
  row_headers = true,
  origin_label = "Z",
  east_edge = function(c, r) return (c == 0 and r == 0) or (c == 2 and r == 1) end,
  south_edge = function(c, r) return r == 1 end,
}
local rt_lines = maplib.render(rt_grid, rt_opts)
local geom = maplib.geometry(rt_grid, rt_opts)

check("geometry.height matches render() line count", geom.height == #rt_lines,
  geom.height .. " vs " .. #rt_lines)
for _, l in ipairs(rt_lines) do
  check("geometry.width matches every rendered line's visible width",
    pagelib.visible_width(l) == geom.width, l)
end

-- prefix_width = row_header_width(1) + separator(1) = 2; col_header_lines = 1;
-- body_lines_per_row = 2 (south_edge supplied).
local prefix_width = 2
local col_header_lines = 1
for r = 0, 2 do
  for c = 0, 2 do
    local x = prefix_width + c * 3
    local y = col_header_lines + r * 2
    local gc, gr = geom.cell_at(x, y)
    check(string.format("cell_at round-trip glyph-start (%d,%d) -> (%d,%d)", x, y, c, r),
      gc == c and gr == r, gc .. "," .. tostring(gr))
    local gc2, gr2 = geom.cell_at(x + 1, y)
    check(string.format("cell_at round-trip glyph-2nd-char (%d,%d) -> (%d,%d)", x + 1, y, c, r),
      gc2 == c and gr2 == r, tostring(gc2) .. "," .. tostring(gr2))
  end
end

-- header line (y=0): every x is nil.
for x = 0, geom.width - 1 do
  local gc, gr = geom.cell_at(x, 0)
  check("header row (y=0) is never a cell at x=" .. x, gc == nil and gr == nil)
end

-- row-header column (x=0) and separator column (x=1) at a body y: nil.
do
  local gc, gr = geom.cell_at(0, 1)
  check("row-header field (x=0) is never a cell", gc == nil and gr == nil)
  local gc2, gr2 = geom.cell_at(1, 1)
  check("separator column (x=1) is never a cell", gc2 == nil and gr2 == nil)
end

-- east-edge slot (glyph_start + 2) at a cell row: nil.
do
  local x = prefix_width + 0 * 3 + 2
  local gc, gr = geom.cell_at(x, col_header_lines + 0 * 2)
  check("east-edge slot is never a cell", gc == nil and gr == nil)
end

-- edge row (odd body line) at any x: nil.
do
  local y = col_header_lines + 0 * 2 + 1 -- edge row under grid row 0
  local gc, gr = geom.cell_at(prefix_width, y)
  check("edge row is never a cell", gc == nil and gr == nil)
end

-- out of bounds.
do
  local gc, gr = geom.cell_at(-1, 1)
  check("negative x is never a cell", gc == nil and gr == nil)
  gc, gr = geom.cell_at(1, -1)
  check("negative y is never a cell", gc == nil and gr == nil)
  gc, gr = geom.cell_at(geom.width, col_header_lines)
  check("x at/past total width is never a cell", gc == nil and gr == nil)
  gc, gr = geom.cell_at(prefix_width, geom.height)
  check("y at/past total height is never a cell", gc == nil and gr == nil)
end

-- ---- 16x16 grid: width discipline at scale --------------------------------
local grid16 = {
  w = 16, h = 16,
  cell = function(c, r)
    if (c + r) % 5 == 0 then return nil end
    local glyph = string.char(65 + ((c + r) % 26))
    local color
    if (c + r) % 3 == 0 then color = C.green
    elseif (c + r) % 3 == 1 then color = C.yellow end
    return { glyph = glyph, color = color, sel = (c == r) }
  end,
}
local opts16 = { col_headers = true, row_headers = true }
local lines16 = maplib.render(grid16, opts16)
local geom16 = maplib.geometry(grid16, opts16)

check("16x16 line count matches geometry.height", #lines16 == geom16.height,
  #lines16 .. " vs " .. geom16.height)
local w0 = pagelib.visible_width(lines16[1])
check("16x16 header line width matches geometry.width", w0 == geom16.width, w0)
for i, l in ipairs(lines16) do
  check("16x16 line " .. i .. " visible width equals every other line's",
    pagelib.visible_width(l) == w0, pagelib.visible_width(l))
end

-- ---- legend: flow + wrap + no color bleed ---------------------------------
local entries = {
  { glyph = "A", color = C.green,  label = "Ax" },
  { glyph = "B", color = C.red,    label = "By" },
  { glyph = "C", color = nil,      label = "Cz" },
  { glyph = "D", color = C.yellow, label = "Dw" },
}
local legend10 = maplib.legend(10, entries)
check("legend wraps into 2 lines at width 10", #legend10 == 2, #legend10)

local e1 = C.green .. "A" .. RESET .. " " .. "Ax"
local e2 = C.red .. "B" .. RESET .. " " .. "By"
local e3 = "C" .. " " .. "Cz"
local e4 = C.yellow .. "D" .. RESET .. " " .. "Dw"
check("legend line1: two entries joined, first pair fits exactly at width 10",
  legend10[1] == e1 .. "  " .. e2)
check("legend line2: remaining two entries, second pair fits exactly",
  legend10[2] == e3 .. "  " .. e4)
check("legend line1 visible width is exactly the requested width",
  pagelib.visible_width(legend10[1]) == 10)

check("legend no color bleed: line1 ends with entry2's own reset (or lack of color)",
  legend10[1]:sub(-#e2) == e2)

local legend_wide = maplib.legend(100, entries)
check("legend at ample width flows onto a single line", #legend_wide == 1, #legend_wide)
check("legend single line joins all four entries with the separator",
  legend_wide[1] == table.concat({ e1, e2, e3, e4 }, "  "))

local legend_empty = maplib.legend(10, {})
check("legend of no entries returns no lines", #legend_empty == 0, #legend_empty)

if failures > 0 then os.exit(1) end
print("ALL MAPLIB TESTS PASSED")
