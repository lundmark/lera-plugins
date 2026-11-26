-- Compact combat feedback ported from the legacy General plugin.
-- The noisy MUD line is replaced in place by a short status line.

local M = {}
M.name = "gags"
M.version = "1.2"
M.priority = 20

local trigger_ids = {}

local function colour(text, r, g, b)
  return string.format("\27[38;2;%d;%d;%dm%s\27[0m", r, g, b, text)
end

-- PCRE2 patterns see ANSI-stripped text supplied by the trigger engine.
-- Keep the legacy precedence: the first substitution wins.
local gags = {
  { "^You drive your attack past .+ resistances!$", colour("You penetrate.", 0, 255, 255) },
  { "^(?:Combat: )?You critically hit .+$", colour("You critically hit.", 0, 255, 255) },
  { "^Your great speed allows you to attack again!$", colour("You strike again.", 0, 255, 255) },
  { "^You nimbly dodge .+ attack!$", colour("You dodge.", 51, 204, 204) },
  { "^Your shield blocks .+ attack!$", colour("You block.", 51, 204, 204) },
  -- No game transcript is available here; accept only the standalone status
  -- FREE CAST, so help/chat sentences mentioning it remain visible.
  { "^FREE CAST$", colour("Free Cast.", 0, 255, 255) },
}

function M.on_load()
  for _, gag in ipairs(gags) do
    local replacement = gag[2]
    trigger_ids[#trigger_ids + 1] = trigger.add(gag[1], function()
      return replacement
    end, { substitute = true })
  end
end

function M.on_unload()
  for _, id in ipairs(trigger_ids) do
    trigger.remove(id)
  end
  trigger_ids = {}
end

return M
