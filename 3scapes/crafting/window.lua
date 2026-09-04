-- Tab bar + page shell for the crafting popup, opened by /craft. Pages are
-- pure builders (`mod.lines(width) -> array of strings`, reading state.lua's
-- data only); this module owns the tab bar, the page registry, per-page
-- scroll offsets, and tab-click routing. Modeled on guild_viking/window.lua,
-- trimmed for a v1 with no right-click page menu and no clickable body rows
-- (crafting's pages are read-only dashboards, not action grids).
local pagelib = require("pagelib")
local scroller = require("scroller")

local window = {}

local info_page = require("pages.info")
local inventory_page = require("pages.inventory")
local skills_page = require("pages.skills")
local buildings_page = require("pages.buildings")
local jobs_page = require("pages.jobs")
local recipes_page = require("pages.recipes")
local market_page = require("pages.market")

window.PAGES = {
  { key = "info",      label = "Info",      mod = info_page },
  { key = "inventory", label = "Inventory", mod = inventory_page },
  { key = "skills",    label = "Skills",    mod = skills_page },
  { key = "buildings", label = "Buildings", mod = buildings_page },
  { key = "jobs",       label = "Jobs",      mod = jobs_page },
  { key = "recipes",   label = "Recipes",   mod = recipes_page },
  { key = "market",    label = "Market",    mod = market_page },
}

local pages_by_key = {}
for _, p in ipairs(window.PAGES) do pages_by_key[p.key] = p end

-- Cached lines from each page's last render, feeding that page's scroller.
local last_lines = {}
local scrollers = {}
for _, p in ipairs(window.PAGES) do
  last_lines[p.key] = {}
  scrollers[p.key] = scroller.make_top_scroller(function() return #last_lines[p.key] end)
end

local current_key = window.PAGES[1].key

function window.current_page() return current_key end

function window.set_page(key)
  if not pages_by_key[key] then return false end
  current_key = key
  ui.dirty()
  return true
end

function window.scroll(delta) return scrollers[current_key].scroll(delta) end
function window.scroll_to_bottom() return scrollers[current_key].scroll_to_bottom() end
function window.following_tail() return scrollers[current_key].following_tail() end

-- Recorded from the most recent LOCAL render pass, for tab-click hit-testing
-- (CLAUDE.md "Pane Pointer Input": a remote WebSocket viewer's render must
-- never clobber what local click routing depends on).
local tab_spans = {}
local recorded_tab_rows = 0

local SEPARATOR = " "

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

function window.render(rect, opts)
  local w, h = rect:w(), rect:h()
  if w <= 0 or h <= 0 then return end

  local tab_rows = render_tabbar(rect)
  local body_h = h - tab_rows
  if lera.render_pass() ~= "remote" then
    recorded_tab_rows = tab_rows
  end
  if body_h <= 0 then return end

  local page = pages_by_key[current_key]
  local lines = page.mod.lines(w)

  local sc = scrollers[current_key]
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

-- A LEFT down inside a recorded tab span switches page (fires on down, same
-- as guild_viking's chrome tabs). Nothing else in this v1 is clickable.
function window.on_pointer(event)
  if event.kind == "cancel" then return false end
  if event.button ~= "left" or event.kind ~= "down" then return false end
  for _, s in ipairs(tab_spans) do
    if event.y == s.row and event.x >= s.col_start and event.x < s.col_end then
      return window.set_page(s.key)
    end
  end
  return false
end

return window
