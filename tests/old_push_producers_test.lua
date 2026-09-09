-- Offline producer regression: use the same PCRE2 dialect/capture convention
-- as Lera, never Lua-pattern approximations. Requires libpcre2-8 and LuaJIT.
package.path = "3scapes/?.lua;generic/?.lua;" .. package.path
local ffi = require("ffi")
ffi.cdef[[
void *pcre2_compile_8(const char *, size_t, uint32_t, int *, size_t *, void *);
void pcre2_code_free_8(void *);
void *pcre2_match_data_create_from_pattern_8(const void *, void *);
void pcre2_match_data_free_8(void *);
int pcre2_match_8(const void *, const char *, size_t, size_t, uint32_t, void *, void *);
size_t *pcre2_get_ovector_pointer_8(void *);
]]
local pcre = ffi.load("pcre2-8")
local checks = 0
local function check(ok, message)
  assert(ok, message)
  checks = checks + 1
end
local records, next_id = {}, 0
trigger = {
  add = function(pattern, fn, opts)
    local err, offset = ffi.new("int[1]"), ffi.new("size_t[1]")
    local code = pcre.pcre2_compile_8(pattern, #pattern, 0x000a0000, err, offset, nil)
    assert(code ~= nil, "invalid PCRE2: " .. pattern)
    code = ffi.gc(code, pcre.pcre2_code_free_8)
    next_id = next_id + 1
    records[next_id] = { code = code, fn = fn, opts = opts }
    return next_id
  end,
  remove = function(id) records[id] = nil end,
}
local function feed(line)
  local matches, omitted = 0, false
  for _, record in pairs(records) do
    local md = pcre.pcre2_match_data_create_from_pattern_8(record.code, nil)
    local rc = pcre.pcre2_match_8(record.code, line, #line, 0, 0, md, nil)
    if rc > 0 then
      local offsets = pcre.pcre2_get_ovector_pointer_8(md)
      local args = {}
      for i = 0, rc - 1 do
        args[#args + 1] = line:sub(tonumber(offsets[2*i]) + 1, tonumber(offsets[2*i+1]))
      end
      record.fn(unpack(args))
      matches = matches + 1
      omitted = omitted or record.opts.omit_from_output == true
    end
    pcre.pcre2_match_data_free_8(md)
  end
  return matches, omitted
end
local commands, printed, sent = {}, {}, {}
package.preload.command = function() return {
  register = function(spec) commands[spec.name] = spec.handler; return spec.name end,
  unregister = function(id) commands[id] = nil end,
  get = function(name) return commands[name] end,
} end
package.preload.wm = function() return { make_scroller = function() return {} end } end
local saved
store = {
  load = function() end, get = function() return saved end,
  set = function(value) saved = value end, save = function() end,
}
lera = { time = function() return 1000 end }
mud = { send = function(text) sent[#sent + 1] = text end }
mip = { on = function(code) return code end, off = function() end }
gmcp = { on = function(code) return code end, remove = function() end }
local real_print = print
print = function(text) printed[#printed + 1] = text end
local sink
plugin = { get = function(name) if name == "push_notify" then return sink end end }
local chat = require("chat_monitor")
local kill = require("kill_trigger")
chat.on_load()
kill.on_load()
chat.on_setup()
kill.on_setup()
local positives = {
  { "Your legs run away with you north.", "wimpy", "You have wimpied." },
  { "Your legs run away with you ", "wimpy", "You have wimpied." },
  { "You have found a glittering gem!", "worlddrop" },
  { "You have found !", "worlddrop" },
  { "YOWZA! You are lucky enough to find a gem!", "worlddrop" },
  { "YOWZA!  You are lucky enough to find a gem!", "worlddrop" },
  { "YOWZA! You are lucky enough to find ", "worlddrop" },
  { "You catch the glint of something special.", "artifactdrop" },
}
for _, case in ipairs(positives) do
  local n, omit = feed(case[1])
  check(n == 1 and not omit, "missing push must retain text")
end
feed("Other dealt the killing blow to a rat.")
local calls, channels = {}, {}
local function spy()
  return {
    register_channel = function(name, opts) channels[name] = opts or {} end,
    notify = function(channel, text) calls[#calls + 1] = { channel, text }; return false end,
  }
end
sink = spy() -- Late load, without another producer setup.
for _, case in ipairs(positives) do
  calls = {}
  local n, omit = feed(case[1])
  check(n == 1 and not omit, "text trigger must not omit output")
  check(#calls == 1 and calls[1][1] == case[2] and calls[1][2] == (case[3] or case[1]),
    "exact channel/text: " .. case[1])
end
for _, channel in ipairs({ "tells", "wimpy", "worlddrop", "artifactdrop" }) do
  check(channels[channel] ~= nil, "late registration: " .. channel)
end
local negatives = {
  "Your legs run away with you", "Your legs run away with them north.",
  "Someone says: Your legs run away with you north.",
  "You have found a gem", "You have found a gem! extra", "xYou have found a gem!",
  "YOWZA!You are lucky enough to find a gem!", "YOWZA!   You are lucky enough to find a gem!",
  "YOWZA! You were lucky enough to find a gem!", "xYOWZA! You are lucky enough to find a gem!",
  "You catch the glint of something special!", "You catch the glint of something special",
  "You catch the glint of something special. extra", "xYou catch the glint of something special.",
  "Other dealt the killing blow to a rat!", "Other dealt the killing blow to a rat. extra",
}
for _, line in ipairs(negatives) do
  calls = {}
  check(feed(line) == 0 and #calls == 0, "negative: " .. line)
end
commands["/killers"]("addocmd loot")
commands["/killers"]("add self")
local heard = 0
kill.on_monster_died(function() heard = heard + 1 end)
local function blow(line, expected, expected_command)
  calls, sent, printed = {}, {}, {}
  local before = heard
  local n, omit = feed(line)
  check(n == 1 and omit, "kill retains existing replacement-output rule")
  check(#printed == 1 and printed[1]:find("dealt the killing blow to", 1, true), "formatted kill output retained")
  check(heard == before + 1, "kill listeners still fire once")
  check(#calls == expected, "kill branch notification count: " .. line)
  if expected_command then check(sent[1] == expected_command, "kill commands retained") end
end
blow("  Other  dealt the killing blow to   A Rat  .", 1, "loot")
check(calls[1][1] == "killingblow" and calls[1][2] == "Other dealt the killing blow to A Rat", "trimmed exact killingblow payload")
check(channels.killingblow ~= nil, "late kill channel registration")
blow("TAPIR dealt the killing blow to a rat.", 0, "sl")
blow("A Rat dealt the killing blow to a rat.", 0, "sl")
commands["/killers"]("off")
blow("Other dealt the killing blow to a rat.", 0)
check(#sent == 0, "disabled kill sends no commands")
commands["/killers"]("on")
commands["/killers"]("del self")
blow("A Rat dealt the killing blow to a rat.", 1, "loot")
-- Removed/replaced sink must never receive stale callbacks.
sink = nil
calls = {}
feed(positives[1][1]); feed("Other dealt the killing blow to a rat.")
check(#calls == 0, "unloaded consumer not called")
channels = {}
sink = spy()
feed(positives[1][1]); feed("Other dealt the killing blow to a rat.")
check(#calls == 2 and channels.wimpy and channels.killingblow, "replacement consumer discovered")
chat.on_setup(); chat.on_setup(); kill.on_setup(); kill.on_setup()
calls = {}
feed(positives[1][1]); feed("Other dealt the killing blow to a rat.")
check(#calls == 2, "repeated setup adds no callbacks")
chat.on_unload(); kill.on_unload()
check(next(records) == nil, "unload removes every producer trigger")
saved = nil
chat.on_load(); kill.on_load(); chat.on_setup(); kill.on_setup()
calls = {}
for _, case in ipairs(positives) do check(feed(case[1]) == 1, "one trigger after reload") end
feed("Other dealt the killing blow to a rat.")
check(#calls == #positives + 1, "one notification per event after reload")
-- Real consumer, no credentials, with a fail-closed push backend: never sends.
push = {
  init = function() error("test must not configure credentials") end,
  send = function() error("test must not send pushes") end,
  enabled = function() return false end,
}
saved = nil
sink = require("push_notify")
sink.on_load()
chat.on_setup(); kill.on_setup()
for _, case in ipairs(positives) do feed(case[1]) end
feed("Other dealt the killing blow to a rat.")
sink.on_unload()
for _, channel in ipairs({ "wimpy", "worlddrop", "artifactdrop", "killingblow" }) do
  check(saved.config.channels[channel].enabled == false, "real channel defaults opt-in: " .. channel)
  check(saved.config.channels[channel].priority == 0, "normal channel priority: " .. channel)
end
check(saved.config.grace_period == 60 and saved.config.rate_limit == 60, "consumer policy unchanged")
chat.on_unload(); kill.on_unload()
print = real_print
print("ALL PASS (" .. checks .. " offline old-push producer checks)")
