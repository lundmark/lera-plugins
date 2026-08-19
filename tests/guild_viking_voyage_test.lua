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
for key, fn in pairs(voyage) do protocol.handler(key, fn) end

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

-- VMAPH (LEGACY 2523): width|height|player_x|player_y -- resets rows/edges only on
-- dimension change, swaps any pending POI batch into the live list.
protocol.ingest("VMAPH", "10|8|3|4")
check("vmaph dims", S.vmap_w == 10 and S.vmap_h == 8)
check("vmaph player pos", S.vmap_px == 3 and S.vmap_py == 4)
check("vmaph expecting", S.vmap_pois_expecting == true)

-- VMAPL (LEGACY 2549): type|name|x|y|owner entries, semicolon-separated, into the
-- pending buffer (dedup by "x,y"), promoted to the live list on next VMAPH.
protocol.ingest("VMAPL", "town|Havn|3|4|PlayerA;fort|Alpha|5|2|")
check("vmapl pending count", #S.vmap_pois_pending == 2)
check("vmapl pending fields", S.vmap_pois_pending[1].type == "town" and S.vmap_pois_pending[1].name == "Havn"
      and S.vmap_pois_pending[1].x == 3 and S.vmap_pois_pending[1].y == 4
      and S.vmap_pois_pending[1].owner == "PlayerA")
check("vmapl pending owner default", S.vmap_pois_pending[2].owner == "")
check("vmapl live not yet swapped", #S.vmap_pois == 0)

-- VMAPL dedup: same "x,y" key is not inserted twice
protocol.ingest("VMAPL", "town|Havn|3|4|PlayerA")
check("vmapl dedup", #S.vmap_pois_pending == 2)

-- Next VMAPH swaps the pending batch into the live list.
protocol.ingest("VMAPH", "10|8|3|4")
check("vmaph swap", #S.vmap_pois == 2 and S.vmap_pois[1].name == "Havn")
check("vmaph rows preserved on same dims", S.vmap_w == 10 and S.vmap_h == 8)

-- VMAPH with changed dimensions resets rows/edges
S.vmap_rows[1] = "existing row"
protocol.ingest("VMAPH", "12|9|0|0")
check("vmaph reset rows on dim change", S.vmap_rows[1] == nil)
check("vmaph new dims", S.vmap_w == 12 and S.vmap_h == 9)

-- VMAPL_END (LEGACY 2580): no-op in LEGACY -- registered so protocol.ingest
-- doesn't record it as unknown; state is untouched.
protocol.ingest("VMAPL_END", "")
check("vmapl_end no-op", S.vmap_w == 12)

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING VOYAGE TESTS PASSED")
