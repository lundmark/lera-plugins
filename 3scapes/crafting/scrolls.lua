-- Local scroll preference and drop notice handling shared by Automation and /craft.
local M = {}
local auto_read = false
local scroll_notice

function M.load()
  store.load()
  local saved = store.get()
  auto_read = type(saved) == "table" and saved.auto_read == true
end

function M.auto_read() return auto_read end

function M.reset()
  scroll_notice = nil
end

function M.set_auto_read(enabled)
  auto_read = enabled
  M.reset()
  if not (store.set({ auto_read = enabled }) and store.save()) then
    buffer.color_print(nil, nil, "[Crafting] Could not save the auto-read setting for next time.")
  end
end

local DROP_START = "Something glints among the remains --"
local DROP_LEAD = "Something glints"
local DROP_END = " recipe scroll! You tuck it away; it is bound to you."
local DROP_LIMIT = 200

-- The server can wrap the notice through the recipe name or the delivery
-- confirmation. Wait for the complete notice before sending a targeted read.
function M.on_line(raw)
  if not scroll_notice and not raw:find(DROP_LEAD, 1, true) then return raw end

  local plain = raw:gsub("\27%[[0-9;?]*[ -/]*[@-~]", ""):match("^%s*(.-)%s*$")
  if plain:sub(1, #DROP_LEAD) == DROP_LEAD then
    scroll_notice = plain
  elseif scroll_notice and plain ~= "" then
    scroll_notice = scroll_notice .. " " .. plain
  else
    scroll_notice = nil
  end

  if not scroll_notice then return raw end
  if #scroll_notice > DROP_LIMIT then
    scroll_notice = nil
    return raw
  end
  if scroll_notice:sub(-#DROP_END) ~= DROP_END then return raw end

  local name
  if scroll_notice:sub(1, #DROP_START) == DROP_START then
    name = scroll_notice:sub(#DROP_START + 1, -#DROP_END - 1):match("^ an? (.+)$")
  end
  scroll_notice = nil
  if name and name:match("^[%w][%w .'&(),%-]*$") then
    local command = "read " .. name .. " scroll"
    if not auto_read or not mud.send(command) then
      buffer.color_print(nil, "FFFFFF", "[Crafting] Recipe scroll dropped: " .. name
        .. " (" .. command .. ")")
    end
  end
  return raw
end

return M
