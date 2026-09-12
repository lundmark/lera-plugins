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
  [4] = "De Praesidiis",
  [5] = "De Societate",
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
  local by_kind = {}
  for _, p in ipairs(S.powers) do
    local k = p.kind or 0
    by_kind[k] = by_kind[k] or {}
    table.insert(by_kind[k], p)
  end

  local function row(p)
    -- Underscores to spaces IS the command argument: shmaintain lower-cases
    -- and resolves its target through resolve_skill()/query_spell(), both of
    -- which take the spaced display form ("scutum spiritale").
    local label = tostring(p.id or ""):gsub("_", " ")
    local mark = p.on and (C.bright_green .. "on " .. P.RESET)
                       or (C.dim .. "off" .. P.RESET)
    local keep = p.maintained and (C.cyan .. "M" .. P.RESET) or " "
    L[#L + 1] = string.format("  %s %s %s", mark, keep, P.pad(pretty(p.id), width - 8))
    targets[#L] = { id = p.id, label = label }
  end

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
  L[#L + 1] = C.dim .. "  M = flagged to re-maintain after a drop" .. P.RESET
  L[#L + 1] = C.dim .. "  click a power to toggle it" .. P.RESET
  if S.party == 1 then
    L[#L + 1] = C.bright_cyan .. "  De Societate party is active" .. P.RESET
  end
  return L, targets
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
  powers  = { title = "Powers",  fn = M.powers },
  discord = { title = "Discord", fn = M.discord },
}

M.ORDER = { "status", "powers", "discord" }

return M
