-- Named-popup registry + generic pane-page-to-popup wrapper, backing /vik's
-- popup subcommands (map/sea/voyage/cityplan/war -> toggle; pop <page> ->
-- open_page). See CLAUDE.md's "Popup Overlay" section for the
-- require("wm").popup contract sandboxed plugins reach -- open/close/
-- is_open, owner-bound, one popup at a time.
--
-- A renderer module registered here has the shape:
--   { lines = function(width) -> array of strings, PURE,
--     on_pointer = function(ev, ctx) -> bool|nil, OPTIONAL,
--     title = "..." }
-- `lines` must read only its own view's state (page state / page_opts);
-- `on_pointer` may mud.send, mutate the view's own module-local state, open
-- require("menu"), and ui.dirty() -- see the plan's Global Constraints.
local scroller = require("scroller")
local pagelib = require("pagelib")
local window = require("window")

local popups = {}

local registry = {}

-- Name of the popup last opened via popups.toggle -- cleared by that
-- specific open's own on_close closure, so it always reflects whichever
-- toggle-opened popup (if any) is actually the one on screen right now,
-- regardless of whether it closed via a second toggle, Escape, an outside
-- click, or being replaced by another popup (named or /vik pop).
local shown_name = nil

-- Registers (or replaces) a named popup's renderer module. map/sea/voyage/
-- cityplan/war register here in Tasks 3-6; nothing does yet in Task 1, so
-- toggling any of those names currently prints the "no such popup" message
-- below until its task lands.
function popups.register(name, module)
  registry[name] = module
end

-- Wraps a pure lines(width) builder (plus an optional on_pointer) in a
-- scrolling wm.popup renderer. The cached line count feeding the scroller's
-- clamp is pass-guarded exactly like window.lua's own render(): only the
-- LOCAL render pass may update it, so a remote WebSocket viewer's own popup
-- size can never reclamp -- and silently move -- the local user's scroll
-- offset (see window.lua's render() comment for the full rationale; this is
-- the identical mechanism, reused here for the same reason).
local function wrap(lines_fn, on_pointer_fn)
  local last_count = 0
  local sc = scroller.make_top_scroller(function() return last_count end)

  local wrapper = {}

  function wrapper.render(rect, opts)
    local w, h = rect:w(), rect:h()
    if w <= 0 or h <= 0 then return end
    local lines = lines_fn(w)
    if lera.render_pass() ~= "remote" then
      last_count = #lines
      sc.set_height(h)
    end
    local offset = sc.offset()
    local first = offset + 1
    local last = math.min(#lines, offset + h)
    for i = first, last do
      ui.text_ansi(ui.rect(rect:x(), rect:y() + (i - first), w, 1),
        pagelib.trunc(lines[i], w))
    end
  end

  wrapper.scroll = sc.scroll
  wrapper.scroll_to_bottom = sc.scroll_to_bottom
  wrapper.following_tail = sc.following_tail

  -- ctx is deliberately extensible: cell_from_xy (a maplib hit-test) joins
  -- it once Task 2's maplib exists for the grid views to consume.
  if on_pointer_fn then
    function wrapper.on_pointer(ev)
      return on_pointer_fn(ev, {
        close = function() require("wm").popup.close() end,
      })
    end
  end

  return wrapper
end

local function open_wrapper(title, lines_fn, on_pointer_fn, on_close_fn)
  local wrapper = wrap(lines_fn, on_pointer_fn)
  require("wm").popup.open(wrapper, {
    title = title,
    width = 0.9,
    height = 0.9,
    on_close = on_close_fn,
  })
end

-- Opens the named popup, replacing whatever popup (named or not) is
-- currently open; closes it instead if it is already the one showing.
-- Returns false (and prints a friendly message) for a name nothing has
-- registered yet.
function popups.toggle(name)
  local mod = registry[name]
  if not mod then
    buffer.color_print(nil, "DAA520", "Viking: no such popup '" .. tostring(name) .. "'")
    return false
  end

  local wm = require("wm")
  if wm.popup.is_open() and shown_name == name then
    wm.popup.close()
    return true
  end

  open_wrapper(mod.title, mod.lines, mod.on_pointer, function()
    if shown_name == name then shown_name = nil end
  end)
  shown_name = name
  return true
end

-- Wraps any window.PAGES entry's lines in the same scrolling wrapper, with
-- no on_pointer (a pane page has none of its own). Always opens (replacing
-- whatever else is open); `/vik pop <page>` is detached-window parity, not
-- a toggle.
function popups.open_page(page_key)
  local page
  for _, p in ipairs(window.PAGES) do
    if p.key == page_key then page = p end
  end
  if not page then
    buffer.color_print(nil, "DAA520", "Viking: no such page '" .. tostring(page_key) .. "'")
    return false
  end

  open_wrapper(page.label, page.mod.lines, nil, function()
    shown_name = nil
  end)
  return true
end

return popups
