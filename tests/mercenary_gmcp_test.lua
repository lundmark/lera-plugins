-- mercenary Merc.* GMCP ingest. Run from the lera-plugins repo root with
-- LERA_ROOT pointing at a built Lera checkout.
package.path = "3scapes/mercenary/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- ---- stubs ----------------------------------------------------------------
local clock = 1000
lera = { time = function() return clock end }

local registered = {}
local removed = {}
gmcp = {
  on = function(pkg, fn) registered[pkg] = fn; return pkg end,
  remove = function(id) removed[id] = true; return true end,
  enabled = function() return true end,
}

local protocol = require("protocol")

local applied = {}
protocol.on_apply(function(sub, mirror, merc, switched)
  applied[#applied + 1] = { sub = sub, mirror = mirror, merc = merc, switched = switched }
end)

local function reset()
  applied = {}
  protocol.reset_connection()
end

-- ---- subscription ---------------------------------------------------------
-- Kills: subscribing to each sub-package by name. The codec resolves `Merc 1`
-- to every sub-package through its root fallback (gmcp_codec.c:402-405), so a
-- single root registration is both sufficient and required -- five separate
-- registrations would advertise five entries in Core.Supports.Set.
reset()
protocol.subscribe()
check("subscribes at the root only",
  registered["Merc"] ~= nil and registered["Merc.Vitals"] == nil,
  "registered: " .. tostring(next(registered)))

-- ---- envelope stripping ---------------------------------------------------
-- Kills: an implementation that merges the raw payload into the mirror. The
-- attribution and control members are protocol scaffolding; leaking `merc`
-- into the mirror would make it indistinguishable from a payload field and
-- would resurface as a bogus stat.
reset()
protocol.on_gmcp("Merc.Vitals", { merc = "kaziar", full = 1, hp = 412, hp_max = 500 })
local m = protocol.mirror("Vitals")
check("envelope members never reach the mirror",
  m.hp == 412 and m.merc == nil and m.full == nil,
  "mirror merc=" .. tostring(m.merc) .. " full=" .. tostring(m.full))

-- Kills: stripping only `merc`. The reserved set is one union shared across
-- every namespace (gmcp_ns_key_reserved), so `guild` is reserved for Merc.*
-- frames too even though Merc never stamps it.
reset()
protocol.on_gmcp("Merc.Info", { merc = "kaziar", guild = "viking", cost = 12 })
check("guild is stripped from a Merc frame",
  protocol.mirror("Info").guild == nil)

-- ---- attribution ----------------------------------------------------------
-- Kills: trusting the frame without checking `merc`. The protocol layer always
-- stamps it, so a missing or non-string attribution means a malformed frame
-- and must not be applied under a nil identity.
reset()
local ok1 = protocol.on_gmcp("Merc.Vitals", { hp = 1 })
local ok2 = protocol.on_gmcp("Merc.Vitals", { merc = 7, hp = 1 })
check("a frame without a string attribution is dropped",
  ok1 == false and ok2 == false and protocol.mirror("Vitals") == nil
    and protocol.counters().bad_attribution == 2,
  "bad_attribution=" .. protocol.counters().bad_attribution)

-- ---- package routing ------------------------------------------------------
-- Kills: routing on a prefix match, which would file Merc.Nonsense under some
-- real package. An unknown sub-package is counted and dropped.
reset()
local ok3 = protocol.on_gmcp("Merc.Nonsense", { merc = "kaziar", x = 1 })
check("an unknown sub-package is dropped and counted",
  ok3 == false and protocol.counters().bad_package == 1)

-- Kills: a case-sensitive comparison against the capitalized name only.
reset()
protocol.on_gmcp("merc.vitals", { merc = "kaziar", hp = 5 })
check("sub-package matching is case-insensitive",
  protocol.mirror("Vitals") ~= nil and protocol.mirror("Vitals").hp == 5)

-- ---- delta merge ----------------------------------------------------------
-- Kills: replacing the mirror on every frame. Frames are deltas: a key absent
-- from a delta means unchanged, and replacing would zero every field the tick
-- did not move.
reset()
protocol.on_gmcp("Merc.Vitals", { merc = "kaziar", hp = 412, hp_max = 500, ap = 40 })
protocol.on_gmcp("Merc.Vitals", { merc = "kaziar", hp = 380 })
m = protocol.mirror("Vitals")
check("a delta frame merges and leaves absent keys alone",
  m.hp == 380 and m.hp_max == 500 and m.ap == 40,
  "hp_max=" .. tostring(m.hp_max) .. " ap=" .. tostring(m.ap))

-- ---- full replacement -----------------------------------------------------
-- Kills: treating `full` as an inert envelope member (which is what
-- guild_viking does, and why it carries a documented stale-pane gap). The
-- mudlib forces full=1 on any frame where a previously cached key vanished
-- (namespace_info_impl.h:379-390), so a full frame is the ONLY signal that a
-- key is gone, and merging it would freeze the vanished key forever.
reset()
protocol.on_gmcp("Merc.Info", { merc = "kaziar", full = 1, status = 1, cost = 12, theme = "wolf" })
protocol.on_gmcp("Merc.Info", { merc = "kaziar", full = 1, status = 5 })
m = protocol.mirror("Info")
check("a full frame replaces the mirror, clearing omitted keys",
  m.status == 5 and m.cost == nil and m.theme == nil,
  "cost=" .. tostring(m.cost) .. " theme=" .. tostring(m.theme))

-- ---- mercenary switch -----------------------------------------------------
-- Kills: clearing state when the attribution changes. THE load-bearing case.
-- The delta cache is keyed by (namespace, sub-package) and knows nothing about
-- which mercenary pushed (secure/pinc/gmcp.h:715-718), so on a switch every
-- field the two mercenaries share is suppressed as unchanged and is never
-- resent. Clearing would zero those fields permanently.
reset()
protocol.on_gmcp("Merc.Vitals", { merc = "kaziar", full = 1, hp = 412, hp_max = 500, ap = 40 })
protocol.on_gmcp("Merc.Vitals", { merc = "brenna", hp = 300 })
m = protocol.mirror("Vitals")
check("a switch preserves fields the two mercenaries share",
  m.hp == 300 and m.hp_max == 500 and m.ap == 40,
  "hp_max=" .. tostring(m.hp_max) .. " ap=" .. tostring(m.ap))

-- Kills: not reporting the switch. state.lua must reset derived tracking
-- (deltas, xp baselines) even though the field values are kept.
check("the switch is reported to the apply callback",
  applied[1].switched == false and applied[2].switched == true
    and applied[2].merc == "brenna")

-- Kills: reporting a switch on the first frame of a connection, where there is
-- no previous mercenary to have switched away from.
check("the first frame is not a switch", applied[1].switched == false)

-- ---- paging ---------------------------------------------------------------
-- Kills: applying each page independently. An oversized key is sliced across
-- pages with the key repeated, so a client that applies pages independently
-- silently truncates a long list to its final slice.
reset()
protocol.on_gmcp("Merc.Skills", { merc = "kaziar", page = 1, pages = 2, bury = { 1, 2 } })
check("an incomplete run does not apply", protocol.mirror("Skills") == nil)
protocol.on_gmcp("Merc.Skills", { merc = "kaziar", page = 2, pages = 2, bury = { 3 }, points = 4 })
m = protocol.mirror("Skills")
check("pages accumulate and slices concatenate in page order",
  m ~= nil and #m.bury == 3 and m.bury[3] == 3 and m.points == 4,
  m and ("#bury=" .. tostring(#m.bury)) or "no mirror")

-- Kills: gating the slice concatenation on the LATER page being non-empty as
-- well. The server slices by byte budget, not by element count, so a later page
-- can legitimately carry an empty slice of a key alongside other keys -- and a
-- `#v > 0` guard sends that down the overwrite branch and discards the two
-- entries page 1 accumulated. The fixture's page 2 carries exactly that: an
-- empty `bury` slice plus a scalar, so the run still has a reason to exist.
reset()
protocol.on_gmcp("Merc.Skills", { merc = "kaziar", page = 1, pages = 2, bury = { 1, 2 } })
protocol.on_gmcp("Merc.Skills", { merc = "kaziar", page = 2, pages = 2, bury = {}, points = 4 })
m = protocol.mirror("Skills")
check("an empty later slice leaves the accumulated array intact",
  m ~= nil and #m.bury == 2 and m.bury[1] == 1 and m.bury[2] == 2 and m.points == 4,
  m and ("#bury=" .. tostring(#m.bury)) or "no mirror")

-- Kills: counting an undecodable payload as a bad attribution. The C layer
-- delivers absent or undecodable JSON as nil; that is a decode failure, not a
-- frame that failed to name its mercenary, and /merc status reports the two
-- apart. A fold shows up as 1 here and 0 in the column asserted zero.
reset()
local ok_nil = protocol.on_gmcp("Merc.Vitals", nil)
local ok_str = protocol.on_gmcp("Merc.Vitals", "not a table")
check("a non-table payload is counted apart from a bad attribution",
  ok_nil == false and ok_str == false
    and protocol.counters().bad_payload == 2
    and protocol.counters().bad_attribution == 0,
  "payload=" .. protocol.counters().bad_payload
    .. " attribution=" .. protocol.counters().bad_attribution)

-- Kills: continuing a run across an out-of-order page. The run cannot be
-- trusted once a page is missing, and applying it would present a partial
-- snapshot as a complete one.
reset()
protocol.on_gmcp("Merc.Talents", { merc = "kaziar", page = 1, pages = 3, a = 1 })
local ok4 = protocol.on_gmcp("Merc.Talents", { merc = "kaziar", page = 3, pages = 3, c = 3 })
check("an out-of-order page aborts the run",
  ok4 == false and protocol.mirror("Talents") == nil
    and protocol.counters().bad_page == 1)

-- Kills: keeping a stale partial run when a new snapshot starts. A fresh
-- page 1 is a new snapshot and must abandon whatever was accumulating.
reset()
protocol.on_gmcp("Merc.Skills", { merc = "kaziar", page = 1, pages = 2, bury = { 1 } })
protocol.on_gmcp("Merc.Skills", { merc = "kaziar", page = 1, pages = 2, bury = { 9 } })
protocol.on_gmcp("Merc.Skills", { merc = "kaziar", page = 2, pages = 2 })
check("a fresh page 1 abandons a partial run",
  #protocol.mirror("Skills").bury == 1 and protocol.mirror("Skills").bury[1] == 9)

-- Boundary characterization, NOT a mutant kill for the `pages <= 1` comparator
-- itself: page/pages appear only when a frame is actually split, so pages==1
-- must take the unpaged path -- but weakening that comparator so pages==1 falls
-- into the paged branch creates a one-page run that passes the ordering check
-- and applies an identical mirror, so those two branches converge by
-- construction and no mutation of THAT comparator can fail this case. Other
-- mutations elsewhere in the paged branch do fail it (page == pages + 1, say),
-- which is why it is kept: it pins the boundary against a future refactor that
-- makes the branches diverge.
reset()
protocol.on_gmcp("Merc.Vitals", { merc = "kaziar", page = 1, pages = 1, hp = 7 })
check("pages<=1 applies immediately", protocol.mirror("Vitals").hp == 7)

-- ---- connection reset -----------------------------------------------------
-- Kills: keeping mirrors across a disconnect. The server clears its whole
-- namespace cache on disconnect (gmcp_clear_core_state), so retained mirrors
-- would no longer be congruent with it, and a stale merc would render against
-- a session that has none.
reset()
protocol.on_gmcp("Merc.Vitals", { merc = "kaziar", hp = 412 })
protocol.on_gmcp("Merc.Info", { merc = "kaziar", cost = 12 })
protocol.reset_connection()
check("disconnect clears every mirror",
  protocol.mirror("Vitals") == nil and protocol.mirror("Info") == nil
    and protocol.merc_name() == nil and protocol.counters().applied == 0)

-- Kills: not recording arrival, which /merc status reports. Skills and Talents
-- push only on registration, allocation and level-up, so "has this connection
-- seen them at all" is the difference between real zeroes and no data.
reset()
clock = 4242
protocol.on_gmcp("Merc.Vitals", { merc = "kaziar", hp = 1 })
check("arrival time is recorded per sub-package",
  protocol.seen("Vitals") == 4242 and protocol.seen("Skills") == nil)
clock = 1000

-- ---- a failed subscription ------------------------------------------------
-- Kills: ignoring a nil return from gmcp.on. A failed registration leaves the
-- plugin deaf for the whole session, and every symptom of that is also a
-- symptom of a server that simply never pushes: /merc status reports `frames 0`
-- either way. The diagnostic is the only thing that separates them.
reset()
protocol.unsubscribe()
local diagnostics = {}
local real_print, real_on = print, gmcp.on
gmcp.on = function() return nil end
print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  diagnostics[#diagnostics + 1] = table.concat(parts, " ")
end
local sub_id = protocol.subscribe()
print, gmcp.on = real_print, real_on
local diag = table.concat(diagnostics, "\n")
check("a failed subscription is diagnosed rather than silent",
  sub_id == nil and diag:find("mercenary", 1, true) ~= nil
    and diag:find("Merc", 1, true) ~= nil,
  "id=" .. tostring(sub_id) .. " diag=" .. diag)
protocol.subscribe()

-- ---- summary --------------------------------------------------------------
if failures > 0 then
  print("FAILURES: " .. failures)
  os.exit(1)
end
print("mercenary_gmcp_test: all cases passed")
