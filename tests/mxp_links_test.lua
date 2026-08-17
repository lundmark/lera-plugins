-- mxp_links unit tests. Run from the lera-plugins repo root with LERA_ROOT
-- pointing at a built Lera checkout.
--
-- mxp_links makes MXP <send>/<a> links reachable without a mouse: it gathers
-- links from recent output lines and opens a popup menu to fire one. It must
-- never register a keybinding itself (bind.* is outside the plugin sandbox).
package.path = "generic/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- ---- stubs ------------------------------------------------------------------
local stored_data = nil
store = {
  load = function() end,
  get = function() return stored_data end,
  set = function(d) stored_data = d end,
  save = function() end,
}

-- lines[n] holds the links on the nth-newest visible line, mirroring
-- mxp.links(n). Out-of-range n yields an empty table, as the C API does.
local lines = {}
local mxp_on = true
local on_link_cb
mxp = {
  enabled = function() return mxp_on end,
  links = function(n) return lines[n] or {} end,
  on_link = function(fn) on_link_cb = fn return 1 end,
  remove_link_handler = function() return true end,
}

local sent = {}
mud = { send = function(t) sent[#sent + 1] = t end }

local input_text
input = { set_text = function(t) input_text = t end }

local clipboard_writes = {}
local clipboard_ok = true
clipboard = {
  write = function(t)
    if not clipboard_ok then error("clipboard unavailable") end
    clipboard_writes[#clipboard_writes + 1] = t
    return true
  end,
}

local printed = {}
buffer = {
  color_print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do
      local v = select(i, ...)
      if type(v) == "string" then parts[#parts + 1] = v end
    end
    printed[#printed + 1] = table.concat(parts)
  end,
}

local function output()
  return table.concat(printed, "\n")
end

-- The popup menu: record what the plugin asked to open.
local opened
local menu_stub = {
  open = function(spec) opened = spec end,
  close = function() opened = nil end,
  is_open = function() return opened ~= nil end,
}

-- Command registry, owner-scoped like the plugin facade.
local registered = {}
local unregistered = {}
local command_stub = {
  register = function(spec)
    registered[#registered + 1] = spec
    return #registered
  end,
  unregister = function(id)
    unregistered[#unregistered + 1] = id
    return true
  end,
}

local real_require = require
require = function(name)
  if name == "menu" then return menu_stub end
  if name == "command" then return command_stub end
  return real_require(name)
end

local links = require("mxp_links")

local function reset()
  lines, sent, printed, clipboard_writes = {}, {}, {}, {}
  input_text, opened = nil, nil
  mxp_on, clipboard_ok = true, true
end

local function link(kind, text, value, extra)
  local l = { kind = kind, text = text, value = value, hint = "", prompt = false, line = 1 }
  for k, v in pairs(extra or {}) do l[k] = v end
  return l
end

-- ---- collecting -------------------------------------------------------------
reset()
lines[1] = { link("send", "north", "north") }
lines[3] = { link("send", "south", "south"), link("url", "site", "https://x.example") }
local got = links.collect()
check("collect_finds_all_links", #got == 3, "#=" .. #got)
check("collect_is_newest_first", got[1].text == "north" and got[2].text == "south",
      got[1].text .. "," .. got[2].text)
check("collect_preserves_kind", got[3].kind == "url", got[3].kind)
check("count_matches_collect", links.count() == 3, links.count())

reset()
-- Every room repeats its exits; identical links must collapse to one row.
for n = 1, 10 do lines[n] = { link("send", "north", "north") } end
check("collect_dedupes_identical", #links.collect() == 1, #links.collect())

reset()
-- Same label, different command: genuinely distinct, must both survive.
lines[1] = { link("send", "go", "north"), link("send", "go", "south") }
check("collect_keeps_same_label_different_value", #links.collect() == 2)

reset()
lines[1] = { link("send", "empty", "") }
check("collect_skips_empty_value", #links.collect() == 0)

reset()
-- Beyond scan_lines must not be gathered.
links.configure({ scan_lines = 3 })
lines[2] = { link("send", "near", "near") }
lines[9] = { link("send", "far", "far") }
got = links.collect()
check("collect_honours_scan_lines", #got == 1 and got[1].text == "near",
      "#=" .. #got)
links.configure({ scan_lines = 40 })

reset()
links.configure({ max_items = 2 })
for n = 1, 5 do lines[n] = { link("send", "exit" .. n, "exit" .. n) } end
check("collect_honours_max_items", #links.collect() == 2, #links.collect())
links.configure({ max_items = 60 })

-- ---- firing -----------------------------------------------------------------
reset()
check("fire_send_uses_mud_send",
      links.fire(link("send", "north", "north")) and sent[1] == "north", sent[1])

reset()
links.fire(link("send", "pw", "secret", { prompt = true }))
check("fire_prompt_fills_input_line", input_text == "secret" and #sent == 0, input_text)

reset()
links.fire(link("url", "site", "https://x.example"))
check("fire_url_does_not_send", #sent == 0)
check("fire_url_prints_it", output():find("https://x.example", 1, true) ~= nil, output())
check("fire_url_copies_when_possible", clipboard_writes[1] == "https://x.example")

reset()
clipboard_ok = false
local ok = links.fire(link("url", "site", "https://x.example"))
check("fire_url_survives_clipboard_failure", ok and output():find("x.example", 1, true))

reset()
check("fire_rejects_non_table", links.fire("north") == false)
check("fire_rejects_missing_value", links.fire({ kind = "send" }) == false)

reset()
lines[1] = { link("send", "a", "a"), link("send", "b", "b") }
check("fire_index_fires_nth", links.fire_index(2) and sent[1] == "b", sent[1])
reset()
lines[1] = { link("send", "a", "a") }
check("fire_index_rejects_out_of_range", links.fire_index(9) == false)
check("fire_index_rejects_garbage", links.fire_index("x") == false)

-- ---- picker -----------------------------------------------------------------
reset()
check("open_returns_false_with_no_links", links.open() == false)
check("open_explains_when_no_links", output():find("no MXP links", 1, true) ~= nil, output())

reset()
mxp_on = false
links.open()
check("open_explains_when_mxp_inactive",
      output():find("MXP is not active", 1, true) ~= nil, output())

reset()
lines[1] = { link("send", "north", "north"), link("send", "Door", "open door", { hint = "creaky" }) }
check("open_returns_true_with_links", links.open() == true)
check("open_passes_items", opened and #opened.items == 2, opened and #opened.items)
check("open_labels_plain_link_by_text", opened.items[1].label == "north", opened.items[1].label)
check("open_label_shows_differing_command",
      opened.items[2].label:find("Door", 1, true) and opened.items[2].label:find("open door", 1, true),
      opened.items[2].label)
check("open_search_includes_hint",
      opened.items[2].search:find("creaky", 1, true) ~= nil, opened.items[2].search)
check("open_provides_on_select", type(opened.on_select) == "function")

-- Selecting a row must fire the link that row referred to.
opened.on_select(opened.items[2].value)
check("select_fires_chosen_link", sent[1] == "open door", sent[1])

reset()
lines[1] = { link("send", "north", "north") }
links.configure({ show_value = false })
links.open()
check("show_value_false_hides_command", opened.items[1].label == "north", opened.items[1].label)
links.configure({ show_value = true })

reset()
lines[1] = { link("send", "pw", "secret", { prompt = true }) }
links.open()
check("prompt_link_marked_in_label",
      opened.items[1].label:find("[prompt]", 1, true) ~= nil, opened.items[1].label)

-- ---- command registration ---------------------------------------------------
reset()
links.on_load()
local spec = registered[1]
check("registers_a_command", spec ~= nil)
check("command_is_slash_link", spec and spec.name == "/link", spec and spec.name)
check("command_accepts_args", spec and spec.accepts_args == true)
check("command_has_summary", spec and type(spec.summary) == "string" and #spec.summary > 0)

reset()
lines[1] = { link("send", "a", "a"), link("send", "b", "b") }
spec.handler("2")
check("command_with_number_fires_directly", sent[1] == "b" and opened == nil, sent[1])

reset()
lines[1] = { link("send", "a", "a") }
spec.handler(nil)
check("command_without_args_opens_picker", opened ~= nil and #sent == 0)

reset()
lines[1] = { link("send", "a", "a") }
spec.handler("  3  ")
check("command_reports_missing_index", output():find("no link 3", 1, true) ~= nil, output())

-- ---- persistence ------------------------------------------------------------
reset()
links.configure({ scan_lines = 12, title = "Go" })
links.on_unload()
check("unload_persists_config",
      stored_data and stored_data.scan_lines == 12 and stored_data.title == "Go",
      stored_data and tostring(stored_data.scan_lines))
check("unload_unregisters_command", #unregistered > 0)

stored_data = { scan_lines = 7, max_items = 9, show_value = false, title = "L" }
links.on_load()
local cfg = links.get_config()
check("load_restores_config",
      cfg.scan_lines == 7 and cfg.max_items == 9 and cfg.show_value == false and cfg.title == "L",
      cfg.scan_lines .. "/" .. cfg.max_items .. "/" .. tostring(cfg.show_value))

check("configure_rejects_non_table", type(links.configure("x")) == "table")
check("configure_clamps_scan_lines", links.configure({ scan_lines = 0 }).scan_lines >= 1)

-- ---- session link stats -----------------------------------------------------
-- A profile status line wants "how many links has this session seen", which
-- collect() cannot answer: it only sees the lines still in scrollback.
reset()
links.on_load()
check("subscribes to on_link", type(on_link_cb) == "function")
links.reset_stats()
check("stats start at zero", links.stats().total == 0, links.stats().total)
if type(on_link_cb) == "function" then
  on_link_cb(link("send", "north", "north"))
  on_link_cb(link("url", "site", "https://x.example"))
  check("stats count every link", links.stats().total == 2, links.stats().total)
  -- Duplicates are collapsed for display, but the session total counts them all.
  on_link_cb(link("send", "north", "north"))
  check("stats count duplicates too", links.stats().total == 3, links.stats().total)
  check("stats survive a malformed link",
        pcall(on_link_cb, nil) and links.stats().total >= 3, links.stats().total)
end

-- ---- sandbox discipline -----------------------------------------------------
-- bind.* is not exposed to plugins; registering a key here would raise at load
-- time on a real client. The profile owns the keybinding.
check("plugin_never_touches_bind", rawget(_G, "bind") == nil)

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
