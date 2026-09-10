-- Lera plugin manager: a clickable, Lera-styled view of the current session's plugins.
--
-- Lera currently exposes the loaded plugin registry, but not a directory listing
-- API.  Consequently this manager can always operate on loaded plugins and can
-- load any plugin by name/path supplied to the command.  That keeps discovery
-- honest instead of pretending an unloaded plugin is available when it is not.

local M = { name = "plugin_manager", version = "1.0", priority = 57 }
local command = require("command")

local popup_open = false
local command_id = nil
local hits = {}
local pending_action = nil

local function loaded_plugins()
  local result = {}
  for _, entry in ipairs(plugin.list()) do
    result[#result + 1] = {
      name = tostring(entry.name or "?"),
      version = tostring(entry.version or "?"),
      path = tostring(entry.path or ""),
      loaded = true,
    }
  end
  table.sort(result, function(a, b) return a.name:lower() < b.name:lower() end)
  return result
end

local function close_popup()
  local wm = require("wm")
  if popup_open and wm.popup.is_open() then wm.popup.close() end
  popup_open = false
  hits = {}
end

local function report(action, name, ok, err)
  if ok then
    print(string.format("[pm] %s %s", action, name))
  else
    print(string.format("[pm] %s %s failed: %s", action, name, tostring(err or "unknown error")))
  end
end

local function reload(name)
  -- Never unload ourselves while our pointer callback is executing.
  if name == M.name then
    print("[pm] Reloading the manager itself is not available; unload/reload it from the command line.")
    return
  end
  close_popup()
  local ok, result = pcall(plugin.unload, name)
  if not ok or not result then
    report("reload", name, false, ok and "unload failed" or result)
    M.open()
    return
  end
  local loaded, err = plugin.load(name)
  report("reload", name, loaded ~= nil, err)
  M.open()
end

local function toggle(entry)
  if entry.name == M.name then
    print("[pm] The manager cannot disable itself while it is open.")
    return
  end
  close_popup()
  local ok, result = pcall(plugin.unload, entry.name)
  report("disabled", entry.name, ok and result, ok and nil or result)
  M.open()
end

local function load(name)
  if name == "" then
    print("Usage: /pm load <plugin name or path>")
    return
  end
  local loaded, err = plugin.load(name)
  report("enabled", name, loaded ~= nil, err)
  if popup_open then ui.dirty() end
end

local function do_hit(hit)
  if hit.action == "close" then
    close_popup()
  elseif hit.action == "refresh" then
    ui.dirty()
  elseif hit.action == "reload" then
    reload(hit.name)
  elseif hit.action == "disable" then
    toggle({ name = hit.name })
  end
end

local window = {}
function window.render(rect)
  local list = loaded_plugins()
  local next_hits = {}
  local function text(x, y, value, color)
    ui.text_ansi(ui.rect(rect:x() + x, rect:y() + y, math.max(1, rect:w() - x), 1), color .. value .. "\27[0m")
  end

  text(0, 0, "[Refresh] [Close]", "\27[96m")
  next_hits[#next_hits + 1] = { action = "refresh", x1 = 0, x2 = 9, y = 0 }
  next_hits[#next_hits + 1] = { action = "close", x1 = 11, x2 = 16, y = 0 }
  text(0, 1, "Loaded plugins (click an action; use /pm load NAME for an unloaded plugin)", "\27[2m")

  local row = 3
  for _, entry in ipairs(list) do
    if row >= rect:h() then break end
    local label = string.format("%-22s v%-8s", entry.name, entry.version)
    text(0, row, label, "\27[97m")
    local reload_x = math.max(0, rect:w() - 18)
    local disable_x = math.max(0, rect:w() - 9)
    text(reload_x, row, "[Reload]", "\27[93m")
    text(disable_x, row, "[Disable]", "\27[91m")
    next_hits[#next_hits + 1] = { action = "reload", name = entry.name,
      x1 = reload_x, x2 = reload_x + 7, y = row }
    next_hits[#next_hits + 1] = { action = "disable", name = entry.name,
      x1 = disable_x, x2 = disable_x + 8, y = row }
    row = row + 1
  end
  if #list == 0 and row < rect:h() then text(0, row, "No plugins are currently loaded.", "\27[2m") end
  if lera.render_pass() ~= "remote" then hits = next_hits end
end

function window.on_pointer(event)
  if event.kind == "down" and event.button == "left" then
    pending_action = nil
    for _, hit in ipairs(hits) do
      if event.y == hit.y and event.x >= hit.x1 and event.x <= hit.x2 then
        pending_action = hit
        return true
      end
    end
    return false
  end
  if event.kind == "up" and event.button == "left" then
    local hit = pending_action
    pending_action = nil
    if hit and event.y == hit.y and event.x >= hit.x1 and event.x <= hit.x2 then
      do_hit(hit)
      return true
    end
  end
  return false
end

function M.open()
  local wm = require("wm")
  if popup_open and wm.popup.is_open() then return end
  wm.popup.open(window, {
    title = "Plugin Manager", width = 0.52, height = 0.62,
    on_close = function() popup_open = false; hits = {} end,
  })
  popup_open = true
end

function M.close() close_popup() end
function M.toggle()
  if popup_open and require("wm").popup.is_open() then M.close() else M.open() end
end

local function dispatch(args)
  local input = tostring(args or "")
  local verb, name = input:match("^%s*(%S+)%s*(.-)%s*$")
  verb = (verb or ""):lower()
  if verb == "" or verb == "show" or verb == "toggle" then M.toggle(); return end
  if verb == "close" or verb == "hide" then M.close(); return end
  if verb == "load" or verb == "enable" then load(name or ""); return end
  if verb == "reload" then
    if not name or name == "" then print("Usage: /pm reload <plugin>") else reload(name) end
    return
  end
  if verb == "disable" or verb == "unload" then
    if not name or name == "" then print("Usage: /pm disable <plugin>") else toggle({ name = name }) end
    return
  end
  print("Usage: /pm [show|close|load NAME|reload NAME|disable NAME]")
end

function M.on_load()
  command_id = assert(command.register({
    name = "/pm", aliases = { "/pluginmanager" },
    usage = "/pm [show|close|load NAME|reload NAME|disable NAME]",
    summary = "Manage loaded Lera plugins in a clickable window",
    description = "Click Reload or Disable for a loaded plugin. Use /pm load NAME to load a plugin by name or path.",
    accepts_args = true, handler = dispatch,
  }))
end

function M.on_unload()
  close_popup()
  if command_id then command.unregister(command_id); command_id = nil end
end

return M
