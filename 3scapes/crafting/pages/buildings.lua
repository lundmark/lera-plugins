-- Buildings page: every built building -> tier, plus refinery splits
-- (Craft.Buildings). Both fields are arrays of flat records, not mappings
-- keyed by building name -- that shape was confirmed to vanish entirely
-- over GMCP delivery (see crafting_daemon's gmcp.h _cgmcp_push_buildings).
local pagelib = require("pagelib")
local state = require("state")

local C = pagelib.C
local M = {}
local REALMS = { "Chaos", "Fantasy", "Science", "Global" }
local LEGACY_MAX_TIER = 5

local function tier_color(t)
  if t >= 5 then return C.bright_green end
  if t >= 3 then return C.green end
  if t >= 1 then return C.yellow end
  return C.dim
end

local function plan_blocker(plan, entries, skills)
  local prerequisite = entries[plan.prerequisite]
  if plan.prerequisite ~= "" and (not prerequisite or (prerequisite.tier or 0) < 1) then
    return "Build " .. plan.prerequisite .. " first"
  end
  local skill = skills[plan.skill]
  if skill and skill.unlocked == 0 then
    return "Unlock " .. pagelib.title(plan.skill)
  end
end

local function build_menu(name, cost, duration, blocker)
  local arg = pagelib.command_arg(name)
  if not arg then return nil end
  local items = { { label = "View cost and requirements", value = "cbuild construct " .. arg } }
  if not blocker then
    items[#items + 1] = { label = "Queue Tier 1 construction", value = "cbuild construct " .. arg .. " confirm" }
  end
  return { title = name .. " | " .. cost .. " | " .. duration, items = items }
end

local function duration_text(seconds)
  local minutes = math.ceil(seconds / 60)
  if minutes < 60 then return minutes .. "m" end
  return string.format("%dh %02dm", math.floor(minutes / 60), minutes % 60)
end

local function upgrade_action(name, building, plans, tiers)
  if not building.tier or building.tier < 1 or building.build or building.pending then return end
  local arg = pagelib.command_arg(name)
  local next_tier = building.tier + 1
  local quote = tiers[next_tier]
  if not arg or (not quote and building.tier >= LEGACY_MAX_TIER) then return end

  local plan = plans[name]
  local title = name .. " | Tier " .. next_tier
  local menu = { title = title, items = {
    { label = "View cost and token breakdown", value = "cbuild build " .. arg },
  } }
  if quote and plan then
    local realm = plan.realm == "Global" and "per realm" or "(" .. plan.realm .. ")"
    local cost = pagelib.fmt_num(quote.cost) .. " T" .. next_tier .. " tokens " .. realm
    menu.title = title .. " | " .. cost .. " | " .. duration_text(quote.duration)
    menu.items[#menu.items + 1] = {
      label = "Queue Tier " .. next_tier .. " upgrade",
      value = "cbuild upgrade-to " .. next_tier .. " " .. arg .. " confirm",
    }
  end
  return {
    { label = "Upgrade", menu = menu },
    primary = { key = name, menu = menu, left_menu = true },
  }
end

local function add_unbuilt(lines, actions, width, s, entries)
  local groups = { Chaos = {}, Fantasy = {}, Science = {}, Global = {} }
  for _, plan in ipairs(s.build_plans) do
    local group = groups[plan.realm]
    if group and not entries[plan.name] then group[#group + 1] = plan end
  end
  local heading = false
  for _, realm in ipairs(REALMS) do
    local plans = groups[realm]
    if #plans > 0 then
      if not heading then
        lines[#lines + 1] = ""
        lines[#lines + 1] = pagelib.header(width, "Unbuilt Buildings")
        heading = true
      end
      table.sort(plans, function(a, b) return a.name < b.name end)
      lines[#lines + 1] = pagelib.header(width, realm, pagelib.REALM_COLOR[realm])
      local rows, buttons = {}, {}
      for _, plan in ipairs(plans) do
        local blocker = plan_blocker(plan, entries, s.skills)
        local cost = pagelib.fmt_num(plan.cost) .. " " .. plan.token
        local duration = duration_text(plan.duration)
        local menu = build_menu(plan.name, cost, duration, blocker)
        local label = menu and C.bright_cyan .. plan.name .. pagelib.RESET or plan.name
        rows[#rows + 1] = { label, cost, duration, blocker or "Available", "" }
        if menu then
          buttons[#rows] = {
            { label = blocker and "Details" or "Build", menu = menu },
            primary = { key = plan.name, menu = menu, left_menu = true },
          }
        end
      end
      pagelib.add_table(lines, width, {
        { title = "Building", w = "*" }, { title = "T1 cost", w = 16 }, { title = "Build time", w = 10 },
        { title = "Requirements", w = 28 }, { title = "Action", w = 11 },
      }, rows, actions, buttons)
      lines[#lines + 1] = ""
    end
  end
end

function M.lines(width)
  width = pagelib.page_width(width)
  local s = state.get()
  local lines, actions = {}, {}
  local function add(text) lines[#lines + 1] = text end

  if #s.buildings == 0 and #s.builds == 0 and #s.pending_builds == 0 and #s.build_plans == 0 then
    add(pagelib.trunc(C.dim .. "No buildings constructed yet." .. pagelib.RESET, width))
    return lines
  end

  local entries, names = {}, {}
  local function entry(name)
    if not entries[name] then
      entries[name] = {}
      names[#names + 1] = name
    end
    return entries[name]
  end
  for _, b in ipairs(s.buildings) do entry(b.name or "?").tier = b.tier end
  for _, b in ipairs(s.pending_builds) do entry(b.building or "?").pending = b.tier end
  for _, b in ipairs(s.builds) do entry(b.building or "?").build = b end
  table.sort(names)

  local rows, buttons, plans = {}, {}, {}
  for _, plan in ipairs(s.build_plans) do plans[plan.name] = plan end
  for _, name in ipairs(names) do
    local b = entries[name]
    local current = b.tier and (tier_color(b.tier) .. "T" .. b.tier .. pagelib.RESET) or "-"
    local target = b.build and b.build.tier or b.pending
    local status = b.build and "Under construction" or b.pending and "Awaiting funding" or "Built"
    local timer = b.build and pagelib.job_time(b.build.due, b.build.duration, s.jobs_clock) or "-"
    local button = upgrade_action(name, b, plans, s.upgrade_tiers)
    local label = button and C.bright_cyan .. name .. pagelib.RESET or name
    rows[#rows + 1] = { label, current, target and ("T" .. target) or "-", status, timer, "" }
    buttons[#rows] = button
  end
  if #rows > 0 then
    add(pagelib.header(width, "Buildings"))
    pagelib.add_table(lines, width, {
      { title = "Building", w = "*" }, { title = "Tier", w = 6 }, { title = "Target", w = 7 },
      { title = "Status", w = 20 }, { title = "Completion", w = 25 }, { title = "Action", w = 11 },
    }, rows, actions, buttons)
  end
  add_unbuilt(lines, actions, width, s, entries)

  -- Refineries have their own tab now. This used to inline every allocation
  -- here, which was reasonable while the server sent only the stages that had
  -- one; it now sends the whole ten-stage chain per refinery, so reproducing
  -- it here would bury the building list under sixty mostly-empty rows.
  -- A one-line summary keeps the cross-reference without the noise.
  if #s.refineries > 0 then
    local seen, count, allocated = {}, 0, 0
    for _, r in ipairs(s.refineries) do
      local k = r.building or "?"
      if not seen[k] then seen[k] = true; count = count + 1 end
      if (r.percent or 0) > 0 then allocated = allocated + 1 end
    end
    add("")
    add(pagelib.trunc(string.format(
      "%s%d refiner%s, %d allocated stage%s -- see the Refinery tab%s",
      C.dim, count, count == 1 and "y" or "ies",
      allocated, allocated == 1 and "" or "s", pagelib.RESET), width))
  end

  return lines, actions
end

return M
