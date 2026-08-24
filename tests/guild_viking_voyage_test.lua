-- guild_viking handlers/voyage.lua unit tests. Run from the lera-plugins repo
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

-- ---- lera API stubs (same shape as guild_viking_test.lua) -------------------
local dirty_count = 0
ui = { dirty = function() dirty_count = dirty_count + 1 end }
local stored = nil
store = {
  load = function() end,
  get = function() return stored end,
  set = function(d) stored = d end,
  save = function() end,
}
lera = { time = function() return 1000 end, version = function() return "test" end }
buffer = { color_print = function() end }
mud = { send = function() end }
local mip_handlers, mip_handler_count = {}, 0
mip = {
  on = function(code, cb)
    mip_handlers[code] = cb
    mip_handler_count = mip_handler_count + 1
    return mip_handler_count
  end,
  off = function() end,
  enabled = function() return true end,
  fire = function(code, data) mip_handlers[code](12345, code, data) end,
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
  fire = function(pkg, data) gmcp_handlers[pkg](pkg, data) end,
}
trigger = { add = function() return 1 end, remove = function() end }
timer = { every = function() return 1 end, remove = function() end }
alias = { add = function() return 1 end, remove = function() end }
plugin = { get = function() return nil end }
local real_require = require
require = function(name)
  if name == "command" then
    return { register = function() return 1 end, unregister = function() return true end,
             get = function() return nil end, list = function() return {} end }
  end
  return real_require(name)
end

local protocol = require("protocol")
local S = require("state").S
local voyage = require("handlers.voyage")
-- Mirrors init.lua's RESERVED set: everything in a handler module that is not
-- one of the module-level conventions is an exact MIP key.
local RESERVED = { _market_seam = true, _patterns = true, _gmcp = true }
for key, fn in pairs(voyage) do
  if not RESERVED[key] then protocol.handler(key, fn) end
end
for _, p in ipairs(voyage._patterns or {}) do
  protocol.pattern_handler(p.pattern, p.fn)
end
for key, fn in pairs(voyage._gmcp or {}) do
  protocol.gmcp_handler(key, fn)
end

