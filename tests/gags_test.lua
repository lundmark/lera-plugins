local gags = dofile("generic/gags.lua")

local function cyan(text)
  return "\27[38;2;0;255;255m" .. text .. "\27[0m"
end

local function defense(text)
  return "\27[38;2;51;204;204m" .. text .. "\27[0m"
end

local ordinary = "\27[32mOrdinary output.\27[0m"
local cases = {
  { ordinary, ordinary },
  { "You critically hit", "You critically hit" },
  { "Combat: You cri\27[31mtically hit the guard.\27[0m", cyan("You critically hit.") },
  { "You drive your attack past You critically hit the guard's resistances!", cyan("You penetrate.") },
  { "Your great speed allows you to attack again!", cyan("You strike again.") },
  { "You nimbly dodge a fierce attack!", defense("You dodge.") },
  { "Your shield blocks the attack!", defense("You block.") },
  { "The spell prompt says FREE CAST", cyan("Free Cast.") },
}

for _, case in ipairs(cases) do
  assert(gags.on_line(case[1]) == case[2], case[1])
end
assert(gags.on_line(nil) == nil)
print("gags_test: PASS")
