local pagelib = require("pagelib")
local recipe_inputs = require("recipe_inputs")

local M = {}

function M.is_recipe(recipe)
  local id = recipe.id or ""
  return id:match("^prod%-") or id:match("^starter%-")
end

local function free_slots(s, queue)
  local room = s.queue_cap > 0 and s.queue_cap - s.queue_total or 1
  local cap = queue and (queue.cap or 0) > 0 and queue.cap or 5
  return math.min(room, cap - (queue and queue.depth or 0))
end

local function batch_items(command, recipe, first, room)
  local items = {}
  local inputs = recipe_inputs.parse(recipe.materials)
  for quantity = first, room do
    local cost = recipe_inputs.total(inputs, quantity)
    local time = (recipe.time or 0) > 0 and math.ceil(recipe.time * quantity / 60) .. " min base"
    local detail = (cost or "Cost unavailable") .. " | " .. (time or "Time unavailable")
    items[#items + 1] = { label = "Queue " .. quantity .. " | " .. detail,
      value = command .. " " .. quantity }
  end
  return items
end

local function recipe_menu(recipe, room, items)
  return { title = recipe.name .. " | " .. math.max(0, room) .. " free slots", items = items }
end

local function batch_menu(command, recipe, room)
  local items = batch_items(command, recipe, 2, room)
  return recipe_menu(recipe, room, items)
end

local function repeat_options(items, s, recipe, building, command)
  if not s.automation then return end
  local rule
  for _, candidate in ipairs(s.repeat_rules) do
    if candidate.building == recipe.building then
      rule = candidate
      break
    end
  end

  local configured = rule and rule.recipe == recipe.name
  local enabled = s.automation.enabled == 1
  if configured then
    local label = "Stop repeating this recipe"
    if rule.status then label = label .. " | " .. rule.status end
    items[#items + 1] = { label = label,
      value = "cmake auto clear " .. building }
  else
    local label = rule and ("Replace repeat for " .. rule.recipe) or "Repeat this recipe"
    items[#items + 1] = { label = enabled and label or (label .. " (save while paused)"),
      value = command }
  end
  items[#items + 1] = {
    label = enabled and "Pause all automation" or "Start all saved automation",
    value = enabled and "cmake auto off" or "cmake auto on",
  }
  items[#items + 1] = { label = "Open Automation", value = { page = "automation" } }
end

function M.eligibility(recipe, tier, required, skill)
  if not tier or tier < 1 then return "Build station" end
  if not required then return "Waiting for catalogue" end
  if tier < required then return "Needs T" .. required end
  if skill and skill.unlocked == 0 then return "Skill locked" end
  if (recipe.rank or 0) > 0 then
    if not skill then return "Waiting for skill" end
    if (skill.rank or 0) < recipe.rank then return "Needs R" .. recipe.rank end
  end
end

function M.actions(s, recipe, queue, tier, required)
  if not M.is_recipe(recipe) then return nil, "" end
  local note = M.eligibility(recipe, tier, required, s.skills[recipe.skill])
  if note then return nil, note end

  local building = pagelib.command_arg(recipe.building)
  local name = pagelib.command_arg(recipe.name)
  if not building or not name then return nil, "" end
  local args = building .. " " .. name
  local command = "cmake " .. args
  local room = free_slots(s, queue)
  local buttons = {}
  local single = room > 0 and (command .. " 1") or nil
  local auto = "cmake auto repeat " .. args
  if room > 0 then
    buttons[#buttons + 1] = { label = "Queue 1", command = single, allow_repeat = true }
  end
  if room > 1 then
    buttons[#buttons + 1] = { label = "More",
      menu = function() return batch_menu(command, recipe, room) end }
  end
  if s.automation then
    buttons[#buttons + 1] = { label = "Repeat", menu = function()
      local items = {}
      repeat_options(items, s, recipe, building, auto)
      return { title = recipe.name, items = items }
    end }
  end
  if single or s.automation then
    buttons.primary = {
      key = args, command = single, allow_repeat = true,
      menu = function()
        local items = batch_items(command, recipe, 1, room)
        repeat_options(items, s, recipe, building, auto)
        return recipe_menu(recipe, room, items)
      end,
    }
  end
  return buttons, room <= 0 and "Queue full" or ""
end

return M
