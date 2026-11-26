-- Known recipes and the full production catalogue, grouped by realm and station.
local pagelib = require("pagelib")
local state = require("state")

local C = pagelib.C
local M = {}
local REALMS = { "Chaos", "Fantasy", "Science" }

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

local function render_list(lines, width, records, known)
  local names, groups = building_groups(records)
  local spec = known and {
    { title = "Recipe", w = "*" }, { title = "Rank", w = 6 },
    { title = "Base time", w = 11 }, { title = "Ingredients", w = math.floor(width / 2) },
  } or {
    { title = "Recipe", w = "*" }, { title = "Tier", w = 9 }, { title = "Rank", w = 9 },
  }

  for _, name in ipairs(names) do
    local group = groups[name]
    table.sort(group, function(a, b) return (a.name or a.id or "") < (b.name or b.id or "") end)
    lines[#lines + 1] = pagelib.header(width, name, C.bright_cyan)
    local rows = {}
    for _, r in ipairs(group) do
      local recipe_name = r.name or r.id or "?"
      if known then
        local materials = r.materials and r.materials ~= "" and r.materials or "-"
        rows[#rows + 1] = { recipe_name, r.rank or "-", duration(r.time), materials }
      else
        rows[#rows + 1] = { recipe_name, r.tier or "-", r.rank or "-" }
      end
    end
    pagelib.add_table(lines, width, spec, rows)
    lines[#lines + 1] = ""
  end
end

function M.lines(width)
  width = pagelib.page_width(width)
  local s = state.get()
  local lines = {}
  for _, realm in ipairs(REALMS) do
    local key = realm:lower()
    local known = s.recipes_known[key] or {}
    lines[#lines + 1] = pagelib.header(width, realm .. " Known Recipes (" .. #known .. ")",
      pagelib.REALM_COLOR[realm])
    if #known == 0 then
      lines[#lines + 1] = "No learned recipes."
      lines[#lines + 1] = ""
    else
      render_list(lines, width, known, true)
    end
  end

  lines[#lines + 1] = pagelib.header(width, "Production Catalogue")
  local count = 0
  for _, realm in ipairs(REALMS) do
    local catalogue = s.recipes_catalogue[realm:lower()] or {}
    if #catalogue > 0 then
      count = count + #catalogue
      lines[#lines + 1] = pagelib.header(width, realm, pagelib.REALM_COLOR[realm])
      render_list(lines, width, catalogue, false)
    end
  end
  if count == 0 then lines[#lines + 1] = "Waiting for catalogue data." end
  return lines
end

return M
