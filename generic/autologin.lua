-- Autologin plugin for Lera
-- Automatically enters username and password when prompted
local M = {}

M.name = "autologin"
M.version = "1.0"

-- Configuration (user should modify these)
local username = "user"
local password = "pw"
local logged_in = false
local on_login_hook

function M.on_connect()
    mud.send(username)
    mud.send(password)
    logged_in = true
    if on_login_hook then
        on_login_hook()
    end
end

function M.on_disconnect()
    logged_in = false
end

-- Allow configuration from other scripts
function M.set_credentials(user, pass)
  username = user
  password = pass
end

function M.is_logged_in()
  return logged_in
end

function M.on_login(func)
    on_login_hook = func
end

return M
