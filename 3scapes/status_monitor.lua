-- Status Monitor: a Lera popup port of the legacy StatusMonitor miniwindow.
-- It reads the existing plugin APIs rather than duplicating their GMCP feeds.

local M = { name = "status_monitor", version = "1.0", priority = 55 }
M.window_launcher = { label = "Status Monitor", compact_label = "Status", order = 10 }
local command = require("command")

local defaults = {
  page = "overview",
  sections = {
    position = true, stepper = true, killers = true, commands = true,
    target = true, coffin = true, reboot = true, lag = true,
  },
}
local settings = {}
local popup_open, command_id, timer_id = false, nil, nil
local hits = { tabs = {}, toggles = {} }

local function copy_defaults()
  settings = { page = defaults.page, sections = {} }
  for key, value in pairs(defaults.sections) do settings.sections[key] = value end
end

local function save()
  store.set(settings)
  store.save()
end

local function load()
  copy_defaults()
  store.load()
  local saved = store.get()
  if type(saved) ~= "table" then return end
  if saved.page == "overview" or saved.page == "sections" then settings.page = saved.page end
  if type(saved.sections) == "table" then
    for key in pairs(defaults.sections) do
      if type(saved.sections[key]) == "boolean" then settings.sections[key] = saved.sections[key] end
    end
  end
end

local function refresh()
  if popup_open then ui.dirty() end
end

local function plugin_api(name)
  local plugin = plugin.get(name)
  return plugin
end

local function call(plugin, method, ...)
  if not plugin or type(plugin[method]) ~= "function" then return nil end
  local ok, first, second = pcall(plugin[method], ...)
  if not ok then return nil end
  return first, second
end

local function dim(text) return "\27[2m" .. text .. "\27[0m" end
local function cyan(text) return "\27[96m" .. text .. "\27[0m" end
local function green(text) return "\27[92m" .. text .. "\27[0m" end
local function yellow(text) return "\27[93m" .. text .. "\27[0m" end
local function red(text) return "\27[91m" .. text .. "\27[0m" end

local function trunc(text, width)
  text = tostring(text or "")
  if width <= 1 then return "" end
  if #text <= width then return text end
  return text:sub(1, width - 1) .. "~"
end

