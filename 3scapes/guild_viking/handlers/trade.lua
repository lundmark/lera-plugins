-- Trade and economy payload parsers, ported verbatim from LEGACY
-- guild_viking.lua (github.com/.../3s_scripts_old, read-only reference).
-- Each parser body transcribes its LEGACY `elseif key == "..."` branch:
-- string.split -> util.split, state. -> S. (module-local alias). Display
-- calls (viking_window.*, ColourNote) are dropped -- protocol.ingest already
-- marks ui.dirty(); parsers never do.
local S = require("state").S
local util = require("util")

local M = {}

-- MARKET/TGOODS seam for Task 7's market module (price history, demand
-- tracking). nil until Task 7 sets it; parsers call through only when set.
M._market_seam = { on_market = nil, on_tgoods = nil }

-- 1-char good abbreviations used by TGOODS (LEGACY guild_viking.lua:41-47).
local GOOD_SHORT = {
  t = "timber", o = "ore",   i = "iron",  f = "furs",  h = "fish",
  g = "grain",  m = "mead",  a = "amber", r = "runestones",
  s = "spoils", k = "salted_fish", b = "bread", e = "fine_furs",
  l = "tools",  j = "gemstones", y = "honey",
  w = "weapons", u = "armour", n = "finery",
}

-- STAFF stat-slot order (LEGACY guild_viking.lua:2348).
local STAFF_STAT_ORDER = { "combat", "trade", "craft", "sea", "wild", "land", "charm" }

-- LEGACY 941
M.CARTS = function(val)
  S.carts = {}
  for entry in val:gmatch("[^;]+") do
    if #S.carts >= 30 then break end  -- Safety limit
    local escort_n = 0
    local refit = "standard"
    local f = util.split(entry, "|")
    local fields = #f
    if fields >= 5 then
      local mode, good, village = f[1], f[2], f[3]
      local ret, amt, half, quality, cid, ctier, cdur, ccap, cesc, legs_str =
        f[4], f[5], f[6] or "", f[7] or "", f[8] or "", f[9] or "",
        f[10] or "", f[11] or "", f[12] or "", f[13] or ""
      if fields >= 14 then
        refit = f[13] or "standard"
        legs_str = f[14] or ""
      end
      escort_n = tonumber(cesc) or 0
      if refit == "" then refit = "standard" end
      local legs = {}
      if legs_str and #legs_str > 0 then
        local leg_sep = legs_str:find("!") and "[^!]+" or "[^;]+"
        for leg_entry in legs_str:gmatch(leg_sep) do
          local lf = util.split(leg_entry, "|")
          if #lf >= 4 then
            table.insert(legs, { mode=lf[1], good=lf[2], amount=tonumber(lf[3]) or 0, village=lf[4] })
          end
        end
      end
      table.insert(S.carts, { mode=mode, good=good, village=village,
        return_in=tonumber(ret) or 0, amount=tonumber(amt) or 0,
        halfway_in=tonumber(half) or 0, quality_pct=tonumber(quality) or 100,
        cart_id=tonumber(cid) or 0, tier=tonumber(ctier) or 1,
        durability=tonumber(cdur) or 100, cap=tonumber(ccap) or 0,
        escort=escort_n, refit=refit, legs=legs })
    end
  end
end

-- LEGACY 978
M.COURIER = function(val)
  -- Value = "<tier>!<entries>"; each entry good|village|secs|amount|cost|fee
  S.courier = { tier = 0, runs = {} }
  local tstr, entries = val:match("^([^!]*)!(.*)$")
  if not tstr then tstr, entries = val, "" end
  S.courier.tier = tonumber(tstr) or 0
  for entry in (entries or ""):gmatch("[^;]+") do
    local good, village, secs, amt, cost, fee =
      entry:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    if good then
      table.insert(S.courier.runs, { good=good, village=village,
        return_in=tonumber(secs) or 0, amount=tonumber(amt) or 0,
        cost=tonumber(cost) or 0, fee=tonumber(fee) or 0 })
    end
  end
end

