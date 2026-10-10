-- Explicit user actions only. No timer plays, discards, buys or resumes a game.
local protocol = require("protocol")
local M = {}
local selected, selected_snapshot = {}, nil
local pending = false

local function state()
  local s = protocol.get()
  if s and selected_snapshot ~= s.snapshot then
    selected, selected_snapshot, pending = {}, s.snapshot, false
  end
  return s
end

local function has(rows, id)
  for _, row in ipairs(rows or {}) do if row.id == id then return row end end
end

local function safe_id(id)
  return type(id) == "string" and #id == 29 and id:match("^i%-%d+$")
end

function M.reset() selected, selected_snapshot, pending = {}, nil, false end
function M.on_publish()
  selected, pending = {}, false
  local s = protocol.get()
  selected_snapshot = s and s.snapshot
end

function M.busy()
  local s = state()
  return not s or s.session == "" or pending or s.state.processing == 1 or s.state.paused == 1
end

function M.selected(id) state(); return selected[id] == true end

function M.selection()
  local s = state()
  local ids = {}
  if s then
    for _, card in ipairs(s.cards.hand) do
      if selected[card.id] then ids[#ids + 1] = card.id end
    end
  end
  return ids
end

function M.toggle(id)
  local s = state()
  if M.busy() then return false end
  local card = has(s.cards.hand, id)
  if not card or card.selectable ~= 1 then return false end
  if not selected[id] and #M.selection() >= 5 then return false end
  selected[id] = not selected[id]
  return true
end

local function targets(s, action, index)
  if action == "play" or action == "discard" then return s.cards.hand end
  if action == "buy_card" then return s.offers.cards end
  if action == "open_pack" then return s.offers.boosters end
  if action == "redeem_voucher" then return s.offers.vouchers end
  if action == "reorder_jokers" then return s.cards.jokers end
  if action == "use_consumable" then return index == 1 and s.cards.consumables or s.cards.hand end
  if action == "pick_pack" then return index == 1 and s.offers.pack or s.cards.hand end
  if action == "sell_card" then
    local rows = {}
    for _, row in ipairs(s.cards.jokers) do rows[#rows + 1] = row end
    for _, row in ipairs(s.cards.consumables) do rows[#rows + 1] = row end
    return rows
  end
end

local actions = { play = true, discard = true, buy_card = true, sell_card = true,
  reorder_jokers = true, use_consumable = true, open_pack = true, pick_pack = true,
  redeem_voucher = true, skip_pack = true, cash_out = true, reroll = true, start_blind = true }

-- This validates command safety and displayed identity, not all Balatro gameplay legality.
-- The native owner/revision/intent preflight remains authoritative for every request.
function M.command(action, ids)
  local s = state()
  if M.busy() or not actions[action] or type(ids) ~= "table" then return nil end
  if not s.session:match("^[a-zA-Z0-9_-]+$") or s.revision ~= math.floor(s.revision) then return nil end
  if action == "start_blind" then
    if #ids ~= 1 or ids[1] ~= "bl_small" then return nil end
  elseif action == "cash_out" or action == "reroll" or action == "skip_pack" then
    if #ids ~= 0 then return nil end
  else
    if #ids < 1 or #ids > 1024 then return nil end
    local seen = {}
    for index, id in ipairs(ids) do
      if not safe_id(id) or seen[id] or not has(targets(s, action, index), id) then return nil end
      seen[id] = true
    end
  end
  return string.format("balatro do %s %d %s%s", s.session, s.revision, action,
    #ids > 0 and " " .. table.concat(ids, " ") or "")
end

function M.send(action, ids)
  local command = M.command(action, ids)
  if not command then return false end
  mud.send(command)
  pending = true
  return true
end

-- Refresh is always an explicit user click; it sends no gameplay action.
function M.refresh()
  pending = false
  mud.send("balatro status")
end

return M
