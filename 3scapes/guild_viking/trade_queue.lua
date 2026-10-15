-- A queue refresh is staged privately; only a complete generation replaces public routes.
local S = require("state").S
local M = {}
local pending
local function integer(n) return type(n) == "number" and n >= 0 and n == math.floor(n) end
local function incomplete()
  S.trade_queue = S.trade_queue or {}
  S.trade_queue_complete = false
end

-- Compatibility with Guild.Trade on servers predating the dedicated queue stream.
function M.legacy(parts)
  if type(parts) ~= "table" or type(parts.queue) ~= "table" then return end
  if S.trade_queue_stream then return end -- never mix two transports/generations
  local jobs, rows, grouped = {}, {}, {}
  for _, leg in ipairs(parts.queue_legs or {}) do
    if type(leg) == "table" then
      grouped[leg.job] = grouped[leg.job] or {}
      grouped[leg.job][#grouped[leg.job] + 1] = leg
    end
  end
  for _, job in ipairs(parts.queue) do
    if type(job) == "table" then jobs[#jobs + 1] = job end
  end
  local previous_count = S.trade_queue_count
  S.trade_queue_count = #jobs
  if parts.queue_legs == nil and #jobs > 0 then
    if previous_count ~= #jobs or not S.trade_queue_complete then incomplete() end
    return -- missing details cannot erase the last complete display
  end
  for _, job in ipairs(jobs) do
    local source = grouped[job.job] or {}
    table.sort(source, function(a, b) return (a.seq or 0) < (b.seq or 0) end)
    local legs = {}
    for _, leg in ipairs(source) do
      legs[#legs + 1] = { mode = tostring(leg.mode or ""), good = tostring(leg.good or ""),
        amount = tonumber(leg.amount) or 0, village = tostring(leg.village or ""),
        value = tonumber(leg.value) or 0 }
    end
    if #legs == 0 then incomplete(); return end
    rows[#rows + 1] = { mode = legs[1].mode, good = legs[1].good,
      amount = legs[1].amount, village = legs[1].village,
      escort = tonumber(job.escort) or 0, legs = legs }
  end
  S.trade_queue, S.trade_queue_complete = rows, true
end

local function validate(parts)
  if type(parts) ~= "table" or type(parts.meta) ~= "table" then
    error("trade queue: missing chunk metadata")
  end
  local m = parts.meta
  if type(m.revision) ~= "string" or #m.revision == 0 or #m.revision > 128
      or not integer(m.total) or not integer(m.job) or not integer(m.leg_from)
      or not integer(m.leg_total) or not integer(m.count) or m.count > 2
      or m.leg_from + m.count > m.leg_total
      or (m.leg_total > 0 and m.count == 0)
      or (m.total == 0 and (m.job ~= 0 or m.count ~= 0 or m.leg_total ~= 0))
      or (m.total > 0 and m.job >= m.total) then
    error("trade queue: invalid chunk metadata")
  end
  local legs = parts.legs or {}
  if type(legs) ~= "table" or #legs ~= m.count then error("trade queue: missing chunk legs") end
  for i, leg in ipairs(legs) do
    if type(leg) ~= "table" or leg.revision ~= m.revision or leg.job ~= m.job
        or leg.seq ~= m.leg_from + i - 1 or type(leg.mode) ~= "string"
        or type(leg.good) ~= "string" or type(leg.village) ~= "string"
        or not integer(leg.amount) then error("trade queue: invalid chunk leg") end
  end
  return m, legs
end

function M.stream(parts)
  -- A malformed or interrupted update cannot leave automation trusting old rows as current.
  incomplete()
  local m, legs = validate(parts)
  if not S.trade_queue_stream then pending = nil end
  if m.revision ~= S.trade_queue_stream then
    if m.job ~= 0 or m.leg_from ~= 0 then return end
    pending = { revision = m.revision, total = m.total, job = 0, offset = 0,
                rows = {}, legs = {} }
    S.trade_queue_stream = m.revision
  end
  if not pending then
    -- A duplicate final chunk after publication is harmless.
    if S.trade_queue_revision == m.revision then S.trade_queue_complete = true end
    return
  end
  if pending.total ~= m.total then error("trade queue: changed snapshot size") end
  if m.job < pending.job or (m.job == pending.job and m.leg_from < pending.offset) then
    return -- retransmitted chunk; no route or leg is appended twice
  end
  if m.job ~= pending.job or m.leg_from ~= pending.offset then
    pending = nil
    error("trade queue: missing or out-of-order chunk")
  end
  if pending.offset == 0 then
    pending.leg_total, pending.escort, pending.cart = m.leg_total, m.escort, m.cart
  elseif pending.leg_total ~= m.leg_total or pending.escort ~= m.escort
      or pending.cart ~= m.cart then
    pending = nil
    error("trade queue: changed job metadata")
  end
  S.trade_queue_count = m.total -- authoritative headers, not a partial route count
  for _, leg in ipairs(legs) do
    pending.legs[#pending.legs + 1] = { mode = leg.mode, good = leg.good,
      amount = leg.amount, village = leg.village, value = 0 }
  end
  pending.offset = pending.offset + m.count
  if pending.offset < m.leg_total then return end
  if m.total > 0 then
    local first = pending.legs[1] or { mode = "", good = "", amount = 0, village = "" }
    pending.rows[#pending.rows + 1] = { mode = first.mode, good = first.good,
      amount = first.amount, village = first.village, escort = tonumber(m.escort) or 0,
      cart_id = tonumber(m.cart) or 0, legs = pending.legs }
    pending.job, pending.offset, pending.legs = pending.job + 1, 0, {}
  end
  if pending.job == pending.total then
    S.trade_queue = pending.rows
    S.trade_queue_revision = m.revision
    S.trade_queue_complete = true
    pending = nil
  end
end
return M
