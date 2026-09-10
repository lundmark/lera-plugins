-- Port of the legacy Mushclient Professions plugin.
--
-- The XML is a trigger manager, not a data protocol: it watches profession
-- start/stop messages, optionally suppresses repetitive proc messages, and
-- uses the `profs` MUD command to display the profession list. Lera keeps the
-- same controls under /profs and registers only the triggers the user enables.

local M = {}
local command = require("command")
M.name = "professions"
M.version = "1.0"
M.priority = 40

local trigger_ids = {}
local command_id = nil
local enabled = { profession_advance = true }

local highlight = {
  sadist = {
    start = "^Your hand touches the whip, and your lips curl into a cruel sneer\\.$",
    stop = "^You find yourself satisfied with your enemy's PAIN\\.\\.\\. for now\\.$",
    remove = { "^Time to make it hurt\\.$" },
  },
  mystic = {
    start = "^Your Mystic's Orb begins to glow brightly!$",
    stop = "^The glow from your Mystic's Orb dissipates\\.$",
    remove = { "^Your Mystic's Orb glows softly and hums with energy\\.$" },
  },
  weaponmaster = {
    start = "^Your badge shimmers, and you press your attack!$",
    stop = "^You relax your attack\\.$",
    remove = { "^Your weapons become instruments of death!$" },
  },
  puppet_master = {
    start = "^The marionette strings spring to life as the hooks search for a puppet!$",
    stop = "^Your hand falters, and the marionette goes limp as the hooks retract\\.$",
    remove = { '^You pick up the cross and cackle, "DANCE MY MINIONS! DANCE!"$' },
  },
  contortionist = {
    start = "^You begin to dodge and weave and dance out of harm's way!$",
    stop = "^You tire from the dodging and weaving and pause to catch your breath\\.$",
    remove = { "^You dodge and weave and twist away from attacks!$" },
  },
  cult_leader = {
    start = "^Inspiration strikes! You reveal the truth about kitty mind control!$",
    stop = "^You take a break to readjust your tinfoil hat\\.$",
    remove = { "^You urge everybody to fight against ([A-Z][a-z]+(?:@3s)?)$" },
  },
  swordsman = {
    start = "^Your swordsman's training kicks in and you press your attack!$",
    stop = "^Your swordsman's advantage ends\\.$",
    remove = { "^You press your attack using your swordsman's training!$" },
  },
  puppeteer = {
    start = "^The marionette strings spring to life as the hooks search for a puppet!$",
    stop = "^Your hand falters, and the marionette goes limp as the hooks retract\\.$",
  },
  hypnotist = {
    start = "^You tune your breathing and heartbeat, and slip into a hypnotic state!$",
    stop = "^The clash of combat distracts you from your hypnotic state\\.$",
    remove = { "^You manipulate mental and magical energies with ease!$" },
  },
  staff_master = {
    start = "^Your training takes over, and your weapon becomes a blur!$",
    stop = "^You feel your attacks slow down to a normal pace\\.$",
    remove = { "^You spin your weapon deftly, and press the attack!$" },
  },
  shield_specialist = {
    start = "^You feel more confident in your ability to block enemy attacks!$",
    stop = "^Your confidence in your ability to block enemy attacks fades\\.$",
    remove = { "^Your confidence bolsters your ability to block enemy attacks!$" },
  },
  big_game_hunter = {
    start = "^Your crazed ambition overflows!$",
    stop = "^Your wild ambition takes a back seat to prudence\\.$",
    remove = {
      "^Your ambition overflows as you try to bring down the big game!$",
      "^Your wild ambition drives you ever onward!$",
      "^Your ambition overflows as you try to bring down the big game with a ferocious attack!$",
    },
  },
  daredevil = {
    start = "^Adrenaline fills your veins! This is AWESOME!$",
    stop = "^The adrenaline fades a little\\.$",
    remove = { "^Adventure! You're having the time of your life!$" },
  },
  magician = {
    start = "^The shabby black top hat belches forth magical nexus that fuels your attacks!$",
    stop = "^With a POP the magical nexus snaps shut\\.$",
    remove = { "^The familiar spirit taps ley lines, seeking to power your spells!$" },
  },
  magician3s = {
    start = "^The familiar spirit stirs into wakefulness!$",
    stop = "^The familiar spirit curls up and goes to sleep\\.  Grumble\\.$",
    remove = { "^The familiar spirit taps ley lines, seeking to power your spells!$" },
  },
  assassin = {
    start = "^A flash of insidious insight strikes you!$",
    stop = "^Your insidious inspiration fades\\.$",
    remove = { "^Insidious inspiration strikes you, and you make the most of each attack!$" },
  },
  brawler = {
    start = "^You enter a state of unarmed frenzy!$",
    stop = "^Your unarmed frenzy ends\\.$",
    remove = { "^You bring your deadly natural weapons down on your opponent!$" },
  },
  tactician = {
    start = "^You outfox your opponent and take advantage of it!$",
    stop = "^Your tactical advantage ends\\.$",
    remove = { "^You press your advantage on your outsmarted foe!$" },
  },
  acrobat = {
    start = "^You begin to dodge and weave and dance out of harm's way!$",
    stop = "^You tire from the dodging and weaving and pause to catch your breath\\.$",
  },
  electrician = {
    start = "^You reconfigure your board's circuitry for maximal power!$",
    stop = "^A connection on your board burns out, you'll need to patch it\\.$",
  },
}

