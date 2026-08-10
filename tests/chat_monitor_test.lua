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
lera = { render_pass = function() return "local" end, display = function() return "tty" end }

local chat = require("chat_monitor")
chat.on_load()

local function send_chat(sender, text)
  mip_handlers["CAA"]("k", "CAA", "gossip~Gossip~" .. sender .. "~" .. text)
end

local RECT = { x = 0, y = 0, w = 40, h = 5 }   -- borderless: 40x5 content
local function render()
  drawn = {}
  chat.render(RECT, { show_border = false })
  return drawn
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

print(failures == 0 and "ALL PASS" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
