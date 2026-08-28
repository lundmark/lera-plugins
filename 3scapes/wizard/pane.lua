-- The file pane: the wizard's current directory, as rows.
--
-- rows() is separated from render() so the row model is testable without a
-- screen. render() is a pure draw from it, which also keeps it idempotent
-- across the local and remote (WebSocket) render passes.

local wm = require("wm")
local protocol = require("protocol")

local M = {}

local sc = wm.make_scroller({
  count = function() return #M.rows() end,
})

M.scroll = sc.scroll
M.scroll_to_bottom = sc.scroll_to_bottom
M.following_tail = sc.following_tail

-- A row is { text, is_dir, name }. Only is_dir rows are clickable; `name` is
-- the bare entry name the cd is built from.
function M.rows()
  if not protocol.available() then
    return { { text = "Files.List unavailable (not a wizard?)",
               is_dir = false } }
  end

  local cwd = protocol.cwd()
  if not cwd then
    return { { text = "loading...", is_dir = false } }
  end

  local entry = protocol.lookup(cwd)
  if not entry then
    return { { text = "loading...", is_dir = false } }
  end
  if entry.error then
    return { { text = cwd .. ": " .. entry.error, is_dir = false } }
  end
  if not entry.complete then
    return { { text = "loading...", is_dir = false } }
  end

  local rows = {}
  for i = 1, #entry.dirs do
    rows[#rows + 1] = { text = entry.dirs[i] .. "/", is_dir = true,
                        name = entry.dirs[i] }
  end
  for i = 1, #entry.files do
    rows[#rows + 1] = { text = entry.files[i], is_dir = false,
                        name = entry.files[i] }
  end
  if entry.truncated then
    rows[#rows + 1] = { text = "(listing truncated)", is_dir = false }
  end
  return rows
end

-- The first row index currently drawn, given the scroll offset.
local function first_visible(height)
  local rows = M.rows()
  local start = #rows - height + 1 - sc.offset()
  if start < 1 then start = 1 end
  return start
end

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

-- Whether the most recent render() drew a border. on_pointer() has no opts of
-- its own -- wm calls it with just the event -- so it has to agree with
-- render() about the inset some other way. Defaults to true, matching
-- opts.show_border's own default.
local border_shown = true

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

  local rows = M.rows()
  local start = first_visible(h)
  local line = 0
  for i = start, #rows do
    if line >= h then break end
    ui.text(ui.rect(x, y + line, w, 1), rows[i].text)
    line = line + 1
  end
end

function M.on_pointer(event)
  if event.kind ~= "down" or event.button ~= "left" then return false end

  -- event.x/event.y are pane-local and include the border; run the height
  -- through the same inset render() used so a click on content lands on the
  -- row it visually points at, and a click on the top/bottom border rows
  -- navigates nowhere. Column position never mattered here -- a row is
  -- selected by y alone, same as before this fix.
  local _, oy, _, oh = inset_for_border(0, 0, event.width or 0, event.height or 0,
                                        border_shown)
  local local_y = (event.y or 0) - oy
  if local_y < 0 or local_y >= oh then return false end

  local rows = M.rows()
  local index = first_visible(oh) + local_y
  local row = rows[index]
  if not row or not row.is_dir then return false end

  -- A real cd, so the confirmation line updates the cwd exactly as a typed one
  -- would. There is deliberately no second source of truth here.
  mud.send("cd " .. row.name)
  return true
end

return M
