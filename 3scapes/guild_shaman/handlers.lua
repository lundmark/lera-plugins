-- Guild.* frame parsers for the shaman guild.
--
-- One writer per server panel (players/shaman/obj/include/gmcp.h). Writers
-- only ever touch S; they never draw and never call ui.dirty() -- init.lua
-- marks the UI dirty once per frame, so a writer that did it too would just
-- queue redundant redraws.
--
-- DELTA SEMANTICS, and why every writer below is defensive about absent keys:
-- the first push of a sub-package after subscribing carries `full: 1` plus the
-- complete key set; every later push carries ONLY the keys that changed, with
-- no `full` key. So on a full frame a key's absence means "gone", but on a
-- delta it means "unchanged" -- and a writer that rebuilt its list from a
-- delta would wipe data the server never intended to retract. Each writer
-- therefore checks the key is actually present before replacing anything.
local S = require("state").S

local M = {}

local function num(x) return tonumber(x) or 0 end
local function str(x) return (x ~= nil) and tostring(x) or "" end

-- ---------------------------------------------------------------------------
-- Guild.State
-- ---------------------------------------------------------------------------
-- Scalars only, so a delta can be applied field by field: each key is written
-- only when the frame actually carries it.
local function write_state(d)
  if d.subguild        ~= nil then S.subguild        = str(d.subguild) end
  if d.rank            ~= nil then S.rank            = str(d.rank) end
  if d.title           ~= nil then S.title           = str(d.title) end
  if d.guild_level     ~= nil then S.guild_level     = num(d.guild_level) end
  if d.guild_age       ~= nil then S.guild_age       = num(d.guild_age) end
  if d.combat_age      ~= nil then S.combat_age      = num(d.combat_age) end
  if d.gp1_name        ~= nil then S.gp1_name        = str(d.gp1_name) end
  if d.gp1             ~= nil then S.gp1             = num(d.gp1) end
  if d.gp1_max         ~= nil then S.gp1_max         = num(d.gp1_max) end
  if d.gp2_name        ~= nil then S.gp2_name        = str(d.gp2_name) end
  if d.gp2             ~= nil then S.gp2             = num(d.gp2) end
  if d.gp2_max         ~= nil then S.gp2_max         = num(d.gp2_max) end
  if d.terra           ~= nil then S.terra           = num(d.terra) end
  if d.caelum          ~= nil then S.caelum          = num(d.caelum) end
  if d.fervor          ~= nil then S.fervor          = num(d.fervor) end
  if d.claw_depth      ~= nil then S.claw_depth      = num(d.claw_depth) end
  if d.spirits_learned ~= nil then S.spirits_learned = num(d.spirits_learned) end
end

-- ---------------------------------------------------------------------------
-- Guild.Skills
-- ---------------------------------------------------------------------------
-- The server sends all six categories together or not at all, so this list is
-- replaced wholesale when `cats` is present -- but only then.
local function write_skills(d)
  if type(d.cats) ~= "table" then return end
  local out = {}
  for _, r in ipairs(d.cats) do
    out[#out + 1] = {
      cat = num(r.cat), gxp = num(r.gxp), last = num(r.last),
      skills = num(r.skills), held = num(r.held),
      maxed = num(r.maxed), levels = num(r.levels),
    }
  end
  S.skillcats = out
end

-- ---------------------------------------------------------------------------
-- Guild.Powers
-- ---------------------------------------------------------------------------
-- `powers` is the authoritative running set each time it is sent: the server
-- rebuilds it from COMBAT_POWER_IDS plus the live maintained/societas
-- mappings, so a power that stopped simply is not in the new array. Replacing
-- the list wholesale is therefore correct -- and necessary, since merging
-- would leave stopped powers showing as running forever.
local function write_powers(d)
  if d.party ~= nil then S.party = num(d.party) end
  if type(d.powers) ~= "table" then return end
  local out = {}
  for _, r in ipairs(d.powers) do
    out[#out + 1] = {
      id = str(r.id), kind = num(r.k),
      on = num(r.on) == 1, maintained = num(r.m) == 1,
    }
  end
  S.powers = out
end

