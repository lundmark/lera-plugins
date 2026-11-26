package.path = "3scapes/crafting/?.lua;" .. package.path
lera = { time = function() return 1000 end }

local protocol = require("protocol")
local applied = { Info = 0, State = 0 }
protocol.on_apply(function(sub) applied[sub] = applied[sub] + 1 end)

local function check_feed(info, state, other_info, other_state)
  protocol.reset_connection()
  applied.Info, applied.State = 0, 0

  local standing = { full = 1, realms = { Fantasy = { level = 3 } } }
  assert(protocol.on_gmcp(info, standing))
  assert(protocol.on_gmcp(other_info, standing))
  assert(protocol.mirror("Info").realms.Fantasy.level == 3)
  assert(applied.Info == 1, "both Info wire names applied the same frame")

  local summary = { full = 1, souls = 9 }
  local chunk = { full = 1, materials_g12c0 = { { name = "Mana Crystal", qty = 2 } } }
  local close = { full = 1, materials_chunks_g12 = 1 }
  assert(protocol.on_gmcp(state, summary))
  assert(protocol.on_gmcp(other_state, summary))
  assert(protocol.on_gmcp(other_state, chunk))
  assert(protocol.materials_stage_debug().have == 0, "the alternate feed staged a chunk")
  assert(protocol.on_gmcp(state, chunk))
  assert(protocol.on_gmcp(state, close))
  assert(protocol.on_gmcp(other_state, close))
  assert(protocol.mirror("State").souls == 9)
  assert(protocol.mirror("State").materials[1].name == "Mana Crystal")
  assert(applied.State == 3, "the alternate State feed applied an update")
  assert(protocol.counters().applied == 4 and protocol.counters().bad_package == 0)
end

check_feed("Craft.Info", "Craft.State", "Craft.Infodata", "Craft.Statedata")
check_feed("Craft.Infodata", "Craft.Statedata", "Craft.Info", "Craft.State")
print("Crafting GMCP wire names and material chunks: PASS")

-- Exercise action routing through the popup using server-shaped records.
local state = require("state")
local window = require("window")
local pagelib = require("pagelib")
local sent = {}
local menu
package.loaded.menu = { open = function(opts) menu = opts end }
local pass = "local"
lera.render_pass = function() return pass end
mud = { send = function(command) sent[#sent + 1] = command end }
local function rect(x, y, w, h)
  return { x = function() return x end, y = function() return y end,
    w = function() return w end, h = function() return h end }
end
local drawn = {}
ui = { rect = rect, dirty = function() end, text_ansi = function(area, text)
  drawn[area:y()] = text:gsub("\27%[[%d;]*m", "")
end }

local function render(width, height)
  drawn = {}
  window.render(rect(0, 0, width or 90, height or 35))
end

local function button(label)
  for y, row in pairs(drawn) do
    local x = row:find(label, 1, true)
    if x then return x - 1, y end
  end
  error("missing button " .. label)
end

local function click(x, y)
  return window.on_pointer({ x = x, y = y, kind = "down", button = "left" })
end

state.apply("Skills", { skills_0 = {
  woodwork = { unlocked = 1, can_train = 1, train_realm = "Fantasy", rank = 2, trained = 2,
    train_cost = 3, train_abbr = "wrn", autotrain = 0 },
  gemcraft = { unlocked = 1, can_train = -3, train_realm = "Fantasy" },
  bladesmithing = { unlocked = 0, can_train = -2, train_realm = "Fantasy" },
} })
state.apply("Buildings", { bldgs = { "Grand Forge|2" } })
state.apply("Recipes", {
  catalogue_fantasy = {
    { building = "Grand Forge", name = "Mana Crystal Axe", tier = 1 },
    { building = "Grand Forge", name = "Star Silver Axe", tier = 3 },
  },
  known_fantasy = {
    { building = "Grand Forge", name = "Mana Crystal Axe", id = "prod-14-axe",
      materials = "2x Mana Crystal", time = 4200 },
    { building = "Grand Forge", name = "Star Silver Axe", id = "prod-14-star-axe" },
    { building = "Grand Forge", name = "Refine Mana Crystal", id = "refine-example" },
  },
})
state.apply("Jobs", {
  queue_cap = 5, queue_total = 3, ready = { { name = "Healthy Tonic" } },
  queues = { { building = "Grand Forge", depth = 3, cap = 5, stalled = 1,
    items = "Mana Crystal Axe, Mana Crystal Axe, Star Silver Axe" } },
})
window.set_page("info")
render()
assert(click(button("[Collect all]")))
assert(sent[#sent] == "ccollect")
assert(click(button("[Skills]")) and window.current_page() == "skills")
render()
local train_x, train_y = button("[Train]")
local _, realm_y = button("Fantasy Skills")
assert(train_y > realm_y and drawn[train_y]:find("3x wrn", 1, true))
assert(not click(55, train_y), "plain skill text must not send a command")
pass = "remote"
render(12, 4)
pass = "local"
assert(click(train_x, train_y) and sent[#sent] == "ctrain woodwork")
assert(click(train_x, train_y) and #sent == 2, "double click sent a second train")
render()
assert(click(button("[Auto off]")) and sent[#sent] == "ctrain auto woodwork")
window.set_page("jobs")
render()
local _, fantasy_y = button("Fantasy")
local _, forge_y = button("Grand Forge")
assert(forge_y > fantasy_y and button("2 x Mana Crystal Axe"))
assert(click(button("[Queue 1]")) and sent[#sent] == "cmake Grand Forge Mana Crystal Axe 1")
assert(click(button("[More]")) and #menu.items == 1)
menu.on_select(menu.items[1].value)
assert(sent[#sent] == "cmake Grand Forge Mana Crystal Axe 2")
assert(click(button("[Clear queue]")))
local before = #sent
menu.on_select(menu.items[1].value)
assert(#sent == before, "keeping the queue sent a command")
menu.on_select(menu.items[2].value)
assert(sent[#sent] == "cmake cancel Grand Forge")
local _, blocked_y = button("Needs T3")
assert(not click(0, blocked_y), "tier-locked recipe unexpectedly clickable")
local queue_x, queue_y = button("[Queue 1]")
window.scroll(1)
assert(not click(queue_x, queue_y), "old body hit map survived a scroll")
render(4, 40)
for _, row in pairs(drawn) do
  assert(pagelib.visible_width(row) == 4, "narrow popup row overflowed")
end
window.reset_actions()
assert(not click(queue_x, queue_y), "old body hit map survived popup close")
before = #sent
menu.on_select(menu.items[2].value)
assert(#sent == before, "old confirmation survived popup close")
print("Crafting realm groups and popup actions: PASS")
