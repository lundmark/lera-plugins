-- Focused integration tests with real plugins and mocked host/parser APIs.
package.path = "3scapes/?.lua;generic/?.lua;" .. package.path
local failures = 0
local function check(name, ok)
  print("CASE " .. name .. ": " .. (ok and "PASS" or "FAIL"))
  if not ok then failures = failures + 1 end
end
local commands, saved, saves = {}, nil, 0
package.loaded.command = {
  register = function(spec) commands[spec.name] = spec.handler; return spec.name end,
  unregister = function() end,
}
store = {
  load = function() end, get = function() return saved end,
  set = function(data)
    saved = {settings = {}}
    for k, v in pairs(data.settings) do saved.settings[k] = v end
  end,
  save = function() saves = saves + 1 end,
}
local parsed = {
  ["2n"] = {"n", "n"}, ["(ne)"] = {"ne"},
  ["(enter portal)"] = {"enter portal"}, ["esw"] = {"e", "s", "w"},
}
local parses = 0
alias = {add = function() return 1 end, remove = function() end}
speedwalk = {
  graph_create = function() return {
    add_place = function() end, place_count = function() return 0 end,
    edge_count = function() return 0 end,
  } end,
  parse = function(s) parses = parses + 1; return parsed[s] end,
  flatten = function(path) return path end,
}
lera = {frame_reset = function() end}
mud = {send = function() error("render must not send commands") end}
local sw = require("speedwalk")
sw.on_load()
sw.configure_place("route", "2n|(ne)|(enter portal)|esw", "orc")
sw.set_current_place("route")
check("parsed command preview capped at five", table.concat(sw.upcoming_steps(), ",") == "n,n,ne,enter portal,e")
check("zero limit", #sw.upcoming_steps(0) == 0)
local snapshot = sw.upcoming_steps()
snapshot[1] = "changed"
check("snapshot cannot mutate route", sw.peek_step().commands[1] == "n")
sw.take_step()
check("index counts groups, preview uses commands", table.concat(sw.upcoming_steps(), ",") == "ne,enter portal,e,s,w")
sw.reset_steps()
local grid = {rows = {"O-O-O", "  |  ", "  @  "}, w = 5, h = 3}
local room = {
  map = function() return grid end, room = function() return "Crossroads" end,
  area = function() return "Test" end, exits_string = function() return "(n, e)" end,
  monsters = function() return {"an orc"} end, players = function() return {} end,
}
local plugins = {speedwalk = sw, roominfo = room}
plugin = {get = function(name) return plugins[name] end}
local drawn = {}
ui = {
  box = function() end,
  rect = function(x, y, w, h) return {x = x, y = y, w = w, h = h} end,
  text = function(rect, text) drawn[#drawn + 1] = {rect = rect, text = text} end,
}
ui.text_ansi = ui.text
local mm = require("minimap")
plugins.minimap = mm
mm.on_load()
local mv = require("mapview")
local function render(mod, w, h, border)
  drawn = {}
  mod.render({x = 10, y = 20, w = w or 60, h = h or 20}, {show_border = border == true})
  local lines = {}
  for _, d in ipairs(drawn) do lines[#lines + 1] = d.text:gsub("\27%[[%d;]*m", "") end
  return table.concat(lines, "\n")
end
local function has(text, needle) return text:find(needle, 1, true) ~= nil end
check("default off exposed", mm.get_settings().show_next_steps == false)
local baseline = render(mm)
local hybrid_baseline = render(mv)
check("disabled no preview", not has(baseline, "Next:") and not has(hybrid_baseline, "Next:"))
commands["/minimap"]("next on")
check("immediately saved", saves == 1 and saved.settings.show_next_steps == true)
check("independent of steps", mm.get_settings().show_steps == false)
check("direct parsed preview", has(render(mm), "Next: n, n, ne, enter portal, e"))
local hybrid = render(mv)
check("hybrid shared preview and existing info", has(hybrid, "Next: n, n, ne, enter portal, e")
  and has(hybrid, "Crossroads") and has(hybrid, "[Area: Test]") and has(hybrid, "(n, e)")
  and has(hybrid, "route [0/4]") and has(hybrid, "T:orc") and has(hybrid, "an orc"))
local parse_count = parses
render(mm); render(mv)
check("render read-only", parses == parse_count and sw.step_info().current == 0 and sw.peek_step().raw == "2n")
commands["/minimap"]("next")
check("bare toggle off saves and restores layout", saves == 2 and not saved.settings.show_next_steps
  and render(mm) == baseline and render(mv) == hybrid_baseline)
commands["/minimap"]("next on")
package.loaded.minimap = nil
mm = require("minimap"); plugins.minimap = mm; mm.on_load()
check("reload restores immediately persisted setting", mm.get_settings().show_next_steps == true)
commands["/minimap"]("next invalid")
check("invalid argument no mutation", saves == 3 and mm.get_settings().show_next_steps)
mm.toggle_steps()
check("counter and path remain independently available", has(render(mm), "route [0/4]") and has(render(mm), "1"))
mm.toggle_room_name(); mm.toggle_exits()
for _, mod in ipairs({mm, mv}) do
  local narrow = render(mod, 10, 20)
  check(mod.name .. " narrow preview clipped", has(narrow, "Next: n, ~"))
  for _, border in ipairs({false, true}) do
    for w = 1, 4 do
      for h = 1, 4 do
        render(mod, w, h, border)
        local inset = border and 1 or 0
        for _, d in ipairs(drawn) do
          local r = d.rect
          assert(r.x >= 10 + inset and r.y >= 20 + inset and r.w > 0 and r.h > 0)
          assert(r.x + r.w <= 10 + w - inset and r.y + r.h <= 20 + h - inset)
        end
      end
    end
  end
  check(mod.name .. " tiny panes stay inside bounds", true)
end
for _ = 1, 4 do sw.take_step() end
check("route end agrees with peek, does not wrap", sw.peek_step() == nil and #sw.upcoming_steps() == 0
  and not has(render(mm), "Next:") and not has(render(mv), "Next:"))
check("preview leaves end index untouched", sw.step_info().current == 4)
sw.take_step()
check("only take_step resets after end", sw.step_info().current == 0 and sw.upcoming_steps()[1] == "n")
grid = nil
check("missing map still shows known steps", has(render(mm), "Next:") and has(render(mv), "Next:"))
local fallback_rect
plugins.mapper = {render = function(rect) fallback_rect = rect end}
check("hybrid mapper fallback retains preview", has(render(mv), "Next:") and fallback_rect.h == 19)
plugins.mapper = nil
plugins.speedwalk = nil
check("missing speedwalk hides preview", not has(render(mm), "Next:") and not has(render(mv), "Next:"))
plugins.speedwalk = sw
sw.clear_steps()
check("empty dynamic exploration has no invented route", mm.next_steps_text() == nil
  and not has(render(mm), "Next:") and not has(render(mv), "Next:"))
commands["/minimap"]("next off")
check("explicit off persists", saved.settings.show_next_steps == false)
if failures > 0 then error(failures .. " FAILURE(S)") end
print("ALL PASS")
