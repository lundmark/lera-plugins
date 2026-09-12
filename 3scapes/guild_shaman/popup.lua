-- Popup presentation for the shaman pages.
--
-- guild_viking surfaces its pages the same way (see its popups.lua): the
-- profile's four wm slots are already spoken for by chat/map/stats/output, so
-- a guild plugin that wants a real window uses the popup overlay rather than
-- competing for a slot. Printing pages into the scrollback works but scrolls
-- away and cannot be scrolled independently, which is the whole reason this
-- exists.
--
-- pages.lua's builders are already pure `lines(width)` functions, which IS the
-- renderer contract, so this file is only the scrolling wrapper around them.
local pages = require("pages")

local M = {}

-- Which page is showing, so a second `/sham powers` closes it instead of
-- reopening the same thing on top of itself.
local shown = nil

-- One scrolling renderer around a page builder.
--
-- The line count is recomputed inside render() rather than cached at open
-- time, because the pages are fed by GMCP and grow and shrink under the popup
-- as frames land -- a Powers list gains rows the moment another power is
-- toggled on. Feeding the scroller a stale count would let the offset clamp
-- against a length the page no longer has.
-- Tab order. A table (not pairs over pages.PAGES) so the bar is stable --
-- pairs() order is undefined and the tabs would shuffle between renders.
local TAB_ORDER = { "status", "powers", "discord" }
local SEPARATOR = " "

-- Which tab the popup is currently showing. Module-level so a click can move
-- it without reopening the popup.
local current = "status"

-- Column spans recorded by the last LOCAL render, for on_pointer hit-testing:
-- { key, row, col_start, col_end } with zero-based columns, col_end exclusive.
-- Mirrors guild_viking/window.lua's tab_spans, including its pass guard --
-- a remote render must not overwrite the local layout being clicked on.
local tab_spans = {}
local tab_rows = 0

-- Body hit-testing, recorded by the last LOCAL render alongside tab_spans.
-- body_targets is pages.powers' line-index -> { id, label } map; body_top is
-- how many rows the tab bar used; body_offset is the scroll offset those rows
-- were drawn at.
local body_targets = nil
local body_top = 0
local body_offset = 0
local body_drawn = 0

