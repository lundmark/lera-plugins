-- Ships, voyage, and sea-map payload parsers, ported verbatim from LEGACY
-- guild_viking.lua (github.com/.../3s_scripts_old, read-only reference).
-- Each parser body transcribes its LEGACY `elseif key == "..."` branch:
-- string.split -> util.split, state. -> S. (module-local alias). Display
-- calls (viking_window.*, ColourNote) are dropped -- protocol.ingest already
-- marks ui.dirty(); parsers never do.
local S = require("state").S
local util = require("util")
local gmcp_grid = require("gmcp_grid")

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

-- The MIP territory-map keys (VMAPH, VMAPL, VMAPL_END, and the VMR/MEE/MES
-- row patterns below) are received and deliberately dropped: Guild.Map
-- replaces them outright, and `write_map` at the bottom of this file is the
-- only thing that fills S.vmap_*. They are registered as explicit no-ops
-- rather than left unregistered so protocol.ingest does not file three dozen
-- keys per map push under `unknown`, where /vik status reports keys nobody
-- has taught the client about yet.
--
-- Nothing is lost by dropping them. MIP's VMAPH has carried five fields
-- (w|h|px|py|active) since send_mip_map() gained the on-map flag, while the
-- parser this replaces anchored on exactly four -- so it never matched a real
-- frame, S.vmap_w stayed 0, and the Territory Map popup has been drawing
-- nothing on the MIP path regardless.
local function ignore_mip_map_key() end

M.VMAPH = ignore_mip_map_key
M.VMAPL = ignore_mip_map_key
M.VMAPL_END = ignore_mip_map_key

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

-- The MIP terrain and edge row keys, dropped for the reason given above
-- M.VMAPH. One shared no-op rather than three, since none of them reads its
-- arguments.
local function ignore_mip_map_row() end

M._patterns = {
  { pattern = "^VCR%d%d$", fn = vcr_row },
  { pattern = "^VMR%d%d$", fn = ignore_mip_map_row },
  { pattern = "^MEE%d%d$", fn = ignore_mip_map_row },
  { pattern = "^MES%d%d$", fn = ignore_mip_map_row },
}

-- ---------------------------------------------------------------------------
-- Guild.Map -- the territory map, GMCP only.
-- ---------------------------------------------------------------------------
--
-- Guild.Map is the one panel in this migration whose GMCP shape deliberately
-- differs from MIP's, and the difference is why the MIP path above is gone
-- rather than kept alongside. MIP bakes the player's 'X' into the terrain row
-- itself, so every single step rewrites the whole terrain plane -- about
-- 5.3KB reshipped through the delta cache on a 60x30 grid because someone
-- walked one tile. Guild.Map sends the rows clean and the position as its own
-- `pos` key, so a step costs about 20 bytes and the planes change only when
-- the world does.
--
-- The client model already wanted it this way: popups/map.lua has always
-- treated S.vmap_rows as terrain alone and drawn the marker itself from
-- S.vmap_px/S.vmap_py (see its make_grid), overwriting MIP's baked 'X' with
-- an identical one. The one place MIP's marker was not overwritten is
-- pathfinding.lua, which reads the same rows as terrain and therefore saw
-- 'X' -- not a real terrain glyph -- for whichever cell the player stood on.
-- Clean rows fix that as a side effect.
--
-- Every member is optional. Ordinary frames are deltas: a key absent means
-- unchanged, never empty, so a frame carrying only `pos` must move the marker
-- and leave the planes alone.
local function apply_dimensions(parts)
  local w = tonumber(parts.w)
  local h = tonumber(parts.h)
  if w == nil and h == nil then return end
  local new_w = w or S.vmap_w
  local new_h = h or S.vmap_h
  -- Rows sized for the old grid cannot be reinterpreted at a new width, and
  -- the surplus rows of a shrunk grid would otherwise linger below the map.
  if new_w ~= S.vmap_w or new_h ~= S.vmap_h then
    S.vmap_rows = {}
    S.vmap_east_edges = {}
    S.vmap_south_edges = {}
  end
  S.vmap_w = new_w
  S.vmap_h = new_h
end

