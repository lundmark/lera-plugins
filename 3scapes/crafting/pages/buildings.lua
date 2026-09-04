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

  if #s.refineries > 0 then
    local groups, order = {}, {}
    for _, r in ipairs(s.refineries) do
      local k = r.building or "?"
      if not groups[k] then groups[k] = {}; order[#order + 1] = k end
      table.insert(groups[k], r)
    end
    table.sort(order)
    add("")
    add(pagelib.header(width, "Refinery Allocation"))
    for _, name in ipairs(order) do
      add(pagelib.trunc(C.bright_cyan .. name .. pagelib.RESET, width))
      local rows2 = groups[name]
      table.sort(rows2, function(a, b) return (a.tier or 0) < (b.tier or 0) end)
      for _, r in ipairs(rows2) do
        add(pagelib.trunc(string.format("  %s: %s%d%%%s",
          pagelib.title(r.material or ("t" .. tostring(r.tier))), C.yellow, r.percent or 0, pagelib.RESET), width))
      end
    end
  end

  return lines
end

return M
