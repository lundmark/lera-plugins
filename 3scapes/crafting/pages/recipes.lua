-- Recipes page: known recipes per realm (with what they need and how long
-- they take), plus the production catalogue -- what each building can
-- eventually make, both grouped by the building that teaches/produces them
-- (Craft.Recipes).
local pagelib = require("pagelib")
local state = require("state")

local C = pagelib.C
local M = {}

local REALM_KEYS = { "chaos", "fantasy", "science" }
local REALM_LABELS = { chaos = "Chaos", fantasy = "Fantasy", science = "Science" }

local function fmt_time(secs)
  secs = secs or 0
  if secs <= 0 then return "-" end
  local h = math.floor(secs / 3600)
  local m = math.floor((secs % 3600) / 60)
  local s = secs % 60
  if h > 0 then return string.format("%dh%02dm", h, m) end
  if m > 0 then return string.format("%dm%02ds", m, s) end
  return string.format("%ds", s)
end

-- Groups `rows` by `rows[i][key_field]`, sorted by group name, each group's
-- own rows sorted by `sort_field`. Returns an ordered array of
-- {name=group, rows={...}}.
local function group_by(rows, key_field, sort_field)
  local groups, order = {}, {}
  for _, r in ipairs(rows) do
    local k = r[key_field] or "?"
    if not groups[k] then groups[k] = {}; order[#order + 1] = k end
    table.insert(groups[k], r)
  end
  table.sort(order)
  local out = {}
  for _, k in ipairs(order) do
    table.sort(groups[k], function(a, b) return (a[sort_field] or "") < (b[sort_field] or "") end)
    out[#out + 1] = { name = k, rows = groups[k] }
  end
  return out
end

-- A building/refinery sub-header: colored name, dash-filled to width, same
-- shape as pagelib.header() but a distinct color and one indent level -- so
-- it reads unambiguously as a section break and never as a data row sharing
-- the zebra rhythm of the rows underneath it.
local function subheader(width, text, color)
  local raw = color .. text .. " " .. string.rep("-", width)
  return pagelib.trunc(raw, width)
end

function M.lines(width)
  width = width or 80
  local s = state.get()
  local lines = {}
  local function add(text) lines[#lines + 1] = text end

  for _, rk in ipairs(REALM_KEYS) do
    local known = s.recipes_known[rk] or {}
    add(pagelib.header(width, REALM_LABELS[rk] .. " Recipes (" .. #known .. " known)"))
    if #known == 0 then
      add(pagelib.trunc(C.dim .. "  none learned yet" .. pagelib.RESET, width))
    else
      -- Grouped under the refinery/building that teaches each recipe's
      -- skill (the server resolves skill -> building name): one column
      -- title row for the whole realm, then a building sub-header per
      -- group with just that building's recipes underneath it.
      local groups = group_by(known, "building", "name")
      local col_cache = {}
      for _, g in ipairs(groups) do
        local rows = {}
        for _, r in ipairs(g.rows) do
          rows[#rows + 1] = {
            pagelib.title(r.name or r.id or "?"),
            tostring(r.rank or 0),
            fmt_time(r.time),
            (r.materials and r.materials ~= "") and r.materials or "-",
          }
        end
        col_cache[#col_cache + 1] = { name = g.name, cols = pagelib.columns(width - 2, {
          { title = "Recipe", w = 24 }, { title = "Rank", w = 5 },
          { title = "Time", w = 8 }, { title = "Uses", w = "*" },
        }, rows) }
      end
      add("  " .. col_cache[1].cols[1])
      for _, g in ipairs(col_cache) do
        local bname = (g.name ~= "" and g.name ~= "?") and g.name or "Other"
        add("  " .. subheader(width - 2, bname, C.bright_cyan))
        local i
        for i = 2, #g.cols do
          add("  " .. pagelib.zebra(i - 2) .. g.cols[i] .. pagelib.RESET)
        end
      end
    end
    add("")
  end

  add(pagelib.header(width, "Production Catalogue (by building)"))
  local all_rows = {}
  for _, rk in ipairs(REALM_KEYS) do
    for _, c in ipairs(s.recipes_catalogue[rk] or {}) do
      all_rows[#all_rows + 1] = c
    end
  end
  if #all_rows == 0 then
    add(pagelib.trunc(C.dim .. "  no catalogue data received yet" .. pagelib.RESET, width))
    return lines
  end

  local groups = group_by(all_rows, "building", "name")
  local col_shown = false
  for _, g in ipairs(groups) do
    add(subheader(width - 2, g.name, C.bright_cyan))
    local rows = {}
    for _, c in ipairs(g.rows) do
      rows[#rows + 1] = { pagelib.title(c.name or ""), "T" .. tostring(c.tier or 0),
        tostring(c.rank or 0) }
    end
    local cols = pagelib.columns(width - 2, {
      { title = "Makes", w = "*" }, { title = "Tier", w = 6 }, { title = "Rank", w = 6 },
    }, rows)
    if not col_shown then
      add("  " .. cols[1])
      col_shown = true
    end
    local i
    for i = 2, #cols do
      add("  " .. pagelib.zebra(i - 2) .. cols[i] .. pagelib.RESET)
    end
    add("")
  end

  return lines
end

return M
