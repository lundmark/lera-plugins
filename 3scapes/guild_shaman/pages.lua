-- Page builders for guild_shaman.
--
-- Pure: each builder takes a width and returns an array of ANSI strings. No
-- ui.* calls, no state mutation, no mud.send -- the same page-purity rule
-- guild_viking's pages/*.lua are held to, so a page can be rendered from
-- anywhere (pane, /sham command, stats_window) without side effects.
local P = require("pagelib")
local S = require("state").S

local C = P.C
local M = {}

-- Category ids come from the server's SKILLCAT_* constants
-- (players/shaman/include/skills.h). The server sends the numeric id only --
-- naming them is the client's job, exactly as the Latin power ids are, which
-- keeps the GMCP frame inside PROTOCOL_FRAME_MAX.
local CAT_NAMES = {
  [0] = "De Bello Spirituali",
  [1] = "Comes Spiritualis",
  [2] = "Magia Spiritualis",
  [3] = "De Natura",
  [4] = "De Societate",
  [5] = "De Praesidiis",
}

-- Power kinds, matching gmcp.h's "k" tag.
local function fmt_age(secs)
  secs = secs or 0
  if secs <= 0 then return "-" end
  local d = math.floor(secs / 86400)
  if d > 0 then return d .. "d" end
  local h = math.floor(secs / 3600)
  if h > 0 then return h .. "h" end
  return math.max(1, math.floor(secs / 60)) .. "m"
end

