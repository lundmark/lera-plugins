-- wizard file pane: entries, column layout, scrolling and pointer navigation.
-- Run from the lera-plugins repo root with LERA_ROOT pointing at a built Lera
-- checkout.
--
-- The pane lays entries out in ls-style columns, filled COLUMN-MAJOR (down
-- column 1, then down column 2). Several cases below exist specifically to
-- kill a row-major implementation, which would pass a naive single-column
-- suite unnoticed.
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
    local count = opts.count
    -- Clamps exactly as scripts/default/wm.lua does: offset is a DISTANCE FROM
    -- THE TAIL bounded to [0, count-1], and a negative delta (up/older)
    -- increases it. A stub that skipped the clamp would make the pane's
    -- top-anchoring look broken when it is correct.
    local function clamp()
      local max = count() - 1
      if max < 0 then max = 0 end
      if offset > max then offset = max end
      if offset < 0 then offset = 0 end
    end
    return {
      offset = function() clamp(); return offset end,
      scroll = function(d) offset = offset - d; clamp() end,
      scroll_to_bottom = function() offset = 0 end,
      following_tail = function() clamp(); return offset == 0 end,
      on_append = function() end,
      on_trim = function() end,
      count = count,
    }
  end,
}

local drawn = {}
local boxes = {}
ui = {
  dirty = function() end,
  -- Records position as well as text: a column layout is only testable if the
  -- x of each cell is observable.
  text = function(rect, s) drawn[#drawn + 1] = { x = rect.x, y = rect.y, text = s } end,
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

local function drawn_text(x, y)
  for i = 1, #drawn do
    if drawn[i].x == x and drawn[i].y == y then return drawn[i].text end
  end
  return nil
end

local function has_text(s)
  for i = 1, #drawn do if drawn[i].text == s then return true end end
  return false
end

-- ---- entries ---------------------------------------------------------------

protocol.reset()
protocol.set_available(true)
protocol.set_cwd("/players/simon")
protocol.store("/players/simon", {
  dirs = { "zebra", "archive" },
  files = { "notes.txt", "arena.c" },
  complete = true, truncated = false,
})

do
  local e = pane.entries()
  check("entries: directories first, alphabetical",
        e[1].text == "archive/" and e[2].text == "zebra/",
        e[1] and e[1].text .. "," .. tostring(e[2] and e[2].text))
  check("entries: files follow, alphabetical, unslashed",
        e[3].text == "arena.c" and e[4].text == "notes.txt",
        tostring(e[3] and e[3].text) .. "," .. tostring(e[4] and e[4].text))
  check("entries: directories are flagged", e[1].is_dir == true and e[3].is_dir == false)
  check("entries: name is the bare entry, no slash", e[1].name == "archive")
  check("entries: one per listing entry", #e == 4, #e)
  check("entries: a normal listing has no notice", pane.notice() == nil,
        tostring(pane.notice()))
end

-- ---- notices ---------------------------------------------------------------

protocol.store("/players/simon", {
  dirs = {}, files = { "a" }, complete = true, truncated = true,
})
check("notice: truncation is reported",
      (pane.notice() or ""):find("truncated", 1, true) ~= nil, tostring(pane.notice()))
check("notice: truncation does not become an entry",
      #pane.entries() == 1, #pane.entries())

protocol.store("/players/simon", {
  dirs = {}, files = {}, complete = true, error = "denied",
})
check("notice: an error is reported",
      (pane.notice() or ""):find("denied", 1, true) ~= nil, tostring(pane.notice()))
check("notice: an error yields no entries", #pane.entries() == 0)

protocol.store("/players/simon", { dirs = {}, files = {}, complete = false })
check("notice: an incomplete listing says loading",
      (pane.notice() or ""):find("loading", 1, true) ~= nil, tostring(pane.notice()))

protocol.reset()
check("notice: unavailable Files.List is explained rather than blank",
      (pane.notice() or ""):find("wizard", 1, true) ~= nil, tostring(pane.notice()))
check("notice: unavailable yields no entries", #pane.entries() == 0)

-- ---- column layout ---------------------------------------------------------
--
-- Fixture, sorted: archive/(8) areas/(6) mmm/(4) zebra/(6) arena.c(7)
-- notes.txt(9). Longest is 9, so cell width is 9 + 2 gutter = 11.
-- A pane of w=30 insets to 28 content columns: floor((28+2)/11) = 2 columns,
-- and ceil(6/2) = 3 grid rows.
--   column 0 (x=1)  : archive/  areas/  mmm/
--   column 1 (x=12) : zebra/    arena.c notes.txt

protocol.reset()
protocol.set_available(true)
protocol.set_cwd("/players/simon")
protocol.store("/players/simon", {
  dirs = { "zebra", "archive", "mmm", "areas" },
  files = { "notes.txt", "arena.c" },
  complete = true, truncated = false,
})

drawn = {}
pane.render({ x = 0, y = 0, w = 30, h = 10 }, { title = "Files" })
check("layout: six entries draw six cells", #drawn == 6, #drawn)
check("layout: column 0 starts at the content x", drawn_text(1, 1) == "archive/",
      tostring(drawn_text(1, 1)))
check("layout: column 1 is one cell width across", drawn_text(12, 1) == "zebra/",
      tostring(drawn_text(12, 1)))
check("layout: column-major fills DOWN column 0 first",
      drawn_text(1, 2) == "areas/" and drawn_text(1, 3) == "mmm/",
      "row-major would put zebra/ at (1,2); got "
        .. tostring(drawn_text(1, 2)))
check("layout: column 1 continues the sequence",
      drawn_text(12, 2) == "arena.c" and drawn_text(12, 3) == "notes.txt",
      tostring(drawn_text(12, 2)))

-- ---- pointer over columns --------------------------------------------------

sent = {}
local consumed = pane.on_pointer({ kind = "down", button = "left", x = 1, y = 1,
                                   inside = true, width = 30, height = 10 })
check("pointer: a click in column 0 navigates", #sent == 1 and sent[1] == "cd archive",
      tostring(sent[1]))
check("pointer: a consumed down returns literal true", consumed == true)

sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 12, y = 1,
                  inside = true, width = 30, height = 10 })
check("pointer: a click in column 1 resolves COLUMN-MAJOR",
      #sent == 1 and sent[1] == "cd zebra",
      "row-major would resolve areas/ here; got " .. tostring(sent[1]))

sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 1, y = 3,
                  inside = true, width = 30, height = 10 })
check("pointer: the third row of column 0 is the third entry",
      #sent == 1 and sent[1] == "cd mmm", tostring(sent[1]))

sent = {}
consumed = pane.on_pointer({ kind = "down", button = "left", x = 12, y = 2,
                             inside = true, width = 30, height = 10 })
check("pointer: a click on a file sends nothing", #sent == 0, tostring(sent[1]))
check("pointer: an unconsumed down does not return true", consumed ~= true,
      "so a left drag can still start a text selection")

sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 1, y = 0,
                  inside = true, width = 30, height = 10 })
check("pointer: a click on the top border does not navigate", #sent == 0)

sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 0, y = 1,
                  inside = true, width = 30, height = 10 })
check("pointer: a click on the left border does not navigate", #sent == 0,
      "x=0 is the border column, not content")

sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 1, y = 40,
                  inside = true, width = 30, height = 10 })
