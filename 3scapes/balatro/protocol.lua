-- Assemble complete wire messages, then complete native snapshot areas before publication.
-- Balatro deliberately sends full logical packets; deltas between area segments are ambiguous.
local M = {}
local packages = { info = true, profile = true, state = true, cards = true,
  shop = true, score = true }
local areas = { cards = { hand = true, jokers = true, consumables = true },
  shop = { cards = true, vouchers = true, boosters = true, pack = true } }
local envelope = { full = true, page = true, pages = true }
local current, stage, wires, handler, callback
local counters

local function integer(n, low, high)
  return type(n) == "number" and n == math.floor(n) and n >= low and n <= high
end

local function scalar(v)
  return type(v) == "string" and #v <= 128
    or type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = copy(v) end
  return out
end

local function array(values, limit)
  if type(values) ~= "table" or #values > limit then return false end
  local count = 0
  for key in pairs(values) do
    if not integer(key, 1, #values) then return false end
    count = count + 1
  end
  return count == #values
end

local function record(row)
  if type(row) ~= "table" then return false end
  local count = 0
  for key, value in pairs(row) do
    if type(key) ~= "string" or not scalar(value) then return false end
    count = count + 1
  end
  return count <= 16
end

local function item(row)
  return record(row) and type(row.id) == "string" and #row.id == 29
    and row.id:match("^i%-%d+$") and type(row.art) == "string"
    and row.art:match("^[a-z]+/[a-zA-Z0-9_]+$")
end

function M.reset()
  current, stage, wires = nil, nil, {}
  counters = { frames = 0, packets = 0, published = 0, rejected = 0 }
end
M.reset()

function M.on_publish(fn) callback = fn end
function M.get() return current end -- Renderers treat this as read-only.
function M.counters() return copy(counters) end

-- TCP preserves frame order. Never apply a page until its full message is assembled.
local function wire_message(sub, data)
  if type(data) ~= "table" or data.full ~= 1 then return nil end
  local page, pages = data.page or 1, data.pages or 1
  if not integer(pages, 1, 8) or not integer(page, 1, pages) then return nil end
  if page == 1 then wires[sub] = { pages = pages, next_page = 1, data = {} } end
  local wire = wires[sub]
  if not wire or wire.pages ~= pages or wire.next_page ~= page then
    wires[sub] = nil
    return nil
  end
  for key, value in pairs(data) do
    if not envelope[key] then
      local previous = wire.data[key]
      if previous ~= nil then
        if type(value) == "table" and array(value, 128) and array(previous, 128) then
          for _, row in ipairs(value) do previous[#previous + 1] = copy(row) end
        elseif value ~= previous then
          wires[sub] = nil
          return nil
        end
      else
        -- Bound supported container depth before copying untrusted decoded tables.
        if type(value) == "table" then
          if not array(value, 128) then wires[sub] = nil; return nil end
          for _, row in ipairs(value) do
            if not scalar(row) and not record(row) then wires[sub] = nil; return nil end
          end
        elseif not scalar(value) then wires[sub] = nil; return nil end
        wire.data[key] = copy(value)
      end
    end
  end
  wire.next_page = page + 1
  if page == pages then wires[sub] = nil; return wire.data end
  return false
end

local function valid_identity(data)
  return data.schema == 1 and type(data.session) == "string" and #data.session <= 128
    and (data.session == "" or data.session:match("^[a-zA-Z0-9_-]+$"))
    and integer(data.revision, 0, 2147483647) and type(data.snapshot) == "string"
    and #data.snapshot <= 128
end

local function valid_meta(sub, data)
  if sub == "info" then return integer(data.ready, 0, 1) end
  if sub == "profile" then
    if not array(data.decks, 32) then return false end
    for _, deck in ipairs(data.decks) do
      if not record(deck) or type(deck.id) ~= "string" or not integer(deck.unlocked, 0, 1)
        or not integer(deck.max_stake, 1, 8) then return false end
    end
    return true
  end
  if sub == "state" then
    if type(data.phase) ~= "string" or not integer(data.processing, 0, 1)
      or not integer(data.paused, 0, 1) or not integer(data.money, -2147483648, 2147483647) then
      return false
    end
    for _, key in ipairs({ "hands_left", "discards_left", "round", "ante", "stake" }) do
      if data[key] ~= nil and not integer(data[key], 0, 2147483647) then return false end
    end
    return true
  end
  if sub == "score" then return type(data.score) == "string" and type(data.target) == "string" end
  if sub == "shop" then return type(data.shop) == "string" and type(data.pack) == "string" end
  return false
end

local function collect_area(sub, data)
  if not areas[sub][data.area] or not integer(data.segments, 1, 171)
    or not integer(data.segment, 1, data.segments) or not integer(data.total, 0, 1024)
    or data.segments ~= math.max(1, math.ceil(data.total / 6))
    or not array(data.items, 6) then return false end
  local expected = math.min(6, math.max(0, data.total - (data.segment - 1) * 6))
  if #data.items ~= expected then return false end
  for _, row in ipairs(data.items) do if not item(row) then return false end end
  local key = sub .. ":" .. data.area
  local area = stage.areas[key]
  if not area then
    area = { segments = data.segments, total = data.total, parts = {} }
    stage.areas[key] = area
  end
  if area.segments ~= data.segments or area.total ~= data.total then return false end
  if area.parts[data.segment] then return false end
  area.parts[data.segment] = copy(data.items)
  return true
end

local function complete()
  for _, name in ipairs({ "info", "profile", "state", "score", "shop" }) do
    if not stage.meta[name] then return false end
  end
  local assembled = {}
  for sub, names in pairs(areas) do
    assembled[sub] = {}
    for name in pairs(names) do
      local area = stage.areas[sub .. ":" .. name]
      if not area then return false end
      local rows, seen = {}, {}
      for index = 1, area.segments do
        if not area.parts[index] then return false end
        for _, row in ipairs(area.parts[index]) do
          if seen[row.id] then return nil end
          rows[#rows + 1], seen[row.id] = row, true
        end
      end
      if #rows ~= area.total then return nil end
      assembled[sub][name] = rows
    end
  end
  return assembled
end

local function packet(sub, data)
  if not valid_identity(data) then return false end
  if current and current.session == data.session and data.revision < current.revision then
    return false
  end
  if stage and stage.session == data.session and data.revision < stage.revision then return false end
  if not stage or stage.snapshot ~= data.snapshot or stage.session ~= data.session then
    stage = { session = data.session, revision = data.revision, snapshot = data.snapshot,
      meta = {}, areas = {} }
  end
  if stage.revision ~= data.revision then return false end
  if data.area ~= nil then
    if not areas[sub] or not collect_area(sub, data) then stage = nil; return false end
  else
    if not valid_meta(sub, data) then return false end
    stage.meta[sub] = copy(data)
  end
  local assembled = complete()
  if assembled == nil then stage = nil; return false end
  if assembled then
    current = { session = stage.session, revision = stage.revision, snapshot = stage.snapshot,
      info = stage.meta.info, profile = stage.meta.profile, state = stage.meta.state,
      score = stage.meta.score, shop = stage.meta.shop,
      cards = assembled.cards, offers = assembled.shop }
    stage = nil
    counters.published = counters.published + 1
    if callback then callback(current) end
  end
  return true
end

function M.ingest(package, data)
  counters.frames = counters.frames + 1
  local sub = type(package) == "string" and package:lower():match("^balatro%.([a-z]+)$")
  if not packages[sub] then counters.rejected = counters.rejected + 1; return false end
  local message = wire_message(sub, data)
  if message == false then return true end -- More wire pages are still needed.
  if not message or not packet(sub, message) then
    counters.rejected = counters.rejected + 1
    return false
  end
  counters.packets = counters.packets + 1
  return true
end

function M.subscribe()
  if handler then return handler end
  handler = gmcp.on("Balatro", M.ingest)
  return handler
end

function M.unsubscribe()
  if handler then gmcp.remove(handler); handler = nil end
end

return M
