-- Session buttons: a strip of rounded tabs, one per session, for a profile to
-- place in its layout. The profile owns where the strip sits and how tall it
-- is; this plugin draws it, switches on click and says when it has anything
-- to show (see session_buttons.md).
local M = { name = "session_buttons", version = "2.0" }
local spans = {}
local enabled = true
local command_id
local command
local ok, module = pcall(require, "command")
if ok then command = module end

-- wm.assign picks this up: a collapsing split folds the slot away while false.
function M.visible()
  return enabled and #session.list() > 1
end

function M.render(rect)
  spans = {}
  local active = session.active()
  local x = 0
  for _, name in ipairs(session.list()) do
    -- Names are labels, never caller-supplied ANSI. Leave ordinary names
    -- unchanged while replacing terminal control bytes before drawing.
    local text = name:gsub("[%z\1-\31\127]", "?")
    local width = #text + 4
    if x + width > rect:w() then break end
    ui.box(ui.rect(rect:x() + x, rect:y(), width, rect:h()), "rounded", "")
    local label = name == active and ("\27[1;97m " .. text .. " \27[0m")
                                 or ("\27[2m " .. text .. " \27[0m")
    ui.text_ansi(ui.rect(rect:x() + x + 1, rect:y() + 1, width - 2, 1), label)
    spans[#spans + 1] = { first = x, last = x + width - 1, name = name }
    x = x + width
  end
end

function M.on_pointer(event)
  if not M.visible() or event.kind ~= "down" or event.button ~= "left"
      or not event.inside then return false end
  for _, span in ipairs(spans) do
    if event.x >= span.first and event.x <= span.last then
      if span.name ~= session.active() then
        local ok, switched = pcall(session.switch, span.name)
        if not ok or not switched then
          print("[session_buttons] Could not switch to " .. span.name .. ".")
        end
      end
      return true
    end
  end
  return false
end

function M.set_enabled(value)
  enabled = value == true
  spans = {}
  ui.dirty()
end

function M.on_load()
  if not (session.active and session.switch) then
    error("session_buttons requires Lera's session.active() and session.switch()")
  end
  if command then
    command_id = command.register({
      name = "/tabs", usage = "/tabs [on|off]", accepts_args = true,
      summary = "Show or hide session buttons",
      handler = function(args)
        local arg = (args or ""):match("^%s*(.-)%s*$"):lower()
        if arg == "" then M.set_enabled(not enabled)
        elseif arg == "on" then M.set_enabled(true)
        elseif arg == "off" then M.set_enabled(false)
        else print("Usage: /tabs [on|off]"); return end
        print("Session buttons " .. (enabled and "on" or "off") .. ".")
      end,
    })
  end
end

function M.on_unload()
  spans = {}
  if command_id then command.unregister(command_id); command_id = nil end
end

return M
