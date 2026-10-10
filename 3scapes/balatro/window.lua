-- Local pointer targets belong to the exact snapshot rendered. Remote views never overwrite them.
local protocol = require("protocol")
local controller = require("controller")
local M = {}
local page, mode, offset, max_offset = "hand", "png", 0, 0
local hits, images = {}, {}
local change_mode

local function clean(value)
  return tostring(value or ""):gsub("[%c]", "")
end

function M.page() return page end
function M.mode() return mode end
function M.on_mode(fn) change_mode = fn end
function M.set_mode(value)
  if value ~= "png" and value ~= "ascii" then return false end
  mode = value
  if change_mode then change_mode(value) end
  ui.dirty()
  return true
end
function M.set_page(value)
  if value ~= "hand" and value ~= "shop" and value ~= "profile" then return false end
  page, offset = value, 0
  ui.dirty()
  return true
end
function M.scroll(delta)
  offset = math.max(0, math.min(max_offset, offset + delta))
  ui.dirty()
end
function M.scroll_to_bottom() offset = max_offset; ui.dirty() end
function M.following_tail() return false end
function M.reset() hits, images, offset = {}, {}, 0 end

local function title(card)
  if card.hidden == 1 then return "Face-down" end
  if card.kind ~= "Playing" then return clean(card.name) end
  local ranks = { [11] = "J", [12] = "Q", [13] = "K", [14] = "A" }
  return (ranks[card.rank] or tostring(card.rank or "?")) .. " " .. clean(card.suit)
end

local function draw_image(rect, card)
  if mode ~= "png" or not lera.display or lera.display() ~= "gui"
    or type(ui.image_load) ~= "function" or type(ui.image) ~= "function" then return false end
  local key = card.art
  if type(key) ~= "string" or not key:match("^[a-z]+/[a-zA-Z0-9_]+$") then return false end
  if images[key] == nil then
    local ok, image = pcall(ui.image_load, "images/" .. key .. ".png")
    images[key] = ok and image or false
  end
  if not images[key] then return false end
  ui.image(rect, images[key], { fit = "contain", filter = "nearest" })
  return true
end

