lera = { time = function() return 1 end }
local protocol = dofile("3scapes/crafting/protocol.lua")
local state = dofile("3scapes/crafting/state.lua")
state.reset()
local applied = 0
protocol.on_apply(function(sub, mirror)
  applied = applied + 1
  state.apply(sub, mirror)
end)

local function jobs(data)
  assert(protocol.on_gmcp("Craft.Jobs", data))
  return protocol.mirror("Jobs")
end

local old = jobs({ full = 1, ready = {{ name = "Iron Axe" }}, queue_cap = 40 })
local forge, loom = { building = "Grand Forge" }, { building = "Mana Loom" }

-- A missing middle batch must leave the previous complete view in place.
assert(jobs({ full = 1, jobs_a_1_3_q = {forge} }) == old)
assert(jobs({ full = 1, jobs_a_3_3_l = {2, 40} }) == old)
assert(applied == 1)

-- A replacement generation contains every list, including implicit empties.
assert(jobs({ full = 1, jobs_b_1_3_q = {forge} }) == old)
assert(jobs({ full = 1, jobs_a_2_3_q = {forge} }) == old)
assert(jobs({ full = 1, jobs_b_2_3_q = {loom} }) == old)
local current = jobs({ full = 1, jobs_b_3_3_l = {2, 40} })
assert(applied == 2 and #current.queues == 2 and #current.ready == 0)
assert(current.queues[1] == forge and current.queues[2] == loom)
assert(current.queue_total == 2 and current.queue_cap == 40)

-- Switching back to an ordinary update clears rows that left the queue.
current = jobs({ full = 1, queues = {}, ready = {}, queue_total = 0, queue_cap = 40 })
assert(applied == 3 and #current.queues == 0)

-- Old server full and delta pages also combine repeats before applying.
local first_page = { full = 1, page = 1, pages = 3, queues = {forge} }
assert(jobs(first_page) == current)
assert(jobs({ full = 1, page = 2, pages = 3, queue_cap = 40 }) == current)
current = jobs({ full = 1, page = 3, pages = 3, queues = {loom} })
assert(applied == 4 and #current.queues == 2 and current.queue_cap == 40)
assert(#first_page.queues == 1)
assert(jobs({ page = 1, pages = 2, queues = {loom} }) == current)
current = jobs({ page = 2, pages = 2, queues = {forge} })
assert(applied == 5 and #current.queues == 2 and current.queues[1] == loom)
assert(current.queue_cap == 40)

-- Older Market pushes can use both driver pages and numbered list keys.
protocol.on_gmcp("Craft.Market", { full = 1, page = 1, pages = 2, orders = {forge} })
assert(protocol.mirror("Market") == nil)
protocol.on_gmcp("Craft.Market", { full = 1, page = 2, pages = 2, orders_1 = {loom} })
local market = state.snapshot()
assert(#market.orders == 2 and market.orders[2].building == "Mana Loom")

local function market_batch(gen, index, count, code, rows)
  local key = string.format("mkt_%s_%d_%d_%s", gen, index, count, code)
  assert(protocol.on_gmcp("Craft.Market", { full = 1, [key] = rows }))
end

-- A larger book crosses the driver's eight-page allowance. Only batch 11
-- commits it. A gap and a concurrent Jobs push must leave Market intact.
market_batch("d", 1, 3, "a", {{ id = 1 }})
market_batch("d", 3, 3, "l", {})
assert(#state.snapshot().orders == 2)
for i = 1, 9 do
  market_batch("e", i, 11, "m", {{ id = i }})
end
assert(#state.snapshot().orders == 2)
jobs({ full = 1, jobs_f_1_2_q = {forge} })
market_batch("e", 10, 11, "c", {"Iron Axe", "Mana Loom"})
jobs({ full = 1, jobs_f_2_2_l = {1, 40} })
assert(#state.snapshot().queues == 1 and #state.snapshot().orders == 2)
market_batch("e", 11, 11, "l", {})
market = state.snapshot()
assert(#market.orders == 0 and #market.auctions == 0)
assert(#market.material_orders == 9 and market.material_orders[9].id == 9)
assert(#market.scroll_outbox == 2 and market.scroll_outbox[2] == "Mana Loom")
protocol.on_gmcp("Craft.Market", { full = 1, material_orders = {{ id = 10 }} })
market = state.snapshot()
assert(#market.material_orders == 1 and market.material_orders[1].id == 10)
assert(#market.scroll_outbox == 0)

jobs({ full = 1, jobs_c_1_2_q = {loom} })
protocol.reset_connection()
assert(jobs({ full = 1, jobs_c_2_2_l = {1, 40} }) == nil)
print("crafting jobs tests passed")
