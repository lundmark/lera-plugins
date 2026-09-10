-- chat_monitor unit tests. Run from the lera-plugins repo root with LERA_ROOT
-- pointing at a built Lera checkout.
local lera_root = assert(os.getenv("LERA_ROOT"), "LERA_ROOT is required")
lera_root = lera_root:gsub("/+$", "")
package.path = "3scapes/?.lua;" .. lera_root .. "/scripts/default/?.lua;" .. package.path

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
local drawn = {}   -- rows painted by the last render: {y -> text}
ui = {
  dirty = function() end,
  box = function() end,
  text = function() end,
  rect = function(x, y, w, h) return { x = x, y = y, w = w, h = h } end,
  text_ansi = function(rect, text) drawn[rect.y] = text end,
  on_render = function() end,
  on_mouse_wheel = function() end,
}
-- Stateful, so a save/load round trip can be exercised: starts empty, which is
-- what the initial on_load below sees.
local stored_chat = nil
local store_writes = 0
store = {
  load = function() end,
  get = function() return stored_chat end,
  set = function(data) stored_chat = data; store_writes = store_writes + 1 end,
  save = function() store_writes = store_writes + 1 end,
}
trigger = {
  add = function() return 1 end,
  remove = function() end,
}
trigger = {
  add = function() return 1 end,
  remove = function() end,
}
local mip_handlers = {}
mip = {
  on = function(code, fn) mip_handlers[code] = fn; return code end,
  off = function() end,
}
local gmcp_handlers = {}
gmcp = {
  on = function(package, fn) gmcp_handlers[package] = fn; return package end,
  remove = function() return true end,
}

-- Command registry stub, matching the real one: the handler is called with
-- everything after the command name.
local registered = {}
local command_stub = {
  register = function(spec) registered[#registered + 1] = spec return #registered end,
  unregister = function() return true end,
  get = function(name)
    for _, spec in ipairs(registered) do
      if spec.name == name then return { name = spec.name } end
    end
    return nil
  end,
}
local real_require = require
require = function(name)
  if name == "command" then return command_stub end
  return real_require(name)
end
buffer = {
  scroll_offset = function() return 0 end,
  set_scroll_offset = function() end,
  following_tail = function() return true end,
}
local render_pass = "local"
lera = { render_pass = function() return render_pass end, display = function() return "tty" end }
-- wm requires menu, which registers its Up/Down/Enter/cancel binds at module
-- load time, so bind must exist before the require below.
bind = {
  add = function() return 1 end,
  remove = function() return true end,
  enable = function() return true end,
  count = function() return 0 end,
}

local chat = require("chat_monitor")
chat.on_load()

local function send_chat(sender, text)
  mip_handlers["CAA"]("k", "CAA", "gossip~Gossip~" .. sender .. "~" .. text)
end

-- Comm.Channel.Text exactly as 3K sends it.
local function send_gmcp(channel, talker, text, package)
  gmcp_handlers["Comm"](package or "Comm.Channel.Text",
    { channel = channel, talker = talker, text = text })
end

-- Rendered rows carry SGR codes now: the lead-in runs in the line type's colour
-- and the body in the text colour, so an assertion about wording has to look at
-- the plain text.
local function plain(row)
  if type(row) ~= "string" then return nil end
  return (row:gsub("\027%[[%d;]*m", ""))
end

local function spec_for(name)
  for _, spec in ipairs(registered) do
    if spec.name == name then return spec end
  end
  return nil
end

local RECT = { x = 0, y = 0, w = 40, h = 5 }   -- borderless: 40x5 content
local function render_at(rect)
  drawn = {}
  chat.render(rect, { show_border = false })
  return drawn
end
local function render()
  return render_at(RECT)
end

-- ---- at tail: newest at the bottom -------------------------------------------
for i = 1, 10 do send_chat("Bob", "message " .. i) end
local rows = render()
check("tail_shows_newest", rows[4] and rows[4]:find("message 10", 1, true) ~= nil,
      rows[4])
check("starts_following_tail", chat.following_tail())

-- ---- line-type formatting updates invalidate cached local rows ----------------
check("set_color_accepts_public_chat_type", chat.set_color("chat_gossip", "red"))
local recolored_local = render()
render_pass = "remote"
local recolored_remote = render()
render_pass = "local"
check("set_color_updates_cached_local_row",
      recolored_local[4] and recolored_local[4]:find("\027[31m", 1, true) == 1,
      recolored_local[4])
check("set_color_keeps_local_remote_rows_equal",
      recolored_local[4] == recolored_remote[4],
      tostring(recolored_local[4]) .. " vs " .. tostring(recolored_remote[4]))
chat.set_color("chat_gossip", "bright_cyan")
render()

-- ---- scrolled back: view holds when messages arrive ---------------------------
chat.scroll(-2)
render()
local held = render()[4]
check("scrolled_back", not chat.following_tail())

check("scrolled_set_color_accepts_public_chat_type",
      chat.set_color("chat_gossip", "yellow"))
local styled_held = render()[4]
local held_text = held and held:gsub("\027%[[0-9;]*m", "")
local styled_held_text = styled_held and styled_held:gsub("\027%[[0-9;]*m", "")
check("format_change_preserves_scrolled_state", not chat.following_tail())
check("format_change_preserves_scrolled_viewport",
      styled_held_text == held_text,
      tostring(styled_held_text) .. " vs " .. tostring(held_text))
check("format_change_restyles_scrolled_viewport",
      styled_held and styled_held:find("\027[33m", 1, true) == 1,
      styled_held)
chat.set_color("chat_gossip", "bright_cyan")
render()

send_chat("Bob", "message 11")
local after = render()
check("append_holds_view", after[4] == held, after[4] .. " vs " .. tostring(held))

-- ---- scroll_to_bottom resumes the tail ----------------------------------------
chat.scroll_to_bottom()
rows = render()
check("bottom_shows_message_11", rows[4]:find("message 11", 1, true) ~= nil, rows[4])
check("back_at_tail", chat.following_tail())

-- ---- wrapped rows count as scroll units ---------------------------------------
send_chat("Bob", string.rep("word ", 30))   -- wraps to several rows at w=40
local long_rows = render()
chat.scroll(-1)                              -- one wrapped ROW up, not one message
local one_up = render()
check("scroll_unit_is_wrapped_row", one_up[4] == long_rows[3],
      tostring(one_up[4]) .. " vs " .. tostring(long_rows[3]))
chat.scroll_to_bottom()

-- ---- clamping ------------------------------------------------------------------
chat.scroll(-100000)
check("clamps_to_oldest", not chat.following_tail())
chat.scroll(100000)
check("clamps_to_tail", chat.following_tail())

-- ---- trim preserves a held viewport and clamps only when necessary ------------
chat.clear()
chat.set_max_lines(8)
local TRIM_RECT = { x = 0, y = 0, w = 40, h = 2 }
for i = 1, 8 do send_chat("Bob", "trim message " .. i) end
render_at(TRIM_RECT)
chat.scroll(-2)
local trim_before = render_at(TRIM_RECT)
check("trim_starts_scrolled_back", not chat.following_tail())

chat.set_max_lines(7)  -- drops message 1, which is above the visible viewport
local trim_after = render_at(TRIM_RECT)
check("trim_preserves_visible_viewport",
      trim_after[0] == trim_before[0] and trim_after[1] == trim_before[1],
      tostring(trim_after[1]) .. " vs " .. tostring(trim_before[1]))
check("trim_preserves_scrolled_state", not chat.following_tail())

chat.scroll(-100000)
chat.set_max_lines(3)
local trim_clamped = render_at(TRIM_RECT)
check("trim_clamps_to_oldest_retained_row",
      trim_clamped[1] and trim_clamped[1]:find("trim message 6", 1, true) ~= nil,
      trim_clamped[1])
check("trim_clamp_remains_scrolled_back", not chat.following_tail())

chat.scroll_to_bottom()
local trim_tail = render_at(TRIM_RECT)
check("trim_tail_shows_retained_rows",
      trim_tail[0] and trim_tail[0]:find("trim message 7", 1, true) ~= nil and
      trim_tail[1] and trim_tail[1]:find("trim message 8", 1, true) ~= nil,
      tostring(trim_tail[0]) .. " / " .. tostring(trim_tail[1]))
check("trim_tail_resumes_following", chat.following_tail())

-- ---- remote render pass draws wrapped content at its own width ----------------
-- The render callback runs a second time per dirty frame when a WebSocket
-- client is connected, at the CLIENT screen's dimensions (which can differ
-- from the local screen). Confirm the remote pass actually renders, wrapped
-- at ITS width, not the local one.
chat.clear()
chat.set_max_lines(100)
for i = 1, 8 do send_chat("Bob", "remote isolation message " .. i) end

