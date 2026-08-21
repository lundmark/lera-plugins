-- guild_viking pane page unit tests: Task 3's pages/stats.lua (also hosts
-- Farm/Builds from Task 5, per the plan's shared-harness note). Run from the
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
-- pages/stats.lua is pure (no ui.* calls), but it requires combat.lua, whose
-- trigger functions (never invoked here) call ui.dirty() -- stub it anyway
-- so a future accidental call fails loudly as a stub-missing error, not
-- silently.
ui = { dirty = function() end }
lera = { render_pass = function() return "local" end }

local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local combat = require("combat")
local stats_page = require("pages.stats")

local S = state.S

-- ---- seed state with known values -------------------------------------------
S.daler = 12345
S.hp, S.mhp, S.hp_delta = 350, 500, 5
S.threk, S.mthrek, S.threk_delta = 10, 50, -2
S.seid, S.mseid, S.seid_delta = 80, 100, 0
S.vig, S.mvig, S.vig_delta = 40, 80, 0
S.rad, S.mrad, S.rad_delta = 20, 40, 0
S.fury = "[***-------]"
S.ldng, S.mldng, S.lrst = 3, 4, 10
S.chain, S.bsdepth = 7, 2
S.god_power_name, S.god_power_next = "", 0

S.vis, S.vis_gain, S.vis_session = 100, 5, 20
S.kap, S.kap_gain, S.kap_session = 200, 3, 15
S.soe, S.soe_gain, S.soe_session = 50, 0, 5
S.aud, S.aud_gain, S.aud_session = 10, 1, 2
S.xp_session_start = os.time() - 65   -- 1m5s elapsed

S.en5, S.ens, S.rndz = "Wolf", "low", 3
S.mob_name_full, S.estatus_pct, S.combat = "Grey Wolf", 42, true

S.stfx = { { name = "ein", val = "54", cat = "Def" } }

page_opts.set("show_stats_xp", true)
page_opts.set("show_stats_buffs", true)

local WIDTH = 80

local function joined(lines)
  return table.concat(lines, "\n")
end

-- Returns the 1-based line index of the first line containing `needle`
-- (plain substring, ANSI escapes included but not interfering since needle
-- itself has none), or nil.
local function find_line(lines, needle)
  for i, l in ipairs(lines) do
    if l:find(needle, 1, true) then return i end
  end
  return nil
end

-- ---- full render: every gated section on ------------------------------------
local lines = stats_page.lines(WIDTH)
check("lines() returns a non-empty array", #lines > 5, #lines)

local all = joined(lines)

-- ---- daler line, fmt_num'd -------------------------------------------------
check("daler line present with fmt_num'd value",
      all:find(pagelib.fmt_num(S.daler), 1, true) ~= nil, pagelib.fmt_num(S.daler))

-- ---- an hp row: bar glyphs AND "350/500" -----------------------------------
local hp_idx = find_line(lines, "350/500")
check("an hp row contains \"350/500\"", hp_idx ~= nil, all)
if hp_idx then
  local hp_line = lines[hp_idx]
  check("that hp row contains bar glyphs (# and -)",
        hp_line:find("#", 1, true) ~= nil and hp_line:find("%-%-") ~= nil, hp_line)
end

-- ---- section headers present, in order --------------------------------------
local section_order = { "Vitals", "Ledung / Chain", "God", "Saga XP", "Enemy", "Active Effects" }
local last_idx = 0
local order_ok = true
local missing
for _, name in ipairs(section_order) do
  local idx = find_line(lines, name)
  if not idx then
    order_ok = false
    missing = name
  elseif idx <= last_idx then
    order_ok = false
    missing = name .. " (out of order)"
  else
    last_idx = idx
  end
end
check("every section header present, in order", order_ok, missing)

-- ---- enemy row shows en5 + ens ----------------------------------------------
local enemy_idx = find_line(lines, "Wolf")
check("an enemy row mentions en5 (Wolf)", enemy_idx ~= nil, all)
if enemy_idx then
  check("the same/adjacent enemy content mentions ens (low)",
        (lines[enemy_idx]:find("low", 1, true) ~= nil)
        or (lines[enemy_idx + 1] and lines[enemy_idx + 1]:find("low", 1, true) ~= nil),
        lines[enemy_idx] .. " / " .. tostring(lines[enemy_idx + 1]))
end

-- ---- saga section vanishes when show_stats_xp is off ------------------------
page_opts.set("show_stats_xp", false)
local lines_no_xp = stats_page.lines(WIDTH)
check("Saga XP header disappears when show_stats_xp is off",
      find_line(lines_no_xp, "Saga XP") == nil)
check("session-gained content disappears too",
      find_line(lines_no_xp, "Session gained") == nil)
page_opts.set("show_stats_xp", true)
local lines_xp_back = stats_page.lines(WIDTH)
check("Saga XP header reappears once the opt is back on",
      find_line(lines_xp_back, "Saga XP") ~= nil)

-- ---- stfx section vanishes when show_stats_buffs is off ---------------------
page_opts.set("show_stats_buffs", false)
local lines_no_buffs = stats_page.lines(WIDTH)
check("Active Effects header disappears when show_stats_buffs is off",
      find_line(lines_no_buffs, "Active Effects") == nil)
check("the stfx entry itself (ein:54) disappears too",
      find_line(lines_no_buffs, "ein:54") == nil)
page_opts.set("show_stats_buffs", true)
local lines_buffs_back = stats_page.lines(WIDTH)
check("Active Effects header reappears once the opt is back on",
      find_line(lines_buffs_back, "Active Effects") ~= nil)
check("the stfx entry (ein:54) reappears too",
      find_line(lines_buffs_back, "ein:54") ~= nil)

-- ---- Active Effects also vanishes with an empty stfx list, opt still on ----
local saved_stfx = S.stfx
S.stfx = {}
local lines_no_effects = stats_page.lines(WIDTH)
check("Active Effects header absent when stfx is empty (even with the opt on)",
      find_line(lines_no_effects, "Active Effects") == nil)
S.stfx = saved_stfx

-- ---- combat.lua's exported STFX category metadata is what the page uses ----
check("combat.lua exports STFX_CAT_ORDER", type(combat.STFX_CAT_ORDER) == "table"
      and #combat.STFX_CAT_ORDER == 5)
check("combat.lua exports STFX_CAT_LABELS", type(combat.STFX_CAT_LABELS) == "table"
      and combat.STFX_CAT_LABELS.Def == "Def")

-- ---- width is respected: every emitted row's visible width <= width --------
local width_ok = true
local widest
for _, l in ipairs(lines) do
  local vw = pagelib.visible_width(l)
  if vw > WIDTH then
    width_ok = false
    widest = vw
  end
end
check("every row's visible width is <= the requested width", width_ok, widest)

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING PAGES1 TESTS PASSED")
