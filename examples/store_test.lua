-- Store test plugin for Lera
-- Tests the persistent storage functionality
local M = {}

M.name = "store_test"
M.version = "1.0"

-- Default settings
local defaults = {
  counter = 0,
  last_run = "never",
  items = {}
}

local settings = {}

function M.on_load()
  print("[store_test] Loading...")

  -- Load saved data from disk first
  store.load()
  local data = store.get()
  if data then
    print("[store_test] Loaded saved data")
    settings = data.settings or defaults
    print("[store_test] Counter was: " .. settings.counter)
  else
    print("[store_test] No saved data, using defaults")
    settings = defaults
  end

  -- Increment counter
  settings.counter = settings.counter + 1
  settings.last_run = "now"
  print("[store_test] Counter is now: " .. settings.counter)

  -- Show storage path
  local path = store.path()
  if path then
    print("[store_test] Storage dir: " .. path)
  end
end

function M.on_unload()
  print("[store_test] Saving data...")

  -- Save our settings
  store.set({ settings = settings })
  local ok = store.save()

  if ok then
    print("[store_test] Data saved successfully")
  else
    print("[store_test] Failed to save data!")
  end
end

-- Add an item (for testing)
function M.add_item(name)
  table.insert(settings.items, name)
  print("[store_test] Added item: " .. name)
end

-- List items
function M.list_items()
  print("[store_test] Items:")
  for i, item in ipairs(settings.items) do
    print("  " .. i .. ": " .. item)
  end
end

-- Get current settings
function M.get_settings()
  return settings
end

return M
