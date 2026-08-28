-- wizard file pane rows, scrolling and pointer navigation. Run from the
-- lera-plugins repo root with LERA_ROOT pointing at a built Lera checkout.
package.path = "3scapes/wizard/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

local offset = 0
package.loaded["wm"] = {
  make_scroller = function(opts)
    return {
      offset = function() return offset end,
      -- offset is a DISTANCE FROM THE TAIL, so a negative delta (up/older)
      -- increases it. Getting this backwards would make the pane's row
      -- arithmetic look right against a stub that is wrong.
      scroll = function(d) offset = math.max(0, offset - d) end,
      scroll_to_bottom = function() offset = 0 end,
      following_tail = function() return offset == 0 end,
      on_append = function() end,
      on_trim = function() end,
      count = opts and opts.count,
    }
  end,
}

local drawn = {}
local boxes = {}
ui = {
  dirty = function() end,
  text = function(_, s) drawn[#drawn + 1] = s end,
  box = function(_, style, title) boxes[#boxes + 1] = { style = style, title = title } end,
  -- Real rects are userdata with method accessors; the stub returns the plain
  -- table form the renderer also has to accept.
  rect = function(x, y, w, h) return { x = x, y = y, w = w, h = h } end,
}
local sent = {}
mud = { send = function(t) sent[#sent + 1] = t end }
gmcp = { on = function() return 1 end, send = function() return true end,
         enabled = function() return true end }

local protocol = require("protocol")
local pane = require("pane")

-- ---- rows -----------------------------------------------------------------

protocol.reset()
protocol.set_available(true)
protocol.set_cwd("/players/simon")
protocol.store("/players/simon", {
  dirs = { "archive", "areas" },
  files = { "arena.c", "notes.txt" },
  complete = true, truncated = false,
})

do
  local rows = pane.rows()
  check("rows: directories come first",
        rows[1].text == "archive/" and rows[2].text == "areas/",
        rows[1] and rows[1].text)
  check("rows: files follow, unslashed",
        rows[3].text == "arena.c" and rows[4].text == "notes.txt",
        rows[3] and rows[3].text)
  check("rows: directories are flagged",
        rows[1].is_dir == true and rows[3].is_dir == false)
  check("rows: one row per entry", #rows == 4, #rows)
end

protocol.store("/players/simon", {
  dirs = {}, files = { "a" }, complete = true, truncated = true,
})
do
  local rows = pane.rows()
  check("rows: truncation is shown",
        rows[#rows].text:find("truncated", 1, true) ~= nil,
        rows[#rows] and rows[#rows].text)
  check("rows: the truncation notice is not clickable",
        rows[#rows].is_dir == false)
end

protocol.store("/players/simon", {
  dirs = {}, files = {}, complete = true, error = "denied",
})
do
  local rows = pane.rows()
  check("rows: an error is rendered",
        #rows == 1 and rows[1].text:find("denied", 1, true) ~= nil,
        rows[1] and rows[1].text)
end

protocol.store("/players/simon", { dirs = {}, files = {}, complete = false })
do
  local rows = pane.rows()
  check("rows: an incomplete listing says so",
        #rows == 1 and rows[1].text:find("loading", 1, true) ~= nil,
        rows[1] and rows[1].text)
end

protocol.reset()
do
  local rows = pane.rows()
  check("rows: unavailable Files.List is explained rather than blank",
        #rows == 1 and rows[1].text:find("wizard", 1, true) ~= nil,
        rows[1] and rows[1].text)
end

-- ---- pointer --------------------------------------------------------------

protocol.reset()
protocol.set_available(true)
protocol.set_cwd("/players/simon")
protocol.store("/players/simon", {
  dirs = { "archive" }, files = { "arena.c" }, complete = true, truncated = false,
})

sent = {}
-- y=1: the pane now boxes itself, so pane-local y=0 is the top border and
-- y=1 is the first content row (was y=0 before the border existed).
local consumed = pane.on_pointer({ kind = "down", button = "left", x = 0, y = 1,
                                   inside = true, width = 20, height = 10 })
check("pointer: a click on a directory sends a cd",
      #sent == 1 and sent[1] == "cd archive",
      sent[1])
check("pointer: a consumed down returns literal true",
      consumed == true,
      "only literal true consumes the event")

sent = {}
-- y=2: the second content row (was y=1 before the border existed).
consumed = pane.on_pointer({ kind = "down", button = "left", x = 0, y = 2,
                             inside = true, width = 20, height = 10 })
check("pointer: a click on a file sends nothing",
      #sent == 0, sent[1])
check("pointer: an unconsumed down does not return true",
      consumed ~= true,
      "so a left drag can still start a text selection")

sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 0, y = 40,
                  inside = true, width = 20, height = 10 })
check("pointer: a click past the last row sends nothing", #sent == 0)

sent = {}
pane.on_pointer({ kind = "move", button = "left", x = 0, y = 0,
                  inside = true, width = 20, height = 10 })
check("pointer: only a down navigates", #sent == 0,
      "a move over a directory must not cd")

sent = {}
pane.on_pointer({ kind = "down", button = "right", x = 0, y = 0,
                  inside = true, width = 20, height = 10 })
check("pointer: only the left button navigates", #sent == 0)

-- ---- scrolling ------------------------------------------------------------

offset = 0
check("scroll: following the tail initially", pane.following_tail() == true)
pane.scroll(-3)
check("scroll: scrolling moves the offset", pane.following_tail() == false)
pane.scroll_to_bottom()
check("scroll: scroll_to_bottom returns to the tail", pane.following_tail() == true)

-- A scrolled pane must offset which row a click lands on. Three rows in a
-- two-row pane: at the tail the visible rows are d2,d3; scrolled back one they
-- are d1,d2. Both are asserted, because a pane that ignored the offset entirely
-- would still pass the second case alone.
protocol.store("/players/simon", {
  dirs = { "d1", "d2", "d3" }, files = {}, complete = true, truncated = false,
})

-- height=4 (was 2): with the border now drawn, two content rows need four
-- pane rows, and y=1 (was 0) is the first content row.
offset = 0
sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 0, y = 1,
                  inside = true, width = 20, height = 4 })
check("pointer: at the tail, the top visible row is the second entry",
      #sent == 1 and sent[1] == "cd d2",
      tostring(sent[1]))

pane.scroll(-1)
sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 0, y = 1,
                  inside = true, width = 20, height = 4 })
check("pointer: scrolled back one, the top visible row is the first entry",
      #sent == 1 and sent[1] == "cd d1",
      tostring(sent[1]))

-- ---- border ----------------------------------------------------------------

protocol.reset()
protocol.set_available(true)
protocol.set_cwd("/players/simon")
protocol.store("/players/simon", {
  dirs = { "areas" }, files = {}, complete = true, truncated = false,
})

boxes = {}
pane.render({ x = 0, y = 0, w = 20, h = 10 }, { title = "Files /players/simon" })
check("render: the pane boxes itself with the title wm passed",
      #boxes == 1 and boxes[1].title == "Files /players/simon",
      boxes[1] and tostring(boxes[1].title))

boxes = {}
pane.render({ x = 0, y = 0, w = 20, h = 10 })
check("render: a missing opts table still renders", #boxes == 1)

-- A click on the top border must not navigate, and the first content row
-- (pane-local y=1, once bordered) must.
protocol.store("/players/simon", {
  dirs = { "d1" }, files = {}, complete = true, truncated = false,
})
sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 1, y = 0,
                  inside = true, width = 20, height = 10 })
check("pointer: a click on the top border does not navigate", #sent == 0, sent[1])

sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 1, y = 1,
                  inside = true, width = 20, height = 10 })
check("pointer: the first content row is at y=1 once bordered",
      #sent == 1 and sent[1] == "cd d1", tostring(sent[1]))

print(failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
