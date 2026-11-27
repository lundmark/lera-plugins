-- Refinery page: every refinery's full ten-stage chain, what each stage
-- refines into, how much of the throughput is allocated to it, and whether it
-- is reachable yet (Craft.Buildings' "refineries" rows).
--
-- The server sends one row PER STAGE now rather than only per allocated stage,
-- so this page can show the whole ladder including the stages you have not
-- unlocked. That matters because the locked stages are the interesting ones --
-- they are the high-tier materials the weapon and armour ladders climb into,
-- and the only way to see how far off they are is to see them listed.
--
-- Row fields (state.lua's parse_refinery_row):
--   building, tier (= stage index), material, percent,
--   bldg_tier, max_tier, min_rank
-- bldg_tier 0 means the refinery is not built. A stage is locked when
-- stage > max_tier; the server computes max_tier (building tier x 2, clamped
-- to the chain length) so client and server cannot disagree about the rule.
local pagelib = require("pagelib")
local state = require("state")

local C = pagelib.C
local M = {}

local function stage_color(locked, pct)
  if locked then return C.dim end
  if pct > 0 then return C.bright_green end
  return C.white
end

function M.lines(width)
  width = pagelib.page_width(width)
  local s = state.get()
  local lines = {}
  local function add(text) lines[#lines + 1] = text end

  if #s.refineries == 0 then
    add(pagelib.trunc(C.dim .. "No Craft.Buildings refinery data received yet."
      .. pagelib.RESET, width))
    return lines
  end

  -- Group the flat row list back into one block per refinery, preserving the
  -- order the stages arrived in rather than re-sorting by name: the chain IS
  -- an ordered progression and stage 1 must stay first.
  local groups, order = {}, {}
  for _, r in ipairs(s.refineries) do
    local k = r.building or "?"
    if not groups[k] then groups[k] = {}; order[#order + 1] = k end
    table.insert(groups[k], r)
  end
  table.sort(order)

  local first = true
  for _, name in ipairs(order) do
    local rows = groups[name]
    table.sort(rows, function(a, b) return (a.tier or 0) < (b.tier or 0) end)

    -- bldg_tier/max_tier are per-refinery, so any row carries them. Absent on
    -- the legacy four-field payload, in which case the lock state is unknown
    -- and every stage is shown as available rather than wrongly greyed out.
    local head = rows[1] or {}
    local bldg_tier = head.bldg_tier
    local max_tier = head.max_tier
    local legacy = (bldg_tier == nil)

    if not first then add("") end
    first = false

    if not legacy and bldg_tier < 1 then
      add(pagelib.header(width, name))
      add(pagelib.trunc("  " .. C.dim .. "not built" .. pagelib.RESET, width))
    else
      local suffix = legacy and ""
        or string.format("  T%d  stages 1-%d", bldg_tier, max_tier or 0)
      add(pagelib.header(width, name .. suffix))

      -- Total allocated, so an under- or over-committed refinery is obvious
      -- without adding the column up by eye.
      local total = 0
      for _, r in ipairs(rows) do total = total + (r.percent or 0) end
      local tcol = C.bright_green
      if total == 0 then tcol = C.dim
      elseif total > 100 then tcol = C.bright_red
      elseif total < 100 then tcol = C.yellow end
      add(pagelib.trunc("  " .. tcol .. "allocated " .. total .. "%" .. pagelib.RESET
        .. "  " .. pagelib.meter(total, 100, 33, tcol), width))

      local trows = {}
      for _, r in ipairs(rows) do
        local stage = r.tier or 0
        local locked = (not legacy) and max_tier and stage > max_tier
        local pct = r.percent or 0
        local color = stage_color(locked, pct)
        trows[#trows + 1] = {
          "T" .. stage,
          color .. pagelib.title(r.material or "") .. pagelib.RESET,
          r.min_rank and ("R" .. r.min_rank) or "",
          locked and "locked" or (pct > 0 and "allocated" or "available"),
          locked and "-" or (pagelib.bar(14, pct, 100, color) .. " " .. pct .. "%"),
        }
      end

      pagelib.add_table(lines, width, {
        { title = "Stage",    w = 6 },
        { title = "Material", w = "*" },
        { title = "Rank",     w = 6 },
        { title = "Status",   w = 11 },
        { title = "Allocation", w = 20 },
      }, trows)
    end
  end

  add("")
  add(pagelib.trunc(C.dim
    .. "crefine allocate <realm> <material> <percent>  |  crefine reset <realm>"
    .. pagelib.RESET, width))

  return lines
end

return M
