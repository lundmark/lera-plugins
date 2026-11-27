-- Offline substitution regression using real PCRE2, as in the trigger engine.
-- Run from the repo root with LuaJIT and libpcre2-8 on PATH.
package.path = "generic/?.lua;" .. package.path
local ffi = require("ffi")
ffi.cdef[[
void *pcre2_compile_8(const char *, size_t, uint32_t, int *, size_t *, void *);
void pcre2_code_free_8(void *);
void *pcre2_match_data_create_from_pattern_8(const void *, void *);
void pcre2_match_data_free_8(void *);
int pcre2_match_8(const void *, const char *, size_t, size_t, uint32_t, void *, void *);
]]
local pcre = ffi.load("pcre2-8")
local checks = 0
local function check(ok, message)
  assert(ok, message)
  checks = checks + 1
end
local records, order, removed = {}, {}, {}
local next_id = 100
trigger = {
  add = function(pattern, fn, opts)
    local err, offset = ffi.new("int[1]"), ffi.new("size_t[1]")
    local code = pcre.pcre2_compile_8(pattern, #pattern, 0x000a0000, err, offset, nil)
    assert(code ~= nil, "invalid PCRE2: " .. pattern)
    next_id = next_id + 1
    records[next_id] = { code = ffi.gc(code, pcre.pcre2_code_free_8), fn = fn, opts = opts }
    order[#order + 1] = next_id
    return next_id
  end,
  remove = function(id)
    check(records[id] ~= nil, "remove only live trigger ids")
    removed[#removed + 1] = id
    records[id] = nil
  end,
}

local function feed(raw)
  -- Only the test harness strips ANSI: C does this before matching in Lera.
  local plain = raw:gsub("\27%[[0-9;?]*[ -/]*[@-~]", "")
  for _, id in ipairs(order) do
    local record = records[id]
    if record then
      local md = pcre.pcre2_match_data_create_from_pattern_8(record.code, nil)
      assert(md ~= nil, "PCRE2 match data allocation")
      local rc = pcre.pcre2_match_8(record.code, plain, #plain, 0, 0, md, nil)
      pcre.pcre2_match_data_free_8(md)
      assert(rc >= -1, "PCRE2 matching error: " .. rc)
      if rc > 0 then
        local replacement = record.fn(plain)
        if record.opts.substitute and type(replacement) == "string" and replacement ~= "" then
          return replacement -- First substitute wins in registration order.
        end
      end
    end
  end
  return raw
end

local cyan = "\27[38;2;0;255;255m"
local teal = "\27[38;2;51;204;204m"
local reset = "\27[0m"
local expected = {
  cyan .. "You penetrate." .. reset,
  cyan .. "You critically hit." .. reset,
  cyan .. "You strike again." .. reset,
  teal .. "You dodge." .. reset,
  teal .. "You block." .. reset,
  cyan .. "Free Cast." .. reset,
}
local gags = require("gags")
check(gags.name == "gags" and gags.priority == 20, "plugin identity and priority")
check(gags.on_line == nil, "no exported line hook")
gags.on_load()
check(#order == 6, "exactly six triggers")
for i, id in ipairs(order) do
  check(records[id].opts.substitute == true, "substitute enabled: " .. i)
  check(not records[id].opts.omit_from_output, "no omit/reprint: " .. i)
  check(records[id].fn() == expected[i], "replacement and precedence: " .. i)
end

local positives = {
  { "You drive your attack past the guard's resistances!", 1 },
  { "You critically hit the guard.", 2 },
  { "Combat: You critically hit the guard.", 2 },
  { "Combat: You cri\27[31mtically hit the guard.\27[0m", 2 },
  { "You drive your attack past You critically hit the guard's resistances!", 1 },
  { "Your great speed allows you to attack again!", 3 },
  { "You nimbly dodge the guard's attack!", 4 },
  { "Your shield blocks the guard's attack!", 5 },
  -- Standalone game/status line chosen in the absence of a transcript.
  { "FREE CAST", 6 },
  { "\27[32mFREE CAST\27[0m", 6 },
}
for _, case in ipairs(positives) do
  check(feed(case[1]) == expected[case[2]], "substitution: " .. case[1])
end
local negatives = {
  "\27[31mOrdinary ANSI output.\27[0m",
  "You critically hit", "You critically hit ", "Combat: You critically hit",
  "Simon tells you 'You critically hit Bob there.'",
  "Help: You critically hit the guard.",
  "The spell prompt says FREE CAST", "Simon tells you: FREE CAST later",
  "Help: FREE CAST", "FREE CAST later",
  "You drive your attack past  resistances!",
  "You nimbly dodge  attack!", "Your shield blocks  attack!",
}
for _, line in ipairs(negatives) do
  check(feed(line) == line, "unchanged: " .. line)
end
for _, case in ipairs({ positives[1], positives[6], positives[7], positives[8] }) do
  for _, line in ipairs({ "Someone says: " .. case[1], case[1] .. " extra" }) do
    check(feed(line) == line, "anchored: " .. line)
  end
end

gags.on_unload()
check(#removed == 6 and next(records) == nil, "unload removes every trigger")
for i, id in ipairs(order) do check(removed[i] == id, "removed registered id") end
gags.on_unload()
check(#removed == 6, "second unload does not remove stale ids")
check(feed("FREE CAST") == "FREE CAST", "unloaded triggers do not substitute")
gags.on_load()
check(#order == 12, "reload registers six fresh triggers")
check(feed("FREE CAST") == expected[6], "reload substitutes")
gags.on_unload()
check(#removed == 12 and next(records) == nil, "reload cleanup")
print("ALL PASS (" .. checks .. " gags checks)")
