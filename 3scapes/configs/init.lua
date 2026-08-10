-- 3scapes MUD Configuration for Lera
-- Copy this to your profile directory and customize

--------------------------------------------------------------------------------
-- Plugin Path Setup
--------------------------------------------------------------------------------
-- Add lera-plugins directories to the plugin search path
-- Adjust the path to where you cloned lera-plugins
local plugins_base = os.getenv("HOME") .. "/code/lera-plugins"
plugin.add_path(plugins_base .. "/generic")
plugin.add_path(plugins_base .. "/3scapes")

--------------------------------------------------------------------------------
-- Plugin Loading
--------------------------------------------------------------------------------
local function load_plugin(name)
  local loaded, err = plugin.load(name)
  if err then
    print("[init] Failed to load " .. name .. ": " .. err)
  end
  return loaded
end

-- Core plugins (order matters: roominfo before mapper)
local help         = load_plugin("help")
local autologin    = load_plugin("autologin")
local deadmans     = load_plugin("deadmans")
local input_echo   = load_plugin("input_echo")
local push_notify  = load_plugin("push_notify")

-- 3scapes plugins
local chat         = load_plugin("chat_monitor")
local roominfo     = load_plugin("roominfo")
local mapper       = load_plugin("mapper")
local mapview      = load_plugin("mapview")
local minimap      = load_plugin("minimap")
local speedwalk    = load_plugin("speedwalk")
local autostepper  = load_plugin("autostepper")
local pstats       = load_plugin("player_stats")
local stats_window = load_plugin("stats_window")
local merc         = load_plugin("mercenary")
local kill_trigger = load_plugin("kill_trigger")
local guild_druid  = load_plugin("guild_druid")

--------------------------------------------------------------------------------
-- Autologin Setup
--------------------------------------------------------------------------------
-- Credentials are managed by the autologin plugin itself:
--   /autologin set <user> <pass>  - Set and save credentials
--   /autologin show               - Show current username
--   /autologin clear              - Remove credentials
if autologin then
  autologin.on_login(function()
    mip.enable()
    if guild_druid then guild_druid.setup() end
  end)
end

--------------------------------------------------------------------------------
-- Chat Monitor Configuration
--------------------------------------------------------------------------------
if chat then
  chat.add_chatline("gossip", { color = "bright_cyan", label = "Gossip" })

  chat.configure("tell_in", {
    color = "green",
    label = "Tell",
    prefix = function(cfg, who) return (who or "???") .. " tells you: " end,
  })

  chat.configure("tell_out", {
    color = "green",
    label = "Tell",
    prefix = function(cfg, who) return "You tell " .. (who or "???") .. ": " end,
  })

  chat.configure("emote_in", {
    color = "bright_green",
    label = "Soul",
    prefix = function() return "" end,
  })

  chat.configure("emote_out", {
    color = "bright_green",
    label = "Soul",
    prefix = function() return "" end,
  })
end

--------------------------------------------------------------------------------
-- Connection
--------------------------------------------------------------------------------
local mud_host = "marble.3k.org"
local mud_port = 3200

mud.connect(mud_host, mud_port)

-- Default commands (/connect, /disconnect, /reconnect, /quit, /echo, ...)
-- Ships with lera (scripts/default/commands.lua); no-op if already loaded.
require('commands')

--------------------------------------------------------------------------------
-- Window Manager Layout
--------------------------------------------------------------------------------
local wm = require("wm")

wm.set_layout(wm.layouts.four_panel)
wm.show_status(false)

-- Assign plugins to window slots
if chat then
  wm.assign("chat", chat, {
    title = function() return "Chat (" .. chat.count() .. ")" end
  })
end

if mapview then
  wm.assign("map", mapview, {
    title = function()
      if mapper and mapper.is_mapping() then return "Map [MAPPING]" end
      return "Map"
    end
  })
elseif mapper then
  wm.assign("map", mapper, {
    title = function()
      return mapper.is_mapping() and "Map [MAPPING]" or "Map"
    end
  })
end

if stats_window then
  wm.assign("stats", stats_window, { title = "Stats" })
end

-- Output title shows connection status
wm.set_output_title(function()
  local state = mud.state()
  local host = mud.host() or mud_host
  local port = mud.port() or mud_port
  if state == "connected" then
    return host .. ":" .. port .. " | Lines: " .. buffer.line_count()
  elseif state == "connecting" then
    return "Connecting to " .. host .. ":" .. port .. "..."
  elseif state == "error" then
    return "Connection error"
  else
    return "Disconnected"
  end
end)

wm.init()

--------------------------------------------------------------------------------
-- Keybindings
--------------------------------------------------------------------------------
bind.add("alt+1", function()
  wm.set_layout(wm.layouts.four_panel)
  print("[Layout] Four panel")
end)

bind.add("alt+2", function()
  wm.set_layout(wm.layouts.simple)
  print("[Layout] Simple")
end)

bind.add("alt+3", function()
  wm.set_layout(wm.layouts.map_top)
  print("[Layout] Map top")
end)

-- Scroll the chat pane (ctrl+y up, ctrl+n down; works in GUI, kitty
-- terminals, and legacy TTYs). The output pane keeps PageUp/PageDown, and in
-- GUI mode the mouse wheel scrolls whichever pane is under the cursor.
bind.add("ctrl+y", function() wm.scroll("chat", -5) end)
bind.add("ctrl+n", function() wm.scroll("chat", 5) end)

--------------------------------------------------------------------------------
-- Speedwalks (load area definitions)
--------------------------------------------------------------------------------
local speedwalks_file = plugin.script_dir() .. "/speedwalks.lua"
local f = io.open(speedwalks_file, "r")
if f then
  f:close()
  dofile(speedwalks_file)
end