function M.render(rect)
  local w, h = rect:w(), rect:h()
  if w <= 0 or h <= 0 then return end
  local local_pass = not lera.render_pass or lera.render_pass() ~= "remote"
  local s = protocol.get()
  local rendered_hits = {}
  local row = 0
  local function text(x, y, width, value)
    width = math.max(0, math.min(width, w - x))
    if x >= 0 and y >= 0 and y < h and width > 0 then
      ui.text_ansi(ui.rect(rect:x() + x, rect:y() + y, width, 1), clean(value):sub(1, width))
    end
  end
  local function hit(x, y, width, height, fn)
    if x >= 0 and x + width <= w and y >= 0 and y + height <= h then
      rendered_hits[#rendered_hits + 1] = { x = x, y = y, w = width, h = height,
        snapshot = s and s.snapshot, fn = fn }
    end
  end
  local function button(x, y, label, enabled, fn)
    local value = enabled and "[" .. label .. "]" or "(" .. label .. ")"
    text(x, y, #value, value)
    if enabled then hit(x, y, #value, 1, fn) end
    return x + #value + 1
  end
  local x = 0
  for _, tab in ipairs({ { "hand", "Hand" }, { "shop", "Shop" }, { "profile", "Profile" } }) do
    local key = tab[1]
    x = button(x, row, tab[2], true, function() M.set_page(key) end)
  end
  row = row + 1
  x = button(0, row, "PNG", true, function() M.set_mode("png") end)
  x = button(x, row, "ASCII", true, function() M.set_mode("ascii") end)
  x = button(x, row, "Refresh", true, controller.refresh)
  button(x, row, "Help", true, function() mud.send("balatro help") end)
  row = row + 1
  if not s then
    text(0, row, w, "Waiting for the owner-bound Balatro feed.")
    text(0, row + 1, w, "Use Refresh after receiving your Balatro Hand.")
    if local_pass then hits = rendered_hits end
    return
  end
  local v = s.state
  text(0, row, w, "Balatro | " .. clean(v.phase) .. " | $" .. clean(v.money)
    .. " | H " .. clean(v.hands_left) .. " D " .. clean(v.discards_left))
  text(0, row + 1, w, "Score " .. clean(v.score) .. " / " .. clean(v.target))
  text(0, row + 2, w, v.paused == 1 and "Saved work paused. Use balatro resume."
    or controller.busy() and "Waiting for the next saved snapshot."
    or s.info.ready == 0 and "Under construction: wizard test controls." or "Choose your cards.")
  row = row + 3
  local body_top = row
  local logical_row = 0
  local function line(value)
    local cy = body_top + logical_row - offset
    if cy >= body_top then text(0, cy, w, value) end
    logical_row = logical_row + 1
  end
  local function grid(cards)
    local columns = math.max(1, math.floor(w / 11))
    for index, card in ipairs(cards) do
      local cx = ((index - 1) % columns) * 11
      local cy = body_top + logical_row - offset + math.floor((index - 1) / columns) * 7
      local marker = controller.selected(card.id) and "*" or " "
      if cy >= body_top then text(cx, cy, 10, "[" .. marker .. tostring(index) .. "] " .. title(card)) end
      if cy >= body_top and cy + 6 < h then
        local image_rect = ui.rect(rect:x() + cx, rect:y() + cy + 1, math.min(10, w - cx), 5)
        if not draw_image(image_rect, card) then
          text(cx, cy + 1, 10, "+--------+")
          text(cx, cy + 2, 10, "|" .. title(card):sub(1, 8) .. string.rep(" ",
            math.max(0, 8 - #title(card))) .. "|")
          text(cx, cy + 3, 10, "|" .. clean(card.enhancement):sub(1, 8))
          text(cx, cy + 4, 10, "|" .. clean(card.seal):sub(1, 8))
          text(cx, cy + 5, 10, "+--------+")
        end
        if not controller.busy() then
          local id = card.id
          hit(cx, cy, math.min(10, w - cx), 6, function() controller.toggle(id); ui.dirty() end)
        end
      end
    end
    logical_row = logical_row + math.ceil(#cards / columns) * 7
  end
  local function action_row(label, entries, action, with_targets)
    line(label)
    for _, card in ipairs(entries) do
      local id = card.id
      local value = title(card) .. " $" .. clean(action == "sell_card" and card.sell_cost or card.cost)
      local cy = body_top + logical_row - offset
      if cy >= body_top then
        text(0, cy, math.max(1, w - 9), value)
        button(math.max(0, w - 8), cy, action == "sell_card" and "Sell" or "Choose",
          not controller.busy() and not (action == "sell_card" and
            clean(card.stickers):find("eternal", 1, true)), function()
            local ids = { id }
            if with_targets then
              for _, target in ipairs(controller.selection()) do ids[#ids + 1] = target end
            end
            controller.send(action, ids); ui.dirty()
          end)
      end
      logical_row = logical_row + 1
    end
  end
  if page == "profile" then
    line("Deck access")
    for _, deck in ipairs(s.profile.decks or {}) do
      line(clean(deck.id) .. " | " .. (deck.unlocked == 1 and "unlocked" or "locked")
        .. " | stake " .. clean(deck.max_stake))
    end
    line("Collection feed and challenge controls are being prepared.")
  elseif page == "shop" then
    local cy = body_top - offset
    if cy >= body_top then
      x = button(0, cy, "Reroll $" .. clean(s.shop.reroll_cost),
        not controller.busy() and v.phase == "shop", function() controller.send("reroll", {}); ui.dirty() end)
      button(x, cy, "Skip pack", not controller.busy() and v.phase == "pack",
        function() controller.send("skip_pack", {}); ui.dirty() end)
    end
    logical_row = logical_row + 1
    action_row("Shop cards", s.offers.cards, "buy_card")
    action_row("Vouchers", s.offers.vouchers, "redeem_voucher")
    action_row("Booster packs", s.offers.boosters, "open_pack")
    action_row("Pack choices", s.offers.pack, "pick_pack", true)
    if v.phase == "pack" then line("Select target cards below before choosing a packed consumable."); grid(s.cards.hand) end
  else
    local cy = body_top - offset
    if cy >= body_top then
      x = button(0, cy, "Play", not controller.busy() and v.phase == "playing",
        function() controller.send("play", controller.selection()); ui.dirty() end)
      x = button(x, cy, "Discard", not controller.busy() and v.phase == "playing",
        function() controller.send("discard", controller.selection()); ui.dirty() end)
      x = button(x, cy, "Small Blind", not controller.busy() and v.phase == "blind_select",
        function() controller.send("start_blind", { "bl_small" }); ui.dirty() end)
      button(x, cy, "Cash out", not controller.busy() and v.phase == "round_eval",
        function() controller.send("cash_out", {}); ui.dirty() end)
    end
    logical_row = logical_row + 1
    grid(s.cards.hand)
    action_row("Jokers", s.cards.jokers, "sell_card")
    action_row("Consumables: select targets above before using", s.cards.consumables, "use_consumable", true)
  end
  if local_pass then
    hits = rendered_hits
    max_offset = math.max(0, logical_row - (h - body_top))
    offset = math.min(offset, max_offset)
  end
end

function M.on_pointer(event)
  if event.kind ~= "down" or event.button ~= "left" then return false end
  local s = protocol.get()
  for _, hit in ipairs(hits) do
    if event.x >= hit.x and event.x < hit.x + hit.w and event.y >= hit.y and event.y < hit.y + hit.h then
      if hit.snapshot ~= (s and s.snapshot) then return false end
      hit.fn()
      return true
    end
  end
  return false
end

return M
