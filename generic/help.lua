-- Help command plugin for Lera
local M = {}

M.name = "help"
M.version = "1.0"

-- Command registry: other plugins can register commands here
M.commands = {
  help = {
    usage = "/help [topic]",
    desc = "Show help. Topics: commands, <module>, <module>.<function>"
  },
  quit = {
    usage = "/quit",
    desc = "Exit Lera"
  },
  plugins = {
    usage = "/plugins",
    desc = "List loaded plugins"
  },
  load = {
    usage = "/load <plugin>",
    desc = "Load a plugin"
  },
  unload = {
    usage = "/unload <plugin>",
    desc = "Unload a plugin"
  },
  chat = {
    usage = "/chat <subcommand>",
    desc = "Chat monitor commands: types, toggle, gag, ungag, clear"
  },
}

-- Allow other plugins to register commands
function M.register(name, usage, desc)
  M.commands[name] = { usage = usage, desc = desc }
end

local function show_commands()
  print("Commands:")
  for name, cmd in pairs(M.commands) do
    print("  " .. cmd.usage)
    print("    " .. cmd.desc)
  end
  print("")
  print("For API docs: /help <module> or /help <module>.<function>")
  print("Modules: " .. table.concat(docs.modules(), ", "))
end

local function show_module(name)
  local mod = docs.module(name)
  if not mod then
    print("Unknown module: " .. name)
    print("Available: " .. table.concat(docs.modules(), ", "))
    return
  end

  print(name .. " - " .. mod.desc)
  print("")
  for _, fn in ipairs(mod.functions) do
    print("  " .. fn.usage)
    print("    " .. fn.desc)
    print("")
  end
end

local function show_function(modname, fnname)
  local mod = docs.module(modname)
  if not mod then
    print("Unknown module: " .. modname)
    return
  end

  for _, fn in ipairs(mod.functions) do
    if fn.name == fnname then
      print(fn.usage)
      print("  " .. fn.desc)
      return
    end
  end

  print("Unknown function: " .. modname .. "." .. fnname)
end

local function show_help(arg)
  if not arg or arg == "" then
    print("Lera Help")
    print("=========")
    print("")
    print("Usage: /help <topic>")
    print("")
    print("Topics:")
    print("  commands     - Show slash commands")
    print("  <module>     - Show module API (e.g., /help mud)")
    print("  <mod>.<fn>   - Show function help (e.g., /help trigger.add)")
    print("  hooks        - Show plugin hook functions")
    print("")
    print("Modules: " .. table.concat(docs.modules(), ", "))
    return
  end

  -- Check for command help
  if arg == "commands" then
    show_commands()
    return
  end

  -- Check for module.function format
  local modname, fnname = arg:match("^(%w+)%.(%w+)$")
  if modname and fnname then
    show_function(modname, fnname)
    return
  end

  -- Check for command
  local cmd = M.commands[arg]
  if cmd then
    print(cmd.usage)
    print("  " .. cmd.desc)
    return
  end

  -- Check for module
  local mod = docs.module(arg)
  if mod then
    show_module(arg)
    return
  end

  -- Try search
  local results = docs.search(arg)
  if #results > 0 then
    print("Search results for '" .. arg .. "':")
    for _, r in ipairs(results) do
      print("  " .. r.module .. "." .. r.name)
      print("    " .. r.usage)
    end
  else
    print("No help found for: " .. arg)
    print("Try: /help commands, /help <module>, or /help hooks")
  end
end

local function list_plugins()
  local plugins = plugin.list()
  print("Loaded plugins:")
  for _, p in ipairs(plugins) do
    print("  " .. p.name .. " v" .. (p.version or "?"))
  end
end

local function load_plugin(name)
  if not name or name == "" then
    print("Usage: /load <plugin>")
    return
  end
  local p, err = plugin.load(name)
  if p then
    print("Loaded: " .. name)
  else
    print("Failed to load: " .. (err or "unknown error"))
  end
end

local function unload_plugin(name)
  if not name or name == "" then
    print("Usage: /unload <plugin>")
    return
  end
  if plugin.unload(name) then
    print("Unloaded: " .. name)
  else
    print("Failed to unload: " .. name)
  end
end

