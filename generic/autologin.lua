-- Autologin plugin for Lera
-- Automatically enters username and password when prompted
-- Credentials are stored persistently using the store API
local M = {}

M.name = "autologin"
M.version = "2.0"

local username = nil
local password = nil
local logged_in = false
local on_login_hook = nil

-- Show help
local function show_help()
  print("[autologin] Commands:")
  print("  /autologin set <user> <pass>  - Set credentials")
  print("  /autologin show               - Show current username")
  print("  /autologin clear              - Remove stored credentials")
end

-- Load stored credentials
function M.on_load()
  store.load()
  local data = store.get()
  if data then
    username = data.username
    password = data.password
  end

  -- Single alias catches all /autologin commands
  alias.add("^/autologin(.*)$", function(_, rest)
    -- rest is everything after "/autologin" (from capture group)
    rest = rest:match("^%s*(.*)$") or ""  -- trim leading whitespace

    -- Parse subcommand and arguments
    local cmd, args = rest:match("^(%S+)%s*(.*)$")

    if not cmd or cmd == "" then
      show_help()
    elseif cmd == "set" then
      local user, pass = args:match("^(%S+)%s+(.+)$")
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

    return nil
  end)
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
