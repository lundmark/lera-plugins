local M = { name = "balatro", version = "0.1", priority = 50,
  window_launcher = { label = "Balatro", compact_label = "Cards", order = 45 } }
local protocol = require("protocol")
local controller = require("controller")
local window = require("window")
local command_id, opened = nil, false

local function save_mode(mode)
  if store.set({ mode = mode }) == false or store.save() == false then
    print("[balatro] Could not save the display preference.")
  end
end

function M.open()
  require("wm").popup.open(window, { title = "Balatro", width = 0.85, height = 0.8,
    on_close = function() opened = false end })
  opened = true
end
function M.close()
  if opened and require("wm").popup.is_open() then require("wm").popup.close() end
  opened = false
end
function M.toggle() if opened then M.close() else M.open() end end
function M.is_open() return opened end

local function command(args)
  args = (args or ""):lower()
  if args == "" then M.toggle()
  elseif args == "png" or args == "ascii" then window.set_mode(args); M.open()
  elseif args == "hand" or args == "shop" or args == "profile" then window.set_page(args); M.open()
  elseif args == "refresh" then controller.refresh()
  elseif args == "play" or args == "discard" then controller.send(args, controller.selection())
  elseif args == "new" then mud.send("balatro test new")
  elseif args == "resume" then mud.send("balatro resume")
  elseif args == "help" then mud.send("balatro help")
  elseif args == "status" then
    local c = protocol.counters()
    print(string.format("[balatro] %d frames, %d complete snapshots, %d rejected frames",
      c.frames, c.published, c.rejected))
  else print("/balatro [hand|shop|profile|png|ascii|refresh|play|discard|new|resume|help|status]") end
  ui.dirty()
end

function M.on_load()
  store.load()
  local data = store.get() or {}
  window.set_mode(data.mode == "ascii" and "ascii" or "png")
  window.on_mode(save_mode)
  protocol.on_publish(function() controller.on_publish(); if opened then ui.dirty() end end)
  protocol.subscribe()
  command_id = require("command").register({ name = "/balatro", accepts_args = true,
    usage = "/balatro [hand|shop|profile|png|ascii|refresh|play|discard|new|resume|help|status]",
    summary = "Balatro cards and explicit actions from the private Balatro GMCP feed",
    handler = command })
end

function M.on_disconnect()
  protocol.reset(); controller.reset(); window.reset(); M.close()
end

function M.on_unload()
  save_mode(window.mode())
  if command_id then require("command").unregister(command_id); command_id = nil end
  protocol.unsubscribe(); M.on_disconnect()
end

return M
