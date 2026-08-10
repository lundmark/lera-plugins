local M = {}
M.name = "sample"

function M.on_load()
  store.load()
  alias.add("^sample$", function() mud.send("sample") end)
  trigger.add("^line$", function() end)
  timer.every(1000, function() end)
  mip.on("ABC", function() end)
  plugin.get("dependency")
end

function M.render(rect)
  ui.text(rect, "sample")
end

return M
