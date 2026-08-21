-- Voyage Status popup (/vik voyage): the compact voyage-status SUBSET of
-- LEGACY guild_viking.lua's draw_page11 (14674-15297) -- per the plan's
-- binding split ruling, exactly the Voyage Status fields (+ Awaiting
-- Resolution + Identity/Traits/Crew, which LEGACY draws as a continuation of
-- the same status block, guild_viking.lua:14996-15121) plus the
-- Queue/Saga/Crew Memory sections, and NO chart. See popups/sea.lua's header
-- comment for the full section classification, gate table, and hotspot
-- enumeration/port table -- this module reuses popups/sea_common.lua's
-- section builders verbatim and adds nothing of its own; there is no
-- chart-only content here to duplicate that comment for.
--
-- This module has no grid (no chart), so it exposes neither geometry() nor
-- grid_line_offset() nor on_pointer -- ctx.cell_from_xy simply does not
-- apply here, exactly like a module with no data to grid, per popups.lua's
-- header comment.
local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local common = require("popups.sea_common")

local S = state.S

local M = {}
M.title = "Voyage Status"

-- Shared with popups/sea.lua's pre_chart_lines (same three-gate structure:
-- mip_voyage_seen -> show_sea_voyage -> voyage_status), but this module has
-- no chart section to hold back behind grid_line_offset, so lines() can
-- just build straight through in one pass.
function M.lines(width)
  local out = { pagelib.header(width, "Voyage Status") }

  if not S.mip_voyage_seen then
    for _, l in ipairs(common.mip_gate_lines(width)) do out[#out + 1] = l end
    return out
  end
  if not page_opts.get("show_sea_voyage") then return out end
  if not S.voyage_status then
    for _, l in ipairs(common.no_voyage_lines(width)) do out[#out + 1] = l end
    return out
  end

  for _, l in ipairs(common.status_lines(width)) do out[#out + 1] = l end
  if page_opts.get("show_sea_queue") then
    for _, l in ipairs(common.queue_lines(width)) do out[#out + 1] = l end
  end
  if page_opts.get("show_sea_saga") then
    for _, l in ipairs(common.saga_lines(width)) do out[#out + 1] = l end
  end
  if page_opts.get("show_sea_memory") then
    for _, l in ipairs(common.memory_lines(width)) do out[#out + 1] = l end
  end
  return out
end

return M
