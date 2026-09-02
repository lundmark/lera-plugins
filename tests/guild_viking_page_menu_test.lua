-- guild_viking per-page context menu (page_menu.lua) unit tests. Run from the
-- lera-plugins repo root with LERA_ROOT pointing at a built Lera checkout.
--
-- Ports LEGACY guild_viking.lua:11040-11148 (PAGE_MENUS), 11165-11209
-- (viking_show_page_menu) and 11211-11250 (viking_page_menu_pick). LEGACY
-- keyed its table by numeric page index; this port keys it by lera page key,
-- so the mapping itself is asserted here rather than assumed:
--   LEGACY 1,2,3,4,5,6,8,9,11,12,13,14 -> the twelve pane pages in order,
--   LEGACY 7 -> the Map popup, LEGACY 10 -> the Sea popup.
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
local dirty_count = 0
ui = { dirty = function() dirty_count = dirty_count + 1 end }
local sent = {}
mud = { send = function(s) sent[#sent + 1] = s end }
local printed = {}
buffer = { color_print = function(_, _, s) printed[#printed + 1] = s end }
lera = { render_pass = function() return "local" end }

-- require("menu") is the real contract this feature is built on, but the real
-- module needs the whole input/bind layer -- stubbed here to capture what was
-- opened, which is exactly what these cases assert. The REAL menu.lua is
-- exercised end-to-end by tests/menu_test.lua; the real popup.lua dispatch
-- path for this feature is exercised by guild_viking_popup_dispatch_test.lua.
local opened = nil
local open_count = 0
package.loaded["menu"] = {
  open = function(spec) opened = spec; open_count = open_count + 1 end,
  close = function() opened = nil end,
  is_open = function() return opened ~= nil end,
}

-- persist.save() is called on every toggle (LEGACY:11245's
-- OnPluginSaveState). Counted, not exercised -- persist.lua's own round-trip
-- is covered in guild_viking_test.lua.
local saves = 0
package.loaded["persist"] = { save = function() saves = saves + 1 end, load = function() end }

local page_opts = require("page_opts")
local page_menu = require("page_menu")

local function label_of(items, needle)
  for _, it in ipairs(items) do
    if it.label:find(needle, 1, true) then return it.label end
  end
  return nil
end

local function value_of(items, needle)
  for _, it in ipairs(items) do
    if it.label:find(needle, 1, true) then return it.value end
  end
  return nil
end

-- ---- the page->menu mapping ------------------------------------------------
-- Every pane page and both menu-bearing popups must have a menu; a page with
-- no LEGACY menu must return nil rather than an empty list, so a caller can
-- tell "no menu for this page" from "a menu that happens to be empty".
local expect_pages = {
  "stats", "city", "farm", "builds", "people", "goods",
  "bonds", "ranks", "court", "army", "war", "trade", "map", "sea",
}
for _, key in ipairs(expect_pages) do
  local items = page_menu.items(key)
  check("items(" .. key .. ") returns a non-empty list",
    type(items) == "table" and #items > 0, items and #items)
end
check("items() for an unknown page is nil", page_menu.items("nope") == nil)

-- ---- LEGACY item content, spot-checked per page ----------------------------
-- LEGACY:11041-11044 ([1] stats).
local stats = page_menu.items("stats")
check("stats menu has exactly LEGACY's two rows", #stats == 2, #stats)
check("stats menu carries Show Saga XP", label_of(stats, "Show Saga XP") ~= nil)
check("stats menu carries Show Buffs", label_of(stats, "Show Buffs") ~= nil)

-- LEGACY:11046-11063 ([2] city) -- 16 rows, of which show_city_plan_icons is
-- dropped (see below), leaving 15.
local city = page_menu.items("city")
check("city menu carries Show Longships", label_of(city, "Show Longships") ~= nil)
check("city menu carries the Auto-Raid action row",
  label_of(city, "Auto-Raid settings...") ~= nil)

-- LEGACY:11094-11098 ([7] map) -- belongs to the Map POPUP in lera.
local map = page_menu.items("map")
check("map menu carries Show Locations List", label_of(map, "Show Locations List") ~= nil)
check("map menu carries the Travel action row", label_of(map, "Travel to...") ~= nil)

-- LEGACY:11106-11124 ([10] sea) -- belongs to the Sea POPUP in lera.
local sea = page_menu.items("sea")
check("sea menu carries Show Voyage", label_of(sea, "Show Voyage") ~= nil)
check("sea menu carries Confirm Chart Clicks",
  label_of(sea, "Confirm Chart Clicks") ~= nil)
check("sea menu carries the Auto-Voyage action row",
  label_of(sea, "Auto-Voyage settings...") ~= nil)

-- LEGACY:11142-11148 ([14] trade) -- the trade dashboard's own menu, which
-- repeats four city keys plus the auto-trade rows.
local trade = page_menu.items("trade")
check("trade menu carries Show Carts", label_of(trade, "Show Carts") ~= nil)
check("trade menu carries the Auto-Trade action row",
  label_of(trade, "Auto-Trade settings...") ~= nil)

-- ---- deliberate omissions --------------------------------------------------
-- The three *_icons keys are real page_opts entries (so /vik opts lists them)
-- but NOTHING reads them: they gate LEGACY's graphical Wang-tile branch,
-- which this conversion never ported (text view only). Offering a control
-- that provably does nothing is worse than not offering it.
check("city menu omits the inert Show City Plan Icons row",
  label_of(city, "City Plan Icons") == nil)
check("map menu omits the inert Show Map Icons row",
  label_of(map, "Map Icons") == nil)
check("sea menu omits the inert Show Chart Icons row",
  label_of(sea, "Chart Icons") == nil)
-- LEGACY:11174 appends "Change Font" to EVERY page menu; it retuned that
-- plugin window's own font, and lera's font is global and composition-level.
for _, key in ipairs(expect_pages) do
  check("the " .. key .. " menu omits the Change Font chrome row",
    label_of(page_menu.items(key), "Change Font") == nil)
end

-- ---- checkbox and action prefixes (LEGACY:11190-11199, byte-faithful) -----
page_opts.set("show_stats_buffs", true)
page_opts.set("show_stats_xp", false)
local pre = page_menu.items("stats")
check("an ON toggle renders LEGACY's [+] prefix",
  label_of(pre, "Show Buffs") == "[+] Show Buffs", label_of(pre, "Show Buffs"))
check("an OFF toggle renders LEGACY's [ ] prefix",
  label_of(pre, "Show Saga XP") == "[ ] Show Saga XP", label_of(pre, "Show Saga XP"))
check("an action row renders LEGACY's > prefix",
  label_of(city, "Auto-Raid settings...") == ">  Auto-Raid settings...",
  label_of(city, "Auto-Raid settings..."))
-- The filter text is the bare label, so typing "saga" finds a row whose
-- visible label starts with a checkbox prefix.
check("a toggle row's search text is the bare LEGACY label",
  pre[1].search == "Show Saga XP" or pre[2].search == "Show Saga XP")

-- ---- open() ----------------------------------------------------------------
opened, open_count = nil, 0
page_menu.open("stats")
check("open() opens a menu", opened ~= nil)
check("open() titles the menu after the page", opened and opened.title == "Stats")
check("open() supplies an on_select", opened and type(opened.on_select) == "function")
check("open() on an unknown page opens nothing",
  (function() opened = nil; page_menu.open("nope"); return opened == nil end)())

-- ---- pick(): a toggle flips, persists, redraws and REOPENS -----------------
-- Deliberate deviation from LEGACY, disclosed in the module header: LEGACY
-- closed the menu after every toggle (11245-11247). Reopening lets the user
-- flip (or type-to-filter) several rows without a right-click between each.
page_opts.set("show_stats_buffs", false)
saves, dirty_count, opened, open_count = 0, 0, nil, 0
page_menu.open("stats")
local v = value_of(page_menu.items("stats"), "Show Buffs")
opened.on_select(v)
check("selecting a toggle flips its page_opt",
  page_opts.get("show_stats_buffs") == true)
check("selecting a toggle persists immediately", saves == 1, saves)
check("selecting a toggle marks the UI dirty", dirty_count > 0, dirty_count)
check("selecting a toggle reopens the menu in place", open_count == 2, open_count)
check("the reopened menu shows the new checkbox state",
  label_of(opened.items, "Show Buffs") == "[+] Show Buffs",
  label_of(opened.items, "Show Buffs"))
opened.on_select(v)
check("selecting it again flips it back",
  page_opts.get("show_stats_buffs") == false)

-- ---- pick(): action rows dispatch to the existing menus --------------------
-- LEGACY:11216-11239 closes the page menu and opens the target menu; here
-- menu.open's own "opening a menu cancels the open one" contract does that.
local dispatched
package.loaded["autotrader.tick"] = { open_menu = function() dispatched = "atrade" end }
package.loaded["autoraid"] = { open_menu = function() dispatched = "araid" end }
package.loaded["autovoyage"] = { open_menu = function() dispatched = "avoyage" end }
package.loaded["popups.map"] = { open_poi_menu = function() dispatched = "travel" end }
package.loaded["autoherd"] = { open_menu = function() dispatched = "aherd" end }

local function pick_action(page, needle)
  dispatched = nil
  page_menu.open(page)
  opened.on_select(value_of(page_menu.items(page), needle))
  return dispatched
end
check("the Auto-Trade action row opens the autotrader menu",
  pick_action("goods", "Auto-Trade settings...") == "atrade")
check("the Auto-Raid action row opens the auto-raid menu",
  pick_action("city", "Auto-Raid settings...") == "araid")
check("the Auto-Voyage action row opens the auto-voyage menu",
  pick_action("sea", "Auto-Voyage settings...") == "avoyage")
check("the Travel action row opens the POI menu",
  pick_action("map", "Travel to...") == "travel")
-- Auto-Herd is the one automation that SPENDS the player's daler, and it had
-- no page_menu presence at all -- no toggle row and no settings row, while
-- each of its three non-spending siblings had both. LEGACY carried exactly
-- these two rows (guild_viking.lua:12625-12626); they live on the stock page
-- here rather than city because this port moved every livestock section onto
-- its own page, which is where LEGACY's rows sat relative to their content.
check("the Auto-Herd toggle row exists on the stock page",
  label_of(page_menu.items("stock"), "Auto-Herd (husbandry)") ~= nil,
  label_of(page_menu.items("stock"), "Auto-Herd"))
check("the Auto-Herd toggle row is a page_opts key row, not an action",
  (value_of(page_menu.items("stock"), "Auto-Herd (husbandry)") or "")
    == "key:auto_herd",
  value_of(page_menu.items("stock"), "Auto-Herd (husbandry)"))
check("the Auto-Herd action row opens the auto-herd menu",
  pick_action("stock", "Auto-Herd settings...") == "aherd")

-- An action row must never touch page_opts or persist.
saves = 0
local before = page_opts.get("show_map_towns")
pick_action("map", "Travel to...")
check("an action row does not flip any page_opt",
  page_opts.get("show_map_towns") == before)
check("an action row does not persist", saves == 0, saves)

-- ---- pick(): nothing is ever sent to the MUD from a toggle -----------------
-- The menu is a display-option surface; only the ported action rows reach
-- code that can send, and each of those is its own already-reviewed menu.
sent = {}
page_menu.open("city")
for _, it in ipairs(page_menu.items("city")) do
  if it.value:find("^key:") then opened.on_select(it.value) end
end
check("toggling every row on a page sends nothing to the MUD", #sent == 0, #sent)

-- ---- unknown/garbage values are inert --------------------------------------
saves, dispatched = 0, nil
page_menu.open("stats")
opened.on_select("key:no_such_option_at_all")
check("an unknown option key does not persist", saves == 0, saves)
opened.on_select("action:no_such_action")
check("an unknown action dispatches nothing", dispatched == nil)
opened.on_select("garbage-with-no-prefix")
check("a malformed value is inert", saves == 0 and dispatched == nil)

print(failures == 0 and "ALL GUILD_VIKING PAGE_MENU TESTS PASSED"
  or (failures .. " GUILD_VIKING PAGE_MENU TEST FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
