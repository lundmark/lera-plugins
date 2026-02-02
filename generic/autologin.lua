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

-- Load stored credentials
function M.on_load()
  local data = store.get()
  if data then
    username = data.username
    password = data.password
  end

  -- Register alias for /autologin command
  alias.add("^/autologin%s+set%s+(%S+)%s+(.+)$", function(user, pass)
    M.set_credentials(user, pass)
    print("[autologin] Credentials saved for: " .. user)
    return nil
  end)

  alias.add("^/autologin%s+show$", function()
    if username then
      print("[autologin] Username: " .. username)
      print("[autologin] Password: " .. string.rep("*", password and #password or 0))
    else
      print("[autologin] No credentials configured")
      print("[autologin] Use: /autologin set <username> <password>")
    end
    return nil
  end)

  alias.add("^/autologin%s+clear$", function()
    username = nil
    password = nil
    store.set(nil)
    store.save()
    print("[autologin] Credentials cleared")
    return nil
  end)

  alias.add("^/autologin$", function()
    print("[autologin] Commands:")
    print("  /autologin set <user> <pass>  - Set credentials")
    print("  /autologin show               - Show current username")
    print("  /autologin clear              - Remove stored credentials")
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
