-- Jobs page: building construction, masterwork queue, typed production
-- queues, and finished items waiting to be collected (Craft.Jobs). Every
-- timer here is an absolute `due` epoch from the server; the countdown is
-- computed fresh on every render (init.lua's 1s timer keeps the popup
-- redrawing while it's open, so this reads live even with no new GMCP frame).
local pagelib = require("pagelib")
local state = require("state")

local C = pagelib.C
local M = {}

local function countdown_color(left)
  if left <= 0 then return C.bright_green end
  if left <= 60 then return C.yellow end
  return C.white
end

local function countdown(due)
  local left = (due or 0) - lera.time()
  if left <= 0 then return "ready", countdown_color(left) end
  local h = math.floor(left / 3600)
  local m = math.floor((left % 3600) / 60)
  local sec = left % 60
  local text
  if h > 0 then text = string.format("%dh %dm", h, m)
  elseif m > 0 then text = string.format("%dm %ds", m, sec)
  else text = string.format("%ds", sec) end
  return text, countdown_color(left)
end

local function due_line(add, width, prefix, name, due)
  local text, color = countdown(due)
  add(pagelib.trunc(string.format("  %s%s%s  %s(%s)%s",
    C.white, prefix .. name, pagelib.RESET, color, text, pagelib.RESET), width))
end

function M.lines(width)
  width = width or 80
  local s = state.get()
  local lines = {}
  local function add(text) lines[#lines + 1] = text end

  if #s.builds > 0 then
    local sorted = {}
    for _, b in ipairs(s.builds) do sorted[#sorted + 1] = b end
    table.sort(sorted, function(a, b) return (a.building or "") < (b.building or "") end)
    add(pagelib.header(width, "Under Construction"))
    for _, b in ipairs(sorted) do
      due_line(add, width, "", string.format("%s -> T%d", b.building or "?", b.tier or 0), b.due)
    end
    add("")
  end

  if #s.pending_builds > 0 then
    local sorted = {}
    for _, b in ipairs(s.pending_builds) do sorted[#sorted + 1] = b end
    table.sort(sorted, function(a, b) return (a.building or "") < (b.building or "") end)
    add(pagelib.header(width, "Awaiting Funding"))
    for _, b in ipairs(sorted) do
      local need_desc
      if b.global == 1 then
        need_desc = pagelib.fmt_num(b.need or 0) .. " tokens from each realm"
      else
        need_desc = pagelib.fmt_num(b.need or 0) .. " " .. (b.token or "") .. " " .. (b.realm or "") .. " tokens"
      end
      add(pagelib.trunc(string.format("  %s%s -> T%d%s  %sneed %s%s",
        C.white, b.building or "?", b.tier or 0, pagelib.RESET,
        C.dim, need_desc, pagelib.RESET), width))
    end
    add(pagelib.trunc(C.dim .. "  Starts automatically once funded." .. pagelib.RESET, width))
    add("")
  end

  if #s.masterwork > 0 then
    add(pagelib.header(width, "Masterwork Queue"))
    for _, mw in ipairs(s.masterwork) do
      local label = (mw.name or "item") .. (mw.target and mw.target > 0
        and (" (level " .. tostring(mw.target) .. ")") or "")
      due_line(add, width, "", label, mw.due)
    end
    add("")
  end

  local q_sorted = {}
  for _, q in ipairs(s.queues) do q_sorted[#q_sorted + 1] = q end
  table.sort(q_sorted, function(a, b) return (a.building or "") < (b.building or "") end)
  add(pagelib.header(width, "Production Queues"))
  add(pagelib.kv(width, "Total queued:", s.queue_total .. " / " .. s.queue_cap, C.bright_cyan))
  if #q_sorted == 0 then
    add(pagelib.trunc(C.dim .. "  No queued production." .. pagelib.RESET, width))
  end
  for _, q in ipairs(q_sorted) do
    add(pagelib.trunc(C.bright_cyan .. (q.building or "?") .. pagelib.RESET
      .. C.dim .. "  (" .. (q.depth or 0) .. "/" .. (q.cap or 0) .. " queued)" .. pagelib.RESET,
      width))
    if q.current_id and q.current_id ~= "" then
      due_line(add, width, "> ", pagelib.title(q.current_name or q.current_id), q.current_due)
    elseif q.stalled == 1 then
      add(pagelib.trunc("  " .. C.bright_red .. "(stalled -- missing materials)"
        .. pagelib.RESET, width))
    else
      add(pagelib.trunc("  " .. C.dim .. "(waiting for you to be online to start)"
        .. pagelib.RESET, width))
    end
    if q.items and q.items ~= "" then
      add(pagelib.trunc("    " .. C.dim .. "+ " .. pagelib.RESET .. q.items, width))
    end
  end

  if #s.ready > 0 then
    add("")
    add(pagelib.header(width, "Ready to Collect (ccollect)"))
    for _, item in ipairs(s.ready) do
      local expiry = ""
      if item.expires and item.expires > 0 then
        -- An outbox item with no time left is already pruned server-side
        -- before a frame could ever report it, so "expires" here is always
        -- still in the future -- no "ready"/zero case to special-case.
        local text, ecolor = countdown(item.expires)
        expiry = C.dim .. "  expires in " .. ecolor .. text .. pagelib.RESET
      end
      add(pagelib.trunc("  " .. C.bright_green .. (item.name or "item") .. pagelib.RESET
        .. C.dim .. "  quality " .. tostring(item.quality or 0) .. pagelib.RESET
        .. expiry, width))
    end
  end

  return lines
end

return M
