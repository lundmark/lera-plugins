-- Autologin plugin for Lera
-- Automatically enters username and password when prompted
-- Credentials are stored persistently using the store API
local M = {}

M.name = "autologin"
M.version = "2.0"

-- require("command") is optional: a profile that never required 'commands' has
-- no registry, and the automatic login still works.
local command
do
  local ok, mod = pcall(require, "command")
  if ok then command = mod end
end

local username = nil
local password = nil
local logged_in = false
local on_login_hook = nil
local command_id = nil

-- Show help
local function show_help()
  print("[autologin] Commands:")
  print("  /autologin set <user> <pass>  - Set credentials")
  print("  /autologin show               - Show current username")
  print("  /autologin clear              - Remove stored credentials")
end

-- The registry hands the handler everything after the command name.
local function dispatch(args)
  local cmd, rest = tostring(args or ""):match("^%s*(%S*)%s*(.-)%s*$")

  if cmd == "" then
    show_help()
  elseif cmd == "set" then
    local user, pass = rest:match("^(%S+)%s+(.+)$")
    if user and pass then
      M.set_credentials(user, pass)
      print("[autologin] Credentials saved for: " .. user)
    else
      print("[autologin] Usage: /autologin set <username> <password>")
    end
  elseif cmd == "show" then
    if username then
      print("[autologin] Username: " .. username)
      print("[autologin] Password: " .. string.rep("*", password and #password or 0))
    else
      print("[autologin] No credentials configured")
      print("[autologin] Use: /autologin set <username> <password>")
    end
  elseif cmd == "clear" then
    username = nil
    password = nil
    store.set(nil)
    store.save()
    print("[autologin] Credentials cleared")
  else
    print("[autologin] Unknown command: " .. cmd)
    show_help()
  end
end

-- Load stored credentials
function M.on_load()
  store.load()
  local data = store.get()
  if data then
    username = data.username
    password = data.password
  end

  if not command then return end
  local id, err = command.register({
    name = "/autologin",
    usage = "/autologin [set <user> <pass>|show|clear]",
    summary = "Automatic login on connect",
    description = "Stores a username and password and sends them when the MUD "
      .. "connection is established. 'show' masks the password.",
    accepts_args = true,
    handler = dispatch,
  })
  if id then
    command_id = id
  else
    print("[autologin] command registration failed: " .. tostring(err))
  end
end

function M.on_unload()
  -- The loader drops a plugin's commands on unload; unregistering here keeps a
  -- manual reload from colliding with its own leftover record.
  if command and command_id then
    pcall(command.unregister, command_id)
    command_id = nil
  end
end

function M.on_connect()
  if username and password then
    mud.send(username)
    mud.send(password)
    logged_in = true
    if on_login_hook then
      on_login_hook()
    end
  else
    print("[autologin] No credentials configured - use /autologin set <user> <pass>")
  end
end

function M.on_disconnect()
  logged_in = false
end

-- Set and persist credentials
function M.set_credentials(user, pass)
  username = user
  password = pass
  store.set({ username = user, password = pass })
  store.save()
end

function M.is_logged_in()
  return logged_in
end

function M.has_credentials()
  return username ~= nil and password ~= nil
end

function M.on_login(func)
  on_login_hook = func
end

return M
