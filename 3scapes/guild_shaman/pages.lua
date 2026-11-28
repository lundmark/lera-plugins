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
function M.status(width)
  width = width or 60
  local L = {}

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
    for _, c in ipairs(S.skillcats) do
      local name = CAT_NAMES[c.cat] or ("Category " .. c.cat)
      local gain = c.last > 0 and (C.bright_green .. " +" .. c.last .. P.RESET) or ""
      L[#L + 1] = string.format("%s %s%s",
        P.pad(C.dim .. name .. P.RESET, 22),
        P.pad(string.format("%d gxp", c.gxp), 12),
        string.format("%s%d/%d held  %d/%d maxed  %d levels%s%s",
          C.dim, c.held, c.skills, c.maxed, c.skills, c.levels, P.RESET, gain))
    end
  end

  return L
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
  local L, targets = {}, {}

  L[#L + 1] = P.header(width, "Maintained powers")
  if #S.powers == 0 then
    L[#L + 1] = C.dim .. "  (no powers available yet)" .. P.RESET
    return L, targets
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
  return L, targets
end

function M.skills(width)
  width = width or 72
  if not S.skill_details then return { C.dim .. "Waiting for skill details." .. P.RESET } end

  local pools = {}
  for _, cat in ipairs(S.skillcats) do pools[cat.cat] = cat.gxp end
  local lines, category = {}, nil
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
    if skill.requirements ~= "" then
      local line = "    "
      for word in skill.requirements:gmatch("%S+") do
        if #line > 4 and #line + #word + 1 > width then
          lines[#lines + 1] = C.dim .. line .. P.RESET
          line = "    "
        end
        if #line > 4 then line = line .. " " end
        line = line .. word
      end
      lines[#lines + 1] = C.dim .. line .. P.RESET
    end
  end
  if #lines == 0 then lines[1] = "No skills available." end
  return lines
end

function M.companions(width)
  width = width or 72
  if not S.companions then return { C.dim .. "Waiting for companion details." .. P.RESET } end

  local bonded = 0
  for _, spirit in ipairs(S.companions) do
    if spirit.bonded then bonded = bonded + 1 end
  end
  local lines = { P.header(width, string.format("Manifestations bonded %d/%d", bonded, S.bond_cap)) }
  for _, group in ipairs({ "earth", "sky" }) do
    lines[#lines + 1] = C.bright_cyan .. pretty(group) .. P.RESET
    local start = #lines
    for _, spirit in ipairs(S.companions) do
      if spirit.category == group then
        lines[#lines + 1] = "  " .. P.pad(spirit.name, 36)
          .. (spirit.bonded and (C.bright_green .. "Bonded") or (C.dim .. "Learned")) .. P.RESET
      end
    end
    if #lines == start then lines[#lines + 1] = C.dim .. "  None learned" .. P.RESET end
  end
  if bonded < S.bond_cap then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Use 'bond manifestation' in the manifestation's room."
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- Discord -- leyline strain and what it is costing
-- ---------------------------------------------------------------------------
function M.discord(width)
  width = width or 60
  local L = {}

  L[#L + 1] = P.header(width, "Leyline discord")

  -- Label only. The raw region key is no longer sent (it could be a
  -- "path:/players/<wiz>/areas/..." fallback), so there is nothing to fall
  -- back TO -- an unnamed area reports as unknown rather than as its path.
  L[#L + 1] = P.kv("Here",
                   (S.ley_here_label ~= "" and S.ley_here_label) or "unknown",
                   C.white)
  -- Discord is a 0-100 strain reading, so a HIGH value is bad -- pct_color
  -- rates high as good, hence the inverted argument.
  local dcol = P.pct_color(100 - S.ley_here_discord, 100)
  L[#L + 1] = P.kv("Discord", S.ley_here_discord, dcol) .. " " ..
              P.bar(math.max(8, math.min(24, width - 24)),
                    S.ley_here_discord, 100, dcol)

  -- No backlash block here. The server deliberately stopped sending the
  -- shaman's own penalty on this panel (see send_gmcp_leyline()'s header in
  -- players/shaman/obj/include/gmcp.h): discord is world state a client may
  -- render, the damage a shaman is personally losing to it is not. This tab
  -- shows realms and areas only.
  L[#L + 1] = ""
  L[#L + 1] = P.header(width, "Realms")
  if #S.ley_realms == 0 then
    L[#L + 1] = C.dim .. "  (no realm is disturbed)" .. P.RESET
  else
    for _, r in ipairs(S.ley_realms) do
      local col = P.pct_color(100 - math.min(r.discord, 100), 100)
      L[#L + 1] = string.format(" %s %s",
        P.pad(col .. tostring(r.discord) .. P.RESET, 5),
        P.pad(r.realm, 22))
    end
  end

  L[#L + 1] = ""
  L[#L + 1] = P.header(width, "Disturbed areas")
  if #S.ley_regions == 0 then
    L[#L + 1] = C.dim .. "  (the ley lines are calm)" .. P.RESET
    return L
  end
  for i, r in ipairs(S.ley_regions) do
    if i > 15 then
      L[#L + 1] = C.dim .. string.format("  ... and %d more",
        #S.ley_regions - 15) .. P.RESET
      break
    end
    local col = P.pct_color(100 - r.discord, 100)
    L[#L + 1] = string.format(" %s %s %s",
      P.pad(col .. tostring(r.discord) .. P.RESET, 5),
      P.pad(r.region, 22),
      C.dim .. r.realm .. P.RESET)
  end
  return L
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
