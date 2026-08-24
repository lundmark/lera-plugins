-- guild_viking combat.lua unit tests. Run from the lera-plugins repo root
-- with LERA_ROOT pointing at a built Lera checkout.
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

-- ---- lera API stubs (same shape as guild_viking_test.lua) ------------------
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
  -- real shape: callback(key, code, data) -- key is the 5-digit packet
  -- sequence number, data is the payload string.
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
-- trigger stub captures registrations by pattern so init.lua wiring can be
-- exercised the same way guild_viking_test.lua exercises mip/gmcp wiring.
local trigger_handlers, trigger_id_count = {}, 0
trigger = {
  add = function(pattern, fn)
    trigger_id_count = trigger_id_count + 1
    trigger_handlers[trigger_id_count] = { pattern = pattern, fn = fn }
    return trigger_id_count
  end,
  remove = function(id) trigger_handlers[id] = nil end,
}
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

local S = require("state").S
local combat = require("combat")

-- Register combat.triggers the same way init.lua's on_load does, so the
-- trigger stub records them under the numeric ids the assertions below key
-- off of (1 = hp_bar_1, 2 = hp_bar_1_cont, ... 8 = hp_bar_3_cont).
for _, t in ipairs(combat.triggers) do
  trigger.add(t.pattern, t.fn)
end

-- ---- FFF composite: guild.events.mip_info (LEGACY 868-905) -----------------

combat.on_composite("A~350~B~500~")
check("composite A/B", S.hp == 350 and S.mhp == 500)

combat.on_composite("K~Wolf~")
check("composite K sets attacker and combat", S.mob_name_full == "Wolf" and S.combat == true)


-- ---- GMCP Guild.State: encounter / target --------------------------------
-- The MUD's hp-bar triggers already own S.en5/S.ens/S.rndz/S.combat, so these
-- writers deliberately fill only what nothing else writes when MIP is off.
check("gmcp writers exported", type(combat._gmcp) == "table"
      and type(combat._gmcp.TARGET) == "function"
      and type(combat._gmcp.ENCOUNTER) == "function",
      type(combat._gmcp))

-- Kills: not mapping target.name, which is the enemy name the Stats page's
-- Enemy block prints (pages/stats.lua:246) and the one field FFF's K tag owned.
S.mob_name_full = "stale"
combat._gmcp.TARGET({ name = "Ice Troll", name5 = "Ice T", hp_status = "wou" })
check("gmcp target.name fills mob_name_full", S.mob_name_full == "Ice Troll",
      S.mob_name_full)

-- Kills: a writer that invents a value for an absent enemy. The server sends
-- the literal "None", matching what FFF's K tag produced.
combat._gmcp.TARGET({ name = "None", name5 = "None", hp_status = "" })
check("gmcp target.name of None passes through", S.mob_name_full == "None",
      S.mob_name_full)

-- Kills: not mapping encounter.rounds (FFF's N tag).
S.combat_rounds = 99
combat._gmcp.ENCOUNTER({ active = 1, rounds = 7 })
check("gmcp encounter.rounds fills combat_rounds", S.combat_rounds == 7,
      S.combat_rounds)

-- Kills: a writer that also claims S.combat. The hp-bar triggers own it, and a
-- second writer on the same field is the collision class that bit the housing
-- totals -- so ENCOUNTER must leave it alone even though it carries `active`.
S.combat = "sentinel"
combat._gmcp.ENCOUNTER({ active = 0, rounds = 3 })
check("gmcp encounter leaves S.combat to the triggers", S.combat == "sentinel",
      tostring(S.combat))

-- Kills: trusting the payload. gmcp delivers nil for undecodable JSON, and a
-- delta frame may carry a group with fields missing.
S.mob_name_full = "keep"
combat._gmcp.TARGET(nil)
combat._gmcp.TARGET({})
check("gmcp target tolerates nil and empty", S.mob_name_full == "keep",
      S.mob_name_full)
S.combat_rounds = 5
combat._gmcp.ENCOUNTER(nil)
check("gmcp encounter tolerates nil", S.combat_rounds == 5, S.combat_rounds)

combat.on_composite("K~~")
check("composite K empty attacker clears combat", S.mob_name_full == "None" and S.combat == false)

combat.on_composite("L~42~")
check("composite L", S.estatus_pct == 42)

combat.on_composite("N~7~")
check("composite N", S.combat_rounds == 7)

-- M carries no value slot: LEGACY backs the index up by one instead of the
-- usual +2 stride, resyncing on the very next token rather than skipping it.
S.hp = 0
combat.on_composite("M~A~350~")
check("composite M resyncs onto the next tag", S.hp == 350)

do
  local before = dirty_count
  combat.on_composite("A~1~")
  check("composite marks dirty", dirty_count > before)
end

-- ---- hp_bar_1 (LEGACY 501) --------------------------------------------------
-- XML: ^H\[(\d+)\|(\d+)\((\d+)\|(\d+)\)\] S\[(\d+)\|(\d+)\] V\[(\d+)\|(\d+)\] R\[(\d+)\|(\d+)\](?: F(\[[^\]]*\]) C\[(\d+)/(\d+)\])?

