-- Overview: tasks that need attention, realm standing, and shared capacity.
local pagelib = require("pagelib")
local state = require("state")

local C, RESET = pagelib.C, pagelib.RESET
local M = {}
local REALMS = { "Chaos", "Fantasy", "Science" }

function M.lines(width)
  width = pagelib.page_width(width)
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

  local attention, buttons = {}, {}
  local function show_attention(task, count, button)
    if count < 1 then return end
    attention[#attention + 1] = { task, count }
    buttons[#attention] = { button }
  end
  show_attention("Finished items", #s.ready, { label = "Collect all", command = "ccollect" })
  show_attention("Skills ready to train", ready, { label = "Skills", page = "skills" })
  show_attention("Stalled buildings", stalled, { label = "Production", page = "jobs" })
  if #attention > 0 then
    add(pagelib.header(width, "Needs Attention"))
    pagelib.add_table(lines, width, {
      { title = "Task", w = "*" }, { title = "Count", w = 8 }, { title = "Action", w = 18 },
    }, attention, actions, buttons)
    add("")
  end

  add(pagelib.header(width, "Realm Standing"))
  local standing = {}
  for _, name in ipairs(REALMS) do
    local r = s.realms[name] or { level = 0, bonus = 0, xp = 0, license = 0 }
    local st = s.standing[name] or { drop_rank = 0, drop_extra = 0, drop_bump = 0 }
    standing[#standing + 1] = { pagelib.REALM_COLOR[name] .. name .. RESET, r.level,
      pagelib.fmt_num(r.xp), "+" .. r.bonus .. "%", r.license, st.drop_rank,
      "+" .. st.drop_extra .. "%", "+" .. st.drop_bump .. "%" }
  end
  pagelib.add_table(lines, width, {
    { title = "Realm", w = "*" }, { title = "Level", w = 6 }, { title = "Total XP", w = 10 },
    { title = "Bonus", w = 7 }, { title = "License", w = 8 }, { title = "Drop rank", w = 10 },
    { title = "Extra drop", w = 11 }, { title = "Tier bump", w = 10 },
  }, standing)

  add("")
  add(pagelib.header(width, "Capacity"))
  pagelib.add_table(lines, width, {
    { title = "Resource", w = "*" }, { title = "Tier", w = 6 },
    { title = "Used / Capacity", w = 33 },
  }, {
    { "Material storage", s.storage_tier, pagelib.meter(s.stock_used, s.stock_cap, 33) },
    { "Soul Well", s.soul_tier, pagelib.meter(s.souls, s.soul_cap, 33) },
    { "Production queue", "-", pagelib.meter(s.queue_total, s.queue_cap, 33) },
  })

  add("")
  add(pagelib.header(width, "Bonuses"))
  pagelib.add_table(lines, width, {
    { title = "Bonus", w = "*" }, { title = "Value", w = 16 },
  }, {
    { "Crafting speed", "+" .. s.bonus_speed .. "%" },
    { "Storage", "+" .. s.bonus_logistics },
    { "Soul capacity", "+" .. s.bonus_soul_cap .. "%" },
    { "Soul gain", "+" .. s.bonus_soul_gain .. "%" },
  })

  if not state.has_data() then
    add("")
    add(pagelib.trunc(C.dim .. "No Craft.* data received yet this connection." .. RESET, width))
  end
  return lines, actions
end

return M
