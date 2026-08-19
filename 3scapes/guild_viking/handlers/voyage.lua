-- Ships, voyage, and sea-map payload parsers, ported verbatim from LEGACY
-- guild_viking.lua (github.com/.../3s_scripts_old, read-only reference).
-- Each parser body transcribes its LEGACY `elseif key == "..."` branch:
-- string.split -> util.split, state. -> S. (module-local alias). Display
-- calls (viking_window.*, ColourNote) are dropped -- protocol.ingest already
-- marks ui.dirty(); parsers never do.
local S = require("state").S
local util = require("util")

local M = {}

-- LEGACY 1102
M.SHIPS = function(val)
  S.ships = {}
  for entry in val:gmatch("[^;]+") do
    if #S.ships >= 20 then break end  -- Safety limit
    local f = util.split(entry, "|")
    local fields = #f
    if fields >= 5 then
      local name, tier, st, tgt, ret, sid, crew, convoy, convoy_size, convoy_bonus, saga_title, saga_raids, held_s, sdur =
        f[1], f[2], f[3], f[4] or "", f[5], f[6] or "", f[7] or "", f[8] or "",
        f[9] or "", f[10] or "", f[11] or "", f[12] or "", f[13] or "", f[14] or ""
      table.insert(S.ships, { name=name, tier=tonumber(tier) or 1,
        state=st, target=tgt, return_in=tonumber(ret) or 0,
        ship_id=(sid and sid ~= "") and tonumber(sid) or nil,
        crew=tonumber(crew) or 0,
        convoy=(convoy and convoy ~= "") and tonumber(convoy) or 0,
        convoy_size=(convoy_size and convoy_size ~= "") and tonumber(convoy_size) or 0,
        convoy_bonus=(convoy_bonus and convoy_bonus ~= "") and tonumber(convoy_bonus) or 0,
        saga_title=saga_title or "",
        saga_raids=tonumber(saga_raids) or 0,
        held=(held_s == "1"),
        durability=(sdur and sdur ~= "") and tonumber(sdur) or 100 })
    end
  end
end

