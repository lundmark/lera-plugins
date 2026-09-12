-- guild_shaman: GMCP ingestion + page rendering tests.
-- Run from the lera-plugins repo root with LERA_ROOT pointing at a built
-- Lera checkout:
--   LERA_ROOT=/path/to/lera $LERA_ROOT/external/luajit/src/luajit \
--     tests/guild_shaman_test.lua
package.path = "3scapes/guild_shaman/?.lua;" .. package.path

-- Captured before the stubs below replace the global print: the plugin's
-- scrollback output is redirected into `printed`, so the harness has to report
-- through the original or its own results vanish into the capture table.
local emit = print

local failures = 0
local function check(name, ok, detail)
  if ok then
    emit("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    emit("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- ---- lera API stubs --------------------------------------------------------
-- ONLY the calls lera actually provides are stubbed here, and nothing else.
-- An earlier version of this file invented buffer.print, buffer.color_print_at
-- and ui.width -- none of which exist -- so every test passed while the real
-- client threw on load. A stub for a function the host does not have turns the
-- suite into a test of the stub. The real surface:
--   print(line)                       scrollback (global)
--   buffer.color_print(bg, fg, text)  scrollback, colour triplets
--   ui.text_ansi(rect, line)          draw into a rect
--   ui.rect(x, y, w, h) / ui.dirty()
--   gmcp.on(pkg, fn) / gmcp.remove(id)
--   require("command").register/unregister   -- a MODULE, not a global
local printed = {}
local drawn_rects = {}

print = function(line) printed[#printed + 1] = tostring(line) end

buffer = {
  color_print = function(...)
    local a = { ... }
    printed[#printed + 1] = tostring(a[3])
  end,
}

ui = {
  dirty = function() end,
  rect = function(x, y, w, h) return { x = x, y = y, w = w, h = h } end,
  text_ansi = function(rect, line)
    drawn_rects[#drawn_rects + 1] = rect
    printed[#printed + 1] = tostring(line)
  end,
}

-- The tab bar guards its span recording on lera.render_pass(), the same way
-- guild_viking/window.lua does, so a remote render cannot clobber the local
-- layout a click is hit-tested against. That makes `lera` a real dependency
-- of popup.lua's render path -- the harness's undefined-global guard caught
-- it the moment the tab bar landed.
lera = {
  render_pass = function() return "local" end,
  display = function() return "tty" end,
}

local gmcp_subs = {}
gmcp = {
  on = function(pkg, fn) gmcp_subs[#gmcp_subs + 1] = { pkg = pkg, fn = fn }; return #gmcp_subs end,
  remove = function() end,
}

local registered
package.loaded["command"] = {
  register = function(spec) registered = spec; return 1 end,
  unregister = function() end,
}

local setup_guild_name
plugin = {
  get = function(name)
    if name ~= "stats_window" then return nil end
    return { register_guild = function(guild_name) setup_guild_name = guild_name end }
  end,
}

-- require("wm") for a sandboxed plugin exposes only make_scroller plus the
-- owner-bound popup facade (open/close/is_open) -- NOT assign, layouts or the
-- composition mutators. Stubbing only that much keeps the suite honest about
-- what the plugin is actually allowed to reach.
local popup_state = { open = false, renderer = nil, opts = nil }
package.loaded["wm"] = {
  make_scroller = function(opts)
    local offset = 0
    local sc = {}
    function sc.offset() return offset end
    function sc.following_tail() return offset == 0 end
    function sc.scroll(delta)
      offset = offset - delta
      local max = math.max(0, opts.count() - 1)
      if offset > max then offset = max end
      if offset < 0 then offset = 0 end
      return true
    end
    function sc.scroll_to_bottom() offset = 0 return true end
    return sc
  end,
  popup = {
    open = function(renderer, o)
      if popup_state.open and popup_state.opts and popup_state.opts.on_close then
        popup_state.opts.on_close()
      end
      popup_state.open, popup_state.renderer, popup_state.opts = true, renderer, o
    end,
    close = function()
      if popup_state.open and popup_state.opts and popup_state.opts.on_close then
        popup_state.opts.on_close()
      end
      popup_state.open, popup_state.renderer, popup_state.opts = false, nil, nil
    end,
    is_open = function() return popup_state.open end,
  },
}

-- Guard: the plugin must not reach for a global the host does not define.
-- Any read of an undeclared global from here on is a hard failure, which is
-- exactly the class of bug that shipped last time.
setmetatable(_G, { __index = function(_, k)
  error("plugin read undefined global '" .. tostring(k) .. "'", 2)
end })

local state = require("state")
local S = state.S
local handlers = require("handlers")
local pages = require("pages")
local init = require("init")

local function frame(pkg, data)
  data.guild = data.guild or "shaman"
  return handlers.on_gmcp(pkg, data)
end

-- ===========================================================================
-- Frame routing
-- ===========================================================================
check("foreign guild frames are rejected",
      frame("Guild.State", { guild = "viking", rank = "Jarl" }) == false)
check("foreign frame did not write state", S.rank == "")
check("unknown sub-package is ignored",
      frame("Guild.Nonesuch", { x = 1 }) == false)
check("non-table payload is ignored",
      handlers.on_gmcp("Guild.State", "nope") == false)

-- ===========================================================================
-- Guild.State
-- ===========================================================================
check("State frame accepted", frame("Guild.State", {
  subguild = "Ursus", rank = "Custos", title = "Custos Limen",
  guild_level = 1200, guild_age = 172800, combat_age = 3600,
  gp1_name = "Vis", gp1 = 40, gp1_max = 100,
  gp2_name = "Vis Major", gp2 = 3, gp2_max = 5,
  terra = 7, caelum = 4, fervor = 9, claw_depth = 2,
  spirits_learned = 5,
}) == true)
check("State: scalars written", S.rank == "Custos" and S.guild_level == 1200
      and S.gp1 == 40 and S.terra == 7 and S.fervor == 9, S.rank)
check("State: frame counter advanced", S.frames == 1, S.frames)
check("has_data becomes true after a Shaman frame", init.has_data() == true)

-- Delta semantics: a later frame carries only what changed, and an absent key
-- must leave the previous value alone rather than zeroing it.
frame("Guild.State", { gp1 = 12 })
check("State delta: present key updated", S.gp1 == 12, S.gp1)
check("State delta: absent keys preserved",
      S.rank == "Custos" and S.terra == 7 and S.gp1_max == 100,
      S.rank .. "/" .. S.terra .. "/" .. S.gp1_max)

-- ===========================================================================
-- Guild.Skills
-- ===========================================================================
frame("Guild.Skills", { cats = {
  { cat = 0, gxp = 500, last = 2, skills = 8, held = 8, maxed = 1, levels = 240 },
  { cat = 1, gxp = 900, last = 12, skills = 21, held = 10, maxed = 0, levels = 310 },
} })
check("Skills: both categories stored", #S.skillcats == 2, #S.skillcats)
check("Skills: fields parsed",
      S.skillcats[1].gxp == 500 and S.skillcats[2].skills == 21,
      S.skillcats[1].gxp)
-- A Skills frame with no `cats` key at all is a delta that changed nothing.
frame("Guild.Skills", {})
check("Skills delta without cats leaves the list alone", #S.skillcats == 2)

-- ===========================================================================
-- Guild.Powers
-- ===========================================================================
frame("Guild.Powers", { party = 1, powers = {
  { id = "vitare", k = 0, on = 1, m = 1 },
  { id = "custodio", k = 0, on = 0, m = 0 },
  { id = "scutum_spiritale", k = 1, on = 1, m = 1 },
} })
check("Powers: all three stored", #S.powers == 3, #S.powers)
check("Powers: booleans parsed",
      S.powers[1].on == true and S.powers[2].on == false
      and S.powers[1].maintained == true and S.powers[2].maintained == false)
check("Powers: kind tag parsed", S.powers[3].kind == 1, S.powers[3].kind)
check("Powers: party flag", S.party == 1)

-- The running set is authoritative on every send: a power that stopped is
-- simply absent, so the list must be REPLACED, not merged -- otherwise a
-- stopped power would show as running forever.
frame("Guild.Powers", { powers = { { id = "vitare", k = 0, on = 0, m = 1 } } })
check("Powers: list replaced wholesale, not merged", #S.powers == 1, #S.powers)
check("Powers: stopped power reflects new state", S.powers[1].on == false)

-- ===========================================================================
-- Guild.Leyline
-- ===========================================================================
-- The frame deliberately still CARRIES penalty/penalty_raw/visus even though
-- the server no longer sends them: the point is to prove the client ignores
-- them. If a future server change puts the shaman's backlash back on the
-- wire, this plugin must not start rendering it again.
frame("Guild.Leyline", {
  here = "jarnveden", here_label = "Jarnveden", here_discord = 40,
  penalty = 15, penalty_raw = 20, visus = 100,
  realms = {
    { realm = "north", d = 52 },
    { realm = "south", d = 3 },
  },
  regions = {
    { r = "angarboda", d = 12, realm = "north" },
    { r = "jarnveden", d = 40, realm = "north" },
    { r = "calm", d = 0, realm = "south" },
  },
})
check("Leyline: scalars parsed",
      S.ley_here_label == "Jarnveden" and S.ley_here_discord == 40)
check("Leyline: the shaman's own backlash is NOT ingested",
      S.ley_penalty == nil and S.ley_penalty_raw == nil and S.ley_visus == nil,
      tostring(S.ley_penalty))
check("Leyline: realms stored, hottest first",
      #S.ley_realms == 2 and S.ley_realms[1].realm == "north"
      and S.ley_realms[1].discord == 52, #S.ley_realms)
check("Leyline: regions stored", #S.ley_regions == 3, #S.ley_regions)
check("Leyline: sorted hottest first",
      S.ley_regions[1].discord == 40 and S.ley_regions[3].discord == 0,
      S.ley_regions[1].discord)
-- An empty region array is a real state ("the ley lines are calm"), so it must
-- be applied rather than treated as a missing key.
frame("Guild.Leyline", { regions = {} })
check("Leyline: empty region list is applied, not ignored", #S.ley_regions == 0)

-- ===========================================================================
-- Pages render without error and produce content
-- ===========================================================================
for _, key in ipairs(pages.ORDER) do
  local ok, lines = pcall(pages.PAGES[key].fn, 72)
  check("page '" .. key .. "' renders", ok and type(lines) == "table" and #lines > 0,
        ok and (type(lines) == "table" and #lines) or lines)
  if ok and type(lines) == "table" then
    local bad = nil
    for i, l in ipairs(lines) do
      if type(l) ~= "string" then bad = i break end
    end
    check("page '" .. key .. "' yields only strings", bad == nil, bad)
  end
end

-- Pages must be pure: rendering twice from unchanged state gives the same
-- output, and touches nothing in S.
local before = S.frames
local a = table.concat(pages.PAGES.status.fn(72), "\n")
local b = table.concat(pages.PAGES.status.fn(72), "\n")
check("status page is pure (stable output)", a == b)
check("status page mutates no state", S.frames == before)
check("status page renders combat duration and skill progress",
      a:find("In combat", 1, true) ~= nil
      and a:find("held", 1, true) ~= nil
      and a:find("levels", 1, true) ~= nil)

-- ===========================================================================
-- Command surface
-- ===========================================================================
init.on_load()
check("on_load subscribed to Guild", #gmcp_subs == 1 and gmcp_subs[1].pkg == "Guild",
      gmcp_subs[1] and gmcp_subs[1].pkg)
check("on_load registered /sham", registered ~= nil and registered.name == "/sham",
      registered and registered.name)
init.on_setup()
check("on_setup registers Shaman with stats_window", setup_guild_name == "guild_shaman",
      setup_guild_name)

registered.handler("")
-- The popup is tabbed now: ONE window titled "Shaman", with the page chosen
-- by the active tab. Assert the selected tab rather than the window title.
check("/sham bare opens the popup on the Status tab",
      popup_state.open and require("popup").current() == "status",
      require("popup").current())

-- Toggle semantics: the same page again closes rather than stacking.
registered.handler("status")
check("/sham status again closes the popup", popup_state.open == false)

registered.handler("discord")
check("/sham discord selects the Discord tab",
      popup_state.open and require("popup").current() == "discord",
      require("popup").current())

-- Switching page while one is open replaces it and leaves exactly one open.
registered.handler("powers")
check("/sham powers switches the open popup to the Powers tab",
      popup_state.open and require("popup").current() == "powers",
      require("popup").current())

-- ---- clicking the tab bar ---------------------------------------------------
-- The point of the tab bar: a click switches page without any command. Render
-- first so the spans exist (they are recorded during render, guarded on
-- lera.render_pass), then click inside the first tab's columns.
do
  local pop = require("popup")
  local r = popup_state.renderer
  r.render({ x = 0, y = 0, w = 60, h = 20 })

  check("popup exposes on_pointer once it has a tab bar",
        type(r.on_pointer) == "function")

  -- Column 0 of row 0 is inside "Status", the first tab.
  local claimed = r.on_pointer({ kind = "down", button = "left", x = 0, y = 0 })
  check("a left click on the Status tab is claimed", claimed == true)
  check("a left click on the Status tab selects it", pop.current() == "status",
        pop.current())

  -- A click past the end of the bar hits no span and must not be claimed,
  -- so the popup never swallows an interaction it did not handle.
  local miss = r.on_pointer({ kind = "down", button = "left", x = 58, y = 0 })
  check("a left click outside every tab span is not claimed", miss == false)

  -- A body click (below the bar) is likewise not a tab hit.
  local body = r.on_pointer({ kind = "down", button = "left", x = 0, y = 5 })
  check("a click below the tab bar is not treated as a tab", body == false)

  -- ---- category headers and click-to-toggle --------------------------------
  -- The powers page groups rows under the same Latin headings shmaintain
  -- prints, and a click on a row sends the toggle. Pet openers arrive as
  -- k 3 -- a subset of the combat powers the server tags k 0, split apart
  -- server-side precisely so this grouping is reproducible client-side.
  handlers.on_gmcp("Guild.Powers", {
    guild = "shaman", full = 1, party = 0,
    powers = {
      { id = "scutum_spiritale", k = 0, on = 1, m = 1 },
      { id = "vitare",           k = 0, on = 0, m = 0 },
      { id = "flumen_vitae",     k = 1, on = 1, m = 1 },
      { id = "duritia_ursi",     k = 3, on = 0, m = 1 },
      { id = "damnum_repellere", k = 2, on = 0, m = 1 },
    },
  })
  pop.toggle("powers")
  if pop.current() ~= "powers" then pop.toggle("powers") end

  local lines, targets = require("pages").powers(60)
  local function has_line(want)
    for _, l in ipairs(lines) do
      if l:gsub("\27%[[0-9;]*m", ""):find(want, 1, true) then return true end
    end
    return false
  end
  check("powers page shows the Incantationes header",
        has_line("Incantationes (Spells)"))
  check("powers page shows the Potestates Belli header",
        has_line("Potestates Belli (Combat Powers)"))
  check("powers page splits pet openers into Potestates Bestiarum",
        has_line("Potestates Bestiarum (Pet Skillsets)"))
  check("powers page shows the De Societate header",
        has_line("Potestates Societatis (De Societate)"))

  -- Every clickable row maps to the spaced form shmaintain resolves.
  local n, saw_pet = 0, false
  for _, t in pairs(targets) do
    n = n + 1
    check("target label has no underscores: " .. t.label,
          not t.label:find("_", 1, true))
    if t.label == "duritia ursi" then saw_pet = true end
  end
  check("every power row is clickable", n == 5, n)
  check("a pet opener is clickable too", saw_pet)

  -- Now click one, through the real pointer path.
  local sent = {}
  mud = { send = function(cmd) sent[#sent + 1] = cmd end }
  r.render({ x = 0, y = 0, w = 60, h = 30 })

  -- Find the drawn row for a known power and click it.
  local want_row
  for idx, t in pairs(targets) do
    if t.label == "scutum spiritale" then want_row = idx end
  end
  -- Scan the body for the row that maps to this power rather than assuming
  -- the tab bar height and scroll offset: the mapping under test is
  -- line-index -> screen-row, and asserting exactly ONE screen row produces
  -- the command verifies it far better than hardcoding the arithmetic.
  local hits = {}
  for probe_y = 0, 29 do
    sent = {}
    if r.on_pointer({ kind = "down", button = "left", x = 4, y = probe_y })
       and sent[1] == "shmaintain scutum spiritale" then
      hits[#hits + 1] = probe_y
    end
  end
  check("exactly one body row toggles a given power", #hits == 1,
        table.concat(hits, ","))
  sent = {}
  local claimed_row = r.on_pointer({
    kind = "down", button = "left", x = 4, y = hits[1] or -1 })
  check("a click on a power row is claimed", claimed_row == true)
  check("a click on a power row sends the shmaintain toggle",
        sent[1] == "shmaintain scutum spiritale", sent[1])

  -- A click on a header/blank line inside the body is not a power row and
  -- must not be claimed, so it never sends a stray command.
  local before_n = #sent
  local blank = r.on_pointer({ kind = "down", button = "left", x = 4, y = 1 })
  check("a click on a section header sends nothing",
        blank == false and #sent == before_n, tostring(blank) .. "/" .. #sent)
  mud = nil

  -- Right-click on a tab must not switch pages.
  r.on_pointer({ kind = "down", button = "left", x = 0, y = 0 })
  local before = pop.current()
  local rc = r.on_pointer({ kind = "down", button = "right", x = 20, y = 0 })
  check("a right click on the tab bar is ignored", rc == false and pop.current() == before)

  -- REGRESSION GUARD. The handler first read event.type, which the real API
  -- never sets -- scripts/default/popup.lua's local_event() emits `kind`. The
  -- tabs rendered but no click ever matched, and the tests missed it because
  -- they were written against the same wrong shape. An event carrying only
  -- `type` must therefore be ignored: if this ever passes, the handler has
  -- drifted back onto the wrong field.
  r.on_pointer({ kind = "down", button = "left", x = 0, y = 0 })   -- back to Status
  local typed = r.on_pointer({ type = "down", button = "left", x = 20, y = 0 })
  check("an event using 'type' instead of 'kind' is not claimed", typed == false)
  check("...and does not change the selected tab", pop.current() == "status", pop.current())
end

-- The popup renderer must draw through ui.text_ansi and respect the rect.
drawn_rects = {}
printed = {}
local pdrawn = popup_state.renderer.render({ x = 2, y = 3, w = 60, h = 4 }, {})
check("popup renderer draws through ui.text_ansi", #drawn_rects > 0, #drawn_rects)
check("popup renderer never exceeds the rect height", pdrawn <= 4, pdrawn)
check("popup renderer honours the rect origin",
      drawn_rects[1].x == 2 and drawn_rects[1].y == 3,
      drawn_rects[1] and (drawn_rects[1].x .. "," .. drawn_rects[1].y))
check("popup renderer handles a zero-size rect",
      popup_state.renderer.render({ x = 0, y = 0, w = 0, h = 0 }, {}) == 0)
check("popup renderer exposes the scroll contract",
      type(popup_state.renderer.scroll) == "function"
      and type(popup_state.renderer.following_tail) == "function")

registered.handler("close")
check("/sham close closes the popup", popup_state.open == false)

-- The scrollback escape hatch still works.
printed = {}
registered.handler("discord print")
check("/sham <page> print still dumps to the scrollback", #printed > 0, #printed)
check("/sham <page> print does NOT open a popup", popup_state.open == false)

printed = {}
registered.handler("ingest")
check("/sham ingest reports frame counts", #printed == 2, #printed)

printed = {}
registered.handler("bogus")
check("/sham bogus prints usage",
      #printed == 1 and printed[1]:find("usage") ~= nil, printed[1])

-- A frame arriving through the real subscription path reaches the writers.
S.rank = ""
gmcp_subs[1].fn("Guild.State", { guild = "shaman", rank = "Magister" })
check("subscription callback routes into the writers", S.rank == "Magister", S.rank)

-- ===========================================================================
-- Paged pushes (regression)
-- ===========================================================================
-- Guild payloads too big for one frame are partitioned by the protocol layer
-- (secure/protocol/namespace_info_impl.h:574) and a sliced list concatenates
-- across pages in page order. Dispatching each page straight to a writer left
-- only the LAST slice, because write_powers replaces S.powers wholesale --
-- a shaman running fifteen powers saw a handful in the panel while shmaintain
-- listed them all.
-- Sentinel so "still the old list" is distinguishable from "the new list,
-- truncated" -- earlier cases in this file leave real rows in S.powers.
S.powers = { { id = "sentinel", kind = 0, on = false, maintained = false } }
handlers.on_gmcp("Guild.Powers", {
  guild = "shaman", full = 1, page = 1, pages = 2,
  powers = {
    { id = "vitare",           k = 0, on = 0, m = 1 },
    { id = "ictum_excipere",   k = 0, on = 1, m = 1 },
    { id = "simulatus_impetus",k = 0, on = 1, m = 1 },
  },
})
check("a non-final page does not publish a partial list",
      #S.powers == 1 and S.powers[1].id == "sentinel",
      #S.powers .. "/" .. tostring(S.powers[1] and S.powers[1].id))

handlers.on_gmcp("Guild.Powers", {
  guild = "shaman", page = 2, pages = 2,
  powers = {
    { id = "depellere",      k = 0, on = 1, m = 1 },
    { id = "scutum_spiritale", k = 0, on = 1, m = 1 },
  },
  party = 0,
})
check("sliced pages concatenate in page order", #S.powers == 5, #S.powers)
check("page 1 rows survive reassembly",
      S.powers[1] and S.powers[1].id == "vitare",
      S.powers[1] and S.powers[1].id)
check("page 2 rows land after page 1 rows",
      S.powers[5] and S.powers[5].id == "scutum_spiritale",
      S.powers[5] and S.powers[5].id)

-- Non-list keys riding a later page must still reach the writer.
check("scalars from a later page are applied", S.party == 0, S.party)

-- An unpaged push after a paged one must not inherit the run.
handlers.on_gmcp("Guild.Powers", {
  guild = "shaman", full = 1,
  powers = { { id = "vitare", k = 0, on = 1, m = 1 } },
})
check("an unpaged push replaces, not appends", #S.powers == 1, #S.powers)

-- ===========================================================================
-- stats_window integration
-- ===========================================================================
printed = {}
local drawn = init.render_guild_stats({ x = 0, y = 0, w = 40, h = 10 }, {})
check("render_guild_stats draws rows", drawn > 0, drawn)
check("render_guild_stats drew exactly what it reported", #printed == drawn,
      #printed .. " vs " .. drawn)

printed = {}
local clipped = init.render_guild_stats({ x = 0, y = 0, w = 40, h = 2 }, {})
check("render_guild_stats respects the rect height", clipped <= 2, clipped)

check("render_guild_stats handles a zero-height rect",
      init.render_guild_stats({ x = 0, y = 0, w = 40, h = 0 }, {}) == 0)

-- Before any frame has landed the pane must claim no space at all, so a
-- non-shaman character never sees an empty shaman block.
local saved_frames = S.frames
S.frames = 0
check("has_data is false before the first frame", init.has_data() == false)
check("render_guild_stats draws nothing before the first frame",
      init.render_guild_stats({ x = 0, y = 0, w = 40, h = 10 }, {}) == 0)
S.frames = saved_frames

-- ===========================================================================
-- Disconnect handling
-- ===========================================================================
registered.handler("status")
check("popup open before unload", popup_state.open == true)
init.on_unload()
check("on_unload closes the popup so it cannot outlive the plugin",
      popup_state.open == false)

init.on_disconnect()
check("on_disconnect resets the ingestion counters", S.frames == 0)
check("on_disconnect PRESERVES guild data (it is still the best view)",
      S.rank == "Magister" and S.gp1_max == 100, S.rank)

emit(string.format("\n%d failures", failures))
os.exit(failures == 0 and 0 or 1)
