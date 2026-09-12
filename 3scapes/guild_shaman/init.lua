-- Guild Shaman plugin for lera.
--
-- Consumes the four Guild.* GMCP panels the shaman gobj pushes
-- (players/shaman/obj/include/gmcp.h): State, Skills, Powers and Leyline.
-- Everything here is read-only -- this plugin renders what the server reports
-- and sends no commands of its own, so there is no automation surface to
-- govern and nothing for the deadmans plugin to gate.
--
-- Layout, mirroring guild_viking's separation of concerns at a much smaller
-- scale (four panels rather than thirty, so no window.lua/page_opts machinery
-- is warranted):
--   state.lua    the shared S table
--   handlers.lua one writer per GMCP panel
--   pagelib.lua  formatting helpers
--   pages.lua    pure page builders (Status / Powers / Discord)
--   init.lua     registration, the /sham command, stats_window integration
local S = require("state").S
local state = require("state")
local handlers = require("handlers")
local pages = require("pages")
local P = require("pagelib")
local popup = require("popup")
-- The slash-command registry is a Lua module, not one of the C-provided
-- globals (gmcp/buffer/ui/mud/timer/trigger/store are), so it has to be
-- required like guild_viking's init.lua does. Registering against a bare
-- `command` global fails at on_load with "attempt to index global 'command'".
local command = require("command")

local M = {}
M.name = "guild_shaman"
M.version = "1.0"
-- Same slot guild_druid uses: after player_stats (40) so vitals are already
-- parsed, before stats_window (100) so render_guild_stats has data to draw.
M.priority = 45

local gmcp_id, command_id

local function note(hex, text)
  buffer.color_print(nil, hex, text)
end

-- Print a page's lines into the scrollback. print() is the scrollback API for
-- scripts (buffer.color_print takes bg/fg/text triplets and has no plain-line
-- form, and there is no buffer.print at all); the page builders already emit
-- SGR escapes inline, which the buffer renders directly.
--
-- Width is fixed at 72 rather than read from the terminal: lera exposes no
-- ui.width, and the pages use width only for rule length and bar sizing, so a
-- fixed value costs decoration fidelity on very wide or narrow terminals and
-- nothing else.
local PAGE_WIDTH = 72

local function print_page(key)
  local page = pages.PAGES[key]
  if not page then return false end
  for _, line in ipairs(page.fn(PAGE_WIDTH)) do
    print(line)
  end
  return true
end