-- LEGACY 1161
M.LONGSHIP = function(val)
  S.mip_voyage_seen = true
  S.voyage_longships = {}
  for entry in val:gmatch("[^;]+") do
    if #S.voyage_longships >= 20 then break end  -- Safety limit
    -- 15 fields, matching the server LONGSHIP packet order:
    -- sid|name|tier|state|target|return|crew|hired_crew|safe|
    -- identity|captain|crew_traits|ship_traits|saga_title|saga_raids
    local sid, name, tier, st, tgt, ret, crew, hired, safe, identity, captain, crew_traits, ship_traits, saga_title, saga_raids =
      entry:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
    if sid then
      local rec = {
        ship_id = tonumber(sid) or 0,
        name = name or "",
        tier = tonumber(tier) or 1,
        state = st or "docked",
        target = tgt or "",
        return_in = tonumber(ret) or 0,
        crew = tonumber(crew) or 0,
        hired_crew = tonumber(hired) or 0,
        safe = tonumber(safe) or 0,
        renown = 0,  -- fleet renown now sent as FLEET_RENOWN in EXTRA
        identity = identity or "",
        captain = captain or "",
        crew_traits = {},
        ship_traits = {},
        saga_title = saga_title or "",
        saga_raids = tonumber(saga_raids) or 0,
      }
      for trait in (crew_traits or ""):gmatch("[^,]+") do
        rec.crew_traits[#rec.crew_traits + 1] = trait
      end
      for trait in (ship_traits or ""):gmatch("[^,]+") do
        rec.ship_traits[#rec.ship_traits + 1] = trait
      end
      table.insert(S.voyage_longships, rec)
    end
  end
end

-- LEGACY 1199
M.VOYAGE = function(val)
  S.mip_voyage_seen = true
  if val == "" then
    S.voyage_status = nil
    S.voyage_wait = ""
  else
    local vstate, ship_id, ship_name, contract_name, contract_type, danger,
      x, y, width, height, hull, morale, supplies, stress, crew_alive, crew_max,
      steps, next_move, threat_name, threat_level, threat_pressure, paused_type,
      weather_key, captain, identity, crew_traits, ship_traits =
      val:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
    if vstate then
      S.voyage_status = {
        state = vstate or "",
        ship_id = tonumber(ship_id) or 0,
        ship_name = ship_name or "",
        contract_name = contract_name or "",
        contract_type = contract_type or "",
        danger = tonumber(danger) or 0,
        x = tonumber(x) or 0,
        y = tonumber(y) or 0,
        width = tonumber(width) or 0,
        height = tonumber(height) or 0,
        hull = tonumber(hull) or 0,
        morale = tonumber(morale) or 0,
        supplies = tonumber(supplies) or 0,
        stress = tonumber(stress) or 0,
        crew_alive = tonumber(crew_alive) or 0,
        crew_max = tonumber(crew_max) or 0,
        steps = tonumber(steps) or 0,
        next_move = tonumber(next_move) or 0,
        threat_name = threat_name or "",
        threat_level = tonumber(threat_level) or 0,
        threat_pressure = tonumber(threat_pressure) or 0,
        paused_type = paused_type or "",
        weather_key = weather_key or "",
        renown = 0,  -- fleet renown now sent as FLEET_RENOWN in EXTRA
        captain = captain or "",
        identity = identity or "",
        crew_traits = {},
        ship_traits = {},
      }
      -- Backward-compatible fallback: infer wait status from VOYAGE paused_type.
      S.voyage_wait = paused_type or ""
      for trait in (crew_traits or ""):gmatch("[^,]+") do
        S.voyage_status.crew_traits[#S.voyage_status.crew_traits + 1] = trait
      end
      for trait in (ship_traits or ""):gmatch("[^,]+") do
        S.voyage_status.ship_traits[#S.voyage_status.ship_traits + 1] = trait
      end
    else
      S.voyage_status = nil
      S.voyage_wait = ""
    end
  end
end

-- LEGACY 1254
M.VOYAGE_WAIT = function(val)
  S.mip_voyage_seen = true
  S.voyage_wait = tostring(val or "")
end

-- LEGACY 1257
M.VRESOLVE = function(val)
  S.mip_voyage_seen = true
  S.voyage_resolve_options = {}
  for entry in val:gmatch("[^,]+") do
    if #S.voyage_resolve_options >= 10 then break end
    table.insert(S.voyage_resolve_options, entry)
  end
end

-- LEGACY 1264
M.VOFFERS = function(val)
  -- Pending launch contracts: shipname|idx:type:name:danger:difficulty:fit;...
  -- fit = 0 suicidal, 1 underfitted, 2 risky, 3 ready (auto-voyage safety).
  S.voyage_offers = nil
  if val and #val > 0 then
    local ship, rest = val:match("^([^|]*)|(.*)$")
    if ship then
      local list = {}
      for entry in rest:gmatch("[^;]+") do
        -- new 6-field form (with fit), falling back to the old 5-field form
        local idx, typ, nm, dng, diff, fit =
          entry:match("^(%d+):([^:]*):([^:]*):(%d+):([^:]*):(%d+)$")
        if not idx then
          idx, typ, nm, dng, diff = entry:match("^(%d+):([^:]*):([^:]*):(%d+):(.*)$")
        end
        if idx then
          list[#list + 1] = { index = tonumber(idx), type = typ, name = nm,
                              danger = tonumber(dng) or 0, difficulty = diff,
                              fit = tonumber(fit) or 3 }
        end
      end
      if #list > 0 then S.voyage_offers = { ship = ship, list = list } end
    end
  end
end

-- LEGACY 1288
M.VCHART = function(val)
  S.mip_voyage_seen = true
  S.voyage_chart_width = 0
  S.voyage_chart_height = 0
  S.voyage_chart_mode = ""
  S.voyage_chart_rows = {}
  if val ~= "" then
    local size, mode, rows = val:match("^([^|]*)|([^|]*)|(.*)$")
    if size then
      local parsed_size = tonumber(size) or 0
      S.voyage_chart_width = parsed_size
      S.voyage_chart_height = parsed_size
      S.voyage_chart_mode = mode or ""
      for entry in (rows or ""):gmatch("[^,]+") do
        S.voyage_chart_rows[#S.voyage_chart_rows + 1] = entry
      end
    end
  end
end

-- LEGACY 1306
M.VCHH = function(val)
  S.mip_voyage_seen = true
  local width, height, mode = val:match("^([^|]*)|([^|]*)|([^|]*)$")
  if width then
    local new_w = tonumber(width) or 0
    local new_h = tonumber(height) or 0
    S.voyage_chart_width = new_w
    S.voyage_chart_height = new_h
    S.voyage_chart_mode = mode or ""
    S.voyage_chart_rows = {}
    if new_h > 0 then
      for i = 1, new_h do
        S.voyage_chart_rows[i] = ""
      end
    end
  end
end

-- LEGACY 1326
M.VQPATH = function(val)
  S.mip_voyage_seen = true
  S.voyage_queue = {}
  for entry in val:gmatch("[^,]+") do
    if #S.voyage_queue >= 100 then break end  -- Safety limit
    S.voyage_queue[#S.voyage_queue + 1] = entry
  end
end

-- LEGACY 1333
M.VSAGA = function(val)
  S.mip_voyage_seen = true
  S.voyage_saga = {}
  for entry in val:gmatch("[^;]+") do
    if #S.voyage_saga >= 200 then break end  -- Safety limit
    S.voyage_saga[#S.voyage_saga + 1] = entry
  end
end

-- LEGACY 1340
M.VMEM = function(val)
  S.mip_voyage_seen = true
  S.voyage_memory = {}
  for entry in val:gmatch("[^;]+") do
    if #S.voyage_memory >= 100 then break end  -- Safety limit
    S.voyage_memory[#S.voyage_memory + 1] = entry
  end
end

-- LEGACY 1347
M.VBOONS = function(val)
  S.mip_voyage_seen = true
  S.voyage_boons = val or ""
end

-- LEGACY 1350
M.VSPOILS = function(val)
  S.mip_voyage_seen = true
  S.voyage_spoils_daler = tonumber(val) or 0
end

-- LEGACY 1353
M.VGOODS = function(val)
  S.mip_voyage_seen = true
  S.voyage_goods = {}
  for entry in val:gmatch("[^;]+") do
    local name, count = entry:match("^([^:]+):(%d+)$")
    if name and count then
      S.voyage_goods[#S.voyage_goods + 1] = { name = name, count = tonumber(count) or 0 }
    end
  end
end

-- LEGACY 1362
M.VAIDS = function(val)
  S.mip_voyage_seen = true
  S.voyage_aids = {}
  for entry in val:gmatch("[^;]+") do
    local name, count = entry:match("^([^:]+):(%d+)$")
    if name and count then
      S.voyage_aids[#S.voyage_aids + 1] = { name = name, count = tonumber(count) or 0 }
    end
  end
end

-- LEGACY 1371
M.VRUNES = function(val)
  S.mip_voyage_seen = true
  S.voyage_runes = {}
  for entry in val:gmatch("[^;]+") do
    local name, count = entry:match("^([^:]+):(%d+)$")
    if name and count then
      S.voyage_runes[#S.voyage_runes + 1] = { name = name, count = tonumber(count) or 0 }
    end
  end
end

-- LEGACY 1380
M.VRELICS = function(val)
  S.mip_voyage_seen = true
  S.voyage_relics = {}
  for entry in val:gmatch("[^;]+") do
    if #S.voyage_relics >= 50 then break end
    S.voyage_relics[#S.voyage_relics + 1] = entry
  end
end

-- LEGACY 1387
M.VCURIOS = function(val)
  S.mip_voyage_seen = true
  S.voyage_curios = {}
  for entry in val:gmatch("[^,]+") do
    if #S.voyage_curios >= 50 then break end
    S.voyage_curios[#S.voyage_curios + 1] = entry
  end
end

-- LEGACY 1394
M.VREAGENT = function(val)
  S.mip_voyage_seen = true
  S.voyage_reagents = tonumber(val) or 0
end

-- LEGACY 1397
M.VSAILED = function(val)
  S.mip_voyage_seen = true
  S.voyage_sailed = {}
  if val and #val > 0 then
    for pair in val:gmatch("[^;]+") do
      local x, y = pair:match("^(%d+),(%d+)$")
      if x and y then
        local ri = tonumber(y) + 1
        local ci = tonumber(x) + 1
        if not S.voyage_sailed[ri] then S.voyage_sailed[ri] = {} end
        S.voyage_sailed[ri][ci] = true
      end
    end
  end
end

-- LEGACY 2293
M.VMREG = function(val)
  S.mission_reg_left = tonumber(val) or -1
end

-- LEGACY 2295
M.VMNEW = function(val)
  S.mission_new_left = tonumber(val) or -1
end

-- LEGACY 2331
M.WEATHER = function(val)
  local sea, wth, str = val:match("^([^|]+)|([^|]+)|([^|]+)$")
  if sea then
    S.season      = sea
    S.weather     = wth
    S.weather_str = tonumber(str) or 1
  end
end

-- LEGACY 2523
M.VMAPH = function(val)
  local mw, mh, mpx, mpy = val:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
  if mw then
    local new_w = tonumber(mw) or 0
    local new_h = tonumber(mh) or 0
    -- Only reset edge/row data when map dimensions change
    if new_w ~= S.vmap_w or new_h ~= S.vmap_h then
      S.vmap_rows = {}
      S.vmap_east_edges = {}
      S.vmap_south_edges = {}
    end
    -- Swap completed pending batch into live list (no flicker)
    -- Always swap if a pending batch exists, even if empty (handles cleanup)
    if S.vmap_pois_pending ~= nil then
      S.vmap_pois = S.vmap_pois_pending
      S.vmap_pois_keys = S.vmap_pois_pending_keys or {}
    end
    -- Reset pending buffer for incoming VMAPL chunks
    S.vmap_pois_pending = nil
    S.vmap_pois_pending_keys = {}
    S.vmap_pois_expecting = true
    S.vmap_w  = new_w
    S.vmap_h  = new_h
    S.vmap_px = tonumber(mpx) or -1
    S.vmap_py = tonumber(mpy) or -1
  end
end

-- LEGACY 2549, plus the LEGACY 2659-2668 promotion check (see the fix report
-- for the mapping): in LEGACY that check runs once per whole MIP packet,
-- after the entire elseif chain, not inside any single branch -- it fires
-- whenever "vmap_pois is still empty but the pending buffer has data".
-- vmap_pois_pending can only gain data from this handler, so the equivalent
-- moment in a per-key dispatch architecture is the end of this same
-- ingest call: nothing else in this module can clear vmap_pois to empty
-- between VMAPL calls, so checking here fires under exactly the same
-- condition LEGACY's post-packet check would have found true.
M.VMAPL = function(val)
  -- Build into pending buffer; swapped to live list on next VMAPH
  if S.vmap_pois_expecting then
    S.vmap_pois_pending = {}
    S.vmap_pois_pending_keys = {}
    S.vmap_pois_expecting = false
  end
  if not S.vmap_pois_pending then S.vmap_pois_pending = {} end
  if not S.vmap_pois_pending_keys then S.vmap_pois_pending_keys = {} end
  for entry in val:gmatch("[^;]+") do
    local ptype, pname, px2, py2, powner =
      entry:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]*)$")
    if ptype then
      local ekey = (px2 or "?") .. "," .. (py2 or "?")
      if not S.vmap_pois_pending_keys[ekey] then
        S.vmap_pois_pending_keys[ekey] = true
        table.insert(S.vmap_pois_pending, { type=ptype, name=pname,
          x=tonumber(px2) or -1, y=tonumber(py2) or -1,
          owner=powner or "" })
      end
    end
  end
  -- If vmap_pois is still empty but the pending buffer has data, promote it
  -- immediately rather than waiting for the next VMAPH heartbeat cycle.
  if S.vmap_pois_pending and #S.vmap_pois_pending > 0
     and #(S.vmap_pois or {}) == 0 then
    S.vmap_pois      = S.vmap_pois_pending
    S.vmap_pois_keys = S.vmap_pois_pending_keys or {}
    S.vmap_pois_pending = nil
    S.vmap_pois_pending_keys = {}
    S.vmap_pois_expecting = true
  end
end

-- LEGACY 2580. Empty branch in LEGACY -- registered as a no-op so
-- protocol.ingest doesn't record it as an unknown key.
M.VMAPL_END = function(val) end

-- LEGACY 2140
M.FLEET_RENOWN = function(val)
  S.fleet_renown = tonumber(val) or 0
end

-- Pattern-dispatched keys (LEGACY matches these with key:match(...) rather
-- than an exact elseif branch). Registered by init.lua via
-- protocol.pattern_handler, not protocol.handler -- these fn's receive the
-- key itself (to extract the embedded row index) as well as the value.

-- LEGACY 1322-1325 (`^VCR%d%d$`)
local function vcr_row(key, val)
  local ridx = tonumber(key:sub(4)) or 0
  S.mip_voyage_seen = true
  S.voyage_chart_rows[ridx + 1] = val or ""
end

-- LEGACY 2571-2573 (`^VMR%d%d$`)
local function vmr_row(key, val)
  local ridx = tonumber(key:sub(4)) or 0
  S.vmap_rows[ridx + 1] = val
end

-- LEGACY 2574-2576 (`^MEE%d%d$`)
local function mee_row(key, val)
  local ridx = tonumber(key:sub(4)) or 0
  S.vmap_east_edges[ridx + 1] = val
end

-- LEGACY 2577-2579 (`^MES%d%d$`)
local function mes_row(key, val)
  local ridx = tonumber(key:sub(4)) or 0
  S.vmap_south_edges[ridx + 1] = val
end

M._patterns = {
  { pattern = "^VCR%d%d$", fn = vcr_row },
  { pattern = "^VMR%d%d$", fn = vmr_row },
  { pattern = "^MEE%d%d$", fn = mee_row },
  { pattern = "^MES%d%d$", fn = mes_row },
}

return M
