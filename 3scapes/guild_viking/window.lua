-- Tab bar + page shell for the guild_viking main pane (stage 2). Pages are
-- pure builders (`mod.lines(width) -> array of strings`, reading state.lua's
-- S and page_opts.lua only, per the plan's "pages are pure" constraint); this
-- module owns the tab bar, the page registry, per-page scroll offsets, and
-- pointer routing, matching CLAUDE.md's wm.assign renderer contract:
-- render(rect, opts), on_pointer(event), and auto-captured
-- scroll/scroll_to_bottom/following_tail.
local pagelib = require("pagelib")

local window = {}

-- Ordered page registry. Task 9 replaces the last two placeholder entries
-- (army/war); no PAGES entry still points at pages.placeholder after this --
-- Task 10's audit removed pages/placeholder.lua once nothing referenced it
-- any more.
local stats_page = require("pages.stats")
local city_page = require("pages.city")
local trade_page = require("pages.trade")
local farm_page = require("pages.farm")
local builds_page = require("pages.builds")
local people_page = require("pages.people")
local goods_page = require("pages.goods")
local bonds_page = require("pages.bonds")
local ranks_page = require("pages.ranks")
local court_page = require("pages.court")
local army_page = require("pages.army")
local war_page = require("pages.war")

window.PAGES = {
  { key = "stats",  label = "Stats",  mod = stats_page },
  { key = "city",   label = "City",   mod = city_page },
  { key = "farm",   label = "Farm",   mod = farm_page },
  { key = "builds", label = "Builds", mod = builds_page },
  { key = "people", label = "People", mod = people_page },
  { key = "goods",  label = "Goods",  mod = goods_page },
  { key = "bonds",  label = "Bonds",  mod = bonds_page },
  { key = "ranks",  label = "Ranks",  mod = ranks_page },
  { key = "court",  label = "Court",  mod = court_page },
  { key = "army",   label = "Army",   mod = army_page },
  { key = "war",    label = "War",    mod = war_page },
  { key = "trade",  label = "Trade",  mod = trade_page },
}

local pages_by_key = {}
for _, p in ipairs(window.PAGES) do pages_by_key[p.key] = p end

-- Cached lines from each page's last render, keyed by page key -- feeds that
-- page's scroller's count() and the windowing math in window.render. Starts
-- empty so a page never rendered yet clamps to offset 0.
local last_lines = {}

-- ---------------------------------------------------------------------------
-- Per-page scrolling.
--
-- wm.make_scroller (scripts/default/wm.lua) is chat/log-shaped: offset counts
-- back from the newest line and its clamp is count()-1, which fits a pane
-- whose content grows at the bottom and where "at rest" (offset 0) means
-- "showing the newest line". These pages are dashboards read top-down with
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
-- ---------------------------------------------------------------------------
local function make_top_scroller(count_fn)
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
  -- module-level comment above make_top_scroller.
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

local scrollers = {}
for _, p in ipairs(window.PAGES) do
  last_lines[p.key] = {}
  scrollers[p.key] = make_top_scroller(function() return #last_lines[p.key] end)
end

local current_key = window.PAGES[1].key

function window.current_page()
  return current_key
end

-- Switching pages preserves each page's own scroller offset (LEGACY's
-- page_scroll behavior) -- nothing here touches `scrollers`.
function window.set_page(key)
  if not pages_by_key[key] then return false end
  current_key = key
  ui.dirty()
  return true
end

function window.scroll(delta)
  return scrollers[current_key].scroll(delta)
end

function window.scroll_to_bottom()
  return scrollers[current_key].scroll_to_bottom()
end

function window.following_tail()
  return scrollers[current_key].following_tail()
end

-- ---------------------------------------------------------------------------
-- Tab bar
-- ---------------------------------------------------------------------------

-- Recorded { key, row, col_start, col_end } spans from the most recent LOCAL
-- render, for on_pointer hit-testing. Mirrors wm.lua's slot-rect recording
-- and popup.lua's render() hit-test rect: recorded only when
-- `lera.render_pass() ~= "remote"` (CLAUDE.md "Pane Pointer Input" /
-- popup.lua's idiom), so a remote render pass never clobbers what the local
-- click routing depends on.
local tab_spans = {}

local SEPARATOR = " "

-- Draws the tab bar into the top of `rect`, flowing onto further rows when
-- the joined label width exceeds the rect width. Returns the number of rows
-- used. Column tracking is explicit (not string length) because the reverse-
-- video escapes wrapping the current tab must not count toward wrap
-- decisions or hit-test spans.
local function render_tabbar(rect)
  local w = rect:w()
  local row_texts, spans = { "" }, {}
  local row, col = 0, 0

  for _, p in ipairs(window.PAGES) do
    local text = p.label
    local seg_len = #text
    if col > 0 and col + seg_len > w then
      row = row + 1
      row_texts[row + 1] = ""
      col = 0
    end
    local start_col = col
    local draw_text = text
    if p.key == current_key then
      draw_text = "\27[7m" .. text .. "\27[27m"
    end
    row_texts[row + 1] = row_texts[row + 1] .. draw_text
    col = col + seg_len
    spans[#spans + 1] = { key = p.key, row = row, col_start = start_col, col_end = col }
    if col < w then
      row_texts[row + 1] = row_texts[row + 1] .. SEPARATOR
      col = col + 1
    end
  end

  if lera.render_pass() ~= "remote" then
    tab_spans = spans
  end

  for r = 1, row + 1 do
    ui.text_ansi(ui.rect(rect:x(), rect:y() + (r - 1), w, 1),
      pagelib.trunc(row_texts[r] or "", w))
  end

  return row + 1
end

-- ---------------------------------------------------------------------------
-- wm.assign renderer contract
-- ---------------------------------------------------------------------------

function window.render(rect, opts)
  local w, h = rect:w(), rect:h()
  if w <= 0 or h <= 0 then return end

  local tab_rows = render_tabbar(rect)
  local body_h = h - tab_rows
  if body_h <= 0 then return end

  local page = pages_by_key[current_key]
  local lines = page.mod.lines(w)

  local sc = scrollers[current_key]
  -- Only the LOCAL render pass may adjust the scroller's height-based clamp,
  -- or update the cached `lines` that clamp's count() reads. The scroll
  -- offset itself is a single Lua-side value shared across render targets by
  -- design (CLAUDE.md "Pane Scrolling" WebSocket note: a Lua-scrolled wm
  -- pane has no local/remote gate). But a remote WebSocket viewer can be
  -- sized independently of the local pane (CLAUDE.md "Resize semantics"),
  -- AND -- for a page whose line count is width-sensitive, stats being the
  -- first -- can produce a different total line count at its own width. If
  -- either leaked into the shared clamp, a remote render could reclamp --
  -- and silently move -- the offset the LOCAL user chose, purely as a side
  -- effect of the remote client's own screen size or width. Skipping both on
  -- a remote pass leaves the persisted clamp (and therefore the offset)
  -- exactly as the last local render left it; the remote pass still reads
  -- that same offset and windows its OWN `lines`/body_h against it below
  -- (see the loop after `offset` is read), it just never mutates the shared
  -- state.
  if lera.render_pass() ~= "remote" then
    last_lines[current_key] = lines
    sc.set_height(body_h)
  end
  local offset = sc.offset()
  local count = #lines
  local first = offset + 1
  local last = math.min(count, offset + body_h)

  local body_y = rect:y() + tab_rows
  for i = first, last do
    ui.text_ansi(ui.rect(rect:x(), body_y + (i - first), w, 1),
      pagelib.trunc(lines[i], w))
  end
end

-- A LEFT down inside a recorded tab span switches page and returns true;
-- every other event (a down with a different/no button, e.g. a middle- or
-- right-click on a tab, or a down elsewhere, e.g. the body) returns false so
-- the pane never falsely claims an interaction it didn't handle.
function window.on_pointer(event)
  if event.kind ~= "down" or event.button ~= "left" then return false end
  for _, s in ipairs(tab_spans) do
    if event.y == s.row and event.x >= s.col_start and event.x < s.col_end then
      return window.set_page(s.key)
    end
  end
  return false
end

return window
