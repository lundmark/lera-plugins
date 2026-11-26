-- Jobs page: building construction, masterwork queue, typed production
-- queues, and finished items waiting to be collected (Craft.Jobs). Every
-- timer here is an absolute `due` epoch from the server; the countdown is
-- computed fresh on every render (init.lua's 1s timer keeps the popup
-- redrawing while it's open, so this reads live even with no new GMCP frame).
local pagelib = require("pagelib")
local state = require("state")

local C = pagelib.C
local M = {}
local REALMS = { "chaos", "fantasy", "science" }

local function countdown_color(left)
  if left <= 0 then return C.bright_green end
  if left <= 60 then return C.yellow end
  return C.white
end

local function countdown(due, clock)
  local left = (due or 0) - (clock or lera.time())
  if left <= 0 then return "ready", countdown_color(left) end
  local h = math.floor(left / 3600)
  local m = math.floor((left % 3600) / 60)
  local sec = left % 60
  local text
  if h > 0 then text = string.format("%dh %dm", h, m)
  elseif m > 0 then text = string.format("%dm %ds", m, sec)
  else text = string.format("%ds", sec) end
  return text, countdown_color(left)
end

local function due_line(add, width, prefix, name, due, clock)
  local text, color = countdown(due, clock)
  add(pagelib.trunc(string.format("  %s%s%s  %s(%s)%s",
    C.white, prefix .. name, pagelib.RESET, color, text, pagelib.RESET), width))
end

local function queue_batches(add, width, items)
  local previous, count
  local function flush()
    if not previous then return end
    local label = count > 1 and (count .. " x " .. previous) or previous
    add(pagelib.trunc("    " .. C.dim .. "+ " .. pagelib.RESET .. label, width))
  end
  for item in (items or ""):gmatch("[^,]+") do
    item = item:match("^%s*(.-)%s*$")
    if item == previous then
      count = count + 1
    else
      flush()
      previous, count = item, 1
    end
  end
  flush()
end

local function free_queue_slots(s, q)
  local room = s.queue_cap > 0 and s.queue_cap - s.queue_total or 1
  if q and (q.cap or 0) > 0 then room = math.min(room, q.cap - (q.depth or 0)) end
  return room
end

local function queue_buttons(args, recipe, room, can_repeat)
  local command = "cmake " .. args
  local buttons = {}
  if room > 0 then
    buttons[#buttons + 1] = { label = "Queue 1", command = command .. " 1" }
  end
  if room > 1 then
    local items = {}
    for quantity = 2, math.min(room, 5) do
      items[#items + 1] = { label = "Queue " .. quantity, value = command .. " " .. quantity }
    end
    buttons[#buttons + 1] = { label = "More", menu = { title = recipe, items = items } }
  end
  if can_repeat then
    buttons[#buttons + 1] = { label = "Repeat", command = "cmake auto repeat " .. args }
  end
  return buttons
end

-- The catalogue supplies the realm and required building tier. Known recipes
-- supply costs and names. Only exact production matches become cmake actions.
local function realm_buildings(s, realm, tiers, queues)
  local buildings = {}
  for _, recipe in ipairs(s.recipes_catalogue[realm] or {}) do
    local building = recipe.building
    if building and recipe.name and (tiers[building] or queues[building]) then
      local group = buildings[building] or { recipe_tiers = {}, recipes = {} }
      buildings[building] = group
      group.recipe_tiers[recipe.name] = recipe.tier or 0
    end
  end

  for _, recipe in ipairs(s.recipes_known[realm] or {}) do
    local group = buildings[recipe.building]
    local id = recipe.id or ""
    local tier = group and group.recipe_tiers[recipe.name]
    if tier and (id:match("^prod%-") or id:match("^starter%-")) then
      group.recipes[#group.recipes + 1] = { recipe = recipe, tier = tier }
    end
  end

  local names = {}
  for name, group in pairs(buildings) do
    -- Owned refinery catalogue entries are not typed production jobs.
    if queues[name] or #group.recipes > 0 then names[#names + 1] = name end
    table.sort(group.recipes, function(a, b) return a.recipe.name < b.recipe.name end)
  end
  table.sort(names)
  return names, buildings
end

function M.lines(width)
  width = width or 80
  local s = state.get()
  local lines, actions = {}, {}
  local function add(text) lines[#lines + 1] = text end
  local function action(label, command, detail)
    pagelib.action_row(lines, actions, width, { { label = label, command = command } }, detail)
  end

  if #s.ready > 0 then
    add(pagelib.header(width, "Ready to Collect"))
    action("Collect all", "ccollect", #s.ready .. " finished")
    for _, item in ipairs(s.ready) do
      local expiry = ""
      if item.expires and item.expires > 0 then
        expiry = "  expires in " .. countdown(item.expires)
      end
      add(pagelib.trunc("  " .. (item.name or "item") .. C.dim .. "  quality "
        .. tostring(item.quality or 0) .. expiry .. pagelib.RESET, width))
    end
    add("")
  end

  if #s.builds > 0 then
    local sorted = {}
    for _, b in ipairs(s.builds) do sorted[#sorted + 1] = b end
    table.sort(sorted, function(a, b) return (a.building or "") < (b.building or "") end)
    add(pagelib.header(width, "Under Construction"))
    for _, b in ipairs(sorted) do
      due_line(add, width, "", string.format("%s -> T%d", b.building or "?", b.tier or 0),
        b.due, s.jobs_clock)
    end
    add("")
  end

  if #s.pending_builds > 0 then
    local sorted = {}
    for _, b in ipairs(s.pending_builds) do sorted[#sorted + 1] = b end
    table.sort(sorted, function(a, b) return (a.building or "") < (b.building or "") end)
    add(pagelib.header(width, "Awaiting Funding"))
    for _, b in ipairs(sorted) do
      local need_desc
      if b.global == 1 then
        need_desc = pagelib.fmt_num(b.need or 0) .. " tokens from each realm"
      else
        need_desc = pagelib.fmt_num(b.need or 0) .. " " .. (b.token or "") .. " " .. (b.realm or "") .. " tokens"
      end
      add(pagelib.trunc(string.format("  %s%s -> T%d%s  %sneed %s%s",
        C.white, b.building or "?", b.tier or 0, pagelib.RESET,
        C.dim, need_desc, pagelib.RESET), width))
    end
    add(pagelib.trunc(C.dim .. "  Starts automatically once funded." .. pagelib.RESET, width))
    add("")
  end

  if #s.masterwork > 0 then
    add(pagelib.header(width, "Masterwork Queue"))
    for _, mw in ipairs(s.masterwork) do
      local label = (mw.name or "item") .. (mw.target and mw.target > 0
        and (" (level " .. tostring(mw.target) .. ")") or "")
      due_line(add, width, "", label, mw.due, s.jobs_clock)
    end
    add("")
  end

  local queues, tiers, shown = {}, {}, {}
  for _, q in ipairs(s.queues) do if q.building then queues[q.building] = q end end
  for _, b in ipairs(s.buildings) do if b.name then tiers[b.name] = b.tier end end
  add(pagelib.header(width, "Production"))
  add(pagelib.kv(width, "Total queued:", s.queue_total .. " / " .. s.queue_cap, C.bright_cyan))

  local function draw_queue(q)
    if not q then
      add(pagelib.trunc("  " .. C.dim .. "Idle" .. pagelib.RESET, width))
      return
    end
    if q.current_id and q.current_id ~= "" then
      due_line(add, width, "Making ", q.current_name or q.current_id, q.current_due, s.jobs_clock)
    elseif q.stalled == 1 then
      add(pagelib.trunc("  " .. C.bright_red .. "Stalled (missing materials)"
        .. pagelib.RESET, width))
    else
      add(pagelib.trunc("  " .. C.dim .. "Waiting to start" .. pagelib.RESET, width))
    end
    queue_batches(add, width, q.items)
  end

  local function draw_building(name, group)
    local q, tier = queues[name], tiers[name] or 0
    local building_arg = pagelib.command_arg(name)
    local queued = q and ("  " .. (q.depth or 0) .. "/" .. (q.cap or 0) .. " queued") or ""
    add(pagelib.trunc(C.bright_cyan .. name .. pagelib.RESET .. queued, width))
    draw_queue(q)
    if q and (q.depth or 0) > 0 and building_arg then
      pagelib.action_row(lines, actions, width, {
        { label = "Clear queue", menu = { title = name, items = {
          { label = "Keep queued items", value = false },
          { label = "Remove all pending items", value = "cmake cancel " .. building_arg },
        } } },
      })
    end
    local room = free_queue_slots(s, q)
    for _, row in ipairs(group.recipes) do
      local recipe = row.recipe
      local skill = s.skills[recipe.skill]
      local detail = recipe.name .. "  " .. (recipe.materials or "")
      if (recipe.time or 0) > 0 then
        detail = detail .. "  " .. math.ceil(recipe.time / 60) .. " min base"
      end
      local recipe_arg = pagelib.command_arg(recipe.name)
      if tier < row.tier then
        add(pagelib.trunc("  Needs T" .. row.tier .. "  " .. detail, width))
      elseif skill and (skill.rank or 0) < (recipe.rank or 0) then
        add(pagelib.trunc("  Needs R" .. recipe.rank .. "  " .. detail, width))
      elseif (room > 0 or s.automation) and building_arg and recipe_arg then
        local buttons = queue_buttons(building_arg .. " " .. recipe_arg, recipe.name, room, s.automation)
        pagelib.action_row(lines, actions, width, buttons, detail)
      else
        add(pagelib.trunc("  " .. detail, width))
      end
    end
    add("")
  end

  for _, realm in ipairs(REALMS) do
    local names, buildings = realm_buildings(s, realm, tiers, queues)
    if #names > 0 then
      add(pagelib.header(width, pagelib.title(realm)))
      for _, name in ipairs(names) do
        shown[name] = true
        draw_building(name, buildings[name])
      end
    end
  end

  local other = {}
  for name in pairs(queues) do
    if not shown[name] then other[#other + 1] = name end
  end
  table.sort(other)
  for _, name in ipairs(other) do draw_building(name, { recipes = {} }) end
  if not next(shown) and #other == 0 then
    add(pagelib.trunc(C.dim .. "No production jobs or available recipes." .. pagelib.RESET, width))
  end

  return lines, actions
end

return M