local function chat_command(args)
  -- Get chat_monitor plugin
  local chat = plugin.get("chat_monitor")
  if not chat then
    print("Chat monitor plugin not loaded")
    return
  end

  -- Parse subcommand
  local parts = {}
  for word in args:gmatch("%S+") do
    table.insert(parts, word)
  end

  local subcmd = parts[1] or ""

  if subcmd == "" or subcmd == "help" then
    print("Chat monitor commands:")
    print("  /chat types           - List all chat line types")
    print("  /chat toggle <type>   - Toggle a line type on/off")
    print("  /chat enable <type>   - Enable a line type")
    print("  /chat disable <type>  - Disable a line type")
    print("  /chat color <type> <color> - Set color for a type")
    print("  /chat gag <type> <pattern> - Add a gag pattern")
    print("  /chat ungag <type> <pattern> - Remove a gag pattern")
    print("  /chat gags <type>     - List gags for a type")
    print("  /chat clear           - Clear all chat messages")
    print("")
    print("Colors: black, red, green, yellow, blue, magenta, cyan, white")
    print("        bright_black, bright_red, bright_green, etc.")
  elseif subcmd == "types" then
    local types = chat.list_types()
    print("Chat line types:")
    for _, t in ipairs(types) do
      local status = t.enabled and "ON" or "OFF"
      local gags = t.gag_count > 0 and (" [" .. t.gag_count .. " gags]") or ""
      print(string.format("  %-15s %-12s %s (%s)%s", t.id, t.color, status, t.label, gags))
    end
  elseif subcmd == "toggle" then
    local type_id = parts[2]
    if not type_id then
      print("Usage: /chat toggle <type>")
      return
    end
    local enabled = chat.toggle(type_id)
    if enabled ~= nil then
      print(type_id .. " is now " .. (enabled and "enabled" or "disabled"))
    else
      print("Unknown type: " .. type_id)
    end
  elseif subcmd == "enable" then
    local type_id = parts[2]
    if not type_id then
      print("Usage: /chat enable <type>")
      return
    end
    if chat.enable(type_id) then
      print(type_id .. " enabled")
    else
      print("Unknown type: " .. type_id)
    end
  elseif subcmd == "disable" then
    local type_id = parts[2]
    if not type_id then
      print("Usage: /chat disable <type>")
      return
    end
    if chat.disable(type_id) then
      print(type_id .. " disabled")
    else
      print("Unknown type: " .. type_id)
    end
  elseif subcmd == "color" then
    local type_id = parts[2]
    local color = parts[3]
    if not type_id or not color then
      print("Usage: /chat color <type> <color>")
      return
    end
    if chat.set_color(type_id, color) then
      print(type_id .. " color set to " .. color)
    else
      print("Failed - unknown type or invalid color")
    end
  elseif subcmd == "gag" then
    local type_id = parts[2]
    local pattern = parts[3]
    if not type_id or not pattern then
      print("Usage: /chat gag <type> <pattern>")
      return
    end
    if chat.add_gag(type_id, pattern) then
      print("Added gag '" .. pattern .. "' to " .. type_id)
    else
      print("Unknown type: " .. type_id)
    end
  elseif subcmd == "ungag" then
    local type_id = parts[2]
    local pattern = parts[3]
    if not type_id or not pattern then
      print("Usage: /chat ungag <type> <pattern>")
      return
    end
    if chat.remove_gag(type_id, pattern) then
      print("Removed gag '" .. pattern .. "' from " .. type_id)
    else
      print("Gag not found")
    end
  elseif subcmd == "gags" then
    local type_id = parts[2]
    if not type_id then
      print("Usage: /chat gags <type>")
      return
    end
    local gags = chat.list_gags(type_id)
    if #gags == 0 then
      print("No gags for " .. type_id)
    else
      print("Gags for " .. type_id .. ":")
      for i, g in ipairs(gags) do
        print("  " .. i .. ". " .. g)
      end
    end
  elseif subcmd == "clear" then
    chat.clear()
    print("Chat cleared")
  else
    print("Unknown subcommand: " .. subcmd)
    print("Type /chat help for usage")
  end
end

local alias_ids = {}

function M.on_load()
  -- Register command aliases
  alias_ids[#alias_ids + 1] = alias.add("^/help\\s*(.*)$", function(_, arg)
    show_help(arg)
    return nil
  end)

  alias_ids[#alias_ids + 1] = alias.add("^/quit$", function()
    lera.quit()
    return nil
  end)

  alias_ids[#alias_ids + 1] = alias.add("^/plugins$", function()
    list_plugins()
    return nil
  end)

  alias_ids[#alias_ids + 1] = alias.add("^/load\\s+(.+)$", function(_, name)
    load_plugin(name)
    return nil
  end)

  alias_ids[#alias_ids + 1] = alias.add("^/unload\\s+(.+)$", function(_, name)
    unload_plugin(name)
    return nil
  end)

  alias_ids[#alias_ids + 1] = alias.add("^/chat\\s*(.*)$", function(_, args)
    chat_command(args)
    return nil
  end)

  print("[help] Loaded - type /help for commands")
end

function M.on_unload()
  for _, id in ipairs(alias_ids) do
    alias.remove(id)
  end
  alias_ids = {}
end

return M
