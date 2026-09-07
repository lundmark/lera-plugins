-- Buildings page: every built building -> tier, plus refinery splits
-- (Craft.Buildings). Both fields are arrays of flat records, not mappings
-- keyed by building name -- that shape was confirmed to vanish entirely
-- over GMCP delivery (see crafting_daemon's gmcp.h _cgmcp_push_buildings).
local pagelib = require("pagelib")
local state = require("state")

local C = pagelib.C
local M = {}

local function tier_color(t)
  if t >= 5 then return C.bright_green end
  if t >= 3 then return C.green end
  if t >= 1 then return C.yellow end
  return C.dim
end

function M.lines(width)
  width = width or 80
  local s = state.get()
  local lines = {}
  local function add(text) lines[#lines + 1] = text end

  if #s.buildings == 0 then
    add(pagelib.trunc(C.dim .. "No buildings constructed yet." .. pagelib.RESET, width))
    return lines
  end

  local sorted = {}
  for _, b in ipairs(s.buildings) do sorted[#sorted + 1] = b end
  table.sort(sorted, function(a, b) return (a.name or "") < (b.name or "") end)

  add(pagelib.header(width, "Buildings"))
  local rows, colors = {}, {}
  for _, b in ipairs(sorted) do
    rows[#rows + 1] = { b.name, "T" .. tostring(b.tier or 0) }
    colors[#colors + 1] = tier_color(b.tier or 0)
  end
  local cols = pagelib.columns(width, {
    { title = "Building", w = "*" },
    { title = "Tier", w = 6 },
  }, rows)
  add(cols[1])
  local i
  for i = 2, #cols do
    add(colors[i - 1] .. cols[i] .. pagelib.RESET)
  end

  -- Refineries have their own tab now. This used to inline every allocation
  -- here, which was reasonable while the server sent only the stages that had
  -- one; it now sends the whole ten-stage chain per refinery, so reproducing
  -- it here would bury the building list under sixty mostly-empty rows.
  -- A one-line summary keeps the cross-reference without the noise.
  if #s.refineries > 0 then
    local seen, count, allocated = {}, 0, 0
    for _, r in ipairs(s.refineries) do
      local k = r.building or "?"
      if not seen[k] then seen[k] = true; count = count + 1 end
      if (r.percent or 0) > 0 then allocated = allocated + 1 end
    end
    add("")
    add(pagelib.trunc(string.format(
      "%s%d refiner%s, %d allocated stage%s -- see the Refinery tab%s",
      C.dim, count, count == 1 and "y" or "ies",
      allocated, allocated == 1 and "" or "s", pagelib.RESET), width))
  end

  return lines
end

return M
