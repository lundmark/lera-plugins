-- Craft.Market order books and auctions.
local pagelib = require("pagelib")
local state = require("state")

local C, RESET = pagelib.C, pagelib.RESET
local M = {}

local function countdown(closes)
  local left = (closes or 0) - lera.time()
  if left <= 0 then return C.dim .. "ended" .. RESET end
  local color = left <= 30 and C.yellow or C.white
  local minutes = math.floor(left / 60)
  local label = minutes > 0 and string.format("%dm %02ds", minutes, left % 60) or (left .. "s")
  return color .. label .. RESET
end

local function token_label(tid)
  local realm, level = tostring(tid or ""):match("^(%a+)_(%d+)$")
  if not realm then return tostring(tid or "?") end
  realm = pagelib.title(realm)
  return (pagelib.REALM_COLOR[realm] or C.white) .. realm .. RESET .. " T" .. level
end

local function mat_name(o)
  return pagelib.title(o.material_name or tostring(o.mat or o.material or "?"))
end

local function recipe_name(o)
  return pagelib.title(o.recipe_name or o.recipe or "?")
end

local function order_type(o)
  return (o.type == "sell" and C.bright_green or C.bright_cyan)
    .. pagelib.title(o.type or "?") .. RESET
end

local function number(value)
  return pagelib.fmt_num(tonumber(value))
end

local function bid(o)
  return (tonumber(o.high_bid) or 0) > 0 and number(o.high_bid) or "-"
end

function M.lines(width)
  width = pagelib.page_width(width)
  local s = state.get()
  local lines = {}
  local function book(title, records, spec, row, empty)
    lines[#lines + 1] = pagelib.header(width, title)
    if #records == 0 then
      lines[#lines + 1] = pagelib.trunc(C.dim .. empty .. RESET, width)
    else
      local rows = {}
      for _, record in ipairs(records) do rows[#rows + 1] = row(record) end
      pagelib.add_table(lines, width, spec, rows)
    end
    lines[#lines + 1] = ""
  end

  book("Reagent Offers", s.orders, {
    { title = "ID", w = 7 }, { title = "Reagent", w = "*" }, { title = "Seller", w = 16 },
    { title = "Qty", w = 8 }, { title = "Price", w = 12 },
  }, function(o)
    return { o.id, mat_name(o), o.seller, number(o.qty), number(o.price) }
  end, "No offers posted.")

  book("Material Orders", s.material_orders, {
    { title = "ID", w = 7 }, { title = "Material", w = "*" }, { title = "Side", w = 6 },
    { title = "Player", w = 16 }, { title = "Qty", w = 8 }, { title = "Coins", w = 12 },
  }, function(o)
    return { o.id, mat_name(o), order_type(o), o.player, number(o.qty), number(o.price) }
  end, "No orders posted.")

  book("Token Exchanges", s.exchanges, {
    { title = "ID", w = 7 }, { title = "Player", w = "*" },
    { title = "Offering", w = 24 }, { title = "Asking", w = 24 },
  }, function(o)
    return { o.id, o.player, number(o.give_qty) .. "x " .. token_label(o.give_token),
      number(o.want_qty) .. "x " .. token_label(o.want_token) }
  end, "No exchanges posted.")

  book("Auctions", s.auctions, {
    { title = "ID", w = 7 }, { title = "Material", w = "*" }, { title = "Seller", w = 14 },
    { title = "Qty", w = 7 }, { title = "High bid", w = 12 },
    { title = "Reserve", w = 12 }, { title = "Closes", w = 11 },
  }, function(o)
    return { o.id, mat_name(o), o.seller, number(o.qty), bid(o), number(o.reserve), countdown(o.closes) }
  end, "No active auctions.")

  book("Recipe Scroll Orders", s.scroll_orders, {
    { title = "ID", w = 7 }, { title = "Recipe", w = "*" }, { title = "Side", w = 6 },
    { title = "Player", w = 16 }, { title = "Coins", w = 12 },
  }, function(o)
    return { o.id, recipe_name(o), order_type(o), o.player, number(o.price) }
  end, "No orders posted.")

  book("Recipe Scroll Auctions", s.scroll_auctions, {
    { title = "ID", w = 7 }, { title = "Recipe", w = "*" }, { title = "Seller", w = 16 },
    { title = "High bid", w = 12 }, { title = "Reserve", w = 12 }, { title = "Closes", w = 11 },
  }, function(o)
    return { o.id, recipe_name(o), o.seller, bid(o), number(o.reserve), countdown(o.closes) }
  end, "No active auctions.")

  if #s.scroll_outbox > 0 then
    lines[#lines + 1] = pagelib.header(width, "Scrolls Ready to Collect")
    lines[#lines + 1] = pagelib.trunc(C.bright_green .. #s.scroll_outbox .. " waiting" .. RESET
      .. "  cmarket scroll collect", width)
    for _, name in ipairs(s.scroll_outbox) do
      lines[#lines + 1] = pagelib.trunc("  " .. pagelib.title(tostring(name)), width)
    end
  end
  return lines
end

return M
