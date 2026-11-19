# Viking queue snapshots

Long trade queues use `Guild.TradeQueue`, independently of the other Trade
panels. A push carries `meta` and up to two `legs` records. A push may itself
be paged by the GMCP protocol; the existing protocol decoder rejoins those
pages before the queue writer sees it.

`meta` contains `revision` (snapshot ID), `total` (jobs), `job` (zero-based job
index), `leg_from`, `leg_total`, `count` (0–2), `escort`, and `cart`. Every leg
contains `revision`, `job`, `seq`, `mode`, `good`, `amount`, and `village`.
Repeating identity in the legs prevents unchanged-content delta suppression
from making a new chunk incomplete. Metadata changes on every chunk. An
explicit empty snapshot has total/job/leg_from/leg_total/count all zero.

The guild freezes one complete queue and restarts the revision if it changes
during transfer. The client stages records privately and replaces
`state.S.trade_queue` only when all jobs and legs are present. Missing,
malformed, or out-of-order chunks preserve the previous complete display and
mark `trade_queue_complete = false`. A new revision starts recovery.
`trade_queue_count` is the snapshot's job count, independent of how many route
details have arrived. Consumers must wait while `trade_queue_complete` is
false. The Trade page labels the previous snapshot during refresh.

The legacy `Guild.Trade` queue/queue_legs form remains supported by the decoder
for older servers. Missing details do not erase the prior display. Once the
new stream is seen, legacy deltas cannot overwrite it. Connection resets clear
its freshness evidence. Counts and stream state are not persisted as server
truth across connections.

This decoder changes no saved game jobs and sends no trade commands. Update
the client before activating the guild's new transport, since old clients do
not understand the separate package. Verify a complete Trade-page queue before
resuming automation. No queue clear or save-file edit is needed.

Tests: `luajit tests/guild_viking_queue_count_test.lua` and
`luajit tests/guild_viking_queue_stream_test.lua`, plus the existing GMCP Trade,
page and census suites.
