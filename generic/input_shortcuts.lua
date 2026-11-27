-- Command stacking and counted walks through ordinary aliases.
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

local alias_ids = {}
local depth, dispatched, stopped = 0, 0, false
local passthrough

local function stop(reason)
  if not stopped then print("[input_shortcuts] " .. reason) end
  stopped = true
end

-- mud.execute is synchronous. Share limits across stack/walk composition and
-- restore state even if another alias or input filter raises an error.
local function expand(parts, literal)
  if depth == 0 then dispatched, stopped = 0, false end
  if stopped then return end
  if depth == 8 then stop("Expansion exceeds nesting depth 8."); return end
  if dispatched + #parts > limit then
    stop("Expansion exceeds " .. limit .. " commands.")
    return
  end
  depth = depth + 1
  local previous = passthrough
  local ok, err = pcall(function()
    for _, part in ipairs(parts) do
      if stopped then break end
      if dispatched == limit then
        stop("Expansion exceeds " .. limit .. " commands.")
        break
      end
      dispatched = dispatched + 1
      -- A literal separator must not be split again on our own execute call.
      passthrough = (literal or part:find(settings.separator, 1, true)) and part or nil
      mud.execute(part)
      passthrough = previous
    end
  end)
  passthrough = previous
  depth = depth - 1
  if not ok then error(err, 0) end
end

local function pass(text)
  if passthrough == text then
    passthrough = nil
    return true
  end
end

local function stack_alias(text)
  if pass(text) then return text end
  local parts = {}
  for _, part in ipairs(split(text, settings.separator) or {text}) do
    if part ~= "" then parts[#parts + 1] = part end
  end
  expand(parts, text:sub(1, 1) == settings.separator)
end

local function walk_alias(text)
  if pass(text) then return text end
  local path = parse_walk(text)
  -- Alias callbacks cannot fall through to later aliases.
  if not path then return text end
  local parts = {}
  local remaining = depth > 0 and limit - dispatched or limit
  for _, step in ipairs(path) do
    if not step.pause_forward and step.forward ~= "" then
      if #parts + step.count > remaining then
        if depth == 0 then stopped = false end
        stop("Expansion exceeds " .. limit .. " commands.")
        return
      end
      for _ = 1, step.count do
        parts[#parts + 1] = directions[step.forward] or step.forward
      end
    end
  end
  expand(parts)
end

local function escape_regex(text)
  return (text:gsub("([^%w])", "\\%1"))
end

local function unregister_aliases()
  for _, id in ipairs(alias_ids) do alias.remove(id) end
  alias_ids = {}
end

local function register_aliases()
  unregister_aliases()
  local function register(name, pattern, callback)
    local id, err = alias.add(pattern, callback)
    if id then
      alias_ids[#alias_ids + 1] = id
    else
      print("[input_shortcuts] could not register " .. name .. " alias: " .. tostring(err))
    end
  end
  -- Stack first, including when a walk contains the separator.
  if settings.stack then
    register("stack",
      "^[\\s\\S]*" .. escape_regex(settings.separator) .. "[\\s\\S]*\\z", stack_alias)
  end
  if settings.walk then
    -- Only complete sequences of counted directions or parenthesized steps.
    -- Horizontal whitespace matches normalize(); no arbitrary route names.
    register("walk", "^" .. escape_regex(settings.prefix)
      .. "[ \\t]*(?:[0-9]*[ \\t]*(?:[nsewud]|\\([^()\\r\\n]*\\))[ \\t]*)+\\z", walk_alias)
  end
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
  register_aliases()
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
  register_aliases()
end

function M.on_unload()
  unregister_aliases()
  if command_id then command.unregister(command_id); command_id = nil end
end

return M
