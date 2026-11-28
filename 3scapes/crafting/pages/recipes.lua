-- Known recipes and the full production catalogue, grouped by realm and station.
local pagelib = require("pagelib")
local production = require("production")
local recipe_inputs = require("recipe_inputs")
local state = require("state")

local C = pagelib.C
local M = {}
local REALMS = { "Chaos", "Fantasy", "Science" }
local query, craftable_only = "", false

function M.search(text)
  query = text:gsub("[%c]", ""):match("^%s*(.-)%s*$"):lower()
end

local function matches(recipe)
  return query == "" or (recipe.name or ""):lower():find(query, 1, true)
    or (recipe.materials or ""):lower():find(query, 1, true)
end

local function can_make(recipe, tiers, owned, skills, stock)
  local required = tiers[recipe.building] and tiers[recipe.building][recipe.name]
  return production.is_recipe(recipe)
    and not production.eligibility(recipe, owned[recipe.building], required, skills[recipe.skill])
    and recipe_inputs.has_stock(recipe_inputs.parse(recipe.materials), stock)
end

local function duration(seconds)
  if not seconds or seconds <= 0 then return "-" end
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor(seconds % 3600 / 60)
  if hours > 0 then return string.format("%dh %dm", hours, minutes) end
  if minutes > 0 then return string.format("%dm %ds", minutes, seconds % 60) end
  return seconds .. "s"
end

local function building_groups(records)
  local groups, names = {}, {}
  for _, record in ipairs(records) do
    local name = record.building
    if not name or name == "" or name == "?" then name = "Other" end
    if not groups[name] then
      names[#names + 1] = name
      groups[name] = {}
    end
    local group = groups[name]
    group[#group + 1] = record
  end
  table.sort(names)
  return names, groups
end

local function render_list(lines, width, records, actions, recipe_actions)
  local names, groups = building_groups(records)
  local spec = recipe_actions and {
    { title = "Recipe", w = "*" }, { title = "Rank", w = 5 },
    { title = "Base time", w = 10 }, { title = "Ingredients", w = 23 },
    { title = "Action / Status", w = 27 },
  } or {
    { title = "Recipe", w = "*" }, { title = "Tier", w = 9 }, { title = "Rank", w = 9 },
  }

  for _, name in ipairs(names) do
    local group = groups[name]
    table.sort(group, function(a, b) return (a.name or a.id or "") < (b.name or b.id or "") end)
    lines[#lines + 1] = pagelib.header(width, name, C.bright_cyan)
    local rows, buttons = {}, {}
    for _, r in ipairs(group) do
      local recipe_name = r.name or r.id or "?"
      if recipe_actions then
        local materials = r.materials and r.materials ~= "" and r.materials or "-"
        local row_buttons, status = recipe_actions(r)
        if row_buttons and row_buttons.primary then
          recipe_name = C.bright_cyan .. recipe_name .. pagelib.RESET
        end
        rows[#rows + 1] = { recipe_name, r.rank or "-", duration(r.time), materials, status }
        buttons[#rows] = row_buttons
      else
        rows[#rows + 1] = { recipe_name, r.tier or "-", r.rank or "-" }
      end
    end
    pagelib.add_table(lines, width, spec, rows, actions, recipe_actions and buttons)
    lines[#lines + 1] = ""
  end
end

function M.lines(width)
  width = pagelib.page_width(width)
  local s = state.get()
  local lines, actions = {}, {}
  if #s.ready > 0 then
    pagelib.action_row(lines, actions, width, {
      { label = "Collect all", command = "ccollect" },
    }, #s.ready .. " finished")
  end
  pagelib.action_row(lines, actions, width, {
    { label = "Production", page = "jobs" }, { label = "Inventory", page = "inventory" },
  })
  local filters = { {
    label = craftable_only and "All recipes" or "Can craft now",
    activate = function() craftable_only = not craftable_only end,
  } }
  if query ~= "" then
    filters[#filters + 1] = { label = "Clear search", activate = function() M.search("") end }
  end
  pagelib.action_row(lines, actions, width, filters)
  if query ~= "" then
    lines[#lines + 1] = pagelib.trunc("Search: " .. query, width)
  else
    lines[#lines + 1] = pagelib.trunc(C.dim .. "/craft recipes <name or ingredient>" .. pagelib.RESET, width)
  end
  if craftable_only then
    lines[#lines + 1] = pagelib.trunc("Known production recipes with a qualified station and enough stock for one.", width)
  end
  lines[#lines + 1] = pagelib.trunc(C.dim .. "Click a recipe to queue one. Right-click for more."
    .. pagelib.RESET, width)
  lines[#lines + 1] = ""

  local owned, queues, visible = {}, {}, 0
  for _, building in ipairs(s.buildings) do owned[building.name] = building.tier end
  for _, queue in ipairs(s.queues) do if queue.building then queues[queue.building] = queue end end
  local stock = recipe_inputs.stock(s.materials)
  for _, realm in ipairs(REALMS) do
    local key = realm:lower()
    local known, tiers = {}, {}
    for _, entry in ipairs(s.recipes_catalogue[key] or {}) do
      if entry.building and entry.name then
        tiers[entry.building] = tiers[entry.building] or {}
        tiers[entry.building][entry.name] = entry.tier
      end
    end
    for _, recipe in ipairs(s.recipes_known[key] or {}) do
      if matches(recipe) and (not craftable_only or can_make(recipe, tiers, owned, s.skills, stock)) then
        known[#known + 1] = recipe
      end
    end
    if #known > 0 then
      visible = visible + #known
      lines[#lines + 1] = pagelib.header(width, realm .. " Known Recipes (" .. #known .. ")",
        pagelib.REALM_COLOR[realm])
      render_list(lines, width, known, actions, function(recipe)
        local building = recipe.building
        local required = tiers[building] and tiers[building][recipe.name]
        return production.actions(s, recipe, queues[building], owned[building], required, stock)
      end)
    end
  end

  if not craftable_only then
    local showed_catalogue = false
    for _, realm in ipairs(REALMS) do
      local catalogue = {}
      for _, recipe in ipairs(s.recipes_catalogue[realm:lower()] or {}) do
        if matches(recipe) then catalogue[#catalogue + 1] = recipe end
      end
      if #catalogue > 0 then
        if not showed_catalogue then
          lines[#lines + 1] = pagelib.header(width, "Production Catalogue")
          showed_catalogue = true
        end
        visible = visible + #catalogue
        lines[#lines + 1] = pagelib.header(width, realm, pagelib.REALM_COLOR[realm])
        render_list(lines, width, catalogue)
      end
    end
  end
  if visible == 0 then
    lines[#lines + 1] = query ~= "" and "No matching recipes."
      or (craftable_only and "No production recipes can start with current stock." or "Waiting for recipes.")
  end
  return lines, actions
end

return M
