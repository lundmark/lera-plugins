-- Info page: realm standing, soul/storage tiers, global bonuses (Craft.Info).
local pagelib = require("pagelib")
local state = require("state")

local C = pagelib.C
local M = {}

local REALMS = { "Chaos", "Fantasy", "Science" }

function M.lines(width)
  width = width or 80
  local s = state.get()
  local lines, actions = {}, {}
  local function add(text) lines[#lines + 1] = text end

  local ready, stalled = 0, 0
  for _, skill in pairs(s.skills) do
    if skill.unlocked == 1 and skill.can_train == 1 then ready = ready + 1 end
  end
  for _, queue in ipairs(s.queues) do
    if queue.stalled == 1 then stalled = stalled + 1 end
  end
  if ready + stalled + #s.ready > 0 then
    add(pagelib.header(width, "Needs Attention"))
    if #s.ready > 0 then
      pagelib.action_row(lines, actions, width, { { label = "Collect all", command = "ccollect" } },
        #s.ready .. " finished")
    end
    if ready > 0 then
      pagelib.action_row(lines, actions, width, { { label = "Skills", page = "skills" } },
        ready .. " ready to train")
    end
    if stalled > 0 then
      pagelib.action_row(lines, actions, width, { { label = "Production", page = "jobs" } },
        stalled .. " stalled")
    end
    add("")
  end

  add(pagelib.header(width, "Realm Standing"))
  for _, name in ipairs(REALMS) do
    local rc = pagelib.REALM_COLOR[name] or C.white
    local r = s.realms[name] or { level = 0, bonus = 0, xp = 0, license = 0 }
    local st = s.standing[name] or { drop_rank = 0, drop_extra = 0, drop_bump = 0 }
    add(pagelib.trunc(string.format("%s%-8s%s  %sR%-3d%s  %s+%d%%%s  xp %s  license %d",
      rc, name, pagelib.RESET,
      C.bright_green, r.level, pagelib.RESET,
      C.yellow, r.bonus, pagelib.RESET,
      pagelib.fmt_num(r.xp), r.license), width))
    add(pagelib.trunc("  " .. C.dim .. string.format(
      "drop rank %d, +%d%% extra, +%d%% bump", st.drop_rank, st.drop_extra, st.drop_bump)
      .. pagelib.RESET, width))
  end

  add("")
  add(pagelib.header(width, "Global Standing"))
  add(pagelib.kv(width, "Soul Well tier:", s.soul_tier, C.bright_cyan))
  add(pagelib.kv(width, "Storage tier:", s.storage_tier .. "  (cap " .. s.storage_cap .. ")",
    C.bright_cyan))
  add(pagelib.kv(width, "Speed bonus:", "+" .. s.bonus_speed .. "%", C.yellow))
  add(pagelib.trunc("  " .. C.dim .. "(not yet applied to craft time)" .. pagelib.RESET, width))
  add(pagelib.kv(width, "Logistics bonus:", "+" .. s.bonus_logistics .. " storage", C.yellow))
  add(pagelib.kv(width, "Soul capacity bonus:", "+" .. s.bonus_soul_cap, C.yellow))
  add(pagelib.kv(width, "Soul gain bonus:", "+" .. s.bonus_soul_gain .. "%", C.yellow))

  if not state.has_data() then
    add("")
    add(pagelib.trunc(C.dim .. "No Craft.* data received yet this connection."
      .. pagelib.RESET, width))
  end

  return lines, actions
end

return M
