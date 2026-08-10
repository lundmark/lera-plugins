-- chat_monitor unit tests. Run from the lera-plugins repo root:
--   ../lera/external/luajit/src/luajit tests/chat_monitor_test.lua
package.path = "3scapes/?.lua;../lera/scripts/default/?.lua;" .. package.path

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
store = {
  load = function() end,
  get = function() return nil end,
  set = function() end,
  save = function() end,
}
local mip_handlers = {}
mip = {
  on = function(code, fn) mip_handlers[code] = fn; return code end,
  off = function() end,
}
buffer = {
  scroll_offset = function() return 0 end,
  set_scroll_offset = function() end,
  following_tail = function() return true end,
}
local render_pass = "local"
lera = { render_pass = function() return render_pass end, display = function() return "tty" end }

local chat = require("chat_monitor")
chat.on_load()

local function send_chat(sender, text)
  mip_handlers["CAA"]("k", "CAA", "gossip~Gossip~" .. sender .. "~" .. text)
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

-- ---- scrolled back: view holds when messages arrive ---------------------------
chat.scroll(-2)
render()
local held = render()[4]
check("scrolled_back", not chat.following_tail())

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

-- ---- trim keeps the offset sane -------------------------------------------------
chat.set_max_lines(5)
send_chat("Bob", "trigger trim")
chat.scroll(-100000)
local deep = chat  -- offset now at the clamp
chat.scroll_to_bottom()
check("survives_trim", true)  -- reaching here without error is the assertion

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

print(failures == 0 and "ALL PASS" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
