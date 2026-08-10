local M = {}
M.name = "sample_plugin"

function M.on_load()
  store.load()
  local data = store.get() or {}
  store.set({ count = (data.count or 0) + 1 })
  store.save()
  local dependency = assert(plugin.get("declared_dep"))
  assert(dependency.value == "ready")
  alias.add("^sample$", function(_, value)
    mud.send("alias " .. value)
    return "alias:" .. value
  end)
  timer.every(1000, function()
    mud.send("tick")
  end)
end

function M.emit(value)
  mud.send("emit " .. value)
  push.send("push " .. value)
  ipc.broadcast({ value = value })
  ui.text({}, value)
  print("printed " .. value)
  return "done:" .. value
end

return M
