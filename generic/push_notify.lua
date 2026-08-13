-- Push Notification Plugin for Lera
-- Pure consumer for push notifications via Pushover. Producers (other
-- plugins) call M.notify(channel, text); this plugin owns credentials,
-- per-channel enable/priority, the grace period and rate limiting. It never
-- looks at MUD output itself.
--
-- Producer API:
--   pushn = plugin.get("push_notify")          -- in your plugin's on_setup
--   pushn.register_channel("tells", { priority = 1 })
--   pushn.notify("tells", "Bob tells you: hi") -- true if a push was sent
--
-- Channels default to disabled; the user opts in per channel with
-- 'pushn toggle <channel>'. A notify() on an unknown channel auto-registers
-- it (disabled) so it shows up in 'pushn toggle'.
--
-- Commands:
--   pushn                          - Show status and help
--   pushn set <token> <userkey>    - Set Pushover credentials
--   pushn notify <message>         - Send a test notification
--   pushn enable / disable         - Turn notifications on/off
--   pushn toggle                   - List channels and their states
--   pushn toggle <channel>         - Toggle a channel on/off
--   pushn grace <seconds>          - Set activity grace period (0 to disable)

local M = {}
M.name = "push_notify"
M.priority = 50

-- Default configuration
local config = {
  -- Channels, registered by producer plugins: name -> { enabled, priority }
  channels = {},

  -- Event notifications
  events = {
    disconnect = true,
  },

  -- Rate limit in seconds
  rate_limit = 60,

  -- Grace period: don't send if user was active within this many seconds
  grace_period = 60,

  -- Default notification sound
  sound = "pushover",
}

-- Internal state
local credentials_set = false
local alias_ids = {}
local last_user_input = 0  -- Timestamp of last keyboard input
local saved_channels = {}  -- Persisted channel state, applied on registration

-- Helper: check if user has been active recently
local function is_user_active()
  if config.grace_period <= 0 then
    return false
  end
  if last_user_input == 0 then
    return false
  end
  return (lera.time() - last_user_input) < config.grace_period
end

-- Register a channel, applying any persisted enabled/priority state. Safe to
-- call for an already-registered channel (state is preserved).
local function register(name, opts)
  local channel = config.channels[name]
  if not channel then
    channel = {
      enabled = false,
      priority = (opts and opts.priority) or 0,
    }
    local saved = saved_channels[name]
    if saved then
      if saved.enabled ~= nil then channel.enabled = saved.enabled end
      if saved.priority then channel.priority = saved.priority end
    end
    config.channels[name] = channel
  elseif opts and opts.priority and not saved_channels[name] then
    channel.priority = opts.priority
  end
  return channel
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local function show_help()
  print("[pushn] Commands:")
  print("  pushn                        - Show status and help")
  print("  pushn set <token> <userkey>  - Set Pushover credentials")
  print("  pushn notify <message>       - Send a test notification")
  print("  pushn enable                 - Enable notifications")
  print("  pushn disable                - Disable notifications")
  print("  pushn toggle                 - List channels and their states")
  print("  pushn toggle <channel>       - Toggle channel (tells, gossip, etc.)")
  print("  pushn grace <seconds>        - Set activity grace period (0=off)")
end

local function list_channels()
  print("[pushn] Channels:")
  local any = false
  for name, channel in pairs(config.channels) do
    print("  " .. name .. ": " .. (channel.enabled and "ON" or "off"))
    any = true
  end
  if not any then
    print("  (none registered yet)")
  end
end

local function show_status()
  print("[pushn] Status:")
  print("  Credentials: " .. (credentials_set and "set" or "NOT SET"))
  print("  Enabled: " .. (push.enabled() and "yes" or "no"))
  print("  Rate limit: " .. config.rate_limit .. "s")
  print("  Grace period: " .. (config.grace_period > 0 and (config.grace_period .. "s") or "off"))
  if is_user_active() then
    local idle = math.floor(lera.time() - last_user_input)
    print("  User active: yes (idle " .. idle .. "s)")
  else
    print("  User active: no")
  end
  print("  Pending: " .. push.pending())
  list_channels()
  print("  Disconnect alerts: " .. (config.events.disconnect and "on" or "off"))
