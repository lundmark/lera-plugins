-- Settlement, city-plan, buildings, missions and global-status payload
-- parsers, ported verbatim from LEGACY guild_viking.lua (github.com/.../
-- 3s_scripts_old, read-only reference). Each parser body transcribes its
-- LEGACY `elseif key == "..."` branch: string.split -> util.split,
-- state. -> S. (module-local alias). Display calls (viking_window.*,
-- ColourNote) are dropped -- protocol.ingest already marks ui.dirty();
-- parsers never do.
local S = require("state").S
local util = require("util")

local M = {}

-- LEGACY 1683
M.BLOT = function(val)
  local blot_state, reset_in, filled, total = val:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
  if blot_state then
    S.blot_status   = blot_state
    S.blot_reset_in = tonumber(reset_in) or 0
    S.blot_filled   = tonumber(filled)   or 0
    S.blot_total    = tonumber(total)     or 9
  end
end

-- LEGACY 1691
M.FARM = function(val)
  S.farm_plots = {}
  S.farm_wmod  = 0
  for entry in val:gmatch("[^;]+") do
    if #S.farm_plots >= 50 then break end  -- Safety limit
    local meta_wmod = entry:match("^meta|(.+)$")
    if meta_wmod then
      S.farm_wmod = tonumber(meta_wmod) or 0
    else
      -- Format: coord|shroom|time_left|fertilized|wilt_left
      local coord, shroom, tl, fert, wilt = entry:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]*)$")
      if coord then
        table.insert(S.farm_plots, { coord=coord, shroom=shroom,
          time_left=tonumber(tl) or 0, fertilized=tonumber(fert) or 0,
          wilt_left=tonumber(wilt) or -1 })
      end
    end
  end
end

-- LEGACY 1709
M.BUILDS = function(val)
  S.pending_builds = {}
  for entry in val:gmatch("[^;]+") do
    if #S.pending_builds >= 30 then break end  -- Safety limit
    local bid, btier, mt, md, cs, tbs, mat_str = entry:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]*)|?(.*)$")
    if not bid then
      -- old 6-field server fallback (no total_build_secs)
      bid, btier, mt, md, cs, mat_str = entry:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|?(.*)$")
    end
    if bid then
      local mats = {}
      if mat_str and mat_str ~= "" then
        for gentry in mat_str:gmatch("[^,]+") do
          local good, done, need = gentry:match("^([^:]+):(%d+)/(%d+)$")
          if good then
            table.insert(mats, { good=good, done=tonumber(done) or 0, need=tonumber(need) or 0 })
          end
        end
      end
      table.insert(S.pending_builds, { bldg_id=bid,
        tier=tonumber(btier) or 1, mats_total=tonumber(mt) or 0,
        mats_done=tonumber(md) or 0, complete_at_secs=tonumber(cs) or -1,
        total_build_secs=tonumber(tbs) or 0,
        mats=mats })
    end
  end
end

-- LEGACY 1735
M.SUPG = function(val)
  S.ship_upgrades = {}
  for entry in val:gmatch("[^;]+") do
    if #S.ship_upgrades >= 20 then break end  -- Safety limit
    local sname, stier, scs, mt, md, mat_str = entry:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|?(.*)$")
    if sname then
      local mats = {}
      if mat_str and #mat_str > 0 then
        for piece in mat_str:gmatch("[^,]+") do
          local g, d, n = piece:match("^([^:]+):(%d+)/(%d+)$")
          if g then
            table.insert(mats, { good=g, done=tonumber(d) or 0, need=tonumber(n) or 0 })
          end
        end
      end
      table.insert(S.ship_upgrades, { name=sname,
        tier=tonumber(stier) or 1, secs_left=tonumber(scs) or 0,
        mats_total=tonumber(mt) or 0, mats_done=tonumber(md) or 0,
        mats=mats })
    end
  end
end

-- LEGACY 1756
M.SETTLERS = function(val)
  local cnt, mood, tax, water, fert = val:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
  if cnt then
    S.settlers     = tonumber(cnt)   or 0
    S.settler_mood = tonumber(mood)  or 0
    S.settler_tax  = tonumber(tax)   or 0
    S.city_water   = tonumber(water) or 0
    S.city_fert    = tonumber(fert)  or 0
  end
end

