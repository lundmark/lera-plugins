-- The mercenary record: a flat projection of protocol.lua's per-sub-package
-- mirrors, keeping the field names the plugin's public API has always used.

local M = {}

-- mercdefs.h. 1 and 5 are the two a client actually sees: the remaining three
-- either stop the heartbeat or fail the push conditions.
local STATUS_NAMES = {
  [1] = "active", [2] = "dismissed", [3] = "dead",
  [4] = "stored", [5] = "dormant",
}

-- mercenary_base.c:100. (Line 331 defaults to 2 under a stale "neuter"
-- comment; the value is female and the comment is the wrong half.)
local GENDER_NAMES = { [0] = "neutral", [1] = "male", [2] = "female" }

local rec

local function num(v, dflt)
  local n = tonumber(v)
  if n then return n end
  return dflt or 0
end

local function str(v, dflt)
  if type(v) == "string" then return v end
  return dflt or ""
end

local function pct(cur, max)
  if max > 0 then return math.floor(cur / max * 100) end
  return 0
end

local function capitalize(s)
  if s == "" then return s end
  return s:sub(1, 1):upper() .. s:sub(2)
end

function M.reset()
  rec = {
    name = "No Mercenary", merc_name = "",

    hp_current = 0, hp_max = 0, hp_percent = 0, hp_delta = 0,
    stamina_current = 0, stamina_max = 0, stamina_percent = 0,
    stamina_regen = 0, stamina_delta = 0,
    ap_current = 0, ap_max = 0, ap_percent = 0, ap_regen = 0, ap_delta = 0,

    prev_hp = 0, prev_stamina = 0, prev_ap = 0,

    target = "None", target_pct = 0, abilities = "",
    dormant = 0, is_dormant = false,

    class = "", theme = "", gender = 0, gender_name = "neutral",
    status = 0, status_name = "unknown",
    damage_type = "", cost = 0, following = false, eff_level = 0,

    pl_level = 0, pl_xp = 0, pl_needed = 0, pl_max_level = 150,
    il_level = 0, il_xp = 0, il_needed = 0, il_max_level = 30,

    skill_points = 0, fund = 0, spent = 0,
    spent_boot = 0, spent_skills = 0, spent_spec = 0,
    rounds = 0, dmg_out = 0, dmg_in = 0, healing = 0, abilities_used = 0,
    life_rounds = 0, life_dmg_out = 0, life_dmg_in = 0,
    life_healing = 0, life_abilities = 0,

    skills = {}, skills_meta = { points = 0, allocs = 0, next_cost = 0 },
    talents = {}, talents_meta = { points = 0, allocs = 0, next_cost = 0 },

    pl_xp_start = 0, il_xp_start = 0, tracking_start_time = 0,
    pl_xp_per_hour = 0, il_xp_per_hour = 0,
    prev_pl_level = 0, prev_il_level = 0,
    xp_baseline_dirty = false,

    last_update = 0,
  }
end

M.reset()

function M.get() return rec end
function M.has_data() return rec.last_update > 0 end

function M.reset_xp_tracking()
  rec.tracking_start_time = lera.time()
  rec.pl_xp_start = rec.pl_xp
  rec.il_xp_start = rec.il_xp
  rec.pl_xp_per_hour = 0
  rec.il_xp_per_hour = 0
  rec.xp_baseline_dirty = false
end

local function apply_vitals(m)
  rec.prev_hp = rec.hp_current
  rec.prev_stamina = rec.stamina_current
  rec.prev_ap = rec.ap_current

  rec.hp_current = num(m.hp)
  rec.hp_max = num(m.hp_max)
  rec.stamina_current = num(m.stam)
  rec.stamina_max = num(m.stam_max)
  rec.stamina_regen = num(m.stam_regen)
  rec.ap_current = num(m.ap)
  rec.ap_max = num(m.ap_max)
  rec.ap_regen = num(m.ap_regen)
  -- "" is what the wire sends with no target; the historical "None" default
  -- survives only until the first frame. stats_window tests for both.
  rec.target = str(m.target, "")
  rec.target_pct = num(m.target_hp)
  rec.abilities = str(m.abils, "")
  -- Seconds, not ticks, and already decremented once before the first push:
  -- the first value on the wire is 298 of a 300 second recovery.
  rec.dormant = num(m.dormant)

  rec.hp_percent = pct(rec.hp_current, rec.hp_max)
  rec.stamina_percent = pct(rec.stamina_current, rec.stamina_max)
  rec.ap_percent = pct(rec.ap_current, rec.ap_max)

  -- An absent key leaves the mirror value unchanged, so a delta frame that did
  -- not move hp yields a delta of 0 with no special handling.
  rec.hp_delta = rec.hp_current - rec.prev_hp
  rec.stamina_delta = rec.stamina_current - rec.prev_stamina
  rec.ap_delta = rec.ap_current - rec.prev_ap