render()                              -- build the local cache @ w=40 first
chat.scroll(-2)                       -- ...then scroll back against it
local moderate_before = render()
local moderate_tail_before = chat.following_tail()

render_pass = "remote"
local remote_rows = render_at({ x = 0, y = 0, w = 20, h = 5 })
render_pass = "local"

local remote_has_content, remote_within_width = false, true
for _, text in pairs(remote_rows) do
  remote_has_content = true
  local stripped = text:gsub("\027%[%d*m", "")
  if #stripped > 22 then remote_within_width = false end  -- 20 + 2-space continuation indent
end
check("remote_pass_draws_wrapped_content", remote_has_content)
check("remote_pass_wraps_at_remote_width", remote_within_width)

-- The local pass afterward is unaffected: same offset, same rendered rows.
local moderate_after = render()
check("local_offset_survives_remote_pass", chat.following_tail() == moderate_tail_before)
check("local_output_survives_remote_pass",
      moderate_after[0] == moderate_before[0] and moderate_after[1] == moderate_before[1] and
      moderate_after[2] == moderate_before[2] and moderate_after[3] == moderate_before[3] and
      moderate_after[4] == moderate_before[4],
      tostring(moderate_after[4]) .. " vs " .. tostring(moderate_before[4]))

chat.scroll_to_bottom()

-- ---- remote render pass must not yank a deep local scroll position -----------
-- Use a narrow local width (many wrapped rows, so a deep scroll lands well
-- inside the buffer) and a much wider remote width (few wrapped rows). On
-- the old ungated code this combination makes wrapped_ensure()'s
-- sc.on_trim() clamp the local offset down to the (much smaller) REMOTE row
-- count, so the local view visibly jumps forward toward the tail - the
-- "yank a scrolled-back view" bug this gate exists to prevent. The remote
-- pass itself may legitimately show nothing here (the local offset can be
-- deeper than the wide remote layout has rows for) - only the local
-- before/after state is asserted.
local NARROW, WIDE = 15, 200
chat.clear()
for i = 1, 8 do
  send_chat("Bob", "this is a somewhat longer chat message number " .. i ..
                    " with extra words to force wrapping")
end

render_at({ x = 0, y = 0, w = NARROW, h = 5 })   -- build the local cache @ w=15
chat.scroll(-1000)                                -- clamp to the deepest scroll position
local deep_before = render_at({ x = 0, y = 0, w = NARROW, h = 5 })
local deep_tail_before = chat.following_tail()
check("scrolled_to_deep_offset", not deep_tail_before)

render_pass = "remote"
render_at({ x = 0, y = 0, w = WIDE, h = 5 })
render_pass = "local"

-- (This is the assertion that fails without the render_pass gate: the
-- remote-width rebuild re-clamps the local offset against the wrong count.)
local deep_after = render_at({ x = 0, y = 0, w = NARROW, h = 5 })
check("deep_offset_survives_remote_pass", chat.following_tail() == deep_tail_before)
check("deep_output_survives_remote_pass",
      deep_after[0] == deep_before[0] and deep_after[1] == deep_before[1] and
      deep_after[2] == deep_before[2] and deep_after[3] == deep_before[3] and
      deep_after[4] == deep_before[4],
      tostring(deep_after[4]) .. " vs " .. tostring(deep_before[4]))

chat.scroll_to_bottom()

-- ---- width-change rebuild (local pass) ----------------------------------------
chat.clear()
for i = 1, 8 do send_chat("Bob", "width rebuild message " .. i) end
render()                              -- build local cache @ w=40
chat.scroll(-3)
check("scrolled_back_before_width_change", not chat.following_tail())

local ok_render = pcall(render_at, { x = 0, y = 0, w = 25, h = 5 })
check("width_change_local_render_no_crash", ok_render)

chat.scroll_to_bottom()
local bottom_rows = render_at({ x = 0, y = 0, w = 25, h = 5 })
local found_newest = false
for _, text in pairs(bottom_rows) do
  if text:find("message 8", 1, true) then found_newest = true end
end
check("width_change_newest_reachable", found_newest)
check("width_change_back_at_tail", chat.following_tail())

