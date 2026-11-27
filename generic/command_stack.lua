-- Command stacking on an ordinary alias: "look;score" runs two commands.
-- No core hook. A line containing the separator matches the stack alias,
-- which splits it and runs each part through mud.execute, so every part
-- still gets aliases and input filters. Counted speedwalks need nothing
-- here: the speedwalk plugin's "." command already walks ".3n2e".
local M = { name = "command_stack", version = "1.0" }
local command = require("command")

local settings = { enabled = false, separator = ";" }
local LIMIT = 256          -- most commands one stacked line may expand to
local alias_id, command_id
local depth = 0            -- > 0 while this plugin is running a stack's parts

-- A printable, non-space character other than the speedwalk "." prefix.
local function valid_separator(value)
  return type(value) == "string" and #value == 1 and not value:find("[^!-~]")
    and value ~= "."
end

-- PCRE-escape one character.
local function escape(ch)
  return ch:find("%w") and ch or ("\\" .. ch)
end

-- Split a stacked line. A doubled separator is a literal one; a leading
-- separator sends the rest as one command. Returns nil when there is no
-- separator to act on.
function M.split(text, sep)
  if text:sub(1, 1) == sep then return { text:sub(2) } end
  if not text:find(sep, 1, true) then return nil end
  local parts, buf, i = {}, {}, 1
  while i <= #text do
    local ch = text:sub(i, i)
    if ch == sep and text:sub(i + 1, i + 1) == sep then
      buf[#buf + 1] = sep
      i = i + 2
    elseif ch == sep then
      parts[#parts + 1] = table.concat(buf)
      buf, i = {}, i + 1
    else
      buf[#buf + 1] = ch
      i = i + 1
    end
  end
  parts[#parts + 1] = table.concat(buf)
  return parts
end

-- The stack alias. Inside a running stack a part that still holds the
-- separator (a literal one, or what an alias expanded to) is sent as typed
-- instead of being split again.
local function on_stack(line)
  if depth > 0 then return line end
  local parts = M.split(line, settings.separator)
  if not parts then return line end
  if #parts > LIMIT then
    print("[command_stack] A stack may hold up to " .. LIMIT .. " commands; nothing sent.")
    return nil
  end
  depth = depth + 1
  local ok, err = pcall(function()
    for _, part in ipairs(parts) do mud.execute(part) end
  end)
  depth = depth - 1
  if not ok then print("[command_stack] " .. tostring(err)) end
  return nil
end

local function unregister()
  if alias_id then alias.remove(alias_id); alias_id = nil end
end

local function register()
  unregister()
  if settings.enabled then
    alias_id = alias.add("^.*" .. escape(settings.separator) .. ".*$", on_stack)
  end
end

local function show()
  print(string.format("[command_stack] %s, separator %s",
    settings.enabled and "on" or "off", settings.separator))
end

local function configure(args)
  local word, value = (args or ""):match("^%s*(%S*)%s*(%S*)%s*$")
  if word == "on" or word == "off" then
    settings.enabled = word == "on"
  elseif word == "separator" and valid_separator(value) then
    settings.separator = value
  else
    if word ~= "" then print("Usage: /command-stack [on|off | separator CHAR]") end
    show()
    return
  end
  register()
  store.set(settings)
  store.save()
  show()
end

function M.on_load()
  store.load()
  local saved = store.get()
  if type(saved) == "table" then
    settings.enabled = saved.enabled == true
    if valid_separator(saved.separator) then settings.separator = saved.separator end
  end
  register()
  command_id = assert(command.register({
    name = "/command-stack", usage = "/command-stack [on|off | separator CHAR]",
    accepts_args = true, summary = "Run several commands typed on one line",
    handler = configure,
  }))
end

function M.on_unload()
  unregister()
  if command_id then command.unregister(command_id); command_id = nil end
end

return M
