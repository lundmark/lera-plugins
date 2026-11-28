local M = {
  name = "repeat_last_command",
  version = "1.0",
}

function M.run(entry)
  if entry == "" then return end

  -- History can contain multiple input lines, including blank ones.
  for line in (entry .. "\n"):gmatch("(.-)\n") do
    mud.execute(line)
  end
end

return M
