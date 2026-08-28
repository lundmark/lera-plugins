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
-- page/pages are stripped as envelope keys but never reassembled across
-- pages -- each page would merge independently and a paged full frame would
-- keep only its last page. Out of reach for this four-scalar payload; not
-- handled deliberately, not by omission.
local ENVELOPE = { full = true, page = true, pages = true }

local state = nil       -- mirror, congruent with the server's delta cache
local synced_at = nil   -- lera.time() seconds when the mirror was last written

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
  local elapsed = lera.time() - (synced_at or lera.time())
  local left = state.reboot_left - elapsed
  if left < 0 then left = 0 end
  return math.floor(left)
end

-- The bar fills with ELAPSED time, left to right, toward the reboot; the
-- parenthesised time is what remains. floor(), so a cell lights only once its
-- tenth is fully spent.
local function bar(left, total)
  if type(total) ~= "number" or total <= 0 then return nil end
  local elapsed = total - left
  local filled = math.floor(elapsed / total * BAR_CELLS)
  if filled < 0 then filled = 0 end
  if filled > BAR_CELLS then filled = BAR_CELLS end
  return "[" .. string.rep("X", filled) .. string.rep(".", BAR_CELLS - filled) .. "]"
end

-- Days appear from 1d up, hours from 1h up, minutes always. Seconds are never
-- shown: the display would change every second while the underlying value is
-- only re-synced every 2 minutes.
local function duration(seconds)
  local d = math.floor(seconds / 86400)
  local h = math.floor((seconds % 86400) / 3600)
  local m = math.floor((seconds % 3600) / 60)
  if d > 0 then return string.format("%dd %dh %dm", d, h, m) end
  if h > 0 then return string.format("%dh %dm", h, m) end
  return string.format("%dm", m)
end

-- The output-pane title's status half, or nil when nothing usable has arrived.
-- nil matters for rollout: against a mud that does not send Mud.Status the
-- profile shows host:port alone rather than a zeroed bar.
function M.title_fragment()
  if not state then return nil end
  local parts = {}

  local left = M.reboot_left()
  if left then
    -- reboot_total never changes during a boot, so the server's delta cache
    -- never resends it once cached. After a plugin reload the mirror starts
    -- empty and refills from whatever frames arrive next, which may carry
    -- reboot_left/uptime/lag but not reboot_total for a long time (or ever,
    -- until the next full frame). state.uptime + state.reboot_left
    -- reconstructs it from that same snapshot: the mudlib builds reboot_total
    -- as up + left in the first place (obj/shut.c), so the identity always
    -- holds. Deliberately state.reboot_left, not the locally ticked `left`
    -- above -- uptime is a snapshot too, and pairing it with a value that
    -- keeps ticking down would make the reconstructed total shrink over time.
    local total = state.reboot_total or
      (state.uptime and (state.uptime + state.reboot_left))
    local drawn = bar(left, total)
    if drawn then
      parts[#parts + 1] = "Reboot " .. drawn .. " (" .. duration(left) .. ")"
    end
  end

  if type(state.lag) == "number" then
    parts[#parts + 1] = string.format("Lag %.2f", state.lag)
  end

  if #parts == 0 then return nil end
  return table.concat(parts, " | ")
end

local handler_id = nil
local timer_id = nil
local last_fragment = nil

-- Repaint only when the rendered string actually changed. The minute text
-- moves once a minute and the bar far less often, so an idle session leaves
-- lera's "a frame costs GPU work only when the cell grid changed" property
-- intact instead of dirtying the screen every second.
local function tick()
  local fragment = M.title_fragment()
  if fragment ~= last_fragment then
    last_fragment = fragment
    ui.dirty()
  end
end

function M.on_load()
  -- One registration covers the namespace: the mudlib resolves "Mud 1" to
  -- every Mud.* sub-package through its root fallback, so a sub-package added
  -- server-side later arrives with no client change.
  handler_id = gmcp.on("Mud", function(pkg, data)
    M.apply(pkg, data)
    tick()
  end)
  timer_id = timer.every(1000, tick)
end

function M.on_unload()
  if handler_id then gmcp.remove(handler_id); handler_id = nil end
  if timer_id then timer.cancel(timer_id); timer_id = nil end
  M.reset()
  last_fragment = nil
end

function M.on_disconnect()
  M.reset()
  tick()
end

return M