-- Latin skill ids are the server's own keys ("vitare", "custodio", ...).
-- Title-case them for display rather than shipping a lookup table that would
-- have to be kept in step with include/skills.h by hand.
local function pretty(id)
  id = tostring(id or ""):gsub("_", " ")
  return (id:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end

-- ---------------------------------------------------------------------------
-- Status
-- ---------------------------------------------------------------------------
local STATUS_COLUMNS = {
  { key = "cat", title = "Category", width = 22 },
  { key = "gxp", title = "GXP", width = 9 },
  { key = "held", title = "Known", width = 7 },
  { key = "maxed", title = "Maxed", width = 7 },
  { key = "levels", title = "Levels", width = 9 },
  { key = "progress", title = "Progress" },
}

local function completion(cat)
  if cat.level_cap > 0 then return cat.levels / cat.level_cap end
  return cat.skills > 0 and cat.maxed / cat.skills or 0
end

function M.status(width, sort_key, descending)
  width = width or 60
  local L, tips = {}, {}
  local sort_header

  L[#L + 1] = P.header(width, "Shaman")
  local who = S.title ~= "" and S.title or S.rank
  L[#L + 1] = P.kv("Rank", (who ~= "" and who) or "-", C.bright_cyan) ..
              "  " .. P.kv("Path", (S.subguild ~= "" and S.subguild) or "-", C.cyan)
  L[#L + 1] = P.kv("Guild level", S.guild_level, C.white) ..
              "  " .. P.kv("Spirits", S.spirits_learned, C.white) ..
              "  " .. P.kv("Age", fmt_age(S.guild_age), C.dim)
  L[#L + 1] = P.kv("In combat", fmt_age(S.combat_age),
                    S.combat_age > 0 and C.bright_red or C.dim)

  L[#L + 1] = ""
  L[#L + 1] = P.header(width, "Vis")
  local barw = math.max(8, math.min(20, width - 26))
  L[#L + 1] = string.format("%-10s %s %d/%d",
    S.gp1_name, P.bar(barw, S.gp1, S.gp1_max, P.pct_color(S.gp1, S.gp1_max)),
    S.gp1, S.gp1_max)
  L[#L + 1] = string.format("%-10s %s %d/%d",
    S.gp2_name, P.bar(barw, S.gp2, S.gp2_max, P.pct_color(S.gp2, S.gp2_max)),
    S.gp2, S.gp2_max)

  L[#L + 1] = ""
  L[#L + 1] = P.header(width, "Combat resources")
  -- claw_depth counts up to the finisher; fervor is the multiplier pool the
  -- follow-ups spend. Both are shown raw because the server owns their caps.
  L[#L + 1] = P.kv("Claw depth", S.claw_depth, C.yellow) ..
              "  " .. P.kv("Fervor", S.fervor, C.magenta)
  L[#L + 1] = P.kv("Terra", S.terra, C.green) ..
              "  " .. P.kv("Caelum", S.caelum, C.bright_cyan)

  if #S.skillcats > 0 then
    L[#L + 1] = ""
    L[#L + 1] = P.header(width, "Spirit experience")
    local categories = {}
    sort_key = sort_key or "cat"
    for _, category in ipairs(S.skillcats) do categories[#categories + 1] = category end
    table.sort(categories, function(a, b)
      local av = sort_key == "progress" and completion(a) or a[sort_key]
      local bv = sort_key == "progress" and completion(b) or b[sort_key]
      if av == bv then return a.cat < b.cat end
      if descending then return av > bv end
      return av < bv
    end)
    local compact = width < 66
    local bar_width = compact and 8 or math.min(14, width - 62)
    local columns = "%-22s %9s %7s %7s %9s  %s"
    if not compact then
      local labels, spans, start = {}, {}, 0
      for i, column in ipairs(STATUS_COLUMNS) do
        local label = column.title
        if sort_key == column.key then label = label .. (descending and " v" or " ^") end
        labels[i] = label
        local size = column.width or width - start
        spans[i] = { key = column.key, first = start, last = start + size }
        start = start + size + (column.key == "levels" and 2 or 1)
      end
      L[#L + 1] = C.cyan .. string.format(columns, unpack(labels)) .. P.RESET
      sort_header = { line = #L, spans = spans }
    end
    for _, c in ipairs(categories) do
      local name = CAT_NAMES[c.cat] or ("Category " .. c.cat)
      local cap = c.level_cap
      local progress = cap > 0 and P.bar(bar_width, c.levels, cap, P.pct_color(c.levels, cap))
        or P.bar(bar_width, c.maxed, c.skills, P.pct_color(c.maxed, c.skills))
      local levels = cap > 0 and string.format("%d/%d", c.levels, cap) or tostring(c.levels)
      local detail = name .. " | " .. c.gxp .. " GXP. Last round +" .. c.last .. " GXP."
      if compact then
        L[#L + 1] = name .. "  " .. progress
        tips[#L] = detail
        L[#L + 1] = string.format("  %d GXP  %d/%d maxed  %s levels",
          c.gxp, c.maxed, c.skills, levels)
      else
        L[#L + 1] = string.format(columns, name, c.gxp,
          c.held .. "/" .. c.skills, c.maxed .. "/" .. c.skills, levels, progress)
      end
      tips[#L] = detail
    end
  end

  return L, nil, tips, sort_header
end

-- ---------------------------------------------------------------------------
-- Powers -- what is toggled on right now
-- ---------------------------------------------------------------------------
-- Sections in the same order, and under the same Latin headings, that
-- `shmaintain` prints in-game (cmd/shmaintain.c). Matching it matters: a
-- player reads one list or the other and has to recognise the same thing in
-- both. Pet openers are k 3 -- a subset of the combat powers the server tags
-- k 0, split out server-side precisely so this grouping is reproducible here
-- (see send_gmcp_powers()'s header).
local POWER_SECTIONS = {
  { kind = 1, title = "Incantationes (Spells)" },
  { kind = 0, title = "Potestates Belli (Combat Powers)" },
  { kind = 3, title = "Potestates Bestiarum (Pet Skillsets)" },
  { kind = 2, title = "Potestates Societatis (De Societate)" },
}

-- Returns `lines, targets` where targets maps a 1-based line index to
-- { id, label } for the lines that are a power row. The popup hit-tests
-- against it to turn a click into `shmaintain <label>`; every other caller
-- ignores the second value, so this stays a pure builder -- no module state,
-- which is what lets the same function feed the pane, the popup and
-- `/sham powers print` without them interfering.
function M.powers(width)
  width = width or 60
  local L, targets, tips = {}, {}, {}

  L[#L + 1] = P.header(width, "Maintained powers")
  if #S.powers == 0 then
    L[#L + 1] = C.dim .. "  (no powers available yet)" .. P.RESET
    return L, targets, tips
  end

  -- Bucket once, preserving arrival order within a kind; the server emits
  -- COMBAT_POWER_IDS in a fixed order, so rows do not shuffle between frames.
  local by_kind, depellere = {}, false
  for _, p in ipairs(S.powers) do
    local k = p.kind or 0
    by_kind[k] = by_kind[k] or {}
    table.insert(by_kind[k], p)
    if p.id == "depellere" then depellere = p.on end
  end

  local function row(p)
    -- Underscores to spaces IS the command argument: shmaintain lower-cases
    -- and resolves its target through resolve_skill()/query_spell(), both of
    -- which take the spaced display form ("scutum spiritale").
    local label = tostring(p.id or ""):gsub("_", " ")
    local mark = p.on and (C.bright_green .. "On " .. P.RESET)
                       or (C.dim .. "Off" .. P.RESET)
    local keep = p.maintained and (C.cyan .. "On " .. P.RESET)
                              or (C.dim .. "Off" .. P.RESET)
    local blocked = p.needs_bond and "Needs bond"
    if p.id == "responsum_ictu" and not p.on and not p.maintained and not depellere then
      blocked = "Needs Depellere"
    end
    local disable = p.maintained or (p.kind ~= 1 and p.on)
    local action = blocked and (C.yellow .. blocked .. P.RESET)
      or (C.cyan .. (disable and "[Disable]" or "[Enable]") .. P.RESET)
    L[#L + 1] = string.format("  %s %s     %s           %s",
      P.pad(pretty(p.id), 27), mark, keep, action)
    if p.effect and p.effect ~= "" then
      tips[#L] = pretty(p.id) .. " | " .. p.effect
    end
    if not blocked then targets[#L] = { id = p.id, label = label } end
  end

  L[#L + 1] = C.dim .. "  " .. P.pad("Power", 27)
    .. " Running Auto-maintain Action" .. P.RESET

  local any = false
  for _, sec in ipairs(POWER_SECTIONS) do
    local list = by_kind[sec.kind]
    if list and #list > 0 then
      if any then L[#L + 1] = "" end
      any = true
      L[#L + 1] = C.bright_cyan .. sec.title .. P.RESET
      -- Running first inside the section: the panel is read to confirm what
      -- is up, and the section header already carries the categorisation.
      for _, p in ipairs(list) do if p.on then row(p) end end
      for _, p in ipairs(list) do if not p.on then row(p) end end
    end
  end

  L[#L + 1] = ""
  L[#L + 1] = C.dim .. "  Auto-maintain recasts when the effect drops and you can use it." .. P.RESET
  if S.party == 1 then
    L[#L + 1] = C.bright_cyan .. "  De Societate party is active" .. P.RESET
  end
  return L, targets, tips
end

function M.skills(width)
  width = width or 72
  if not S.skill_details then return { C.dim .. "Waiting for skill details." .. P.RESET } end

  local pools = {}
  for _, cat in ipairs(S.skillcats) do pools[cat.cat] = cat.gxp end
  local lines, tips, category = {}, {}, nil
  if not next(S.skill_help) then
    lines[1] = C.dim .. "Waiting for skill descriptions." .. P.RESET
  end
  for _, skill in ipairs(S.skill_details) do
    local pool = pools[skill.cat]
    if category ~= skill.cat then
      category = skill.cat
      if #lines > 0 then lines[#lines + 1] = "" end
      local title = CAT_NAMES[category] or ("Category " .. category)
      if pool then title = title .. "  (" .. pool .. " GXP)" end
      lines[#lines + 1] = P.header(width, title)
      lines[#lines + 1] = C.dim .. "  " .. P.pad("Skill", 28)
        .. P.pad("Level", 9) .. P.pad("Next GXP", 11) .. "Training" .. P.RESET
    end

    local maxed = skill.level >= skill.cap
    local status, color
    if maxed then
      status, color = "Maxed", C.dim
    elseif not skill.eligible then
      status, color = "Needs requirements", C.yellow
    elseif category == 5 then
      status, color = "Automatic", C.cyan
    elseif pool == nil or pool < skill.cost then
      status, color = "Needs GXP", C.yellow
    elseif not S.can_train_here then
      status, color = "At Memoria Maiorum", C.yellow
    else
      status, color = "Ready", C.bright_green
    end
    lines[#lines + 1] = "  " .. P.pad(skill.name, 28)
      .. P.pad(skill.level .. "/" .. skill.cap, 9)
      .. P.pad(maxed and "-" or tostring(skill.cost), 11) .. color .. status .. P.RESET
    local key = skill.cat .. "|" .. skill.name
    local tip
    for _, group in pairs(S.skill_help) do
      if group[key] then
        tip = skill.name .. " | " .. group[key]
        break
      end
    end
    tips[#lines] = tip
    for _, requirement in ipairs(P.wrap(skill.requirements, math.max(1, width - 4))) do
      lines[#lines + 1] = C.dim .. "    " .. requirement .. P.RESET
      tips[#lines] = tip
    end
  end
  if #lines == 0 then lines[1] = "No skills available." end
  return lines, nil, tips
end

function M.companions(width)
  width = width or 72
  if not S.companions then return { C.dim .. "Waiting for companion details." .. P.RESET } end

  local bonded = 0
  for _, spirit in ipairs(S.companions) do
    if spirit.bonded then bonded = bonded + 1 end
  end
  local lines = { P.header(width, string.format("Manifestations bonded %d/%d", bonded, S.bond_cap)) }
  local tips = {}
  for _, group in ipairs({ "earth", "sky" }) do
    lines[#lines + 1] = C.bright_cyan .. pretty(group) .. P.RESET
    local start = #lines
    for _, spirit in ipairs(S.companions) do
      if spirit.category == group then
        lines[#lines + 1] = "  " .. P.pad(spirit.name, 36)
          .. (spirit.bonded and (C.bright_green .. "Bonded") or (C.dim .. "Learned")) .. P.RESET
        tips[#lines] = spirit.name .. " | " .. pretty(group) .. " slot. "
          .. (spirit.bonded and "The bond enables this spirit's pet powers."
            or "Bond this spirit in its room to use its pet powers. One bond per slot.")
      end
    end
    if #lines == start then lines[#lines + 1] = C.dim .. "  None learned" .. P.RESET end
  end
  if bonded < S.bond_cap then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Use 'bond manifestation' in the manifestation's room."
  end
  return lines, nil, tips
end

-- ---------------------------------------------------------------------------
-- Discord -- local strain, realm totals, and damaged areas
-- ---------------------------------------------------------------------------
local LEYLINE_CAP = 100000
local LEYLINE_REALMS = { "Chaos", "Fantasy", "Science" }
local LEYLINE_COLORS = { C.bright_green, C.green, C.yellow, C.bright_red, C.red }

local function discord_meter(value, width)
  local filled = math.min(width, math.floor(math.max(0, value) * width / LEYLINE_CAP))
  if value > 0 then filled = math.max(1, filled) end
  local bar = {}
  for i = 1, filled do
    local color = LEYLINE_COLORS[1 + math.floor((i - 1) * #LEYLINE_COLORS / width)]
    bar[i] = color .. "|" .. P.RESET
  end
  return "[" .. table.concat(bar) .. C.dim .. string.rep("-", width - filled) .. P.RESET .. "]"
end

function M.discord(width)
  width = width or 60
  if not S.ley_ready then return { C.dim .. "Waiting for leyline data." .. P.RESET } end
  local lines, tips = {}, {}
  local bar_width = math.max(6, math.min(24, width - 45))
  local label_width = width - bar_width - 12

  local function row(label, value, detail)
    local meter = discord_meter(value, bar_width) .. string.format(" %7d", value)
    if label_width < 20 or #label > label_width then
      lines[#lines + 1] = label
      tips[#lines] = detail
      lines[#lines + 1] = "  " .. meter
    else
      lines[#lines + 1] = P.pad(label, label_width) .. " " .. meter
    end
    tips[#lines] = detail
  end

  lines[#lines + 1] = P.header(width, "Current area")
  local here = S.ley_here_label ~= "" and S.ley_here_label or "Unknown area"
  local emergency = S.ley_here_discord >= 25000 and " Use shcast urgens on site."
    or " Emergency cleansing opens at 25,000."
  row(here, S.ley_here_discord,
    here .. " | " .. S.ley_here_discord .. " of 100,000 discord." .. emergency)

  lines[#lines + 1] = ""
  lines[#lines + 1] = P.header(width, "Realms")
  local realm_totals = {}
  for _, r in ipairs(S.ley_realms) do realm_totals[pretty(r.realm:lower())] = r.discord end
  local function realm_row(realm, total)
    row(realm, total, realm .. " | " .. total .. " total discord across its areas. A full bar is 100,000.")
  end
  for _, realm in ipairs(LEYLINE_REALMS) do
    realm_row(realm, realm_totals[realm] or 0)
    realm_totals[realm] = nil
  end
  local other_realms = {}
  for realm in pairs(realm_totals) do other_realms[#other_realms + 1] = realm end
  table.sort(other_realms)
  for _, realm in ipairs(other_realms) do realm_row(realm, realm_totals[realm]) end

  lines[#lines + 1] = ""
  lines[#lines + 1] = P.header(width, "Disturbed areas")
  if #S.ley_regions == 0 then
    lines[#lines + 1] = C.dim .. "The ley lines are calm." .. P.RESET
  end
  for _, r in ipairs(S.ley_regions) do
    local realm = r.realm ~= "" and (" (" .. pretty(r.realm:lower()) .. ")") or ""
    local label = r.region .. realm
    row(label, r.discord, label .. " | " .. r.discord
      .. " of 100,000 discord. From the guild nexus, use shcast sanare " .. r.region .. ".")
  end
  return lines, nil, tips
end

M.PAGES = {
  status  = { title = "Status",  fn = M.status },
  skills  = { title = "Skills",  fn = M.skills },
  powers  = { title = "Powers",  fn = M.powers },
  companions = { title = "Companions", fn = M.companions },
  discord = { title = "Discord", fn = M.discord },
}

M.ORDER = { "status", "powers", "skills", "companions", "discord" }

return M