local chatlines = {
  anatomist = { "^You tremble from the need to explore the wet insides of another body\\.$" },
  fieldsmith = { "^The lightning infused hammer crackles with power, ready to dismantle once more\\.$" },
  herbologist = { "^You get a sudden breath of fresh air, and you realize you (.*?)$", "^probably keep your eyes open for more herbs\\.$" },
  hooligan = { "^You take a swig from your riot punch and fuel the fire in your belly!$" },
  marshal = { "^A surge of leadership rushes through your veins, and you are inspired to$" },
  profession_advance = { "^You have become a level ([0-9]+) ([A-Za-z ]+)!$" },
  reforger = { "^You adjust your reforger's kit slightly, ready to do more business\\.$" },
  transmuter = { "^The colours in your transmuter's stone begins to swirl\\.$" },
  weaponsmith = { "^The nanites in your field kit are ready to dismantle more gear\\.$" },
}

local function notify(text, color)
  if buffer and buffer.color_print then
    -- Prompts are held as pending text. Flush them as a complete line before
    -- inserting local output, otherwise the notification can land mid-prompt.
    if buffer.flush_pending then buffer.flush_pending() end
    buffer.color_print(nil, color or "DAA520", text)
  else
    print(text)
  end
end

local function on_start(name)
  notify(">> " .. name, "55AA55")
end

local function on_stop(name)
  notify("<< " .. name, "AA5555")
end

-- Start/stop messages are replacements, not extra output.  on_line runs
-- before trigger processing and its return value updates the existing
-- scrollback line in place.
local function literal_line(pattern)
  local text = pattern:match("^%^(.*)%$$")
  if not text or text:find("%(%?") then return nil end
  return (text:gsub("\\(.)", "%1"))
end

function M.on_line(line)
  local plain = (line or ""):gsub("\27%[[0-9;?]*[ -/]*[@-~]", "")
  for name in pairs(enabled) do
    local h = highlight[name]
    if h then
      if h.start and literal_line(h.start) == plain then
        return "\27[38;2;0;255;255m>> " .. name .. "\27[0m"
      end
      if h.stop and literal_line(h.stop) == plain then
        return "\27[38;2;51;204;204m<< " .. name .. "\27[0m"
      end
    end
  end
  return line
end

local function on_chatline(name, line, c1, c2)
  if name == "profession_advance" then
    notify(string.format("[profession] %s", line), "7FFF00")
  end
end