-- LEGACY 993
M.SPY = function(val)
  -- Value = "<tier>|<mode>|<village>|<secs>|<sabpct>|<sabsecs>|<cdsecs>!<scouts>"
  S.spy = { tier = 0, mode = "", village = "", secs = 0, sab_pct = 0, sab_secs = 0, cd_secs = 0, scouts = {} }
  local scalar, scouts = val:match("^([^!]*)!(.*)$")
  if not scalar then scalar, scouts = val, "" end
  local tier, mmode, mvil, msecs, sabpct, sabsecs, cdsecs =
    scalar:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
  if tier then
    S.spy.tier = tonumber(tier) or 0
    S.spy.mode = mmode or ""
    S.spy.village = mvil or ""
    S.spy.secs = tonumber(msecs) or 0
    S.spy.sab_pct = tonumber(sabpct) or 0
    S.spy.sab_secs = tonumber(sabsecs) or 0
    S.spy.cd_secs = tonumber(cdsecs) or 0
  end
  for entry in (scouts or ""):gmatch("[^;]+") do
    local city, amb, secs = entry:match("^([^:]+):([^:]+):([^:]+)$")
    if city then
      table.insert(S.spy.scouts, { city = city, amb = tonumber(amb) or 0, secs = tonumber(secs) or 0 })
    end
  end
end

-- LEGACY 1015
M.HEAT = function(val)
  S.heat = {}
  for v in val:gmatch("[^;]+") do
    table.insert(S.heat, tonumber(v) or 0)
  end
end

-- LEGACY 1020
M.TRAIN = function(val)
  -- Value = "<tier>|<name>|<stat>|<trained>|<secs>"
  S.train = { tier = 0, name = "", stat = "", trained = 0, secs = 0 }
  local tier, nm, stat, tr, secs = val:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
  if tier then
    S.train.tier = tonumber(tier) or 0
    S.train.name = nm or ""
    S.train.stat = stat or ""
    S.train.trained = tonumber(tr) or 0
    S.train.secs = tonumber(secs) or 0
  end
end

-- LEGACY 1031
M.CUPG = function(val)
  S.cart_upgrades = {}
  for entry in val:gmatch("[^;]+") do
    local f = util.split(entry, "|")
    local cid, ttier, sleft, mt, md = f[1], f[2], f[3], f[4], f[5]
    local mat_str = f[6] or ""
    local target_refit = f[7] or ""
    local job_type = f[8] or ""
    if cid then
      local mats = {}
      if mat_str and #mat_str > 0 then
        for piece in mat_str:gmatch("[^,]+") do
          local g, d, n = piece:match("^([^:]+):(%d+)/(%d+)$")
          if g then
            table.insert(mats, { good=g, done=tonumber(d) or 0, need=tonumber(n) or 0 })
          end
        end
      end
      if job_type == "" then
        job_type = (target_refit ~= "" and "refit" or "upgrade")
      end
      table.insert(S.cart_upgrades, {
        cart_id=tonumber(cid) or 0, target_tier=tonumber(ttier) or 2,
        secs_left=tonumber(sleft) or 0,
        mats_total=tonumber(mt) or 0, mats_done=tonumber(md) or 0,
        target_refit=target_refit, job_type=job_type,
        mats=mats })
    end
  end
end

-- LEGACY 1060
M.CIDLE = function(val)
  S.idle_carts = {}
  for entry in val:gmatch("[^;]+") do
    local cid, ctier, cdur, ccap, crefit = entry:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    if not cid then
      cid, ctier, cdur, ccap = entry:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
      crefit = "standard"
    end
    if cid then
      table.insert(S.idle_carts, {
        cart_id=tonumber(cid) or 0, tier=tonumber(ctier) or 1,
        durability=tonumber(cdur) or 100, cap=tonumber(ccap) or 0, refit=crefit or "standard" })
    end
  end
end

-- LEGACY 1074
M.TQUEUE = function(val)
  S.trade_queue = {}
  for job_entry in val:gmatch("[^;]+") do
    local legs = {}
    local escort = 0
    local leg_strings = util.split(job_entry, "!")
    for idx, ls in ipairs(leg_strings) do
      local lf = util.split(ls, "|")
      if #lf >= 4 then
        table.insert(legs, {
          mode = lf[1],
          good = lf[2],
          amount = tonumber(lf[3]) or 0,
          village = lf[4]
        })
        if idx == #leg_strings and #lf >= 5 then
          escort = tonumber(lf[5]) or 0
        end
      end
    end
    if #legs > 0 then
      local first = legs[1]
      table.insert(S.trade_queue, {
        mode = first.mode, good = first.good,
        amount = first.amount, village = first.village,
        escort = escort, legs = legs })
    end
  end
