-- Tab bar + page shell for the crafting popup, opened by /craft. Pages are
-- pure builders (`mod.lines(width) -> array of strings`, reading state.lua's
-- data only); this module owns the tab bar, the page registry, per-page
-- scroll offsets, and pointer routing for tabs and explicit action buttons.
local pagelib = require("pagelib")
local scroller = require("scroller")

local window = {}

local info_page = require("pages.info")
local inventory_page = require("pages.inventory")
local skills_page = require("pages.skills")
local buildings_page = require("pages.buildings")
local refinery_page = require("pages.refinery")
local jobs_page = require("pages.jobs")
local automation_page = require("pages.automation")
local recipes_page = require("pages.recipes")
local market_page = require("pages.market")

window.PAGES = {
  { key = "info",      label = "Overview",  mod = info_page },
  { key = "inventory", label = "Inventory", mod = inventory_page },
  { key = "skills",    label = "Skills",    mod = skills_page },
  { key = "buildings", label = "Buildings", mod = buildings_page },
  { key = "refinery",  label = "Refinery",  mod = refinery_page },
  { key = "jobs",      label = "Production", mod = jobs_page },
  { key = "automation", label = "Automation", mod = automation_page },
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
local body_hits = {}
local hover_row
local right_target
local last_command, last_command_at
local action_generation = 0

function window.reset_actions()
  body_hits = {}
  hover_row = nil
  right_target = nil
  last_command, last_command_at = nil, nil
  action_generation = action_generation + 1
end

function window.current_page() return current_key end

-- Set by a render that drew a running countdown; consumed by countdown_tick.
local countdown_pending = false

-- Called once a second while the popup is open (init.lua): redraw only when
-- the last render showed a running countdown. The request is consumed even
-- if that deadline has passed, so the next render draws the final "ready" /
-- "ended" state and only re-arms if something is still counting.
function window.countdown_tick()
  if not countdown_pending then return end
  countdown_pending = false
  ui.dirty()
end

function window.set_page(key)
  if not pages_by_key[key] then return false end
  if key ~= current_key then countdown_pending = false end
  current_key = key
  body_hits = {}
  hover_row = nil
  right_target = nil
  ui.dirty()
  return true
end

function window.scroll(delta)
  body_hits = {}
  hover_row = nil
  right_target = nil
  return scrollers[current_key].scroll(delta)
end

function window.scroll_to_bottom()
  body_hits = {}
  hover_row = nil
  right_target = nil
  return scrollers[current_key].scroll_to_bottom()
end
function window.scroll_to_top()
  return window.scroll(-#last_lines[current_key])
end
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

local function draw_hover(rect, first_row, selected_row, text)
  local width = math.min(62, rect:w())
  local lines, content_width = {}, 0
  for part in text:gmatch("[^\n]+") do
    local line = ""
    for word in part:gmatch("%S+") do
      if line ~= "" and pagelib.visible_width(line .. " " .. word) > width - 2 then
        lines[#lines + 1], line = line, ""
      end
      line = line == "" and word or (line .. " " .. word)
    end
    lines[#lines + 1] = line
  end

  local below, above = rect:h() - selected_row - 1, selected_row - first_row
  local show_above = #lines > below and above > below
  local count = math.min(#lines, show_above and above or below)
  local top = show_above and selected_row - count or selected_row + 1
  for i = 1, count do
    content_width = math.max(content_width, pagelib.visible_width(lines[i]) + 2)
  end
  for i = 1, count do
    local body = " " .. lines[i]
    local padding = math.max(0, math.min(width, content_width) - pagelib.visible_width(body))
    ui.text_ansi(ui.rect(rect:x(), rect:y() + top + i - 1, width, 1),
      "\27[7m" .. pagelib.trunc(body, width) .. string.rep(" ", padding) .. pagelib.RESET)
  end
end

function window.render(rect, opts)
  local w, h = rect:w(), rect:h()
  if w <= 0 or h <= 0 then return end

  local local_render = lera.render_pass() ~= "remote"
  if local_render then body_hits = {} end
  local tab_rows = render_tabbar(rect)
  local body_h = h - tab_rows
  if lera.render_pass() ~= "remote" then
    recorded_tab_rows = tab_rows
  end
  if body_h <= 0 then return end

  local page = pages_by_key[current_key]
  pagelib.live_countdown = false
  local lines, actions = page.mod.lines(w)
  if pagelib.live_countdown then countdown_pending = true end

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
    if local_render and actions then
      body_hits[tab_rows + i - first] = actions[i]
    end
    ui.text_ansi(ui.rect(rect:x(), body_y + (i - first), w, 1),
      pagelib.trunc(lines[i], w))
  end
  if local_render and hover_row and hover_row >= tab_rows
      and hover_row < tab_rows + last - first + 1 then
    local target = actions and actions[first + hover_row - tab_rows]
    if target and target.hover then
      draw_hover(rect, tab_rows, hover_row, target.hover)
    end
  end
end

local function send_command(command, allow_repeat)
  if type(command) ~= "string" then return end
  local now = lera.time()
  -- Suppress accidental double clicks on a spending or toggle action.
  if allow_repeat or command ~= last_command or now - last_command_at >= 1 then
    mud.send(command)
    last_command, last_command_at = command, now
  end
end

local function open_menu(menu)
  if type(menu) == "function" then menu = menu() end
  local generation = action_generation
  require("menu").open({
    title = menu.title,
    items = menu.items,
    on_select = function(selection)
      if generation ~= action_generation then return end
      if type(selection) == "table" and selection.page then
        window.set_page(selection.page)
      else
        send_command(selection)
      end
    end,
  })
end

local function on_right_click(event, target)
  if event.kind == "down" then
    right_target = target and target.key
    return right_target ~= nil
  end
  if event.kind == "up" then
    local matched = event.inside ~= false and target and target.key == right_target
    right_target = nil
    if matched then
      open_menu(target.menu)
      return true
    end
  end
  return false
end

function window.on_pointer(event)
  if event.kind == "move" then
    local hit = event.inside ~= false and body_hits[event.y]
    local row = hit and hit.hover and event.y or nil
    if row ~= hover_row then
      hover_row = row
      ui.dirty()
    end
    return false
  end
  if event.kind == "cancel" then
    right_target = nil
    if hover_row then
      hover_row = nil
      ui.dirty()
    end
    return false
  end
  local hits = body_hits[event.y] or {}
  local primary = hits.primary
  if event.button == "right" then return on_right_click(event, primary) end
  if event.button ~= "left" or event.kind ~= "down" then return false end
  for _, s in ipairs(tab_spans) do
    if event.y == s.row and event.x >= s.col_start and event.x < s.col_end then
      return window.set_page(s.key)
    end
  end
  if primary and event.x >= primary.first and event.x < primary.last then
    if primary.left_menu then
      open_menu(primary.menu)
      return true
    elseif primary.command then
      send_command(primary.command, primary.allow_repeat)
      return true
    end
  end
  for _, button in ipairs(hits) do
    if event.x >= button.first and event.x < button.last then
      if button.page then return window.set_page(button.page) end
      if button.activate then
        button.activate()
        window.scroll_to_top()
        ui.dirty()
        return true
      end
      if button.menu then
        open_menu(button.menu)
      else
        send_command(button.command, button.allow_repeat)
      end
      return true
    end
  end
  return false
end

return window