-- LEGACY 1765
M.SETTLERX = function(val)
  local f = util.split(val, "|")
  local n = #f
  local edict, ed_left, ed_cd, hcap, hplots, havg, hqual, hup, jobs, emp, mstaff,
        mult, sec, dig, flour, net, tax_inc, cup, sust_s, emp_sc_s, sent_s, supply_secs, pop_secs
  if n >= 23 then
    edict, ed_left, ed_cd, hcap, hplots, havg, hqual, hup, jobs, emp, mstaff,
          mult, sec, dig, flour, net, tax_inc, cup, sust_s, emp_sc_s, sent_s, supply_secs, pop_secs =
      f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10],
      f[11], f[12], f[13], f[14], f[15], f[16], f[17], f[18], f[19], f[20],
      f[21], f[22], f[23]
  elseif n >= 21 then
    edict, ed_left, ed_cd, hcap, hplots, havg, hqual, hup, jobs, emp, mstaff,
          mult, sec, dig, flour, net, tax_inc, cup, sust_s, emp_sc_s, sent_s =
      f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10],
      f[11], f[12], f[13], f[14], f[15], f[16], f[17], f[18], f[19], f[20]
  elseif n >= 17 then
    edict, ed_left, ed_cd, hcap, hplots, havg, hqual, hup, jobs, emp, mstaff,
          mult, sec, dig, flour, net, cup =
      f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10],
      f[11], f[12], f[13], f[14], f[15], f[16], f[17]
  end
  if edict then
    S.settler_edict = edict or ""
    S.settler_edict_left = tonumber(ed_left) or 0
    S.settler_edict_cd = tonumber(ed_cd) or 0
    S.settler_housing_cap = tonumber(hcap) or 0
    S.settler_housing_plots = tonumber(hplots) or 0
    S.settler_housing_avg = tonumber(havg) or 0
    S.settler_housing_quality = tonumber(hqual) or 0
    S.settler_housing_upkeep = tonumber(hup) or 0
    S.settler_jobs = tonumber(jobs) or 0
    S.settler_employed = tonumber(emp) or 0
    S.settler_market_staffed = tonumber(mstaff) or 0
    S.settler_mult_pct = tonumber(mult) or 100
    S.settler_security = tonumber(sec) or 0
    S.settler_dignity = tonumber(dig) or 0
    S.settler_flourishing = tonumber(flour) or 0
    S.settler_community_net = tonumber(net) or 0
    S.settler_community_upkeep = tonumber(cup) or 0
    S.settler_sustenance = tonumber(sust_s)  or 0
    S.settler_emp_score  = tonumber(emp_sc_s) or 0
    S.settler_sentiment  = tonumber(sent_s)  or 0
    S.settler_supply_next = tonumber(supply_secs) or 0
    S.settler_pop_next    = tonumber(pop_secs)    or 0
  end
end

-- LEGACY 1811
M.SACTIONS = function(val)
  S.settler_actions = {}
  local a1, a2, a3, a4, a5, a6 = val:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
  local names = {
    { "Assembly", tonumber(a1) or 0 },
    { "Watch", tonumber(a2) or 0 },
    { "Crafts", tonumber(a3) or 0 },
    { "Feast", tonumber(a4) or 0 },
    { "Relief", tonumber(a5) or 0 },
    { "Works", tonumber(a6) or 0 },
  }
  for _, rec in ipairs(names) do
    if (rec[2] or 0) > 0 then
      table.insert(S.settler_actions, { name=rec[1], secs=rec[2] })
    end
  end
end

-- LEGACY 1827
M.SROLES = function(val)
  S.settler_roles = {}
  S.settler_commoner = 0
  S.settler_identity = ""
  local segs = util.split(val, ";")
  if segs[1] then
    local m = util.split(segs[1], "|")
    S.settler_commoner = tonumber(m[2]) or 0
    S.settler_identity = m[3] or ""
  end
  local labels = { smidir="Builders", verkamenn="Laborers",
    handverkarar="Artisans", kaupmenn="Merchants", boendr="Farmers",
    leidangr="Militia", vitkar="Seers", hasetar="Rowers" }
  for i = 2, #segs do
    local k, cur, tgt, work, bon = segs[i]:match("^([^:]*):([^:]*):([^:]*):([^:]*):([^:]*)$")
    if k and k ~= "" then
      table.insert(S.settler_roles, {
        key = k, label = labels[k] or k,
        cur = tonumber(cur) or 0, tgt = tonumber(tgt) or 0,
        work = tonumber(work) or 0, bonus = tonumber(bon) or 0,
      })
    end
  end