-- ---- push_notify producer wiring ----------------------------------------------
local push_calls = {}
local registered = {}
local fake_pushn = {
  register_channel = function(name, opts) registered[name] = opts or {} end,
  notify = function(channel, text) push_calls[#push_calls + 1] = { channel = channel, text = text } end,
}
plugin = { get = function(name) if name == "push_notify" then return fake_pushn end end }
chat.on_setup()
check("setup_registers_tells_channel", registered.tells and registered.tells.priority == 1)

mip_handlers["BAB"]("k", "BAB", "~Bob~hi there")
check("incoming_tell_notifies", push_calls[1] and push_calls[1].channel == "tells",
      push_calls[1] and push_calls[1].channel)
check("tell_notify_uses_display_format", push_calls[1] and push_calls[1].text == "[Bob] hi there",
      push_calls[1] and push_calls[1].text)

push_calls = {}
mip_handlers["BAB"]("k", "BAB", "x~Bob~hi back")
check("outgoing_tell_does_not_notify", #push_calls == 0, push_calls[1] and push_calls[1].text)

mip_handlers["BAG"]("k", "BAG", "x~Ann~waves at you")
check("incoming_emote_notifies", push_calls[1] and push_calls[1].channel == "emotes",
      push_calls[1] and push_calls[1].channel)

push_calls = {}
mip_handlers["BAG"]("k", "BAG", "~Me~wave back")
check("outgoing_emote_does_not_notify", #push_calls == 0, push_calls[1] and push_calls[1].text)

send_chat("Ann", "hello everyone")
check("chat_line_notifies_by_command", push_calls[1] and push_calls[1].channel == "gossip",
      push_calls[1] and push_calls[1].channel)

push_calls = {}
chat.add_gag("tell_in", "Spammer")
mip_handlers["BAB"]("k", "BAB", "~Spammer~buy gold")
check("gagged_message_does_not_notify", #push_calls == 0, push_calls[1] and push_calls[1].text)

-- ---- timestamp color ------------------------------------------------------------
local ts_enabled, ts_format, ts_color = chat.timestamps()
check("timestamp_color_defaults_white", ts_color == "white", ts_color)

chat.clear()
chat.set_max_lines(100)
send_chat("Bob", "stamp color message")
rows = render()
-- draw_row wraps the row in the type color (chat_gossip = bright_cyan), then
-- the stamp runs in the timestamp color and switches back to the type color.
local stamped = rows[4]
check("stamp_rendered_in_timestamp_color",
      stamped and stamped:match("^\027%[96m\027%[37m%[%d%d:%d%d%] \027%[96mstamp color message") ~= nil,
      stamped)

-- remote pass renders the stamp identically (shared wrap_msg)
render_pass = "remote"
local stamped_remote = render()[4]
render_pass = "local"
check("stamp_color_matches_on_remote_pass", stamped_remote == stamped,
      tostring(stamped_remote) .. " vs " .. tostring(stamped))

chat.set_timestamps(true, "%H:%M", "yellow")
local restamped = render()[4]
check("stamp_color_configurable",
      restamped and restamped:match("^\027%[96m\027%[33m%[%d%d:%d%d%] \027%[96m") ~= nil,
      restamped)
check("timestamps_returns_color", select(3, chat.timestamps()) == "yellow")
chat.set_timestamps(true, "%H:%M", "white")

-- ---- GMCP source -------------------------------------------------------------
-- The observed 3K payload: Comm.Channel.Text {channel="wiz", talker="Simon",
-- text="test"}. The channel name is used as sent, so it lands on the same type
-- ID MIP CAA would build for that channel.
local st = chat.source()
check("source_starts_on_mip", st.active == "mip", st.active)
check("source_mode_defaults_auto", st.mode == "auto", st.mode)

chat.clear()
send_gmcp("wiz", "Simon", "test")
st = chat.source()
check("gmcp_message_counted", st.gmcp_count == 1, st.gmcp_count)
check("gmcp_latches_source", st.active == "gmcp", st.active)
check("gmcp_creates_channel_type", chat.is_enabled("chat_wiz") == true)

local wiz_label
for _, item in ipairs(chat.list_types()) do
  if item.id == "chat_wiz" then wiz_label = item.label end
end
check("gmcp_labels_type_with_channel_as_sent", wiz_label == "wiz", wiz_label)

-- GMCP text is the bare body, so the talker has to be rendered or it is lost.
local grows = render()
check("gmcp_line_renders_talker", plain(grows[4]) and plain(grows[4]):find("Simon: test", 1, true) ~= nil,
      grows[4])

-- ---- the latch covers every kind of line --------------------------------------
-- GMCP Comm.Channel.Text carries channels, tells (channel "tell") and souls
-- (channel "soul"), so leaving any MIP handler live would double-print.
chat.clear()
send_chat("Bob", "should not appear")
check("mip_channel_dropped_after_latch", chat.count() == 0, chat.count())

mip_handlers["BAB"]("k", "BAB", "~Alice~a tell")
check("mip_tell_dropped_after_latch", chat.count() == 0, chat.count())
mip_handlers["BAG"]("k", "BAG", "~Alice~waves")
check("mip_emote_dropped_after_latch", chat.count() == 0, chat.count())

-- ---- pinning -----------------------------------------------------------------
check("set_source_rejects_nonsense", chat.set_source("carrier-pigeon") == false)
check("set_source_mip", chat.set_source("mip") == true)
check("pinned_mip_reports_mip", chat.source().active == "mip")

chat.clear()
send_gmcp("wiz", "Simon", "ignored while pinned to mip")
check("gmcp_ignored_when_pinned_to_mip", chat.count() == 0, chat.count())
send_chat("Bob", "mip works again")
mip_handlers["BAB"]("k", "BAB", "~Alice~a tell")
check("mip_restored_when_pinned", chat.count() == 2, chat.count())

check("set_source_gmcp", chat.set_source("gmcp") == true)
chat.clear()
send_chat("Bob", "ignored while pinned to gmcp")
mip_handlers["BAB"]("k", "BAB", "~Alice~also ignored")
mip_handlers["BAG"]("k", "BAG", "~Alice~waves")
check("mip_ignored_when_pinned_to_gmcp", chat.count() == 0, chat.count())

chat.set_source("auto")

-- ---- malformed payloads are counted, not printed ------------------------------
chat.clear()
local before_unmapped = chat.source().gmcp_unmapped
gmcp_handlers["Comm"]("Comm.Channel.List", { channels = { "wiz" } })
gmcp_handlers["Comm"]("Comm.Channel.Text", { channel = "wiz" })       -- no text
gmcp_handlers["Comm"]("Comm.Channel.Text", { text = "orphan" })       -- no channel
gmcp_handlers["Comm"]("Comm.Channel.Text", "not a table")
st = chat.source()
check("unmapped_counted", st.gmcp_unmapped == before_unmapped + 4, st.gmcp_unmapped)
check("unmapped_not_printed", chat.count() == 0, chat.count())
check("unmapped_reports_package", st.last_unmapped ~= nil and
      st.last_unmapped.package == "Comm.Channel.Text", st.last_unmapped)

-- A missing talker is not malformed; it just has nothing to prefix with.
chat.clear()
send_gmcp("wiz", nil, "anonymous")
check("missing_talker_still_delivered", chat.count() == 1, chat.count())
grows = render()
check("missing_talker_renders_text", plain(grows[4]) and plain(grows[4]):find("anonymous", 1, true) ~= nil,
      grows[4])

-- ---- tells, souls and multi-target tells --------------------------------------
-- Real 3K payloads:
--   { text="test", talker="Simon", targets={"Lennart","Simon"}, channel="tell" }
--   { text="smiles at you.", talker="Simon", channel="soul" }
chat.set_source("auto")
chat.clear()
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "soul", talker = "Simon", text = "smiles at you." })
grows = render()
check("soul_joins_with_space",
      plain(grows[4]) and plain(grows[4]):find("Simon smiles at you.", 1, true) ~= nil, grows[4])
check("soul_has_no_colon",
      plain(grows[4]) and plain(grows[4]):find("Simon: smiles", 1, true) == nil, grows[4])

chat.clear()
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "tell", talker = "Simon", text = "test",
    targets = { "Lennart", "Simon" } })
