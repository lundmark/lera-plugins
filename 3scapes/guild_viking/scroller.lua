-- Top-anchored scroller for top-down dashboard content: window.lua's pane
-- pages and popups.lua's popup wrapper both read this. Extracted verbatim
-- from window.lua (stage 2) so the popup wrapper can share the exact same
-- offset math without duplicating it -- a pure refactor, zero behavior
-- change; window.lua's own tests cover it unchanged.
--
-- wm.make_scroller (scripts/default/wm.lua) is chat/log-shaped: offset counts
-- back from the newest line and its clamp is count()-1, which fits a pane
-- whose content grows at the bottom and where "at rest" (offset 0) means
-- "showing the newest line". This content is dashboards read top-down with
-- no live tail -- LEGACY's page_scroll table works the same way (a plain
-- top-of-page line offset). Reusing wm.make_scroller as-is would mean offset
-- 0 shows the LAST line of the page, and scrolling "up" would jump from that
-- tail-anchored window toward line 1 in one step, which is backwards for a
-- document meant to be read from the top down.
--
-- make_top_scroller below keeps the exact contract wm.assign auto-captures
-- (offset()/following_tail()/scroll()/scroll_to_bottom()) and the CLAUDE.md
-- sign convention (delta < 0 = up/older = toward line 1) -- it just measures
-- offset as a count of lines below the TOP instead of above the bottom, and
-- clamps against (line count - visible height) instead of (line count - 1).
-- offset 0 therefore shows lines[1..height] (top-anchored "at rest"); this
-- is the deliberate resolution the task brief asked for, in place of trying
-- to force wm.make_scroller's tail semantics onto top-down content.
local scroller = {}

function scroller.make_top_scroller(count_fn)
  local offset, height = 0, 1

  local function clamp()
    local max = count_fn() - height
    if max < 0 then max = 0 end
    if offset > max then offset = max end
    if offset < 0 then offset = 0 end
  end

  local sc = {}

  -- Called every render with the current body height, so clamping tracks a
  -- resized pane as well as a resized page.
  function sc.set_height(h)
    height = (h and h > 0) and h or 1
    clamp()
  end

  function sc.offset()
    clamp()
    return offset
  end

  -- NOTE: unlike a tail-anchored pane (wm.make_scroller / the "output" slot,
  -- where following_tail() == true means "at the newest/bottom line"), this
  -- scroller's "at rest" position is the TOP: following_tail() == true here
  -- means offset() == 0, i.e. showing the page from its first line. Same
  -- name, same wm.assign contract, opposite physical direction -- see the
  -- module-level comment above.
  function sc.following_tail()
    clamp()
    return offset == 0
  end

  function sc.scroll(delta)
    offset = offset + (delta or 0)
    clamp()
    ui.dirty()
  end

  function sc.scroll_to_bottom()
    offset = count_fn()
    clamp()
    ui.dirty()
  end

  return sc
end

return scroller
