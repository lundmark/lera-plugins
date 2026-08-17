-- MXP Links Plugin for Lera
--
-- MXP <send>/<a> links are parsed and recorded by the client, but there is no
-- way to click output text, so on their own they are unreachable. This gathers
-- the links on recent output lines and opens a popup menu to fire one.
--
-- Keybinding is deliberately not done here: bind.* is not in the plugin
-- sandbox, and keys are composition-level. Bind M.open() from your profile:
--
--   local links = plugin.load("mxp_links")
--   bind.add("ctrl+l", function() links.open() end)

local M = {}
M.name = "mxp_links"
M.version = "1.0"

local menu = require("menu")

-- require("command") is optional: a profile that never required 'commands' has
-- no registry, and the plugin still works through M.open().
local command
do
  local ok, mod = pcall(require, "command")
  if ok then command = mod end
end

local config = {
  scan_lines = 40,    -- output lines back to gather links from
  max_items = 60,     -- cap on menu rows
  show_value = true,  -- append the command when it differs from the label
  title = "Links",
}

local command_id
local link_handler_id

-- collect() only sees links still in scrollback, so a running total is tracked
-- separately for status output.
local stats = { total = 0 }

--------------------------------------------------------------------------------
-- Collecting
--------------------------------------------------------------------------------

-- Newest line first, so the current room's exits sort above older ones.
-- Duplicates are collapsed: every room repeats "north", and a menu of twenty
-- identical rows is worse than one.
function M.collect()
  local found, seen = {}, {}
  for n = 1, config.scan_lines do
    local links = mxp.links(n)
    if links then
      for _, link in ipairs(links) do
        local kind = tostring(link.kind or "send")
        local text = tostring(link.text or "")
        local value = tostring(link.value or "")
        local key = kind .. "\0" .. text .. "\0" .. value
        if not seen[key] and #value > 0 then
          seen[key] = true
          found[#found + 1] = {
            kind = kind,
            text = text,
            value = value,
            hint = tostring(link.hint or ""),
            prompt = link.prompt and true or false,
            line = tonumber(link.line) or 0,
          }
          if #found >= config.max_items then return found end
        end
      end
    end
  end
  return found
end

function M.count()
  return #M.collect()
end

-- Links seen this session, including duplicates and lines since trimmed.
function M.stats()
  return { total = stats.total }
end

function M.reset_stats()
  stats.total = 0
end

--------------------------------------------------------------------------------
-- Firing
--------------------------------------------------------------------------------

-- A URL cannot be opened (no browser integration), so it is printed, and copied
-- when a clipboard is available -- best effort, never fatal.
local function fire_url(link)
  buffer.color_print(nil, 3, "[link] ", nil, nil, link.value)
  local ok = pcall(function()
    local wrote = clipboard.write(link.value)
    if wrote then buffer.color_print(nil, 8, "[link] copied to clipboard") end
  end)
  return ok
end

function M.fire(link)
  if type(link) ~= "table" or type(link.value) ~= "string" then return false end
  if link.kind == "url" then
    fire_url(link)
  elseif link.prompt then
    -- <send ... prompt> means "put it in the input line", not "send it".
    input.set_text(link.value)
  else
    mud.send(link.value)
  end
  return true
end

-- Fire the nth collected link (1 = newest). Returns true when one was fired.
function M.fire_index(index)
  local links = M.collect()
  local link = links[tonumber(index) or 0]
  if not link then return false end
  return M.fire(link)
end

--------------------------------------------------------------------------------
-- Picker
--------------------------------------------------------------------------------

local function item_label(link)
  local label = link.text
  if #label == 0 then label = link.value end
  if config.show_value and link.value ~= link.text then
    label = label .. "  \194\187 " .. link.value
  end
  if link.prompt then label = label .. "  [prompt]" end
  return label
end

function M.open()
  local links = M.collect()
  if #links == 0 then
    if mxp.enabled() then
      buffer.color_print(nil, 3, "[links] ", nil, nil,
                         "no MXP links on the last " .. config.scan_lines .. " lines")
    else
      buffer.color_print(nil, 3, "[links] ", nil, nil,
                         "MXP is not active on this connection")
    end
    return false
  end

  local items = {}
  for i, link in ipairs(links) do
    items[i] = {
      label = item_label(link),
      value = i,
      -- Searchable on the command and hint too, not just the visible label.
      search = link.text .. " " .. link.value .. " " .. link.hint,
    }
  end

  menu.open({
    items = items,
    title = config.title,
    on_select = function(index)
      local link = links[tonumber(index) or 0]
      if link then M.fire(link) end
    end,
  })
  return true
end

--------------------------------------------------------------------------------
-- Hooks
--------------------------------------------------------------------------------

function M.on_load()
  store.load()
  local data = store.get()
  if data then
    if tonumber(data.scan_lines) then config.scan_lines = tonumber(data.scan_lines) end
    if tonumber(data.max_items) then config.max_items = tonumber(data.max_items) end
    if data.show_value ~= nil then config.show_value = data.show_value end
    if type(data.title) == "string" then config.title = data.title end
  end

  -- Counting happens here rather than in collect() so the total covers links
  -- whose lines have already aged out of scrollback.
  link_handler_id = mxp.on_link(function()
    stats.total = stats.total + 1
  end)

  if not command then return end
  -- "/link" with no argument opens the picker; "/link 3" fires directly, which
  -- is what a script or a repeated choice wants.
  local id, err = command.register({
    name = "/link",
    usage = "/link [n]",
    summary = "Open the MXP link picker, or fire link n",
    description = "Collects MXP <send>/<a> links from recent output. With no "
      .. "argument, opens a searchable popup to choose one. With a number, "
      .. "fires that link directly (1 = newest).",
    accepts_args = true,
    handler = function(args)
      local n = tonumber(args and args:match("^%s*(%d+)%s*$"))
      if n then
        if not M.fire_index(n) then
          buffer.color_print(nil, 1, "[links] no link " .. n)
        end
        return
      end
      M.open()
    end,
  })
  if id then
    command_id = id
  else
    print("[mxp_links] command registration failed: " .. tostring(err))
  end
end

function M.on_unload()
  store.set({
    scan_lines = config.scan_lines,
    max_items = config.max_items,
    show_value = config.show_value,
    title = config.title,
  })
  store.save()
  if link_handler_id then
    pcall(mxp.remove_link_handler, link_handler_id)
    link_handler_id = nil
  end
  -- The loader removes a plugin's commands on unload; unregistering here keeps
  -- a manual reload from colliding with its own leftover record.
  if command and command_id then
    pcall(command.unregister, command_id)
    command_id = nil
  end
end

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

function M.configure(opts)
  if type(opts) ~= "table" then return M.get_config() end
  if tonumber(opts.scan_lines) then config.scan_lines = math.max(1, tonumber(opts.scan_lines)) end
  if tonumber(opts.max_items) then config.max_items = math.max(1, tonumber(opts.max_items)) end
  if opts.show_value ~= nil then config.show_value = opts.show_value and true or false end
  if type(opts.title) == "string" then config.title = opts.title end
  return M.get_config()
end

function M.get_config()
  return {
    scan_lines = config.scan_lines,
    max_items = config.max_items,
    show_value = config.show_value,
    title = config.title,
  }
end

return M
