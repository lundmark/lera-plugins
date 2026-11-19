-- GMCP queue headers remain authoritative when oversized route details are omitted.
package.path = "3scapes/guild_viking/?.lua;" .. package.path
ui = { dirty = function() end }
local state = require("state")
local S = state.S
local protocol = require("protocol")
local trade = require("handlers.trade")
for key, fn in pairs(trade._gmcp) do protocol.gmcp_handler(key, fn) end
local function frame(parts)
  parts.guild = "viking"
  protocol.on_gmcp("Guild.Trade", parts)
end
local headers = {}
for i = 0, 24 do headers[#headers + 1] = { job = i, escort = 0 } end
frame({ full = 1, queue = headers })
assert(S.trade_queue_count == 25, "missing legs must not erase the received job count")
assert(#S.trade_queue == 0, "missing details must not invent display routes")
frame({ carts = {} })
assert(S.trade_queue_count == 25, "unrelated deltas preserve the job count")
headers[#headers + 1] = { job = 25, escort = 0 }
frame({ queue = headers })
assert(S.trade_queue_count == 26, "an accepted job changes the count without route details")
frame({ queue = { { job = 0, escort = 2 } },
        queue_legs = { { job = 0, seq = 0, mode = "sell", good = "ore",
                         amount = 10, village = "eiriksson" } } })
assert(S.trade_queue_count == 1 and #S.trade_queue == 1,
       "complete frames count and render the same jobs")
frame({ queue = {} })
assert(S.trade_queue_count == 0 and #S.trade_queue == 0, "an empty queue clears both views")
state.reset_connection()
assert(S.trade_queue_count == nil, "reconnect must discard old count evidence")
print("PASS: queue headers count independently of omitted route details")
