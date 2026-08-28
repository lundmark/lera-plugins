-- The file pane: the wizard's current directory, laid out in ls-style columns.
--
-- The entry model is separated from the drawing so the layout is testable
-- without a screen, and render() stays a pure draw from it -- which is also
-- what keeps it idempotent across the local and remote (WebSocket) render
-- passes that both call it.
--
-- Two functions describe what to show:
--   entries() -- the navigable entries, directories A-Z then files A-Z
--   notice()  -- a single full-width message (loading, an error, truncation)
-- A notice is never gridded: it is one row spanning the pane, and it is never
-- clickable.

local wm = require("wm")
local protocol = require("protocol")

local M = {}

-- Blank columns between cells. Two is the usual `ls` separation and is wide
-- enough that a trailing "/" does not visually run into the next column.
local GUTTER = 2

-- The content width the last render used. The scroller's count() takes no
-- arguments but the number of display rows depends on the pane WIDTH, so the
-- width has to reach it somehow; caching the last render's is the same trick
-- border_shown uses below, and it keeps count() and render() in agreement.
local last_w = nil

-- Identity of the listing currently on screen, so a new one can be spotted and
-- scrolled back to the top.
local last_key = nil

-- Whether the most recent render() drew a border. on_pointer() has no opts of
-- its own -- wm calls it with just the event -- so it has to agree with
-- render() about the inset some other way. Defaults to true, matching
-- opts.show_border's own default.
local border_shown = true

-- ---- the entry model -------------------------------------------------------

local function listing()
  if not protocol.available() then return nil, "Files.List unavailable (not a wizard?)" end
  local cwd = protocol.cwd()
  if not cwd then return nil, "loading..." end
  local entry = protocol.lookup(cwd)
  if not entry then return nil, "loading..." end
  if entry.error then return nil, cwd .. ": " .. entry.error end
  if not entry.complete then return nil, "loading..." end
  return entry, entry.truncated and "(listing truncated)" or nil
end

