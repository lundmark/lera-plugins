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
  width = pagelib.page_width(width)
  local s = state.get()
  local lines = {}
  local function add(text) lines[#lines + 1] = text end

  if #s.buildings == 0 and #s.builds == 0 and #s.pending_builds == 0 then
    add(pagelib.trunc(C.dim .. "No buildings constructed yet." .. pagelib.RESET, width))
    return lines
  end

  local entries, names = {}, {}
  local function entry(name)
    if not entries[name] then
      entries[name] = {}
      names[#names + 1] = name
    end
    return entries[name]
  end
  for _, b in ipairs(s.buildings) do entry(b.name or "?").tier = b.tier end
  for _, b in ipairs(s.pending_builds) do entry(b.building or "?").pending = b.tier end
  for _, b in ipairs(s.builds) do entry(b.building or "?").build = b end
  table.sort(names)

  add(pagelib.header(width, "Buildings"))
  local rows = {}
  for _, name in ipairs(names) do
    local b = entries[name]
    local current = b.tier and (tier_color(b.tier) .. "T" .. b.tier .. pagelib.RESET) or "-"
    local target = b.build and b.build.tier or b.pending
    local status = b.build and "Under construction" or b.pending and "Awaiting funding" or "Built"
    local timer = b.build and pagelib.job_time(b.build.due, b.build.duration, s.jobs_clock) or "-"
    rows[#rows + 1] = { name, current, target and ("T" .. target) or "-", status, timer }
  end
  pagelib.add_table(lines, width, {
    { title = "Building", w = "*" }, { title = "Tier", w = 6 }, { title = "Target", w = 7 },
    { title = "Status", w = 20 }, { title = "Completion", w = 29 },
  }, rows)

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