end

-- LEGACY 1850. Begin a NEW grid in a pending buffer; committed only on CPEND
-- once all rows arrived (double-buffer, like WMAP/WMEND's pattern).
M.CPLAN = function(val)
  local f = util.split(val, "|")
  S.cp_pending = {
    enabled = (tonumber(f[1]) or 0) == 1,
    dim     = tonumber(f[2]) or 12,
    placed  = tonumber(f[3]) or 0,
    cap     = tonumber(f[4]) or 0,
    coast   = tonumber(f[5]) or 0,
    moat    = (tonumber(f[6]) or 0) == 1,
    wall    = (tonumber(f[7]) or 0) == 1,
    gate    = tonumber(f[8]) or 6,
    mood    = tonumber(f[9]) or 0,
    margin  = tonumber(f[10]) or 3,
    rows    = {}, blds = {}, unplaced = {}, perks = "",
  }
end

-- LEGACY 1867
M.CPP = function(val)
  if S.cp_pending then S.cp_pending.perks = val or "" end
end

-- LEGACY 1874
M.CPB = function(val)
  if S.cp_pending then
    -- Accumulate (server sends CPB in bounded segments).
    for entry in val:gmatch("[^;]+") do
      local id,bx,by,bw,bh,pal,gl,nm =
        entry:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|?(.*)$")
      if id and id ~= "" then
        table.insert(S.cp_pending.blds, { id=id, x=tonumber(bx) or 0, y=tonumber(by) or 0,
          w=tonumber(bw) or 1, h=tonumber(bh) or 1, pal=pal or "e",
          glyph=gl or "?", name=(nm ~= "" and nm) or id })
      end
    end
  end
end

-- LEGACY 1887
M.CPU = function(val)
  if S.cp_pending then
    -- Accumulate (server sends CPU in bounded segments).
    for entry in val:gmatch("[^;]+") do
      local id,pal,gl,nm = entry:match("^([^|]*)|([^|]*)|([^|]*)|?(.*)$")
      if id and id ~= "" then
        table.insert(S.cp_pending.unplaced, { id=id, pal=pal or "e", glyph=gl or "?",
          name=(nm ~= "" and nm) or id })
      end
    end
  end
end

-- LEGACY 1898
M.CPEND = function(val)
  if S.cp_pending then
    local expected = tonumber(val) or 0
    local got = #S.cp_pending.rows
    S.cp_pending.expected = expected
    S.cp_pending.got = got
    if expected > 0 and got == expected then
      S.city_plan = S.cp_pending           -- complete: commit
    else
      -- Incomplete burst (dropped chunk): keep the last good grid,
      -- record the mismatch for the on-screen debug line.
      S.city_plan = S.city_plan or {}
      S.city_plan.dbg = string.format("dropped: got %d/%d rows", got, expected)
    end
    S.cp_pending = nil
  end
end

-- LEGACY 2037
M.SPROJ = function(val)
  S.settler_projects = {}
  for entry in val:gmatch("[^;]+") do
    if #S.settler_projects >= 30 then break end  -- Safety limit
    local pid, kind, from_t, to_t, secs, mtot, mdone, mdetail, daler = entry:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
    if pid then
      local mat_detail = {}
      if mdetail and mdetail ~= "" then
        for part in mdetail:gmatch("[^,]+") do
          local gname, have, need = part:match("^([^:]+):(%d+)/(%d+)$")
          if gname then
            mat_detail[gname] = { have = tonumber(have) or 0, need = tonumber(need) or 0 }
          end
        end
      end
      table.insert(S.settler_projects, {
        id = pid or "",
        kind = kind or "",
        from_tier = tonumber(from_t) or 0,
        to_tier = tonumber(to_t) or 0,
        secs_left = tonumber(secs) or 0,
        mats_total = tonumber(mtot) or 0,
        mats_done = tonumber(mdone) or 0,
        mat_detail = mat_detail,
        daler = tonumber(daler) or 0,
      })
    end
  end
end

-- LEGACY 2065
M.SHPLOTS = function(val)
  local t1, t2, t3, t4 = val:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
  local nt1 = tonumber(t1) or 0
  local nt2 = tonumber(t2) or 0
  local nt3 = tonumber(t3) or 0
  local nt4 = tonumber(t4) or 0
  S.settler_housing_plot_tiers = {
    t1 = nt1, t2 = nt2, t3 = nt3, t4 = nt4,
  }
  -- Recompute from live plot data (more accurate than snapshot)
  S.settler_housing_plots = nt1 + nt2 + nt3 + nt4
  S.settler_housing_cap   = nt1*18 + nt2*30 + nt3*45 + nt4*65
  if S.settler_housing_cap == 0 then S.settler_housing_cap = S.settler_housing_plots > 0 and S.settler_housing_plots*18 or 0 end
end

-- LEGACY 2078
M.SCIVICS = function(val)
  S.settler_community_buildings = {}
  for entry in val:gmatch("[^;]+") do
    local cid, ctier = entry:match("^([^:]+):(%d+)$")
    if cid then
      S.settler_community_buildings[cid] = tonumber(ctier) or 0
    end
  end
end

-- LEGACY 2086
M.SCONSUME = function(val)
  S.settler_consumption = {}
  for entry in val:gmatch("[^;]+") do
    local good, amt = entry:match("^([^:]+):(%d+)$")
    if good then
      S.settler_consumption[good] = tonumber(amt) or 0
    end
  end
end

-- LEGACY 2160
M.BUILDINGS = function(val)
  S.buildings = {}
  if val and #val > 0 then
    for entry in val:gmatch("[^,]+") do
      local bid, bt = entry:match("^([^:]+):(%d+)$")
      if bid then S.buildings[bid] = tonumber(bt) or 1 end
    end
  end
end

-- LEGACY 2226. Fully replace each packet so a good that stops being produced
-- (e.g. mead -> honey after the Apiary refactor) doesn't linger.
M.PRODUCTION = function(val)
  S.production = {}
  if val and #val > 0 then
    for entry in val:gmatch("[^,]+") do
      local good, amt = entry:match("^([^:]+):(-?%d+)$")
      if good then S.production[good] = tonumber(amt) or 0 end
    end
  end
end

-- LEGACY 2236
M.MONUMENTS = function(val)
  S.monuments = {}
  local parts = {}
  for p in val:gmatch("[^;]+") do
    if #parts >= 51 then break end  -- Safety limit (1 cap + 50 names)
    table.insert(parts, p)
  end
  S.monument_cap = tonumber(parts[1]) or 0
  for i = 2, #parts do
    local s = parts[i]:match("^%s*(.-)%s*$")
    if s and #s > 0 then table.insert(S.monuments, s) end
  end
end

-- LEGACY 2248
M.MISSIONS = function(val)
  S.missions = {}
  for entry in val:gmatch("[^;]+") do
    if #S.missions >= 20 then break end  -- Safety limit
    -- Try new 8-field format first: id|label|reward_rep|reward_daler|expires_in|origin_town|target_town|want_goods
    local id, lbl, rep, rwd, exp, origin_town, target_town, goods_s =
      entry:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
    if id and origin_town and target_town then
      -- New 8-field format detected
      local want = {}
      for g, q in goods_s:gmatch("([^,:|]+):(%d+)") do
        want[g] = tonumber(q) or 0
      end
      table.insert(S.missions, {
        id         = tonumber(id) or 0,
        label      = lbl or "",
        reward_rep = tonumber(rep) or 0,
        reward     = tonumber(rwd) or 0,
        expires_in = tonumber(exp) or 0,
        origin_town = origin_town or "",
        target_town = target_town or "",
        want_goods = want })
    else
      -- Fallback to old 7-field format: id|label|reward_rep|reward_daler|expires_in|town|want_goods
      local id2, lbl2, rep2, rwd2, exp2, town2, goods_s2 =
        entry:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
      if id2 then
        local want = {}
        for g, q in goods_s2:gmatch("([^,:|]+):(%d+)") do
          want[g] = tonumber(q) or 0
        end
        table.insert(S.missions, {
          id         = tonumber(id2) or 0,
          label      = lbl2 or "",
          reward_rep = tonumber(rep2) or 0,
          reward     = tonumber(rwd2) or 0,
          expires_in = tonumber(exp2) or 0,
          origin_town = "",  -- Not available in old format
          target_town = town2 or "",
          want_goods = want })
      end
    end
  end
  -- Refresh UI after missions data is updated
  -- (final update at end of viking_extra covers this)
end

-- LEGACY 2297
M.ERRAND = function(val)
  -- Try new 8-field format first: id|label|reward|expires|origin_town|target_town|reward_good|reward_qty
  local id, lbl, rwd, exp, origin_town, target_town, rgd, rqty =
    val:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")

  if id and id ~= "" and target_town and rgd then
    -- New 8-field format detected
    S.errand = {
      id          = tonumber(id) or 0,
      label       = lbl or "",
      reward      = tonumber(rwd) or 0,
      expires_in  = tonumber(exp) or 0,
      origin_town = origin_town or "",
      target_town = target_town or "",
      reward_good = rgd or "",
      reward_qty  = tonumber(rqty) or 0 }
  else
    -- Fallback to old 7-field format: id|label|reward|expires|target_town|reward_good|reward_qty
    local id2, lbl2, rwd2, exp2, target_town2, rgd2, rqty2 =
      val:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
    if id2 and id2 ~= "" then
      S.errand = {
        id          = tonumber(id2) or 0,
        label       = lbl2 or "",
        reward      = tonumber(rwd2) or 0,
        expires_in  = tonumber(exp2) or 0,
        origin_town = "",  -- Not available in old format
        target_town = target_town2 or "",
        reward_good = rgd2 or "",
        reward_qty  = tonumber(rqty2) or 0 }
    end
  end
  -- Refresh UI after errand data is updated
  -- (final update at end of viking_extra covers this)
end

-- LEGACY 2488
M.NEXTTICK = function(val)
  S.next_tick_in = tonumber(val) or 0
end

-- LEGACY 2490
M.CDTIME = function(val)
  local cd = tonumber(val) or 0
  if cd > 0 then
    S.dispatch_cd_expires_at = os.time() + cd
    S.dispatch_cd = cd
  else
    S.dispatch_cd_expires_at = nil
    S.dispatch_cd = 0
  end
end

-- LEGACY 2499. LEGACY branches `key == "GOD_POWER" or key == "GOD_ACTIVE"`
-- with an identical body for either key -- registered as two exact keys
-- sharing this one fn (protocol.handler exact-tier handlers get only the
-- value, so no key-aware wrapper is needed here).
M.GOD_POWER = function(val)
  local gn = tostring(val or "")
  local valid_gods = {
    Odin=true, Thor=true, Freyja=true, Freyr=true, Tyr=true, Loki=true,
    Frigg=true, Heimdall=true, Baldr=true, Hel=true, Njord=true,
    Skadi=true, Forseti=true
  }
  S.god_power_name = valid_gods[gn] and gn or ""
end
M.GOD_ACTIVE = M.GOD_POWER

-- LEGACY 2507. Same dual-key pattern as GOD_POWER/GOD_ACTIVE above.
M.GOD_POWER_NEXT = function(val)
  local secs = tonumber(val) or 0
  if secs < 0 then secs = 0 end
  S.god_power_next = secs
  S.god_power_next_at = os.time() + secs
end
M.GOD_NEXT = M.GOD_POWER_NEXT

-- LEGACY 2512
M.GOD_POWER_FOCUS = function(val)
  S.god_power_focus = tostring(val or "")
end

-- LEGACY 2514
M.DCYCLE = function(val)
  local dname, dsecs = val:match("^([^|]+)|([^|]+)$")
  if dname then
    S.demand_cycle = dname
    S.demand_cycle_in = tonumber(dsecs) or 0
  else
    S.demand_cycle = val or ""
    S.demand_cycle_in = 0
  end
end

-- LEGACY 2648
M.SEVENTS = function(val)
  S.settler_events = {}
  for entry in val:gmatch("[^;]+") do
    local ts, msg = entry:match("^([^|]+)|(.*)$")
    if ts then
      table.insert(S.settler_events, { ts = tonumber(ts) or 0, msg = msg or "" })
    end
  end
end

-- Pattern-dispatched key (LEGACY matches this with key:match(...) rather
-- than an exact elseif branch). Registered by init.lua via
-- protocol.pattern_handler, not protocol.handler -- fn receives the key
-- itself (to extract the embedded row index) as well as the value.

-- LEGACY 1869 (`^CPT%d%d$`)
local function cpt_row(key, val)
  if S.cp_pending then
    local ridx = tonumber(key:sub(4)) or 0
    S.cp_pending.rows[ridx + 1] = val
  end
end

M._patterns = {
  { pattern = "^CPT%d%d$", fn = cpt_row },
}

return M
