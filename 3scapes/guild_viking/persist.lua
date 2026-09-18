-- Cross-session persistence: the rolling price history (market.lua),
-- (stage 2) the page options and
-- current page (page_opts.lua / window.lua), and (stage 4) the auto-trade
-- settings knobs (autotrader/core.lua, Task 1), the auto-raid settings
-- (autoraid.lua, Task 8: target/ships/convoy), the auto-voyage settings
-- (autovoyage.lua, Task 7: risk/ship/mission_prio/etc) and (viking husbandry
-- plan, Task 3) the Auto-Herd settings (autoherd.lua: goal/reserve/keep/
-- trait_pref/restock/crossbreed/buy_quality/feed_guard/etc, plus
-- per-building overrides), mirroring LEGACY's
-- SetVariable("popt_"..k) + SetVariable("page", ...)
-- (/home/simon/code/3s_scripts_old/lua/guild_viking.lua:3025-3040) -- LEGACY's
-- OnPluginSaveState (MAIN 3023-3024) actually serializes the WHOLE `state`
-- table, so state.autoraid/state.autovoyage survived a reload there for
-- free; this file has to carry each one explicitly instead. Everything else
-- in state.lua is per-connection/session data (combat, carts in transit,
-- etc.) that would be stale on the next load, so it is deliberately NOT
-- persisted here.
local market = require("market")
local page_opts = require("page_opts")
local window = require("window")
-- Private-repo module; nil in the public base. See util.optional_require.
local optional_require = require("util").optional_require
local at_core = optional_require("autotrader.core")

local M = {}

-- autoraid.lua no longer requires persist at its own top level (see that
-- module's header), so a top-level `require("autoraid")` here would be
-- safe on its own -- but autovoyage.lua DOES still require persist at ITS
-- top level (via notify.lua, which requires autoraid THEN autovoyage), so
-- persist.lua's own first load happens WHILE autovoyage.lua is still
-- mid-load. A top-level `require("autovoyage")` here would therefore close
-- a real cycle (autovoyage -> persist -> autovoyage, before the middle
-- persist.lua load has anything to hand back). Deferring BOTH requires into
-- the functions below (called only from M.save()/M.load(), long after every
-- module has finished loading) sidesteps the cycle without depending on
-- notify.lua's particular require order -- same idiom as autoraid.lua's own
-- deferred require("persist") and popups.lua's deferred require("wm").
-- autoherd.lua (Task 3 of the viking husbandry plan) is deferred the same
-- way for the same reason (see that module's own header) -- nothing
-- requires it from a page yet, so it is not part of any live cycle today,
-- but deferring costs nothing and keeps this file's require list uniform.
-- Each returns nil in the public base, where the module is not installed.
local function ar_module() return optional_require("autoraid") end
local function av_module() return optional_require("autovoyage") end
local function ah_module() return optional_require("autoherd") end
local function aw_module() return optional_require("autowar") end

-- Snapshot one automation module's slice, or nil when it is not installed.
local function auto_snapshot(mod_fn, key)
  local mod = mod_fn()
  if not mod then return nil end
  return mod.snapshot()[key]
end

function M.save()
  local opts = {}
  for _, o in ipairs(page_opts.all()) do opts[o.key] = o.value end

  -- What is already persisted, so an absent module's slice survives a save
  -- made by the public base (see the fallbacks below).
  local prev = store.get() or {}

  -- Native store APIs return false on failure; legacy stubs return nil on success.
  if store.set({
    price_history = market.snapshot().price_history,
    page_opts = opts,
    page = window.current_page(),
    -- Fall back to whatever is already stored when a module is absent. The
    -- public base must not blank a private automation slice just because it
    -- cannot see the module that owns it: a user who loaded the public copy
    -- once would otherwise lose every auto* setting on the next save.
    autotrade = (at_core and at_core.snapshot().autotrade) or prev.autotrade,
    autoraid = auto_snapshot(ar_module, "autoraid") or prev.autoraid,
    autovoyage = auto_snapshot(av_module, "autovoyage") or prev.autovoyage,
    autoherd = auto_snapshot(ah_module, "autoherd") or prev.autoherd,
    autowar = auto_snapshot(aw_module, "autowar") or prev.autowar,
  }) == false then
    error("store.set failed: persistence snapshot was not accepted")
  end
  if store.save() == false then
    error("store.save failed: persistence snapshot was not saved to disk")
  end
end

function M.load()
  store.load()
  local data = store.get()
  if not data then return end

  if data.price_history then
    market.restore({ price_history = data.price_history })
  end

  if data.page_opts then
    for k, v in pairs(data.page_opts) do page_opts.set(k, v) end
  end
  if data.page then
    window.set_page(data.page)
  end
  if data.autotrade then
    if at_core then at_core.restore({ autotrade = data.autotrade }) end
  end
  -- All three keys are ABSENT in a store file saved before their own fix --
  -- data.autoraid/data.autovoyage/data.autoherd are simply nil then, so
  -- each branch is skipped and that module's own M.settings() lazily
  -- creates fresh defaults on first use, exactly as if this file had never
  -- been touched.
  if data.autoraid then
    if ar_module() then ar_module().restore({ autoraid = data.autoraid }) end
  end
  if data.autovoyage then
    if av_module() then av_module().restore({ autovoyage = data.autovoyage }) end
  end
  if data.autoherd then
    if ah_module() then ah_module().restore({ autoherd = data.autoherd }) end
  end
  if data.autowar then
    if aw_module() then aw_module().restore({ autowar = data.autowar }) end
  end
end

return M
