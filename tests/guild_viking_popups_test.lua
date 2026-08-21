-- guild_viking popups.lua + /vik popup-routing unit tests. Run from the
-- lera-plugins repo root with LERA_ROOT pointing at a built Lera checkout.
package.path = "3scapes/guild_viking/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- ---- lera API stubs ---------------------------------------------------------
local function make_rect(x, y, w, h)
  return {
    x = function() return x end, y = function() return y end,
    w = function() return w end, h = function() return h end,
  }
end

local dirty_count = 0
local drawn -- { ansi = {...} }, reset per case that cares
local function reset_drawn() drawn = { ansi = {} } end
reset_drawn()

ui = {
  dirty = function() dirty_count = dirty_count + 1 end,
  rect = function(x, y, w, h) return make_rect(x, y, w, h) end,
  text_ansi = function(r, s) drawn.ansi[#drawn.ansi + 1] = { x = r:x(), y = r:y(), s = s } end,
}

local render_pass = "local"
lera = { render_pass = function() return render_pass end, time = function() return 1000 end,
         version = function() return "test" end }

-- Captures each color_print call's text segments, joined, as one entry --
-- lets the "unregistered popup"/"unregistered page" cases assert on the
-- printed message instead of just that a call happened.
local printed = {}
buffer = {
  color_print = function(...)
    local args = { ... }
    local parts = {}
    for i = 3, #args, 3 do
      parts[#parts + 1] = tostring(args[i])
    end
    printed[#printed + 1] = table.concat(parts)
  end,
}
mud = { send = function() end }
local stored = nil
store = {
  load = function() end,
  get = function() return stored end,
  set = function(d) stored = d end,
  save = function() end,
}
local mip_handlers, mip_handler_count = {}, 0
mip = {
  on = function(code, cb)
    mip_handlers[code] = cb
    mip_handler_count = mip_handler_count + 1
    return mip_handler_count
  end,
  off = function() end,
  enabled = function() return true end,
}
local gmcp_handlers, gmcp_handler_count = {}, 0
gmcp = {
  on = function(pkg, cb)
    gmcp_handlers[pkg] = cb
    gmcp_handler_count = gmcp_handler_count + 1
    return gmcp_handler_count
  end,
  remove = function() end,
  enabled = function() return false end,
}
local trigger_reg_count = 0
trigger = {
  add = function() trigger_reg_count = trigger_reg_count + 1; return trigger_reg_count end,
  remove = function() end,
}
local timer_regs = {}
timer = {
  every = function(interval, fn) timer_regs[#timer_regs + 1] = { interval = interval, fn = fn }
    return #timer_regs end,
  remove = function() end,
}
alias = {
  add = function() return 1 end,
  remove = function() end,
}
plugin = { get = function() return nil end }

-- ---- wm.popup facade stub ---------------------------------------------------
-- Sandboxed plugins reach the real popup surface through require("wm").popup
-- (CLAUDE.md "Popup Overlay"); this stub captures every open()/close() call
-- (renderer + opts) instead of loading the real scripts/default/wm.lua +
-- its own require chain (popup/menu/bind), matching the task brief's "a
-- wm.popup facade stub capturing open/close/renderer/opts".
local is_open_flag = false
local current_open = nil -- { renderer = ..., opts = ... }
local opens = {}          -- history of every open() call, in order
local close_count = 0

local function finish_popup()
  local old = current_open
  current_open = nil
  is_open_flag = false
  close_count = close_count + 1
  if old and old.opts and old.opts.on_close then old.opts.on_close() end
end

package.loaded["wm"] = {
  popup = {
    -- Mirrors scripts/default/popup.lua's real _open: an already-open popup
    -- is torn down (firing ITS on_close) before the new one is installed.
    open = function(renderer, opts)
      if is_open_flag then finish_popup() end
      current_open = { renderer = renderer, opts = opts }
      is_open_flag = true
      opens[#opens + 1] = current_open
      return true
    end,
    close = function()
      if not is_open_flag then return false end
      finish_popup()
      return true
    end,
    is_open = function() return is_open_flag end,
  },
}

-- Command registry stub: captures the /vik spec so its handler can be
-- dispatched directly later, same idiom as guild_viking_test.lua.
local registered_vik = nil
local real_require = require
require = function(name)
  if name == "command" then
    return { register = function(spec) registered_vik = spec; return 1 end,
             unregister = function() return true end,
             get = function() return nil end, list = function() return {} end }
  end
  return real_require(name)
end

-- =============================================================================
-- popups.lua: registry / toggle / wrapper mechanics (stubbed wm.popup)
-- =============================================================================
local popups = require("popups")
local window = require("window")

-- ---- register + toggle opens with the module's title and 0.9 sizing --------
local map_lines_calls = 0
local map_module = {
  title = "Territory Map",
  lines = function(w)
    map_lines_calls = map_lines_calls + 1
    local out = {}
    for i = 1, 5 do out[i] = "row " .. i end
    return out
  end,
}
popups.register("map", map_module)

check("toggle unknown-until-registered map returns true now that it's registered",
      popups.toggle("map") == true)
check("wm.popup reports open", is_open_flag == true)
check("popup opened with the module's title", opens[1].opts.title == "Territory Map")
check("popup opened at width 0.9", opens[1].opts.width == 0.9)
check("popup opened at height 0.9", opens[1].opts.height == 0.9)
check("popup renderer has a render function", type(opens[1].renderer.render) == "function")
check("popup renderer has a scroll function", type(opens[1].renderer.scroll) == "function")

-- ---- wrapper renders windowed lines into a stub rect and scrolls -----------
reset_drawn()
opens[1].renderer.render(make_rect(0, 0, 10, 3), { title = "Territory Map" })
check("wrapper called the module's lines()", map_lines_calls >= 1)
check("wrapper drew rows clamped to the rect height (3)", #drawn.ansi == 3)
check("wrapper drew row 1 first", drawn.ansi[1] and drawn.ansi[1].s:find("row 1", 1, true) ~= nil,
      drawn.ansi[1] and drawn.ansi[1].s)
check("wrapper following_tail true before scrolling",
      opens[1].renderer.following_tail() == true)

opens[1].renderer.scroll(2)
check("wrapper following_tail false after scrolling", opens[1].renderer.following_tail() == false)
reset_drawn()
opens[1].renderer.render(make_rect(0, 0, 10, 3), { title = "Territory Map" })
check("wrapper windowed to the new offset (starts at row 3)",
      drawn.ansi[1] and drawn.ansi[1].s:find("row 3", 1, true) ~= nil,
      drawn.ansi[1] and drawn.ansi[1].s)

-- remote pass must not disturb the cached count/clamp the local pass depends on
render_pass = "remote"
reset_drawn()
local ok_remote = pcall(opens[1].renderer.render, make_rect(0, 0, 4, 1), { title = "x" })
check("remote render at a different size does not error", ok_remote)
render_pass = "local"
reset_drawn()
opens[1].renderer.render(make_rect(0, 0, 10, 3), { title = "Territory Map" })
check("local render unchanged after an intervening remote render",
      drawn.ansi[1] and drawn.ansi[1].s:find("row 3", 1, true) ~= nil,
      drawn.ansi[1] and drawn.ansi[1].s)

-- ---- toggle same name closes ------------------------------------------------
check("toggle same name (map) closes", popups.toggle("map") == true)
check("wm.popup now closed", is_open_flag == false)
check("close_count incremented", close_count == 1)

-- ---- toggle other name replaces (old on_close fired) ------------------------
popups.toggle("map") -- reopen
local sea_module = { title = "Sea Chart", lines = function() return { "a", "b" } end }
popups.register("sea", sea_module)

local before_close_count = close_count
check("toggle other name (sea) opens", popups.toggle("sea") == true)
check("old (map) on_close fired during replace", close_count == before_close_count + 1)
check("now open and showing sea's title", is_open_flag == true and opens[#opens].opts.title == "Sea Chart")

check("toggle sea again closes it", popups.toggle("sea") == true)
check("closed after second toggle", is_open_flag == false)

-- ---- toggle on an unregistered name -----------------------------------------
printed = {}
check("toggle unregistered name returns false", popups.toggle("nope") == false)
check("toggle unregistered name does not open a popup", is_open_flag == false)
check("toggle unregistered name prints a friendly message",
      #printed >= 1 and printed[#printed]:find("nope", 1, true) ~= nil, printed[#printed])

-- ---- on_pointer forwarding: ctx carries close() -----------------------------
local seen_ev, seen_ctx
local pointer_module = {
  title = "Pointer Test",
  lines = function() return { "L1" } end,
  on_pointer = function(ev, ctx) seen_ev, seen_ctx = ev, ctx; return true end,
}
popups.register("voyage", pointer_module)
popups.toggle("voyage")
check("wrapper exposes on_pointer when the module has one",
      type(opens[#opens].renderer.on_pointer) == "function")
local down = { kind = "down", button = "left", x = 1, y = 0, inside = true, width = 10, height = 3 }
check("on_pointer forwards the event and returns the module's result",
      opens[#opens].renderer.on_pointer(down) == true)
check("on_pointer received the same event table", seen_ev == down)
check("ctx carries a close function", type(seen_ctx.close) == "function")
seen_ctx.close()
check("ctx.close() closed the popup", is_open_flag == false)

-- ---- open_page wraps a window.PAGES entry (no on_pointer) and scrolls ------
reset_drawn()
check("open_page('stats') returns true", popups.open_page("stats") == true)
check("open_page opened a popup", is_open_flag == true)
local stats_open = opens[#opens]
check("open_page popup titled from the page label", stats_open.opts.title == "Stats")
check("open_page popup width 0.9", stats_open.opts.width == 0.9)
check("open_page popup height 0.9", stats_open.opts.height == 0.9)
check("open_page wrapper has no on_pointer (pane pages have none)",
      stats_open.renderer.on_pointer == nil)

reset_drawn()
local ok_render, err_render = pcall(stats_open.renderer.render, make_rect(0, 0, 80, 10),
                                     { title = "Stats" })
check("open_page wrapper renders the real stats page without error", ok_render, err_render)
check("open_page wrapper drew at least one row", #drawn.ansi > 0)

local ok_scroll = pcall(function()
  stats_open.renderer.scroll(3)
  stats_open.renderer.scroll(-3)
end)
check("open_page wrapper scroll() does not error", ok_scroll)

check("open_page unknown page returns false", popups.open_page("no_such_page") == false)

if is_open_flag then package.loaded["wm"].popup.close() end
check("popup closed before moving to /vik routing tests", is_open_flag == false)

-- =============================================================================
-- placeholder strings: pages/city.lua + pages/war.lua drop " (stage 3)"
-- =============================================================================
local page_opts = require("page_opts")
local S = require("state").S

page_opts.set("show_city_plan", true)
local city_lines = window.PAGES[2].mod.lines(80) -- city
local city_placeholder_found = false
for _, l in ipairs(city_lines) do
  if l:find("City plan: /vik cityplan", 1, true) then city_placeholder_found = true end
  if l:find("(stage 3)", 1, true) then
    check("city.lua placeholder no longer says (stage 3)", false, l)
  end
end
check("city.lua placeholder text updated", city_placeholder_found)

-- war.lua's placeholder only appears once the campaign map has active data
-- (M.lines gates campaign_map_lines on S.war_map.active) -- minimal seed,
-- same shape as guild_viking_window_test.lua's Task-10 seed.
S.war_map = { active = true, dim = 1, turn = 1, mode = "offense", pending = 0,
              town = "Jorvik", works_budget = 0, march_eta = 0, rows = { "." } }
local war_lines = window.PAGES[11].mod.lines(80) -- war
check("window.PAGES[11] is the war page", window.PAGES[11].key == "war")
local war_placeholder_found = false
for _, l in ipairs(war_lines) do
  if l:find("Battle map: /vik war", 1, true) then war_placeholder_found = true end
  if l:find("(stage 3)", 1, true) then
    check("war.lua placeholder no longer says (stage 3)", false, l)
  end
end
check("war.lua placeholder text updated", war_placeholder_found)

-- =============================================================================
-- /vik dispatch: routing to popups.toggle/open_page, "page"/"pop"
-- subcommands, and the war name-collision ruling
-- =============================================================================
local M = dofile("3scapes/guild_viking/init.lua")
M.on_load()
check("vik registered", registered_vik ~= nil and registered_vik.name == "/vik")

-- popups.toggle with an unregistered name prints its own friendly message
-- and opens nothing. Task 5's probe used "war" here, banking on it being
-- the one POPUP_NAMES member still unregistered at this point in the file;
-- Task 6 gave popups.lua a REAL self-registered "war" module (see the
-- bottom of popups.lua), so requiring "popups" above now registers it
-- before this file ever reaches this line -- "war" stopped being a valid
-- probe. Fixed by testing popups.toggle directly with a permanently-fake
-- name (never a real POPUP_NAMES member, so no future task can register it
-- out from under this probe) instead of routing through /vik. The
-- complementary property the old probe also checked -- a POPUP_NAMES
-- member opens its popup rather than switching the pane, even though the
-- name is ALSO a window.PAGES key -- is covered more strongly below by the
-- registered "war" stub ("bare /vik war opened the popup, not the pane").
window.set_page("stats")
printed = {}
local ok_unregistered = popups.toggle("zz_never_registered_popup")
check("popups.toggle with an unregistered name returns false", ok_unregistered == false)
check("popups.toggle with an unregistered name opens nothing", is_open_flag == false)
check("popups.toggle with an unregistered name printed its own message",
      #printed >= 1 and printed[#printed]:find("zz_never_registered_popup", 1, true) ~= nil,
      printed[#printed])

-- Stage 1 registers no named popups yet; register a throwaway "war" module
-- directly through popups.lua (the same singleton init.lua's dispatch uses)
-- so the routing itself can be exercised ahead of Task 6's real content.
local war_popup_calls = 0
popups.register("war", {
  title = "Campaign & Battle",
  lines = function() war_popup_calls = war_popup_calls + 1; return { "x" } end,
})

window.set_page("stats")
registered_vik.handler("war", "/vik")
check("bare /vik war opened the popup, not the pane",
      is_open_flag == true and window.current_page() == "stats")
check("bare /vik war's popup is titled from the war module",
      opens[#opens].opts.title == "Campaign & Battle")
package.loaded["wm"].popup.close()
check("popup closed after bare /vik war test", is_open_flag == false)

registered_vik.handler("page war", "/vik")
check("/vik page war switches the pane to war", window.current_page() == "war")
check("/vik page war did not open a popup", is_open_flag == false)

window.set_page("stats")
registered_vik.handler("stats", "/vik")
check("bare /vik stats still switches the pane (non-colliding key)",
      window.current_page() == "stats" and is_open_flag == false)

window.set_page("stats")
registered_vik.handler("city", "/vik")
check("bare /vik city still switches the pane", window.current_page() == "city")
window.set_page("stats")

registered_vik.handler("pop goods", "/vik")
check("/vik pop goods opened a popup", is_open_flag == true)
check("/vik pop goods popup titled Goods", opens[#opens].opts.title == "Goods")
check("/vik pop goods did not touch the pane page", window.current_page() == "stats")
package.loaded["wm"].popup.close()

printed = {}
registered_vik.handler("pop no_such_page", "/vik")
check("/vik pop <unknown page> did not open a popup", is_open_flag == false)
check("/vik pop <unknown page> printed a message", #printed >= 1)

printed = {}
registered_vik.handler("page", "/vik")
check("/vik page with no key prints usage", #printed >= 1 and printed[#printed]:find("Usage", 1, true) ~= nil)

printed = {}
registered_vik.handler("pop", "/vik")
check("/vik pop with no key prints usage", #printed >= 1 and printed[#printed]:find("Usage", 1, true) ~= nil)

pcall(M.on_unload)

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING POPUPS TESTS PASSED")
