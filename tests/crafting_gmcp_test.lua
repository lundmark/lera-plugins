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

local function visible(label)
  for y, row in pairs(drawn) do
    local x = row:find(label, 1, true)
    if x then return x - 1, y end
  end
end

local function button(label)
  local x, y = visible(label)
  assert(x, "missing button " .. label)
  return x, y
end

local function click(x, y)
  return window.on_pointer({ x = x, y = y, kind = "down", button = "left" })
end

local function right(x, y, kind, inside)
  return window.on_pointer({ x = x, y = y, kind = kind, button = "right", inside = inside })
end

local function choose(label)
  for _, item in ipairs(menu.items) do
    if item.label:find(label, 1, true) then
      menu.on_select(item.value)
      return
    end
  end
  error("missing menu item " .. label)
end

state.apply("Skills", { skills_0 = {
  woodwork = { unlocked = 1, can_train = 1, train_realm = "Fantasy", rank = 2, trained = 2,
    train_cost = 3, train_have = 24, train_abbr = "wrn", autotrain = 0,
    into = 140, to_next = -40, xp_rank = 4 },
  gemcraft = { unlocked = 1, can_train = -3, train_realm = "Fantasy", rank = 1,
    into = 50, to_next = 0, xp_rank = 2 },
  reaving = { unlocked = 1, can_train = 0, train_realm = "any", rank = 3,
    into = 45, to_next = 105, xp_rank = 3 },
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
      skill = "woodwork", rank = 1, materials = "2x Mana Crystal", time = 4200 },
    { building = "Grand Forge", name = "Star Silver Axe", id = "prod-14-star-axe" },
    { building = "Grand Forge", name = "Refine Mana Crystal", id = "refine-example" },
  },
})
state.apply("Jobs", {
  queue_cap = 5, queue_total = 3, ready = { { name = "Healthy Tonic" } },
  queues = { { building = "Grand Forge", depth = 3, cap = 5, stalled = 1, shortfall = "2 Mana Crystal",
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
assert(train_y < realm_y and drawn[train_y]:find("3/24 wrn", 1, true))
assert(drawn[train_y]:find("100/100", 1, true), "banked XP did not fill the next-rank bar")
local _, reaving_y = button("Reaving")
assert(drawn[reaving_y]:find("45/150", 1, true) and drawn[reaving_y]:find("Needs XP", 1, true))
local _, gemcraft_y = button("Gemcraft")
assert(drawn[gemcraft_y]:find("50/50", 1, true)
  and drawn[gemcraft_y]:find("Needs tokens", 1, true))
assert(drawn[reaving_y]:find("[", 1, true) == drawn[train_y]:find("[", 1, true),
  "skill XP bars are not in the same column")
assert(not click(55, train_y), "plain skill text must not send a command")
pass = "remote"
render(12, 4)
pass = "local"
assert(click(train_x, train_y) and sent[#sent] == "ctrain woodwork")
assert(click(train_x, train_y) and #sent == 2, "double click sent a second train")
render()
assert(click(button("[Auto off]")) and sent[#sent] == "ctrain auto woodwork")
assert(not visible("Bladesmithing"), "locked skill visible by default")
assert(click(button("[Show locked]")))
render()
assert(button("Bladesmithing"))
assert(click(button("[Hide locked]")))
render(48, 35)
assert(button("45/150") and button("[Train]"), "compact Skills view lost progress or actions")
window.set_page("jobs")
render()
local _, fantasy_y = button("Fantasy")
local _, stall_y = button("Missing 2 Mana Crystal")
assert(stall_y < fantasy_y and button("2 x Mana Crystal Axe"))
assert(click(button("[Inventory]")) and window.current_page() == "inventory")
window.set_page("jobs")
render()
assert(click(button("[Queue 1]")) and sent[#sent] == "cmake Grand Forge Mana Crystal Axe 1")
assert(click(button("[More]")) and #menu.items == 1)
assert(menu.items[1].label:find("4x Mana Crystal | 140 min base", 1, true))
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

-- Jobs batches include the automation settings and must not apply until complete.
protocol.reset_connection()
protocol.on_apply(function(sub, mirror) state.apply(sub, mirror) end)
local calls = #sent
assert(protocol.on_gmcp("Craft.Jobs", { jobs_a1_1_4_a = {
  { enabled = 1, collect = 0, reserve = 10, idle = 1, scrap = 2 },
} }))
assert(protocol.on_gmcp("Craft.Jobs", { jobs_a1_2_4_q = {
  { building = "Grand Forge", current_id = "axe", current_name = "Mana Crystal Axe",
    current_due = 1120, depth = 0, cap = 5 },
} }))
assert(protocol.on_gmcp("Craft.Jobs", { jobs_a1_3_4_a = {
  { realm = "Fantasy", building = "Grand Forge", recipe = "Mana Crystal Axe",
    status = "Needs 3 more Mana Crystal (keeps 10 in reserve)" },
} }))
assert(not state.get().automation and #sent == calls)
assert(protocol.on_gmcp("Craft.Jobs", { jobs_a1_4_4_l = { 0, 15 } }))
assert(state.get().queue_cap == 15 and state.get().repeat_rules[1].building == "Grand Forge")
assert(state.get().jobs_clock == 1000)
assert(protocol.on_gmcp("Craft.Jobs", { jobs_a2_1_3_a = {
  { enabled = 0, collect = 0, reserve = 0, idle = 0 },
} }))
assert(protocol.on_gmcp("Craft.Jobs", { jobs_a2_3_3_l = { 2, 15 } }))
assert(state.get().automation.enabled == 1, "incomplete batch replaced active plan")

lera.time = function() return 1030 end
window.set_page("jobs")
render()
assert(button("(2m 0s)"), "paused Jobs countdown decreased")
assert(click(button("[Repeat]")))
assert(menu.items[1].label:find("Needs 3 more Mana Crystal", 1, true))
choose("Stop repeating this recipe")
assert(sent[#sent] == "cmake auto clear Grand Forge")
window.set_page("automation")
render()
assert(button("Auto-scrap is on"))
assert(button("Needs 3 more Mana Crystal"))
assert(click(button("[Pause]")) and sent[#sent] == "cmake auto off")
assert(click(button("[Auto-collect off]")))
assert(sent[#sent] == "cmake auto collect on")
assert(click(button("[Reserve]")))
menu.on_select(menu.items[3].value)
assert(sent[#sent] == "cmake auto reserve 10")
local before_clear = #sent
assert(click(button("[Clear]")) and #sent == before_clear, "Clear asks before it clears")
choose("Keep repeating Mana Crystal Axe")
assert(#sent == before_clear, "keeping the rule sends nothing")
assert(click(button("[Clear]")))
choose("Stop repeating it")
assert(sent[#sent] == "cmake auto clear Grand Forge")

assert(protocol.on_gmcp("Craft.Jobs", { full = 1, queue_total = 1, queue_cap = 15,
  automation = { { enabled = 0, collect = 0, reserve = 0, idle = 0 } },
}))
assert(not state.get().jobs_clock and #state.get().repeat_rules == 0)
render()
assert(click(button("[Start]")) and sent[#sent] == "cmake auto on")
print("Crafting automation settings, repeat controls and paused timers: PASS")

-- A closing frame with the wrong index drops the stage: the next batch applies.
assert(protocol.on_gmcp("Craft.Jobs", { jobs_b1_1_3_a = {
  { enabled = 1, collect = 0, reserve = 0, idle = 0 },
} }))
assert(protocol.on_gmcp("Craft.Jobs", { jobs_b1_2_3_l = { 0, 15 } }))
assert(protocol.on_gmcp("Craft.Jobs", { jobs_b2_1_2_a = {
  { enabled = 1, collect = 1, reserve = 5, idle = 0 },
} }))
assert(protocol.on_gmcp("Craft.Jobs", { jobs_b2_2_2_l = { 0, 15 } }))
assert(state.get().automation.collect == 1, "a bad closing frame pinned the Jobs stage")
print("Crafting Jobs batches recover from a bad closing frame: PASS")

-- Market batches (mkt_<gen>_<i>_<n>_<code>) apply only once complete.
assert(protocol.on_gmcp("Craft.Market", { mkt_c1_1_3_o = { { id = 1, good = "Iron" } } }))
assert(protocol.on_gmcp("Craft.Market", { mkt_c1_2_3_c = { "Mana Crystal Axe" } }))
local mirror = protocol.mirror and protocol.mirror("Market")
assert(not (mirror and mirror.orders and mirror.orders[1] and mirror.orders[1].id == 1),
  "an incomplete Market batch was applied")
assert(protocol.on_gmcp("Craft.Market", { mkt_c1_3_3_l = {} }))
mirror = protocol.mirror and protocol.mirror("Market")
assert(mirror and mirror.orders[1].id == 1 and mirror.scroll_outbox[1] == "Mana Crystal Axe"
  and #mirror.auctions == 0, "the complete Market batch is applied, unsent lists empty")
print("Crafting Market batches: PASS")

-- Every tab must fit both a desktop popup and a narrow pane.
state.apply("State", {
  stock_used = 120, stock_cap = 200, souls = 30, soul_cap = 60,
  soul_tiers = { { tier = 1, count = 30, cap = 60 } },
  tokens_fantasy = { { realm = "Fantasy", name = "Worn", qty = 10, level = 1 } },
  materials = { { realm = "Fantasy", name = "Mana Crystal", qty = 15,
    category = "Refined", quality = "15 good" } },
})
state.apply("Buildings", { bldgs = { "Grand Forge|2" },
  refineries = { "Grove Mill|1|Oak Timber|75|2|4|1" } })
state.apply("Jobs", {
  ready = { { name = "Healthy Tonic" } }, queue_cap = 5, queue_total = 1,
  builds = { { building = "Grand Forge", tier = 3, due = 1090, duration = 120 } },
  masterwork = { { name = "Crystal Ring", target = 2, due = 1090, duration = 120 } },
  queues = { { building = "Grand Forge", current_id = "axe", current_name = "Mana Crystal Axe",
    current_due = 1090, current_duration = 120, depth = 1, cap = 5 } },
})
state.apply("Market", {
  scroll_outbox = { "Mana Crystal Axe" },
  exchanges = { { id = 4, player = "Crafter", give_qty = 10, give_token = "fantasy_1",
    want_qty = 2, want_token = "chaos_1" } },
  auctions = { { id = 5, seller = "Crafter", material_name = "Mana Crystal",
    qty = 2, high_bid = 100, reserve = 90, closes = 1090 } },
})
local expected = {
  info = "120/200", inventory = "30/60", skills = "XP to next rank",
  buildings = "50%", refinery = "75%", jobs = "50%",
  automation = "Crafting Automation", recipes = "Ingredients", market = "High bid",
}
for _, page in ipairs(window.PAGES) do
  local wide = table.concat(page.mod.lines(106), "\n")
  assert(wide:find(expected[page.key], 1, true), "missing content from " .. page.key)
  for _, width in ipairs({ 24, 48, 80, 106, 160 }) do
    local lines = page.mod.lines(width)
    for _, line in ipairs(lines) do
      assert(pagelib.visible_width(line) <= width, page.key .. " overflowed width " .. width)
    end
  end
end
local recipes = require("pages.recipes")
window.set_page("recipes")
recipes.search("mana crystal")
render()
assert(button("Mana Crystal Axe") and not visible("Star Silver Axe"))
assert(click(button("[Collect all]")) and sent[#sent] == "ccollect")
assert(click(button("[Queue 1]")) and sent[#sent] == "cmake Grand Forge Mana Crystal Axe 1")
assert(click(button("[More]")) and #menu.items == 3)
menu.on_select(menu.items[3].value)
assert(sent[#sent] == "cmake Grand Forge Mana Crystal Axe 4")
assert(click(button("[Can craft now]")))
render()
assert(button("Mana Crystal Axe") and not visible("Production Catalogue"))
local recipe_x, recipe_y = button("Mana Crystal Axe")
before = #sent
for _ = 1, 5 do assert(click(recipe_x, recipe_y)) end
assert(#sent == before + 5, "rapid recipe clicks were debounced")
for i = before + 1, #sent do
  assert(sent[i] == "cmake Grand Forge Mana Crystal Axe 1")
end
local previous_menu = menu
assert(right(recipe_x, recipe_y, "down"))
assert(not right(recipe_x, recipe_y, "up", false) and menu == previous_menu)
assert(right(recipe_x, recipe_y, "down"))
assert(right(recipe_x, recipe_y, "up", true))
assert(#menu.items == 4 and menu.items[4].label:find("8x Mana Crystal", 1, true))
render(48, 35)
assert(button("[Queue 1]"), "compact recipe view lost the queue button")
recipe_x, recipe_y = button("Mana Crystal Axe")
assert(right(recipe_x, recipe_y, "down") and right(recipe_x, recipe_y, "up", true))
choose("Queue 3 ")
assert(sent[#sent] == "cmake Grand Forge Mana Crystal Axe 3")
render()
assert(click(button("[Clear search]")))
render()
assert(not visible("Search: mana crystal"))
assert(click(button("[All recipes]")))
render()
assert(button("Star Silver Axe"))
assert(visible("Needs T3"), "a tier-locked recipe lost its status")
assert(click(button("[Inventory]")) and window.current_page() == "inventory")
render()
assert(click(button("[Collect all]")) and sent[#sent] == "ccollect")
window.set_page("market")
render()
assert(click(button("[Collect scrolls]")) and sent[#sent] == "cmarket scroll collect")
window.set_page("recipes")
state.apply("Jobs", { queue_cap = 5, queue_total = 5 })
render()
assert(visible("Queue full") and not visible("[Queue 1]"))
assert(not visible("[Collect all]"), "empty outbox still offers collection")
state.apply("Jobs", {
  queue_cap = 5, queue_total = 5, automation = { { enabled = 0 } },
})
recipes.search("mana crystal")
render()
recipe_x, recipe_y = button("Mana Crystal Axe")
assert(not click(recipe_x, recipe_y), "queue-full recipe still starts a manual job")
assert(right(recipe_x, recipe_y, "down") and right(recipe_x, recipe_y, "up", true))
choose("Repeat this recipe (save while paused)")
assert(sent[#sent] == "cmake auto repeat Grand Forge Mana Crystal Axe")
choose("Start all saved automation")
assert(sent[#sent] == "cmake auto on")
choose("Open Automation")
assert(window.current_page() == "automation")
local jobs = require("pages.jobs")
state.apply("Jobs", {
  queues = { { building = "Grand Forge", current_id = "axe", current_due = 1090,
    current_duration = 120 } },
  automation = { { idle = 1 } },
})
lera.time = function() return 1060 end
local frozen = table.concat(jobs.lines(106), "\n")
assert(frozen:find("50%", 1, true), "paused job bar advanced")
print("All crafting tabs fit and timed job progress uses original duration: PASS")

-- Structures plans arrive as separate chunks alongside, not in place of, owned tiers.
protocol.reset_connection()
assert(protocol.on_gmcp("Craft.Structures", { bldgs = { "Grand Forge|2" } }))
assert(protocol.on_gmcp("Craft.Structures", { buildplans = {
  "Grand Forge|Fantasy|||400|worn|3600",
  "Soul Well|Global|||400|each realm|3600",
  "Bone Forge|Chaos|Boneworks|soulsmithing|400|cracked|3600",
} }))
assert(protocol.on_gmcp("Craft.Structures", { buildplans_1 = {
  "Gem Atelier|Fantasy|||400|worn|3600",
  "Weaver's Hall|Fantasy|||400|worn|3600",
} }))
assert(#state.get().buildings == 1 and #state.get().build_plans == 5)
state.apply("Jobs", {
  pending_builds = { { building = "Gem Atelier", tier = 1 } },
  builds = { { building = "Weaver's Hall", tier = 1, due = 1100, duration = 60 } },
})
window.set_page("buildings")
render(106, 44)
assert(visible("Under construction") and visible("Awaiting funding"))
assert(visible("Build Boneworks first") and visible("400 each realm"))
before = #sent
assert(click(button("Soul Well")))
assert(#sent == before, "clicking a building spent tokens before confirmation")
assert(menu.title:find("400 each realm", 1, true))
choose("Queue Tier 1 construction")
assert(sent[#sent] == "cbuild construct Soul Well confirm")
assert(click(button("Bone Forge")) and #menu.items == 1)
choose("View cost and requirements")
assert(sent[#sent] == "cbuild construct Bone Forge")
assert(not click(button("Grand Forge")))
assert(not click(button("Gem Atelier")))
assert(not click(button("Weaver's Hall")))
render(48, 50)
assert(click(button("Soul Well")), "compact view lost construction menu")
state.reset()
state.apply("Buildings", { buildplans = { "Soul Well|Global|||400|each realm|3600" } })
render()
assert(visible("Unbuilt Buildings") and click(button("Soul Well")), "empty account could not build")
print("Unbuilt building catalogue and construction actions: PASS")

state.reset()
state.apply("Buildings", {
  bldgs = { "Blight Farms|1", "Crystal Mines|2", "Biolabs|1", "Unknown Station|1" },
  buildplans = {
    "Soul Well|Global|||400|each realm|3600",
    "Crystal Mines|Fantasy|||400|worn|3600",
    "Biolabs|Science|||400|cracked|3600",
    "Blight Farms|Chaos|||400|cracked|3600",
    "Bone Forge|Chaos|||400|cracked|3600",
  },
})
state.apply("Jobs", {
  pending_builds = { { building = "Crystal Mines", tier = 3 } },
  builds = { { building = "Soul Well", tier = 1, due = 1100, duration = 60 } },
})
render(106, 55)
local chaos_pos = select(2, button("Blight Farms"))
local fantasy_pos = select(2, button("Crystal Mines"))
local science_pos = select(2, button("Biolabs"))
local global_pos = select(2, button("Soul Well"))
local other_pos = select(2, button("Unknown Station"))
local unbuilt_pos = select(2, button("Unbuilt Buildings"))
assert(chaos_pos < fantasy_pos and fantasy_pos < science_pos and science_pos < global_pos
  and global_pos < other_pos and other_pos < unbuilt_pos, "building realm order is wrong")
assert(drawn[chaos_pos - 2]:match("^Chaos ") and drawn[fantasy_pos - 2]:match("^Fantasy ")
  and drawn[science_pos - 2]:match("^Science ") and drawn[global_pos - 2]:match("^Global ")
  and drawn[other_pos - 2]:match("^Other "), "each group needs its realm heading")
assert(drawn[fantasy_pos]:find("Awaiting funding", 1, true))
assert(drawn[global_pos]:find("Under construction", 1, true))
assert(select(2, button("Bone Forge")) > unbuilt_pos)
print("Built, pending, and active construction grouped by realm: PASS")
