-- Server-owned automation. The panel sends settings, never runs a queue loop.
local pagelib = require("pagelib")
local state = require("state")

local M = {}
local REALMS = { "Chaos", "Fantasy", "Science", "Other" }

local function add_button(lines, actions, width, label, command, text)
  pagelib.action_row(lines, actions, width, { { label = label, command = command } }, text)
end

function M.lines(width)
  width = width or 80
  local s = state.get()
  local plan = s.automation
  local lines, actions = { pagelib.header(width, "Crafting Automation") }, {}
  local function add(text) lines[#lines + 1] = pagelib.trunc(text, width) end

  if not plan then
    add("Waiting for automation settings from Craft.Jobs.")
    return lines
  end

  local running = plan.enabled == 1
  add_button(lines, actions, width, running and "Pause" or "Start",
    running and "cmake auto off" or "cmake auto on",
    running and (plan.idle == 1 and "Paused while idle" or "Repeat plan enabled") or "Repeat plan paused")

  local collect = plan.collect == 1
  local recipient = collect and plan.recipient and plan.recipient ~= ""
    and ("Delivers to " .. pagelib.title(plan.recipient)) or "Delivers to inventory while active"
  add_button(lines, actions, width, collect and "Auto-collect on" or "Auto-collect off",
    collect and "cmake auto collect off" or "cmake auto collect on", recipient)

  local items = {}
  for _, n in ipairs({ 0, 5, 10, 20, 50, 100 }) do
    items[#items + 1] = { label = tostring(n), value = "cmake auto reserve " .. n }
  end
  pagelib.action_row(lines, actions, width, {
    { label = "Reserve", menu = { title = "Keep this many of each input", items = items } },
  }, (plan.reserve or 0) .. " of each input kept in stock")

  add("")
  add("Manual queues take priority over repeat recipes.")
  if (plan.scrap or 0) > 1 then
    add("Auto-scrap is on. Discarded crafts earn no production XP.")
  end
  pagelib.action_row(lines, actions, width, {
    { label = "Choose recipes", page = "jobs" },
    { label = "Autotrain skills", page = "skills" },
    { label = "Refineries", page = "refinery" },
  }, "")
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
      add(pagelib.header(width, realm))
      for _, rule in ipairs(group) do
        local building = pagelib.command_arg(rule.building)
        local text = rule.building .. " - " .. (rule.recipe or "?")
        if building then
          add_button(lines, actions, width, "Clear", "cmake auto clear " .. building, text)
        else
          add(text)
        end
        add("  " .. (rule.status or "Waiting"))
      end
    end
  end

  return lines, actions
end

return M