end

local function apply_info(m)
  rec.prev_pl_level = rec.pl_level
  rec.prev_il_level = rec.il_level

  rec.class = str(m.class)
  rec.theme = str(m.theme)
  rec.gender = num(m.gender)
  rec.gender_name = GENDER_NAMES[rec.gender] or "unknown"
  rec.status = num(m.status)
  rec.status_name = STATUS_NAMES[rec.status] or "unknown"
  rec.is_dormant = (rec.status == 5)
  rec.damage_type = str(m.dtype)
  rec.cost = num(m.cost)
  rec.following = (num(m.follow) == 1)
  rec.pl_level = num(m.perm_level)
  rec.pl_max_level = num(m.perm_cap, 150)
  rec.il_level = num(m.inst_level)
  rec.il_max_level = num(m.inst_cap, 30)
  rec.eff_level = num(m.eff_level)

  -- A level-up moves the xp baseline, but the new xp arrives on Merc.Stats,
  -- which rides a different tick. Rebaselining here would measure the new xp
  -- against a stale start over a near-zero interval and spike the rate, so the
  -- reset is deferred to the next Stats frame.
  if rec.prev_pl_level ~= rec.pl_level or rec.prev_il_level ~= rec.il_level then
    rec.xp_baseline_dirty = true
  end
end

local function apply_stats(m)
  rec.pl_xp = num(m.perm_xp)
  rec.pl_needed = num(m.perm_xp_next)
  rec.il_xp = num(m.inst_xp)
  rec.il_needed = num(m.inst_xp_next)
  rec.skill_points = num(m.skill_points)
  rec.fund = num(m.fund)
  rec.spent = num(m.spent_total)
  rec.spent_boot = num(m.spent_boot)
  rec.spent_skills = num(m.spent_skills)
  rec.spent_spec = num(m.spent_spec)
  rec.rounds = num(m.rounds)
  rec.dmg_out = num(m.dmg_out)
  rec.dmg_in = num(m.dmg_in)
  rec.healing = num(m.healing)
  -- Stats.abilities is a COUNTER. The active-abilities string lives on
  -- Vitals.abils and keeps the public name `abilities`.
  rec.abilities_used = num(m.abilities)
  rec.life_rounds = num(m.life_rounds)
  rec.life_dmg_out = num(m.life_dmg_out)
  rec.life_dmg_in = num(m.life_dmg_in)
  rec.life_healing = num(m.life_healing)
  rec.life_abilities = num(m.life_abilities)

  if rec.tracking_start_time == 0 or rec.xp_baseline_dirty then
    M.reset_xp_tracking()
    return
  end
  local elapsed = lera.time() - rec.tracking_start_time
  if elapsed > 0 then
    rec.pl_xp_per_hour = (rec.pl_xp - rec.pl_xp_start) / elapsed * 3600
    rec.il_xp_per_hour = (rec.il_xp - rec.il_xp_start) / elapsed * 3600
  end
end

local APPLY = {
  Vitals = apply_vitals,
  Info = apply_info,
  Stats = apply_stats,
}

function M.apply(sub, mirror, merc_name, switched)
  local fn = APPLY[sub]
  if not fn then return false end

  rec.merc_name = str(merc_name)
  rec.name = capitalize(rec.merc_name)
  fn(mirror)
  rec.last_update = lera.time()
  return true
end

function M.snapshot()
  local out = {}
  for k, v in pairs(rec) do
    if type(v) == "table" then
      local copy = {}
      for ik, iv in pairs(v) do
        if type(iv) == "table" then
          local inner = {}
          for jk, jv in pairs(iv) do inner[jk] = jv end
          copy[ik] = inner
        else
          copy[ik] = iv
        end
      end
      out[k] = copy
    else
      out[k] = v
    end
  end
  return out
end

return M