-- ---------------------------------------------------------------------------
-- /sham
-- ---------------------------------------------------------------------------
local function sham_command(rest)
  rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()

  -- Default surface is the popup window, matching how guild_viking presents
  -- its pages -- the profile's wm slots are all taken, so a guild plugin gets
  -- a real window via the popup overlay rather than a pane. A bare `/sham`
  -- toggles Status; `/sham <page> print` still dumps to the scrollback for
  -- anyone who wants it inline or copyable.
  local page_key, modifier = rest:match("^(%a+)%s+(%a+)$")
  if page_key and modifier == "print" and pages.PAGES[page_key] then
    print_page(page_key)
    return
  end

  if rest == "" then
    popup.toggle("status")
    return
  end
  if rest == "close" then
    popup.close()
    return
  end
  if pages.PAGES[rest] then
    popup.toggle(rest)
    return
  end
  if rest == "ingest" then
    -- Diagnostic counterpart to /vik status: proves whether frames are
    -- actually arriving, which is the first thing to check when a panel
    -- looks stale.
    note("FFA500", string.format(
      "[Shaman] %d frame(s) ingested; last %s.",
      S.frames,
      S.last_frame_at > 0
        and (os.time() - S.last_frame_at) .. "s ago"
        or "never"))
    note("808080", string.format(
      "[Shaman] powers %d | skill categories %d | disturbed regions %d",
      #S.powers, #S.skillcats, #S.ley_regions))
    return
  end

  note("FF0000", "[Shaman] usage: /sham [status | powers | discord | close | ingest] | /sham <page> print")
end

-- ---------------------------------------------------------------------------
-- stats_window integration
-- ---------------------------------------------------------------------------
-- Compact summary for the shared stats pane: the two Vis pools, the live
-- combat resources, and the discord penalty when one is actually being paid.
-- Deliberately short -- the pane is shared with other plugins, so this returns
-- the number of rows it used and never draws past `h`.
function M.render_guild_stats(rect, opts)
  opts = opts or {}
  local x, y, w, h
  if type(rect.x) == "function" then
    x, y, w, h = rect:x(), rect:y(), rect:w(), rect:h()
  else
    x, y, w, h = rect.x, rect.y, rect.w, rect.h
  end
  if not w or not h or w <= 0 or h <= 0 then return 0 end
  -- Nothing has arrived yet: draw nothing rather than a row of zeroes, so the
  -- pane does not claim space for a guild the player may not even be in.
  if S.frames == 0 then return 0 end

  local barw = math.max(6, math.min(10, w - 18))
  local lines = {}
  lines[#lines + 1] = string.format("%s %s %d/%d",
    P.C.cyan .. "Vis" .. P.RESET,
    P.bar(barw, S.gp1, S.gp1_max, P.pct_color(S.gp1, S.gp1_max)),
    S.gp1, S.gp1_max)
  if S.gp2_max > 0 then
    lines[#lines + 1] = string.format("%s %s %d/%d",
      P.C.magenta .. "VsM" .. P.RESET,
      P.bar(barw, S.gp2, S.gp2_max, P.pct_color(S.gp2, S.gp2_max)),
      S.gp2, S.gp2_max)
  end
  lines[#lines + 1] = string.format("%sT%s%d %sC%s%d %sClw%s%d %sFvr%s%d",
    P.C.green, P.RESET, S.terra,
    P.C.bright_cyan, P.RESET, S.caelum,
    P.C.yellow, P.RESET, S.claw_depth,
    P.C.magenta, P.RESET, S.fervor)
  -- Local discord, NOT the shaman's backlash. The pane used to show
  -- "Discord -N%" -- the damage actually being lost -- which came from the
  -- penalty field the server no longer sends (see send_gmcp_leyline()'s
  -- header). here_discord is world state: how disturbed this room is.
  if S.ley_here_discord > 0 then
    lines[#lines + 1] = string.format("%sDiscord%s %d",
      P.C.red, P.RESET, S.ley_here_discord)
  end

  -- ui.text_ansi into a one-row rect per line, the same way guild_druid's own
  -- render_guild_stats draws into the shared pane. There is no
  -- buffer.color_print_at -- buffer.* writes to the scrollback, not to a rect.
  local drawn = 0
  for i = 1, math.min(#lines, h) do
    ui.text_ansi(ui.rect(x, y + i - 1, w, 1), lines[i])
    drawn = drawn + 1
  end
  return drawn
end

-- `stats_window` calls this before it gives a guild plugin any rows. The
-- GMCP frame count is the authoritative readiness signal: cached state from a
-- previous connection is intentionally retained, but must not claim panel
-- space until this connection has actually received Shaman data.
function M.has_data()
  return S.frames > 0
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function M.on_load()
  -- One registration covers every Guild.* sub-package: lera dispatches on the
  -- dot-boundary prefix, so a panel added server-side later needs no change
  -- here. handlers.on_gmcp drops frames stamped with another guild.
  gmcp_id = gmcp.on("Guild", function(pkg, data)
    if handlers.on_gmcp(pkg, data) then
      if ui and ui.dirty then ui.dirty() end
    end
  end)

  local id, err = command.register({
    name = "/sham",
    usage = "/sham [status | powers | discord | close | ingest] | /sham <page> print",
    summary = "Shaman guild status, maintained powers and leyline discord",
    description = "Opens the shaman guild panels fed by GMCP as a scrollable "
      .. "popup window (a second call to the same page closes it): status "
      .. "(rank, Vis pools, combat resources, spirit experience), powers "
      .. "(every toggleable power and whether it is running), and discord "
      .. "(local leyline strain plus the disturbed realms and areas). 'ingest' "
      .. "reports "
      .. "whether GMCP frames are arriving, and '<page> print' dumps a page "
      .. "into the scrollback instead of the window.",
    handler = function(rest) sham_command(rest) end,
  })
  if id then
    command_id = id
  elseif err then
    note("FF0000", "[Shaman] command registration failed: " .. tostring(err))
  end
end

function M.on_setup()
  -- stats_window is loaded before guild plugins in the shared profile.
  -- Registering here makes its compact guild section discover this plugin
  -- after a profile load or a Char.Vitals-driven guild switch.
  local sw = plugin.get("stats_window")
  if sw and sw.register_guild then sw.register_guild("guild_shaman") end
end

function M.on_unload()
  popup.close()
  if gmcp_id then gmcp.remove(gmcp_id) end
  if command_id then command.unregister(command_id) end
end

-- Guild data is preserved across a disconnect (see state.reset_connection);
-- only the per-connection ingestion counters reset.
function M.on_disconnect()
  state.reset_connection()
end

return M
