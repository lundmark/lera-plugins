-- Compact combat feedback ported from the legacy General plugin.
-- The noisy MUD line is replaced in place by a short status line.

local M = {}
M.name = "gags"
M.version = "1.1"
M.priority = 20

local function strip_ansi(line)
  return (line or ""):gsub("\27%[[0-9;?]*[ -/]*[@-~]", "")
end

local function colour(text, r, g, b)
  return string.format("\27[38;2;%d;%d;%dm%s\27[0m", r, g, b, text)
end

function M.on_line(line)
  local plain = strip_ansi(line)

  -- Attack feedback (legacy BriefedAttacks == 0 style).
  if plain:match("^You drive your attack past .+ resistances!$") then
    return colour("You penetrate.", 0, 255, 255)
  end
  if plain:match("^.*You critically hit .*$") then
    return colour("You critically hit.", 0, 255, 255)
  end
  if plain:match("^Your great speed allows you to attack again!$") then
    return colour("You strike again.", 0, 255, 255)
  end

  -- Defense feedback (legacy BriefedDefense == 0 style).
  if plain:match("^You nimbly dodge .+ attack!$") then
    return colour("You dodge.", 51, 204, 204)
  end
  if plain:match("^Your shield blocks .+ attack!$") then
    return colour("You block.", 51, 204, 204)
  end

  if plain:find("FREE CAST", 1, true) then
    return colour("Free Cast.", 0, 255, 255)
  end

  return line
end

return M