-- Planes arrive as an array of row strings, one entry per row, already in the
-- 1-indexed-Lua-for-0-indexed-wire layout the renderer and pathfinding read
-- (rows[1] is wire row 0). The south plane is one row shorter than the grid
-- by construction -- it describes the boundary between row r and row r+1.
local function apply_plane(parts, gmcp_key, state_key, glyphs)
  local rows = parts[gmcp_key]
  if rows == nil then return end
  local enc = (S.vmap_enc or {})[gmcp_key]
  local decoded, failed = gmcp_grid.decode_plane(rows, enc, S.vmap_w or 0, glyphs)
  S[state_key] = decoded
  if failed > 0 then
    -- Printed per push rather than once: a plane that stops decoding is
    -- either a legend this client has fallen behind or a corrupt frame, and
    -- both are worth seeing every time rather than once per session.
    print(string.format("[vik] Guild.Map: %d of %d %s rows undecodable (enc=%s)",
      failed, #rows, gmcp_key, tostring(enc or "glyph")))
  end
end

local function apply_landmarks(parts)
  local landmarks = parts.landmarks
  if type(landmarks) ~= "table" then return end
  -- Rebuilt whole, not merged: `landmarks` is one array key, so a frame
  -- carrying it carries the entire list.
  local pois, keys = {}, {}
  for _, lm in ipairs(landmarks) do
    if type(lm) == "table" then
      local x = tonumber(lm.x) or -1
      local y = tonumber(lm.y) or -1
      -- One marker per cell, first one wins -- the same dedup the MIP path
      -- applied, and the same key shape, since popups/map.lua's own
      -- poi_lookup is likewise one-poi-per-cell.
      local ekey = x .. "," .. y
      if not keys[ekey] then
        keys[ekey] = true
        pois[#pois + 1] = {
          type  = tostring(lm.type or "?"),
          name  = tostring(lm.name or "?"),
          x = x, y = y,
          owner = tostring(lm.owner or ""),
        }
      end
    end
  end
  S.vmap_pois = pois
  S.vmap_pois_keys = keys
end

local function write_map(parts)
  if type(parts) ~= "table" then return end

  -- Decoding context first, and cached in state: `enc`, `legend` and
  -- `legend_edge` change only when the server's tables do, so a delta
  -- carrying fresh planes will not repeat them. Applying a plane against a
  -- stale legend from a previous connection would draw a valid-looking but
  -- wrong map, which is why state.reset_connection clears these three.
  if parts.enc ~= nil then S.vmap_enc = parts.enc end
  if parts.legend ~= nil then
    S.vmap_legend = parts.legend
    S.vmap_terrain_glyphs = gmcp_grid.terrain_glyphs(parts.legend)
  end
  if parts.legend_edge ~= nil then S.vmap_legend_edge = parts.legend_edge end

  -- Then dimensions, because a plane's rows are sized by the grid width.
  apply_dimensions(parts)

  local edge_glyphs = gmcp_grid.edge_glyphs()
  apply_plane(parts, "terrain", "vmap_rows", S.vmap_terrain_glyphs)
  apply_plane(parts, "east", "vmap_east_edges", edge_glyphs)
  apply_plane(parts, "south", "vmap_south_edges", edge_glyphs)

  if type(parts.pos) == "table" then
    S.vmap_px = tonumber(parts.pos.x) or -1
    S.vmap_py = tonumber(parts.pos.y) or -1
  end
  if parts.active ~= nil then S.vmap_active = tonumber(parts.active) or 0 end

  apply_landmarks(parts)
end

-- ---------------------------------------------------------------------------
-- Guild.Fleet: ships
-- ---------------------------------------------------------------------------
-- The GMCP record is the canonical shape and MIP's row is that record's values
-- joined in the same order (_mip_ships_value in the mudlib's client.h), so the
-- two carry identical data under different names. Only three fields are
-- renamed on the way in: `secs` is the countdown MIP called the return field,
-- `id` is the ship id, and `held` arrives as 0/1 where the client stores a
-- boolean.
--
-- The 20-ship cap is MIP's, kept deliberately: it is a display bound (the
-- Fleet page renders a list), not a wire limit, so it has to survive a
-- transport that no longer chunks.
local function write_ships(records)
  if type(records) ~= "table" then return end
  S.ships = {}
  for _, r in ipairs(records) do
    if #S.ships >= 20 then break end
    if type(r) == "table" then
      table.insert(S.ships, {
        name         = tostring(r.name or "?"),
        tier         = tonumber(r.tier) or 1,
        state        = tostring(r.state or "docked"),
        target       = tostring(r.target or ""),
        return_in    = tonumber(r.secs) or 0,
        -- Passed through as the number it is, including 0. Two consumers
        -- write `sh.ship_id or <fallback>` (autoraid.lua, pages/city.lua) and
        -- 0 is truthy in Lua, so folding 0 into nil here would silently change
        -- which branch they take. MIP yielded the number too.
        ship_id      = tonumber(r.id),
        crew         = tonumber(r.crew) or 0,
        convoy       = tonumber(r.convoy) or 0,
        convoy_size  = tonumber(r.convoy_size) or 0,
        convoy_bonus = tonumber(r.convoy_bonus) or 0,
        saga_title   = tostring(r.saga_title or ""),
        saga_raids   = tonumber(r.saga_raids) or 0,
        held         = (tonumber(r.held) or 0) ~= 0,
        durability   = tonumber(r.durability) or 100,
      })
    end
  end
end

-- Guild.City: weather. `strength` -> weather_str. The MIP twin lives here
-- rather than in the city module, so its writer does too.
local function write_weather(rec)
  if type(rec) ~= "table" then return end
  S.season      = tostring(rec.season or "")
  S.weather     = tostring(rec.weather or "")
  S.weather_str = tonumber(rec.strength) or 1
end

-- ---------------------------------------------------------------------------
-- Guild.Voyage writers
-- ---------------------------------------------------------------------------

-- Most of these keys set S.mip_voyage_seen. Its name is historical: the flag
-- means "voyage data has arrived on some transport", and popups/sea.lua,
-- popups/voyage.lua and autovoyage.lua all gate their whole no-data branch on
-- it. Leaving it unset on the GMCP path would take those three dark on a
-- GMCP-only profile, so the writers set it exactly where their MIP twins do.

-- voyage + voyage_crew_traits + voyage_ship_traits. The two trait arrays are
-- containers, which a record used as a container element may not hold, so the
-- server deletes them from the record and sends each as its own key. Five
-- fields are renamed: hull_stress -> stress, steps_sailed -> steps,
-- next_move_in -> next_move, captain_style -> captain, ship_identity ->
-- identity.
local function trait_list(arr)
  local out = {}
  for _, t in ipairs(arr or {}) do out[#out + 1] = tostring(t) end
  return out
end

local function write_voyage(parts)
  if type(parts) ~= "table" then return end
  S.mip_voyage_seen = true
  local rec = parts.voyage
  if rec == nil then return end
  -- An empty record is how the server says "no active voyage", the same thing
  -- MIP's empty VOYAGE value said.
  if type(rec) ~= "table" or rec.state == nil then
    S.voyage_status = nil
    S.voyage_wait = ""
    return
  end
  S.voyage_status = {
    state           = tostring(rec.state or ""),
    ship_id         = tonumber(rec.ship_id) or 0,
    ship_name       = tostring(rec.ship_name or ""),
    contract_name   = tostring(rec.contract_name or ""),
    contract_type   = tostring(rec.contract_type or ""),
    danger          = tonumber(rec.danger) or 0,
    x               = tonumber(rec.x) or 0,
    y               = tonumber(rec.y) or 0,
    width           = tonumber(rec.width) or 0,
    height          = tonumber(rec.height) or 0,
    hull            = tonumber(rec.hull) or 0,
    morale          = tonumber(rec.morale) or 0,
    supplies        = tonumber(rec.supplies) or 0,
    stress          = tonumber(rec.hull_stress) or 0,
    crew_alive      = tonumber(rec.crew_alive) or 0,
    crew_max        = tonumber(rec.crew_max) or 0,
    steps           = tonumber(rec.steps_sailed) or 0,
    next_move       = tonumber(rec.next_move_in) or 0,
    threat_name     = tostring(rec.threat_name or ""),
    threat_level    = tonumber(rec.threat_level) or 0,
    threat_pressure = tonumber(rec.threat_pressure) or 0,
    paused_type     = tostring(rec.paused_type or ""),
    weather_key     = tostring(rec.weather_key or ""),
    -- Fleet renown travels as its own key, not on this record; the MIP
    -- handler zeroed it here for the same reason.
    renown          = 0,
    captain         = tostring(rec.captain_style or ""),
    identity        = tostring(rec.ship_identity or ""),
    crew_traits     = trait_list(parts.voyage_crew_traits),
    ship_traits     = trait_list(parts.voyage_ship_traits),
  }
  -- Backward-compatible fallback the MIP handler also applies: infer the wait
  -- status from paused_type. A voyage_wait key in the same frame is applied by
  -- its own writer and wins, since it sorts after VOYAGE.
  S.voyage_wait = S.voyage_status.paused_type
end

-- longship + longship_crew_traits + longship_ship_traits. Same flattening,
-- but per ship: each trait row carries the ship `id` it belongs to. Renames:
-- id -> ship_id, secs -> return_in, voyage_identity -> identity,
-- captain_style -> captain.
local function write_longship(parts)
  if type(parts) ~= "table" then return end
  S.mip_voyage_seen = true
  if type(parts.longship) ~= "table" then return end
  local crew_by_id, ship_by_id = {}, {}
  local function collect(rows, into)
    for _, r in ipairs(rows or {}) do
      if type(r) == "table" and r.id ~= nil then
        local list = into[r.id]
        if not list then list = {}; into[r.id] = list end
        list[#list + 1] = tostring(r.trait or "")
      end
    end
  end
  collect(parts.longship_crew_traits, crew_by_id)
  collect(parts.longship_ship_traits, ship_by_id)

  S.voyage_longships = {}
  for _, r in ipairs(parts.longship) do
    if #S.voyage_longships >= 20 then break end
    if type(r) == "table" then
      table.insert(S.voyage_longships, {
        ship_id     = tonumber(r.id) or 0,
        name        = tostring(r.name or ""),
        tier        = tonumber(r.tier) or 1,
        state       = tostring(r.state or "docked"),
        target      = tostring(r.target or ""),
        return_in   = tonumber(r.secs) or 0,
        crew        = tonumber(r.crew) or 0,
        hired_crew  = tonumber(r.hired_crew) or 0,
        safe        = tonumber(r.safe) or 0,
        renown      = 0,
        identity    = tostring(r.voyage_identity or ""),
        captain     = tostring(r.captain_style or ""),
        crew_traits = crew_by_id[r.id] or {},
        ship_traits = ship_by_id[r.id] or {},
        saga_title  = tostring(r.saga_title or ""),
        saga_raids  = tonumber(r.saga_raids) or 0,
      })
    end
  end
end

local function write_voyage_wait(v)
  S.mip_voyage_seen = true
  S.voyage_wait = tostring(v or "")
end

-- A plain string array, capped as MIP capped it.
local function string_list_writer(field, cap, seen)
  return function(values)
    if type(values) ~= "table" then return end
    if seen then S.mip_voyage_seen = true end
    local out = {}
    for _, v in ipairs(values) do
      if #out >= cap then break end
      out[#out + 1] = tostring(v)
    end
    S[field] = out
  end
end

-- voffers + voffers_ship. MIP packed the ship name and the offer list into one
-- value; the two are separate keys here. `fit_code` -> fit, and a missing fit
-- defaults to 3 ("ready"), matching the MIP handler.
local function write_voffers(parts)
  if type(parts) ~= "table" then return end
  -- The two halves are independent keys over a delta transport. Only the
  -- arrival of `voffers` itself may clear the list: a frame carrying just a
  -- changed ship name must not be read as "no offers".
  if parts.voffers == nil then
    if parts.voffers_ship ~= nil and S.voyage_offers then
      S.voyage_offers.ship = tostring(parts.voffers_ship)
    end
    return
  end
  if type(parts.voffers) ~= "table" or #parts.voffers == 0 then
    S.voyage_offers = nil
    return
  end
  local list = {}
  for _, r in ipairs(parts.voffers) do
    if type(r) == "table" then
      list[#list + 1] = {
        index      = tonumber(r.index) or 0,
        type       = tostring(r.type or ""),
        name       = tostring(r.name or ""),
        danger     = tonumber(r.danger) or 0,
        difficulty = tostring(r.difficulty or ""),
        fit        = tonumber(r.fit_code) or 3,
      }
    end
  end
  local ship = parts.voffers_ship
  if ship == nil then ship = S.voyage_offers and S.voyage_offers.ship end
  S.voyage_offers = { ship = tostring(ship or ""), list = list }
end

-- vgoods / vaids / vrunes: a name -> count mapping on the wire, a
-- {name, count} list in state.
--
-- Sorted by name. A Lua pairs() walk over a mapping has no defined order, so
-- an unsorted list would reorder itself between frames with nothing in the
-- data to explain it -- the same class of flicker the declared GMCP key order
-- exists to prevent.
local function count_map_writer(field)
  return function(counts)
    if type(counts) ~= "table" then return end
    S.mip_voyage_seen = true
    local names = {}
    for name in pairs(counts) do names[#names + 1] = tostring(name) end
    table.sort(names)
    local out = {}
    for _, name in ipairs(names) do
      out[#out + 1] = { name = name, count = tonumber(counts[name]) or 0 }
    end
    S[field] = out
  end
end

-- vboons is a flags mapping over GMCP where MIP sent the finished display
-- string, so the phrasing has to live here now.
--
-- This is a FIXED CONTRACT mirrored in code, like minimap's glyph table: the
-- five branches and their exact wording are transcribed from
-- _mip_serialize_boons() in the mudlib's client.h, and a change there needs a
-- matching change here. The alternative -- rendering raw flag names -- would
-- put "storm_charm_ready" on the Sea popup where it used to read
-- "Storm Charm ready".
local function write_vboons(flags)
  if type(flags) ~= "table" then return end
  S.mip_voyage_seen = true
  -- 0 and false are both "off"; the server sends these as 0/1 ints, but a
  -- JSON boolean would arrive as false, and in Lua 0 is truthy.
  local function set(v) return v ~= nil and v ~= false and v ~= 0 end
  local parts = {}
  if set(flags.chart_fragment_used) then
    parts[#parts + 1] = "Chart Fragment used"
  end
  if set(flags.revealed_safe_cove) then
    parts[#parts + 1] = "Safe Cove Rumor active"
  end
  if set(flags.storm_charm_ready) then
    parts[#parts + 1] = "Storm Charm ready"
  end
  if set(flags.rigging_bonus) then
    parts[#parts + 1] = "Deepwater Rigging active"
  end
  local steps = tonumber(flags.favorable_current_steps) or 0
  if steps > 0 then
    parts[#parts + 1] = "Favorable Current " .. steps .. " fast step"
      .. ((steps == 1) and "" or "s") .. " left"
  end
  S.voyage_boons = table.concat(parts, ";")
end

-- vsailed: each element is the same "x,y" key MIP joined with ';'. Stored as a
-- [row][col] lookup, both 1-indexed for a 0-based wire coordinate.
local function write_vsailed(coords)
  if type(coords) ~= "table" then return end
  S.mip_voyage_seen = true
  S.voyage_sailed = {}
  for _, entry in ipairs(coords) do
    local x, y = tostring(entry):match("^(%d+),(%d+)$")
    if x then
      local ri, ci = tonumber(y) + 1, tonumber(x) + 1
      if not S.voyage_sailed[ri] then S.voyage_sailed[ri] = {} end
      S.voyage_sailed[ri][ci] = true
    end
  end
end

local function write_vspoils(v)
  S.mip_voyage_seen = true
  S.voyage_spoils_daler = tonumber(v) or 0
end

local function write_vreagent(v)
  S.mip_voyage_seen = true
  S.voyage_reagents = tonumber(v) or 0
end

local function write_fleet_renown(v)
  S.fleet_renown = tonumber(v) or 0
end

M._gmcp = {
  VMAP         = write_map,
  SHIPS        = write_ships,
  WEATHER      = write_weather,
  VOYAGE       = write_voyage,
  LONGSHIP     = write_longship,
  VOYAGE_WAIT  = write_voyage_wait,
  VOFFERS      = write_voffers,
  VRESOLVE     = string_list_writer("voyage_resolve_options", 10, true),
  VQPATH       = string_list_writer("voyage_queue", 100, true),
  VSAGA        = string_list_writer("voyage_saga", 200, true),
  VMEM         = string_list_writer("voyage_memory", 100, true),
  VCURIOS      = string_list_writer("voyage_curios", 50, true),
  VGOODS       = count_map_writer("voyage_goods"),
  VAIDS        = count_map_writer("voyage_aids"),
  VRUNES       = count_map_writer("voyage_runes"),
  VBOONS       = write_vboons,
  VSAILED      = write_vsailed,
  VSPOILS      = write_vspoils,
  VREAGENT     = write_vreagent,
  FLEET_RENOWN = write_fleet_renown,
}


return M
