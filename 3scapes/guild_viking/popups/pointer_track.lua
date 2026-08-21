-- Down-target recording, shared by every interactive popup module
-- (war_campaign, war_battle, cityplan, sea, voyage -- Important #1's "apply
-- uniformly across all five" ruling; map has no click action to protect and
-- does not need a tracker).
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
-- Fail-open by design: when NOTHING has been recorded (down_recorded is
-- false -- either no down ever happened, or the record was already
-- consumed/cleared by a prior up), matches() returns true unconditionally.
-- This is what a bare "up" with no preceding "down" needs -- exactly the
-- shape every module's own direct-call unit tests use (they drive on_pointer
-- with "up" events on their own, never simulating a full down+up capture
-- sequence) -- and it is also exactly correct for the real dispatch path:
-- popup.lua only ever delivers an "up" WITHOUT a preceding "down" having
-- been recorded by THIS module when no capture existed for this event at
-- all, in which case there is no target to compare against anyway.
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
    if not down_recorded then return true end
    return same(down_target, target)
  end

  return t
end

return M
