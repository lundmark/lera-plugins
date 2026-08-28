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
local now_ms = 1000000
lera = { time = function() return now_ms end }

local handlers = {}
gmcp = {
  on = function(pkg, fn) handlers[pkg] = fn; return pkg end,
  remove = function() return true end,
}

local dirty_count = 0
ui = { dirty = function() dirty_count = dirty_count + 1 end }

local timers = {}
timer = {
  every = function(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn }; return #timers end,
  cancel = function() return true end,
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
now_ms = 1000000
M.apply("Mud.Status", full_frame())
check("the countdown starts at the frame's value", M.reboot_left() == 352740)

now_ms = 1000000 + 60000
check("the countdown ticks down locally between frames",
      M.reboot_left() == 352680, M.reboot_left())

now_ms = 1000000 + 60000 + 120000
M.apply("Mud.Status", { reboot_left = 352500 })
check("an arriving frame re-syncs the countdown", M.reboot_left() == 352500)

M.reset()
now_ms = 1000000
M.apply("Mud.Status", { reboot_left = 30, reboot_total = 100, uptime = 70, lag = 0.0 })
now_ms = 1000000 + 90000
check("the countdown clamps at zero rather than going negative",
      M.reboot_left() == 0, M.reboot_left())

M.reset()
check("no frame yet means no countdown", M.reboot_left() == nil)

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