check("pointer: a click past the last row sends nothing", #sent == 0)

sent = {}
pane.on_pointer({ kind = "move", button = "left", x = 1, y = 1,
                  inside = true, width = 30, height = 10 })
check("pointer: only a down navigates", #sent == 0)

sent = {}
pane.on_pointer({ kind = "down", button = "right", x = 1, y = 1,
                  inside = true, width = 30, height = 10 })
check("pointer: only the left button navigates", #sent == 0)

-- An empty cell: column 1 of a 5-entry grid has a hole at its last row.
protocol.store("/players/simon", {
  dirs = { "archive", "areas", "mmm" }, files = { "notes.txt", "arena.c" },
  complete = true, truncated = false,
})
-- sorted: archive/ areas/ mmm/ arena.c notes.txt -> 5 entries, cols 2, rows 3
-- column 0: archive/ areas/ mmm/   column 1: arena.c notes.txt (row 3 empty)
sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 12, y = 3,
                  inside = true, width = 30, height = 10 })
check("pointer: a click on an empty grid cell does nothing", #sent == 0,
      tostring(sent[1]))

-- ---- narrow pane -----------------------------------------------------------

protocol.store("/players/simon", {
  dirs = { "archive" }, files = { "verylongfilename.c" },
  complete = true, truncated = false,
})
drawn = {}
pane.render({ x = 0, y = 0, w = 10, h = 10 })
check("narrow: a pane too small for two columns falls back to one",
      drawn_text(1, 1) == "archive/" and drawn_text(1, 2) ~= nil,
      "entries must stack, not sit side by side")
check("narrow: an over-long name is truncated to the content width",
      #(drawn_text(1, 2) or "") <= 8,
      "content width is 8; got " .. tostring(drawn_text(1, 2)))

-- ---- scrolling and top anchoring -------------------------------------------
--
-- Six single-column entries in a pane with two content rows. A file listing
-- must open at the TOP, unlike a chat pane which opens at its tail.

protocol.store("/players/simon", {
  dirs = { "d1", "d2", "d3", "d4", "d5", "d6" }, files = {},
  complete = true, truncated = false,
})
offset = 0
drawn = {}
pane.render({ x = 0, y = 0, w = 8, h = 4 })
check("scroll: a fresh listing opens at the TOP, not the tail",
      has_text("d1/") and has_text("d2/"),
      "tail-anchored would show d5/,d6/")
check("scroll: only the visible rows are drawn", #drawn == 2, #drawn)

pane.scroll_to_bottom()
drawn = {}
pane.render({ x = 0, y = 0, w = 8, h = 4 })
check("scroll: scroll_to_bottom shows the last entries",
      has_text("d5/") and has_text("d6/"),
      "got " .. tostring(drawn[1] and drawn[1].text))

sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 1, y = 1,
                  inside = true, width = 8, height = 4 })
