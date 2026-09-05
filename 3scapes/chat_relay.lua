-- Relay selected chat_monitor channels between Lera sessions.
local M = { name = "chat_relay", version = "1.0" }

local chat
local routes = {}
local session_name = ""
local command
local menu

local function channel_for(type_id)
  if type(type_id) == "table" then type_id = type_id.id end
  if type(type_id) ~= "string" then return nil end
  if type_id == "tell_in" then return "tells" end
  if type_id == "emote_in" then return "emotes" end
  return type_id:match("^chat_(.+)$")
end

local function type_for(channel)
  if channel == "tells" then return "tell_in" end
  if channel == "emotes" then return "emote_in" end
  return "chat_" .. channel
end

local function available_channels()
  local result, seen = {}, {}
  local types = chat and chat.list_types and chat.list_types() or {}
  for _, type_id in ipairs(types) do
    local channel = channel_for(type_id)
    if channel and not seen[channel] then
      seen[channel] = true
      result[#result + 1] = channel
    end
  end
  if #result == 0 then
    result = { "tells", "emotes", "gossip", "ctell", "vnotify", "vannounce", "ctrade", "soul" }
  end
  table.sort(result)
  return result
end

local function route_enabled(channel, target)
  return routes[channel] and routes[channel][target] == true
end

local function toggle_route(channel, target)
  routes[channel] = routes[channel] or {}
  if route_enabled(channel, target) then
    routes[channel][target] = nil
  else
    routes[channel][target] = true
  end
  if store then store.set({ routes = routes }); store.save() end
end

local function open_menu()
  local items = {}
  local names = session.list()
  for _, target in ipairs(names) do
    if target ~= session_name then
      for _, channel in ipairs(available_channels()) do
        local mark = route_enabled(channel, target) and "ON " or "off"
        items[#items + 1] = {
          label = "[" .. mark .. "] " .. channel .. " -> " .. target,
          value = { channel = channel, target = target },
          search = channel .. " " .. target,
        }
      end
    end
  end
  if #items == 0 then
    print("[chat_relay] No other session is available")
    return false
  end
  return menu.open({
    items = items,
    title = "Chat Relay (click or Enter to toggle)",
    max_height = 12,
    restore_input = "",
    on_select = function(value)
      toggle_route(value.channel, value.target)
      open_menu()
    end,
  })
end

local function handler(args)
  if not args or args:match("^%s*$") then open_menu(); return end
  local parts = {}
  for word in args:gmatch("%S+") do parts[#parts + 1] = word end
  if parts[1] == "list" then
    for channel, targets in pairs(routes) do
      for target in pairs(targets) do print(channel .. " -> " .. target) end
    end
    return
  end
  if (parts[1] == "add" or parts[1] == "remove") and parts[2] and parts[3] then
    routes[parts[2]] = routes[parts[2]] or {}
    routes[parts[2]][parts[3]] = parts[1] == "add" or nil
    if store then store.set({ routes = routes }); store.save() end
    print((parts[1] == "add" and "Relaying " or "Stopped relaying ") .. parts[2] .. " " .. parts[3])
    return
  end
  print("Usage: /chatrelay (open selector) | add <channel> <session> | remove <channel> <session> | list")
end

function M.on_load()
  session_name = session.name()
  menu = require("menu")
  store.load()
  local saved = store.get()
  if saved and type(saved.routes) == "table" then
    routes = {}
    for channel, targets in pairs(saved.routes) do
      if type(channel) == "string" and type(targets) == "table" then
        routes[channel] = {}
        for target, enabled in pairs(targets) do
          if type(target) == "string" and enabled == true then
            routes[channel][target] = true
          end
        end
      end
    end
  end
  chat = plugin.get("chat_monitor")
  if not chat or not chat.on_message or not chat.receive then
    print("[chat_relay] chat_monitor is required")
    return
  end
  session.on_message(function(type_id, sender, text, prefix, remote)
    if remote then
      chat.receive(type_id, sender, text, prefix)
      return
    end
  end)
  chat.on_message(function(type_id, sender, text, opts)
    local channel = channel_for(type_id)
    local targets = channel and routes[channel]
    if not targets then return end
    for target in pairs(targets) do
      local original_prefix = opts and opts.prefix or ""
      -- Keep the original monitor type (tell_in/tell_out, emote_in/emote_out,
      -- or the exact chat_<channel> id). Mapping everything back to tell_in
      -- made relayed messages use the hard-coded incoming-tell colour instead
      -- of the channel/type configuration used by the source message.
      local ok = session.send(target, type_id, sender, text,
        "[" .. session_name .. "] " .. original_prefix)
      if not ok then
        print("[chat_relay] " .. target .. " has no chat relay listener")
      end
    end
  end)
  local ok, mod = pcall(require, "command")
  if ok then
    command = mod
    command.register({name = "/chatrelay", usage = "/chatrelay ...",
      summary = "Relay selected chat channels to another session",
      accepts_args = true, handler = handler})
  end
end

return M
