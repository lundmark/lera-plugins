-- Raid, war, dynasty, army and kingdom payload parsers, ported verbatim from
-- LEGACY guild_viking.lua (github.com/.../3s_scripts_old, read-only
-- reference). Each parser body transcribes its LEGACY `elseif key == "..."`
-- branch: string.split -> util.split, state. -> S. (module-local alias).
-- Display calls (viking_window.*, ColourNote) are dropped -- protocol.ingest
-- already marks ui.dirty(); parsers never do.
local S = require("state").S
local util = require("util")

local M = {}

-- LEGACY 1127
M.RAIDLOG = function(val)
  S.raidlog = {}
  for entry in val:gmatch("[^;]+") do
    if #S.raidlog >= 20 then break end
    local ship, tgt, daler, thr, lost, goods_s =
      entry:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
    if ship then
      local goods = {}
      for g, q in (goods_s or ""):gmatch("([^,:]+):(%d+)") do
        goods[#goods+1] = { good=g, qty=tonumber(q) or 0 }
      end
      table.insert(S.raidlog, { ship=ship, target=tgt,
        daler=tonumber(daler) or 0, thralls=tonumber(thr) or 0,
        lost=(lost == "1"), goods=goods })
    end
  end
end

-- LEGACY 1143
M.RTARGETS = function(val)
  -- val: "lin;lin;...|hist;hist;..." (two groups); each entry is
  -- "name:good1:good2". Keep a flat name list too.
  S.raid_targets = {}
  S.raid_targets_lin = {}
  S.raid_targets_hist = {}
  local lin_s, hist_s = val:match("^(.-)|(.*)$")
  if not lin_s then lin_s = val; hist_s = "" end
  local function parse_group(str, dest)
    for t in (str or ""):gmatch("[^;]+") do
      local nm, g1, g2 = t:match("^([^:]+):([^:]*):([^:]*)$")
      if not nm then nm = t end
      dest[#dest+1] = { name = nm, g1 = (g1 ~= "" and g1) or nil, g2 = (g2 ~= "" and g2) or nil }
      S.raid_targets[#S.raid_targets+1] = nm
    end
  end
  parse_group(lin_s, S.raid_targets_lin)
  parse_group(hist_s, S.raid_targets_hist)
end

-- LEGACY 1478
M.DYNASTY = function(val)
  -- realm|house|spouseName:spouseHouse:spouseAge|heir|living:cap|children
  -- child = name,gender,age,adult(0/1),trait,role   (role "-" if none)
  S.dynasty = nil
  if val and #val > 0 then
    local realm, house, spouse, heir, counts, kids =
      val:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|?(.*)$")
    if realm then
      local d = { realm = realm, house = house,
                  heir = (heir ~= "" and heir or nil), children = {} }
      if spouse and #spouse > 0 then
        local sn, sh, sa, srank = spouse:match("^([^:]*):([^:]*):([^:]*):?([^:]*)$")
        if sn then d.spouse = { name = sn, house = sh, age = tonumber(sa) or 0,
                                rank = tonumber(srank) or 1 } end
      end
      local living, cap = (counts or ""):match("^([^:]*):([^:]*)$")
      d.living = tonumber(living) or 0
      d.cap    = tonumber(cap) or 0
      if kids and #kids > 0 then
        for ch in kids:gmatch("[^;]+") do
          local nm, gen, age, adult, trait, role =
            ch:match("^([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*)$")
          if nm then
            d.children[#d.children+1] = {
              name = nm, gender = gen, age = tonumber(age) or 0,
              adult = (adult == "1"), trait = trait,
              role = (role ~= "-" and role ~= "" and role or nil) }
          end
        end
      end
      S.dynasty = d
    end
  end
end

-- LEGACY 1511
M.ARMY = function(val)
  -- conscripts|cap|used|uid,type,size,vet,ready(0/1),leaderName;...
  S.army = nil
  if val and #val > 0 then
    local consc, cap, used, units = val:match("^([^|]*)|([^|]*)|([^|]*)|?(.*)$")
    if consc then
      local a = { conscripts = tonumber(consc) or 0, cap = tonumber(cap) or 0,
                  used = tonumber(used) or 0, units = {} }
      if units and #units > 0 then
        for u in units:gmatch("[^;]+") do
          local uid, utype, size, vet, ready, leader, traits =
            u:match("^([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),(.*)$")
          if not uid then
            -- back-compat: older 6-field form without traits
            uid, utype, size, vet, ready, leader =
              u:match("^([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),(.*)$")
            traits = ""
          end
          if uid then
            local tlist = {}
            if traits and #traits > 0 then
              for t in traits:gmatch("[^:]+") do tlist[#tlist+1] = t end
            end
            a.units[#a.units+1] = {
              uid = tonumber(uid) or 0, type = utype, size = tonumber(size) or 0,
              vet = tonumber(vet) or 0, ready = (ready == "1"),
              leader = leader, traits = tlist }
          end
        end
      end
      S.army = a
    end
  end
end

-- LEGACY 1544. LEGACY:1552-1555, 1560-1562, 1627-1632 are `if BATTLE_DEBUG
-- then ColourNote(...) end` blocks (BATTLE_DEBUG is a module-level constant
-- `false`, LEGACY:491) -- dropped entirely as display-only debug logging.
-- active|phase|turn|warpoints|mode|target|budget:spent|w:h:dz|terrain|works|units
--   terrain: w*h glyphs row-major (. ^ * w = x #)  (w=marsh; '~' is reserved)
--   works:   w*h glyphs (. none, v stakes, u dugout)
--   unit (fielded): Y/F,label,size,coord,morale,type,leader,bid,ord
--     bid = per-battle unique unit id; ord = 1-based dup index when
--     2+ units share a type+side glyph (0 = unambiguous, no tag needed)
--   unit (reserve): R,label,size,uid,cost,leader   (deploy phase only)
M.BATTLE = function(val)
  S.battle = nil
  if val and #val > 0 then
    -- Split on | to avoid Lua pattern problems with the optional last '|'.
    local f = util.split(val, "|")
    local active = f[1]
    if active then
      -- Server may omit the works grid in some packets (10 vs 11 fields).
      local phase, turn, wp, mode, target, budg, wh, terr, works, units
      if #f >= 11 then
        phase, turn, wp, mode, target, budg, wh, terr, works, units =
          f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11]
      else
        phase, turn, wp, mode, target, budg, wh, terr, works, units =
          f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], "", f[10]
      end
      S.war_points = tonumber(wp) or 0
      if active == "1" then
        local budget, spent = (budg or ""):match("^([^:]*):([^:]*)$")
        local bw, bh, bdz = (wh or ""):match("^([^:]*):([^:]*):?([^:]*)$")
        bw = tonumber(bw) or 8; bh = tonumber(bh) or 8
        local b = { phase = phase, turn = tonumber(turn) or 0,
                    mode = mode, target = target,
                    budget = tonumber(budget) or 0, spent = tonumber(spent) or 0,
                    width = bw, height = bh, dz = tonumber(bdz) or 2, terrain = terr,
                    war_points = tonumber(wp) or 0, units = {}, reserve = {} }
        -- Slice the flat terrain string into per-row strings for drawing.
        if terr and #terr >= bw * bh and bw > 0 then
          b.terrain_rows = {}
          for ri = 1, bh do
            b.terrain_rows[ri] = terr:sub((ri - 1) * bw + 1, ri * bw)
          end
        end
        -- Field-works grid, same slicing.
        if works and #works >= bw * bh and bw > 0 then
          b.works_rows = {}
          for ri = 1, bh do
            b.works_rows[ri] = works:sub((ri - 1) * bw + 1, ri * bw)
          end
        end
        if units and #units > 0 then
          for u in units:gmatch("[^;]+") do
            -- split into fields (reserve=6 incl. leader, fielded=9 incl. bid/ord)
            local f2 = {}
            for x in (u .. ","):gmatch("([^,]*),") do f2[#f2+1] = x end
            local side = f2[1]
            if side == "R" then
              b.reserve[#b.reserve+1] = {
                label = f2[2], size = tonumber(f2[3]) or 0,
                uid = tonumber(f2[4]) or 0, cost = tonumber(f2[5]) or 0,
                leader = (f2[6] ~= "" and f2[6]) or nil }
            elseif side then
              -- Allied house levies ride with you under the hird type
              -- (the server reuses foe_hird for allied aid, so it has
              -- no "you"-side icon of its own); the client names them
              -- ally_levy so they load the green-tinted hird art.
              local uside = (side == "Y") and "you" or "foe"
              local utype = f2[6]
              if uside == "you" and utype == "foe_hird" then utype = "ally_levy" end
              b.units[#b.units+1] = {
                side = uside,
                label = f2[2], size = tonumber(f2[3]) or 0,
                coord = f2[4], morale = tonumber(f2[5]) or 0,
                utype = utype, leader = (f2[7] ~= "" and f2[7]) or nil,
                bid = tonumber(f2[8]) or 0, ord = tonumber(f2[9]) or 0 }
            end
          end
        end
        S.battle = b
      end
    end
  end
end

-- LEGACY 1636
M.DIPLO = function(val)
  -- allies:House@standing,...|foes:House@standing,...
  S.diplomacy = nil
  if val and #val > 0 then
    local allies_s, foes_s = val:match("^allies:([^|]*)|foes:(.*)$")
    local d = { allies = {}, foes = {} }
    local function parse_side(s, out)
      if not s then return end
      for tok in s:gmatch("[^,]+") do
        local house, standing = tok:match("^([^@]+)@(-?%d+)$")
        if house then
          out[#out+1] = { house = house, standing = tonumber(standing) or 0 }
        end
      end
    end
    parse_side(allies_s, d.allies)
    parse_side(foes_s, d.foes)
    if #d.allies > 0 or #d.foes > 0 then S.diplomacy = d end
  end
end

-- LEGACY 1655
M.WAR = function(val)
  -- cb:Town@days,...|incoming:Town@days@strength|camp:Town@def@max,...
  S.war = nil
  if val and #val > 0 then
    local cb_s   = val:match("cb:([^|]*)")   or ""
    local inc_s  = val:match("incoming:([^|]*)") or ""
    local camp_s = val:match("camp:([^|]*)")  or ""
    local w = { claims = {}, incoming = nil, campaigns = {} }
    for tok in cb_s:gmatch("[^,]+") do
      local town, days = tok:match("^([^@]+)@(-?%d+)$")
      if town then w.claims[#w.claims+1] = { town = town, days = tonumber(days) or 0 } end
    end
    if inc_s and #inc_s > 0 then
      local town, days, strength = inc_s:match("^([^@]+)@(-?%d+)@(%d+)$")
      if town then
        w.incoming = { town = town, days = tonumber(days) or 0,
                       strength = tonumber(strength) or 100 }
      end
    end
    for tok in camp_s:gmatch("[^,]+") do
      local town, def, mx = tok:match("^([^@]+)@(-?%d+)@(%d+)$")
      if town then
        w.campaigns[#w.campaigns+1] = { town = town,
          defense = tonumber(def) or 0, max = tonumber(mx) or 100 }
      end
    end
    if #w.claims > 0 or w.incoming or #w.campaigns > 0 then S.war = w end
  end
end

-- LEGACY 1914. Campaign war map: same double-buffer pattern as CPLAN (not in
-- this task's scope). Terrain rows (WMRnn) + a unit overlay (WMO) are
-- committed on WMEND.
M.WMAP = function(val)
  local f = util.split(val, "|")
  S.wm_pending = {
    active  = (tonumber(f[1]) or 0) == 1,
    dim     = tonumber(f[2]) or 0,
    turn    = tonumber(f[3]) or 0,
    mode    = f[4] or "offense",
    pending = tonumber(f[5]) or 0,
    town    = f[6] or "",
    works_budget = tonumber(f[7]) or 0,
    march_eta = tonumber(f[8]) or 0,   -- secs to next tile (0 = holding)
    rows    = {}, units = {}, queue = {},
  }
end

-- LEGACY 1929
M.WMU = function(val)
  -- Per-tile upkeep the marching host draws: food|mead|tools|iron|daler.
  if S.wm_pending then
    local u = util.split(val, "|")
    S.wm_pending.upkeep = {
      food = tonumber(u[1]) or 0, mead = tonumber(u[2]) or 0,
      tools = tonumber(u[3]) or 0, iron = tonumber(u[4]) or 0,
      daler = tonumber(u[5]) or 0 }
  end
end

-- LEGACY 1938
M.WMP = function(val)
  -- War captives summary: held|capacity|kin|pendingFlag|pendName|pendSize|pendCmd
  if S.wm_pending then
    local p = util.split(val, "|")
    S.wm_pending.prison = {
      held = tonumber(p[1]) or 0, cap = tonumber(p[2]) or 0,
      kin = tonumber(p[3]) or 0, pending = (tonumber(p[4]) or 0) == 1,
      pend_name = p[5] or "", pend_size = tonumber(p[6]) or 0,
      pend_cmd = (tonumber(p[7]) or 0) == 1, roster = {} }
  end
end

-- LEGACY 1948
M.WSPOIL = function(val)
  -- Campaign spoils so far: daler|renown|deedCount (paid only on a win).
  if S.wm_pending then
    local s = util.split(val, "|")
    S.wm_pending.spoils = {
      daler = tonumber(s[1]) or 0, renown = tonumber(s[2]) or 0,
      deeds = tonumber(s[3]) or 0 }
  end
end

-- LEGACY 1956
M.WSG = function(val)
  -- Siege engine park: engines|capacity
  if S.wm_pending then
    local s = util.split(val, "|")
    S.wm_pending.siege = {
      engines = tonumber(s[1]) or 0, cap = tonumber(s[2]) or 0 }
  end
end

-- LEGACY 1963
M.WMPL = function(val)
  -- Captive roster: id,name,size,cmd,val;...
  if S.wm_pending and S.wm_pending.prison then
    for entry in val:gmatch("[^;]+") do
      local id, nm, sz, cmd, v = entry:match("^([^,]+),([^,]+),([^,]+),([^,]+),(.+)$")
      if id then
        table.insert(S.wm_pending.prison.roster, {
          id = tonumber(id) or 0, name = nm, size = tonumber(sz) or 0,
          cmd = (tonumber(cmd) or 0) == 1, val = tonumber(v) or 0 })
      end
    end
  end
end

-- LEGACY 1980
M.WMO = function(val)
  if S.wm_pending then
    -- entries: "A:c,r,size,f" (your stack), "*:c,r,0" (objective),
    -- "<n>:c,r,size,f" (enemy army n). f = facing N/E/S/W.
    for entry in val:gmatch("[^;]+") do
      local id, c, r, rest = entry:match("^([^:]+):([^,]+),([^,]+),(.+)$")
      if id then
        local sz, f = rest:match("^([^,]+),?([^,]*)$")
        table.insert(S.wm_pending.units, {
          id = id, c = tonumber(c) or 0, r = tonumber(r) or 0,
          size = tonumber(sz) or 0, f = f or "" })
      end
    end
  end
end

-- LEGACY 1994
M.WMQ = function(val)
  -- Queued paths: "A:A1;B2|F:C3" (1-based names). Stored per unit.
  if S.wm_pending then
    S.wm_pending.queues = {}
    for unit_part in val:gmatch("[^|]+") do
      local id, sqs = unit_part:match("^([^:]+):(.*)$")
      if id and sqs and sqs ~= "" then
        S.wm_pending.queues[id] = {}
        for sq in sqs:gmatch("[^;]+") do
          local col = string.byte(sq:sub(1, 1)) - 65
          local row = (tonumber(sq:sub(2)) or 0) - 1
          if col and row and col >= 0 and row >= 0 then
            table.insert(S.wm_pending.queues[id],
              { c = col, r = row, sq = sq })
          end
        end
      end
    end
    S.wm_pending.queue = S.wm_pending.queues.A or {}
  end
end

-- LEGACY 2014. Dropped display/interaction call sites (see report):
-- `viking_window.update()` (display) and the `viking_camp_selected`/
-- `viking_camp_queue` resets (LEGACY:13362-13363 module globals owned by the
-- not-yet-ported click-to-move war-map window, out of scope for stage 1's
-- headless protocol layer). Every `state.*` write is kept.
M.WMEND = function(val)
  if S.wm_pending then
    local expected = tonumber(val) or 0
    -- Captives + siege park persist independently of an active campaign.
    S.prison = S.wm_pending.prison
    S.siege = S.wm_pending.siege
    if not S.wm_pending.active then
      S.war_map = nil                      -- no campaign -> clear
    elseif expected > 0 and #S.wm_pending.rows == expected then
      S.war_map = S.wm_pending          -- complete: commit (queue included)
    end
    S.wm_pending = nil
  end
end

-- LEGACY 2031
M.PATROL = function(val)
  local count, remaining = val:match("^([^|]*)|([^|]*)$")
  S.patrol = {
    count = tonumber(count) or 0,
    remaining = tonumber(remaining) or 0
  }
end

-- LEGACY 2094
M.GARRISON = function(val)
  local st, fr, gcap, defpow = val:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
  if st then
    S.garrison_stationed = tonumber(st)     or 0
    S.garrison_free      = tonumber(fr)     or 0
    S.garrison_cap       = tonumber(gcap)   or 0
    S.garrison_defpower  = tonumber(defpow) or 0
  end
end

-- LEGACY 2102
M.VARANG = function(val)
  S.varang_out = {}
  S.varang_in  = {}
  local out_s, in_s = val:match("^(.-)%^(.*)$")
  if not out_s then out_s, in_s = val:match("^(.-)%^%^(.*)$") end
  for entry in (out_s or ""):gmatch("[^;]+") do
    if #S.varang_out >= 30 then break end  -- Safety limit
    local nm, cnt, exp = entry:match("^([^|]+)|([^|]+)|([^|]+)$")
    if nm then table.insert(S.varang_out, { name=nm, count=tonumber(cnt) or 0, expires_in=tonumber(exp) or 0 }) end
  end
  for entry in (in_s or ""):gmatch("[^;]+") do
    if #S.varang_in >= 30 then break end  -- Safety limit
    local nm, cnt, exp = entry:match("^([^|]+)|([^|]+)|([^|]+)$")
    if nm then table.insert(S.varang_in,  { name=nm, count=tonumber(cnt) or 0, expires_in=tonumber(exp) or 0 }) end
  end
end

-- LEGACY 2117
M.THRALLS = function(val)
  local parts = {}
  for p in val:gmatch("[^|]+") do table.insert(parts, tonumber(p) or 0) end
  S.thralls = parts[1] or 0
  local bldg_order = {"longhouse","warehouse","farm","apiary","tannery","fishery","lumber_yard","mine","smithy","watchtower","palisade","salting_house","bakehouse","furriers_lodge","smelter","weaponry","armoury","goldsmith","skald_hall"}
  S.thrall_assignments = {}
  for i, bid in ipairs(bldg_order) do
    S.thrall_assignments[bid] = parts[i+1] or 0
  end
  S.thralls_longhouse = S.thrall_assignments["longhouse"] or 0
  S.thralls_warehouse = S.thrall_assignments["warehouse"] or 0
end

-- LEGACY 2128
M.THRALL_FOLLOWER = function(val)
  local lvl, nm, xp, xp_cap, carry_used, carry_cap, thrall_state =
    val:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
  if lvl then
    S.thrall_follower_level = tonumber(lvl) or 0
    S.thrall_follower_name = nm or ""
    S.thrall_follower_xp = tonumber(xp) or 0
    S.thrall_follower_xp_cap = tonumber(xp_cap) or 0
    S.thrall_follower_carry_used = tonumber(carry_used) or 0
    S.thrall_follower_carry_cap = tonumber(carry_cap) or 0
    S.thrall_follower_status = thrall_state or "none"
  end
end

-- LEGACY 2142
M.RAID = function(val)
  local ri, rf, rs = val:match("^([^|]+)|([^|]+)|([^|]+)$")
  if ri then
    S.raid_in       = tonumber(ri) or -1
    S.raid_faction  = rf or ""
    S.raid_strength = tonumber(rs) or 0
  end
end

-- LEGACY 2149
M.GRUDGES = function(val)
  -- Towns you've raided that may send reprisal raids (town:secs_left,...)
  S.grudges = {}
  if val and #val > 0 then
    for entry in val:gmatch("[^,]+") do
      local town, secs = entry:match("^(.+):(%d+)$")
      if town then
        S.grudges[#S.grudges+1] = { town = town, secs = tonumber(secs) or 0 }
      end
    end
  end
end

-- LEGACY 2338
M.BDMG = function(val)
  S.bdmg = {}
  for entry in val:gmatch("[^;]+") do
    local bid, pct = entry:match("^([^|]+)|([^|]+)$")
    if bid then
      table.insert(S.bdmg, { bldg_id=bid, pct=tonumber(pct) or 0 })
    end
  end
end

-- LEGACY 2384
M.STANDINGS = function(val)
  S.standings = {}
  for entry in val:gmatch("[^;]+") do
    local sid, sname, sscore, slabel, sown =
      entry:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    if sid then
      local lid = tonumber(sid) or 0
      S.standings[lid] = {
        name   = sname,
        score  = tonumber(sscore) or 0,
        label  = slabel,
        is_own = (sown == "1") }
    end
  end
end

-- LEGACY 2398
M.VREP = function(val)
  S.village_rep = {}
  for entry in val:gmatch("[^;]+") do
    local vid, vname, vrep, vrank, vstart, vnext =
      entry:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    if vid then
      local lid = tonumber(vid) or 0
      S.village_rep[lid] = {
        name     = vname,
        rep      = tonumber(vrep) or 0,
        rank     = tonumber(vrank) or 0,
        start_at = tonumber(vstart) or 0,
        next_at  = tonumber(vnext) or 0 }
    end
  end
end

-- LEGACY 2413
M.HIRD = function(val)
  S.hird_list = {}
  S.hird_by_id = {}
  for entry in val:gmatch("[^;]+") do
    local f = util.split(entry, "|")
    local fields = #f
    local hid, nm, st, lvl, atk, def, loy, hired, age_ph, mode, champ_f, wpn_f, arm_f
    local hm_mode = "neutral"
    if fields >= 11 then
      hid, nm, st, lvl, atk, def, loy, hired, age_ph, mode, champ_f, wpn_f, arm_f =
        f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11] or "", f[12] or "", f[13] or ""
      hm_mode = (mode == "offensive" or mode == "defensive") and mode or "neutral"
    elseif fields >= 10 then
      nm, st, lvl, atk, def, loy, hired, age_ph, mode, champ_f =
        f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10] or ""
      hm_mode = (mode == "offensive" or mode == "defensive") and mode or "neutral"
    elseif fields >= 9 then
      nm, st, lvl, atk, def, loy, hired, age_ph, mode =
        f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9] or ""
      hm_mode = (mode == "offensive" or mode == "defensive") and mode or "neutral"
    elseif fields >= 8 then
      nm, st, lvl, atk, def, loy, hired, age_ph =
        f[1], f[2], f[3], f[4], f[5], f[6], f[7] or "", f[8] or ""
    elseif fields >= 6 then
      nm, st, lvl, atk, def, loy =
        f[1], f[2], f[3], f[4], f[5], f[6]
    elseif fields >= 3 then
      nm, st, lvl = f[1], f[2], f[3]
    end
    if nm then
      hm_mode = (mode == "offensive" or mode == "defensive") and mode or "neutral"
      local rec = { name=nm, status=st,
        level=tonumber(lvl) or 1,
        atk=tonumber(atk) or 1,
        def=tonumber(def) or 1,
        loyalty=tonumber(loy) or 3,
        hired_at=tonumber(hired) or 0,
        age_phase=age_ph or "young",
        mode=hm_mode,
        champ=tonumber(champ_f) or 0,
        wpn=tonumber(wpn_f) or 0,
        arm=tonumber(arm_f) or 0 }
      table.insert(S.hird_list, rec)
      if hid then S.hird_by_id[tonumber(hid) or 0] = rec end
    end
  end
end

-- Pattern-dispatched key (LEGACY matches this with key:match(...) rather
-- than an exact elseif branch). Registered by init.lua via
-- protocol.pattern_handler, not protocol.handler -- fn receives the key
-- itself (to extract the embedded row index) as well as the value.

-- LEGACY 1975 (`^WMR%d%d$`)
local function wmr_row(key, val)
  if S.wm_pending then
    local ridx = tonumber(key:sub(4)) or 0
    S.wm_pending.rows[ridx + 1] = val
  end
end

M._patterns = {
  { pattern = "^WMR%d%d$", fn = wmr_row },
}

-- ---------------------------------------------------------------------------
-- Guild.Fleet writers
-- ---------------------------------------------------------------------------

-- raidlog + raidlog_goods. A raid entry's goods breakdown is a mapping, and a
-- record used as a container element may not hold one, so the server flattens
-- it into its own top-level array foreign-keyed by `idx` back to the parent
-- entry (_v_raidlog_goods in the mudlib's client.h). Rejoining them is this
-- writer's whole reason for being a composite.
--
-- Either half may arrive alone: frames are deltas, and a raid that brought
-- back nothing produces entries with no goods rows at all. So a missing
-- `raidlog` leaves the list alone, and missing goods simply means every entry
-- gets an empty breakdown.
local function write_raidlog(parts)
  if type(parts) ~= "table" then return end
  local entries = parts.raidlog
  if type(entries) ~= "table" then return end

  -- idx -> goods list, built in one pass. The server appends goods rows in the
  -- order the source mapping iterates, and that order is what MIP's
  -- comma-joined sub-list preserved, so append order is kept here too.
  local goods_by_idx = {}
  if type(parts.raidlog_goods) == "table" then
    for _, g in ipairs(parts.raidlog_goods) do
      if type(g) == "table" then
        local idx = tonumber(g.idx)
        if idx then
          local list = goods_by_idx[idx]
          if not list then list = {}; goods_by_idx[idx] = list end
          list[#list + 1] = { good = tostring(g.good or "?"),
                              qty = tonumber(g.amount) or 0 }
        end
      end
    end
  end

  S.raidlog = {}
  for i, r in ipairs(entries) do
    if #S.raidlog >= 20 then break end
    if type(r) == "table" then
      -- `idx` is the record's own 0-based position; fall back to the array
      -- position when a frame omits it, so a goods-less entry still lands.
      local idx = tonumber(r.idx)
      if idx == nil then idx = i - 1 end
      table.insert(S.raidlog, {
        ship    = tostring(r.ship or ""),
        target  = tostring(r.target or ""),
        daler   = tonumber(r.daler) or 0,
        thralls = tonumber(r.thralls) or 0,
        lost    = (tonumber(r.lost) or 0) ~= 0,
        goods   = goods_by_idx[idx] or {},
      })
    end
  end
end

-- rtargets_lineage + rtargets_historical. These never had a _v_ builder: MIP
-- joined the two arrays with a '|' into one scalar, so GMCP sends them as the
-- two arrays they always were. Each element is still the same
-- "name:good1:good2" string the MIP entries were -- the mudlib's own
-- _war_town_lineage reads them with explode(hold, ":")[0] -- so the per-entry
-- parse is unchanged.
--
-- autoraid.lua indexes S.raid_targets_lin and S.raid_targets_hist
-- positionally within their own group, so each group's order matters but the
-- two are never mixed. S.raid_targets, the flat concatenation, has no reader
-- outside this module; it is still maintained because MIP maintains it and
-- dropping it is a separate cleanup, not part of a transport change.
local function parse_target_group(list)
  local out = {}
  for _, entry in ipairs(list or {}) do
    local t = tostring(entry)
    local nm, g1, g2 = t:match("^([^:]+):([^:]*):([^:]*)$")
    if not nm then nm = t end
    out[#out + 1] = { name = nm, g1 = (g1 ~= "" and g1) or nil,
                      g2 = (g2 ~= "" and g2) or nil }
  end
  return out
end

local function write_rtargets(parts)
  if type(parts) ~= "table" then return end
  -- Each half is replaced only when the frame actually carried it. Frames are
  -- deltas, so rebuilding both from one half would empty the group that did
  -- not change -- the flat list below is then regenerated from what is
  -- STORED, not from what arrived, which is what keeps it whole.
  if parts.rtargets_lineage ~= nil then
    S.raid_targets_lin = parse_target_group(parts.rtargets_lineage)
  end
  if parts.rtargets_historical ~= nil then
    S.raid_targets_hist = parse_target_group(parts.rtargets_historical)
  end
  S.raid_targets = {}
  for _, group in ipairs({ S.raid_targets_lin or {}, S.raid_targets_hist or {} }) do
    for _, rec in ipairs(group) do
      S.raid_targets[#S.raid_targets + 1] = rec.name
    end
  end
end


-- ---------------------------------------------------------------------------
-- Guild.Roster writers
-- ---------------------------------------------------------------------------

-- hird. MIP tolerated five shorter field layouts from older servers; GMCP
-- carries a record, so a field the server did not send is simply absent and
-- takes its default. `hired` -> hired_at and `age` -> age_phase are the two
-- renames; `id` keys the by-id lookup rather than being stored on the record,
-- exactly as the MIP handler had it.
--
-- `mode` is normalised the same way MIP normalised it: anything that is not
-- "offensive" or "defensive" is "neutral", so an unfamiliar mode reads as the
-- harmless one rather than reaching the pages verbatim.
local function write_hird(records)
  if type(records) ~= "table" then return end
  S.hird_list = {}
  S.hird_by_id = {}
  for _, r in ipairs(records) do
    if type(r) == "table" and r.name ~= nil then
      local mode = tostring(r.mode or "")
      if mode ~= "offensive" and mode ~= "defensive" then mode = "neutral" end
      local rec = {
        name      = tostring(r.name),
        status    = r.status ~= nil and tostring(r.status) or nil,
        level     = tonumber(r.level) or 1,
        atk       = tonumber(r.atk) or 1,
        def       = tonumber(r.def) or 1,
        loyalty   = tonumber(r.loyalty) or 3,
        hired_at  = tonumber(r.hired) or 0,
        age_phase = tostring(r.age or "young"),
        mode      = mode,
        champ     = tonumber(r.champ) or 0,
        wpn       = tonumber(r.wpn) or 0,
        arm       = tonumber(r.arm) or 0,
      }
      table.insert(S.hird_list, rec)
      local hid = tonumber(r.id)
      if hid then S.hird_by_id[hid] = rec end
    end
  end
end

-- thralls. A mapping of `total` plus one count per building, where MIP sent
-- the same numbers positionally against a building order the client had to
-- keep in step with the server's. Keyed by name, that whole class of
-- off-by-one is gone: an unfamiliar building is simply a key nothing reads,
-- and a building the server stops sending defaults to 0 rather than shifting
-- every later count by one.
local THRALL_BUILDINGS = {
  "longhouse", "warehouse", "farm", "apiary", "tannery", "fishery",
  "lumber_yard", "mine", "smithy", "watchtower", "palisade", "salting_house",
  "bakehouse", "furriers_lodge", "smelter", "weaponry", "armoury", "goldsmith",
  "skald_hall",
}

local function write_thralls(rec)
  if type(rec) ~= "table" then return end
  S.thralls = tonumber(rec.total) or 0
  S.thrall_assignments = {}
  for _, bid in ipairs(THRALL_BUILDINGS) do
    S.thrall_assignments[bid] = tonumber(rec[bid]) or 0
  end
  S.thralls_longhouse = S.thrall_assignments.longhouse
  S.thralls_warehouse = S.thrall_assignments.warehouse
end

-- thrall_follower. `state` -> thrall_follower_status is the one rename.
local function write_thrall_follower(rec)
  if type(rec) ~= "table" then return end
  S.thrall_follower_level      = tonumber(rec.level) or 0
  S.thrall_follower_name       = tostring(rec.name or "")
  S.thrall_follower_xp         = tonumber(rec.xp) or 0
  S.thrall_follower_xp_cap     = tonumber(rec.xp_cap) or 0
  S.thrall_follower_carry_used = tonumber(rec.carry_used) or 0
  S.thrall_follower_carry_cap  = tonumber(rec.carry_cap) or 0
  S.thrall_follower_status     = tostring(rec.state or "none")
end

-- varang_out + varang_in, MIP's two '^'-separated sections. `secs` ->
-- expires_in. Each half is replaced only when the frame carried it, since the
-- two are independent keys over a delta transport.
local function parse_varang(list, cap)
  local out = {}
  for _, r in ipairs(list or {}) do
    if #out >= cap then break end
    if type(r) == "table" then
      out[#out + 1] = { name = tostring(r.name or ""),
                        count = tonumber(r.count) or 0,
                        expires_in = tonumber(r.secs) or 0 }
    end
  end
  return out
end

local function write_varang(parts)
  if type(parts) ~= "table" then return end
  if parts.varang_out ~= nil then S.varang_out = parse_varang(parts.varang_out, 30) end
  if parts.varang_in ~= nil then S.varang_in = parse_varang(parts.varang_in, 30) end
end

M._gmcp = {
  RAIDLOG          = write_raidlog,
  RTARGETS         = write_rtargets,
  HIRD             = write_hird,
  THRALLS          = write_thralls,
  THRALL_FOLLOWER  = write_thrall_follower,
  VARANG           = write_varang,
}

return M
