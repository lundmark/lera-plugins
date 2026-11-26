-- Craft.Skills, grouped by realm with available training first in each realm.
local pagelib = require("pagelib")
local state = require("state")

local C = pagelib.C
local RESET = pagelib.RESET
local M = {}

local STATUS = {
  [1] = "Ready", [-1] = "Maxed", [-2] = "Locked",
  [-3] = "Needs XP", [-4] = "Needs tokens",
}
local REALMS = { "Chaos", "Fantasy", "Science", "General" }

local function trainable(skill)
  return skill.unlocked == 1 and skill.can_train == 1
end

local function skill_line(width, name, skill)
  local rank = tostring(skill.rank or 0)
  if (skill.rank or 0) ~= (skill.trained or 0) then
    rank = rank .. "/" .. tostring(skill.trained or 0)
  end
  local status = skill.unlocked == 1 and (STATUS[skill.can_train] or "Waiting") or "Locked"
  local text = pagelib.title(name) .. "  R" .. rank .. "  " .. status
  if width >= 58 and (skill.to_next or 0) > 0 and status ~= "Locked" then
    text = text .. "  " .. pagelib.fmt_num(skill.into) .. "/" .. pagelib.fmt_num(skill.to_next) .. " XP"
  end
  if (skill.train_cost or 0) > 0 and status ~= "Locked" then
    text = text .. "  " .. pagelib.fmt_num(skill.train_cost) .. "x " .. (skill.train_abbr or "?")
  end
  return text
end

function M.lines(width)
  width = width or 80
  local skills = state.get().skills
  local lines, actions = {}, {}
  if not next(skills) then
    return { pagelib.trunc(C.dim .. "Waiting for crafting skills." .. RESET, width) }
  end

  local groups = { Chaos = {}, Fantasy = {}, Science = {}, General = {} }
  for name, skill in pairs(skills) do
    local realm = pagelib.title(skill.train_realm) or "General"
    local group = groups[realm] or groups.General
    group[#group + 1] = name
  end

  for _, realm in ipairs(REALMS) do
    local names = groups[realm]
    if #names > 0 then
      local ready = 0
      for _, name in ipairs(names) do
        if trainable(skills[name]) then ready = ready + 1 end
      end
      table.sort(names, function(a, b)
        local ar, br = trainable(skills[a]), trainable(skills[b])
        if ar ~= br then return ar end
        return a < b
      end)
      lines[#lines + 1] = pagelib.header(width, realm .. " Skills (" .. ready .. " ready)")
      for _, name in ipairs(names) do
        local skill = skills[name]
        local buttons = {}
        local arg = pagelib.command_arg(name)
        if arg and trainable(skill) then
          buttons[#buttons + 1] = { label = "Train", command = "ctrain " .. arg }
        end
        if arg and skill.autotrain ~= nil and (skill.unlocked == 1 or skill.autotrain == 1) then
          buttons[#buttons + 1] = {
            label = skill.autotrain == 1 and "Auto on" or "Auto off",
            command = "ctrain auto " .. arg,
          }
        end
        pagelib.action_row(lines, actions, width, buttons, skill_line(width, name, skill))
      end
      lines[#lines + 1] = ""
    end
  end
  return lines, actions
end

return M