grows = render()
check("multi_tell_names_targets",
      plain(grows[4]) and plain(grows[4]):find("Simon -> Lennart: test", 1, true) ~= nil, grows[4])

-- A single target that is the talker alone adds nothing, so it is left off.
chat.clear()
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "tell", talker = "Bob", text = "hi", targets = { "Bob" } })
grows = render()
check("self_only_target_omitted",
      plain(grows[4]) and plain(grows[4]):find("Bob: hi", 1, true) ~= nil, grows[4])

-- A server-sent prefix is used verbatim, whatever the channel or targets say.
chat.clear()
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "tell", talker = "Simon", text = "test",
    targets = { "Lennart" }, prefix = "You tell Lennart: " })
grows = render()
check("server_prefix_used_verbatim",
      plain(grows[4]) and plain(grows[4]):find("You tell Lennart: test", 1, true) ~= nil, grows[4])
check("server_prefix_replaces_synthesis",
      plain(grows[4]) and plain(grows[4]):find("Simon ->", 1, true) == nil, grows[4])

-- A configured prefix applies when the server sent none...
chat.add_chatline("tell", { color = "cyan" })
check("configure_accepts_prefix", chat.configure("chat_tell", {
  prefix = function(_, who) return "<" .. tostring(who) .. "> " end,
}))
chat.clear()
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "tell", talker = "Simon", text = "test" })
grows = render()
check("configured_prefix_used_without_server_prefix",
      plain(grows[4]) and plain(grows[4]):find("<Simon> test", 1, true) ~= nil, grows[4])

-- ...but a server-sent one wins, because the same setting has to serve MIP text
-- that already carries its attribution and GMCP text that does not.
chat.clear()
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "tell", talker = "Simon", text = "test", prefix = "You tell X: " })
grows = render()
check("server_prefix_outranks_configured",
      plain(grows[4]) and plain(grows[4]):find("You tell X: test", 1, true) ~= nil, grows[4])

-- MIP messages are untouched by that rule: no server prefix exists for them.
chat.set_source("mip")
chat.clear()
mip_handlers["BAG"]("k", "BAG", "~Simon~Simon smiles at you.")
grows = render()
check("mip_emote_keeps_configured_empty_prefix",
      plain(grows[4]) and plain(grows[4]):find("Simon smiles at you.", 1, true) ~= nil, grows[4])
chat.set_source("auto")

-- ---- push routing survives the protocol change ---------------------------------
-- The point of mapping direction onto the built-in types: an incoming tell must
-- keep reaching the "tells" push channel whichever protocol delivered it, and an
-- outgoing one must still not.
push_calls = {}
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "tell", direction = "in", talker = "Bob",
    prefix = "Bob tells you: ", text = "hi there" })
check("gmcp_incoming_tell_notifies_tells_channel",
      push_calls[1] and push_calls[1].channel == "tells",
      push_calls[1] and push_calls[1].channel)
check("gmcp_tell_notify_uses_server_prefix",
      push_calls[1] and push_calls[1].text == "Bob tells you: hi there",
      push_calls[1] and push_calls[1].text)

push_calls = {}
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "tell", direction = "out", talker = "Simon",
    prefix = "You tell Bob: ", text = "hi back" })
check("gmcp_outgoing_tell_does_not_notify", #push_calls == 0,
      push_calls[1] and push_calls[1].text)

push_calls = {}
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "soul", direction = "in", talker = "Ann",
    prefix = "Ann ", text = "waves at you." })
check("gmcp_incoming_soul_notifies_emotes_channel",
      push_calls[1] and push_calls[1].channel == "emotes",
      push_calls[1] and push_calls[1].channel)

-- An undirected tell has no in/out to judge, so it lands on channel "tell" --
-- which push_notify auto-registers disabled rather than notifying blind.
push_calls = {}
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "tell", talker = "Bob", text = "undirected" })
check("undirected_tell_notifies_its_own_channel",
      push_calls[1] and push_calls[1].channel == "tell",
      push_calls[1] and push_calls[1].channel)

-- ---- direction maps onto the built-in types ------------------------------------
chat.clear()
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "tell", direction = "in", talker = "Bob",
    prefix = "Bob tells you: ", text = "hi" })
local last = chat.get_messages(1)[1]
check("incoming_tell_maps_to_tell_in", last and last.type == "tell_in",
      last and last.type)

chat.clear()
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "tell", direction = "out", talker = "Simon",
    targets = { "Lennart" }, prefix = "You tell Lennart: ", text = "test" })
last = chat.get_messages(1)[1]
check("outgoing_tell_maps_to_tell_out", last and last.type == "tell_out",
      last and last.type)

chat.clear()
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "soul", direction = "in", talker = "Bob",
    prefix = "Bob ", text = "smiles at you." })
last = chat.get_messages(1)[1]
check("incoming_soul_maps_to_emote_in", last and last.type == "emote_in",
      last and last.type)

chat.clear()
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "SOUL", direction = "OUT", talker = "Simon",
    prefix = "You ", text = "smile." })
last = chat.get_messages(1)[1]
check("direction_and_channel_are_case_insensitive",
      last and last.type == "emote_out", last and last.type)

-- No direction: stay an ordinary channel type rather than guess a direction.
chat.clear()
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "tell", talker = "Bob", text = "hi" })
last = chat.get_messages(1)[1]
check("undirected_tell_stays_a_channel_type", last and last.type == "chat_tell",
      last and last.type)

-- An unknown direction is not a direction.
chat.clear()
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "tell", direction = "sideways", talker = "Bob", text = "hi" })
last = chat.get_messages(1)[1]
check("unknown_direction_stays_a_channel_type", last and last.type == "chat_tell",
      last and last.type)

-- Direction on an ordinary channel is simply ignored.
chat.clear()
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "wiz", direction = "in", talker = "Simon", text = "hello" })
last = chat.get_messages(1)[1]
check("direction_ignored_on_plain_channel", last and last.type == "chat_wiz",
      last and last.type)

-- ---- lead-in spacing ------------------------------------------------------------
-- A server prefix need not end in whitespace; exactly one space is inserted, and
-- a prefix that already ends in one is left alone.
chat.set_source("auto")
chat.clear()
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "wiz", talker = "Simon", text = "test", prefix = "Simon says:" })
grows = render()
check("space_inserted_after_prefix",
      plain(grows[4]) and plain(grows[4]):find("Simon says: test", 1, true) ~= nil,
      grows[4])

