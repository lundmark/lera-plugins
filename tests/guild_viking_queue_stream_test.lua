-- Full snapshot publication, interrupted transfers, generations, and oversized legacy queues.
package.path = "3scapes/guild_viking/?.lua;" .. package.path
ui = { dirty = function() end }
local state = require("state")
local S = state.S
local protocol = require("protocol")
local trade = require("handlers.trade")
for key, fn in pairs(trade._gmcp) do protocol.gmcp_handler(key, fn) end
local queue = require("trade_queue")
local checks = 0
local function check(ok, why) assert(ok, why); checks = checks + 1 end
local function packet(revision, total, job, offset, leg_total)
  local legs = {}
  local count = math.min(2, leg_total - offset)
  for i = offset, offset + count - 1 do
    legs[#legs + 1] = { revision = revision, job = job, seq = i,
      mode = "sell", good = "ore", amount = 10 + i, village = "eiriksson" }
  end
  return { meta = { revision = revision, total = total, job = job, leg_from = offset,
    leg_total = leg_total, count = count, escort = job, cart = 4 }, legs = legs }
end
local function send(p)
  p.guild = "viking"
  protocol.on_gmcp("Guild.TradeQueue", p)
end
local old = { { good = "timber", legs = { { amount = 99 } } } }
S.trade_queue = old
send(packet("snapshot-a", 25, 0, 0, 6))
check(S.trade_queue == old and not S.trade_queue_complete, "partial snapshot preserves old routes")
check(S.trade_queue_count == 25, "complete header total is known before route publication")
-- Complete a 25-job, six-stop queue: 150 legs, exceeding the old 128-record list cap.
for job = 0, 24 do
  for offset = 0, 4, 2 do
    if job ~= 0 or offset ~= 0 then send(packet("snapshot-a", 25, job, offset, 6)) end
    if job < 24 or offset < 4 then
      check(S.trade_queue == old, "no partial generation is published")
    end
  end
end
check(S.trade_queue_complete and #S.trade_queue == 25, "all 25 routes publish atomically")
for i, route in ipairs(S.trade_queue) do
  check(#route.legs == 6 and route.escort == i - 1 and route.cart_id == 4,
        "all route fields and legs survive the split")
end
local complete = S.trade_queue
send(packet("snapshot-a", 25, 24, 4, 6))
check(S.trade_queue == complete and S.trade_queue_complete, "duplicate final chunk is harmless")
send(packet("snapshot-b", 3, 0, 0, 6))
send(packet("snapshot-b", 3, 0, 0, 6))
check(S.trade_queue == complete and not S.trade_queue_complete, "duplicate chunks do not publish early")
-- A changed server queue starts a new generation, replacing the incomplete staging area only.
send(packet("snapshot-c", 1, 0, 0, 4))
check(S.trade_queue == complete, "restarting a generation preserves last complete routes")
send(packet("snapshot-c", 1, 0, 2, 4))
check(S.trade_queue_complete and #S.trade_queue == 1 and #S.trade_queue[1].legs == 4,
      "new generation completes without mixing old legs")
complete = S.trade_queue
local gap = packet("snapshot-gap", 1, 0, 0, 6)
queue.stream(gap)
local ok = pcall(queue.stream, packet("snapshot-gap", 1, 0, 4, 6))
check(not ok and S.trade_queue == complete and not S.trade_queue_complete,
      "missing chunks retain prior routes and disable planning")
local bad = packet("snapshot-invalid", 1, 0, 0, 2)
bad.legs = nil
ok = pcall(queue.stream, bad)
check(not ok and S.trade_queue == complete and not S.trade_queue_complete,
      "metadata without required legs is not a completed refresh")
send(packet("snapshot-empty", 0, 0, 0, 0))
check(S.trade_queue_complete and #S.trade_queue == 0 and S.trade_queue_count == 0,
      "only an explicitly complete empty snapshot clears the display")
-- Legacy headers arriving after the stream must not overwrite the newer snapshot.
protocol.on_gmcp("Guild.Trade", { guild = "viking", queue = { { job = 0 } } })
check(S.trade_queue_count == 0 and #S.trade_queue == 0, "legacy delta cannot mix generations")
state.reset_connection()
check(S.trade_queue_stream == nil and not S.trade_queue_complete, "reconnect invalidates proof of freshness")
send(packet("after-reconnect", 1, 0, 2, 4))
check(not S.trade_queue_complete, "midstream reconnect cannot publish a tail as a full queue")
send(packet("fresh-after-reconnect", 1, 0, 0, 2))
check(S.trade_queue_complete and #S.trade_queue == 1, "fresh generation recovers after reconnect")
-- The new stream also carries jobs beyond the old 100-job display cap.
for job = 0, 124 do
  for offset = 0, 4, 2 do send(packet("large-snapshot", 125, job, offset, 6)) end
end
check(S.trade_queue_complete and #S.trade_queue == 125 and S.trade_queue_count == 125,
      "queue snapshots do not truncate at 100 jobs")
local all_legs = 0
for _, route in ipairs(S.trade_queue) do all_legs = all_legs + #route.legs end
check(all_legs == 750, "all 750 route legs survive a large snapshot")
print("PASS: " .. checks .. " queue stream checks")