end

local function toggle_channel(name)
  if config.channels[name] then
    config.channels[name].enabled = not config.channels[name].enabled
    local status = config.channels[name].enabled and "enabled" or "disabled"
    print("[pushn] Channel '" .. name .. "' " .. status)
  else
    print("[pushn] Unknown channel: " .. name)
    list_channels()
  end
end

local function register_aliases()
  -- "pushn" - show status and help
  alias_ids[#alias_ids + 1] = alias.add("^pushn\\s*$", function()
    show_status()
    print("")
    show_help()
    return nil
  end)

  -- "pushn help" - show help
  alias_ids[#alias_ids + 1] = alias.add("^pushn\\s+help$", function()
    show_help()
    return nil
  end)

  -- "pushn status" - show status
  alias_ids[#alias_ids + 1] = alias.add("^pushn\\s+status$", function()
    show_status()
    return nil
  end)

  -- "pushn set <token> <userkey>" - set credentials
  alias_ids[#alias_ids + 1] = alias.add("^pushn\\s+set\\s+(\\S+)\\s+(\\S+)$", function(_, token, userkey)
    M.set_credentials(token, userkey)
    return nil
  end)

  -- "pushn notify <message>" - send notification
  alias_ids[#alias_ids + 1] = alias.add("^pushn\\s+notify\\s+(.+)$", function(_, message)
    if not credentials_set then
      print("[pushn] No credentials set. Use: pushn set <token> <userkey>")
      return nil
    end
    push.send(message, {
      title = "Lera",
      priority = 0,
      callback = function(success, err)
        if not success then
          print("[pushn] Failed: " .. (err or "unknown error"))
        end
      end
    })
    return nil
  end)

  -- "pushn enable" - enable notifications
  alias_ids[#alias_ids + 1] = alias.add("^pushn\\s+enable$", function()
    push.enable()
    print("[pushn] Notifications enabled")
    return nil
  end)

  -- "pushn disable" - disable notifications
  alias_ids[#alias_ids + 1] = alias.add("^pushn\\s+disable$", function()
    push.disable()
    print("[pushn] Notifications disabled")
    return nil
  end)

  -- "pushn toggle" - list channels and their states
  alias_ids[#alias_ids + 1] = alias.add("^pushn\\s+toggle\\s*$", function()
    list_channels()
    return nil
  end)

  -- "pushn toggle <channel>" - toggle channel
  alias_ids[#alias_ids + 1] = alias.add("^pushn\\s+toggle\\s+(\\S+)$", function(_, channel)
    toggle_channel(channel)
    return nil
  end)

  -- "pushn grace <seconds>" - set grace period
  alias_ids[#alias_ids + 1] = alias.add("^pushn\\s+grace\\s+(\\d+)$", function(_, seconds)
    config.grace_period = tonumber(seconds)
    if config.grace_period > 0 then
      print("[pushn] Grace period set to " .. config.grace_period .. "s")
    else
      print("[pushn] Grace period disabled")
    end
    return nil
  end)
end

local function unregister_aliases()
  for _, id in ipairs(alias_ids) do
    if id then alias.remove(id) end
  end
  alias_ids = {}
end

--------------------------------------------------------------------------------
-- Plugin Hooks
--------------------------------------------------------------------------------

function M.on_load()
  -- Load saved config
  store.load()
  local data = store.get() or {}
  if data.config then
    -- Channel state is applied lazily as producers register; remember it here.
    if data.config.channels then
      saved_channels = data.config.channels
    end
    if data.config.events then
      config.events = data.config.events
    end
    if data.config.rate_limit then
      config.rate_limit = data.config.rate_limit
    end
    if data.config.grace_period then
      config.grace_period = data.config.grace_period
    end
    if data.config.sound then
      config.sound = data.config.sound
    end
  end

  -- Load credentials if saved
  if data.app_token and data.user_key then
    push.init(data.app_token, data.user_key)
    push.set_rate_limit(config.rate_limit)
    credentials_set = true
    print("[pushn] Loaded saved credentials")
  end

  -- Register command aliases
  register_aliases()

  print("[pushn] Loaded - type 'pushn' for commands")
