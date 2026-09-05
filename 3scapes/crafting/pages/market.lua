-- Market page: reagent barter offers, the coin-priced material order book,
-- token-to-token exchanges, and live auctions (Craft.Market).
local pagelib = require("pagelib")
local state = require("state")

local C = pagelib.C
local M = {}

local function countdown(closes)
  local left = (closes or 0) - lera.time()
  if left <= 0 then return "ended", C.dim end
  local m = math.floor(left / 60)
  local s = left % 60
  local color = left <= 30 and C.yellow or C.white
  if m > 0 then return string.format("%dm%02ds", m, s), color end
  return string.format("%ds", s), color
end

local function token_label(tid)
  local realm, lvl = tostring(tid or ""):match("^(%a+)_(%d+)$")
  if not realm then return tostring(tid or "?") end
  local rc = pagelib.REALM_COLOR[realm:sub(1, 1):upper() .. realm:sub(2)] or C.white
  return rc .. realm:sub(1, 1):upper() .. realm:sub(2) .. pagelib.RESET .. " T" .. lvl
end

local function mat_name(o)
  return pagelib.title(o.material_name or tostring(o.mat or o.material or "?"))
end

local function zebra_rows(add, cols)
  add(cols[1])
  local i
  for i = 2, #cols do add(pagelib.zebra(i - 2) .. cols[i] .. pagelib.RESET) end
end

function M.lines(width)
  width = width or 80
  local s = state.get()
  local lines = {}
  local function add(text) lines[#lines + 1] = text end

  add(pagelib.header(width, "Reagent Offers (token-priced barter)"))
  if #s.orders == 0 then
    add(pagelib.trunc(C.dim .. "  none posted" .. pagelib.RESET, width))
  else
    local rows = {}
    for _, o in ipairs(s.orders) do
      rows[#rows + 1] = { tostring(o.id or "?"), o.seller or "?", mat_name(o),
        tostring(o.qty or 0), tostring(o.price or 0) }
    end
    zebra_rows(add, pagelib.columns(width, {
      { title = "ID", w = 5 }, { title = "Seller", w = 14 },
      { title = "Material", w = "*" }, { title = "Qty", w = 6 }, { title = "Price", w = 8 },
    }, rows))
  end

  add("")
  add(pagelib.header(width, "Material Orders (coins)"))
  if #s.material_orders == 0 then
    add(pagelib.trunc(C.dim .. "  none posted" .. pagelib.RESET, width))
  else
    local rows, colors = {}, {}
    for _, o in ipairs(s.material_orders) do
      rows[#rows + 1] = { tostring(o.id or "?"), o.type or "?", o.player or "?",
        mat_name(o), tostring(o.qty or 0), tostring(o.price or 0) }
      colors[#colors + 1] = (o.type == "sell") and C.green or C.yellow
    end
    local cols = pagelib.columns(width, {
      { title = "ID", w = 5 }, { title = "Type", w = 5 }, { title = "Player", w = 14 },
      { title = "Material", w = "*" }, { title = "Qty", w = 6 }, { title = "Price", w = 8 },
    }, rows)
    add(cols[1])
    local i
    for i = 2, #cols do add(colors[i - 1] .. cols[i] .. pagelib.RESET) end
  end

  add("")
  add(pagelib.header(width, "Token Exchanges"))
  if #s.exchanges == 0 then
    add(pagelib.trunc(C.dim .. "  none posted" .. pagelib.RESET, width))
  else
    local i
    for i, e in ipairs(s.exchanges) do
      add(pagelib.zebra(i - 1) .. pagelib.trunc(string.format("  #%d %s: %dx %s -> %dx %s",
        e.id or 0, e.player or "?", e.give_qty or 0, token_label(e.give_token),
        e.want_qty or 0, token_label(e.want_token)), width) .. pagelib.RESET)
    end
  end

  add("")
  add(pagelib.header(width, "Auctions"))
  if #s.auctions == 0 then
    add(pagelib.trunc(C.dim .. "  none active" .. pagelib.RESET, width))
  else
    for _, a in ipairs(s.auctions) do
      local bid = (a.high_bid or 0) > 0 and tostring(a.high_bid) or "---"
      local ctext, ccolor = countdown(a.closes)
      add(pagelib.trunc(string.format("  #%d %s%s%s  %sx %s  bid %s%s%s  reserve %s  %s%s%s",
        a.id or 0, C.white, a.seller or "?", pagelib.RESET,
        tostring(a.qty or 0), mat_name(a),
        C.yellow, bid, pagelib.RESET, tostring(a.reserve or 0),
        ccolor, ctext, pagelib.RESET), width))
    end
  end

  return lines
end

return M
