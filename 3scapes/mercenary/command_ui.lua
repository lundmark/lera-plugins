-- /merc rendering. Named command_ui rather than command because `command` is a
-- sandbox whitelist name that resolves to the registry API.

local M = {}

local state = require("state")
local protocol = require("protocol")

local command_id = nil
local api = nil

local function line(text) buffer.color_print(nil, nil, text) end
local function head(text) buffer.color_print(nil, "FFAA00", text) end
local function warn(text) buffer.color_print(nil, 1, text) end

local function fmt_seconds(secs)
  local m = math.floor(secs / 60)
  return string.format("%d:%02d", m, secs - m * 60)
end

-- Arrival times are recorded as lera.time() epochs. An epoch is not something a
-- reader can do anything with; "42s ago" answers the question /merc status is
-- being asked, which is whether a package is still arriving.
local function ago(at)
  local delta = lera.time() - at
  if delta < 0 then delta = 0 end
  if delta < 60 then return string.format("%ds ago", delta) end
  return fmt_seconds(delta) .. " ago"
end

local function show_summary()
  if not state.has_data() then
    warn("[merc] no mercenary data this connection")
    return
  end
  local s = state.get()
  head(s.name .. "  (" .. s.class .. "/" .. s.theme .. ", " .. s.status_name .. ")")
  line(string.format("HP %d/%d (%d%%)   ST %d/%d +%d   AP %d/%d +%d",
    s.hp_current, s.hp_max, s.hp_percent,
    s.stamina_current, s.stamina_max, s.stamina_regen,
    s.ap_current, s.ap_max, s.ap_regen))
  if s.is_dormant then
    warn("DORMANT - recovering, " .. fmt_seconds(s.dormant) .. " remaining")
  elseif s.target ~= "" and s.target ~= "None" then
    line(string.format("Target: %s (%d%%)", s.target, s.target_pct))
  end
  line(string.format("PL %d/%d  %d/%d xp    IL %d/%d  %d/%d xp    effective %d",
    s.pl_level, s.pl_max_level, s.pl_xp, s.pl_needed,
    s.il_level, s.il_max_level, s.il_xp, s.il_needed, s.eff_level))
  line(string.format("Cost %d/round  %s  %s   fund %d  spent %d (boot %d, skills %d, spec %d)",
    s.cost, s.damage_type, s.following and "following" or "not following",
    s.fund, s.spent, s.spent_boot, s.spent_skills, s.spent_spec))
  line(string.format("Session: %d rounds, %d dealt, %d taken, %d healed, %d abilities",
    s.rounds, s.dmg_out, s.dmg_in, s.healing, s.abilities_used))
  line(string.format("Lifetime: %d rounds, %d dealt, %d taken, %d healed, %d abilities",
    s.life_rounds, s.life_dmg_out, s.life_dmg_in, s.life_healing, s.life_abilities))
end

-- Skills and Talents push only on daemon registration, on allocation and on a
-- level-up; heart_beat() has no reconnect trigger. A link drop short enough
-- that neither a heart_beat nor a registration observes it delivers no slow
-- package at all until the next allocation, and there is no client-side way to
-- ask for one. Saying so beats rendering zeroes that look like real data.
local function slow_missing(sub)
  if protocol.seen(sub) then return false end
  warn("[merc] no Merc." .. sub .. " received this connection.")
  warn("       These push only on hire/summon, an allocation or a level-up.")
  return true
end

