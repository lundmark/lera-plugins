-- pagelib: shared text-rendering toolkit for guild_viking's stage-2 panes.
-- Pure module: no lera API calls, no state access. Every page renderer
-- builds its output through these helpers so cell widths and ANSI resets
-- stay consistent across pages.
local pagelib = {}

pagelib.RESET = "\27[0m"

pagelib.C = {
  green        = "\27[32m",
  bright_green = "\27[92m",
  yellow       = "\27[33m",
  red          = "\27[31m",
  bright_red   = "\27[91m",
  cyan         = "\27[36m",
  bright_cyan  = "\27[96m",
  white        = "\27[37m",
  dim          = "\27[90m",
  magenta      = "\27[35m",
}

-- One color per realm, reused everywhere a realm name shows up (Info,
-- Skills, Recipes, ...) so a realm reads as the same color across every tab.
pagelib.REALM_COLOR = {
  Chaos = pagelib.C.red, Fantasy = pagelib.C.magenta, Science = pagelib.C.cyan,
}

function pagelib.page_width(width)
  return math.min(width or 106, 106)
end

-- Title-cases a space/hyphen-separated display string ("one-handed sword"
-- -> "One-Handed Sword"). Several Craft.* fields arrive lowercase (skill
-- keys used directly as labels, item "display" strings, etc).
function pagelib.title(s)
  if not s or s == "" then return s end
  return (tostring(s):gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b:lower() end))
end

-- Alternating row color for a zebra-striped list: pass the row's 0-based
-- index. Kept as one function so every page stripes with the same rhythm.
function pagelib.zebra(i)
  return (i % 2 == 0) and pagelib.C.white or pagelib.C.dim
end

-- Strip SGR escapes and measure what's left. Simpler than the trunc walker
-- below since it doesn't need to preserve anything.
function pagelib.visible_width(s)
  local stripped = (s or ""):gsub("\27%[[%d;]*m", "")
  return #stripped
end