end

-- LEGACY 1411
M.WSTOCK = function(val)
  S.wstock = {}
  S.wstock_by_good = {}
  for entry in val:gmatch("[^;]+") do
    if #S.wstock >= 50 then break end  -- Safety limit
    -- good|amount|pct  or  good|amount|pct|gradelabel (graded goods)
    local good, amt, pct, lbl = entry:match("^([^|]+)|([^|]+)|([^|]+)|(.*)$")
    if not good then
      good, amt, pct = entry:match("^([^|]+)|([^|]+)|([^|]+)$")
      lbl = nil
    end
    if good then
      local rec = { good=good, amount=tonumber(amt) or 0,
        freshness_pct=tonumber(pct) or 100,
        grade=(lbl and lbl ~= "" and lbl or nil) }
      table.insert(S.wstock, rec)
      S.wstock_by_good[good] = rec
    end
  end
end

-- LEGACY 1430
M.BLOCKS = function(val)
  -- good:amount pairs -- goods reserved from dispatch via 'vtrade block'.
  S.blocks = {}
  for entry in val:gmatch("[^;]+") do
    local g, a = entry:match("^([^:]+):(%d+)$")
    if g then S.blocks[g] = tonumber(a) or 0 end
  end
end

-- LEGACY 1437
M.CELLAR = function(val)
  local stock, cap, tier = val:match("^([^|]+)|([^|]+)|([^|;]+)")
  S.cellar = {
    stock = tonumber(stock) or 0,
    cap = tonumber(cap) or 0,
    tier = tonumber(tier) or 0,
    lots = {}
  }
  -- Parse per-quality-bracket entries after header
  local lots_part = val:match("^[^|]+|[^|]+|[^|;]+;(.*)$")
  if lots_part then
    for lot_entry in lots_part:gmatch("[^;]+") do
      local qty, pct = lot_entry:match("^([^|]+)|([^|]+)$")
      if qty then
        table.insert(S.cellar.lots, { qty=tonumber(qty) or 0, pct=tonumber(pct) or 100 })
      end
    end
  end
end

