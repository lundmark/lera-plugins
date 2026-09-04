-- Window Manager provides a small clickable launcher for optional popup tools.

local M = { name = "window_manager", version = "1.0", priority = 56 }
local command = require("command")

local function entries()
  local found = {}
  for _, loaded in ipairs(plugin.list()) do
    local candidate = plugin.get(loaded.name)
    local meta = candidate and candidate.window_launcher
    if type(meta) == "table" and type(candidate.open) == "function"
       and type(candidate.is_open) == "function" then
      found[#found + 1] = {
        key = loaded.name,
        plugin = loaded.name,
        label = meta.label or loaded.name,
        compact_label = meta.compact_label or meta.label or loaded.name,
        order = tonumber(meta.order) or 100,
      }
    end
  end
  table.sort(found, function(left, right)
    if left.order ~= right.order then return left.order < right.order end
    return left.label < right.label
  end)
  return found
end

local popup_open, command_id = false, nil

local function tool(entry)
  return plugin.get(entry.plugin)
end

local function is_open(entry)
  local candidate = tool(entry)
  if not candidate or type(candidate.is_open) ~= "function" then return false end
  local ok, open = pcall(candidate.is_open)
  return ok and open == true
end

local function open_tool(entry)
  local candidate = tool(entry)
  if not candidate or type(candidate.open) ~= "function" then
    print("[windows] " .. entry.label .. " is not loaded")
    return false
  end
  local ok, err = pcall(candidate.open)
  if not ok then print("[windows] failed to open " .. entry.label .. ": " .. tostring(err)); return false end
  return true
end

local compact = {}
local compact_hits = {}
function compact.render(rect, opts)
  ui.box(rect, "single", (opts and opts.title) or "Windows")
  local inner = ui.shrink(rect, 1)
  if inner:w() <= 0 or inner:h() <= 0 then return end

  local found = entries()
  local columns = 2
  local column_width = math.max(1, math.floor(inner:w() / columns))
  local next_hits = {}
  for index, entry in ipairs(found) do
    local row = math.floor((index - 1) / columns)
    if row >= inner:h() then break end
    local column = (index - 1) % columns
    local x = inner:x() + column * column_width
    local color = is_open(entry) and "\27[2m" or "\27[97m"
    ui.text_ansi(ui.rect(x, inner:y() + row, column_width, 1),
      color .. "[" .. entry.compact_label .. "]\27[0m")
    next_hits[#next_hits + 1] = {
      entry = entry, x = 1 + column * column_width,
      to = 1 + (column + 1) * column_width - 1, y = 1 + row,
    }
  end
  if lera.render_pass() ~= "remote" then compact_hits = next_hits end
end
function compact.on_pointer(event)
  -- wm pointer coordinates include this pane’s one-cell border.
  if event.kind ~= "down" or event.button ~= "left" then return false end
  for _, hit in ipairs(compact_hits) do
    if event.y == hit.y and event.x >= hit.x and event.x <= hit.to then
      return open_tool(hit.entry)
    end
  end
  return false
end

M.pane = compact

local window = {}
function window.render(rect)
  ui.text_ansi(ui.rect(rect:x(), rect:y(), rect:w(), 1), "\27[96m[Windows] [Close]\27[0m")
  ui.text_ansi(ui.rect(rect:x(), rect:y() + 1, rect:w(), 1), "\27[2mClick a tool to open it. Escape or Close returns to the game.\27[0m")
  for index, entry in ipairs(entries()) do
    local open = is_open(entry)
    local color = open and "\27[2m" or "\27[97m"
    local state = open and "\27[2mOPEN\27[0m" or "\27[97mready\27[0m"
    ui.text_ansi(ui.rect(rect:x(), rect:y() + index + 1, rect:w(), 1),
      color .. string.format("[%d] %-18s", index, entry.label) .. "\27[0m " .. state)
  end
end

function window.on_pointer(event)
  if event.kind ~= "down" or event.button ~= "left" then return false end
  if event.y == 0 and event.x >= 10 and event.x < 17 then M.close(); return true end
  local index = event.y - 1
  local entry = entries()[index]
  if not entry then return false end
  return open_tool(entry)
end

local function close_popup()
  local wm = require("wm")
  if popup_open and wm.popup.is_open() then wm.popup.close() end
  popup_open = false
end

function M.open()
  if popup_open and require("wm").popup.is_open() then return end
  require("wm").popup.open(window, { title = "Window Manager", width = 0.46, height = 0.34,
    on_close = function() popup_open = false end })
  popup_open = true
end
function M.close() close_popup() end
function M.toggle()
  if popup_open and require("wm").popup.is_open() then close_popup() else M.open() end
end

local function dispatch(args)
  local target = tostring(args or ""):match("^%s*(%S*)"):lower()
  if target == "" or target == "toggle" then M.toggle(); return end
  if target == "close" or target == "hide" then M.close(); return end
  if target == "show" then M.open(); return end
  for _, entry in ipairs(entries()) do
    if target == entry.key then open_tool(entry); return end
  end
  print("Usage: /windows [show|hide|toggle|<available window>]")
end

function M.on_load()
  command_id = assert(command.register({
    name = "/windows", aliases = { "/win" },
    usage = "/windows [show|hide|toggle|<available window>]",
    summary = "Open optional popup tools from a clickable launcher",
    description = "Discovers and opens loaded plugins that advertise an optional popup window.",
    accepts_args = true, handler = dispatch,
  }))
end

function M.on_unload()
  close_popup()
  if command_id then command.unregister(command_id); command_id = nil end
end

return M
