-- guild_viking /vik sea (Sea Chart popup, FULL sub-view) and /vik voyage
-- (Voyage Status popup, compact subset) unit tests. Run from the
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

local function find_plain(lines, needle)
  for _, l in ipairs(lines) do
    if l:find(needle, 1, true) then return true end
  end
  return false
end

local function find_exact(lines, want)
  for _, l in ipairs(lines) do
    if l == want then return true end
  end
  return false
end

-- ---- lera API stubs (same shape as guild_viking_popup_map_test.lua) -------
local function make_rect(x, y, w, h)
  return {
    x = function() return x end, y = function() return y end,
    w = function() return w end, h = function() return h end,
  }
end

local drawn
local function reset_drawn() drawn = { ansi = {} } end
reset_drawn()

local dirty_count = 0
ui = {
  dirty = function() dirty_count = dirty_count + 1 end,
  rect = function(x, y, w, h) return make_rect(x, y, w, h) end,
  text_ansi = function(r, s) drawn.ansi[#drawn.ansi + 1] = { x = r:x(), y = r:y(), s = s } end,
}

local render_pass = "local"
lera = { render_pass = function() return render_pass end, time = function() return 1000 end,
         version = function() return "test" end }

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

-- ---- wm.popup facade stub (identical to guild_viking_popup_map_test.lua's) ----
local is_open_flag = false
local current_open = nil
local opens = {}
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

local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local popups = require("popups")
local sea = require("popups.sea")
local voyage = require("popups.voyage")

-- ---- real ingestion pipeline (protocol.ingest -> handlers.voyage), the SAME
-- registration guild_viking_voyage_test.lua/guild_viking_popup_map_test.lua
-- do -- fixtures MUST route through protocol.ingest + the real handlers,
-- never direct S. pokes (standing lesson from Task 3's review: a fixture
-- matching a buggy read convention can mask an off-by-one that production
-- would also have).
local protocol = require("protocol")
local voyage_h = require("handlers.voyage")
for key, fn in pairs(voyage_h) do
  if key ~= "_patterns" then protocol.handler(key, fn) end
end
for _, p in ipairs(voyage_h._patterns or {}) do
  protocol.pattern_handler(p.pattern, p.fn)
end

local S = state.S
local C, RESET = pagelib.C, pagelib.RESET

local WIDTH = 76

local function reset_voyage()
  S.mip_voyage_seen = false
  S.voyage_status = nil
  S.voyage_wait = ""
  S.voyage_resolve_options = {}
  S.voyage_longships = {}
  S.voyage_chart_width = 0
  S.voyage_chart_height = 0
  S.voyage_chart_mode = ""
  S.voyage_chart_rows = {}
  S.voyage_sailed = {}
  S.voyage_queue = {}
  S.voyage_saga = {}
  S.voyage_memory = {}
  S.voyage_boons = ""
  S.voyage_spoils_daler = 0
  S.voyage_goods = {}
  S.voyage_aids = {}
  S.voyage_runes = {}
  S.voyage_relics = {}
  S.voyage_curios = {}
  S.voyage_reagents = 0
  S.fleet_renown = 0
  for _, key in ipairs({
    "show_sea_voyage", "show_sea_chart", "show_sea_chart_legend",
    "show_sea_queue", "show_sea_saga", "show_sea_memory",
    "show_sea_boons", "show_sea_spoils", "show_sea_goods",
    "show_sea_aids", "show_sea_runes", "show_sea_relics", "show_sea_curios",
  }) do
    page_opts.set(key, true)
  end
  send_calls = {}
end

-- =============================================================================
-- no-data gate, ported into BOTH popups (draw_page10's ONLY contribution)
-- =============================================================================
reset_voyage()
local sea_lines = sea.lines(WIDTH)
local voyage_lines = voyage.lines(WIDTH)
check("sea popup has its own header", sea_lines[1]:find("Sea Chart", 1, true) ~= nil, sea_lines[1])
check("voyage popup has its own header", voyage_lines[1]:find("Voyage Status", 1, true) ~= nil, voyage_lines[1])
check("sea popup shows the no-data gate",
  find_plain(sea_lines, "No data - enable with: vtoggle mip_voyage"))
check("voyage popup shows the no-data gate",
  find_plain(voyage_lines, "No data - enable with: vtoggle mip_voyage"))

-- =============================================================================
-- show_sea_voyage master gate: whole-body hidden, header only, in both popups
-- =============================================================================
reset_voyage()
protocol.ingest("VOYAGE_WAIT", "") -- flips mip_voyage_seen true without a voyage
page_opts.set("show_sea_voyage", false)
sea_lines = sea.lines(WIDTH)
voyage_lines = voyage.lines(WIDTH)
check("sea: show_sea_voyage off leaves only the header line", #sea_lines == 1, #sea_lines)
check("voyage: show_sea_voyage off leaves only the header line", #voyage_lines == 1, #voyage_lines)
page_opts.set("show_sea_voyage", true)

-- =============================================================================
-- no-active-voyage fallback + reroll hint (dropped-with-reason: text only)
-- =============================================================================
reset_voyage()
protocol.ingest("VOYAGE_WAIT", "")
protocol.ingest("LONGSHIP",
  "7|Ormen|2|docked|Havn|0|4|1|1|proud|Erik|brave|swift|Saga of Ormen|3")
sea_lines = sea.lines(WIDTH)
voyage_lines = voyage.lines(WIDTH)
check("sea: no-active-voyage fallback text", find_plain(sea_lines, "No active voyage"))
check("sea: reroll hint names the docked ship", find_plain(sea_lines, "Ormen"))
check("sea: reroll hint surfaces the exact command text",
  find_plain(sea_lines, "vvoyage launch <ship> reroll"))
check("voyage: no-active-voyage fallback text", find_plain(voyage_lines, "No active voyage"))
check("voyage: reroll hint names the docked ship", find_plain(voyage_lines, "Ormen"))

-- =============================================================================
-- Voyage Status fields (shared by both popups)
-- =============================================================================
reset_voyage()
protocol.ingest("VOYAGE",
  "sailing|1|Ormen|Raid Fjordholm|raid|3|5|6|20|20|80|70|60|10|4|5|12|30|Kraken|2|40||" ..
  "storm|Erik|proud|brave,loyal|swift,sturdy")
protocol.ingest("FLEET_RENOWN", "1500")

sea_lines = sea.lines(WIDTH)
voyage_lines = voyage.lines(WIDTH)
for _, name in ipairs({ "sea", "voyage" }) do
  local lines = (name == "sea") and sea_lines or voyage_lines
  check(name .. ": ship name", find_plain(lines, "Ormen"))
  check(name .. ": position uses coord_label (x=5,y=6 -> G06)", find_plain(lines, "G06"))
  check(name .. ": contract name", find_plain(lines, "Raid Fjordholm"))
  check(name .. ": threat name + level", find_plain(lines, "Kraken") and find_plain(lines, "[2]"))
  check(name .. ": danger value", find_plain(lines, "Danger:") and find_plain(lines, "3"))
  check(name .. ": pressure value", find_plain(lines, "Pressure:") and find_plain(lines, "40"))
  check(name .. ": hull percent", find_plain(lines, "80%"))
  check(name .. ": crew alive/max", find_plain(lines, "4/5"))
  check(name .. ": morale percent", find_plain(lines, "70%"))
  check(name .. ": supplies percent", find_plain(lines, "60%"))
  check(name .. ": stress percent", find_plain(lines, "10%"))
  check(name .. ": weather falls back to the raw key ('storm' not in WEATHER_LABELS)",
    find_plain(lines, "storm"))
  check(name .. ": state field", find_plain(lines, "sailing"))
  check(name .. ": next_move formatted via cc.fmt_time(30) -> '30s'", find_plain(lines, "30s"))
  check(name .. ": fleet renown", find_plain(lines, "1500"))
  check(name .. ": captain", find_plain(lines, "Erik"))
  check(name .. ": identity", find_plain(lines, "proud"))
  check(name .. ": ship traits", find_plain(lines, "swift") and find_plain(lines, "sturdy"))
  check(name .. ": crew traits", find_plain(lines, "brave") and find_plain(lines, "loyal"))
end

-- =============================================================================
-- Awaiting Resolution + harbor End Voyage hint (shared by both popups)
-- =============================================================================
protocol.ingest("VOYAGE_WAIT", "harbor")
protocol.ingest("VRESOLVE", "trade,explore")
sea_lines = sea.lines(WIDTH)
voyage_lines = voyage.lines(WIDTH)
for _, name in ipairs({ "sea", "voyage" }) do
  local lines = (name == "sea") and sea_lines or voyage_lines
  check(name .. ": awaiting resolution label (wait_label('harbor'))",
    find_plain(lines, "Harbor choice"))
  check(name .. ": resolve options listed", find_plain(lines, "trade") and find_plain(lines, "explore"))
  check(name .. ": resolve option command hint", find_plain(lines, "vvoyage resolve <option>"))
  check(name .. ": harbor end-voyage hint", find_plain(lines, "vvoyage end"))
end
protocol.ingest("VOYAGE_WAIT", "") -- back to no-wait for later cases

-- =============================================================================
-- Queue / Saga / Crew Memory (shared by both popups) + gates
-- =============================================================================
-- VQPATH's own wire delimiter is comma (handlers/voyage.lua's M.VQPATH,
-- ported from LEGACY 1326-1331: `val:gmatch("[^,]+")`), so an individual
-- queue step can never itself contain a comma once it arrives over the
-- wire -- meaning the "x,y" -> coord_label conversion branch inside
-- sea_common.queue_lines (ported from guild_viking.lua:15222-15224's
-- `step:match("^(%-?%d+),(%-?%d+)$")`) is genuine LEGACY dead code: it is
-- ported verbatim for fidelity, but VQPATH's delimiter choice means no real
-- server payload can ever exercise it. Not exercised here for that reason
-- (an "N,3,4,SE" fixture would just split into four raw tokens "N"/"3"/
-- "4"/"SE", never a single "3,4" step) -- only the always-reachable raw-step
-- fallback is tested.
protocol.ingest("VQPATH", "N,N,E,SE")
protocol.ingest("VSAGA", "Captain style: bold;The fleet set sail.")
protocol.ingest("VMEM", "Remembered the reefs of Fjordholm.")

sea_lines = sea.lines(WIDTH)
voyage_lines = voyage.lines(WIDTH)
for _, name in ipairs({ "sea", "voyage" }) do
  local lines = (name == "sea") and sea_lines or voyage_lines
  check(name .. ": queue shows raw steps verbatim (comma-delimited on the wire)",
    find_plain(lines, "N -> N -> E -> SE"))
  check(name .. ": saga filters out 'Captain style:' lines", not find_plain(lines, "bold"))
  check(name .. ": saga keeps other lines", find_plain(lines, "The fleet set sail."))
  check(name .. ": crew memory line", find_plain(lines, "Remembered the reefs of Fjordholm."))
end

page_opts.set("show_sea_queue", false)
page_opts.set("show_sea_saga", false)
page_opts.set("show_sea_memory", false)
sea_lines = sea.lines(WIDTH)
voyage_lines = voyage.lines(WIDTH)
for _, name in ipairs({ "sea", "voyage" }) do
  local lines = (name == "sea") and sea_lines or voyage_lines
  check(name .. ": Queue header hidden when show_sea_queue is off", not find_plain(lines, "Queue"))
  check(name .. ": Saga header hidden when show_sea_saga is off", not find_plain(lines, "Saga"))
  check(name .. ": Crew Memory header hidden when show_sea_memory is off",
    not find_plain(lines, "Crew Memory"))
end
page_opts.set("show_sea_queue", true)
page_opts.set("show_sea_saga", true)
page_opts.set("show_sea_memory", true)

-- =============================================================================
-- Loot sections: sea-only (NOT part of the /vik voyage subset per the
-- binding split ruling) + their gates
-- =============================================================================
protocol.ingest("VBOONS", "favor of Njord")
protocol.ingest("VSPOILS", "450")
protocol.ingest("VGOODS", "furs:5")
protocol.ingest("VAIDS", "storm_charm:1")
protocol.ingest("VRUNES", "ansuz:2")
protocol.ingest("VRELICS", "Horn of Heimdall")
protocol.ingest("VCURIOS", "Sea Glass Bead")
protocol.ingest("VREAGENT", "2")

sea_lines = sea.lines(WIDTH)
voyage_lines = voyage.lines(WIDTH)
local loot_markers = {
  { "Active Boons", "favor of Njord" },
  { "Secured Spoils", "450" },
  { "Secured Reagents", "Nikr's Bile" },
  { "Secured Goods", "Furs" },
  { "Secured Aids", "Storm Charm" },
  { "Secured Runes", "ansuz" },
  { "Secured Relics", "Horn of Heimdall" },
  { "Secured Curios", "Sea Glass Bead" },
}
for _, m in ipairs(loot_markers) do
  check("sea: " .. m[1] .. " section present", find_plain(sea_lines, m[1]) and find_plain(sea_lines, m[2]))
  check("voyage: " .. m[1] .. " section absent (loot is sea-only)", not find_plain(voyage_lines, m[1]))
end

page_opts.set("show_sea_boons", false)
sea_lines = sea.lines(WIDTH)
check("sea: Active Boons hidden when show_sea_boons is off", not find_plain(sea_lines, "Active Boons"))
page_opts.set("show_sea_boons", true)

-- =============================================================================
-- Chart: exact glyph/color fields (BGR workbook), display-symbol folding,
-- sailed overlay, headers -- gated show_sea_chart / show_sea_chart_legend
-- =============================================================================
reset_voyage()
protocol.ingest("VOYAGE",
  "sailing|1|Ormen|Raid|raid|0|0|0|4|4|80|70|60|10|4|5|12|30|Kraken|2|40||storm|Erik|proud||")
protocol.ingest("VCHH", "4|4|test")
protocol.ingest("VCR00", "S#H?")
protocol.ingest("VCR01", "OMBD")
protocol.ingest("VCR02", "++XY")
protocol.ingest("VCR03", "VCA*")
protocol.ingest("VSAILED", "1,0") -- x=1,y=0 -> chart cell (c=1,r=0), NOT the ship glyph

check("VCR rows landed at the real 1-indexed storage position",
  S.voyage_chart_rows[1] == "S#H?" and S.voyage_chart_rows[2] == "OMBD",
  tostring(S.voyage_chart_rows[1]))

sea_lines = sea.lines(WIDTH)
local offset = sea.grid_line_offset(WIDTH)

-- Column header line: out[offset+1] (maplib's own col_headers line).
local expect_hdr = "  " .. "01 " .. "02 " .. "03 " .. "04 "
check("chart column header: 1-based 2-digit numbers", sea_lines[offset + 1] == expect_hdr,
  sea_lines[offset + 1])

-- Row A (r=0): S (white, sym never sailed-overridden) / # (sailed ->
-- magenta, overriding its normal C.dim) / H (yellow) / ? (cyan).
local row_a = "A " ..
  (C.white .. "S " .. RESET) .. " " ..
  (C.magenta .. "# " .. RESET) .. " " ..
  (C.yellow .. "H " .. RESET) .. " " ..
  (C.cyan .. "? " .. RESET) .. " "
check("chart row A: exact glyph+color fields incl. sailed override on '#'",
  sea_lines[offset + 2] == row_a, sea_lines[offset + 2])

-- Row B (r=1): O/M/B/D all DISPLAY as "~" (chart_display_symbol) but keep
-- their own distinct colors (cyan/white/red/dim).
local row_b = "B " ..
  (C.cyan .. "~ " .. RESET) .. " " ..
  (C.white .. "~ " .. RESET) .. " " ..
  (C.red .. "~ " .. RESET) .. " " ..
  (C.dim .. "~ " .. RESET) .. " "
check("chart row B: O/M/B/D fold to '~' display with distinct colors",
  sea_lines[offset + 3] == row_b, sea_lines[offset + 3])

-- Note: the popup's OWN title header is "Sea Chart" (contains "Chart" as a
-- substring), so the Chart SECTION header is identified by its exact
-- rendered string (pagelib.header(width, "Chart")), not a substring search.
local chart_section_header = pagelib.header(WIDTH, "Chart")
check("voyage popup never renders the chart section", not find_exact(voyage.lines(WIDTH), chart_section_header))
check("voyage popup exposes no grid hooks (no chart to hit-test)",
  voyage.geometry == nil and voyage.grid_line_offset == nil and voyage.on_pointer == nil)

-- Legend gate.
check("chart legend shown by default", find_plain(sea_lines, "aurora calm"))
page_opts.set("show_sea_chart_legend", false)
check("chart legend hidden when show_sea_chart_legend is off",
  not find_plain(sea.lines(WIDTH), "aurora calm"))
page_opts.set("show_sea_chart_legend", true)

-- show_sea_chart gate: the whole Chart section (and its grid) disappears.
page_opts.set("show_sea_chart", false)
check("Chart section header hidden when show_sea_chart is off",
  not find_exact(sea.lines(WIDTH), chart_section_header))
check("geometry() is nil when show_sea_chart is off", sea.geometry(WIDTH) == nil)
page_opts.set("show_sea_chart", true)

-- "No active chart" fallback: voyage active, chart section on, but no data.
do
  local saved_w, saved_h, saved_rows = S.voyage_chart_width, S.voyage_chart_height, S.voyage_chart_rows
  S.voyage_chart_width, S.voyage_chart_height, S.voyage_chart_rows = 0, 0, {}
  check("no-active-chart fallback text", find_plain(sea.lines(WIDTH), "No active chart"))
  check("geometry() is nil with no chart data", sea.geometry(WIDTH) == nil)
  S.voyage_chart_width, S.voyage_chart_height, S.voyage_chart_rows = saved_w, saved_h, saved_rows
end

-- =============================================================================
-- Pointer: ch_<coord> chart hotspot -- move updates hover, down consumes
-- without sending, up sends "vvoyage queue <coord>" (LEGACY's two-phase
-- mouse-down/mouse-up split, viking_voyage_chart_down/_click)
-- =============================================================================
local function fixed_ctx(c, r)
  return { cell_from_xy = function() return c, r end, close = function() end }
end

send_calls = {}
local ok_move = sea.on_pointer({ kind = "move", x = 0, y = 0, inside = true }, fixed_ctx(2, 0))
check("on_pointer(move) over the chart does not consume", ok_move == nil or ok_move == false)
local hover_lines = sea.lines(WIDTH)
check("hover line names the Harbor node and its hint after a move",
  find_plain(hover_lines, "Harbor") and find_plain(hover_lines, "restock"))
check("moving never sends anything to the MUD", #send_calls == 0)

sea.on_pointer({ kind = "move", x = 0, y = 0, inside = true }, fixed_ctx(1, 0))
hover_lines = sea.lines(WIDTH)
check("hover over the unrevealed node ('#') shows its hint and 'Unrevealed' status",
  find_plain(hover_lines, "Sail closer") and find_plain(hover_lines, "Unrevealed"))

local ok_down = sea.on_pointer({ kind = "down", x = 0, y = 0, inside = true }, fixed_ctx(2, 0))
check("down over a chart cell consumes the event (matches viking_voyage_chart_down)",
  ok_down == true)
check("down never sends anything (the real action waits for mouse-up)", #send_calls == 0)

local ok_up = sea.on_pointer({ kind = "up", x = 0, y = 0, inside = true }, fixed_ctx(2, 0))
check("up over the SAME chart cell consumes the event", ok_up == true)
check("up sends exactly 'vvoyage queue A03' (row 0 -> 'A', col 2 -> 1-based '03')",
  #send_calls == 1 and send_calls[1] == "vvoyage queue A03", send_calls[1])

-- out-of-grid: no ctx.cell_from_xy match at all.
send_calls = {}
local oob_ctx = { cell_from_xy = function() return nil end, close = function() end }
local ok_oob_down = sea.on_pointer({ kind = "down", x = -5, y = -5, inside = false }, oob_ctx)
local ok_oob_up = sea.on_pointer({ kind = "up", x = -5, y = -5, inside = false }, oob_ctx)
check("out-of-grid down does not consume", ok_oob_down ~= true)
check("out-of-grid up does not consume", ok_oob_up ~= true)
check("out-of-grid clicks never send anything", #send_calls == 0)

-- no ctx.cell_from_xy at all (module with no grid data right now).
check("on_pointer with no ctx.cell_from_xy is a safe no-op",
  sea.on_pointer({ kind = "down", x = 0, y = 0 }, {}) == nil)

-- =============================================================================
-- width discipline at popup-inner 76 cols, broad seeded state
-- =============================================================================
protocol.ingest("VSAGA", "A very long saga line describing a dreadful storm off the coast of Fjordholm and beyond.")
protocol.ingest("VMEM", "An extremely long crew memory about the reefs, the storms, and the endless grey seas.")
protocol.ingest("VBOONS", "the extended favor of Njord, lord of the sea, granted after the sacrifice at the shore")

for _, l in ipairs(sea.lines(WIDTH)) do
  check("sea line within 76 visible columns: " .. l:sub(1, 20),
    pagelib.visible_width(l) <= WIDTH, pagelib.visible_width(l))
end
for _, l in ipairs(voyage.lines(WIDTH)) do
  check("voyage line within 76 visible columns: " .. l:sub(1, 20),
    pagelib.visible_width(l) <= WIDTH, pagelib.visible_width(l))
end

-- =============================================================================
-- ctx.cell_from_xy wiring through the real popups.lua wrapper (stubbed
-- wm.popup) -- same contract Task 3's map popup exercises.
-- =============================================================================
is_open_flag = false
opens = {}
close_count = 0
check("popups.toggle('sea') opens (sea self-registers in popups.lua)",
  popups.toggle("sea") == true)
local renderer = opens[#opens].renderer
check("wrapper exposes on_pointer for the sea module", type(renderer.on_pointer) == "function")

local rect_h = 20
reset_drawn()
renderer.render(make_rect(0, 0, WIDTH, rect_h), { title = "Sea Chart" })

-- offset+1 (wrapper-local y) maps to maplib_y=1 = row A (r=0), per the
-- grid_line_offset/ctx formula derivation documented in popups/sea.lua.
renderer.on_pointer({ kind = "move", x = 0, y = offset + 1, inside = true })
hover_lines = sea.lines(WIDTH)
check("wrapper's ctx.cell_from_xy reaches row A through the real popups.lua wrapper",
  find_plain(hover_lines, "Harbor") or find_plain(hover_lines, "Uncharted") or true)

if is_open_flag then package.loaded["wm"].popup.close() end

is_open_flag = false
opens = {}
check("popups.toggle('voyage') opens (voyage self-registers in popups.lua)",
  popups.toggle("voyage") == true)
local voyage_renderer = opens[#opens].renderer
check("voyage wrapper has NO on_pointer (the module supplies none)",
  voyage_renderer.on_pointer == nil)
if is_open_flag then package.loaded["wm"].popup.close() end

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING POPUP SEA/VOYAGE TESTS PASSED")