-- LEGACY 1455
M.REFINERY = function(val)
  -- bldg:tier:stock:cap:grade,qty;grade,qty  (buildings joined by '|')
  S.refineries = {}
  if val and #val > 0 then
    for entry in val:gmatch("[^|]+") do
      local bid, tier, stock, cap, grades = entry:match("^([^:]+):([^:]+):([^:]+):([^:]+):(.*)$")
      if bid then
        local r = { id=bid, tier=tonumber(tier) or 0, stock=tonumber(stock) or 0,
                    cap=tonumber(cap) or 0, grades={} }
        if grades and #grades > 0 then
          for g in grades:gmatch("[^;]+") do
            local gname, gqty, gpct = g:match("^([^,]+),([^,]+),([^,]+)$")
            if not gname then
              gname, gqty = g:match("^([^,]+),([^,]+)$")
            end
            if gname then r.grades[#r.grades+1] = { name=gname,
              qty=tonumber(gqty) or 0, pct=tonumber(gpct) or 100 } end
          end
        end
        S.refineries[#S.refineries+1] = r
      end
    end
  end
end

-- LEGACY 2168
M.ROUTES = function(val)
  S.routes = {}
  if val and #val > 0 then
    for entry in val:gmatch("[^;]+") do
      local vid, vname, road_tier, fort_tier, road_maint, fort_maint, road_name, fort_name = entry:match("^([^|]+)|([^|]+)|(%-?%d+)|(%-?%d+)|(%d+)|(%d+)|([^|]*)|([^|]*)$")
      if vid then
        S.routes[vid] = {
          name = vname or vid,
          road_tier = tonumber(road_tier) or 0,
          fort_tier = tonumber(fort_tier) or 0,
          road_maint = tonumber(road_maint) or 0,
          fort_maint = tonumber(fort_maint) or 0,
          road_name = road_name or "",
          fort_name = fort_name or "",
        }
      end
    end
  end
end

-- LEGACY 2186
M.RUPKEEP = function(val)
  S.route_upkeep = tonumber(val) or 0
end

-- LEGACY 2188
M.UPKEEP = function(val)
  -- Full per-tick daler upkeep breakdown (mirrors the vpayable command).
  local ro, co, th, rd, fo, tot =
    val:match("^(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)$")
  if ro then
    S.upkeep = { roster = tonumber(ro) or 0, community = tonumber(co) or 0,
                 throne = tonumber(th) or 0, roads = tonumber(rd) or 0,
                 forts = tonumber(fo) or 0, total = tonumber(tot) or 0 }
  end
end

-- LEGACY 2197
M.RBUILD = function(val)
  -- Roads/forts under construction, keyed "kind:vid" for lookup in the
  -- Trade Routes render. secs_left: -1 awaiting mats, 0 finalizing, >0 remaining.
  S.route_builds = {}
  if val and #val > 0 then
    for entry in val:gmatch("[^;]+") do
      local vid, vname, kind, tier, mt, md, cs, tbs, mat_str =
        entry:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|(%-?%d+)|([^|]+)|?(.*)$")
      if vid then
        local mats = {}
        if mat_str and mat_str ~= "" then
          for gentry in mat_str:gmatch("[^,]+") do
            local good, done, need = gentry:match("^([^:]+):(%d+)/(%d+)$")
            if good then
              table.insert(mats, { good=good, done=tonumber(done) or 0, need=tonumber(need) or 0 })
            end
          end
        end
        S.route_builds[kind .. ":" .. vid] = {
          vid = vid, name = vname or vid, kind = kind,
          tier = tonumber(tier) or 1,
          mats_total = tonumber(mt) or 0, mats_done = tonumber(md) or 0,
          complete_at_secs = tonumber(cs) or -1,
          total_build_secs = tonumber(tbs) or 0,
          mats = mats,
        }
      end
    end
  end
end

-- LEGACY 2346
M.STAFF = function(val)
  S.staff_list = {}
  for entry in val:gmatch("[^;]+") do
    if #S.staff_list >= 50 then break end  -- Safety limit
    local nm, asgn, skey, stats_s, tr, loy, age, arrive =
      entry:match("^([^|]+)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
    if not nm then
      -- 5-field fallback for older servers
      nm, asgn, skey, stats_s, tr =
        entry:match("^([^|]+)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
    end
    if not nm then nm, asgn = entry:match("^([^|]+)|([^|]*)$") end  -- old server fallback
    if nm then
      local stbl = {}
      local si2 = 0
      for v in (stats_s or ""):gmatch("[^,]+") do
        si2 = si2 + 1
        if STAFF_STAT_ORDER[si2] then stbl[STAFF_STAT_ORDER[si2]] = tonumber(v) or 0 end
      end
      table.insert(S.staff_list, { name=nm, assigned_to=asgn or "0",
        stat_key=skey or "", stats=stbl, trait=tr or "0",
        loyalty=tonumber(loy) or 3, age=age or "veteran",
        arrive_at=tonumber(arrive) or 0 })
    end
  end
end

-- LEGACY 2372
M.BONDS = function(val)
  S.bonds_list = {}
  for entry in val:gmatch("[^;]+") do
    local fa, fb, ticks, tier = entry:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    if fa then
      table.insert(S.bonds_list, {
        id_a  = tonumber(fa)    or 0,
        id_b  = tonumber(fb)    or 0,
        ticks = tonumber(ticks) or 0,
        tier  = tonumber(tier)  or 0 })
    end
  end
end

-- LEGACY 2459. No history-recording call exists in this LEGACY branch (unlike
-- TGOODS); the seam is invoked once per packet with the rebuilt orders list
-- so Task 7's market module can observe order-book changes.
M.MARKET = function(val)
  S.market_orders = {}
  for entry in val:gmatch("[^;]+") do
    local mo_id, mo_buyer, mo_good, mo_remain, mo_price, mo_age =
      entry:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    if mo_id then
      table.insert(S.market_orders, {
        id      = tonumber(mo_id)     or 0,
        buyer   = mo_buyer,
        good    = mo_good,
        remaining = tonumber(mo_remain) or 0,
        price   = tonumber(mo_price)  or 0,
        age_secs = tonumber(mo_age)   or 0 })
    end
  end
  if M._market_seam.on_market then M._market_seam.on_market(S.market_orders) end
end

-- LEGACY 2474
M.INCOMING = function(val)
  S.incoming_fills = {}
  for entry in val:gmatch("[^;]+") do
    local ig, ia, isecs, isel = entry:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    if ig then
      table.insert(S.incoming_fills, {
        good      = ig,
        amount    = tonumber(ia)    or 0,
        arrives_in = tonumber(isecs) or 0,
        seller    = isel or "" })
    end
  end
end

-- LEGACY 2486
M.DALER = function(val)
  S.daler = tonumber(val) or 0
end

-- LEGACY 2581. record_price_history(lin, good, buy, sell) (LEGACY:360) is
-- Task 7's territory; the seam is invoked with exactly the arguments that
-- call consumed, gated by the same "buyv > 0 or sellv > 0" condition.
M.TGOODS = function(val)
  -- val: "0=t:3:0:181;h:2:4:109|1=i:-2:102:26;f:2:1:120..."
  -- compact: 1-char good abbrev, numeric score (-3..3), supply, demand
  -- neutral entries omitted from packet
  -- Server now sends TGOODS in batched packets (6 lineages each).
  -- Reset trade_goods on first TGOODS of a burst, then accumulate.
  local now = os.time()
  if not S._tgoods_last or (now - S._tgoods_last) > 2 then
    S.trade_goods = {}
  end
  S._tgoods_last = now
  for lin_part in val:gmatch("[^|]+") do
    local lin_id_s, goods_s = lin_part:match("^(%d+)=(.*)$")
    if lin_id_s then
      local lin_id = tonumber(lin_id_s)
      S.trade_goods[lin_id] = {}
      for ge in goods_s:gmatch("[^;]+") do
        -- New 6-field format: abbr:score:sup:dem:buy:sell
        local abbr, score, sup, dem, buy, sell =
          ge:match("^([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):([^:]+)$")
        if not abbr then
          -- Legacy 4-field format (older server)
          abbr, score, sup, dem =
            ge:match("^([^:]+):([^:]+):([^:]+):([^:]+)$")
        end
        if abbr then
          local good = GOOD_SHORT[abbr] or abbr
          local buyv  = tonumber(buy)  or 0
          local sellv = tonumber(sell) or 0
          S.trade_goods[lin_id][good] = {
            score  = tonumber(score) or 0,
            supply = tonumber(sup)   or 0,
            demand = tonumber(dem)   or 0,
            buy    = buyv,
            sell   = sellv,
          }
          if buyv > 0 or sellv > 0 then
            if M._market_seam.on_tgoods then M._market_seam.on_tgoods(lin_id, good, buyv, sellv) end
          end
        end
      end
    end
  end
end

-- LEGACY 2624
M.VFIND = function(val)
  S.vfind = { tier = 0, postings = {}, offers = {}, auctions = {} }
  local tier, posts_s, offers_s, aucs_s = val:match("^([^!]*)!([^!]*)!([^!]*)!(.*)$")
  if tier then
    S.vfind.tier = tonumber(tier) or 0
    for entry in (posts_s or ""):gmatch("[^;]+") do
      local pid, stat, min_skill, max_wage, trait, pst = entry:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
      if pid then
        table.insert(S.vfind.postings, { id = tonumber(pid) or 0, stat = stat or "", min_skill = tonumber(min_skill) or 0, max_wage = tonumber(max_wage) or 0, trait = trait or "", state = pst or "" })
      end
    end
    for entry in (offers_s or ""):gmatch("[^;]+") do
      local oid, nm, wage, haggles, expires = entry:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
      if oid then
        table.insert(S.vfind.offers, { id = tonumber(oid) or 0, name = nm or "", wage = tonumber(wage) or 0, haggles = tonumber(haggles) or 0, expires_in = tonumber(expires) or 0 })
      end
    end
    for entry in (aucs_s or ""):gmatch("[^;]+") do
      local aid, nm, reserve, my_bid, closes = entry:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
      if aid then
        table.insert(S.vfind.auctions, { id = tonumber(aid) or 0, name = nm or "", reserve = tonumber(reserve) or 0, my_bid = tonumber(my_bid) or 0, closes_in = tonumber(closes) or 0 })
      end
    end
  end
end

return M
