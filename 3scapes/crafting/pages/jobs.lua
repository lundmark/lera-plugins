-- Jobs page: building construction, masterwork queue, typed production
-- queues, and finished items waiting to be collected (Craft.Jobs). Every
-- timer here is an absolute `due` epoch from the server; the countdown is
-- computed fresh on every render (init.lua's 1s timer keeps the popup
-- redrawing while it's open, so this reads live even with no new GMCP frame).
local pagelib = require("pagelib")
local production = require("production")
local state = require("state")

local C = pagelib.C
local M = {}
local REALMS = { "chaos", "fantasy", "science" }

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

-- The catalogue supplies the realm and required building tier. Known recipes
-- supply costs and names. Only exact production matches become cmake actions.
local function realm_buildings(s, realm, tiers, queues)
  local buildings = {}
  for _, recipe in ipairs(s.recipes_catalogue[realm] or {}) do
    local building = recipe.building
    if building and recipe.name and (tiers[building] or queues[building]) then
      local group = buildings[building] or { recipe_tiers = {}, recipes = {} }
      buildings[building] = group
      group.is_production = group.is_production or recipe.production == 1
      group.recipe_tiers[recipe.name] = recipe.tier or 0
    end
  end

  for _, recipe in ipairs(s.recipes_known[realm] or {}) do
    local group = buildings[recipe.building]
    local tier = group and group.recipe_tiers[recipe.name]
    if tier and production.is_recipe(recipe) then
      group.is_production = true
      group.recipes[#group.recipes + 1] = { recipe = recipe, tier = tier }
    end
  end

  local names = {}
  for name, group in pairs(buildings) do
    -- Owned refinery catalogue entries are not typed production jobs.
    if queues[name] or group.is_production then names[#names + 1] = name end
    table.sort(group.recipes, function(a, b) return a.recipe.name < b.recipe.name end)
  end
  table.sort(names)
  return names, buildings
end

local function draw_attention(lines, actions, width, s, queues, realms)
  local rows, buttons, idle = {}, {}, {}
  for _, q in ipairs(s.queues) do
    if q.stalled == 1 then
      local missing = q.shortfall and q.shortfall ~= "" and q.shortfall or "materials"
      rows[#rows + 1] = { q.building or "?", "Missing " .. missing }
      buttons[#rows] = { { label = "Inventory", page = "inventory" },
        { label = "Refinery", page = "refinery" } }
    end
  end
  for _, realm in ipairs(REALMS) do
    for _, name in ipairs(realms[realm].names) do
      if not queues[name] then idle[#idle + 1] = name end
    end
  end
  if #rows == 0 and #idle == 0 then return end
  local function add(line) lines[#lines + 1] = line end
  add(pagelib.header(width, "Needs Attention"))
  if #rows > 0 then
    pagelib.add_table(lines, width, {
      { title = "Stalled building", w = 23 }, { title = "Why it stopped", w = "*" },
      { title = "Open", w = 25 },
    }, rows, actions, buttons)
  end
  if #idle > 0 then
    add(pagelib.header(width, "Idle Buildings (" .. #idle .. ")", C.dim))
    for _, name in ipairs(idle) do add(pagelib.trunc("  " .. name, width)) end
  end
  add("")
end

function M.lines(width)
  width = pagelib.page_width(width)
  local s = state.get()
  local lines, actions = {}, {}
  local function add(text) lines[#lines + 1] = text end
  local function action(label, command, detail)
    pagelib.action_row(lines, actions, width, { { label = label, command = command } }, detail)
  end

  if #s.ready > 0 then
    add(pagelib.header(width, "Ready to Collect"))
    action("Collect all", "ccollect", #s.ready .. " finished")
    local rows = {}
    for _, item in ipairs(s.ready) do
      rows[#rows + 1] = { item.name or "item", item.quality or "-", pagelib.job_time(item.expires) }
    end
    pagelib.add_table(lines, width, {
      { title = "Item", w = "*" }, { title = "Quality", w = 10 }, { title = "Expires in", w = 13 },
    }, rows)
    add("")
  end

  local queues, tiers, shown, realms = {}, {}, {}, {}
  for _, q in ipairs(s.queues) do if q.building then queues[q.building] = q end end
  for _, b in ipairs(s.buildings) do if b.name then tiers[b.name] = b.tier end end
  for _, realm in ipairs(REALMS) do
    local names, buildings = realm_buildings(s, realm, tiers, queues)
    realms[realm] = { names = names, buildings = buildings }
  end
  draw_attention(lines, actions, width, s, queues, realms)

  if #s.builds > 0 then
    local sorted = {}
    for _, b in ipairs(s.builds) do sorted[#sorted + 1] = b end
    table.sort(sorted, function(a, b) return (a.building or "") < (b.building or "") end)
    add(pagelib.header(width, "Under Construction"))
    local rows = {}
    for _, b in ipairs(sorted) do
      rows[#rows + 1] = { b.building or "?", b.tier or "-", pagelib.job_time(b.due, b.duration, s.jobs_clock) }
    end
    pagelib.add_table(lines, width, {
      { title = "Building", w = "*" }, { title = "Target tier", w = 12 }, { title = "Completion", w = 32 },
    }, rows)
    add("")
  end

  if #s.pending_builds > 0 then
    local sorted = {}
    for _, b in ipairs(s.pending_builds) do sorted[#sorted + 1] = b end
    table.sort(sorted, function(a, b) return (a.building or "") < (b.building or "") end)
    add(pagelib.header(width, "Awaiting Funding"))
    local rows = {}
    for _, b in ipairs(sorted) do
      local need_desc
      if b.global == 1 then
        need_desc = pagelib.fmt_num(b.need or 0) .. " tokens from each realm"
      else
        need_desc = pagelib.fmt_num(b.need or 0) .. " " .. (b.token or "") .. " " .. (b.realm or "") .. " tokens"
      end
      rows[#rows + 1] = { b.building or "?", b.tier or "-", need_desc }
    end
    pagelib.add_table(lines, width, {
      { title = "Building", w = "*" }, { title = "Target tier", w = 12 }, { title = "Still needed", w = 36 },
    }, rows)
    add("")
  end

  if #s.masterwork > 0 then
    add(pagelib.header(width, "Masterwork Queue"))
    local rows = {}
    for _, mw in ipairs(s.masterwork) do
      rows[#rows + 1] = { mw.name or "item", mw.target or "-", pagelib.job_time(mw.due, mw.duration, s.jobs_clock) }
    end
    pagelib.add_table(lines, width, {
      { title = "Item", w = "*" }, { title = "Target level", w = 13 }, { title = "Completion", w = 32 },
    }, rows)
    add("")
  end

  add(pagelib.header(width, "Production"))
  add(pagelib.kv(width, "Total queued:", pagelib.meter(s.queue_total, s.queue_cap, 33)))

  local function draw_queue(q)
    if not q then
      add(pagelib.trunc("  " .. C.dim .. "Idle" .. pagelib.RESET, width))
      return
    end
    if q.current_id and q.current_id ~= "" then
      pagelib.add_table(lines, width, {
        { title = "In production", w = "*" }, { title = "Completion", w = 32 },
      }, { { q.current_name or q.current_id, pagelib.job_time(q.current_due, q.current_duration, s.jobs_clock) } })
    elseif q.stalled == 1 then
      add(pagelib.trunc("  " .. C.bright_red .. "Stalled: missing "
        .. (q.shortfall and q.shortfall ~= "" and q.shortfall or "materials")
        .. pagelib.RESET, width))
    else
      add(pagelib.trunc("  " .. C.dim .. "Waiting to start" .. pagelib.RESET, width))
    end
    queue_batches(add, width, q.items)
  end

  local function draw_building(name, group)
    local q, tier = queues[name], tiers[name] or 0
    local building_arg = pagelib.command_arg(name)
    add(pagelib.header(width, name, C.bright_cyan))
    if q then add(pagelib.kv(width, "Queue:", pagelib.meter(q.depth, q.cap, 33))) end
    draw_queue(q)
    if q and (q.depth or 0) > 0 and building_arg then
      pagelib.action_row(lines, actions, width, {
        { label = "Clear queue", menu = { title = name, items = {
          { label = "Keep queued items", value = false },
          { label = "Remove all pending items", value = "cmake cancel " .. building_arg },
        } } },
      })
    end
    local rows, recipe_buttons = {}, {}
    for _, row in ipairs(group.recipes) do
      local recipe = row.recipe
      local base = (recipe.time or 0) > 0 and (math.ceil(recipe.time / 60) .. " min") or "-"
      local buttons, note = production.actions(s, recipe, q, tier, row.tier)
      recipe_buttons[#rows + 1] = buttons
      rows[#rows + 1] = { recipe.name, recipe.rank or "-", base, recipe.materials or "-", note }
    end
    if #rows > 0 then
      pagelib.add_table(lines, width, {
        { title = "Recipe", w = "*" }, { title = "Rank", w = 5 }, { title = "Base time", w = 10 },
        { title = "Ingredients", w = 22 }, { title = "Action / Status", w = 27 },
      }, rows, actions, recipe_buttons)
    end
    add("")
  end

  for _, realm in ipairs(REALMS) do
    local names, buildings = realms[realm].names, realms[realm].buildings
    if #names > 0 then
      local label = pagelib.title(realm)
      add(pagelib.header(width, label, pagelib.REALM_COLOR[label]))
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
