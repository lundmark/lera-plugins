package.path = "3scapes/crafting/?.lua;" .. package.path

local now, redraws = 1000, 0
local drawn = {}
lera = { time = function() return now end, render_pass = function() return "local" end }
ui = {
  dirty = function() redraws = redraws + 1 end,
  rect = function() end,
  text_ansi = function(_, text) drawn[#drawn + 1] = text end,
}
local rect = {
  w = function() return 100 end, h = function() return 25 end,
  x = function() return 0 end, y = function() return 0 end,
}
local state = require("state")
local window = require("window")

local function render()
  drawn = {}
  window.render(rect)
  return table.concat(drawn, "\n")
end

local function tick(expected)
  local before = redraws
  window.countdown_tick()
  assert(redraws - before == expected)
end

state.apply("Jobs", { builds = {{ building = "Mill", tier = 2, due = now + 2 }} })
state.apply("Market", { scroll_auctions = {{ id = 1, recipe_name = "Ink", closes = now + 3 }} })
render()
tick(0)

window.set_page("jobs")
assert(render():find("(2s)", 1, true))
now = now + 1
tick(1)
assert(render():find("(1s)", 1, true))
now = now + 1
tick(1)
assert(render():find("(ready)", 1, true))
tick(0)

window.set_page("market")
assert(render():find("1s", 1, true))
now = now + 1
tick(1)
assert(render():find("ended", 1, true))
tick(0)

state.apply("Jobs", { ready = {{ name = "Ink", expires = now + 5 }} })
window.set_page("jobs")
assert(render():find("5s", 1, true))
window.set_page("info")
render()
tick(0)
-- A paused crafting clock (#85: automation idle, s.jobs_clock) freezes the
-- timers, so it must not keep asking for redraws.
state.apply("Jobs", { builds = {{ building = "Mill", tier = 2, due = now + 60 }},
  automation = {{ enabled = 1, collect = 0, reserve = 0, idle = 1 }} })
window.set_page("jobs")
render()
now = now + 1
tick(0)
state.apply("Jobs", { builds = {{ building = "Mill", tier = 2, due = now + 60 }},
  automation = {{ enabled = 1, collect = 0, reserve = 0, idle = 0 }} })
render()
now = now + 1
tick(1)
print("crafting_countdown_test: PASS")
