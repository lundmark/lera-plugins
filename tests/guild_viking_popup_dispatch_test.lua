-- Dispatch-layer tests for the guild_viking popups, driven through the REAL
-- scripts/default/popup.lua -- not the direct on_pointer(ev, ctx) calls
-- every per-popup unit suite (guild_viking_popup_war_test.lua and friends)
-- uses. This is fix round 2's Fix 0, the systemic gap the whole-branch
-- review named as the enabler for both Critical findings: popup.lua's real
-- dispatch has its OWN capture/hit-test rules (a "down" must return `true`
-- for the popup layer to ever deliver the matching "up" at all; a captured
-- "up" is delivered at whatever coordinates the release landed on, not
-- re-hit-tested against the down) -- rules no test exercised before this
-- file, which is exactly how war_campaign.lua's down-not-consumed bug
-- (Critical #1) and war_battle.lua's fixed-probe-width bug (Critical #2)
-- both shipped invisibly: calling on_pointer directly with a synthetic "up"
-- event, as every per-popup suite does, bypasses popup.lua's capture logic
-- entirely and cannot see either one.
--
-- Run from the lera-plugins repo root (plugins/, matching run_tests.sh's
-- cwd) with LERA_ROOT pointing at a built Lera checkout. The path below
-- reaches scripts/default/popup.lua at "../scripts/default" relative to
-- that cwd -- see tests/popup_test.lua (run from the LERA repo root
-- instead, hence its own "scripts/default/?.lua" prefix with no "..") for
-- the same module loaded the other way.
package.path = "3scapes/guild_viking/?.lua;../scripts/default/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

local function find_plain(lines, needle)
  for _, l in ipairs(lines) do
    if l:find(needle, 1, true) then return true end
  end
  return false
end

-- ---- stub globals: ui/lera/bind (scripts/default/popup.lua's own deps,
-- copied from tests/popup_test.lua's preamble) plus mud/buffer/menu (the
-- guild_viking popup modules' deps, copied from the per-popup suites). ----
local function make_rect(x, y, w, h)
  return {
    x = function() return x end, y = function() return y end,
    w = function() return w end, h = function() return h end,
  }
end

local dirty_count = 0
local drawn
local function reset_drawn() drawn = { boxes = {}, ansi = {} } end
reset_drawn()

ui = {
  dirty = function() dirty_count = dirty_count + 1 end,
  rect = function(x, y, w, h) return make_rect(x, y, w, h) end,
  shrink = function(r, n) return make_rect(r:x() + n, r:y() + n, r:w() - 2 * n, r:h() - 2 * n) end,
  box = function(r, style, title)
    drawn.boxes[#drawn.boxes + 1] = { x = r:x(), y = r:y(), w = r:w(), h = r:h() }
  end,
  text = function() end,
  text_ansi = function(r, s) drawn.ansi[#drawn.ansi + 1] = { x = r:x(), y = r:y(), s = s } end,
}

local render_pass = "local"
lera = { render_pass = function() return render_pass end, time = function() return 1000 end,
         version = function() return "test" end }

local bind_enabled = {}
local bind_defs = {}
bind = {
  add = function(key, fn)
    bind_defs[#bind_defs + 1] = { key = key, fn = fn }
    return #bind_defs
  end,
  enable = function(id, on) bind_enabled[id] = on end,
}

local send_calls = {}
mud = { send = function(s) send_calls[#send_calls + 1] = s end }

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

local last_menu_open = nil
package.loaded["menu"] = {
  open = function(opts) last_menu_open = opts end,
  close = function() last_menu_open = nil end,
  is_open = function() return last_menu_open ~= nil end,
}
local function menu_has_label(opts, substr)
  for _, it in ipairs(opts.items or {}) do
    if tostring(it.label):find(substr, 1, true) then return true end
  end
  return false
end

-- ---- the REAL popup overlay, wired as require("wm").popup -----------------
-- Sandboxed/trusted composition code (popups.lua) reaches the popup surface
-- through require("wm").popup.{open,close,is_open} (CLAUDE.md "Popup
-- Overlay"); this delegates every one of those three straight to the real
-- module loaded from ../scripts/default/popup.lua, so popups.lua's own
-- open_wrapper/toggle call the REAL open()/close()/is_open() -- the one
-- thing every other guild_viking popup test suite stubs away.
local real_popup = require("popup")
package.loaded["wm"] = {
  popup = {
    open = real_popup.open,
    close = real_popup.close,
    is_open = real_popup.is_open,
  },
}

-- ---- real ingestion pipeline (protocol.ingest -> handlers), same standing
-- lesson as every other guild_viking popup suite: fixtures MUST route
-- through the real handlers, never direct S. pokes.
local state = require("state")
local protocol = require("protocol")
local kingdom = require("handlers.kingdom")
for key, fn in pairs(kingdom) do
  if key ~= "_patterns" then protocol.handler(key, fn) end
end
for _, p in ipairs(kingdom._patterns or {}) do
  protocol.pattern_handler(p.pattern, p.fn)
end

local S = state.S

-- popups.lua self-registers map/sea/voyage/cityplan/war against the "wm"
-- stub above at require-time.
local popups = require("popups")
local war_campaign = require("popups.war_campaign")
local war_battle = require("popups.war_battle")

-- seed_wmap/seed_battle: copied verbatim from
-- guild_viking_popup_war_test.lua (same wire-format helpers, so a fixture
-- written here is directly comparable to that suite's own).
local function seed_wmap(t)
  protocol.ingest("WMAP", table.concat({
    (t.active ~= false) and 1 or 0, t.dim or 0, t.turn or 0, t.mode or "offense",
    t.pending or 0, t.town or "", t.works_budget or 0, t.march_eta or 0,
  }, "|"))
  for wire_row, row in ipairs(t.rows or {}) do
    protocol.ingest(string.format("WMR%02d", wire_row - 1), row)
  end
  if t.units and #t.units > 0 then
    local parts = {}
    for _, u in ipairs(t.units) do
      local entry = u.id .. ":" .. (u.c or 0) .. "," .. (u.r or 0) .. "," .. (u.size or 0)
      if u.f and u.f ~= "" then entry = entry .. "," .. u.f end
      parts[#parts + 1] = entry
    end
    protocol.ingest("WMO", table.concat(parts, ";"))
  end
  protocol.ingest("WMEND", tostring(#(t.rows or {})))
end

local function seed_battle(t)
  local units_parts = {}
  for _, u in ipairs(t.units or {}) do
    if u.side == "R" then
      units_parts[#units_parts + 1] = table.concat(
        { "R", u.label or "", u.size or 0, u.uid or 0, u.cost or 0, u.leader or "" }, ",")
    else
      units_parts[#units_parts + 1] = table.concat({
        u.side or "Y", u.label or "", u.size or 0, u.coord or "", u.morale or 0,
        u.utype or "", u.leader or "", u.bid or 0, u.ord or 0,
      }, ",")
    end
  end
  local wh = string.format("%d:%d:%d", t.width or 8, t.height or 8, t.dz or 2)
  local budg = string.format("%d:%d", t.budget or 0, t.spent or 0)
  local terrain = table.concat(t.terrain_rows or {}, "")
  local works = table.concat(t.works_rows or {}, "")
  protocol.ingest("BATTLE", table.concat({
    (t.active ~= false) and 1 or 0,
    t.phase or "deploy", t.turn or 0, t.war_points or 0, t.mode or "field", t.target or "",
    budg, wh, terrain, works, table.concat(units_parts, ";"),
  }, "|"))
end

-- ---- popup.lua's OWN private box-geometry math, replicated here so this
-- test can convert a popup-LOCAL (lx, ly) -- the same coordinate space
-- on_pointer's `ev.x`/`ev.y` already use -- into the SCREEN (col, row) a
-- real pointer event carries, exactly the conversion wm.lua's own pointer
-- routing would perform before calling popup.handle_pointer. popups.lua's
-- open_wrapper always opens at width=0.9, height=0.9 (never configurable
-- per named popup), so hardcoding those two fractions here is safe and
-- stable, not a guess.
local function resolve(dim, total)
  local n
  if dim <= 1 then n = math.floor(total * dim + 0.5) else n = math.floor(dim) end
  if n > total then n = total end
  if n < 3 then n = math.min(3, total) end
  return n
end

local function box_geometry(root_w, root_h)
  local w = resolve(0.9, root_w)
  local h = resolve(0.9, root_h)
  local x = math.floor((root_w - w) / 2)
  local y = math.floor((root_h - h) / 2)
  return x, y, w, h
end

local function to_screen(root_w, root_h, lx, ly)
  local x, y = box_geometry(root_w, root_h)
  return x + 1 + lx, y + 1 + ly
end

-- maplib.lua's own fixed pitch (maplib.lua's cell_at: `c = math.floor(bx /
-- 3)`) -- each grid cell occupies a 3-column field (a 2-char glyph slot
-- plus one east-edge slot), and neither war_campaign.lua nor war_battle.lua
-- passes col_headers/row_headers (both call maplib.render/geometry with
-- `{}`), so the grid's own body starts at wrapper-local column 0 with no
-- header offset to add. Converts a grid column `gc` to the wrapper-local x
-- to hand to to_screen -- clicking anywhere in the glyph's own 2 columns
-- (this uses the first) hits the cell; the 3rd column is the edge slot.
local function cell_lx(gc) return gc * 3 end

-- =============================================================================
-- Scenario A (Critical #1 RED before the fix): campaign select-own-stack,
-- then queue-a-waypoint, via REAL down->up pairs through popup.lua's actual
-- capture/hit-test dispatch. Before the fix, war_campaign.on_pointer's
-- "down" case returned nil (unconsumed) -- popup.lua therefore never
-- captures the pointer, and the matching "up" is swallowed one layer up
-- (handle_pointer's own `return false` for an uncaptured, non-down,
-- non-move event) -- on_pointer's "up" branch, and therefore
-- viking_campaign_click's whole select/queue/send flow, was NEVER REACHED.
-- =============================================================================
do
  seed_wmap({
    dim = 3, town = "Jorvik", rows = { "...", "...", "..." },
    units = { { id = "A", c = 0, r = 0, size = 10 } },
  })
  check("war_map seeded and active", S.war_map ~= nil and S.war_map.active == true)
  check("popups.toggle('war') opens the campaign map (no battle yet)",
    popups.toggle("war") == true)

  local root_w, root_h = 100, 30
  local root = ui.rect(0, 0, root_w, root_h)
  real_popup.render(root)
  local _, _, bw = box_geometry(root_w, root_h)
  local inner_w = bw - 2

  local off = war_campaign.grid_line_offset(inner_w)

  -- Down+up on (0,0) -- the host's own cell -- selects it.
  local dcol, drow = to_screen(root_w, root_h, cell_lx(0), off + 0)
  send_calls = {}
  check("a REAL down on the host's own cell consumes",
    real_popup.handle_pointer({ kind = "down", button = "left", x = dcol, y = drow }) == true)
  check("a REAL up on the SAME cell also consumes (this is the fix: previously unreachable)",
    real_popup.handle_pointer({ kind = "up", button = "left", x = dcol, y = drow }) == true)
  check("selecting via the real dispatch path never sends", #send_calls == 0)
  check("war_campaign now shows 'Selected A' after a REAL down+up pair",
    find_plain(war_campaign.lines(inner_w), "Selected A"))

  -- Queue a waypoint at grid (1,1) ("B2") via a second real down+up pair.
  local qcol, qrow = to_screen(root_w, root_h, cell_lx(1), off + 1)
  send_calls = {}
  real_popup.handle_pointer({ kind = "down", button = "left", x = qcol, y = qrow })
  real_popup.handle_pointer({ kind = "up", button = "left", x = qcol, y = qrow })
  check("queuing a waypoint via the REAL dispatch path sends the exact command",
    #send_calls == 1 and send_calls[1] == "vcampaign queue A B2", send_calls[1])

  real_popup.close()
  check("scenario A: popup closed cleanly", real_popup.is_open() == false)
end

-- =============================================================================
-- Scenario B (Critical #2 RED before the fix): battle [Actions] line at a
-- REAL popup width (~88 inner columns, the default gui_cols=100 case) vs
-- the 76-column probe war_battle.actions_line_index used to default to
-- unconditionally inside on_pointer. maplib.legend wraps by width, so the
-- [Actions] line's own index shifts between these two widths -- clicking
-- its TRUE on-screen row must open the actions menu.
-- =============================================================================
do
  seed_battle({
    phase = "deploy", target = "Fjordvik", width = 3, height = 2, dz = 1,
    terrain_rows = { "..#", "^*w" }, works_rows = { "v.u", "..." },
  })
  check("battle seeded and active (deploy phase)", S.battle ~= nil and S.battle.phase == "deploy")
  check("popups.toggle('war') now opens the battle board (battle takes priority)",
    popups.toggle("war") == true)

  local root_w, root_h = 100, 30
  local root = ui.rect(0, 0, root_w, root_h)
  real_popup.render(root)
  local _, _, bw = box_geometry(root_w, root_h)
  local inner_w = bw - 2
  check("popup inner width is the real-world figure this bug needs (~88 cols)",
    inner_w == 88, inner_w)

  local idx76 = war_battle.actions_line_index(76)
  local idx_real = war_battle.actions_line_index(inner_w)
  check("the [Actions] line's index genuinely differs by width (legend wrap)",
    idx76 ~= idx_real, idx76 .. " (@76) vs " .. tostring(idx_real) .. " (@" .. inner_w .. ")")

  local col, row = to_screen(root_w, root_h, 0, idx_real - 1)
  last_menu_open = nil
  check("a real down on the TRUE (real-width) [Actions] row consumes",
    real_popup.handle_pointer({ kind = "down", button = "left", x = col, y = row }) == true)
  check("it opens the deploy-phase actions menu (the fix threads the real ev.width through)",
    last_menu_open ~= nil and menu_has_label(last_menu_open, "Begin Battle"),
    last_menu_open)

  real_popup.close()
  check("scenario B: popup closed cleanly (a live capture is auto-cancelled)",
    real_popup.is_open() == false)
end

-- =============================================================================
-- Scenario C (Important #1 / cross-target drag): a down on the REAL
-- [Actions] row followed by an up released over a DIFFERENT target (a grid
-- cell) must NOT fire that cell's action -- only the target that took the
-- mousedown gets the mouseup, exactly LEGACY's own hotspot semantics
-- (popups/pointer_track.lua's header comment). Turn phase, so a leaked
-- cross-target send would be observable as a "vbattle order" command.
-- =============================================================================
do
  seed_battle({
    phase = "turn", turn = 4, target = "Fjordvik", width = 2, height = 2, dz = 1,
    budget = 100, spent = 40, war_points = 22,
    terrain_rows = { "..", ".." },
    units = {
      { side = "Y", label = "Shieldwall", size = 10, coord = "A1", morale = 70,
        utype = "shieldwall", bid = 201 },
      { side = "N", label = "Levy Rabble", size = 12, coord = "B2", morale = 40,
        utype = "foe_levy" },
    },
  })
  check("battle turn-phase seeded", S.battle ~= nil and S.battle.phase == "turn")
  check("popups.toggle('war') opens the battle board (turn phase)",
    popups.toggle("war") == true)

  local root_w, root_h = 100, 30
  local root = ui.rect(0, 0, root_w, root_h)
  real_popup.render(root)
  local _, _, bw = box_geometry(root_w, root_h)
  local inner_w = bw - 2
  local off = war_battle.grid_line_offset(inner_w)

  -- Select the own unit at A1 (gc=0, gr=1) via a real matched down+up pair.
  local scol, srow = to_screen(root_w, root_h, cell_lx(0), off + 1)
  send_calls = {}
  real_popup.handle_pointer({ kind = "down", button = "left", x = scol, y = srow })
  real_popup.handle_pointer({ kind = "up", button = "left", x = scol, y = srow })
  check("selecting the own unit via the real dispatch path never sends", #send_calls == 0)

  -- Cross-target drag: down on the REAL [Actions] row, release over the
  -- enemy's cell (B2, gc=1, gr=0).
  local idx = war_battle.actions_line_index(inner_w)
  local acol, arow = to_screen(root_w, root_h, 0, idx - 1)
  last_menu_open = nil
  real_popup.handle_pointer({ kind = "down", button = "left", x = acol, y = arow })
  check("down on the real [Actions] row opens the turn-phase menu",
    last_menu_open ~= nil and menu_has_label(last_menu_open, "Advance Turn"))

  local ecol, erow = to_screen(root_w, root_h, cell_lx(1), off + 0)
  send_calls = {}
  real_popup.handle_pointer({ kind = "up", button = "left", x = ecol, y = erow })
  check("releasing over the enemy cell after an [Actions] down sends NOTHING",
    #send_calls == 0, send_calls[1])

  -- The selection survives the mismatched drag untouched: a genuinely
  -- matched down+up on the SAME enemy cell right after it still orders the
  -- move -- proving the guard rejects only the mismatch, not selections in
  -- general.
  real_popup.handle_pointer({ kind = "down", button = "left", x = ecol, y = erow })
  real_popup.handle_pointer({ kind = "up", button = "left", x = ecol, y = erow })
  check("a real matched down+up right after still sends the exact order command",
    #send_calls == 1 and send_calls[1] == "vbattle order 201 B2", send_calls[1])

  real_popup.close()
  check("scenario C: popup closed cleanly", real_popup.is_open() == false)
end

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING POPUP DISPATCH TESTS PASSED")