local function show_records(sub, records, meta, fields, label)
  if slow_missing(sub) then return end
  local names = {}
  for name in pairs(records) do names[#names + 1] = name end
  table.sort(names)
  if #names == 0 then
    warn("[merc] no " .. label .. " recorded")
    return
  end
  head(label .. " - " .. meta.points .. " points available, " ..
       meta.allocs .. " allocated, next costs " .. meta.next_cost)
  for _, name in ipairs(names) do
    local r = records[name]
    local parts = {}
    for _, f in ipairs(fields) do
      parts[#parts + 1] = f .. " " .. tostring(r[f] or 0)
    end
    line(string.format("  %-16s %s", name, table.concat(parts, "  ")))
  end
end

local function show_status()
  local st = api.protocol_status()
  head("Merc.* protocol status")
  line("  attributed to: " .. tostring(st.merc or "(nothing received)"))
  local c = st.counters
  line(string.format("  frames %d, applied %d", c.frames, c.applied))
  line(string.format(
    "  dropped: %d bad package, %d bad payload, %d bad attribution, %d bad page",
    c.bad_package, c.bad_payload, c.bad_attribution, c.bad_page))
  for _, sub in ipairs({ "Vitals", "Info", "Stats", "Skills", "Talents" }) do
    local at = st.seen[sub]
    line(string.format("  %-8s %s", sub,
      at and ago(at) or "not received this connection"))
  end
end

local function show_auto_use()
  local c = api.get_auto_use_config()
  head("Auto-use " .. (c.enabled and "ON" or "off"))
  line(string.format("ability=%s  stam>=%d%%  ap>=%d%%  cooldown=%ss",
    c.ability, c.stamina_threshold, c.ap_threshold, c.cooldown_seconds))
end

local function show_help()
  head("Mercenary commands")
  line("/merc                         Show mercenary summary")
  line("/merc skills | talents | status")
  line("/merc omit on|off             Hide/show legacy three-line status output")
  line("/merc auto on|off")
  line("/merc auto ability <name>     none, bandage, mend, sustain, fortify, amplify,")
  line("                               critical, frenzy, rend, combo, aegis, hamstring,")
  line("                               intervene, cover")
  line("/merc auto stam|ap <0-100>    Set required resource percentages")
  line("/merc auto cooldown <seconds>")
  show_auto_use()
end

local function dispatch(args)
  local sub, rest = tostring(args or ""):match("^%s*(%S*)%s*(.-)%s*$")
  sub, rest = (sub or ""):lower(), rest or ""

  if sub == "" then
    show_summary()
    show_help()
  elseif sub == "skills" then
    local records, meta = api.skills()
    show_records("Skills", records, meta, { "raw", "eff" }, "Skills")
  elseif sub == "talents" then
    local records, meta = api.talents()
    show_records("Talents", records, meta, { "points", "eff", "min_level" }, "Talents")
  elseif sub == "status" then
    show_status()
  elseif sub == "omit" then
    local setting = rest:lower()
    if setting ~= "on" and setting ~= "off" then
      warn("Usage: /merc omit on|off")
      return
    end
    api.set_omit_status_lines(setting == "on")
    line("Merc status output omission " .. setting:upper())
  elseif sub == "auto" then
    local action, value = rest:match("^(%S*)%s*(.-)%s*$")
    action, value = (action or ""):lower(), value or ""
    if action == "" then
      show_auto_use()
    elseif action == "on" or action == "off" then
      api.set_auto_use_enabled(action == "on")
      show_auto_use()
    elseif action == "ability" then
      value = value:lower()
      if not api.set_auto_use_ability(value) then
        warn("Unknown mercenary ability: " .. (value ~= "" and value or "(none)"))
        return
      end
      show_auto_use()
    elseif action == "stam" or action == "ap" or action == "cooldown" then
      local number = tonumber(value)
      local ok
      if action == "stam" then ok = number and api.set_auto_use_stamina_threshold(number)
      elseif action == "ap" then ok = number and api.set_auto_use_ap_threshold(number)
      else ok = number and api.set_auto_use_cooldown(number) end
      if not ok then
        local range = action == "cooldown" and "a non-negative number" or "a number from 0 to 100"
        warn("/merc auto " .. action .. " requires " .. range)
        return
      end
      show_auto_use()
    else
      warn("Usage: /merc auto [on|off|ability <name>|stam <0-100>|ap <0-100>|cooldown <seconds>]")
    end
  else
    warn("Usage: /merc [skills|talents|status|omit on|off|auto ...]")
  end
end

function M.install(plugin_api)
  api = plugin_api
  local command = require("command")
  local id, err = command.register({
    name = "/merc",
    usage = "/merc [skills | talents | status | omit on|off | auto ...]",
    summary = "Mercenary state from the Merc.* GMCP namespace",
    description = "Shows the active mercenary's vitals, progression and "
      .. "economy. 'skills' lists trained skill points raw and effective, "
      .. "'talents' the ability specializations, and 'status' reports which "
      .. "Merc.* packages have arrived this connection. Omit can hide or show the three legacy status lines, and auto configures automatic ability use.",
    accepts_args = true,
    handler = function(args) dispatch(args) end,
  })
  if id then
    command_id = id
  else
    print("[mercenary] command registration failed: " .. tostring(err))
  end
end

function M.uninstall()
  if not command_id then return end
  local command = require("command")
  command.unregister(command_id)
  command_id = nil
end

return M
