-- Craft.Skills: aligned training and progress by realm.
local pagelib = require("pagelib")
local state = require("state")

local C = pagelib.C
local RESET = pagelib.RESET
local M = {}

local REALMS = { "Chaos", "Fantasy", "Science", "General" }
local STATUS = {
  [1] = { "Ready", C.bright_green },
  [0] = { "Needs XP", C.dim },
  [-1] = { "Maxed", C.bright_green },
  [-3] = { "Needs tokens", C.yellow },
  [-4] = { "Needs tokens", C.yellow },
}
local LOCKED = { "Locked", C.dim }
local UNKNOWN = { "Unknown", C.dim }

local function trainable(skill)
  return skill.unlocked == 1 and skill.can_train == 1
end

local function training_status(skill)
  if skill.unlocked ~= 1 then return LOCKED end
  return STATUS[skill.can_train] or UNKNOWN
end

local function progress_text(skill, width)
  if skill.unlocked ~= 1 or skill.can_train == -1 then return "-" end
  if type(skill.into) ~= "number" or type(skill.to_next) ~= "number" then return "-" end

  -- The feed sends earned and remaining XP. Remaining can be negative
  -- when enough XP for multiple ranks has already been banked.
  local target = skill.into + skill.to_next
  if target <= 0 then return "-" end
  local earned = math.min(target, math.max(0, skill.into))
  local label = pagelib.fmt_num(earned) .. "/" .. pagelib.fmt_num(target)
  local bar_width = width - 12
  if bar_width < 5 or #label > 11 then return label end

  local color = earned == target and C.bright_green or C.bright_cyan
  return pagelib.bar(bar_width, earned, target, color) .. " " .. label
end

local function next_cost(skill)
  if skill.unlocked ~= 1 or skill.can_train == -1 or (skill.train_cost or 0) <= 0 then
    return "-"
  end
  local color = pagelib.REALM_COLOR[pagelib.title(skill.train_realm)] or C.white
  return color .. pagelib.fmt_num(skill.train_cost) .. "x " .. (skill.train_abbr or "?") .. RESET
end

local function skill_buttons(name, skill)
  local arg = pagelib.command_arg(name)
  if not arg then return nil, nil end
  local train, auto
  if trainable(skill) then
    train = { label = "Train", command = "ctrain " .. arg }
  end
  if skill.autotrain ~= nil and (skill.unlocked == 1 or skill.autotrain == 1) then
    auto = {
      label = skill.autotrain == 1 and "Auto on" or "Auto off",
      command = "ctrain auto " .. arg,
    }
  end
  return train, auto
end

local function button_cell(button)
  if not button then return "" end
  return C.bright_cyan .. "[" .. button.label .. "]" .. RESET
end

local function add_button_span(spans, button, col)
  if button then
    spans[#spans + 1] = { first = col, last = col + #button.label + 2, command = button.command }
  end
end

local function render_columns(lines, actions, width, names, skills)
  local show_ceiling = width >= 96
  local progress_width = math.min(30, width - (show_ceiling and 75 or 65))
  local spec = {
    { title = "Skill", w = "*" },
    { title = "Rank", w = 5 },
    { title = "XP to next rank", w = progress_width },
    { title = "Base cost", w = 9 },
    { title = "Training", w = 12 },
    { title = "Train", w = 7 },
    { title = "Autotrain", w = 10 },
  }
  if show_ceiling then table.insert(spec, 3, { title = "XP rank", w = 7 }) end
  local rows, buttons = {}, {}
  for _, name in ipairs(names) do
    local skill = skills[name]
    local status = training_status(skill)
    local train, auto = skill_buttons(name, skill)
    local dim = skill.unlocked == 1 and C.white or C.dim

    local cells = {
      dim .. pagelib.title(name) .. RESET,
      skill.unlocked == 1 and tostring(skill.rank or 0) or "-",
      progress_text(skill, progress_width),
      next_cost(skill),
      status[2] .. status[1] .. RESET,
      button_cell(train),
      button_cell(auto),
    }
    if show_ceiling then
      table.insert(cells, 3, skill.unlocked == 1 and skill.xp_rank and tostring(skill.xp_rank) or "-")
    end
    rows[#rows + 1] = cells
    buttons[#buttons + 1] = { train, auto }
  end

  local table_lines, widths = pagelib.columns(width, spec, rows)
  local train_col = 0
  for col = 1, #spec - 2 do train_col = train_col + widths[col] + 1 end
  local auto_col = train_col + widths[#spec - 1] + 1

  lines[#lines + 1] = table_lines[1]
  for i, entry in ipairs(buttons) do
    lines[#lines + 1] = table_lines[i + 1]
    local spans = {}
    add_button_span(spans, entry[1], train_col)
    add_button_span(spans, entry[2], auto_col)
    actions[#lines] = spans
  end
end

local function render_compact(lines, actions, width, names, skills)
  for _, name in ipairs(names) do
    local skill = skills[name]
    local status = training_status(skill)
    local rank = skill.unlocked == 1 and (" R" .. tostring(skill.rank or 0)) or ""
    lines[#lines + 1] = pagelib.trunc(pagelib.title(name) .. rank .. "  " .. status[2] .. status[1]
      .. RESET, width)
    if skill.unlocked == 1 and skill.can_train ~= -1 then
      local xp = progress_text(skill, math.min(24, width - 2))
      lines[#lines + 1] = pagelib.trunc("  " .. xp .. " XP  " .. next_cost(skill), width)
    end
    local train, auto = skill_buttons(name, skill)
    local buttons = {}
    if train then buttons[#buttons + 1] = train end
    if auto then buttons[#buttons + 1] = auto end
    if #buttons > 0 then pagelib.action_row(lines, actions, width, buttons) end
  end
end

function M.lines(width)
  width = math.min(width or 100, 106)
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
        local au, bu = skills[a].unlocked == 1, skills[b].unlocked == 1
        if au ~= bu then return au end
        return a < b
      end)
      local heading = realm .. " Skills"
      if ready > 0 then heading = heading .. "  |  " .. ready .. " ready" end
      local color = pagelib.REALM_COLOR[realm] or C.yellow
      lines[#lines + 1] = pagelib.trunc(color .. heading .. RESET
        .. " " .. C.dim .. string.rep("-", width) .. RESET, width)
      if width >= 82 then
        render_columns(lines, actions, width, names, skills)
      else
        render_compact(lines, actions, width, names, skills)
      end
      lines[#lines + 1] = ""
    end
  end
  return lines, actions
end

return M