chat.clear()
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "wiz", talker = "Simon", text = "test", prefix = "Simon says: " })
grows = render()
check("no_double_space_when_prefix_ends_in_one",
      plain(grows[4]) and plain(grows[4]):find("Simon says:  test", 1, true) == nil,
      grows[4])

-- ---- two-tone colouring ---------------------------------------------------------
-- The lead-in carries the line type's colour, the body the text colour.
check("text_color_defaults_white", chat.text_color() == "white", chat.text_color())
chat.set_color("chat_wiz", "bright_cyan")
chat.set_timestamps(false)
chat.clear()
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "wiz", talker = "Simon", text = "body", prefix = "LEAD:" })
grows = render()
check("prefix_in_type_color_body_in_text_color",
      grows[4] and grows[4]:find("\027[96mLEAD: \027[37mbody", 1, true) ~= nil, grows[4])

check("set_text_color_rejects_nonsense", chat.set_text_color("greenish") == false)
check("set_text_color", chat.set_text_color("bright_black") == true)
grows = render()
check("text_color_applies",
      grows[4] and grows[4]:find("\027[96mLEAD: \027[90mbody", 1, true) ~= nil, grows[4])

-- Per-type override beats the global setting.
check("configure_accepts_text_color",
      chat.configure("chat_wiz", { text_color = "yellow" }))
grows = render()
check("per_type_text_color_applies",
      grows[4] and grows[4]:find("\027[96mLEAD: \027[33mbody", 1, true) ~= nil, grows[4])
chat.configure("chat_wiz", { text_color = "white" })
chat.set_text_color("white")

-- A line with no lead-in stays entirely in its type colour: MIP text is already
-- a formatted line, and greying it would discard the per-channel colour.
chat.set_source("mip")
chat.clear()
send_chat("Bob", "whole line one colour")
grows = render()
check("no_prefix_keeps_single_color",
      grows[4] and grows[4]:find("\027[37m", 1, true) == nil, grows[4])
chat.set_source("auto")

-- ---- colour survives wrapping ---------------------------------------------------
-- The body colour has to be re-stated on continuation rows, or a wrapped message
-- reverts to the row's base colour halfway through.
chat.clear()
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "wiz", talker = "Simon", prefix = "LEAD:",
    text = "one two three four five six seven eight nine ten eleven twelve" })
local wrapped_rows = render()
local body_rows = 0
for _, text in pairs(wrapped_rows) do
  if text:find("\027[37m", 1, true) then body_rows = body_rows + 1 end
end
check("wrapped_body_keeps_text_color_on_every_row", body_rows >= 2, body_rows)

