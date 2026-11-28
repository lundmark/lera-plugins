-- Refinery page: every refinery's full ten-stage chain, what each stage
-- refines into, how much of the throughput is allocated to it, and whether it
-- is reachable yet (Craft.Buildings' "refineries" rows).
--
-- The server sends one row PER STAGE now rather than only per allocated stage,
-- so this page can show the whole ladder including the stages you have not
-- unlocked. That matters because the locked stages are the interesting ones --
-- they are the high-tier materials the weapon and armour ladders climb into,
-- and the only way to see how far off they are is to see them listed.
--
-- Row fields (state.lua's parse_refinery_row):
--   building, tier (= stage index), material, percent,
--   bldg_tier, max_tier, min_rank
-- bldg_tier 0 means the refinery is not built. A stage is locked when
-- stage > max_tier; the server computes max_tier (building tier x 2, clamped
-- to the chain length) so client and server cannot disagree about the rule.
local pagelib = require("pagelib")
local state = require("state")

local C = pagelib.C
local M = {}
local REALM_ORDER = { chaos = 1, fantasy = 2, science = 3 }
local STEP = 5

local function stage_color(locked, pct)
  if locked then return C.dim end
  if pct > 0 then return C.bright_green end
  return C.white
end

local function building_realms(s)
  local realms = {}
  for realm, recipes in pairs(s.recipes_catalogue) do
    if REALM_ORDER[realm] then
      for _, recipe in ipairs(recipes) do
        if recipe.building then realms[recipe.building] = realm end
      end
    end
  end
  for _, plan in ipairs(s.build_plans) do
    local realm = plan.realm:lower()
    if REALM_ORDER[realm] then realms[plan.name] = realm end
  end
  return realms
end

local function allocation_buttons(realm, row, total, stage_one)
  local material = pagelib.command_arg(row.material)
  if not realm or not material then return nil end

  local command = "crefine allocate " .. realm .. " " .. material .. " "
  local pct = row.percent
  -- The server takes the difference from stage 1 if the total would exceed 100.
  local room = 100 - total + (row.tier > 1 and stage_one or 0)
  local trim = math.min(math.max(STEP, total - 100), pct)
  local add = math.min(STEP, room, 100 - pct)
  local buttons = {}
  if trim > 0 and room + trim >= 0 then
    buttons[#buttons + 1] = { label = "-" .. trim, command = command .. "-" .. trim,
      allow_repeat = true, hover = string.format("%s: %d%% to %d%%. Frees %d percentage points "
        .. "for other materials. Freed capacity stays unused until assigned.", row.material, pct, pct - trim, trim) }
  end
  if add > 0 then
    local transfer = math.max(0, total + add - 100)
    local source = transfer > 0 and ("Moves " .. transfer .. " percentage points from stage 1.")
      or ("Uses " .. add .. " percentage points of unassigned capacity.")
    if transfer > 0 and transfer < add then
      source = source .. " Uses " .. (add - transfer) .. " points of unassigned capacity."
    end
    buttons[#buttons + 1] = { label = "+" .. add, command = command .. "+" .. add,
      allow_repeat = true, hover = string.format("%s: %d%% to %d%%.\n%s", row.material, pct, pct + add, source) }
  end
  return buttons
end

local function stage_help(name, row, tier_locked, rank_locked, skill_id, blocked)
  if tier_locked then
    return string.format("Upgrade %s to tier %d to open %s.", name, math.ceil(row.tier / 2), row.material)
  end
  if rank_locked then
    return string.format("Train %s to rank %d before allocating output to %s.",
      pagelib.title(skill_id), row.min_rank, row.material)
  end
  if blocked then
    return "Waiting for refinery rank data before enabling adjustments."
  end
  return "Allocation is this material's share of one refinery's production time. "
    .. "Each refinery has a separate 100% budget. Higher stages can draw spare allocation from stage 1."
end

function M.lines(width)
  width = pagelib.page_width(width)
  local s = state.get()
  local lines, actions = {}, {}
  local function add(text) lines[#lines + 1] = text end

  if #s.refineries == 0 then
    add(pagelib.trunc(C.dim .. "No Craft.Buildings refinery data received yet."
      .. pagelib.RESET, width))
    return lines
  end

  -- Group stage rows by refinery, then order refineries by realm and name.
  local groups, order, realms = {}, {}, building_realms(s)
  for _, r in ipairs(s.refineries) do
    local k = r.building or "?"
    if not groups[k] then groups[k] = {}; order[#order + 1] = k end
    table.insert(groups[k], r)
  end
  table.sort(order, function(a, b)
    local ra = REALM_ORDER[realms[a]] or 4
    local rb = REALM_ORDER[realms[b]] or 4
    if ra ~= rb then return ra < rb end
    return a < b
  end)

  local last_realm
  for _, name in ipairs(order) do
    local realm = realms[name] or "other"
    if last_realm then add("") end
    if realm ~= last_realm then
      local label = pagelib.title(realm)
      add(pagelib.header(width, label, pagelib.REALM_COLOR[label]))
      last_realm = realm
    end
    local rows = groups[name]
    table.sort(rows, function(a, b) return (a.tier or 0) < (b.tier or 0) end)

    -- bldg_tier/max_tier are per-refinery, so any row carries them. Absent on
    -- the legacy four-field payload, in which case the lock state is unknown
    -- and every stage is shown as available rather than wrongly greyed out.
    local head = rows[1] or {}
    local bldg_tier = head.bldg_tier
    local max_tier = head.max_tier
    local legacy = (bldg_tier == nil)

    if not legacy and bldg_tier < 1 then
      add(pagelib.header(width, name))
      add(pagelib.trunc("  " .. C.dim .. "not built" .. pagelib.RESET, width))
      actions[#lines] = { hover = "Build " .. name .. " in the Buildings tab to allocate its output." }
    else
      local suffix = legacy and ""
        or string.format("  T%d  stages 1-%d", bldg_tier, max_tier or 0)
      add(pagelib.header(width, name .. suffix))
      local skill_id = s.refinery_skills[name]
      local skill = skill_id and s.skills[skill_id]
      local rank = skill and tonumber(skill.rank)

      -- Total allocated, so an under- or over-committed refinery is obvious
      -- without adding the column up by eye.
      local total, stage_one = 0, 0
      for _, r in ipairs(rows) do
        total = total + r.percent
        if r.tier == 1 then stage_one = r.percent end
      end
      local tcol = C.bright_green
      if total == 0 then tcol = C.dim
      elseif total > 100 then tcol = C.bright_red
      elseif total < 100 then tcol = C.yellow end
      add(pagelib.trunc("  " .. tcol .. "allocated " .. total .. "%" .. pagelib.RESET
        .. "  " .. pagelib.meter(total, 100, 33, tcol), width))
      if not legacy and skill_id ~= "" then
        local label = skill_id and pagelib.title(skill_id) or "Refining skill"
        local status = rank and ("R" .. rank) or "waiting for rank data"
        add(pagelib.trunc("  " .. C.dim .. label .. ": " .. status .. pagelib.RESET, width))
      end

      local trows, buttons = {}, {}
      for _, r in ipairs(rows) do
        local stage = r.tier or 0
        local tier_locked = (not legacy) and max_tier and stage > max_tier
        local rank_locked = rank and r.min_rank and rank < r.min_rank
        local locked = tier_locked or rank_locked
        local pct = r.percent or 0
        local color = stage_color(locked, pct)
        local know_rank = skill_id == "" or (rank and r.min_rank)
        local status = tier_locked and "locked" or rank_locked and ("Needs R" .. r.min_rank)
          or (not legacy and not know_rank and "Syncing")
          or (pct > 0 and "allocated" or "available")
        trows[#trows + 1] = {
          "T" .. stage,
          color .. pagelib.title(r.material or "") .. pagelib.RESET,
          r.min_rank and ("R" .. r.min_rank) or "",
          status,
          tier_locked and "-" or (pagelib.bar(14, pct, 100, color) .. " " .. pct .. "%"),
        }
        if not legacy and max_tier and stage >= 1 and not locked and know_rank then
          buttons[#trows] = allocation_buttons(realms[name], r, total, stage_one)
        end
        buttons[#trows] = buttons[#trows] or {}
        buttons[#trows].hover = stage_help(name, r, tier_locked, rank_locked, skill_id,
          not legacy and not know_rank)
      end

      pagelib.add_table(lines, width, {
        { title = "Stage",    w = 6 },
        { title = "Material", w = "*" },
        { title = "Rank",     w = 6 },
        { title = "Status",   w = 11 },
        { title = "Allocation", w = 20 },
        { title = "Adjust", w = 10 },
      }, trows, actions, buttons)
    end
  end

  add("")
  add(pagelib.trunc(C.dim
    .. "crefine allocate <realm> <material> <percent>  |  crefine reset <realm>"
    .. pagelib.RESET, width))

  return lines, actions
end

return M
