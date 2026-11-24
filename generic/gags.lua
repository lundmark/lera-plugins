-- Compact combat feedback ported from the legacy General plugin.
-- The noisy MUD line is replaced in place by a short status line.

local M = {}
M.name = "gags"
M.version = "1.1"
M.priority = 20

local function colour(text, r, g, b)
  return string.format("\27[38;2;%d;%d;%dm%s\27[0m", r, g, b, text)
end

local penetrate = colour("You penetrate.", 0, 255, 255)
local critical = colour("You critically hit.", 0, 255, 255)
local strike_again = colour("You strike again.", 0, 255, 255)
local dodge = colour("You dodge.", 51, 204, 204)
local block = colour("You block.", 51, 204, 204)
local free_cast = colour("Free Cast.", 0, 255, 255)

function M.on_line(line)
  local plain = line or ""
  if plain:find("\27[", 1, true) then
    plain = plain:gsub("\27%[[0-9;?]*[ -/]*[@-~]", "")
  end

  -- Attack feedback (legacy BriefedAttacks == 0 style).
  if plain:match("^You drive your attack past .+ resistances!$") then
    return penetrate
  end
  if plain:find("You critically hit ", 1, true) then
    return critical
  end
  if plain == "Your great speed allows you to attack again!" then
    return strike_again
  end

  -- Defense feedback (legacy BriefedDefense == 0 style).
  if plain:match("^You nimbly dodge .+ attack!$") then
    return dodge
  end
  if plain:match("^Your shield blocks .+ attack!$") then
    return block
  end

  if plain:find("FREE CAST", 1, true) then
    return free_cast
  end

  return line
end

return M