local function duration(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  local days = math.floor(seconds / 86400)
  local hours = math.floor(seconds % 86400 / 3600)
  local mins = math.floor(seconds % 3600 / 60)
  if days > 0 then return string.format("%dd %dh %dm", days, hours, mins) end
  if hours > 0 then return string.format("%dh %dm", hours, mins) end
  return string.format("%dm", mins)
end

local function bar(pct, cells)
  pct = math.max(0, math.min(100, tonumber(pct) or 0))
  local filled = math.floor(pct / 100 * cells)
  return "[" .. string.rep("#", filled) .. string.rep(".", cells - filled) .. "]"
end

local function add(lines, key, text)
  if settings.sections[key] then lines[#lines + 1] = text end
end

local function overview_lines(width)
  local lines = {}
  local roominfo = plugin_api("roominfo")
  local speedwalk = plugin_api("speedwalk")
  local killers = plugin_api("kill_trigger")
  local stats = plugin_api("player_stats")
  local mudstatus = plugin_api("mudstatus")

  local room = call(roominfo, "info")
  if room then
    local position = room.area or room.room or "Unknown"
    if room.room and room.area and room.room ~= room.area then position = room.area .. " - " .. room.room end
    add(lines, "position", cyan("Pos: ") .. trunc(position, width - 5))
  else
    add(lines, "position", cyan("Pos: ") .. dim("Waiting for Room.Info"))
  end

  local step = call(speedwalk, "step_info")
  if step and (step.total or 0) > 0 then
    local name = step.place or "Steps"
    local pct = step.total > 0 and (step.current or 0) / step.total * 100 or 0
    local current = string.format("%s %s %d/%d", trunc(name, 16), bar(pct, 10), step.current or 0, step.total or 0)
    add(lines, "stepper", cyan("Steps: ") .. current .. dim("  left " .. tostring(step.remaining or 0)))
  else
    add(lines, "stepper", cyan("Steps: ") .. dim("No active step list"))
  end

  local enabled = call(killers, "is_enabled")
  local killer_list = call(killers, "get_killers")
  if type(killer_list) == "table" and #killer_list > 0 then
    add(lines, "killers", cyan("Killers: ") .. (enabled and green("ON ") or red("OFF ")) .. trunc(table.concat(killer_list, ", "), width - 14))
  else
    add(lines, "killers", cyan("Killers: ") .. dim("No configured killers"))
  end

  local commands = call(killers, "get_commands")
  if type(commands) == "table" and #commands > 0 then
    local numbered = {}
    for index, value in ipairs(commands) do numbered[#numbered + 1] = index .. ") " .. value end
    add(lines, "commands", cyan("Commands: ") .. trunc(table.concat(numbered, "  "), width - 11))
  else
    add(lines, "commands", cyan("Commands: ") .. dim("No kill commands"))
  end

  local player = call(stats, "get_stats")
  if player and player.attacker and player.attacker ~= "" then
    local hp = math.max(0, math.min(100, tonumber(player.attacker_hp) or 0))
    local color = hp > 50 and green or (hp > 25 and yellow or red)
    add(lines, "target", cyan("Target: ") .. trunc(player.attacker, math.max(8, width - 28)) .. " " .. color(bar(hp, 10) .. string.format(" %d%%", hp)))
  else
    add(lines, "target", cyan("Target: ") .. dim("None"))
  end

  if player and player.coffin_max and player.coffin_max > 0 then
    local current = tonumber(player.coffin) or 0
    local maximum = tonumber(player.coffin_max) or 0
    local pct = current / maximum * 100
    local color = pct < 70 and green or (pct < 90 and yellow or red)
    add(lines, "coffin", cyan("Coffin: ") .. color(string.format("%d/%d %s", current, maximum, bar(pct, 10))))
  else
    add(lines, "coffin", cyan("Coffin: ") .. dim("Unavailable"))
  end

  local status = call(mudstatus, "snapshot")
  local reboot = call(mudstatus, "reboot_left")
  if reboot then
    local total = status and (status.reboot_total or ((status.uptime or 0) + (status.reboot_left or 0))) or nil
    local pct = total and total > 0 and (total - reboot) / total * 100 or 0
    add(lines, "reboot", cyan("Reboot: ") .. yellow(bar(pct, 10) .. " " .. duration(reboot)))
  else
    add(lines, "reboot", cyan("Reboot: ") .. dim("Waiting for Mud.Status"))
  end

  if status and type(status.lag) == "number" then
    local color = status.lag < 100 and green or (status.lag < 300 and yellow or red)
    add(lines, "lag", cyan("Lag: ") .. color(string.format("%.2f", status.lag)))
  else
    add(lines, "lag", cyan("Lag: ") .. dim("Unavailable"))
  end
  return lines
end

local section_order = {
  { "position", "Position" }, { "stepper", "Step progress" },
  { "killers", "Killers" }, { "commands", "Kill commands" },
  { "target", "Combat target" }, { "coffin", "Coffin" },
  { "reboot", "Reboot" }, { "lag", "Server lag" },
}

local window = {}
function window.render(rect)
  local tabs, toggles = {}, {}
  local tabline = cyan("[Overview]") .. " " .. cyan("[Sections]") .. " " .. cyan("[Close]")
  ui.text_ansi(ui.rect(rect:x(), rect:y(), rect:w(), 1), tabline)
  tabs.overview = { from = 0, to = 9 }
  tabs.sections = { from = 11, to = 20 }
  tabs.close = { from = 22, to = 28 }

  if settings.page == "sections" then
    ui.text_ansi(ui.rect(rect:x(), rect:y() + 2, rect:w(), 1), dim("Click a section to show or hide it."))
    local row = 4
    for _, entry in ipairs(section_order) do
      local key, label = entry[1], entry[2]
      ui.text_ansi(ui.rect(rect:x(), rect:y() + row, rect:w(), 1),
        (settings.sections[key] and green("[x] ") or dim("[ ] ")) .. label)
      toggles[row] = key
      row = row + 1
    end
  else
    local row = 2
    for _, text in ipairs(overview_lines(rect:w())) do
      if row >= rect:h() then break end
      ui.text_ansi(ui.rect(rect:x(), rect:y() + row, rect:w(), 1), text)
      row = row + 1
    end
    if row < rect:h() then ui.text_ansi(ui.rect(rect:x(), rect:y() + row, rect:w(), 1), dim("/monitor [show|hide|toggle|overview|sections|section <name> on|off]")) end
  end
  if lera.render_pass() ~= "remote" then hits = { tabs = tabs, toggles = toggles } end
end

function window.on_pointer(event)
  if event.kind ~= "down" or event.button ~= "left" then return false end
  if event.y == 0 then
    if event.x >= hits.tabs.overview.from and event.x <= hits.tabs.overview.to then settings.page = "overview"
    elseif event.x >= hits.tabs.sections.from and event.x <= hits.tabs.sections.to then settings.page = "sections"
    elseif event.x >= hits.tabs.close.from and event.x <= hits.tabs.close.to then M.close(); return true
    else return false end
    save(); refresh(); return true
  end
  if settings.page == "sections" and hits.toggles[event.y] then
    local key = hits.toggles[event.y]
    settings.sections[key] = not settings.sections[key]
    save(); refresh(); return true
  end
  return false
end

local function close_popup()
  local wm = require("wm")
  if popup_open and wm.popup.is_open() then wm.popup.close() end
  popup_open = false
end

local function open_popup()
  local wm = require("wm")
  if popup_open and wm.popup.is_open() then return end
  wm.popup.open(window, { title = "Status Monitor", width = 0.62, height = 0.62,
    on_close = function() popup_open = false end })
  popup_open = true
end

local function toggle_popup()
  if popup_open and require("wm").popup.is_open() then close_popup() else open_popup() end
end

function M.is_open() return popup_open end
function M.open() open_popup() end
function M.close() close_popup() end
function M.toggle() toggle_popup() end

local function usage()
  print("Usage: /monitor [show|hide|toggle|overview|sections|section <name> on|off|toggle]")
end

local function dispatch(args)
  local sub, rest = tostring(args or ""):match("^%s*(%S*)%s*(.-)%s*$")
  sub, rest = (sub or ""):lower(), rest or ""
  if sub == "" or sub == "toggle" then toggle_popup()
  elseif sub == "show" then open_popup()
  elseif sub == "hide" then close_popup()
  elseif sub == "overview" or sub == "sections" then settings.page = sub; save(); open_popup(); refresh()
  elseif sub == "section" then
    local key, value = rest:match("^(%S+)%s*(%S*)$")
    key, value = (key or ""):lower(), (value or ""):lower()
    if defaults.sections[key] == nil or (value ~= "on" and value ~= "off" and value ~= "toggle") then usage(); return end
    if value == "toggle" then settings.sections[key] = not settings.sections[key] else settings.sections[key] = value == "on" end
    save(); refresh()
  else usage() end
end

function M.on_load()
  load()
  command_id = assert(command.register({
    name = "/monitor", aliases = { "/sm" },
    usage = "/monitor [show|hide|toggle|overview|sections|section <name> on|off]",
    summary = "Open and configure the status monitor",
    description = "Status Monitor is the Lera port of the legacy dashboard. It shows live plugin data and has clickable Overview and Sections pages.",
    accepts_args = true, handler = dispatch,
  }))
  timer_id = timer.every(1000, refresh)
end

function M.on_unload()
  close_popup()
  if timer_id then timer.cancel(timer_id); timer_id = nil end
  if command_id then command.unregister(command_id); command_id = nil end
  save()
end

return M
