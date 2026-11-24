-- Command stacking and counted speedwalks on Lera's pre-alias command hook.
local M = { name = "input_shortcuts", version = "1.0" }
local command = require("command")

local settings = { stack = false, separator = ";", walk = false, prefix = "#" }
local command_id
local limit = 1024
local directions = {
  n = "north", s = "south", e = "east", w = "west", u = "up", d = "down",
  ne = "northeast", nw = "northwest", se = "southeast", sw = "southwest",
}

local function valid_marker(value, max)
  return type(value) == "string" and #value >= 1 and #value <= max
    and not value:find("[^!-~]")
end

-- A leading separator sends the remainder intact. Within a stack, a doubled
-- separator stands for a literal one.
local function split(text, separator)
  if text:sub(1, 1) == separator then return { text:sub(2) } end
  local start, pos = 1, text:find(separator, 1, true)
  if not pos then return nil end

  local parts, fragments = {}, {}
  while pos do
    fragments[#fragments + 1] = text:sub(start, pos - 1)
    if text:sub(pos + 1, pos + 1) == separator then
      fragments[#fragments + 1] = separator
      start = pos + 2
    else
      parts[#parts + 1] = table.concat(fragments)
      fragments = {}
      start = pos + 1
    end
    pos = text:find(separator, start, true)
  end
  fragments[#fragments + 1] = text:sub(start)
  parts[#parts + 1] = table.concat(fragments)
  return parts
end

-- The shared parser already handles directions and parenthesized steps.
-- Allow horizontal spaces between steps while preserving custom commands.
local function normalize(syntax)
  local pieces, start = {}, 1
  for first, last in syntax:gmatch("()%b()()") do
    local outside = syntax:sub(start, first - 1)
    if outside:find("%d[ \t]+%d") then return nil end
    pieces[#pieces + 1] = outside:gsub("[ \t]", "")
    pieces[#pieces + 1] = syntax:sub(first, last - 1)
    start = last
  end
  local outside = syntax:sub(start)
  if outside:find("%d[ \t]+%d") then return nil end
  pieces[#pieces + 1] = outside:gsub("[ \t]", "")
  return table.concat(pieces)
end

local function parse_walk(text)
  local prefix = settings.prefix
  if not settings.walk or text:sub(1, #prefix) ~= prefix or #text == #prefix then return nil end
  local syntax = normalize(text:sub(#prefix + 1))
  if not syntax or syntax == "" then return nil end
  local path = speedwalk.parse(syntax)
  if path and #path > 0 then return path end
end

local function too_many_commands()
  print("[input_shortcuts] Expansion exceeds " .. limit .. " commands.")
  return {}
end

function M.on_command(text)
  local parts = settings.stack and split(text, settings.separator) or nil
  local replacements, changed = {}, parts ~= nil
  for _, part in ipairs(parts or {text}) do
    local path = parse_walk(part)
    if path then
      changed = true
      for _, step in ipairs(path) do
        if not step.pause_forward and step.forward ~= "" then
          if #replacements + step.count > limit then return too_many_commands() end
          local entry = { text = directions[step.forward] or step.forward, skip_aliases = true }
          for _ = 1, step.count do replacements[#replacements + 1] = entry end
        end
      end
    else
      if #replacements == limit then return too_many_commands() end
      replacements[#replacements + 1] = part
    end
  end
  if changed then return replacements end
end

local function configure(args)
  local key, value = (args or ""):match("^%s*(%S+)%s+(%S+)%s*$")
  if (key == "stack" or key == "walk") and (value == "on" or value == "off") then
    settings[key] = value == "on"
  elseif (key == "separator" and valid_marker(value, 1))
      or (key == "prefix" and valid_marker(value, 15)) then
    settings[key] = value
  else
    if (args or ""):find("%S") then
      print("Usage: /input-shortcuts [stack on|off | walk on|off | separator CHAR | prefix TEXT]")
    end
    print(string.format("[input_shortcuts] stack %s (%s), walk %s (%s)",
      settings.stack and "on" or "off", settings.separator,
      settings.walk and "on" or "off", settings.prefix))
    return
  end
  store.set(settings)
  store.save()
end

function M.on_load()
  store.load()
  local saved = store.get()
  if type(saved) == "table" then
    settings.stack = saved.stack == true
    settings.walk = saved.walk == true
    if valid_marker(saved.separator, 1) then settings.separator = saved.separator end
    if valid_marker(saved.prefix, 15) then settings.prefix = saved.prefix end
  end
  command_id = assert(command.register({
    name = "/input-shortcuts", usage = "/input-shortcuts [setting value]", accepts_args = true,
    summary = "Configure command stacking and counted speedwalks", handler = configure,
  }))
end

function M.on_unload()
  if command_id then command.unregister(command_id); command_id = nil end
end

return M