-- And the words survive the paint intact.
local joined = {}
for row = 1, 5 do
  if wrapped_rows[row] then joined[#joined + 1] = plain(wrapped_rows[row]) end
end
joined = table.concat(joined, " ")
check("wrapped_text_not_corrupted_by_paint",
      joined:find("eleven", 1, true) ~= nil and joined:find("LEAD:", 1, true) ~= nil,
      joined)
chat.set_timestamps(true, "%H:%M", "white")

-- ---- disconnect clears the counters, not the memory -----------------------------
chat.set_source("auto")
send_gmcp("wiz", "Simon", "latch me")
check("latched_before_disconnect", chat.source().active == "gmcp")
chat.on_disconnect()
st = chat.source()
check("disconnect_resets_counters", st.gmcp_count == 0 and st.mip_count == 0)
check("disconnect_keeps_mode", st.mode == "auto", st.mode)
-- Having seen GMCP chat outlives the connection: reverting to MIP here would
-- hand the next session's first line back to MIP and duplicate it.
check("disconnect_keeps_source", st.active == "gmcp", st.active)
check("disconnect_keeps_gmcp_seen_flag", st.gmcp_seen == true)

chat.clear()
send_chat("Bob", "mip stays suppressed after disconnect")
check("mip_still_suppressed_after_disconnect", chat.count() == 0, chat.count())

-- ---- /chat command -------------------------------------------------------------
local chat_spec = spec_for("/chat")
check("registers_chat_command", chat_spec ~= nil)
check("chat_command_takes_args", chat_spec and chat_spec.accepts_args == true)

local printed_lines = {}
local real_print = print
local function capture(args)
  printed_lines = {}
  print = function(text) printed_lines[#printed_lines + 1] = tostring(text) end
  chat_spec.handler(args)
  print = real_print
  return table.concat(printed_lines, "\n")
end

local cmd_out = capture("source")
check("chat_source_reports_protocol", cmd_out:find("source: gmcp", 1, true) ~= nil, cmd_out)
check("chat_source_explains_memory",
      cmd_out:find("remembered", 1, true) ~= nil, cmd_out)
check("chat_source_reports_counts", cmd_out:find("gmcp:", 1, true) ~= nil, cmd_out)

capture("source gmcp")
check("chat_source_pins", chat.source().mode == "gmcp", chat.source().mode)
chat.set_source("auto")

cmd_out = capture("source carrier-pigeon")
check("chat_source_rejects_nonsense",
      cmd_out:find("auto, mip or gmcp", 1, true) ~= nil, cmd_out)

cmd_out = capture("types")
check("chat_types_lists", cmd_out:find("chat_wiz", 1, true) ~= nil, cmd_out)

-- ---- opt-in spacing diagnostics: only bounded metadata, never content -----------
local spacing_header = "[chat spacing] %s; records=%d/20; bytes include ANSI/UTF-8; spaces=1-based byte position:length (first 10 runs >=2; ...=more)"
check("spacing_disabled_by_default", capture("spacing report") == spacing_header:format("off", 0))
check("padding_default_on", capture("padding") == "[chat] padding: on; new single-line prose only")
capture("padding off")
chat.receive("tell_in", "Example", "first        second", "")
check("padding_off_preserves", chat.get_messages(1)[1].text == "first        second")
for _, args in ipairs({ "padding maybe", "padding on extra", "padding off extra" }) do
  check("padding_invalid", capture(args) == "Usage: /chat padding [on|off]")
end
check("padding_invalid_unchanged", capture("padding"):find("padding: off", 1, true) ~= nil)
capture("padding on")
chat.receive("other", "Example", "first        second\n    third", "")
check("padding_other_type_untouched", chat.get_messages(1)[1].text == "first        second\n    third")
chat.receive("tell_in", "Example", "first        second", "prefix        preserved")
local prefix_rows = render_at({ x = 0, y = 0, w = 120, h = 5 })
local prefix_found = false
for _, row in pairs(prefix_rows) do
  if row:find("prefix        preserved", 1, true) then prefix_found = true end
end
check("padding_prefix_untouched", prefix_found)
local writes_before_spacing = store_writes
check("spacing_on_clears", capture("spacing on") == "[chat spacing] on; records cleared")
chat.set_source("gmcp")
send_gmcp("private_channel_marker", "private_sender_marker", "é\27[31mA  B\r\n    C\27[0m")
check("spacing_exact_pre_post_bytes", capture("spacing report") == spacing_header:format("on", 1)
  .. "\n[chat spacing] 1 gmcp channel raw{bytes=22 lf=1 cr=1 spaces=[9:2,14:4]} normalized{bytes=17 lf=0 cr=0 spaces=[9:2]}")

-- Synthetic bodies reproduce the reported byte lengths and gap offsets without
-- retaining any private capture text.
capture("spacing on")
chat.receive("chat_gossip", "Example", string.rep("a", 56) .. string.rep(" ", 9)
  .. string.rep("b", 26) .. "  " .. string.rep("c", 10) .. string.rep(" ", 9) .. string.rep("d", 29), "")
send_gmcp("gossip", "Example", string.rep("a", 40) .. string.rep(" ", 8)
  .. string.rep("b", 42) .. "  " .. string.rep("c", 10) .. string.rep(" ", 8) .. string.rep("d", 29))
check("padding_exact_reported_evidence", capture("spacing report") == spacing_header:format("on", 2)
  .. "\n[chat spacing] 1 relay channel raw{bytes=141 lf=0 cr=0 spaces=[57:9,92:2,104:9]} normalized{bytes=125 lf=0 cr=0 spaces=[84:2]}"
  .. "\n[chat spacing] 2 gmcp channel raw{bytes=139 lf=0 cr=0 spaces=[41:8,91:2,103:8]} normalized{bytes=125 lf=0 cr=0 spaces=[84:2]}")
capture("spacing on")
local silent_output = {}
print = function(text) silent_output[#silent_output + 1] = tostring(text) end
send_gmcp("private_channel_marker", "private_sender_marker",
  "private_body_marker  https://private-url.invalid/secret_marker\n    end")
chat.receive("private_type_marker", "private_sender_marker", "private_body_marker", "private_prefix_marker")
print = real_print
check("spacing_no_automatic_logging", #silent_output == 0)
cmd_out = capture("spacing report")
for index, marker in ipairs({ "private_channel_marker", "private_sender_marker", "private_body_marker",
    "private_type_marker", "private_prefix_marker", "https://", "secret_marker", "\27" }) do
  check("spacing_report_excludes_marker_" .. index, not cmd_out:find(marker, 1, true))
end
check("spacing_fixed_categories", cmd_out:find("gmcp channel raw{", 1, true)
  and cmd_out:find("relay other raw{", 1, true))

capture("spacing on")
chat.set_source("mip")
mip_handlers.BAB("k", "BAB", "~private_sender_marker~A" .. string.rep(" ", 60) .. "B")
check("spacing_flattened_mip", capture("spacing report") == spacing_header:format("on", 1)
  .. "\n[chat spacing] 1 mip tell_in raw{bytes=62 lf=0 cr=0 spaces=[2:60]} normalized{bytes=3 lf=0 cr=0 spaces=[]}")
chat.set_source("gmcp")
capture("spacing on")
send_gmcp("private_channel_marker", "private_sender_marker", string.rep("x  ", 11))
check("spacing_run_limit", capture("spacing report") == spacing_header:format("on", 1)
  .. "\n[chat spacing] 1 gmcp channel raw{bytes=33 lf=0 cr=0 spaces=[2:2,5:2,8:2,11:2,14:2,17:2,20:2,23:2,26:2,29:2,...]} normalized{bytes=33 lf=0 cr=0 spaces=[2:2,5:2,8:2,11:2,14:2,17:2,20:2,23:2,26:2,29:2,...]}")
capture("spacing on")
send_gmcp("private_channel_marker", "private_sender_marker", string.rep("x  ", 10))
check("spacing_exactly_ten_runs_not_truncated", not capture("spacing report"):find("29:2,...", 1, true))

capture("spacing on")
for i = 1, 25 do send_gmcp("private_channel_marker", "private_sender_marker", string.rep("x", i)) end
capture("spacing report")
check("spacing_record_limit", #printed_lines == 21 and printed_lines[1] == spacing_header:format("on", 20))
check("spacing_keeps_latest_twenty", printed_lines[2]
  == "[chat spacing] 1 gmcp channel raw{bytes=6 lf=0 cr=0 spaces=[]} normalized{bytes=6 lf=0 cr=0 spaces=[]}"
  and printed_lines[21]
  == "[chat spacing] 20 gmcp channel raw{bytes=25 lf=0 cr=0 spaces=[]} normalized{bytes=25 lf=0 cr=0 spaces=[]}")
local before_invalid = capture("spacing report")
for _, args in ipairs({ "spacing", "spacing private_argument_marker", "spacing on extra",
    "spacing off extra", "spacing report extra" }) do
  check("spacing_invalid_command", capture(args) == "Usage: /chat spacing on|report|off")
  check("spacing_invalid_preserves_state", capture("spacing report") == before_invalid)
end
capture("spacing on")
check("spacing_on_resets_records", capture("spacing report") == spacing_header:format("on", 0))
send_gmcp("private_channel_marker", "private_sender_marker", "A  B")
check("spacing_off_clears", capture("spacing off") == "[chat spacing] off; records cleared")
send_gmcp("private_channel_marker", "private_sender_marker", "A  B")
check("spacing_off_stops_capture", capture("spacing report") == spacing_header:format("off", 0))
capture("spacing on")
send_gmcp("private_channel_marker", "private_sender_marker", "A  B")
chat.on_disconnect()
check("spacing_disconnect_clears", capture("spacing report") == spacing_header:format("off", 0))
check("spacing_never_writes_store", store_writes == writes_before_spacing)
check("spacing_help", capture("help"):find("/chat spacing on|report|off", 1, true) ~= nil)
-- Leave capture enabled to check that unload clears it without persisting it.
capture("spacing on")

-- ---- the remembered source kills the duplicate first line -----------------------
-- Both protocols deliver the same line and MIP arrives first, so a session that
-- starts on MIP prints it before the latch can flip. A profile that has seen
-- GMCP chat before starts on GMCP and never gives MIP the chance.
chat.set_source("auto")
gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "wiz", talker = "Simon", text = "proves gmcp" })
check("gmcp_seen_recorded", chat.source().gmcp_seen == true)

chat.clear()
capture("padding off")
chat.on_unload()
check("padding_persisted", stored_chat.config.padding == false)
check("spacing_unload_clears", capture("spacing report") == spacing_header:format("off", 0))
local function has_spacing_data(value)
  if type(value) == "string" then return value:find("raw{bytes=", 1, true) ~= nil end
  if type(value) ~= "table" then return false end
  for key, item in pairs(value) do
    if tostring(key):find("spacing", 1, true) or has_spacing_data(item) then return true end
  end
  return false
end
check("spacing_not_persisted", not has_spacing_data(stored_chat))
check("gmcp_seen_persisted",
      stored_chat and stored_chat.config and stored_chat.config.gmcp_chat_seen == true,
      stored_chat and stored_chat.config and tostring(stored_chat.config.gmcp_chat_seen))

package.loaded.chat_monitor = nil
local reloaded = require("chat_monitor")
reloaded.on_load()
reloaded.receive("tell_in", "Example", "first        second", "")
check("padding_restored_off", reloaded.get_messages(1)[1].text == "first        second")
-- This stub retains old registrations; release them for a real new command binding.
registered = {}
reloaded.on_unload()
stored_chat.config.padding = true
reloaded.on_load()
chat_spec = spec_for("/chat")

check("reload_starts_on_gmcp", reloaded.source().active == "gmcp",
      reloaded.source().active)
check("reload_reports_remembered",
      reloaded.source().qualifier:find("remembered", 1, true) ~= nil,
      reloaded.source().qualifier)
check("reload_has_no_latch_yet", reloaded.source().gmcp_count == 0,
      reloaded.source().gmcp_count)

-- The first MIP line of the new session is dropped rather than printed: this is
-- the duplicate that used to slip through.
reloaded.clear()
mip_handlers["CAA"]("k", "CAA", "wiz~Wiz~Simon~first line")
check("remembered_source_drops_first_mip_line", reloaded.count() == 0, reloaded.count())

gmcp_handlers["Comm"]("Comm.Channel.Text",
  { channel = "wiz", talker = "Simon", text = "first line" })
check("remembered_source_prints_gmcp_line", reloaded.count() == 1, reloaded.count())

-- A disconnect drops the per-connection latch but keeps the memory, so a
-- reconnect does not re-earn its duplicate.
reloaded.on_disconnect()
check("disconnect_keeps_remembered_source", reloaded.source().active == "gmcp",
      reloaded.source().active)
check("disconnect_keeps_gmcp_seen", reloaded.source().gmcp_seen == true)
reloaded.clear()
mip_handlers["CAA"]("k", "CAA", "wiz~Wiz~Simon~after reconnect")
check("remembered_source_survives_reconnect", reloaded.count() == 0, reloaded.count())

-- Pinning to MIP still wins over the memory, which is the escape hatch if a
-- server stops sending GMCP chat.
reloaded.set_source("mip")
reloaded.clear()
mip_handlers["CAA"]("k", "CAA", "wiz~Wiz~Simon~pinned to mip")
check("pinning_mip_overrides_memory", reloaded.count() == 1, reloaded.count())
reloaded.set_source("auto")
check("auto_returns_to_remembered_gmcp", reloaded.source().active == "gmcp",
      reloaded.source().active)

-- Mobile reads the same accepted logical records and prefix decisions.
check("mobile_history_provider_exists", type(reloaded.companion_source) == "function")
if reloaded.companion_source then
  reloaded.clear()
  reloaded.set_timestamps(false)
  local provider = reloaded.companion_source()
  local empty = provider.page({epoch="",after="",before="",limit=2})
  gmcp_handlers["Comm"]("Comm.Channel.Text", {channel="tell",talker="Simon",targets={"Alice","Bob"},text="hello",prefix="Simon tells Alice and Bob:"})
  gmcp_handlers["Comm"]("Comm.Channel.Text", {channel="wiz",talker="Simon",text="world"})
  local page = provider.page({epoch="",after="",before="",limit=1})
  check("mobile_history_pages_one_record", #page.records == 1 and page.more)
  local older = provider.page({epoch=page.epoch,after="",before=page.records[1].id,limit=2})
  check("mobile_history_keeps_server_tell_targets", #older.records == 1 and older.records[1].text:find("Simon tells Alice and Bob:",1,true))
  local after = provider.page({epoch=page.epoch,after=older.records[1].id,before="",limit=2})
  check("mobile_history_after_is_exclusive", #after.records == 1 and after.records[1].id == page.records[1].id)
  reloaded.clear()
  local cleared = provider.page({epoch=page.epoch,after=page.records[1].id,before="",limit=2})
  check("mobile_history_clear_resets_epoch", cleared.reset and cleared.epoch ~= page.epoch and #cleared.records == 0)
end

-- Continuation folding happens before storage, relay listeners and rendering.
chat = reloaded
chat.set_timestamps(false)
local observed
chat.on_message(function(_, _, text) observed = text end)
local folding_cases = {
  { "lf_indent", "be\n        fixed..", "be fixed.." },
  { "crlf_boundary", "be  \r\n \t fixed..", "be fixed.." },
  { "cr_boundary", "be\r        fixed..", "be fixed.." },
  { "same_line", "  keep   these\tspaces  ", "  keep   these\tspaces  " },
  { "intraline_multiline", "keep   these \n    and   those", "keep   these and   those" },
  { "paragraphs", "first \r\n \t\r\n    second", "first \n \t\n    second" },
  { "explicit_lines", "first\nsecond", "first\nsecond" },
  { "explicit_ansi_line", "first \n\27[31msecond", "first \n\27[31msecond" },
  { "indented_paragraph", "intro\n\n    code()", "intro\n\n    code()" },
  { "unicode", "räksmörgås\n    世界", "räksmörgås 世界" },
  { "flattened_padding", "first" .. string.rep(" ", 60) .. "second",
    "first second" },
  { "eight_nine_two", "first        second  third         fourth", "first second  third fourth" },
  { "seven", "first       second", "first       second" },
  { "ansi_padding", "first    \27[31m    \27[1m second\27[0m", "first \27[31m\27[1msecond\27[0m" },
  { "edge_padding", "        first        second         ", "        first second         " },
  { "tabs", "first\t        second", "first\t        second" },
  { "table", "name        value\n    a        b", "name        value\n    a        b" },
  { "code", "    if ok then\n        run()\n    end", "    if ok then\n        run()\n    end" },
  { "aligned_wrap", "first        second\n        third", "first        second\n        third" },
  { "edge_newlines", "\n  first\n    second \n", "first second" },
  { "only_blank", " \n \t\r\n", "" },
  { "ansi_indent", "be \27[0m \n \27[31m   fixed..\27[0m",
    "be \27[0m\27[31mfixed..\27[0m" },
}
for _, protocol in ipairs({ "gmcp_tell", "gmcp_emote", "gmcp_gossip", "BAB", "BAG", "CAA" }) do
  local channel = protocol:match("^gmcp_(.+)$")
  chat.set_source(channel and "gmcp" or "mip")
  for _, case in ipairs(folding_cases) do
    chat.clear()
    if channel then
      gmcp_handlers.Comm("Comm.Channel.Text", {
        channel = channel, direction = "out", talker = "Example", prefix = "You tell Example:",
        text = case[2],
      })
    else
      local lead = protocol == "CAA" and "gossip~Gossip~Example~" or "x~Example~"
      mip_handlers[protocol]("k", protocol, lead .. case[2])
    end
    check("fold_" .. protocol .. "_" .. case[1], chat.get_messages(1)[1].text == case[3])
    check("fold_listener_" .. protocol .. "_" .. case[1], observed == case[3])
    for _, relay_type in ipairs({ "tell_in", "tell_out", "emote_in", "emote_out", "chat_gossip" }) do
      chat.receive(relay_type, "Example", case[2], "")
      check("padding_relay_" .. relay_type .. "_" .. case[1], chat.get_messages(1)[1].text == case[3])
    end
    chat.receive("tell_in", "Example", case[3], "")
    check("fold_idempotent_" .. protocol .. "_" .. case[1], chat.get_messages(1)[1].text == case[3])
  end
end

-- Separate protocol events are separate messages, never inferred continuations.
chat.clear()
send_chat("Example", "first")
send_chat("Example", "        second")
check("fold_does_not_merge_events", chat.count() == 2
  and chat.get_messages(1)[1].text == "        second")

-- Receiving a relay is idempotent and must not notify outgoing listeners.
observed = nil
chat.receive("tell_in", "Example", "be \r\n        fixed..", "[remote] Example tells you:")
check("fold_remote_receive", chat.get_messages(1)[1].text == "be fixed.." and observed == nil)

-- Exercise the real relay plugin with a closed in-process session transport.
local remote_receiver, relayed
session = {
  name = function() return "local-test" end,
  on_message = function(fn) remote_receiver = fn end,
  send = function(target, type_id, sender, text, prefix)
    relayed = { target, type_id, sender, text, prefix }
    return true
  end,
}
plugin = { get = function(name) if name == "chat_monitor" then return chat end end }
local relay = require("chat_relay")
relay.on_load()
spec_for("/chatrelay").handler("add tells remote-test")
chat.set_source("mip")
mip_handlers.BAB("k", "BAB", "~Example~be\n        fixed..")
check("fold_relay_send", relayed and relayed[4] == "be fixed..")
relayed = nil
remote_receiver("tell_in", "Example", "be\r\n        fixed..", "[remote]", true)
check("fold_relay_receive_no_loop", chat.get_messages(1)[1].text == "be fixed.." and relayed == nil)
mip_handlers.BAB("k", "BAB", "~Example~first        second  third         fourth")
check("padding_relay_send", relayed and relayed[4] == "first second  third fourth")
relayed = nil
for _, type_id in ipairs({ "tell_in", "emote_in", "chat_gossip" }) do
  remote_receiver(type_id, "Example", "first        second  third         fourth", "[remote]", true)
  check("padding_real_relay_" .. type_id,
    chat.get_messages(1)[1].text == "first second  third fourth" and relayed == nil)
end

-- URL detection and hit testing use normalized bytes, including paragraph
-- separators and ANSI at the fold. No browser or network call is made.
local opened_url
mxp = { open_url = function(url) opened_url = url; return true end }
for _, separator in ipairs({ " \n \27[31m   ", " \r\n \r\n \27[31m   ", "    \27[31m    ", "         \27[31m" }) do
  chat.clear()
  chat.receive("tell_in", "Example", "see" .. separator .. "https://example.org/path\27[0m done", "")
  local rows = render_at({ x = 0, y = 0, w = 100, h = 5 })
  local row, column
  for y, text in pairs(rows) do
    local start = plain(text):find("https://example.org/path", 1, true)
    if start then row, column = y, start - 1 end
  end
  check("fold_url_rendered", row ~= nil)
  if row then
    local function point(kind, x)
      return chat.on_pointer({ kind = kind, button = "left", x = x, y = row,
        width = 100, height = 5, inside = true })
    end
    check("fold_url_left_boundary", not point("down", column - 1))
    check("fold_url_right_boundary", not point("down", column + #"https://example.org/path"))
    opened_url = nil
    check("fold_url_hit", point("down", column))
    point("up", column)
    check("fold_url_target", opened_url == "https://example.org/path")
    check("fold_ansi_preserved", rows[row]:find("\27[31m", 1, true) ~= nil)
  end
  if separator:find("\r", 1, true) then
    check("fold_blank_row_retained", plain(rows[3] or ""):match("^ *$") ~= nil
      and plain(rows[2] or ""):find("see", 1, true) ~= nil)
  end
end

local wrapped_url = "https://example.org/abcdefghij"
for _, separator in ipairs({ "\n    ", "\n  \n    ", "\n", "        ", "         " }) do
  chat.clear()
  chat.receive("tell_in", "Example", "see" .. separator .. "\27[31m" .. wrapped_url .. "\27[0m", "")
  local rect = { x = 0, y = 0, w = 12, h = 15 }
  local rows = render_at(rect)
  render_pass = "remote"
  local remote_rows = render_at(rect)
  render_pass = "local"
  local clicked = 0
  for y, text in pairs(rows) do
    check("fold_wrapped_remote_matches", remote_rows[y] == text)
    local visible = plain(text)
    check("fold_wrapped_fits", #visible <= rect.w)
    local chunk = visible:gsub("^ +", ""):gsub("^see *", "")
    if chunk ~= "" then
      check("fold_wrapped_url_chunk", wrapped_url:find(chunk, 1, true) ~= nil)
      local start = assert(visible:find(chunk, 1, true)) - 1
      for x = start, start + #chunk - 1 do
        opened_url = nil
        local event = { kind = "down", button = "left", x = x, y = y,
          width = rect.w, height = rect.h, inside = true }
        check("fold_wrapped_url_hit", chat.on_pointer(event))
        event.kind = "up"
        chat.on_pointer(event)
        check("fold_wrapped_url_target", opened_url == wrapped_url)
        clicked = clicked + 1
      end
    end
  end
  check("fold_wrapped_all_url_cells", clicked == #wrapped_url)
end

-- Hanging indentation includes the timestamp and the full server lead-in.
chat.clear()
chat.receive("tell_in", "Skuggis", string.rep("word ", 30), "[Livsfara] Skuggis tells you:")
local hanging_rect = { x = 0, y = 0, w = 80, h = 20 }
render_pass = "local"
local hanging_rows = render_at(hanging_rect)
local body_column, continuations = nil, 0
for y = 0, hanging_rect.h - 1 do
  local line = plain(hanging_rows[y] or "")
  if line:find("Skuggis tells you:", 1, true) then
    body_column = assert(line:find("word", 1, true))
  elseif line:find("word", 1, true) then
    continuations = continuations + 1
    check("hanging_body_alignment", body_column ~= nil and line:find("word", 1, true) == body_column)
  end
end
check("hanging_has_continuations", continuations > 0)
render_pass = "remote"
local remote_hanging = render_at(hanging_rect)
for y = 0, hanging_rect.h - 1 do
  check("hanging_remote_matches", remote_hanging[y] == hanging_rows[y])
end
render_pass = "local"

print(failures == 0 and "ALL PASS" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