check("scroll: a click follows the scrolled view",
      #sent == 1 and sent[1] == "cd d5", tostring(sent[1]))

pane.scroll(-1)
drawn = {}
pane.render({ x = 0, y = 0, w = 8, h = 4 })
check("scroll: scrolling up one row moves the view up one entry",
      has_text("d4/") and has_text("d5/"),
      "got " .. tostring(drawn[1] and drawn[1].text))

check("scroll: following_tail is false once scrolled back",
      pane.following_tail() == false)

-- ---- border ----------------------------------------------------------------

boxes = {}
pane.render({ x = 0, y = 0, w = 30, h = 10 }, { title = "Files /players/simon" })
check("render: the pane boxes itself with the title wm passed",
      #boxes == 1 and boxes[1].title == "Files /players/simon",
      boxes[1] and tostring(boxes[1].title))

boxes = {}
pane.render({ x = 0, y = 0, w = 30, h = 10 })
check("render: a missing opts table still renders", #boxes == 1)

boxes = {}
drawn = {}
pane.render({ x = 0, y = 0, w = 30, h = 10 }, { show_border = false })
check("render: show_border=false draws no box", #boxes == 0)
check("render: unbordered content starts at x=0",
      drawn_text(0, 0) ~= nil,
      "without a border there is no inset; got "
        .. tostring(drawn[1] and drawn[1].x) .. "," .. tostring(drawn[1] and drawn[1].y))

-- ---- notice rendering ------------------------------------------------------

protocol.store("/players/simon", {
  dirs = { "archive" }, files = {}, complete = true, truncated = true,
})
drawn = {}
pane.render({ x = 0, y = 0, w = 30, h = 10 }, { title = "Files" })
check("render: the notice draws below the grid, full width",
      has_text("archive/") and (drawn[#drawn].text or ""):find("truncated", 1, true) ~= nil,
      tostring(drawn[#drawn] and drawn[#drawn].text))

protocol.reset()
drawn = {}
pane.render({ x = 0, y = 0, w = 30, h = 10 }, { title = "Files" })
check("render: an unavailable pane draws only its notice",
      #drawn == 1 and (drawn[1].text or ""):find("wizard", 1, true) ~= nil,
      tostring(drawn[1] and drawn[1].text))

print(failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
