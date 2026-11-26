-- Saved server settings and the repeat plan by realm.
local pagelib = require("pagelib")
local state = require("state")

local M = {}
local REALMS = { "Chaos", "Fantasy", "Science", "Other" }

function M.lines(width)
  width = pagelib.page_width(width)
  local s = state.get()
  local plan = s.automation
  local lines, actions = { pagelib.header(width, "Crafting Automation") }, {}
  local function add(text) lines[#lines + 1] = pagelib.trunc(text, width) end

  if not plan then
    add("Waiting for automation settings from Craft.Jobs.")
    return lines
  end

  local running, collect = plan.enabled == 1, plan.collect == 1
  local recipient = collect and plan.recipient and plan.recipient ~= ""
    and ("On for " .. pagelib.title(plan.recipient)) or (collect and "On" or "Off")
  local items = {}
  for _, n in ipairs({ 0, 5, 10, 20, 50, 100 }) do
    items[#items + 1] = { label = tostring(n), value = "cmake auto reserve " .. n }
  end
  pagelib.add_table(lines, width, {
    { title = "Setting", w = "*" }, { title = "Current value", w = 27 },
    { title = "Action", w = 22 },
  }, {
    { "Repeat plan", running and (plan.idle == 1 and "Paused while idle" or "Enabled") or "Paused" },
    { "Auto-collect", recipient },
    { "Material reserve", (plan.reserve or 0) .. " of each input" },
  }, actions, {
    { { label = running and "Pause" or "Start", command = running and "cmake auto off" or "cmake auto on" } },
    { { label = collect and "Auto-collect on" or "Auto-collect off",
      command = collect and "cmake auto collect off" or "cmake auto collect on" } },
    { { label = "Reserve", menu = { title = "Keep this many of each input", items = items } } },
  })

  add("")
  add("Manual queues take priority over repeat recipes.")
  if (plan.scrap or 0) > 1 then
    add("Auto-scrap is on. Discarded crafts earn no production XP.")
  end
  pagelib.action_row(lines, actions, width, {
    { label = "Choose recipes", page = "jobs" },
    { label = "Autotrain skills", page = "skills" },
    { label = "Refineries", page = "refinery" },
  })
  add("")

  local groups = { Chaos = {}, Fantasy = {}, Science = {}, Other = {} }
  for _, rule in ipairs(s.repeat_rules) do
    local group = groups[pagelib.title(rule.realm)] or groups.Other
    group[#group + 1] = rule
  end
  if #s.repeat_rules == 0 then add("Use Repeat on a recipe in Production to add a rule.") end

  for _, realm in ipairs(REALMS) do
    local group = groups[realm]
    if #group > 0 then
      table.sort(group, function(a, b) return a.building < b.building end)
      add(pagelib.header(width, realm .. " Repeat Recipes", pagelib.REALM_COLOR[realm]))
      local rows, buttons = {}, {}
      for _, rule in ipairs(group) do
        local building = pagelib.command_arg(rule.building)
        rows[#rows + 1] = { rule.building, rule.recipe or "?", rule.status or "Waiting" }
        if building then buttons[#rows] = { { label = "Clear", command = "cmake auto clear " .. building } } end
      end
      pagelib.add_table(lines, width, {
        { title = "Building", w = 21 }, { title = "Recipe", w = 23 },
        { title = "Status", w = "*" }, { title = "Action", w = 9 },
      }, rows, actions, buttons)
      add("")
    end
  end
  return lines, actions
end

return M
