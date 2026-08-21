-- guild_viking window/tab-bar unit tests. Run from the lera-plugins repo
-- root with LERA_ROOT pointing at a built Lera checkout.
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
local drawn -- { ansi = {...}, texts = {...} }, reset per case that cares
local function reset_drawn() drawn = { ansi = {}, texts = {} } end
reset_drawn()

ui = {
  dirty = function() dirty_count = dirty_count + 1 end,
  rect = function(x, y, w, h) return make_rect(x, y, w, h) end,
  text = function(r, s) drawn.texts[#drawn.texts + 1] = { x = r:x(), y = r:y(), s = s } end,
  text_ansi = function(r, s) drawn.ansi[#drawn.ansi + 1] = { x = r:x(), y = r:y(), s = s } end,
}

local render_pass = "local"
lera = { render_pass = function() return render_pass end }

local window = require("window")

-- ---- PAGES registry ---------------------------------------------------------
local expected_pages = {
  { key = "stats",  label = "Stats" },
  { key = "city",   label = "City" },
  { key = "farm",   label = "Farm" },
  { key = "builds", label = "Builds" },
  { key = "people", label = "People" },
  { key = "goods",  label = "Goods" },
  { key = "bonds",  label = "Bonds" },
  { key = "ranks",  label = "Ranks" },
  { key = "court",  label = "Court" },
  { key = "army",   label = "Army" },
  { key = "war",    label = "War" },
  { key = "trade",  label = "Trade" },
}
check("PAGES has 12 entries", #window.PAGES == 12, #window.PAGES)
local pages_ok = true
for i, exp in ipairs(expected_pages) do
  local got = window.PAGES[i]
  if not got or got.key ~= exp.key or got.label ~= exp.label then pages_ok = false end
end
check("PAGES keys/labels match the twelve stage-2 pages", pages_ok)
check("every PAGES entry starts on pages.placeholder", (function()
  for _, p in ipairs(window.PAGES) do
    if type(p.mod) ~= "table" or type(p.mod.lines) ~= "function" then return false end
  end
  return true
end)())
check("current_page defaults to stats", window.current_page() == "stats")

local function find_page(key)
  for _, p in ipairs(window.PAGES) do
    if p.key == key then return p end
  end
end

-- ---- tab bar: all twelve labels rendered, current highlighted --------------
reset_drawn()
window.render(make_rect(0, 0, 100, 5), {})
check("tab bar drew at least the header row", #drawn.ansi >= 1)
local tabrow = drawn.ansi[1] and drawn.ansi[1].s or ""
local all_present = true
for _, p in ipairs(expected_pages) do
  if not tabrow:find(p.label, 1, true) then all_present = false end
end
check("tab bar contains all twelve labels", all_present, tabrow)
check("current tab (Stats) is reverse-video highlighted",
      tabrow:find("\27%[7mStats\27%[27m") ~= nil, tabrow)
check("non-current tab (City) is not reverse-video wrapped",
      not tabrow:find("\27%[7mCity\27%[27m"), tabrow)

-- ---- set_page: switches, unknown key refused --------------------------------
check("set_page switches to a known key", window.set_page("city") == true)
check("current_page reflects the switch", window.current_page() == "city")
check("set_page refuses an unknown key", window.set_page("bogus") == false)
check("current_page unchanged after a refused switch", window.current_page() == "city")
check("set_page back to stats", window.set_page("stats") == true)

-- ---- on_pointer: tab-span down switches page, body down does not -----------
-- Column layout for a 100-wide bar (one label per gap, 1-space separator):
-- Stats[0,5) City[6,10) Farm[11,15) Builds[16,22) ... -- verified against the
-- render above (all twelve labels fit on row 0 at width 100).
reset_drawn()
window.render(make_rect(0, 0, 100, 5), {})

local down_on_farm = { kind = "down", button = "left", x = 12, y = 0,
                       inside = true, width = 100, height = 5 }
check("down on Farm's tab span switches page", window.on_pointer(down_on_farm) == true)
check("current_page is now farm", window.current_page() == "farm")

window.set_page("stats")
local down_in_body = { kind = "down", button = "left", x = 5, y = 2,
                        inside = true, width = 100, height = 5 }
check("down in the body returns false", window.on_pointer(down_in_body) == false)
check("current_page unchanged by a body down", window.current_page() == "stats")

-- ---- per-page scroller offsets are independent; windowing respects offset --
local stats_lines = {}
for i = 1, 50 do stats_lines[i] = "L" .. i end
find_page("stats").mod = { lines = function() return stats_lines end }
find_page("city").mod = { lines = function() return { "C1", "C2", "C3" } end }

window.set_page("stats")
local body_rect = make_rect(0, 0, 100, 5) -- tab row (1) + body height (4)

reset_drawn()
window.render(body_rect, {})
-- drawn.ansi[1] is the tab row; body rows follow.
check("stats body starts at L1 before scrolling",
      drawn.ansi[2] and drawn.ansi[2].s:find("^L1%s") ~= nil, drawn.ansi[2] and drawn.ansi[2].s)
check("stats following_tail true before scrolling", window.following_tail() == true)

window.scroll(10)
check("stats following_tail false after scrolling down", window.following_tail() == false)

reset_drawn()
window.render(body_rect, {})
check("stats body windowed to the new offset (L11..L14)",
      drawn.ansi[2] and drawn.ansi[2].s:find("^L11%s") ~= nil
      and drawn.ansi[5] and drawn.ansi[5].s:find("^L14%s") ~= nil,
      drawn.ansi[2] and drawn.ansi[2].s)

check("switching to city switches page", window.set_page("city") == true)
reset_drawn()
window.render(body_rect, {})
check("city (never scrolled) is at its own tail", window.following_tail() == true)
check("city shows its own short content",
      drawn.ansi[2] and drawn.ansi[2].s:find("^C1%s") ~= nil, drawn.ansi[2] and drawn.ansi[2].s)

check("switching back to stats", window.set_page("stats") == true)
check("stats offset preserved across the page switch", window.following_tail() == false)
reset_drawn()
window.render(body_rect, {})
check("stats still windowed at L11..L14 after switching away and back",
      drawn.ansi[2] and drawn.ansi[2].s:find("^L11%s") ~= nil, drawn.ansi[2] and drawn.ansi[2].s)

window.scroll_to_bottom()
check("scroll_to_bottom moves stats to its last page", window.following_tail() == false)
reset_drawn()
window.render(body_rect, {})
check("stats tail window ends at L50",
      drawn.ansi[5] and drawn.ansi[5].s:find("^L50%s") ~= nil, drawn.ansi[5] and drawn.ansi[5].s)

-- ---- remote pass does not clobber hit-test spans ----------------------------
window.set_page("stats")
render_pass = "local"
reset_drawn()
window.render(make_rect(0, 0, 100, 5), {}) -- records spans for the WIDE layout
check("(setup) down on Farm's span works against the wide layout",
      window.on_pointer(down_on_farm) == true and window.current_page() == "farm")
window.set_page("stats")

render_pass = "remote"
reset_drawn()
local ok_remote = pcall(window.render, make_rect(0, 0, 20, 5), {}) -- drastically different layout
check("remote render into a different-width rect does not error", ok_remote)

check("remote pass did not update the recorded spans",
      window.on_pointer(down_on_farm) == true and window.current_page() == "farm")

-- ---- Finding 1 (review round 1): a remote pass at a DIFFERENT height must --
-- not mutate the shared scroller clamp a later local render depends on. -----
window.set_page("stats")
render_pass = "local"
reset_drawn()
window.render(body_rect, {})       -- establishes height = 4 (body_rect's body_h)
window.scroll_to_bottom()          -- offset -> 46 (count 50 - height 4)
reset_drawn()
window.render(body_rect, {})       -- "before": window at H1 = 4
check("(setup) before window ends at L50",
      drawn.ansi[5] and drawn.ansi[5].s:find("^L50%s") ~= nil, drawn.ansi[5] and drawn.ansi[5].s)
local before_window = { drawn.ansi[2].s, drawn.ansi[3].s, drawn.ansi[4].s, drawn.ansi[5].s }

render_pass = "remote"
reset_drawn()
-- H2 = 10 (a TALLER remote body) -- if set_height ran unguarded here, the
-- clamp's max (count - height) would shrink from 46 to 40 and reclamp the
-- LOCAL offset down, even though only a remote viewer's own size changed.
local ok_remote_height = pcall(window.render, make_rect(0, 0, 100, 11), {})
check("remote render at a different height does not error", ok_remote_height)

render_pass = "local"
reset_drawn()
window.render(body_rect, {})       -- render locally again at the SAME H1
local after_window = { drawn.ansi[2].s, drawn.ansi[3].s, drawn.ansi[4].s, drawn.ansi[5].s }
check("local window unchanged after an intervening remote render at a different height",
      after_window[1] == before_window[1] and after_window[2] == before_window[2]
      and after_window[3] == before_window[3] and after_window[4] == before_window[4],
      after_window[1])

-- ---- Finding 2a (review round 1): a down on a WRAPPED (row>0) tab span ----
-- switches page and returns true. A 30-wide rect wraps the twelve labels
-- onto three rows: row0 Stats/City/Farm/Builds/People, row1
-- Goods/Bonds/Ranks/Court/Army, row2 War/Trade (verified against
-- render_tabbar's column bookkeeping: Goods[0,5) Bonds[6,11) ...).
window.set_page("stats")
render_pass = "local"
reset_drawn()
window.render(make_rect(0, 0, 30, 10), {})
check("narrow rect wraps the tab bar onto multiple rows", #drawn.ansi >= 3)
check("wrapped row 1 contains Bonds",
      drawn.ansi[2] and drawn.ansi[2].s:find("Bonds", 1, true) ~= nil,
      drawn.ansi[2] and drawn.ansi[2].s)

local down_on_wrapped_bonds = { kind = "down", button = "left", x = 8, y = 1,
                                 inside = true, width = 30, height = 10 }
check("down on a wrapped-row tab span switches page",
      window.on_pointer(down_on_wrapped_bonds) == true)
check("current_page is now bonds (from a row-1 span)", window.current_page() == "bonds")
window.set_page("stats")

-- ---- Finding 2b (review round 1): a down on the separator column between --
-- two adjacent labels matches neither span and returns false.
render_pass = "local"
reset_drawn()
window.render(make_rect(0, 0, 100, 5), {}) -- restores the wide layout's spans
local page_before_separator_down = window.current_page()
local down_on_separator = { kind = "down", button = "left", x = 5, y = 0, -- the
                             -- single space between Stats[0,5) and City[6,10)
                             inside = true, width = 100, height = 5 }
check("down on the separator column between two tabs returns false",
      window.on_pointer(down_on_separator) == false)
check("separator down does not change the page",
      window.current_page() == page_before_separator_down)

render_pass = "local"

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING WINDOW TESTS PASSED")