-- ANSI-aware truncation/padding to exactly `width` visible cells. Escape
-- sequences (\27[...m) are copied through verbatim and cost zero width;
-- everything else counts one cell. We walk the string one unit at a time
-- (one whole escape, or one visible char) so an escape can never be split
-- mid-sequence by the width cutoff: the loop only ever stops *between*
-- units, right when `visible == width`, never inside one.
function pagelib.trunc(s, width)
  s = s or ""
  if width < 0 then width = 0 end
  local out = {}
  local visible = 0
  local escaped = false
  local i, len = 1, #s
  while i <= len and visible < width do
    if s:byte(i) == 27 then
      local seq = s:match("^\27%[[%d;]*m", i)
      if seq then
        out[#out + 1] = seq
        escaped = true
        i = i + #seq
      else
        out[#out + 1] = s:sub(i, i)
        visible = visible + 1
        i = i + 1
      end
    else
      out[#out + 1] = s:sub(i, i)
      visible = visible + 1
      i = i + 1
    end
  end
  if visible < width then
    out[#out + 1] = string.rep(" ", width - visible)
  end
  if escaped then
    out[#out + 1] = pagelib.RESET
  end
  return table.concat(out)
end

-- Ported from LEGACY's fmt_num (/home/simon/code/3s_scripts_old/lua/guild_viking.lua:7423):
--   fmt_num = function(n)
--     local s = tostring(math.floor(n or 0))
--     local result = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
--     return result:gsub("^,", "")
--   end
-- Same convention: reverse, comma every 3 digits from the right, reverse
-- back, strip a leading comma left over from a length that's a multiple of 3.
function pagelib.fmt_num(n)
  local s = tostring(math.floor(n or 0))
  local result = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (result:gsub("^,", ""))
end

-- Ported from LEGACY's get_percent_color
-- (/home/simon/code/3s_scripts_old/lua/guild_viking.lua:342-355):
--   amount = (current or 0) / (max or 100)
--   > 0.9  -> "#19ff25" (bright green)
--   > 0.75 -> "#1e7523" (green)
--   > 0.5  -> "#f2e935" (yellow)
--   > 0.25 -> "#ffa500" (orange)
--   else   -> "#ff0000" (red)
-- Same five strict thresholds, mapped onto pagelib.C's green/yellow/red
-- family in best-to-worst order (five tiers, five colors: no separate
-- "orange" in the ANSI table, so that tier maps to red and the worst tier
-- to bright_red).
function pagelib.pct_color(val, max)
  local amount = (val or 0) / (max or 100)
  if amount > 0.9 then
    return pagelib.C.bright_green
  elseif amount > 0.75 then
    return pagelib.C.green
  elseif amount > 0.5 then
    return pagelib.C.yellow
  elseif amount > 0.25 then
    return pagelib.C.red
  else
    return pagelib.C.bright_red
  end
end

-- Text bar "[####----]" of exactly `width` total visible cells including
-- the brackets. `color` colors the filled run only, reset after.
function pagelib.bar(width, val, max, color)
  local inner = width - 2
  if inner < 0 then inner = 0 end
  val = val or 0
  max = max or 0
  local filled
  if max <= 0 then
    filled = 0
  elseif val >= max then
    filled = inner
  else
    filled = math.floor(inner * val / max + 0.5)
    if filled < 0 then filled = 0 end
    if filled > inner then filled = inner end
  end
  local empty = inner - filled
  local body
  if filled > 0 and color then
    body = color .. string.rep("#", filled) .. pagelib.RESET .. string.rep("-", empty)
  else
    body = string.rep("#", filled) .. string.rep("-", empty)
  end
  return "[" .. body .. "]"
end

-- 5-band gradient bar, matching the server's own _gradient_bar (csouls.c,
-- cbuild.c): red -> yellow -> yellow -> green -> bright_green across the
-- FILLED run (not a single threshold color for the whole bar). Lera's
-- palette has no distinct "orange"/"hired" slot, so bands 0-1 share red,
-- same compromise pagelib.pct_color already makes for its 5 tiers.
function pagelib.gradient_bar(width, val, max)
  local inner = width - 2
  if inner < 0 then inner = 0 end
  val = val or 0
  max = max or 0
  local filled
  if max <= 0 then
    filled = 0
  elseif val >= max then
    filled = inner
  else
    filled = math.floor(inner * val / max + 0.5)
    if filled < 0 then filled = 0 end
    if filled > inner then filled = inner end
  end
  local bands = { pagelib.C.red, pagelib.C.red, pagelib.C.yellow, pagelib.C.green, pagelib.C.bright_green }
  local band_size = math.max(1, math.floor(inner / #bands))
  local body = {}
  local i
  for i = 1, inner do
    if i <= filled then
      local band = math.min(#bands, math.floor((i - 1) / band_size) + 1)
      body[#body + 1] = bands[band] .. "#"
    else
      body[#body + 1] = pagelib.C.dim .. "-"
    end
  end
  return "[" .. table.concat(body) .. pagelib.RESET .. "]"
end

-- Targets helper (Task 6): a bracketed clickable label ("[Run There]"),
-- colored, with its own PLAIN (escape-free) width returned alongside so a
-- caller building a window.lua pointer target's col_start/col_end can do
-- the column arithmetic in plain character counts -- the same "escapes
-- cost zero width" convention window.lua's render_tabbar already uses for
-- its own tab-span bookkeeping, rather than re-deriving width by stripping
-- escapes back out of the colored string via pagelib.visible_width.
function pagelib.button(text, color)
  local plain = "[" .. text .. "]"
  return (color or "") .. plain .. pagelib.RESET, #plain
end

-- Section header: text then a dash fill to exactly `width`, all in one
-- fixed header color. Overflow (text alone at/past width) truncates via
-- trunc exactly like every other primitive.
function pagelib.header(width, text, color)
  text = text or ""
  local raw = (color or pagelib.C.yellow) .. text .. pagelib.RESET
    .. " " .. pagelib.C.dim .. string.rep("-", width)
  return pagelib.trunc(raw, width)
end

-- Dim label, a space, the (optionally colored) value, padded/truncated to
-- width.
function pagelib.kv(width, label, value, value_color)
  local raw = pagelib.C.dim .. (label or "") .. pagelib.RESET .. " " ..
    (value_color or "") .. tostring(value)
  return pagelib.trunc(raw, width)
end

-- cols: array of { title = string, w = number | "*" } -- exactly one "*"
-- column takes the leftover width. Returns the formatted rows and the
-- resolved cell widths for hit-testing. Each input row is an array of cell
-- strings. Truncating cells independently keeps colors within their cells.
function pagelib.columns(width, cols, rows)
  local n = #cols
  local fixed_total, star_idx = 0, nil
  for i, c in ipairs(cols) do
    if c.w == "*" then
      star_idx = i
    else
      fixed_total = fixed_total + c.w
    end
  end
  local sep_total = n > 0 and (n - 1) or 0
  local widths = {}
  local leftover = width - fixed_total - sep_total
  if leftover < 0 then leftover = 0 end
  for i, c in ipairs(cols) do
    widths[i] = (star_idx == i) and leftover or c.w
  end
  if fixed_total + sep_total > width then
    local available = math.max(0, width - sep_total)
    for i, w in ipairs(widths) do
      widths[i] = math.floor(w * available / fixed_total)
    end
  end

  local function row_str(cells)
    local parts = {}
    for i = 1, n do
      parts[i] = pagelib.trunc(tostring(cells[i] or ""), widths[i])
    end
    local row = table.concat(parts, " ")
    return width < sep_total and pagelib.trunc(row, width) or row
  end

  local out = {}
  local header_cells = {}
  for i, c in ipairs(cols) do
    header_cells[i] = pagelib.C.dim .. (c.title or "")
  end
  out[1] = row_str(header_cells)
  for _, r in ipairs(rows) do
    out[#out + 1] = row_str(r)
  end
  return out, widths
end

local function mark_primary(actions, line, button, label, width)
  if not button then return end
  local spans = actions[line] or {}
  actions[line] = spans
  spans.primary = {
    first = 0, last = math.min(width, pagelib.visible_width(tostring(label))),
    key = button.key, command = button.command, allow_repeat = button.allow_repeat,
    menu = button.menu, left_menu = button.left_menu,
  }
end

-- Append a table with row targets in the first column and buttons in the last.
function pagelib.add_table(lines, width, spec, rows, actions, buttons)
  local fixed, flexible = #spec - 1, nil
  for i, col in ipairs(spec) do
    if col.w == "*" then flexible = i else fixed = fixed + col.w end
  end
  if width < fixed + (flexible and 14 or 0) then
    local primary = flexible or 1
    lines[#lines + 1] = pagelib.trunc(pagelib.C.dim .. spec[primary].title .. pagelib.RESET, width)
    for i, row in ipairs(rows) do
      lines[#lines + 1] = pagelib.trunc(tostring(row[primary] or "-"), width)
      local row_buttons = buttons and buttons[i]
      mark_primary(actions, #lines, row_buttons and row_buttons.primary, row[primary], width)
      for col, column in ipairs(spec) do
        local value = row[col]
        if col ~= primary and value ~= nil and value ~= "" and value ~= "-" then
          value = tostring(value)
          if pagelib.visible_width(value) + #column.title + 4 > width then
            value = value:gsub("^%[[^%]]*%] ", "")
          end
          lines[#lines + 1] = pagelib.trunc("  " .. column.title .. ": " .. value, width)
        end
      end
      if row_buttons and #row_buttons > 0 then
        pagelib.action_row(lines, actions, width, row_buttons)
      end
    end
    return
  end

  local formatted, widths = pagelib.columns(width, spec, rows)
  local last = #widths
  local action_col = 0
  if buttons then
    for col = 1, last - 1 do action_col = action_col + widths[col] + 1 end
  end
  lines[#lines + 1] = formatted[1]
  for i = 1, #rows do
    local row_buttons = buttons and buttons[i]
    local primary_line = #lines + 1
    if row_buttons and #row_buttons > 0 and widths[last] > 0 and action_col < width then
      local button_lines, ranges = {}, {}
      pagelib.action_row(button_lines, ranges, widths[last], row_buttons)
      lines[#lines + 1] = pagelib.trunc(formatted[i + 1], action_col) .. button_lines[1]
      local spans = ranges[1]
      if #spans < #row_buttons then
        lines[#lines] = formatted[i + 1]
        pagelib.action_row(lines, actions, width, row_buttons)
      else
        for _, span in ipairs(spans) do
          span.first, span.last = span.first + action_col, span.last + action_col
        end
        actions[#lines] = spans
      end
    else
      lines[#lines + 1] = formatted[i + 1]
      if row_buttons and #row_buttons > 0 then
        pagelib.action_row(lines, actions, width, row_buttons)
      end
    end
    mark_primary(actions, primary_line, row_buttons and row_buttons.primary, rows[i][1], widths[1])
  end
end

function pagelib.meter(value, capacity, width, color)
  value = value or 0
  if not capacity or capacity < 1 then return pagelib.fmt_num(value) end
  local label = pagelib.fmt_num(value) .. "/" .. pagelib.fmt_num(capacity)
  local bar_width = math.min(18, width - 14)
  if bar_width < 5 or #label > 13 then return label end
  return pagelib.bar(bar_width, value, capacity, color or pagelib.C.bright_cyan) .. " " .. label
end

function pagelib.job_time(due, duration, clock)
  if not due or due <= 0 then return "-" end
  local left = math.max(0, due - (clock or lera.time()))
  local eta = "ready"
  if left >= 3600 then
    eta = string.format("%dh %dm", math.floor(left / 3600), math.floor(left % 3600 / 60))
  elseif left >= 60 then
    eta = string.format("%dm %ds", math.floor(left / 60), left % 60)
  elseif left > 0 then
    eta = string.format("%ds", left)
  end
  if not duration or duration <= 0 then return "(" .. eta .. ")" end
  local elapsed = math.max(0, duration - left)
  local pct = math.floor(100 * elapsed / duration)
  return pagelib.bar(14, elapsed, duration, pagelib.C.bright_cyan) .. " " .. pct .. "%  " .. eta
end

-- Add visible buttons before a row's detail and record their cell ranges.
function pagelib.action_row(lines, actions, width, buttons, detail)
  local row, spans, col = {}, {}, 0
  for _, button in ipairs(buttons) do
    local label = "[" .. button.label .. "]"
    local last = col + #label
    if last > width then break end
    row[#row + 1] = pagelib.C.bright_cyan .. label .. pagelib.RESET .. " "
    spans[#spans + 1] = { first = col, last = last, command = button.command,
      page = button.page, menu = button.menu, activate = button.activate,
      allow_repeat = button.allow_repeat }
    col = last + 1
  end
  lines[#lines + 1] = pagelib.trunc(table.concat(row) .. (detail or ""), width)
  actions[#lines] = spans
end

-- GMCP labels become arguments only after rejecting control and stacking delimiters.
function pagelib.command_arg(value)
  if type(value) ~= "string" or not value:match("%S") or value:find("[%c;]") then return nil end
  return value
end

return pagelib