-- SHIPS (LEGACY 1102): name|tier|state|target|return|sid|crew|convoy|convoy_size|
--   convoy_bonus|saga_title|saga_raids|held|durability  (>=5 fields required)
protocol.ingest("SHIPS", "Ormen|2|docked|Havn|300|s1|4|0|0|0|Saga of Ormen|1|1|80")
check("ships count", #S.ships == 1)
check("ships fields", S.ships[1].name == "Ormen" and S.ships[1].tier == 2
      and S.ships[1].target == "Havn" and S.ships[1].return_in == 300)
check("ships held/durability", S.ships[1].held == true and S.ships[1].durability == 80)

-- SHIPS safety cap: 21 entries -> capped at 20
do
  local entries = {}
  for i = 1, 21 do
    entries[#entries + 1] = string.format("Ship%d|1|docked|Havn|0", i)
  end
  protocol.ingest("SHIPS", table.concat(entries, ";"))
  check("ships safety cap", #S.ships == 20)
end

-- LONGSHIP (LEGACY 1161): 15 fields: sid|name|tier|state|target|return|crew|
--   hired_crew|safe|identity|captain|crew_traits|ship_traits|saga_title|saga_raids
protocol.ingest("LONGSHIP",
  "1|Ormen|2|sailing|Havn|300|4|1|1|proud|Erik|brave,loyal|swift,sturdy|Saga of Ormen|3")
check("longship count", #S.voyage_longships == 1)
check("longship fields", S.voyage_longships[1].name == "Ormen" and S.voyage_longships[1].captain == "Erik"
      and S.voyage_longships[1].saga_raids == 3)
check("longship traits", #S.voyage_longships[1].crew_traits == 2 and S.voyage_longships[1].crew_traits[1] == "brave"
      and #S.voyage_longships[1].ship_traits == 2 and S.voyage_longships[1].ship_traits[2] == "sturdy")
check("longship mip_voyage_seen", S.mip_voyage_seen == true)

-- LONGSHIP safety cap: 21 entries -> capped at 20
do
  local entries = {}
  for i = 1, 21 do
    entries[#entries + 1] = string.format("%d|Ship%d|1|docked|Havn|0|1|0|0|id|cap||||", i, i)
  end
  protocol.ingest("LONGSHIP", table.concat(entries, ";"))
  check("longship safety cap", #S.voyage_longships == 20)
end

-- VOYAGE (LEGACY 1199): 27 fields: state|ship_id|ship_name|contract_name|contract_type|
--   danger|x|y|width|height|hull|morale|supplies|stress|crew_alive|crew_max|steps|
--   next_move|threat_name|threat_level|threat_pressure|paused_type|weather_key|
--   captain|identity|crew_traits|ship_traits
protocol.ingest("VOYAGE",
  "sailing|1|Ormen|Raid Fjordholm|raid|3|5|6|20|20|80|70|60|10|4|5|12|30|Kraken|2|40|" ..
  "|storm|Erik|proud|brave,loyal|swift,sturdy")
check("voyage state", S.voyage_status.state == "sailing" and S.voyage_status.ship_id == 1
      and S.voyage_status.contract_name == "Raid Fjordholm")
check("voyage position", S.voyage_status.x == 5 and S.voyage_status.y == 6
      and S.voyage_status.width == 20 and S.voyage_status.height == 20)
check("voyage threat", S.voyage_status.threat_name == "Kraken" and S.voyage_status.threat_level == 2)
check("voyage traits", #S.voyage_status.crew_traits == 2 and S.voyage_status.crew_traits[2] == "loyal")
check("voyage wait fallback", S.voyage_wait == "")

-- VOYAGE with empty value clears status
protocol.ingest("VOYAGE", "")
check("voyage cleared", S.voyage_status == nil and S.voyage_wait == "")

-- VOYAGE_WAIT (LEGACY 1254): plain string
protocol.ingest("VOYAGE_WAIT", "becalmed")
check("voyage_wait", S.voyage_wait == "becalmed")

-- VRESOLVE (LEGACY 1257): comma-separated options, cap 10
protocol.ingest("VRESOLVE", "fight,flee,parley")
check("vresolve count", #S.voyage_resolve_options == 3)
check("vresolve values", S.voyage_resolve_options[1] == "fight" and S.voyage_resolve_options[3] == "parley")

do
  local opts = {}
  for i = 1, 11 do opts[#opts + 1] = "opt" .. i end
  protocol.ingest("VRESOLVE", table.concat(opts, ","))
  check("vresolve safety cap", #S.voyage_resolve_options == 10)
end

-- VOFFERS (LEGACY 1264): shipname|idx:type:name:danger:difficulty:fit;...
protocol.ingest("VOFFERS", "Ormen|0:raid:Raid Fjordholm:3:medium:3;1:trade:Trade Run:1:easy:0")
check("voffers ship", S.voyage_offers.ship == "Ormen")
check("voffers count", #S.voyage_offers.list == 2)
check("voffers fields", S.voyage_offers.list[1].name == "Raid Fjordholm" and S.voyage_offers.list[1].danger == 3
      and S.voyage_offers.list[1].fit == 3)
check("voffers fallback fit default", S.voyage_offers.list[2].fit == 0)

-- VOFFERS old 5-field fallback form (no fit) -> fit defaults to 3
protocol.ingest("VOFFERS", "Ormen|0:raid:Raid Fjordholm:3:medium")
check("voffers fallback form fit default", S.voyage_offers.list[1].fit == 3)

-- VOFFERS empty value clears offers
protocol.ingest("VOFFERS", "")
check("voffers cleared", S.voyage_offers == nil)

-- VCHART (LEGACY 1288): size|mode|comma-separated rows
protocol.ingest("VCHART", "5|coastal|row1,row2,row3")
check("vchart dims", S.voyage_chart_width == 5 and S.voyage_chart_height == 5)
check("vchart mode", S.voyage_chart_mode == "coastal")
check("vchart rows", #S.voyage_chart_rows == 3 and S.voyage_chart_rows[2] == "row2")

-- VCHART empty value resets
protocol.ingest("VCHART", "")
check("vchart cleared", S.voyage_chart_width == 0 and #S.voyage_chart_rows == 0)

-- VCHH (LEGACY 1306): width|height|mode -- pre-sizes voyage_chart_rows with empties
protocol.ingest("VCHH", "8|4|open")
check("vchh dims", S.voyage_chart_width == 8 and S.voyage_chart_height == 4)
check("vchh mode", S.voyage_chart_mode == "open")
check("vchh rows presized", #S.voyage_chart_rows == 4 and S.voyage_chart_rows[1] == "" and S.voyage_chart_rows[4] == "")

-- VCR%d%d (LEGACY 1322-1325, pattern-dispatched): row content keyed by a
-- 2-digit row index embedded in the key itself (0-indexed -> 1-indexed).
S.mip_voyage_seen = false
protocol.ingest("VCR00", "~~~~~~~~")
protocol.ingest("VCR07", "..~~S~~.")
check("vcr row 0 lands at index 1", S.voyage_chart_rows[1] == "~~~~~~~~")
check("vcr07 payload routes to row 8", S.voyage_chart_rows[8] == "..~~S~~.")
check("vcr sets mip_voyage_seen", S.mip_voyage_seen == true)

-- VQPATH (LEGACY 1326): comma-separated queue entries, cap 100
protocol.ingest("VQPATH", "N,N,E,SE")
check("vqpath count", #S.voyage_queue == 4)
check("vqpath values", S.voyage_queue[3] == "E")

do
  local moves = {}
  for i = 1, 101 do moves[#moves + 1] = "N" end
  protocol.ingest("VQPATH", table.concat(moves, ","))
  check("vqpath safety cap", #S.voyage_queue == 100)
end

-- VSAGA (LEGACY 1333): semicolon-separated entries, cap 200
protocol.ingest("VSAGA", "The fleet set sail.;A storm was weathered.")
check("vsaga count", #S.voyage_saga == 2)
check("vsaga values", S.voyage_saga[1] == "The fleet set sail.")

-- VMEM (LEGACY 1340): semicolon-separated entries, cap 100
protocol.ingest("VMEM", "Remembered the reefs of Fjordholm.")
check("vmem count", #S.voyage_memory == 1)
check("vmem values", S.voyage_memory[1] == "Remembered the reefs of Fjordholm.")

-- VBOONS (LEGACY 1347): plain string
protocol.ingest("VBOONS", "favor of Njord")
check("vboons", S.voyage_boons == "favor of Njord")

-- VSPOILS (LEGACY 1350): plain number
protocol.ingest("VSPOILS", "450")
check("vspoils", S.voyage_spoils_daler == 450)

-- VGOODS (LEGACY 1353): name:count pairs, semicolon-separated
protocol.ingest("VGOODS", "silver:12;furs:5")
check("vgoods count", #S.voyage_goods == 2)
check("vgoods fields", S.voyage_goods[1].name == "silver" and S.voyage_goods[1].count == 12)

-- VAIDS (LEGACY 1362): name:count pairs
protocol.ingest("VAIDS", "rope:3;anchor:1")
check("vaids count", #S.voyage_aids == 2)
check("vaids fields", S.voyage_aids[1].name == "rope" and S.voyage_aids[1].count == 3)

-- VRUNES (LEGACY 1371): name:count pairs
protocol.ingest("VRUNES", "ansuz:2;tiwaz:1")
check("vrunes count", #S.voyage_runes == 2)
check("vrunes fields", S.voyage_runes[1].name == "ansuz" and S.voyage_runes[1].count == 2)

-- VRELICS (LEGACY 1380): semicolon-separated flat strings, cap 50
protocol.ingest("VRELICS", "Horn of Heimdall;Shard of Mjolnir")
check("vrelics count", #S.voyage_relics == 2)
check("vrelics values", S.voyage_relics[1] == "Horn of Heimdall")

do
  local entries = {}
  for i = 1, 51 do entries[#entries + 1] = "Relic" .. i end
  protocol.ingest("VRELICS", table.concat(entries, ";"))
  check("vrelics safety cap", #S.voyage_relics == 50)
end

-- VCURIOS (LEGACY 1387): comma-separated flat strings, cap 50
protocol.ingest("VCURIOS", "Carved Whale Tooth,Sea Glass Bead")
check("vcurios count", #S.voyage_curios == 2)
check("vcurios values", S.voyage_curios[2] == "Sea Glass Bead")

do
  local entries = {}
  for i = 1, 51 do entries[#entries + 1] = "Curio" .. i end
  protocol.ingest("VCURIOS", table.concat(entries, ","))
  check("vcurios safety cap", #S.voyage_curios == 50)
end

-- VREAGENT (LEGACY 1394): plain number
protocol.ingest("VREAGENT", "2")
check("vreagent", S.voyage_reagents == 2)

-- VSAILED (LEGACY 1397): "x,y" pairs, semicolon-separated -> row/col grid (1-indexed, y=row, x=col)
protocol.ingest("VSAILED", "0,0;2,1;3,1")
check("vsailed row1", S.voyage_sailed[1] and S.voyage_sailed[1][1] == true)
check("vsailed row2", S.voyage_sailed[2] and S.voyage_sailed[2][3] == true and S.voyage_sailed[2][4] == true)
check("vsailed empty", S.voyage_sailed[1][2] == nil)

-- VSAILED empty value clears
protocol.ingest("VSAILED", "")
check("vsailed cleared", next(S.voyage_sailed) == nil)

-- VMREG (LEGACY 2293): plain number, -1 default
protocol.ingest("VMREG", "4")
check("vmreg", S.mission_reg_left == 4)
protocol.ingest("VMREG", "")
check("vmreg default", S.mission_reg_left == -1)

-- VMNEW (LEGACY 2295): plain number, -1 default
protocol.ingest("VMNEW", "2")
check("vmnew", S.mission_new_left == 2)
protocol.ingest("VMNEW", "")
check("vmnew default", S.mission_new_left == -1)

-- WEATHER (LEGACY 2331): season|weather|weather_str
protocol.ingest("WEATHER", "winter|snow|2")
check("weather fields", S.season == "winter" and S.weather == "snow" and S.weather_str == 2)

-- FLEET_RENOWN (LEGACY 2140): plain number
protocol.ingest("FLEET_RENOWN", "1500")
check("fleet_renown", S.fleet_renown == 1500)

-- ---- Guild.Map -------------------------------------------------------------
--
-- The territory map is GMCP-only: MIP's VMAPH/VMAPL/VMR/MEE/MES keys are
-- received and dropped (see the bottom of this section). Frames arrive
-- through protocol.on_gmcp, which strips the envelope and hands every
-- Guild.Map key to the single composite writer as one table.

-- protocol_grid_pack_row()'s packing, transcribed from
-- secure/protocol/grid_codec_impl.h. Only used to prove a packed plane
-- reaches the codec at all; the codec's own correctness is
-- guild_viking_gmcp_grid_test.lua's subject.
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function pack_row(codes, bits)
  local octets, acc, held = {}, 0, 0
  for i = 1, #codes do
    acc = acc * (2 ^ bits) + codes[i]
    held = held + bits
    if held >= 8 then
      octets[#octets + 1] = math.floor(acc / 2 ^ (held - 8)) % 256
      held = held - 8
      acc = (held > 0) and (acc % 2 ^ held) or 0
    end
  end
  if held > 0 then octets[#octets + 1] = (acc * 2 ^ (8 - held)) % 256 end
  local out = {}
  for i = 1, #octets, 3 do
    local chunk = octets[i] * 65536
      + (octets[i + 1] or 0) * 256 + (octets[i + 2] or 0)
    local function ch(n) return B64:sub(n + 1, n + 1) end
    out[#out + 1] = ch(math.floor(chunk / 262144) % 64)
    out[#out + 1] = ch(math.floor(chunk / 4096) % 64)
    if octets[i + 1] then out[#out + 1] = ch(math.floor(chunk / 64) % 64) end
    if octets[i + 2] then out[#out + 1] = ch(chunk % 64) end
  end
  return table.concat(out)
end

local GLYPH_ENC = { terrain = "glyph", east = "glyph", south = "glyph" }
local TERRAIN_LEGEND = {
  ["0"] = "unexplored", ["1"] = "plains", ["2"] = "forest", ["3"] = "hills",
  ["4"] = "mountains", ["5"] = "tundra", ["6"] = "coast",
  ["7"] = "water (fjord/lake)", ["8"] = "bridge",
  ["9"] = "river/ford (unbridged)", ["10"] = "road",
}
local EDGE_LEGEND = { ["0"] = "blocked (impassable edge)", ["1"] = "open (passable edge)" }

local function map_frame(payload)
  payload.guild = "viking"
  protocol.on_gmcp("Guild.Map", payload)
end

-- A full frame: dimensions, position, all three planes as glyph rows, and the
-- landmark list.
map_frame({
  full = 1, w = 5, h = 2, active = 1, pos = { x = 3, y = 1 },
  enc = GLYPH_ENC, legend = TERRAIN_LEGEND, legend_edge = EDGE_LEGEND,
  terrain = { "pp.ff", "AAtt." },
  east = { "10101", "11110" },
  south = { "01010" },
  landmarks = {
    { type = "town", name = "Havn", x = 3, y = 1, owner = "PlayerA" },
    { type = "fort", name = "Alpha", x = 5, y = 2, owner = "" },
  },
})
check("map dims", S.vmap_w == 5 and S.vmap_h == 2)
check("map player pos", S.vmap_px == 3 and S.vmap_py == 1)
check("map active", S.vmap_active == 1)
check("map terrain rows land at 1-indexed positions",
      S.vmap_rows[1] == "pp.ff" and S.vmap_rows[2] == "AAtt.")
check("map east edges", S.vmap_east_edges[1] == "10101" and S.vmap_east_edges[2] == "11110")
-- The south plane describes the boundary between row r and row r+1, so it is
-- one row shorter than the grid by construction.
check("map south edges", S.vmap_south_edges[1] == "01010" and #S.vmap_south_edges == 1)
check("map landmarks", #S.vmap_pois == 2 and S.vmap_pois[1].type == "town"
      and S.vmap_pois[1].name == "Havn" and S.vmap_pois[1].x == 3
      and S.vmap_pois[1].y == 1 and S.vmap_pois[1].owner == "PlayerA")
check("map landmark owner default", S.vmap_pois[2].owner == "")

-- Terrain rows are CLEAN -- no player marker baked in. This is the whole
-- reason MIP's map path is gone rather than kept: MIP wrote an 'X' into the
-- player's own cell, which popups/map.lua overdrew but pathfinding.lua read
-- as if it were terrain.
check("the player's own cell carries real terrain, not a marker",
      S.vmap_rows[2]:sub(4, 4) == "t")

-- A step sends `pos` alone. Every other key is absent, which means unchanged
-- -- never empty.
map_frame({ pos = { x = 4, y = 1 } })
check("a pos-only delta moves the marker", S.vmap_px == 4 and S.vmap_py == 1)
check("a pos-only delta leaves the planes standing",
      S.vmap_rows[1] == "pp.ff" and S.vmap_east_edges[1] == "10101"
      and #S.vmap_pois == 2 and S.vmap_w == 5)

-- Walking off the biome grid keeps the last known coordinates but clears
-- `active`, which is what the popup labels the position with.
map_frame({ active = 0 })
check("active clears without disturbing the position",
      S.vmap_active == 0 and S.vmap_px == 4 and S.vmap_py == 1)
map_frame({ active = 1 })

-- Same dimensions preserve the planes; a changed dimension drops them,
-- because rows sized for the old grid cannot be reinterpreted at a new width.
map_frame({ w = 5, h = 2 })
check("unchanged dims preserve the planes", S.vmap_rows[1] == "pp.ff")
map_frame({ w = 6, h = 3 })
check("changed dims reset the planes",
      S.vmap_rows[1] == nil and S.vmap_east_edges[1] == nil
      and S.vmap_south_edges[1] == nil)
check("changed dims are applied", S.vmap_w == 6 and S.vmap_h == 3)

-- A frame naming only one dimension still resets, and keeps the other.
map_frame({ w = 5, h = 2, terrain = { "ppppp", "fffff" } })
map_frame({ h = 4 })
check("a partial dimension change keeps the dimension it did not name",
      S.vmap_w == 5 and S.vmap_h == 4 and S.vmap_rows[1] == nil)

-- Landmarks are one array key, so a frame carrying them carries the whole
-- list: it replaces rather than merges, and two landmarks on one cell keep
-- the first (popups/map.lua indexes one POI per cell).
map_frame({
  landmarks = {
    { type = "town", name = "Havn", x = 3, y = 4, owner = "PlayerA" },
    { type = "fort", name = "Beta", x = 9, y = 9, owner = "" },
    { type = "fort", name = "BetaDup", x = 9, y = 9, owner = "PlayerC" },
  },
})
check("landmarks replace the previous list", #S.vmap_pois == 2)
check("two landmarks on one cell keep the first", S.vmap_pois[2].name == "Beta")

-- A packed push. `enc` names the encoding per plane and `legend` explains the
-- codes; both are cached, so the delta that follows can ship planes alone.
map_frame({
  w = 3, h = 2,
  enc = { terrain = "b4", east = "b1", south = "b1" },
  legend = TERRAIN_LEGEND, legend_edge = EDGE_LEGEND,
  terrain = { pack_row({ 1, 1, 0 }, 4), pack_row({ 2, 2, 4 }, 4) },
  east = { pack_row({ 1, 0, 1 }, 1) },
  south = { pack_row({ 0, 0, 1 }, 1) },
})
check("a packed terrain plane decodes to glyph rows",
      S.vmap_rows[1] == "pp." and S.vmap_rows[2] == "ffA",
      tostring(S.vmap_rows[1]) .. "/" .. tostring(S.vmap_rows[2]))
check("packed edge planes decode to passability rows",
      S.vmap_east_edges[1] == "101" and S.vmap_south_edges[1] == "001")

-- enc/legend change only when the server's own tables do, so a delta shipping
-- fresh planes will not repeat them. Decoding against the cached pair is the
-- ordinary case, not the exception.
map_frame({ terrain = { pack_row({ 0, 10, 8 }, 4) } })
check("a plane arriving without enc decodes against the cached context",
      S.vmap_rows[1] == ".+=", tostring(S.vmap_rows[1]))

-- That cache must not outlive its connection: a fresh packed plane read
-- against a previous session's legend would draw a wrong map that looks
-- entirely plausible.
require("state").reset_connection()
check("disconnect clears the decoding context",
      S.vmap_enc == nil and S.vmap_legend == nil and S.vmap_terrain_glyphs == nil)
map_frame({ w = 3, h = 1, enc = { terrain = "b4" },
            terrain = { pack_row({ 1, 1, 0 }, 4) } })
check("a packed plane with no legend empties rather than guessing glyphs",
      S.vmap_rows[1] == "", tostring(S.vmap_rows[1]))

-- MIP's map keys are still sent by the server and are deliberately inert.
-- They are registered rather than left unknown so /vik status's unknown list
-- keeps meaning "keys nobody has taught this client about".
map_frame({ w = 4, h = 2, enc = GLYPH_ENC, legend = TERRAIN_LEGEND,
            terrain = { "pppp", "ffff" }, pos = { x = 1, y = 1 } })
local before = protocol.stats().unknown["VMAPH"]
protocol.ingest("VMAPH", "9|9|0|0|1")
protocol.ingest("VMAPL", "town|Ignored|0|0|")
protocol.ingest("VMAPL_END", "1")
protocol.ingest("VMR00", "XXXX")
protocol.ingest("MEE00", "111")
protocol.ingest("MES00", "000")
check("the MIP map keys leave the GMCP map untouched",
      S.vmap_w == 4 and S.vmap_rows[1] == "pppp" and S.vmap_px == 1
      and S.vmap_east_edges[1] == nil,
      tostring(S.vmap_w) .. "/" .. tostring(S.vmap_rows[1]) .. "/"
        .. tostring(S.vmap_px) .. "/" .. tostring(S.vmap_east_edges[1]))
check("the MIP map keys are not counted unknown",
      protocol.stats().unknown["VMAPH"] == before
      and protocol.stats().unknown["VMR00"] == nil)

-- Pattern-tier dispatch precedence and unknown-key accounting (using
-- synthetic keys -- not real LEGACY telemetry -- since none of this module's
-- registered patterns collide with each other or with any exact key).
local precedence_calls = {}
protocol.handler("ZQTEST01", function(v) precedence_calls[#precedence_calls + 1] = "exact:" .. v end)
protocol.pattern_handler("^ZQTEST%d%d$",
  function(k, v) precedence_calls[#precedence_calls + 1] = "pattern:" .. k .. ":" .. v end)
protocol.ingest("ZQTEST01", "hello")
check("exact beats pattern when both match", #precedence_calls == 1 and precedence_calls[1] == "exact:hello")
protocol.ingest("ZQTEST02", "world")
check("pattern still dispatches a key with no exact match",
      #precedence_calls == 2 and precedence_calls[2] == "pattern:ZQTEST02:world")

local unknown_before = protocol.stats().unknown.ZQNOPE or 0
protocol.ingest("ZQNOPE", "x")
check("unknown still counted when neither tier matches",
      (protocol.stats().unknown.ZQNOPE or 0) == unknown_before + 1)

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING VOYAGE TESTS PASSED")
