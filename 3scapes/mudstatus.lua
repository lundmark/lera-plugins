-- Mud Status Plugin for Lera
-- Sole subscriber to the GMCP Mud.* namespace, which on 3scapes carries one
-- sub-package: Mud.Status, pushed by /obj/shut every 2 minutes with the reboot
-- countdown and the driver's heartbeat lag.
--
-- The server delta-caches the payload, so a frame carries only what changed:
-- absence of a key means "unchanged", never "zero". Merge, never replace --
-- except for a frame carrying `full`, which the mudlib sends precisely when a
-- previously cached key has vanished.
--
-- Between pushes the countdown is derived from the arrival stamp, so the title
-- reads truthfully in the 2 minutes between frames instead of freezing.

local M = {}
M.name = "mudstatus"
M.version = "1.0"

local BAR_CELLS = 10
local ENVELOPE = { full = true, page = true, pages = true }

local state = nil       -- mirror, congruent with the server's delta cache
local synced_at = nil   -- lera.time() ms when the mirror was last written

local function is_status(pkg)
  return type(pkg) == "string" and pkg:lower() == "mud.status"
end

function M.apply(pkg, data)
  if not is_status(pkg) or type(data) ~= "table" then return end
  if data.full or state == nil then state = {} end
  for k, v in pairs(data) do
    if not ENVELOPE[k] then state[k] = v end
  end
  synced_at = lera.time()
end

function M.reset()
  state = nil
  synced_at = nil
end

function M.snapshot()
  if not state then return nil end
  local copy = {}
  for k, v in pairs(state) do copy[k] = v end
  return copy
end

-- Seconds until reboot, ticked down from the arrival stamp. nil when no frame
-- has carried reboot_left yet.
function M.reboot_left()
  if not state or type(state.reboot_left) ~= "number" then return nil end
  local elapsed = (lera.time() - (synced_at or lera.time())) / 1000
  local left = state.reboot_left - elapsed
  if left < 0 then left = 0 end
  return math.floor(left)
end

return M
