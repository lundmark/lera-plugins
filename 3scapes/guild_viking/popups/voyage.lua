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
-- Page title: "Voyage" (NOT "Voyage Status"), deliberately distinct from
-- common.status_lines' own "Voyage Status" section header a few lines
-- below it. The two used to be the same string, rendering "Voyage Status"
-- twice in a row with an active voyage (fix round 1, Important #2) -- this
-- module's OWN top-of-popup header exists only to give the popup a title
-- when there's nothing else to show yet (the no-data/no-voyage fallbacks),
-- exactly like popups/map.lua's "Territory Map" and popups/sea.lua's
-- "Sea Chart" headers; neither of those collides with any section header
-- either. Convention going forward: a module's own top header must never
-- equal one of its section headers.
--
-- This module has no grid (no chart), so it exposes neither geometry() nor
-- grid_line_offset() -- ctx.cell_from_xy simply does not apply here, exactly
-- like a module with no data to grid, per popups.lua's header comment. It
-- DOES expose on_pointer now (fix round 1, remedy #1): the same
-- "[Actions]" line popups/sea.lua renders (reroll/resolve/end/clear, see
-- sea_common.lua's M.actions()) is hit-tested here too via ctx.line_from_y,
-- since the Queue section -- and therefore the Clear Queue action -- is
-- part of this module's own subset.
local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local common = require("popups.sea_common")

local S = state.S

local M = {}
M.title = "Voyage"

-- Shared with popups/sea.lua's pre_chart_lines (same three-gate structure:
-- mip_voyage_seen -> show_sea_voyage -> voyage_status, and the same
-- "[Actions]" line appended right after the status/no-voyage block), but
-- this module has no chart section to hold anything back for, so lines()
-- builds straight through in one pass. Second return value: the 1-based
-- index of the "[Actions]" line, or nil -- same shape as popups/sea.lua's
-- pre_chart_lines, kept in lockstep with `out` by construction so the
-- rendered line and the hit-test index can never drift apart.
local function pre_lines(width)
  local out = { pagelib.header(width, "Voyage") }

  if not S.mip_voyage_seen then
    for _, l in ipairs(common.mip_gate_lines(width)) do out[#out + 1] = l end
    return out, nil
  end
  if not page_opts.get("show_sea_voyage") then return out, nil end
  if not S.voyage_status then
    for _, l in ipairs(common.no_voyage_lines(width)) do out[#out + 1] = l end
  else
    for _, l in ipairs(common.status_lines(width)) do out[#out + 1] = l end
  end

  local actions_idx = nil
  local action_lines = common.actions_line(width)
  if #action_lines > 0 then
    for _, l in ipairs(action_lines) do out[#out + 1] = l end
    actions_idx = #out
  end
  return out, actions_idx
end

function M.lines(width)
  local out = pre_lines(width)
  if not (S.mip_voyage_seen and page_opts.get("show_sea_voyage") and S.voyage_status) then
    return out
  end

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

-- Same width-invariance rationale as popups/sea.lua's M.actions_line_index
-- (re-confirmed on review during fix round 2, contrasted there with
-- popups/war_battle.lua's actions line, which is NOT width-invariant):
-- nothing pre_lines renders ever reflows by width (no wrapping happens
-- anywhere in this module's output), so a fixed probe width is safe here
-- too -- verified by this module's own two-different-widths test case.
-- ACTIONS_PROBE_WIDTH remains the fallback for a caller with no width to
-- hand; on_pointer below still threads the pointer event's own `ev.width`
-- through for defense in depth / uniformity with the other action-line
-- modules.
local ACTIONS_PROBE_WIDTH = 76
function M.actions_line_index(width)
  local _, idx = pre_lines(width or ACTIONS_PROBE_WIDTH)
  return idx
end

-- Pointer: the "[Actions]" line is this module's ONLY clickable content
-- (no chart, no grid) -- see popups/sea.lua's header comment for the full
-- hotspot enumeration/port table this line covers. No down-target tracker
-- here: unlike sea/cityplan/map/war_campaign/war_battle, this module has
-- exactly one clickable target, so there is no cross-target drag for a
-- tracker to defend against.
function M.on_pointer(ev, ctx)
  if ev.kind ~= "down" or not ctx.line_from_y then return nil end
  local idx = M.actions_line_index(ev.width)
  if not idx or ctx.line_from_y(ev.y) ~= idx then return nil end
  common.open_actions_menu()
  return true
end

return M
