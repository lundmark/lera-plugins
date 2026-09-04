-- Hide blank output lines while keeping them in the scrollback buffer.
-- Lines containing only whitespace or ANSI control sequences are hidden.

local M = {}
M.name = "hide_blank_lines"
M.version = "1.0"

-- Strip CSI escape sequences before deciding whether a line has visible text.
local function visible_text(line)
  return (line or ""):gsub("\27%[[0-9;?]*[ -/]*[@-~]", "")
end

function M.on_line(line)
  if visible_text(line):match("^%s*$") then
    return nil
  end
  return line
end

return M