local hp_bar_1 = trigger_handlers[1]
check("hp_bar_1 registered first", hp_bar_1.pattern:find("H\\[", 1, true) == 2)

S.hp_prev = 0
hp_bar_1.fn("H[350|500(70|100)] S[10|20] V[5|9] R[1|4]",
  "350", "500", "70", "100", "10", "20", "5", "9", "1", "4", nil, nil, nil)
check("hp_bar_1 no-fury base fields", S.hp == 350 and S.mhp == 500 and S.threk == 70
      and S.mthrek == 100 and S.seid == 10 and S.mseid == 20 and S.vig == 5 and S.mvig == 9
      and S.rad == 1 and S.mrad == 4)
check("hp_bar_1 first sample has no delta (hp_prev was 0)", S.hp_delta == 0 and S.hp_prev == 350)
check("hp_bar_1 fury/chain default to empty/zero when absent", S.fury == "" and S.chain == 0
      and S.bsdepth == 0)

hp_bar_1.fn("H[300|500(70|100)] S[10|20] V[5|9] R[1|4] F[----------] C[3/2]",
  "300", "500", "70", "100", "10", "20", "5", "9", "1", "4", "[----------]", "3", "2")
check("hp_bar_1 second sample computes hp_delta", S.hp == 300 and S.hp_delta == -50
      and S.hp_prev == 300)
check("hp_bar_1 fury/chain/bsdepth captured", S.fury == "[----------]" and S.chain == 3
      and S.bsdepth == 2)

-- wrapped sample: F/C absent, chain/bsdepth must hold their last-known value
hp_bar_1.fn("H[300|500(70|100)] S[10|20] V[5|9] R[1|4]",
  "300", "500", "70", "100", "10", "20", "5", "9", "1", "4", nil, nil, nil)
check("hp_bar_1 wrapped sample keeps last chain/bsdepth", S.chain == 3 and S.bsdepth == 2
      and S.fury == "[----------]")

-- ---- hp_bar_1_cont (LEGACY 587) --------------------------------------------
-- XML: ^[-*]*\] C\[(\d+)/(\d+)\]\s*$
local hp_bar_1_cont = trigger_handlers[2]
S.chain, S.bsdepth = 0, 0
hp_bar_1_cont.fn("----------] C[5/3]", "5", "3")
check("hp_bar_1_cont", S.chain == 5 and S.bsdepth == 3)

-- ---- hp_bar_2 (LEGACY 599) --------------------------------------------------
-- XML: ^G\[(\d+)\((\d+)\)\|(\d+)\((\d+)\)\|(\d+)\((\d+)\)\|(\d+)\((\d+)\)\] L\[(\d*)\|(\d*)\((\d*)%\)\] E\[([^|]*)\|([^|]*)(?:\|(\d*))?\]?
local hp_bar_2 = trigger_handlers[3]

S.vis_session, S.kap_session, S.soe_session, S.aud_session = 0, 0, 0, 0
S.xp_session_start = nil
-- mldng (11) is deliberately distinct from vis_gain (10): a c2/c10 capture
-- index swap in the trigger parser would otherwise pass this fixture.
hp_bar_2.fn("G[100(10)|200(20)|300(30)|400(40)] L[5|11(50%)] E[wolf|low|3]",
  "100", "10", "200", "20", "300", "30", "400", "40", "5", "11", "50", "wolf", "low", "3")
check("hp_bar_2 base fields", S.vis == 100 and S.vis_gain == 10 and S.kap == 200
      and S.kap_gain == 20 and S.soe == 300 and S.soe_gain == 30 and S.aud == 400
      and S.aud_gain == 40 and S.ldng == 5 and S.mldng == 11 and S.lrst == 50)
check("hp_bar_2 enemy fields", S.en5 == "wolf" and S.ens == "low" and S.rndz == 3)
check("hp_bar_2 combat true when enemy present", S.combat == true)
check("hp_bar_2 session accumulates on first sample", S.vis_session == 10 and S.kap_session == 20
      and S.soe_session == 30 and S.aud_session == 40 and S.xp_session_start ~= nil)

local session_start_after_first = S.xp_session_start
hp_bar_2.fn("G[110(10)|220(20)|330(30)|440(40)] L[5|11(50%)] E[wolf|low|4]",
  "110", "10", "220", "20", "330", "30", "440", "40", "5", "11", "50", "wolf", "low", "4")