-- Sorted so a grid scans predictably. Directories stay grouped ahead of files
-- -- the grouping is the useful part, and mixing them would scatter the only
-- rows that are clickable.
function M.entries()
  local entry = listing()
  if not entry then return {} end

  local dirs = {}
  for i = 1, #entry.dirs do dirs[i] = entry.dirs[i] end
  table.sort(dirs)

  local files = {}
  for i = 1, #entry.files do files[i] = entry.files[i] end
  table.sort(files)

  local out = {}
  for i = 1, #dirs do
    out[#out + 1] = { text = dirs[i] .. "/", is_dir = true, name = dirs[i] }
  end
  for i = 1, #files do
    out[#out + 1] = { text = files[i], is_dir = false, name = files[i] }
  end
  return out
end

function M.notice()
  local _, message = listing()
  return message
end

-- ---- layout ----------------------------------------------------------------

-- Grid geometry for a content width: the entries, how many columns fit, how
-- many rows that needs, and the per-cell width.
--
-- Columns are uniform, sized to the longest entry in the whole listing. n
-- columns need n*longest + (n-1)*GUTTER cells, so the count that fits is
-- floor((w + GUTTER) / (longest + GUTTER)) -- the +GUTTER accounts for the
-- last column needing no trailing gutter.
local function grid(w)
  local entries = M.entries()
  if #entries == 0 then return entries, 1, 0, w end

  local longest = 0
  for i = 1, #entries do
    if #entries[i].text > longest then longest = #entries[i].text end
  end

  local cell = longest + GUTTER
  local cols = math.floor((w + GUTTER) / cell)
  if cols < 1 then cols = 1 end
  local rows = math.ceil(#entries / cols)
  return entries, cols, rows, cell
end

-- Total display rows: the grid, plus the notice's own row when there is one.
local function display_rows(w)
  local _, _, rows = grid(w)
  return rows + (M.notice() and 1 or 0)
end

local sc = wm.make_scroller({
  -- Before the first render there is no width to lay out against. 40 is only
  -- a placeholder for that one call; every later count() uses the real width.
  count = function() return display_rows(last_w or 40) end,
})

M.scroll = sc.scroll
M.scroll_to_bottom = sc.scroll_to_bottom
M.following_tail = sc.following_tail

-- The first display row drawn, given the scroll offset. The offset is a
-- distance from the tail, so the arithmetic is tail-relative even though a
-- fresh listing is anchored to the top by reset_scroll_on_new_listing below.
local function first_visible(h, total)
  local start = total - h + 1 - sc.offset()
  if start < 1 then start = 1 end
  return start
end

-- A directory listing should open showing its FIRST entries; the scroller
-- otherwise starts at the tail, which is right for a chat pane and wrong here.
-- Scrolling up by the row count lands on the top because the scroller clamps
-- the offset to count-1.
local function reset_scroll_on_new_listing()
  local cwd = protocol.cwd()
  local entry = cwd and protocol.lookup(cwd)
  local key = table.concat({
    tostring(cwd),
    tostring(entry and entry.complete),
    tostring(entry and #entry.dirs or 0),
    tostring(entry and #entry.files or 0),
    tostring(M.notice()),
  }, "|")
  if key == last_key then return end
  last_key = key
  sc.scroll(-(display_rows(last_w or 40) + 1))
end

-- ---- drawing ---------------------------------------------------------------

-- A rect is USERDATA whose fields are methods (src/lua/api_ui.c:79-86), not a
-- table of plain fields. wm may also hand a plain table through, so both forms
-- are read -- the same dual-form idiom as chat_monitor.lua:973-976. Note the
-- fields are w/h, not width/height.
local function rect_dims(rect)
  if type(rect.x) == "function" then
    return rect:x(), rect:y(), rect:w(), rect:h()
  end
  return rect.x, rect.y, rect.w, rect.h
end

-- The one place the border inset is applied, so render() and on_pointer()
-- can never drift apart on it. Takes the OUTER (pane-local, border included)
-- geometry and returns the CONTENT geometry.
local function inset_for_border(x, y, w, h, show_border)
  if show_border then
    return x + 1, y + 1, w - 2, h - 2
  end
  return x, y, w, h
end

function M.render(rect, opts)
  opts = opts or {}
  local show_border = opts.show_border ~= false
  local title = opts.title or "Files"
  border_shown = show_border

  local x, y, w, h = rect_dims(rect)
  if show_border then ui.box(rect, "single", title) end
  x, y, w, h = inset_for_border(x, y, w, h, show_border)
  if w <= 0 or h <= 0 then return end

  last_w = w
  reset_scroll_on_new_listing()

  local notice = M.notice()
  local entries, cols, rows, cell = grid(w)
  local start = first_visible(h, rows + (notice and 1 or 0))

  local line = 0
  for r = start, rows do
    if line >= h then break end
    for c = 0, cols - 1 do
      -- Column-major: a column runs the full grid height before the next
      -- begins, so entry order reads DOWN a column, as plain `ls` does.
      local e = entries[c * rows + r]
      if e then
        local cx = c * cell
        local avail = w - cx
        if avail > 0 then
          local text = e.text
          if #text > avail then text = text:sub(1, avail) end
          ui.text(ui.rect(x + cx, y + line, #text, 1), text)
        end
      end
    end
    line = line + 1
  end

  if notice and line < h then
    ui.text(ui.rect(x, y + line, w, 1), notice)
  end
end

function M.on_pointer(event)
  if event.kind ~= "down" or event.button ~= "left" then return false end

  -- event.x/event.y are pane-local and include the border; run them through the
  -- same inset render() used so a click lands on the cell it visually points
  -- at, and a click on a border row or column navigates nowhere.
  local ox, oy, ow, oh = inset_for_border(0, 0, event.width or 0, event.height or 0,
                                          border_shown)
  local lx = (event.x or 0) - ox
  local ly = (event.y or 0) - oy
  if lx < 0 or lx >= ow or ly < 0 or ly >= oh then return false end

  local notice = M.notice()
  local entries, cols, rows, cell = grid(ow)
  local row = first_visible(oh, rows + (notice and 1 or 0)) + ly
  -- Past the grid: either the notice's row or empty space. Neither navigates.
  if row > rows then return false end

  local col = math.floor(lx / cell)
  if col >= cols then return false end

  -- Indexed against the TOTAL grid rows, not the visible ones: a column spans
  -- the whole grid, so scrolling changes which rows show, not how a column is
  -- numbered.
  local e = entries[col * rows + row]
  if not e or not e.is_dir then return false end
  -- Only the text itself is clickable, not the gutter padding after it.
  if (lx - col * cell) >= #e.text then return false end

  -- A real cd, so the confirmation line updates the cwd exactly as a typed one
  -- would. There is deliberately no second source of truth here.
  mud.send("cd " .. e.name)
  return true
end

return M
