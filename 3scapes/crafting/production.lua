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

local function batch_menu(command, recipe, room)
  local items = {}
  local inputs = recipe_inputs.parse(recipe.materials)
  for quantity = 2, room do
    local cost = recipe_inputs.total(inputs, quantity)
    local time = (recipe.time or 0) > 0 and math.ceil(recipe.time * quantity / 60) .. " min base"
    local detail = (cost or "Cost unavailable") .. " | " .. (time or "Time unavailable")
    items[#items + 1] = { label = "Queue " .. quantity .. " | " .. detail,
      value = command .. " " .. quantity }
  end
  return { title = recipe.name .. " | " .. room .. " free slots", items = items }
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
  if room > 0 then
    buttons[#buttons + 1] = { label = "Queue 1", command = command .. " 1" }
  end
  if room > 1 then
    buttons[#buttons + 1] = { label = "More", menu = batch_menu(command, recipe, room) }
  end
  if s.automation then
    buttons[#buttons + 1] = { label = "Repeat", command = "cmake auto repeat " .. args }
  end
  return buttons, room <= 0 and "Queue full" or ""
end

return M
