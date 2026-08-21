-- War popup composite (/vik war): picks whichever of the two board views --
-- the campaign map (popups/war_campaign.lua) or the tactical battle board
-- (popups/war_battle.lua) -- is the live, actionable one right now, and
-- delegates lines()/on_pointer()/geometry()/grid_line_offset() to it.
--
-- MODE CONDITION (disclosed -- LEGACY's draw_page_war does NOT gate these
-- two sections as mutually exclusive). Reading guild_viking.lua's
-- draw_page_war (14061-14084) top to bottom: it draws the campaign map
-- whenever `state.war_map and state.war_map.active` (14077-14079), THEN
-- unconditionally draws the prison panel, THEN -- gated only by
-- page_opts.show_war_battle, independent of the campaign check above --
-- either the battle board or "No battle underway." (14084-14601). Both the
-- campaign map and the battle board can and do appear TOGETHER, stacked in
-- one page, whenever a campaign is open while a battle is also under way.
-- LEGACY's own comment at the top of the campaign-map draw explains why
-- that stacking is intentional there: "Campaign map: drawn whenever a
-- campaign is open -- including while a tactical battle runs. The server
-- stops streaming WMAP during a battle (the campaign is frozen), so this
-- renders the last-received state above the battle board" (14073-14076).
--
-- This popup is single-focus by design (the plan's brief: "a manual
-- override cycle via a keyless affordance is NOT needed -- the composite
-- follows state"), so where LEGACY stacks, this composite must pick. The
-- natural either/or implied by LEGACY's own comment is used as the mode
-- condition: a tactical battle, once joined, is the thing actually live
-- and interactive -- the campaign march freezes underneath it -- so BATTLE
-- TAKES PRIORITY whenever `S.battle` is present; the campaign map is shown
-- only when there is no battle (whether or not one ever starts). Neither
-- present -> a plain "nothing to show" line, since a popup needs SOME
-- content and this board-only popup carries none of the pane's other
-- sections (council/campaigns/houses) to fall back on -- by design, since
-- this task's brief scopes the popup to the two BOARD views only.
--
-- The prison panel is NOT part of this composite -- it already lives in
-- the pane (pages/war.lua) and this task's brief says explicitly not to
-- duplicate it.
local pagelib = require("pagelib")
local state = require("state")
local war_campaign = require("popups.war_campaign")
local war_battle = require("popups.war_battle")

local S = state.S
local C = pagelib.C
local RESET = pagelib.RESET

local M = {}
M.title = "War"

local function active_module()
  if S.battle then return war_battle end
  if S.war_map and S.war_map.active then return war_campaign end
  return nil
end

function M.lines(width)
  local mod = active_module()
  if not mod then
    return { pagelib.trunc(C.dim .. "No campaign or battle underway." .. RESET, width) }
  end
  return mod.lines(width)
end

function M.on_pointer(ev, ctx)
  local mod = active_module()
  if not mod or not mod.on_pointer then return nil end
  return mod.on_pointer(ev, ctx)
end

function M.geometry(width)
  local mod = active_module()
  if not mod or not mod.geometry then return nil end
  return mod.geometry(width)
end

function M.grid_line_offset(width)
  local mod = active_module()
  if not mod or not mod.grid_line_offset then return 0 end
  return mod.grid_line_offset(width)
end

return M