-- Draws the tab bar into the top of the rect, wrapping onto further rows when
-- the labels outrun the width. Returns rows used. Column tracking is explicit
-- rather than string length because the reverse-video escapes around the
-- active tab must not count toward wrap decisions or hit-test spans.
local function render_tabbar(x, y, w)
  local row_texts, spans = { "" }, {}
  local row, col = 0, 0

  for _, key in ipairs(TAB_ORDER) do
    local page = pages.PAGES[key]
    if page then
      local text = page.title
      local seg = #text
      if col > 0 and col + seg > w then
        row = row + 1
        row_texts[row + 1] = ""
        col = 0
      end
      local start_col = col
      local draw = (key == current) and ("\27[7m" .. text .. "\27[27m") or text
      row_texts[row + 1] = (row_texts[row + 1] or "") .. draw
      col = col + seg
      spans[#spans + 1] = { key = key, row = row, col_start = start_col, col_end = col }
      if col < w then
        row_texts[row + 1] = row_texts[row + 1] .. SEPARATOR
        col = col + 1
      end
    end
  end

  if lera.render_pass() ~= "remote" then
    tab_spans = spans
    tab_rows = row + 1
  end

  for r = 1, row + 1 do
    ui.text_ansi(ui.rect(x, y + (r - 1), w, 1), row_texts[r] or "")
  end
  return row + 1
end

local function wrap()
  local last_count = 0
  local sc = require("wm").make_scroller({ count = function() return last_count end })

  local wrapper = {}

  function wrapper.render(rect, opts)
    local x, y, w, h
    if type(rect.x) == "function" then
      x, y, w, h = rect:x(), rect:y(), rect:w(), rect:h()
    else
      x, y, w, h = rect.x, rect.y, rect.w, rect.h
    end
    if not w or not h or w <= 0 or h <= 0 then return 0 end

    local used = render_tabbar(x, y, w)
    local body_h = h - used
    if body_h <= 0 then return used end

    local page = pages.PAGES[current] or pages.PAGES.status
    -- Second return value is the clickable-row map (line index -> target);
    -- only pages.powers builds one, and nil for every other page is exactly
    -- what disables body clicks there.
    local lines, targets = page.fn(w)
    last_count = #lines

    local offset = sc.offset()
    local drawn = 0
    for i = 1, body_h do
      local line = lines[i + offset]
      if not line then break end
      ui.text_ansi(ui.rect(x, y + used + i - 1, w, 1), line)
      drawn = drawn + 1
    end

    -- Same pass guard as tab_spans: a remote render must not overwrite the
    -- layout the local user is clicking on. body_top/body_offset are stored
    -- with the map because a click arrives in popup-local rows and has to be
    -- translated back through the CURRENT scroll offset to a line index.
    if lera.render_pass() ~= "remote" then
      body_targets = targets
      body_top = used
      body_offset = offset
      body_drawn = drawn
    end
    return used + drawn
  end

  -- LEFT down inside a recorded tab span switches page and consumes the event
  -- (same MouseDown-fires convention guild_viking/window.lua documents). Any
  -- other button, or a down outside the bar, returns false so the popup never
  -- claims an interaction it did not handle.
  function wrapper.on_pointer(event)
    -- The field is `kind`, NOT `type` -- scripts/default/popup.lua's
    -- local_event() builds { kind, button, x, y, inside, width, height } and
    -- guild_viking/window.lua reads event.kind for the same reason. Checking
    -- event.type silently matched nothing, so the tabs rendered but never
    -- responded to a click.
    --
    -- x/y are already popup-local (local_event subtracts the border), so they
    -- line up with the rows render_tabbar drew and need no adjustment.
    if not event or event.kind ~= "down" or event.button ~= "left" then return false end
    -- The tab loop is skipped for a click below the bar rather than returning
    -- outright: body rows are hit-tested after it, and an unconditional early
    -- return here made every power-row click a no-op.
    if event.y < tab_rows then
      for _, t in ipairs(tab_spans) do
        if event.y == t.row and event.x >= t.col_start and event.x < t.col_end then
          current = t.key
          -- scroll_to_bottom() sets offset = 0, and this renderer indexes
          -- lines[i + offset] from the top -- so offset 0 IS the top of the newly
          -- selected page. (The earlier extra sc.scroll(-1e9) was a redundant
          -- clamp to the same place.)
          sc.scroll_to_bottom()
          ui.dirty()
          return true
        end
      end
    end

    -- Below the tab bar: a click on a power row toggles it. The command is
    -- the same one the player would type -- `shmaintain <name>` is itself a
    -- toggle (cmd/shmaintain.c), so the click needs no knowledge of the
    -- current state and cannot desync from it. Nothing is sent optimistically
    -- and no local state is written: the authoritative answer arrives as the
    -- next Guild.Powers frame.
    if body_targets then
      local row = event.y - body_top
      if row >= 0 and row < body_drawn then
        local target = body_targets[row + 1 + body_offset]
        -- `mud` is a lera-injected global. Guarded rather than assumed: the
        -- pointer handler runs inside the UI event path, where an index of a
        -- nil global would take the popup down rather than merely failing to
        -- send.
        if target and mud and mud.send then
          mud.send("shmaintain " .. target.label)
          return true
        end
      end
    end
    return false
  end

  -- Auto-captured by wm.popup.open off the renderer table, same contract as a
  -- pane renderer.
  function wrapper.scroll(delta) return sc.scroll(delta) end
  function wrapper.scroll_to_bottom() return sc.scroll_to_bottom() end
  function wrapper.following_tail() return sc.following_tail() end

  return wrapper
end

-- Opens `key`'s page as a popup, or closes it if that same page is already
-- the one showing. Returns false for an unknown page name so the caller can
-- fall through to its usage line.
function M.toggle(key)
  local page = pages.PAGES[key]
  if not page then return false end

  local wm = require("wm")
  -- Same page requested while it is already the one on screen: close.
  if wm.popup.is_open() and shown and current == key then
    wm.popup.close()
    shown = nil
    return true
  end

  -- Already open on a DIFFERENT tab: just switch, no reopen. This is what
  -- makes '/sham powers' behave like clicking the Powers tab.
  current = key
  if wm.popup.is_open() and shown then
    ui.dirty()
    return true
  end

  wm.popup.open(wrap(), {
    title = "Shaman",
    width = 0.8,
    height = 0.8,
    -- Cleared on ANY close (a second toggle, Escape, a click outside, or
    -- being replaced by another popup), so the toggle above can never get
    -- out of step with what is actually on screen.
    on_close = function() shown = nil end,
  })
  shown = key
  return true
end

function M.close()
  local wm = require("wm")
  if wm.popup.is_open() then wm.popup.close() end
  shown = nil
end

function M.shown() return shown end

-- Which tab is selected. The popup has ONE title now ("Shaman") and the page
-- identity lives in the tab bar, so this is what callers (and tests) should
-- ask rather than reading the window title.
function M.current() return current end

return M
