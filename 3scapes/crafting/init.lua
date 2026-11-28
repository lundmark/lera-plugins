-- Crafting plugin: /craft opens a tabbed popup window over the Craft.* GMCP
-- namespace (Info/Skills/Buildings/Jobs/Recipes/Market), mirroring how
-- guild_viking's popups work for the viking guild. See
-- players/skuggis/crafting/doc/GMCP.md and include/gmcp.h in the mudlib repo
-- for the wire schema this reads.

local M = {}
M.name = "crafting"
M.version = "1.0"
M.priority = 50
M.window_launcher = { label = "Crafting", compact_label = "Craft", order = 40 }

local protocol = require("protocol")
local state = require("state")
local window = require("window")

local popup_open = false
local timer_id = nil
local auto_read = false
local scroll_notice

local function open_popup()
  -- wm.popup.open() itself displaces whatever popup (anyone's) is currently
  -- shown and fires its on_close first, so no manual close-before-open here.
  local wm = require("wm")
  wm.popup.open(window, {
    title = "Crafting",
    width = 0.7,
    height = 0.65,
    on_close = function()
      popup_open = false
      window.reset_actions()
    end,
  })
  popup_open = true
end

local function close_popup()
  local wm = require("wm")
  if popup_open and wm.popup.is_open() then wm.popup.close() end
  popup_open = false
end

local function toggle_popup()
  local wm = require("wm")
  if popup_open and wm.popup.is_open() then
    wm.popup.close()
    popup_open = false
  else
    open_popup()
  end
end

function M.is_open() return popup_open end
function M.open() if not popup_open then open_popup() end end
function M.close() close_popup() end
function M.toggle() toggle_popup() end

local function line(text) buffer.color_print(nil, nil, text) end
local function head(text) buffer.color_print(nil, "FFAA00", text) end

-- Diagnostic for tracking down GMCP delivery problems: shows what actually
-- arrived (frame counters, last-seen per sub-package) and, for Recipes
-- specifically, the raw mirror keys -- so "recipes_chaos" being present or
-- absent tells us directly whether this is a receipt problem or a
-- projection problem in state.lua, without guessing.
local function show_status()
  local c = protocol.counters()
  head("Craft.* protocol status")
  line(string.format("  frames %d, applied %d, bad package %d, bad payload %d",
    c.frames, c.applied, c.bad_package, c.bad_payload))
  for _, sub in ipairs({ "Info", "State", "Skills", "Buildings", "Jobs", "Recipes", "Market" }) do
    local at = protocol.seen(sub)
    line(string.format("  %-10s %s", sub,
      at and (math.floor(lera.time() - at) .. "s ago") or "not received this connection"))
  end
  local mirror = protocol.mirror("Recipes")
  if not mirror then
    line("  Recipes mirror: nil (no frame received yet)")
  else
    local keys = {}
    for k in pairs(mirror) do keys[#keys + 1] = k end
    table.sort(keys)
    line("  Recipes mirror keys (" .. #keys .. "): " .. (next(keys) and table.concat(keys, ", ") or "(empty)"))
  end

  -- Same raw dump for Buildings -- "bldgs" (renamed from "owned", which
  -- never once survived delivery under any chunking/pacing/shape -- see
  -- gmcp.h's _cgmcp_push_buildings_step comment) showing nil in the FIELDS
  -- table below only proves that EXACT key is absent; dumping every key
  -- actually present rules out (or catches) something arriving under an
  -- unexpected/garbled name instead of silently not arriving at all.
  local bmirror = protocol.mirror("Buildings")
  if not bmirror then
    line("  Buildings mirror: nil (no frame received yet)")
  else
    local bkeys = {}
    for k in pairs(bmirror) do bkeys[#bkeys + 1] = k end
    table.sort(bkeys)
    line("  Buildings mirror keys (" .. #bkeys .. "): " .. (next(bkeys) and table.concat(bkeys, ", ") or "(empty)"))
  end

  -- The raw mirror dump below only ever shows the FIRST chunk of a
  -- numbered-key field (e.g. "materials") -- state.lua's collect_rows()
  -- is what actually combines materials/materials_1/materials_2/... into
  -- what pages/inventory.lua reads, so THIS is the count that matters.
  local rec = state.get()
  line("  state.materials (reconstructed total): " .. #rec.materials)
  local ms = protocol.materials_stage_debug()
  line(string.format("  materials staging: gen=%s expected=%s have=%d",
    tostring(ms.gen), tostring(ms.expected), ms.have))
  line("  materials staged chunk sizes: " .. (ms.sizes ~= "" and ms.sizes or "(none)"))
  local sm2 = protocol.mirror("State")
  if sm2 then
    local mat_keys = {}
    for k in pairs(sm2) do
      if k == "materials" or k:match("^materials_%d+$") then mat_keys[#mat_keys + 1] = k end
    end
    table.sort(mat_keys)
    line("  State materials chunk keys (" .. #mat_keys .. "): " .. (next(mat_keys) and table.concat(mat_keys, ", ") or "(none)"))
  end

  -- Buildings/refineries are chunked the same way materials is ("bldgs",
  -- "bldgs_1", ...) -- the raw FIELDS dump below only shows chunk 0, so the
  -- reconstructed total here is the count that actually matters.
  line("  state.buildings (reconstructed total): " .. #rec.buildings)
  line("  state.refineries (reconstructed total): " .. #rec.refineries)

  -- "applied" only proves a frame arrived under that package name -- it
  -- says nothing about whether the mapping-valued fields INSIDE it survived
  -- (State's did not, despite showing as applied). Dumping every non-Recipe
  -- package's top-level field shapes side by side is the only way to see
  -- which packages are actually intact versus just recognized.
  local function shape(v)
    if type(v) ~= "table" then return tostring(v) end
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    return "table[" .. n .. "]"
  end
  local FIELDS = {
    Info = { "realms", "standing", "soul", "storage", "bonuses" },
    State = { "souls", "soul_cap", "stock_used", "stock_cap", "soul_tiers",
      "materials", "tokens_chaos", "tokens_fantasy", "tokens_science" },
    Buildings = { "bldgs", "refineries" },
    Jobs = { "builds", "masterwork", "queues", "queue_total", "queue_cap", "ready" },
    Market = { "orders", "material_orders", "exchanges", "auctions" },
  }
  for _, sub in ipairs({ "Info", "State", "Buildings", "Jobs", "Market" }) do
    local m = protocol.mirror(sub)
    if not m then
      line("  " .. sub .. " mirror: nil (no frame received yet)")
    else
      for _, k in ipairs(FIELDS[sub]) do
        line(string.format("  %s.%-18s %s", sub, k, shape(m[k])))
      end
    end
  end
end

local CRAFT_USAGE = "/craft [overview | inventory | skills | buildings | refinery | production "
  .. "| automation | recipes [search] | market | status | autoread [on|off]]"

local function set_auto_read(value)
  if value == "on" or value == "off" then
    auto_read = value == "on"
    scroll_notice = nil
    if not (store.set({ auto_read = auto_read }) and store.save()) then
      line("[Crafting] Could not save the auto-read setting for next time.")
    end
  elseif value ~= "" then
    line("Usage: /craft autoread [on|off]")
    return
  end
  line("[Crafting] Recipe scroll auto-read is " .. (auto_read and "on." or "off."))
end

local function dispatch(args)
  local word = tostring(args or ""):match("^%s*(%S*)"):lower()
  if word == "overview" then word = "info" end
  if word == "production" then word = "jobs" end
  if word == "" then
    toggle_popup()
    return
  end
  if word == "status" then
    show_status()
    return
  end
  if word == "autoread" then
    set_auto_read(args:match("^%s*%S+%s*(.-)%s*$"):lower())
    return
  end
  for _, p in ipairs(window.PAGES) do
    if p.key == word then
      if not popup_open then open_popup() end
      window.set_page(word)
      local search = tostring(args or ""):match("^%s*%S+%s+(.+)")
      if word == "recipes" and search then
        p.mod.search(search)
        window.scroll_to_top()
      end
      return
    end
  end
  buffer.color_print(nil, "DAA520", "Usage: " .. CRAFT_USAGE)
end

local command_id = nil

local function install_command()
  local command = require("command")
  local id, err = command.register({
    name = "/craft",
    usage = CRAFT_USAGE,
    summary = "Crafting state from the Craft.* GMCP namespace",
    description = "Opens (or closes) the crafting window. A page name opens "
      .. "straight to that tab. Skills offers training, and Production shows "
      .. "buildings, queues, available recipes, and finished items. Automation "
      .. "manages repeat recipes, material reserves, and automatic collection. "
      .. "Use /craft autoread on to learn newly dropped recipe scrolls automatically.",
    accepts_args = true,
    handler = function(args) dispatch(args) end,
  })
  if id then
    command_id = id
  else
    print("[crafting] command registration failed: " .. tostring(err))
  end
end

local function uninstall_command()
  if not command_id then return end
  local command = require("command")
  command.unregister(command_id)
  command_id = nil
end

local DROP_START = "Something glints among the remains --"
local DROP_LEAD = "Something glints"
local DROP_END = " recipe scroll! You tuck it away; it is bound to you."
local DROP_LIMIT = 200

-- The server can wrap the notice through the recipe name or the delivery
-- confirmation. Wait for the complete notice before sending a targeted read.
function M.on_line(raw)
  if not scroll_notice and not raw:find(DROP_LEAD, 1, true) then return raw end

  local plain = raw:gsub("\27%[[0-9;?]*[ -/]*[@-~]", ""):match("^%s*(.-)%s*$")
  if plain:sub(1, #DROP_LEAD) == DROP_LEAD then
    scroll_notice = plain
  elseif scroll_notice and plain ~= "" then
    scroll_notice = scroll_notice .. " " .. plain
  else
    scroll_notice = nil
  end

  if not scroll_notice then return raw end
  if #scroll_notice > DROP_LIMIT then
    scroll_notice = nil
    return raw
  end
  if scroll_notice:sub(-#DROP_END) ~= DROP_END then return raw end

  local name
  if scroll_notice:sub(1, #DROP_START) == DROP_START then
    name = scroll_notice:sub(#DROP_START + 1, -#DROP_END - 1):match("^ an? (.+)$")
  end
  scroll_notice = nil
  if name and name:match("^[%w][%w .'&(),%-]*$") then
    local command = "read " .. name .. " scroll"
    if not auto_read or not mud.send(command) then
      buffer.color_print(nil, "FFFFFF", "[Crafting] Recipe scroll dropped: " .. name
        .. " (" .. command .. ")")
    end
  end
  return raw
end

function M.on_load()
  store.load()
  local saved = store.get()
  auto_read = type(saved) == "table" and saved.auto_read == true

  protocol.on_apply(function(sub, mirror)
    state.apply(sub, mirror)
    if popup_open then ui.dirty() end
  end)
  protocol.subscribe()
  install_command()

  -- Refresh live countdowns between GMCP frames.
  timer_id = timer.every(1000, function()
    if popup_open then window.countdown_tick() end
  end)
end

function M.on_disconnect()
  -- The server clears its GMCP namespace cache on disconnect, so retained
  -- mirrors would no longer be congruent with it.
  protocol.reset_connection()
  state.reset()
  scroll_notice = nil
  close_popup()
end

function M.on_unload()
  scroll_notice = nil
  if timer_id then timer.cancel(timer_id); timer_id = nil end
  close_popup()
  uninstall_command()
  protocol.unsubscribe()
end

return M
