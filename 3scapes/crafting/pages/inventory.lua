-- Inventory page: live tokens, souls, and material stock (Craft.State) --
-- the cinv/csouls equivalent. State's mapping-keyed-by-dynamic-name fields
-- (material name, realm name, tier number) don't survive GMCP delivery
-- intact, so the server sends arrays of flat records instead -- every field
-- here reads from those arrays, not from a lookup-by-name mapping.
local pagelib = require("pagelib")
local state = require("state")

local C = pagelib.C
local M = {}

local REALMS = { "Chaos", "Fantasy", "Science" }

function M.lines(width)
  width = pagelib.page_width(width)
  local s = state.get()
  local lines, actions = {}, {}
  local function add(text) lines[#lines + 1] = text end

  if #s.ready > 0 then
    pagelib.action_row(lines, actions, width, {
      { label = "Collect all", command = "ccollect" },
    }, #s.ready .. " finished")
  end

  add(pagelib.header(width, "Storage and Souls"))
  local capacity = {
    { "Material storage", pagelib.meter(s.stock_used, s.stock_cap, 32) },
    { "All souls", pagelib.meter(s.souls, s.soul_cap, 32) },
  }
  -- Same tier names + T#/cap rows as csouls, not a bare "T1 50" tally.
  local any_tier = false
  for _, t in ipairs(s.soul_tiers) do
    if (t.cap or 0) > 0 or (t.count or 0) > 0 then any_tier = true end
  end
  if any_tier then
    local sorted_tiers = {}
    for _, t in ipairs(s.soul_tiers) do sorted_tiers[#sorted_tiers + 1] = t end
    table.sort(sorted_tiers, function(a, b) return (a.tier or 0) < (b.tier or 0) end)
    for _, t in ipairs(sorted_tiers) do
      if (t.cap or 0) > 0 or (t.count or 0) > 0 then
        capacity[#capacity + 1] = { "T" .. tostring(t.tier) .. " " .. (t.name or "?"),
          pagelib.meter(t.count, t.cap, 32) }
      end
    end
  end
  pagelib.add_table(lines, width, {
    { title = "Resource", w = "*" }, { title = "Used / Capacity", w = 32 },
  }, capacity)

  add("")
  add(pagelib.header(width, "Currency Tokens"))
  -- The server now always sends all 15 (3 realms x 5 tiers), zero or not, so
  -- every tier is listed here even at 0 -- no more guessing whether an
  -- absent realm means "you have none" or "dropped somewhere".
  do
    for _, realm in ipairs(REALMS) do
      local rc = pagelib.REALM_COLOR[realm] or C.white
      local rows_in = {}
      for _, t in ipairs(s.tokens) do
        if t.realm == realm then rows_in[#rows_in + 1] = t end
      end
      table.sort(rows_in, function(a, b) return (a.level or 0) < (b.level or 0) end)
      local rows = {}
      for _, t in ipairs(rows_in) do
        rows[#rows + 1] = { (t.name or ("T" .. tostring(t.level))) .. " token",
          pagelib.fmt_num(t.qty or 0) }
      end
      if #rows > 0 then
        add(pagelib.header(width, realm, rc))
        pagelib.add_table(lines, width, {
          { title = "Token", w = "*" }, { title = "In stock", w = 12 },
        }, rows)
        add("")
      end
    end
  end

  add(pagelib.header(width, "Materials"))
  if #s.materials == 0 then
    add(pagelib.trunc(C.dim .. "  none in stock" .. pagelib.RESET, width))
  else
    -- Grouped "Chaos Realm" / "Fantasy Realm" / "Science Realm", same as
    -- cinv -- plus a trailing Cross-Realm bucket for the handful of
    -- materials (Prime Essence and the like) that aren't realm-bound.
    local groups, order = {}, {}
    for _, m in ipairs(s.materials) do
      local k = m.realm or "Cross-Realm"
      if not groups[k] then groups[k] = {}; order[#order + 1] = k end
      table.insert(groups[k], m)
    end
    local rank = { Chaos = 1, Fantasy = 2, Science = 3, ["Cross-Realm"] = 4 }
    table.sort(order, function(a, b) return (rank[a] or 9) < (rank[b] or 9) end)

    for _, realm in ipairs(order) do
      local rows_in = groups[realm]
      table.sort(rows_in, function(a, b) return (a.name or "") < (b.name or "") end)
      local rc = pagelib.REALM_COLOR[realm] or C.bright_cyan
      add(pagelib.header(width, realm, rc))
      local rows = {}
      for _, m in ipairs(rows_in) do
        rows[#rows + 1] = { pagelib.title(m.name or "?"), pagelib.fmt_num(m.qty),
          m.category or "", (m.quality and m.quality ~= "") and m.quality or "-" }
      end
      pagelib.add_table(lines, width, {
        { title = "Material", w = "*" }, { title = "In stock", w = 9 },
        { title = "Type", w = 12 }, { title = "Quality spread", w = math.floor(width / 2) },
      }, rows)
    end
  end

  if not state.has_data() then
    add("")
    add(pagelib.trunc(C.dim .. "No Craft.* data received yet this connection."
      .. pagelib.RESET, width))
  end

  return lines, actions
end

return M
