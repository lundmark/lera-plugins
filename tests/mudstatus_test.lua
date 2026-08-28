-- mudstatus unit tests. Run from the lera-plugins repo root with LERA_ROOT
-- pointing at a built Lera checkout.
--
-- mudstatus is the sole subscriber to the GMCP Mud.* namespace. The server
-- delta-caches the payload, so a frame carries only what changed and the
-- client MUST merge rather than replace. The countdown is ticked locally
-- between the server's 2-minute pushes.
package.path = "3scapes/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- ---- stubs ------------------------------------------------------------------
local now_s = 1000
lera = { time = function() return now_s end }

local handlers = {}
local removed_handlers = {}
gmcp = {
  on = function(pkg, fn) handlers[pkg] = fn; return pkg end,
  remove = function(id) removed_handlers[#removed_handlers + 1] = id; return true end,
}

local dirty_count = 0
ui = { dirty = function() dirty_count = dirty_count + 1 end }

local timers = {}
local cancelled_timers = {}
timer = {
  every = function(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn }; return #timers end,
  cancel = function(id) cancelled_timers[#cancelled_timers + 1] = id; return true end,
}

local M = require("mudstatus")

local function full_frame()
  return { reboot_left = 352740, reboot_total = 432000, uptime = 79260, lag = 0.02 }
end

-- ---- merge ------------------------------------------------------------------
M.reset()
M.apply("Mud.Status", full_frame())
local snap = M.snapshot()
check("a first frame populates the mirror",
      snap and snap.reboot_left == 352740 and snap.lag == 0.02, snap and snap.lag)

M.apply("Mud.Status", { lag = 0.41 })
snap = M.snapshot()
check("a delta frame merges and leaves absent keys intact",
      snap.lag == 0.41 and snap.reboot_left == 352740, snap.reboot_left)

M.apply("Mud.Status", { full = 1, reboot_left = 100, reboot_total = 200, uptime = 100 })
snap = M.snapshot()
check("a full frame replaces the mirror outright", snap.lag == nil, snap.lag)

M.reset()
M.apply("Mud.Status", { reboot_left = 10, full = 1, page = 1, pages = 1 })
snap = M.snapshot()
check("envelope keys never reach the mirror",
      snap.full == nil and snap.page == nil and snap.pages == nil)

M.reset()
M.apply("Mud.Other", { reboot_left = 5 })
check("a foreign Mud sub-package is ignored", M.snapshot() == nil)

M.reset()
M.apply("Mud.Status", "not a table")
check("a non-table payload is ignored", M.snapshot() == nil)

-- ---- derived countdown ------------------------------------------------------
M.reset()
now_s = 1000
M.apply("Mud.Status", full_frame())
check("the countdown starts at the frame's value", M.reboot_left() == 352740)

now_s = 1000 + 60
check("the countdown ticks down locally between frames",
      M.reboot_left() == 352680, M.reboot_left())

now_s = 1000 + 60 + 120
M.apply("Mud.Status", { reboot_left = 352500 })
check("an arriving frame re-syncs the countdown", M.reboot_left() == 352500)

-- Regression demonstration for the lera.time() units bug: lera.time() returns
-- whole seconds (src/lua/api_lera.c), not milliseconds, so `elapsed` must NOT
-- be divided by 1000. A full 2-minute inter-frame gap with no frame delivered
-- must move the countdown down by exactly 120, not by ~0 (the /1000 bug) or 1.
M.reset()
now_s = 1000
M.apply("Mud.Status", full_frame())
local before = M.reboot_left()
now_s = 1000 + 120
local after = M.reboot_left()
check("a 120-second advance with no new frame drops the countdown by 120",
      before - after == 120, "before=" .. tostring(before) .. " after=" .. tostring(after))

M.reset()
now_s = 1000
M.apply("Mud.Status", { reboot_left = 30, reboot_total = 100, uptime = 70, lag = 0.0 })
now_s = 1000 + 90
check("the countdown clamps at zero rather than going negative",
      M.reboot_left() == 0, M.reboot_left())

M.reset()
check("no frame yet means no countdown", M.reboot_left() == nil)

-- ---- rendering --------------------------------------------------------------
M.reset()
check("no frame yet means no fragment", M.title_fragment() == nil)

M.reset()
now_s = 1000
-- Just booted: nothing elapsed, so the bar is empty.
M.apply("Mud.Status", { reboot_left = 432000, reboot_total = 432000, uptime = 0, lag = 0.02 })
check("a fresh boot draws an empty bar",
      M.title_fragment() == "Reboot [..........] (5d 0h 0m) | Lag 0.02",
      M.title_fragment())

M.reset()
-- Half elapsed.
M.apply("Mud.Status", { reboot_left = 216000, reboot_total = 432000, uptime = 216000, lag = 0.0 })
check("a half-elapsed cycle fills half the bar",
      M.title_fragment() == "Reboot [XXXXX.....] (2d 12h 0m) | Lag 0.00",
      M.title_fragment())

M.reset()
-- Due imminently: days and hours drop out of the text. The bar is NOT full --
-- 720s of a 432000s cycle is 99.83% elapsed, which floors to 9 cells. A tenth
-- cell means the tenth tenth is fully spent, and it is not.
M.apply("Mud.Status", { reboot_left = 720, reboot_total = 432000, uptime = 431280, lag = 0.31 })
check("an imminent reboot shows minutes only and stops one cell short",
      M.title_fragment() == "Reboot [XXXXXXXXX.] (12m) | Lag 0.31",
      M.title_fragment())

M.reset()
-- Only a fully spent cycle fills every cell.
M.apply("Mud.Status", { reboot_left = 0, reboot_total = 432000, uptime = 432000, lag = 0.0 })
check("a spent cycle fills the bar completely",
      M.title_fragment() == "Reboot [XXXXXXXXXX] (0m) | Lag 0.00",
      M.title_fragment())

M.reset()
M.apply("Mud.Status", { reboot_left = 7140, reboot_total = 432000, uptime = 424860, lag = 0.0 })
check("under a day shows hours and minutes without a day field",
      M.title_fragment():find("(1h 59m)", 1, true) ~= nil, M.title_fragment())

-- duration() boundary: exactly 86400s is 1 whole day with nothing left over.
-- By hand: d = floor(86400/86400) = 1, h = floor((86400%86400)/3600) = 0,
-- m = floor((86400%3600)/60) = 0 -> "1d 0h 0m".
-- total = 172800, left = 86400 -> elapsed = 86400 -> filled = floor(86400/172800*10) = 5.
M.reset()
M.apply("Mud.Status", { reboot_left = 86400, reboot_total = 172800, uptime = 86400 })
check("duration renders exactly one day with no leftover hours or minutes",
      M.title_fragment() == "Reboot [XXXXX.....] (1d 0h 0m)", M.title_fragment())

-- duration() boundary: a value in [3540, 3599] is under one hour, so it must
-- render as a bare "59m" with no hours field at all.
-- By hand (left = 3540): d = 0, h = floor(3540/3600) = 0, m = floor(3540/60) = 59
-- -> "59m" (the h > 0 branch never triggers).
-- total = 7080, left = 3540 -> elapsed = 3540 -> filled = floor(3540/7080*10) = 5.
M.reset()
M.apply("Mud.Status", { reboot_left = 3540, reboot_total = 7080, uptime = 3540 })
check("duration renders a bare minutes field just under one hour",
      M.title_fragment() == "Reboot [XXXXX.....] (59m)", M.title_fragment())

M.reset()
-- A denominator of zero cannot produce a fraction; the bar is omitted rather
-- than dividing by zero or drawing a meaningless full bar.
M.apply("Mud.Status", { reboot_left = 60, reboot_total = 0, uptime = 0, lag = 0.05 })
check("a zero denominator omits the bar but keeps lag",
      M.title_fragment() == "Lag 0.05", M.title_fragment())

M.reset()
M.apply("Mud.Status", { lag = 1.5 })
check("lag alone renders without a reboot group",
      M.title_fragment() == "Lag 1.50", M.title_fragment())

M.reset()
M.apply("Mud.Status", { reboot_left = 3600, reboot_total = 7200, uptime = 3600 })
check("a reboot group renders without lag",
      M.title_fragment() == "Reboot [XXXXX.....] (1h 0m)", M.title_fragment())

-- reboot_total never changes during a boot, so the server's delta cache never
-- resends it once cached: a plugin reload starts with an empty mirror and may
-- go on refilling from reboot_left/uptime/lag frames alone, with reboot_total
-- absent for a long time (or until the next full frame). uptime + reboot_left
-- must reconstruct the denominator so the bar still renders.
-- By hand: total = uptime(324000) + reboot_left(108000) = 432000.
-- elapsed = 432000 - 108000 = 324000; filled = floor(324000/432000*10) = 7.
-- duration(108000): 108000/86400 = 1d, remainder 21600 = 6h, remainder 0 = 0m.
M.reset()
M.apply("Mud.Status", { reboot_left = 108000, uptime = 324000, lag = 0.10 })
check("reboot_total absent (post-reload) still derives the bar from uptime",
      M.title_fragment() == "Reboot [XXXXXXX...] (1d 6h 0m) | Lag 0.10",
      M.title_fragment())

-- ---- lifecycle --------------------------------------------------------------
M.reset()
handlers = {}
timers = {}
dirty_count = 0
M.on_load()
check("on_load subscribes to the Mud namespace once, not per sub-package",
      handlers["Mud"] ~= nil and handlers["Mud.Status"] == nil)
check("on_load installs a one-second tick",
      #timers == 1 and timers[1].ms == 1000, #timers)

-- The plugin must repaint when the rendered string changes...
now_s = 2000
dirty_count = 0
handlers["Mud"]("Mud.Status", { reboot_left = 7200, reboot_total = 7200, uptime = 0, lag = 0.02 })
check("an arriving frame marks the ui dirty", dirty_count > 0, dirty_count)

-- ...and must NOT repaint on a tick that changes nothing, or an idle session
-- would rebuild the screen every second for no reason.
dirty_count = 0
timers[1].fn()
check("an unchanged tick does not mark the ui dirty", dirty_count == 0, dirty_count)

-- A minute later the rendered minutes have changed, so a repaint is due.
now_s = 2000 + 60
dirty_count = 0
timers[1].fn()
check("a tick that changes the rendered text marks the ui dirty",
      dirty_count == 1, dirty_count)

-- The server drops its whole namespace cache on disconnect, so a retained
-- mirror would stop being congruent with it.
dirty_count = 0
M.on_disconnect()
check("disconnect clears the mirror", M.title_fragment() == nil)
check("disconnect repaints the now-empty title", dirty_count == 1, dirty_count)

removed_handlers = {}
cancelled_timers = {}
M.on_unload()
check("unload leaves no state behind", M.snapshot() == nil)
check("unload removes exactly the handler on_load installed",
      #removed_handlers == 1 and removed_handlers[1] == "Mud", removed_handlers[1])
check("unload cancels exactly the timer on_load installed",
      #cancelled_timers == 1 and cancelled_timers[1] == 1, cancelled_timers[1])

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