end

function M.on_unload()
  -- Unregister command aliases
  unregister_aliases()

  -- Save config. Persist saved state for channels no producer registered
  -- this session, so a temporarily unloaded producer doesn't lose its toggle.
  local channels = {}
  for name, saved in pairs(saved_channels) do
    channels[name] = { enabled = saved.enabled, priority = saved.priority }
  end
  for name, channel in pairs(config.channels) do
    channels[name] = { enabled = channel.enabled, priority = channel.priority }
  end

  local data = store.get() or {}
  data.config = {
    channels = channels,
    events = config.events,
    rate_limit = config.rate_limit,
    grace_period = config.grace_period,
    sound = config.sound,
  }
  store.set(data)
  store.save()
end

function M.on_input(text)
  -- Track user activity for grace period
  last_user_input = lera.time()
  return text
end

function M.on_disconnect()
  if not credentials_set or not config.events.disconnect then
    return
  end

  -- High priority for disconnect alerts (bypasses quiet hours)
  push.alert("MUD connection lost", "DISCONNECTED")
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Declare a channel. opts = { priority = -2..2 }. Persisted user state
-- (enabled, priority) wins over opts for a channel the user has toggled.
function M.register_channel(name, opts)
  register(name, opts)
end

-- Send a push notification on a channel. Returns true if a push was sent.
-- An unknown channel is auto-registered disabled so it appears in
-- 'pushn toggle' for the user to opt in.
function M.notify(channel, text)
  local ch = register(channel)
  if not credentials_set or not push.enabled() then
    return false
  end
  if not ch.enabled then
    return false
  end
  if is_user_active() then
    return false
  end
  if push.is_rate_limited(channel) then
    return false
  end

  local msg = text
  if #msg > 200 then
    msg = msg:sub(1, 197) .. "..."
  end

  push.send(msg, {
    title = channel:upper(),
    priority = ch.priority or 0,
    sound = config.sound,
    callback = function(success, err)
      if not success then
        print("[pushn] Failed to send: " .. (err or "unknown error"))
      end
    end
  })

  push.record_send(channel)
  return true
end

function M.set_credentials(app_token, user_key)
  push.init(app_token, user_key)
  push.set_rate_limit(config.rate_limit)
  credentials_set = true

  -- Save credentials
  local data = store.get() or {}
  data.app_token = app_token
  data.user_key = user_key
  store.set(data)
  store.save()

  print("[pushn] Credentials saved")
end

function M.clear_credentials()
  credentials_set = false
  local data = store.get() or {}
  data.app_token = nil
  data.user_key = nil
  store.set(data)
  store.save()
  print("[pushn] Credentials cleared")
end

function M.enable_channel(name, enabled)
  local channel = register(name)
  channel.enabled = enabled
  print("[pushn] " .. name .. " notifications " .. (enabled and "enabled" or "disabled"))
end

function M.set_rate_limit(seconds)
  config.rate_limit = seconds
  push.set_rate_limit(seconds)
  print("[pushn] Rate limit set to " .. seconds .. " seconds")
end

function M.set_grace_period(seconds)
  config.grace_period = seconds
  if seconds > 0 then
    print("[pushn] Grace period set to " .. seconds .. " seconds")
  else
    print("[pushn] Grace period disabled")
  end
end

function M.set_sound(sound)
  config.sound = sound
  print("[pushn] Sound set to: " .. sound)
end

function M.enable_disconnect(enabled)
  config.events.disconnect = enabled
  print("[pushn] Disconnect alerts " .. (enabled and "enabled" or "disabled"))
end

function M.test()
  if not credentials_set then
    print("[pushn] No credentials set. Use: pushn set <token> <userkey>")
    return
  end

  push.send("Test notification from Lera", {
    title = "Test",
    priority = 0,
    callback = function(success, err)
      if not success then
        print("[pushn] Test failed: " .. (err or "unknown error"))
      end
    end
  })
end

function M.status()
  show_status()
end

return M
