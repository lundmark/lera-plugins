-- Down-target recording, shared by the interactive popup modules that need
-- it (war_campaign, war_battle, cityplan, sea). map never consumes a
-- "down" at all (hover-only), so popup.lua never captures a gesture for
-- it and it needs no tracker; voyage's [Actions] line is its only
-- clickable target, so there is no second target for a mismatched up to
-- land on. Both are documented inline in their own modules.
--
-- Real MUSHclient/miniwin hotspot semantics: a mouseup is only delivered to
-- the SAME hotspot that took the matching mousedown, even for a hotspot with
-- no MouseDown callback of its own (the miniwin runtime still tracks capture
-- internally). lera's popup layer (scripts/default/popup.lua) instead
-- captures by BUTTON alone -- once a down is consumed, every subsequent up
-- for that button is delivered to whichever renderer/module is live at that
-- moment, at whatever coordinates the release landed on, with no notion of
-- "which target got the down". Left alone, that turns a drag from one
-- target to another (or, for the war composite, a mode flip mid-drag from
-- war_campaign to war_battle) into a click that fires the WRONG target's
-- action -- the exact bug this task's Critical #1 and Important #1 findings
-- describe.
--
-- Each module keeps its own module-local tracker (one call to M.tracker()
-- at load time) and records what its own "down" hit; "up" then only acts
-- when the up's own target matches the recorded down target -- reproducing
-- the "hotspot that took the mousedown gets the mouseup" rule despite the
-- popup layer's coarser button-only capture. A module clears the record on
-- "cancel" (synthesized by popup.lua when the popup closes mid-drag) and
-- after every "up", matched or not.
--
-- FAIL-CLOSED (fix round 3 -- flipped from an earlier fail-open default).
-- When NOTHING has been recorded (down_recorded is false -- either no down
-- ever happened, or the record was already consumed/cleared by a prior
-- up), matches() now returns FALSE: no recorded down means no target to
-- have matched, so nothing may act. The earlier fail-open default existed
-- only to let each module's own direct-call unit tests drive "up" events
-- on their own, without simulating a full down+up sequence -- a testing
-- convenience, not a real requirement, and it was actively wrong for the
-- real dispatch path: popups/war.lua's composite re-resolves which
-- sub-module is "active" on every call, so a battle ending mid-drag (down
-- consumed by war_battle, `S.battle` cleared before the up arrives) could
-- route that up to war_campaign, whose OWN tracker never recorded that
-- down -- fail-open let it act anyway, firing a real command for a
-- gesture it was never part of. war.lua's own gesture-pinning (see its
-- header comment) now keeps a captured gesture routed to the module that
-- actually took the down, but this tracker is a second, independent line
-- of defense: even a mis-routed up must still fail to act when this
-- specific module recorded no matching down of its own. Audited on this
-- flip: none of the four modules that hold a tracker (war_campaign,
-- war_battle, cityplan, sea) has any legitimate on_pointer path that
-- relies on acting without a recorded down of its own.
local M = {}

local function same(a, b)
  if a == nil or b == nil then return false end
  if a.kind ~= b.kind then return false end
  if a.kind == "cell" then return a.c == b.c and a.r == b.r end
  return true -- non-cell kinds (e.g. "actions") match on kind alone
end

function M.tracker()
  local down_target = nil
  local down_recorded = false
  local t = {}

  function t.record(target)
    down_target = target
    down_recorded = true
  end

  function t.clear()
    down_target = nil
    down_recorded = false
  end

  function t.matches(target)
    if not down_recorded then return false end
    return same(down_target, target)
  end

  return t
end

return M