check("hp_bar_2 session accumulates across two invocations", S.vis_session == 20
      and S.kap_session == 40 and S.soe_session == 60 and S.aud_session == 80)
check("hp_bar_2 xp_session_start does not reset once set",
      S.xp_session_start == session_start_after_first)

hp_bar_2.fn("G[110(0)|220(0)|330(0)|440(0)] L[5|11(50%)] E[None|]",
  "110", "0", "220", "0", "330", "0", "440", "0", "5", "11", "50", "None", "", nil)
check("hp_bar_2 zero-gain round does not accumulate", S.vis_session == 20
      and S.kap_session == 40 and S.soe_session == 60 and S.aud_session == 80)
check("hp_bar_2 combat false when enemy is None", S.combat == false)
check("hp_bar_2 rndz nil defaults to 0", S.rndz == 0)

-- ---- hp_bar_2_cont (LEGACY 669) ---------------------------------------------
-- XML: ^(\d+)\]\s*$
local hp_bar_2_cont = trigger_handlers[4]
hp_bar_2_cont.fn("42]", "42")
check("hp_bar_2_cont", S.rndz == 42)

-- ---- hp_bar_2_vis (LEGACY 679) -----------------------------------------------
-- XML: ^Vis:(\d+)\s+Kap:(\d+)\s+Soe:(\d+)\s+Aud:(\d+)\s+L\[(\d+)\|(\d+)\]\s+E\[([^\]]*)\]?
local hp_bar_2_vis = trigger_handlers[5]
S.vis_gain, S.kap_gain, S.soe_gain, S.aud_gain, S.lrst, S.rndz = 9, 9, 9, 9, 9, 9
hp_bar_2_vis.fn("Vis:12399  Kap:16168  Soe:495  Aud:14507  L[1|4] E[None]",
  "12399", "16168", "495", "14507", "1", "4", "None")
check("hp_bar_2_vis fields", S.vis == 12399 and S.kap == 16168 and S.soe == 495
      and S.aud == 14507 and S.ldng == 1 and S.mldng == 4 and S.en5 == "None")
check("hp_bar_2_vis clears gains/lrst/rndz/ens", S.vis_gain == 0 and S.kap_gain == 0
      and S.soe_gain == 0 and S.aud_gain == 0 and S.lrst == 0 and S.rndz == 0 and S.ens == "")
check("hp_bar_2_vis combat false when no enemy", S.combat == false)

hp_bar_2_vis.fn("Vis:1  Kap:1  Soe:1  Aud:1  L[1|4] E[bear]",
  "1", "1", "1", "1", "1", "4", "bear")
check("hp_bar_2_vis combat true with enemy", S.combat == true and S.en5 == "bear")

-- ---- hp_bar_3 family (LEGACY 725, 760, 768) ----------------------------------
local hp_bar_3 = trigger_handlers[6]
local hp_bar_3_open = trigger_handlers[7]
local hp_bar_3_cont = trigger_handlers[8]

hp_bar_3.fn("[ein:54 bvorn:91 bles:34]", "ein:54 bvorn:91 bles:34")
check("hp_bar_3 count", #S.stfx == 3)
check("hp_bar_3 entry fields", S.stfx[1].name == "ein" and S.stfx[1].val == "54"
      and S.stfx[1].cat == "Def" and S.stfx[1].cs == "#00CCCC" and S.stfx[1].ci == 0xCCCC00)
check("hp_bar_3 heal category", S.stfx[3].name == "bles" and S.stfx[3].cat == "Heal")

hp_bar_3.fn("[]", "")
check("hp_bar_3 empty clears stfx", #S.stfx == 0)

-- unknown tag falls back to STFX_DEFAULT
hp_bar_3.fn("[zzz:12]", "zzz:12")
check("hp_bar_3 unknown tag uses default meta", S.stfx[1].cat == "DoT" and S.stfx[1].cs == "#FF5555")

-- wrap reassembly: open buffers the fragment, cont stitches and parses
hp_bar_3.fn("[]", "")
hp_bar_3_open.fn("[ein:54 bvorn:91", "ein:54 bvorn:91")
hp_bar_3_cont.fn("bles:34]", "bles:34")
check("hp_bar_3_open/cont reassembles wrapped stfx", #S.stfx == 3 and S.stfx[3].name == "bles")

-- lone "]" with nothing pending (G[]/Vis line wrap tail) is swallowed, not applied
hp_bar_3.fn("[ein:54]", "ein:54")
local before_swallow = #S.stfx
hp_bar_3_cont.fn("]", "")
check("hp_bar_3_cont with no pending open is a no-op", #S.stfx == before_swallow
      and S.stfx[1].name == "ein")

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING COMBAT TESTS PASSED")