local function add_trigger(pattern, callback, omit)
  local id, err = trigger.add(pattern, callback,
    omit and { omit_from_output = true } or nil)
  if id then
    trigger_ids[#trigger_ids + 1] = id
  else
    print("[professions] Failed to register trigger: " .. pattern ..
      " (" .. tostring(err) .. ")")
  end
  return id ~= nil
end

local function enable_profession(name)
  if enabled[name] then return end
  if not highlight[name] and not chatlines[name] then return false end
  enabled[name] = true
  local h = highlight[name]
  if h then
    -- start/stop are handled by on_line so the replacement occupies the
    -- original line; only proc/remove messages need trigger-level omission.
    for _, pattern in ipairs(h.remove or {}) do add_trigger(pattern, function() end, true) end
  end
  -- These were routed to the old chat pane. Lera's normal output is the
  -- least surprising equivalent and keeps the original line visible.
  for _, pattern in ipairs(chatlines[name] or {}) do
    add_trigger(pattern, function(line, c1, c2) on_chatline(name, line, c1, c2) end, false)
  end
  return true
end

local function remove_profession(name)
  if not enabled[name] then return false end
  enabled[name] = nil
  -- Rebuild all dynamic triggers. This is small and avoids keeping a second
  -- index that can drift when a user toggles several professions.
  local keep = {}
  for n in pairs(enabled) do keep[#keep + 1] = n end
  for _, id in ipairs(trigger_ids) do trigger.remove(id) end
  trigger_ids = {}
  enabled = {}
  for _, n in ipairs(keep) do enable_profession(n) end
  return true
end

local function sorted_names(t)
  local out = {}
  for name in pairs(t) do out[#out + 1] = name end
  table.sort(out)
  return out
end

local function show_list()
  notify("[professions] Active:", "DAA520")
  for _, name in ipairs(sorted_names(enabled)) do notify("  " .. name, "FFFFFF") end
end

local function show_help()
  notify("Usage: /profs [status | add <profession> | remove <profession> | list]", "DAA520")
  notify("With no arguments, asks the MUD for the profession list.", "FFFFFF")
end

local function show_status()
  notify("[professions] version " .. M.version, "DAA520")
  notify("  registered triggers: " .. tostring(#trigger_ids), "FFFFFF")
  notify("  enabled: " .. table.concat(sorted_names(enabled), ", "), "FFFFFF")
end

local function dispatch(args)
  local sub, name = tostring(args or ""):match("^%s*(%S*)%s*(%S*)")
  sub, name = (sub or ""):lower(), (name or ""):lower()
  if sub == "" then
    show_help()
    show_list()
    mud.send("profs")
  elseif sub == "list" then
    show_list()
  elseif sub == "status" then
    show_status()
  elseif sub == "add" then
    if enable_profession(name) then
      store.set({ enabled = enabled }); store.save()
      notify("[professions] Enabled " .. name .. ".", "55AA55")
    else notify("[professions] Unknown profession: " .. name, "AA5555") end
  elseif sub == "remove" then
    if remove_profession(name) then
      store.set({ enabled = enabled }); store.save()
      notify("[professions] Removed " .. name .. ".", "AA5555")
    else notify("[professions] Profession is not active: " .. name, "AA5555") end
  else show_help() end
end

function M.on_load()
  store.load()
  local saved = store.get()
  if saved and type(saved.enabled) == "table" then enabled = saved.enabled end
  local id, err = command.register({
    name = "/profs",
    usage = "/profs [add <profession>|remove <profession>|list]",
    summary = "Track and highlight profession effects",
    accepts_args = true,
    handler = dispatch,
  })
  command_id = id
  if not id then print("[professions] command registration failed: " .. tostring(err)) end
  local initial = {}
  for name in pairs(enabled) do initial[#initial + 1] = name end
  enabled = {}
  for _, name in ipairs(initial) do enable_profession(name) end
  notify("[professions] Loaded. Use /profs to query professions.", "DAA520")
end

function M.on_unload()
  for _, id in ipairs(trigger_ids) do trigger.remove(id) end
  trigger_ids = {}
  if command_id then command.unregister(command_id); command_id = nil end
end

return M
