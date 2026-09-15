-- Out-of-combat notifications for 3scapes. Char.Combat owns the combat state;
-- push_notify owns channel opt-in, credentials, activity grace and rate limits.
local M = { name = "combat_notify", version = "1.0" }
local CHANNEL = "out_of_combat"
local DEFAULT_DELAY = 300
local delay = DEFAULT_DELAY
local in_combat, idle_since, notified = nil, nil, false
local timer_id, handler_id, command_id
local pushn

local command
do
  local ok, mod = pcall(require, "command")
  if ok then command = mod end
end

local function reset()
  in_combat, idle_since, notified = nil, nil, false
end

local function ready()
  return mud.connected() and gmcp.enabled()
end

local function get_push_notify()
  local current = plugin.get("push_notify")
  if current ~= pushn then
    pushn = current
    if pushn and pushn.register_channel then
      pushn.register_channel(CHANNEL)
    end
  end
  return pushn
end

local function on_combat(_, data)
  if not ready() then reset(); return end
  if type(data) ~= "table" or type(data.attacker) ~= "string" then return end
  if data.attacker ~= "" then
    in_combat, idle_since, notified = true, nil, false
  elseif in_combat ~= false then
    in_combat, idle_since, notified = false, lera.time(), false
  end
end

local function tick()
  -- Discover late/reloaded consumers even before a combat snapshot arrives,
  -- so the channel is visible in /pushn toggle as soon as both plugins load.
  local sink = get_push_notify()
  if not ready() then reset(); return end
  if idle_since == nil or notified then return end
  local elapsed = math.floor(lera.time() - idle_since)
  if elapsed < delay or not sink or not sink.notify then return end
  -- A suppressed or rejected submission stays due while this idle period is
  -- current. Combat/connection resets discard it, so there is no event backlog.
  notified = sink.notify(CHANNEL,
    string.format("You have been out of combat for %d seconds.", elapsed)) == true
end

local function valid_delay(value)
  return type(value) == "number" and value >= 1 and value <= 86400
    and value == math.floor(value)
end

local function show_help()
  print("[combatnotify] Usage: /combatnotify [status|delay <seconds>|help]")
  print("  /combatnotify delay <seconds> - Set delay (1-86400; default 300)")
  print("  /pushn toggle out_of_combat  - Toggle alerts (default off)")
  print("  Sends once per idle period; resets when combat resumes or you disconnect.")
  print("  Push credentials, global enable, activity grace and rate limits use /pushn.")
end

local function show_status()
  if not ready() then reset() end
  print(string.format("[combatnotify] Delay: %ds", delay))
  if in_combat == nil then
    print("  Waiting for a fresh Char.Combat state while connected.")
  elseif in_combat then
    print("  In combat.")
  else
    local elapsed = math.max(0, math.floor(lera.time() - idle_since))
    local status = notified and "notification submitted"
      or (elapsed >= delay and "due; waiting for push settings to allow submission"
        or string.format("due in %ds", delay - elapsed))
    print(string.format("  Out of combat for %ds; %s.", elapsed, status))
  end
  print("  Channel: out_of_combat (check /pushn toggle for its enabled state)")
end

local function dispatch(args)
  local sub, rest = tostring(args or ""):match("^%s*(%S*)%s*(.-)%s*$")
  sub = sub:lower()
  if sub == "" or sub == "status" then
    show_status()
    if sub == "" then show_help() end
  elseif sub == "delay" then
    local seconds = tonumber(rest:match("^%d+$"))
    if not valid_delay(seconds) then show_help(); return end
    delay = seconds
    local data = store.get() or {}
    data.delay = delay
    store.set(data)
    store.save()
    print(string.format("[combatnotify] Delay set to %ds", delay))
  else
    show_help()
  end
end

function M.on_load()
  reset()
  store.load()
  local data = store.get() or {}
  delay = valid_delay(data.delay) and data.delay or DEFAULT_DELAY
  handler_id = gmcp.on("Char.Combat", on_combat)
  timer_id = timer.every(1000, tick)
  if command then
    local err
    command_id, err = command.register({
      name = "/combatnotify",
      usage = "/combatnotify [status|delay <seconds>|help]",
      summary = "Push notification after time out of combat",
      description = "Waits for Char.Combat idle state, then sends once after the "
        .. "configured delay (default 300 seconds). Enable with /pushn toggle "
        .. "out_of_combat. Global push enable, activity grace and rate limits apply.",
      accepts_args = true,
      handler = dispatch,
    })
    if not command_id then
      print("[combatnotify] command registration failed: " .. tostring(err))
    end
  end
  print("[combatnotify] Loaded - type /combatnotify for status and help")
end

function M.on_setup() get_push_notify() end
function M.on_connect() reset() end
function M.on_disconnect() reset() end

function M.on_unload()
  if timer_id then timer.cancel(timer_id); timer_id = nil end
  if handler_id then gmcp.remove(handler_id); handler_id = nil end
  if command_id then command.unregister(command_id); command_id = nil end
  pushn = nil
  reset()
end

return M
