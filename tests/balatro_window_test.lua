package.path = "3scapes/balatro/?.lua;" .. package.path
local checks, sent, paints, pass = 0, {}, 0, "local"
local function expect(condition, label) assert(condition, label); checks = checks + 1 end
local function id(n) return string.format("i-%027d", n) end
local function rect(x, y, w, h)
  return { x = function() return x end, y = function() return y end,
    w = function() return w end, h = function() return h end }
end
local live = { session = "fixture-run", revision = 1, snapshot = "fixture-run:1:0:0",
  info = { ready = 0 }, state = { phase = "playing", processing = 0, paused = 0,
    score = "0", target = "300", money = 4, hands_left = 3, discards_left = 2 },
  cards = { hand = {}, jokers = {}, consumables = {} },
  offers = { cards = {}, vouchers = {}, boosters = {}, pack = {} },
  shop = {}, profile = { decks = {} } }
for n = 1, 2 do
  live.cards.hand[n] = { id = id(n), rank = n + 1, suit = "Hearts", kind = "Playing",
    art = "playing/hearts_" .. (n + 1), selectable = 1 }
end
package.loaded.protocol = { get = function() return live end }
mud = { send = function(command) sent[#sent + 1] = command end }
lera = { render_pass = function() return pass end, display = function() return "gui" end }
ui = { rect = rect, dirty = function() end, text_ansi = function() end,
  image_load = function(path) return { path = path } end,
  image = function() paints = paints + 1 end }
local controller = require("controller")
local window = require("window")
window.render(rect(100, 50, 64, 30))
expect(paints == 2, "PNG mode renders both front images")
expect(window.on_pointer({ kind = "down", button = "left", x = 1, y = 7 }),
  "pointer uses pane-relative coordinates")
expect(controller.selected(id(1)), "first displayed card selected")
expect(#sent == 0, "selecting a card never emits gameplay")

pass = "remote"
window.render(rect(0, 0, 11, 40))
expect(window.on_pointer({ kind = "down", button = "left", x = 12, y = 7 }),
  "remote narrow render cannot overwrite local card targets")
expect(controller.selected(id(2)), "local second card target retained")
expect(not window.on_pointer({ kind = "down", button = "right", x = 1, y = 5 }),
  "right click cannot play a hand")
expect(window.on_pointer({ kind = "down", button = "left", x = 1, y = 5 }), "play button consumes click")
expect(#sent == 1 and sent[1] == "balatro do fixture-run 1 play " .. id(1) .. " " .. id(2),
  "one play click emits exact displayed session and ordered selected IDs")
expect(not window.on_pointer({ kind = "cancel", button = "left", x = 1, y = 5 }),
  "pointer cancellation emits no action")

live.snapshot, live.revision = "fixture-run:2:0:0", 2
expect(not window.on_pointer({ kind = "down", button = "left", x = 1, y = 5 }),
  "stale render targets cannot act on a newer snapshot")
expect(#sent == 1, "stale click sends nothing")
pass = "local"
window.set_mode("ascii")
local before = paints
window.render(rect(0, 0, 64, 30))
expect(paints == before, "ASCII mode does not load/draw PNG images")
expect(window.on_pointer({ kind = "down", button = "left", x = 1, y = 7 }),
  "ASCII card remains clickable")
expect(controller.selected(id(1)), "ASCII selection uses same native identity")
expect(not window.set_mode("../other"), "only the two supported modes are accepted")
print("balatro_window_test: " .. checks .. " passed")