-- ---------------------------------------------------------------------------
-- Guild.Leyline
-- ---------------------------------------------------------------------------
-- `regions` only carries regions that have DRIFTED from baseline, so an empty
-- array is a real state ("the world is calm"), not a missing one -- which is
-- exactly why the presence check is on the key and not on its length.
local function write_leyline(d)
  -- d.here (the raw region key) is no longer sent and is not read: it could
  -- be a "path:/players/<wiz>/areas/..." fallback, which is an internal key,
  -- not an area name. here_label is the only place-name on this panel.
  if d.here_label   ~= nil then S.ley_here_label   = str(d.here_label) end
  if d.here_discord ~= nil then S.ley_here_discord = num(d.here_discord) end
  -- penalty / penalty_raw / visus are deliberately NOT read. The server no
  -- longer sends them (see send_gmcp_leyline()'s header in
  -- players/shaman/obj/include/gmcp.h) and must not start again: discord is
  -- world state a client may render, the damage a shaman is personally losing
  -- to it is not. Keeping readers here would silently re-enable that the
  -- moment anything put the fields back on the wire.
  if type(d.realms) == "table" then
    local rs = {}
    for _, r in ipairs(d.realms) do
      rs[#rs + 1] = { realm = str(r.realm), discord = num(r.d) }
    end
    table.sort(rs, function(a, b) return a.discord > b.discord end)
    S.ley_realms = rs
  end
  if type(d.regions) == "table" then
    local out = {}
    for _, r in ipairs(d.regions) do
      out[#out + 1] = { region = str(r.r), discord = num(r.d), realm = str(r.realm) }
    end
    -- Hottest first: a Discord panel is read to find where the damage is.
    table.sort(out, function(a, b) return a.discord > b.discord end)
    S.ley_regions = out
  end
end

-- ---------------------------------------------------------------------------
-- Page reassembly
-- ---------------------------------------------------------------------------
-- Guild pushes are PAGED. When a payload does not fit one frame the protocol
-- layer partitions it (secure/protocol/namespace_info_impl.h:574) and stamps
-- `page`/`pages` on each piece. A list too large for the remaining budget is
-- SLICED, a sliced key never shares a page with anything else, and "pages of
-- one push concatenate repeated keys in page order, so the client rebuilds
-- the list."
--
-- Dispatching each page straight to a writer therefore truncated every sliced
-- list to whatever the LAST page happened to carry: write_powers replaces
-- S.powers wholesale, so a two-page Guild.Powers left only the tail slice
-- showing. That is why a shaman running fifteen powers saw a handful in the
-- panel while shmaintain listed them all. guild_viking/protocol.lua's
-- merge_page has always done this; the shaman plugin never got it.
local ENVELOPE = { guild = true, full = true, page = true, pages = true }

-- Open page runs, keyed by sub-package suffix. A run only ever spans the
-- frames of a single push, so an interrupted one is replaced rather than aged
-- out -- see the `page <= 1` reset below.
local runs = {}

-- An empty table is indistinguishable from an empty array in Lua, which is
-- fine here: concatenating an empty slice into an empty slice is a no-op
-- either way.
local function is_array(v)
  return type(v) == "table" and (#v > 0 or next(v) == nil)
end

-- Merge one page's keys into a run. A key repeated across pages is a sliced
-- array whose slices concatenate in page order; only arrays are ever sliced
-- server-side, so a repeated non-array is last-wins.
local function merge_page(run, data)
  for key, value in pairs(data) do
    if not ENVELOPE[key] then
      local prev = run[key]
      if prev == nil then
        run[key] = value
      elseif is_array(prev) and is_array(value) then
        for i = 1, #value do prev[#prev + 1] = value[i] end
      else
        run[key] = value
      end
    end
  end
end

M.PANELS = {
  State   = write_state,
  Skills  = write_skills,
  Powers  = write_powers,
  Leyline = write_leyline,
}

-- Entry point from init.lua's gmcp.on("Guild", ...) subscription. `package` is
-- the full dotted name ("Guild.Powers"); the suffix after the last dot selects
-- the writer. Frames from another guild are dropped here rather than in each
-- writer: the server stamps `guild` on every payload precisely so a client
-- carrying several guild plugins can tell them apart.
function M.on_gmcp(package, data)
  if type(data) ~= "table" then return false end
  if type(data.guild) ~= "string" or data.guild:lower() ~= "shaman" then
    return false
  end
  local suffix = tostring(package):match("([^.]+)$")
  local fn = suffix and M.PANELS[suffix]
  if not fn then return false end

  S.frames = S.frames + 1
  S.last_frame_at = os.time()

  -- Unpaged push (the common case): the frame IS the payload.
  local pages = tonumber(data.pages) or 1
  if pages <= 1 then
    runs[suffix] = nil
    fn(data)
    return true
  end

  -- Paged push: accumulate, and only run the writer once the last page lands.
  -- Writers replace list keys wholesale, so handing them a partial run would
  -- reintroduce exactly the truncation this exists to prevent.
  local page = tonumber(data.page) or 1
  local run = runs[suffix]
  if not run or page <= 1 then
    run = { guild = data.guild }
    runs[suffix] = run
  end
  merge_page(run, data)
  if page < pages then return false end

  runs[suffix] = nil
  fn(run)
  return true
end

return M
