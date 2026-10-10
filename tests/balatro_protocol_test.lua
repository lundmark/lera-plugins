-- Run with: luajit tests/balatro_protocol_test.lua
package.path = "3scapes/balatro/?.lua;" .. package.path
local protocol = require("protocol")
local controller = require("controller")
local checks, sent = 0, {}
mud = { send = function(command) sent[#sent + 1] = command end }

local function expect(condition, label)
  assert(condition, label)
  checks = checks + 1
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for k, v in pairs(value) do result[k] = copy(v) end
  return result
end

local function id(number) return string.format("i-%027d", number) end
local function item(number)
  return { id = id(number), art = "playing/hearts_2", name = "Two", kind = "Playing",
    rank = 2, suit = "Hearts", selectable = 1 }
end

local function packet(sub, extra, revision)
  local data = { schema = 1, session = "fixture-run", revision = revision or 1,
    snapshot = "fixture-run:" .. (revision or 1) .. ":0:0", full = 1 }
  for k, v in pairs(extra or {}) do data[k] = copy(v) end
  return { "Balatro." .. sub, data }
end

local function fixture(revision, count)
  local result = { packet("Info", { ready = 0, wizard_only = 1 }, revision),
    packet("Profile", { decks = {} }, revision),
    packet("State", { phase = "playing", money = 4, processing = 0, paused = 0 }, revision),
    packet("Shop", { shop = "", pack = "" }, revision),
    packet("Score", { score = "0", target = "300" }, revision) }
  for _, sub in ipairs({ "Cards", "Shop" }) do
    local names = sub == "Cards" and { "hand", "jokers", "consumables" }
      or { "cards", "vouchers", "boosters", "pack" }
    for _, area in ipairs(names) do
      local size = area == "hand" and (count or 2) or 0
      local segments = math.max(1, math.ceil(size / 6))
      for segment = 1, segments do
        local rows = {}
        for index = (segment - 1) * 6 + 1, math.min(size, segment * 6) do
          rows[#rows + 1] = item(index)
        end
        result[#result + 1] = packet(sub, { area = area, segment = segment,
          segments = segments, total = size, items = rows }, revision)
      end
    end
  end
  return result
end

local function feed(packets)
  for _, p in ipairs(packets) do assert(protocol.ingest(p[1], p[2]), "valid packet rejected") end
end

protocol.reset()
local first = fixture(1, 14)
for index = 1, #first - 1 do
  expect(protocol.ingest(first[index][1], first[index][2]), "valid partial packet")
  expect(protocol.get() == nil, "incomplete snapshot cannot publish")
end
feed({ first[#first] })
expect(#protocol.get().cards.hand == 14, "all logical segments assemble in hand order")
expect(protocol.get().cards.hand[14].id == id(14), "last identity appears exactly once")
expect(#protocol.get().offers.pack == 0, "empty pack replaces previous panel")

-- An incomplete newer snapshot keeps the prior complete game visible.
local second = fixture(2, 2)
feed({ second[1], second[2] })
expect(protocol.get().revision == 1 and #protocol.get().cards.hand == 14,
  "incomplete revision cannot replace published hand")
feed({ unpack(second, 3) })
expect(protocol.get().revision == 2 and #protocol.get().cards.hand == 2, "new snapshot replaces atomically")
expect(not protocol.ingest(first[1][1], first[1][2]), "older revision rejected")

-- A physical split is assembled before interpreting logical card segmentation.
protocol.reset()
local all = fixture(3, 2)
local hand
for _, p in ipairs(all) do
  if p[2].area == "hand" then hand = p else feed({ p }) end
end
local page1 = copy(hand[2]); page1.items = { item(1) }; page1.page = 1; page1.pages = 2
local page2 = { full = 1, page = 2, pages = 2, items = { item(2) } }
expect(protocol.ingest(hand[1], page1), "first physical page accepted")
expect(protocol.get() == nil, "first physical page never publishes a partial hand")
expect(protocol.ingest(hand[1], page2), "second physical page accepted")
expect(#protocol.get().cards.hand == 2, "wire items concatenate before logical assembly")

expect(controller.toggle(id(1)), "displayed hand card selectable")
expect(controller.selection()[1] == id(1), "selection follows native hand order")
expect(not controller.toggle(id(99)), "unavailable card cannot be selected")
expect(controller.command("play", { id(1) }) == "balatro do fixture-run 3 play " .. id(1),
  "safe click uses exact native session/revision")
expect(controller.command("play", { id(1), id(1) }) == nil, "duplicate selection rejected")
expect(controller.command("play", { "i-123\nquit" }) == nil, "command injection rejected")
expect(controller.command("buy_card", { id(1) }) == nil, "hand cannot masquerade as shop offer")
expect(controller.command("unknown", {}) == nil, "unsupported action rejected")
expect(controller.send("play", { id(1) }) and #sent == 1, "one explicit action emits one command")
expect(not controller.send("play", { id(1) }) and #sent == 1, "pending click cannot emit a duplicate")
controller.refresh()
expect(sent[2] == "balatro status", "refresh sends no gameplay action")

-- Physical page gaps and corrupt art/identities never replace the last valid state.
local prior = protocol.get()
expect(not protocol.ingest("Balatro.Cards", { full = 1, page = 2, pages = 2 }),
  "orphan physical page rejected")
local bad = packet("Cards", { area = "hand", total = 1, segment = 1, segments = 1,
  items = { { id = id(1), art = "../../secrets" } } }, 4)
expect(not protocol.ingest(bad[1], bad[2]), "asset path traversal rejected")
expect(protocol.get() == prior, "malformed snapshot preserves last complete state")
bad = packet("Info", {}, 4); bad[2].schema = 2
expect(not protocol.ingest(bad[1], bad[2]), "unsupported schema rejected")
expect(not protocol.ingest("Other.State", {}), "unrelated namespace ignored")
bad = packet("Profile", { decks = "not an array" }, 4)
expect(not protocol.ingest(bad[1], bad[2]), "malformed profile container cannot reach renderer")
bad = packet("State", { phase = "playing", money = "four", paused = 0, processing = 0 }, 4)
expect(not protocol.ingest(bad[1], bad[2]), "malformed state counters rejected")
protocol.reset(); controller.reset()
expect(protocol.get() == nil and controller.command("play", { id(1) }) == nil,
  "disconnect clears state and blocks stale commands")
print("balatro_protocol_test: " .. checks .. " passed")
