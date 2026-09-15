-- Shared state for the guild_shaman plugin.
--
-- One table, mutated in place by handlers.lua and read by pages/*.lua. Same
-- shape and rationale as guild_viking's state.lua: pages must never have to
-- ask whether a field exists yet, so every key is seeded here with a value of
-- the right TYPE (empty table, zero, empty string) rather than nil. A page
-- that renders before the first GMCP frame lands then shows an empty panel
-- instead of erroring on a nil index.
local M = {}

M.S = {
  -- ---- Guild.State ------------------------------------------------------
  -- Identity and the two Vis pools. gp1/gp2 keep the server's own generic
  -- naming (gp1_name is "Vis", gp2_name "Vis Major") so a rename server-side
  -- needs no client change.
  subguild = "",
  rank = "",
  title = "",
  guild_level = 0,
  guild_age = 0,
  combat_age = 0,
  gp1_name = "Vis", gp1 = 0, gp1_max = 0,
  gp2_name = "Vis Major", gp2 = 0, gp2_max = 0,
  -- Live combat resources. terra/caelum are the Earth/Sky companion flows;
  -- fervor and claw_depth drive the Ungues Spiritualis chain.
  terra = 0, caelum = 0,
  fervor = 0, claw_depth = 0,
  spirits_learned = 0,

  -- ---- Guild.Skills -----------------------------------------------------
  -- One entry per skill category, keyed by the server's numeric category id.
  -- Each: { cat, gxp, last, skills, held, maxed, levels }.
  skillcats = {},

  -- ---- Guild.Powers -----------------------------------------------------
  -- Flat list of every toggleable power, each { id, k, on, m } where k is
  -- 0 = combat power, 1 = maintained spell, 2 = De Societate power.
  powers = {},
  party = 0,

  -- ---- Guild.Leyline ----------------------------------------------------
  -- here/here_label/here_discord describe the room the shaman is standing in;
  -- ley_realms is the per-realm rollup and ley_regions the drifted areas.
  --
  -- There are no penalty/visus fields: the server stopped sending the shaman's
  -- own backlash on this panel deliberately, and holding slots for it here
  -- would invite something to fill them again.
  ley_here_label = "", ley_here_discord = 0,
  ley_realms = {}, ley_regions = {},

  -- Ingestion bookkeeping, for the status line.
  frames = 0,
  last_frame_at = 0,
}

-- Called on disconnect. Guild DATA is deliberately preserved (the same ruling
-- guild_viking's state.reset_connection() makes): it is still the best view of
-- the character until fresh frames arrive, and wiping it makes every panel
-- flash empty on a reconnect. Only the per-connection counters reset.
function M.reset_connection()
  M.S.frames = 0
  M.S.last_frame_at = 0
end

return M
