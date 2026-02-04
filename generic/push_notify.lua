-- Push Notification Plugin for Lera
-- Sends push notifications via Pushover for tells, channels, and events
--
-- Commands:
--   pushn                          - Show status and help
--   pushn set <token> <userkey>    - Set Pushover credentials
--   pushn notify <message>         - Send a test notification
--   pushn enable / disable         - Turn notifications on/off
--   pushn toggle <channel>         - Toggle a channel on/off
--   pushn filter                   - List keywords
--   pushn filter add <word>        - Add a keyword filter
--   pushn filter remove <word>     - Remove a keyword filter
--   pushn filter toggle <word>     - Toggle a keyword filter
--   pushn grace <seconds>          - Set activity grace period (0 to disable)

local M = {}
M.name = "push_notify"
M.priority = 50

-- Default configuration
local config = {
  -- Channel patterns to watch
  channels = {
    tells = { pattern = "^(.+) tells you", enabled = false, priority = 1 },
    gossip = { pattern = "^%[gossip%]", enabled = false, priority = 0 },
    auction = { pattern = "^%[auction%]", enabled = false, priority = 0 },
    guild = { pattern = "^%[guild%]", enabled = false, priority = 0 },
  },

  -- Custom keywords to watch for (in any line)
  keywords = {},

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

-- Helper: check if any pattern matches
local function check_patterns(line)
  -- Check channel patterns
  for name, channel in pairs(config.channels) do
    if channel.enabled and line:match(channel.pattern) then
      return name, channel.priority or 0
    end
  end

  -- Check keywords
  local lower_line = line:lower()
  for _, kw in ipairs(config.keywords) do
    if lower_line:find(kw:lower(), 1, true) then
      return "keyword:" .. kw, 1
    end
  end

  return nil
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
  print("  pushn toggle <channel>       - Toggle channel (tells, gossip, etc.)")
  print("  pushn filter                 - List keyword filters")
  print("  pushn filter add <word>      - Add keyword filter")
  print("  pushn filter remove <word>   - Remove keyword filter")
  print("  pushn filter toggle <word>   - Toggle keyword filter")
  print("  pushn grace <seconds>        - Set activity grace period (0=off)")
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
  print("  Channels:")
  for name, channel in pairs(config.channels) do
    local status = channel.enabled and "ON" or "off"
    print("    " .. name .. ": " .. status)
  end
  print("  Keywords: " .. (#config.keywords > 0 and table.concat(config.keywords, ", ") or "(none)"))
  print("  Disconnect alerts: " .. (config.events.disconnect and "on" or "off"))
end

local function list_filters()
  if #config.keywords == 0 then
    print("[pushn] No keyword filters set")
  else
    print("[pushn] Keyword filters:")
    for i, kw in ipairs(config.keywords) do
      print("  " .. i .. ". " .. kw)
    end
  end
end

local function add_filter(word)
  -- Check if already exists
  for _, kw in ipairs(config.keywords) do
    if kw:lower() == word:lower() then
      print("[pushn] Keyword already exists: " .. word)
      return
    end
  end
  table.insert(config.keywords, word)
  print("[pushn] Added keyword filter: " .. word)
end

local function remove_filter(word)
  for i, kw in ipairs(config.keywords) do
    if kw:lower() == word:lower() then
      table.remove(config.keywords, i)
      print("[pushn] Removed keyword filter: " .. kw)
      return
    end
  end
  print("[pushn] Keyword not found: " .. word)
end

local function toggle_filter(word)
  for i, kw in ipairs(config.keywords) do
    if kw:lower() == word:lower() then
      table.remove(config.keywords, i)
      print("[pushn] Removed keyword filter: " .. kw)
      return
    end
  end
  table.insert(config.keywords, word)
  print("[pushn] Added keyword filter: " .. word)
end

local function toggle_channel(name)
  if config.channels[name] then
    config.channels[name].enabled = not config.channels[name].enabled
    local status = config.channels[name].enabled and "enabled" or "disabled"
    print("[pushn] Channel '" .. name .. "' " .. status)
  else
    print("[pushn] Unknown channel: " .. name)
    print("[pushn] Available channels: " .. table.concat((function()
      local names = {}
      for n in pairs(config.channels) do names[#names+1] = n end
      return names
    end)(), ", "))
  end
end

local function register_aliases()
  -- "pushn" - show status and help
  alias_ids[#alias_ids + 1] = alias.add("^pushn$", function()
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

  -- "pushn toggle <channel>" - toggle channel
  alias_ids[#alias_ids + 1] = alias.add("^pushn\\s+toggle\\s+(\\S+)$", function(_, channel)
    toggle_channel(channel)
    return nil
  end)

  -- "pushn filter" - list filters
  alias_ids[#alias_ids + 1] = alias.add("^pushn\\s+filter$", function()
    list_filters()
    return nil
  end)

  -- "pushn filter add <word>" - add filter
  alias_ids[#alias_ids + 1] = alias.add("^pushn\\s+filter\\s+add\\s+(\\S+)$", function(_, word)
    add_filter(word)
    return nil
  end)

  -- "pushn filter remove <word>" - remove filter
  alias_ids[#alias_ids + 1] = alias.add("^pushn\\s+filter\\s+remove\\s+(\\S+)$", function(_, word)
    remove_filter(word)
    return nil
  end)

  -- "pushn filter toggle <word>" - toggle filter
  alias_ids[#alias_ids + 1] = alias.add("^pushn\\s+filter\\s+toggle\\s+(\\S+)$", function(_, word)
    toggle_filter(word)
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
    -- Merge saved config
    if data.config.channels then
      for name, channel in pairs(data.config.channels) do
        if config.channels[name] then
          config.channels[name].enabled = channel.enabled
          if channel.priority then
            config.channels[name].priority = channel.priority
          end
        end
      end
    end
    if data.config.keywords then
      config.keywords = data.config.keywords
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

  -- Save config
  local data = store.get() or {}
  data.config = {
    channels = {},
    keywords = config.keywords,
    events = config.events,
    rate_limit = config.rate_limit,
    grace_period = config.grace_period,
    sound = config.sound,
  }
  for name, channel in pairs(config.channels) do
    data.config.channels[name] = {
      enabled = channel.enabled,
      priority = channel.priority,
    }
  end
  store.set(data)
  store.save()
end

function M.on_input(text)
  -- Track user activity for grace period
  last_user_input = lera.time()
  return text
end

function M.on_line(line)
  if not credentials_set or not push.enabled() then
    return line
  end

  -- Skip if user has been active recently
  if is_user_active() then
    return line
  end

  local pattern_id, priority = check_patterns(line)
  if pattern_id then
    -- Check rate limit
    if push.is_rate_limited(pattern_id) then
      return line
    end

    -- Truncate long lines
    local msg = line
    if #msg > 200 then
      msg = msg:sub(1, 197) .. "..."
    end

    -- Send notification
    local title = pattern_id:match("^keyword:") and "Keyword Match" or pattern_id:upper()
    push.send(msg, {
      title = title,
      priority = priority,
      sound = config.sound,
      callback = function(success, err)
        if not success then
          print("[pushn] Failed to send: " .. (err or "unknown error"))
        end
      end
    })

    -- Record for rate limiting
    push.record_send(pattern_id)
  end

  return line
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
  if config.channels[name] then
    config.channels[name].enabled = enabled
    print("[pushn] " .. name .. " notifications " .. (enabled and "enabled" or "disabled"))
  else
    print("[pushn] Unknown channel: " .. name)
  end
end

function M.add_channel(name, pattern, priority)
  config.channels[name] = {
    pattern = pattern,
    enabled = true,
    priority = priority or 0,
  }
  print("[pushn] Added channel: " .. name)
end

function M.remove_channel(name)
  if config.channels[name] then
    config.channels[name] = nil
    print("[pushn] Removed channel: " .. name)
  end
end

function M.add_keyword(word)
  add_filter(word)
end

function M.remove_keyword(word)
  remove_filter(word)
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
