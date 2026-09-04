-- Autostepper Plugin for Lera
-- Automatically walks routes, checking rooms and killing targets
-- Requires: speedwalk, roominfo plugins

local M = {}
M.name = "autostepper"
M.version = "1.0"
M.priority = 40  -- After roominfo (10), before speedwalk (50)

--------------------------------------------------------------------------------
-- Dependencies
--------------------------------------------------------------------------------

-- Output colours. buffer.color_print takes (bg, fg, text) triplets with fg as
-- nil, a 0-255 palette index or "RRGGBB" (src/lua/api_buffer.c:461) -- the same
-- call every other plugin in this tree prints its replies with
-- (guild_viking/autotrader/tick.lua, mercenary/command_ui.lua). The red is
-- autotrader's, deliberately: a hard stop should look the same wherever it
-- comes from.
--
-- The TAG is one fixed colour on every line, so the stepper's own narration is
-- findable in a busy combat scroll. The MESSAGE colour says what kind of line
-- it is -- the distinction worth having at a glance is "it moved" vs "it
-- attacked" vs "something needs me" -- and ordinary narration is left at nil,
-- the buffer's default foreground: repainting every line would make the
-- colours mean nothing.
--
-- Loudness is the organising idea, not prettiness: a step is the line the
-- stepper emits most, so it is the quietest thing on the list, and the eye
-- should be pulled by the rare lines instead. Headings are violet rather than
-- a second amber -- next to COLOR_WARN one more gold would have read as "look
-- at this" when it only means "a report starts here".
local COLOR_TAG   = "5FAFD7"   -- steel blue: the [autostepper] tag, always
local COLOR_INFO  = nil        -- ordinary narration: the default foreground
local COLOR_HEAD  = "CE93D8"   -- violet: report headings (Status:, Commands:)
local COLOR_RUN   = "9CCC65"   -- green: start, stop, complete, mode changes
local COLOR_STEP  = "9E9E9E"   -- grey: movement, the routine line
local COLOR_FIGHT = "FF8A65"   -- coral: attacking
local COLOR_WARN  = "FFC107"   -- amber: a guess, a refusal, something to see
local COLOR_ERROR = "FF4444"   -- red: the run cannot go on (autotrader's red)
local COLOR_TRACE = "78909C"   -- slate: /step trace, off by default

local function log(msg, color)
  buffer.color_print(nil, COLOR_TAG, "[autostepper] ",
                     nil, color or COLOR_INFO, tostring(msg))
end

-- Narration from a module that does not own the palette: explore/mode.lua
-- names the KIND of line it is emitting and this maps it, so the colours have
-- exactly one definition and retuning them stays a one-block edit.
local COLOR_BY_KIND = {
  run = COLOR_RUN, step = COLOR_STEP, fight = COLOR_FIGHT,
  warn = COLOR_WARN, error = COLOR_ERROR, head = COLOR_HEAD,
}

local function log_kind(msg, kind)
  log(msg, kind and COLOR_BY_KIND[kind] or COLOR_INFO)
end

-- /step trace. Off by default and silent when off.
--
-- It exists because the events that drive an arrival are INVISIBLE in a
-- session log: a GMCP frame prints nothing, and neither does a settle timer
-- firing. A run that stepped twice with no MUD output between the two steps
-- (seen live in the chaos sea, 2026-09-03) is therefore indistinguishable, from
-- the outside, between "a stray frame armed the settle" and "a prompt that was
-- not ours completed the arrival" -- and those want opposite fixes. This turns
-- the invisible half of the state machine into lines you can paste.
local tracing = false

local function trace(msg)
  if not tracing then return end
  log("trace: " .. msg, COLOR_TRACE)
end

local sw = nil      -- speedwalk plugin (set in on_load)
local ri = nil      -- roominfo plugin (set in on_load)
local explore = require("explore.mode")

-- Hand the explore module our logger, so its narration wears the same tag and
-- the same palette. Guarded because debug_set_explore installs partial
-- stand-ins; a module given no logger falls back to a plain tagged print.
local function wire_explore_logger()
  if explore and explore.set_logger then explore.set_logger(log_kind) end
end
wire_explore_logger()

-- Area profiles, by name. A profile is data plus four predicates; no engine
-- logic lives in one.
local AREAS = {
  chaossea = "areas.chaossea",
}
local area_cache = {}

local function load_area(name)
  if area_cache[name] then return area_cache[name] end
  local path = AREAS[name]
  if not path then return nil end
  local ok, mod = pcall(require, path)
  if not ok then
    log("area '" .. name .. "' failed to load: " .. tostring(mod), COLOR_ERROR)
    return nil
  end
  area_cache[name] = mod
  return mod
end

-- Test seam: swap the explore module for a stand-in.
function M.debug_set_explore(stub)
  explore = stub or require("explore.mode")
  wire_explore_logger()
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local state = "idle"    -- idle, stepping, fighting
local prompt_count = 0  -- Count of prompts received (diagnostic only)
local pending_prompts = 0  -- prompts still owed before the current step arrives
local enabled = false   -- Is autostepper active?
local prompt_trigger_id = nil  -- Trigger ID for prompt detection
local no_target_trigger_id = nil  -- Trigger ID for "There is no X here."
local failed_attacks = 0  -- count of attacks whose keyword never resolved
-- Refreshes that timed out. A run that decides from a pruned guess instead of
-- the server's answer used to do it in complete silence; a climbing count here
-- is the difference between "the plugin is confused" and "the answers are not
-- arriving", which is the first thing worth knowing.
local unanswered_refreshes = 0

-- Which source do_step() takes steps from: "explore" or "route". Fixed once,
-- in M.start, and never re-derived from explore.active() per step. Deciding
-- it fresh every step meant that the moment explore mode deactivated itself
-- mid-run (the in_area check leaving the area, say), the very next do_step()
-- would take the route branch and call sw.take_step() -- walking a stored
-- speedwalk path from wherever the player now stands, outside the area.
local run_mode = nil

-- The settle timer is armed from roominfo.on_room_frame -- ANY accepted room
-- frame, not just Room.Info -- because no single package is a reliable
-- arrival signal. The server suppresses a resend when a payload repeats the
-- last one it sent, and in a maze where many rooms share a name and exit set,
-- Room.Info is exactly the package most likely to be suppressed (the live
-- stall this fixed: two adjacent rooms with identical name/exits/num, differing
-- only in contents, left Room.Info silent with no prompt pattern configured to
-- fall back on). Arming from the generic signal means whichever of
-- Room.Info/Room.Contents/Room.Map actually arrives starts the settle.
--
-- A frame lands before the room text and therefore before the prompt. The
-- settle is not acted on immediately, though: a burst is up to three separate
-- frames (Info, then Contents, then Map), so a decision made in the first
-- frame's callback could read the previous room's monsters. Settling for a
-- moment lets the whole burst -- including a paged Room.Contents -- land
-- first; the `if settle_timer then return end` dedupe below means only the
-- first frame in a burst arms anything, and the timer's job is to outlast
-- the rest.
--
-- That reasoning only ever protected against a burst racing an EARLY decision
-- -- it never protected against the settle deciding TOO SOON on an incomplete
-- burst. The burst is not self-describing: the server sends Room.Info ->
-- Room.Contents -> Room.Map, but any of the three can be suppressed, so a
-- burst may begin with any one of them and the first frame carries no
-- indication of whether more is coming. A live misfire hit exactly this: a
-- room's Room.Info settled and decided "no monsters" before that room's
-- Room.Contents (which held one) had arrived.
--
-- The prompt is the one reliable burst terminator -- the MUD sends the
-- frames, then the room text, then the prompt, after everything, by
-- construction. So when a prompt pattern is configured, the prompt must be
-- authoritative and the settle must not race it: arm the long fallback
-- instead, which only fires if the prompt was lost or the pattern has
-- drifted. With no pattern configured the settle is the only signal
-- available, so it keeps arming at the short delay, unchanged.
local BURST_SETTLE_MS = 150            -- no prompt pattern: the only signal
local PROMPT_FALLBACK_MS = 1500        -- prompt configured: rescue, not rival
local settle_timer = nil
-- Every accepted room frame, counted before any state test, plus the count as
-- it stood when the current step went out. The difference answers the one
-- question the transcript of a bad run cannot: did anything actually describe
-- a room to us between the step and the arrival we committed?
local frames_seen = 0
local frames_at_step = 0
local room_info_sub = nil
local room_frame_sub = nil   -- roominfo.on_room_frame id, removed on unload

-- Per-room view of what the room held on arrival.
--
-- The GMCP Room.* packages fire on room entry only: nothing re-emits when a mob
-- dies or a player leaves, and there is no client-initiated refresh. So
-- roominfo.monsters() still lists the mob we just killed for as long as we stand
-- in the room, and a decision loop that re-read it would attack the corpse
-- forever. (The old '=M=' scraper refreshed on every 'glance', which is why this
-- was not needed before.) Instead: seed once per room from roominfo, then prune
-- locally as each target is finished. Every fight removes exactly one monster,
-- so a room is always emptied in a bounded number of fights.
local room_key = nil        -- identity of the room the view below describes
local room_monsters = {}    -- monster names still believed to be standing
local room_players = {}     -- player names seen on arrival
local current_target = nil  -- monster do_attack() is working on

-- Char.Combat {attacker, attacker_hp, rounds, target} is pushed, delta-cached,
-- and free (no request, no budget): when a fight ends, query_attack() is nil,
-- the server sends one zeroed snapshot, and the stream goes quiet. A snapshot
-- with no attacker means the fight is over. This LATCHES the first time any
-- Char.Combat frame arrives -- not just an end-of-combat one -- because that
-- is the signal GMCP is telling us about this connection's combat at all;
-- from then on the prompt path must stand down from ending fights, or two
-- writers would own the same transition (the same trap guild_viking's vitals
-- block and chat_monitor's source both document). It is per-connection and is
-- checked per callback rather than once at registration, because it flips
-- mid-connection: the prompt is on screen before the first Char.Combat frame
-- lands.
local combat_gmcp_seen = false
local combat_gmcp_sub = nil     -- gmcp handler id, removed on unload
local room_contents_sub = nil   -- roominfo.on_room_contents id, removed on unload

-- Once Char.Combat says a fight is over, a stale prompt-driven guess (prune
-- the last-attacked name from the local view and decide) is no longer good
-- enough: a mob that survived its round would be abandoned rather than
-- re-attacked. So instead of deciding immediately, ask the server what is
-- actually in the room -- one Room.Refresh per fight, not per round -- and
-- decide from the answer. The guess is DEMOTED to a fallback for when the
-- question goes unanswered, not deleted: Room.Refresh is budgeted
-- (PROTOCOL_ROOM_REFRESH_PER_TICK = 2/s) and an over-budget request is
-- dropped silently with no error payload, so a run that waited forever on an
-- unanswerable question would be worse than one that occasionally guesses
-- wrong.
local REFRESH_TIMEOUT_MS = 1000
local awaiting_refresh = false   -- true between the request and its answer/timeout
local refresh_timeout_id = nil

-- Configuration
local config = {
  -- Disabled by default. Under GMCP a glance buys nothing -- Room.* fires on
  -- room entry only and is not re-emitted for one, which is why the local
  -- monster view below exists -- so it survived purely to manufacture a second
  -- prompt for the state machine, and that pair was the cause of the stall
  -- where the stepper sat silent waiting for a prompt that never came.
  -- Set it back to "glance" for a brief-mode player who wants the room text.
  glance_cmd = "",
  attack_cmd = "kill",        -- Command prefix for attacking (kill <target>)
  prompt_pattern = nil,       -- Pattern to detect prompts (set by user)
  auto_attack = true,         -- Attack valid targets automatically
  step_on_player = true,      -- Take step if player in room (don't fight)
  step_on_no_monster = true,  -- Take step if no monsters
  targets_only = false,       -- Only kill monsters in target list (-> mode)
  -- nil until the user picks one with "/step set dive on|off". It must stay
  -- nil: the AREA PROFILE defaults the policy (spec 5.3), and a value here
  -- is passed to explore.start unconditionally, which would make the
  -- profile's own default_policy unreachable dead config.
  explore_policy = nil,      -- "clear" | "dive"; see explore/map.lua
}

-- Callbacks
local on_step_callbacks = {}      -- Called when a step is taken
local on_attack_callbacks = {}    -- Called when attacking
local on_complete_callbacks = {}  -- Called when route complete
local on_skip_callbacks = {}      -- Called when skipping a monster

--------------------------------------------------------------------------------
-- Internal Functions
--------------------------------------------------------------------------------

local function notify(callbacks, ...)
  for _, cb in ipairs(callbacks) do
    local ok, err = pcall(cb, ...)
    if not ok then
      log("Callback error: " .. tostring(err), COLOR_ERROR)
    end
  end
end

local function copy_names(list)
  local out = {}
  for i, n in ipairs(list or {}) do out[i] = n end
  return out
end

-- roominfo's identity for the room we are standing in. Falls back to the room
-- name, and then to a constant, so an unsynced roominfo seeds the view once
-- rather than on every decision.
local function roominfo_room_key()
  -- While exploring, the coordinate is the only usable identity. roominfo's is
  -- not: an area with no room ids reports nil, and its name is the same for a
  -- whole layer, so the key would never change and the local monster view would
  -- never reseed between rooms.
  if explore and explore.active() then
    local key = explore.room_key()
    if key then return key end
  end
  if not ri then return "?" end
  local rid = ri.room_id and ri.room_id()
  if rid then return "id:" .. tostring(rid) end
  local name = ri.room and ri.room()
  if name and name ~= "" then return "name:" .. name end
  return "?"
end

-- Reseed the local view when roominfo says we are somewhere new. Reading
-- roominfo here rather than from its on_room_change callback is deliberate:
-- Room.Info fires that notification before the new room's Room.Contents has
-- been handled, so a callback would seed the previous room's occupants.
local function sync_room_view()
  local key = roominfo_room_key()
  if key == room_key then
    trace("view kept (key " .. tostring(key) .. ", " .. #room_monsters
          .. " tracked)")
    return
  end
  local was = room_key
  room_key = key
  room_monsters = copy_names(ri and ri.monsters and ri.monsters())
  room_players = copy_names(ri and ri.players and ri.players())
  current_target = nil
  trace("view reseeded " .. tostring(was) .. " -> " .. tostring(key)
        .. " (" .. #room_monsters .. " monsters, " .. #room_players
        .. " players from roominfo)")
end

-- Strike one occurrence of a finished target from the local view.
local function forget_monster(name)
  if not name then return end
  for i, n in ipairs(room_monsters) do
    if n == name then
      table.remove(room_monsters, i)
      return
    end
  end
end

local process_room  -- forward declaration: on_prompt calls it, it calls do_step

local function cancel_refresh_wait()
  if refresh_timeout_id then
    timer.cancel(refresh_timeout_id)
    refresh_timeout_id = nil
  end
  awaiting_refresh = false
end

-- The fallback: today's guess, demoted rather than deleted (see the state
-- comment above for why). Strikes the last-attacked name from the local view
-- and decides from what remains.
local function prune_and_decide()
  cancel_refresh_wait()
  forget_monster(current_target)
  current_target = nil
  state = "idle"
  process_room()
end

-- The keyword guess in do_attack() is exactly that -- a guess -- and can fail
-- to resolve: "kill <keyword>" against a monster whose vocabulary does not
-- include it answers "There is no <keyword> here." and starts no fight, so
-- with nothing watching for that answer the run would wait forever for a
-- combat-end signal that can never arrive.
--
-- The state gate is the actual guard, not the pattern: give.c and other
-- mudlib commands emit the identical sentence for items, so a player giving
-- something away would otherwise prune a monster that is genuinely still
-- standing. Only state == "fighting" with no refresh outstanding identifies
-- the line as an answer to OUR attack -- outside "fighting" the line belongs
-- to someone else, and while awaiting_refresh a fight has already ended and
-- the question this line could be answering was never asked.
--
-- Legacy had this trigger, but its handler only counted failures in its
-- multi-target "dimhall" mode and did nothing for a single failed attack --
-- this recovery rule is a design decision here, not a port.
--
-- Termination: every firing removes one entry from the finite local view via
-- forget_monster(), so a room is always resolved in a bounded number of
-- attempts. A later Room.Refresh (only ever sent after a SUCCESSFUL fight)
-- can re-seed a monster that previously failed, costing one wasted attempt
-- per refresh, but the sequence still terminates because refreshes are
-- themselves bounded by successful fights. Without the prune here, the next
-- decision would pick the same monster, send the same failing keyword, and
-- fail identically forever.
local function on_attack_no_target(_, name)
  if state ~= "fighting" or awaiting_refresh then return end
  cancel_refresh_wait()  -- defensive; the gate above means there should be none
  forget_monster(current_target)
  current_target = nil
  state = "idle"
  failed_attacks = failed_attacks + 1
  log("Attack did not resolve: \"" .. tostring(name) .. "\"", COLOR_WARN)
  process_room()
end

-- The answer arrived: reseed the local view from roominfo UNCONDITIONALLY,
-- ignoring the room key. The room has not changed -- we are asking about the
-- room we are already standing in -- and the whole point of the refresh is to
-- replace the pruned guess with the server's own answer, so the normal
-- "only reseed on a new room" gate must not apply here.
local function reseed_and_decide()
  cancel_refresh_wait()
  room_monsters = copy_names(ri and ri.monsters and ri.monsters())
  room_players = copy_names(ri and ri.players and ri.players())
  current_target = nil
  state = "idle"
  process_room()
end

-- Char.Combat says the fight just ended. Ask the server what is actually in
-- the room rather than guessing: one Room.Refresh per fight, not per round.
--
-- The awaiting_refresh guard is load-bearing, not defensive dressing: without
-- it a second no-attacker frame arriving before the first refresh answers or
-- times out re-enters this function, sends a second Room.Refresh, and
-- overwrites refresh_timeout_id -- orphaning the first timer with no
-- cancel_refresh_wait() ever run on it. That orphan later fires
-- prune_and_decide() during a subsequent, unrelated fight, pruning the wrong
-- monster. Do not lean on the mudlib's "the zero snapshot is sent once"
-- guarantee to argue this guard is unreachable: gmcp_combat_send_step
-- (secure/protocol/char_combat_impl.h:76) bypasses its delta cache whenever
-- force is set, and gmcp_send_combat(1) is called forced from both the
-- reconnect/ready path and the subscription-transition path, so a second
-- zero snapshot within the ~1s refresh window is a real, reachable case, not
-- a hypothetical one.
local function handle_combat_end()
  if state ~= "fighting" or awaiting_refresh then return end
  local sent = gmcp.send("Room.Refresh", { packages = { "Room.Contents" } })
  if not sent then
    -- Not connected, or GMCP isn't enabled: the request never went out, so
    -- there is nothing to wait for. Waiting out the timeout here would be a
    -- stall with no cause to find later.
    prune_and_decide()
    return
  end
  awaiting_refresh = true
  trace("combat ended; Room.Refresh sent, awaiting the answer")
  refresh_timeout_id = timer.after(REFRESH_TIMEOUT_MS, function()
    refresh_timeout_id = nil
    -- Over-budget refreshes are dropped silently with no error payload, so a
    -- request that never gets answered looks identical to one still in
    -- flight. Falling back here is what keeps that case from waiting forever.
    --
    -- Said out loud, and counted: this is the plugin acting on a guess where
    -- it asked for facts, and a run that does it repeatedly is a run whose
    -- every later decision may be about the wrong room.
    unanswered_refreshes = unanswered_refreshes + 1
    log("Room.Refresh went unanswered; deciding from the pruned view",
        COLOR_WARN)
    prune_and_decide()
  end)
end

-- gmcp.on("Char.Combat", cb): {attacker, attacker_hp, rounds, target}. Any
-- frame -- not only an end-of-combat one -- latches combat_gmcp_seen, since
-- that is what tells the prompt path this connection has a GMCP answer for
-- combat end and should stand down.
local function on_char_combat(_, data)
  if type(data) ~= "table" then return end
  combat_gmcp_seen = true
  local attacker = data.attacker
  local has_attacker = attacker ~= nil and attacker ~= ""
  if has_attacker then return end
  handle_combat_end()
end

-- roominfo.on_room_contents(cb): fires once per COMPLETE Room.Contents list.
-- Only meaningful while a refresh is outstanding; a list arriving for any
-- other reason (another plugin's own re-glance, say) must not be mistaken for
-- our answer.
local function on_room_contents_frame()
  if not awaiting_refresh then
    trace("contents frame with no refresh outstanding; ignored")
    return
  end
  trace("refresh answered")
  reseed_and_decide()
end

local function cancel_settle()
  if settle_timer then
    timer.cancel(settle_timer)
    settle_timer = nil
  end
end

-- The single place an arrival is committed, from either signal. Idempotent:
-- whichever lands second finds state ~= "stepping" and does nothing.
-- `cause` is trace-only, and names which signal committed the arrival: the
-- settle timer (a room frame landed) or the prompt. Which one it was is the
-- first thing to know about an arrival that turns out to have been wrong,
-- since only one of them is evidence that the MUD moved us.
local function complete_arrival(cause)
  if not enabled or state ~= "stepping" then return end
  cancel_settle()
  pending_prompts = 0
  state = "idle"
  trace("arrival committed by " .. tostring(cause) .. "; "
        .. (frames_seen - frames_at_step) .. " frame(s) since the step")
  if explore and explore.active() then explore.on_arrival() end
  process_room()
end

-- Feeding the explorer is information: a frame describes the room we are
-- standing in whether or not a step is outstanding, and the frames that
-- arrive while the stepper is idle are the ones that matter most -- the entry
-- room's, seen when the player walks into the area before explore mode is
-- even started. This stays on roominfo.on_room_info alone, deliberately not
-- the generic on_room_frame signal: explore.on_frame records the room's exits
-- from ri.info(), and if it re-ran on every Contents or Map frame too, a
-- Room.Map arriving for a room whose Room.Info was suppressed would write the
-- PREVIOUS room's exits at the new coordinate -- a desync the topology check
-- would then report as real. See on_room_frame_arrival below for the settle
-- timer, which is the job that *does* need to run from any frame.
local function on_room_info_frame()
  if explore and explore.active() and explore.on_frame and ri and ri.info then
    explore.on_frame(ri.info())
  end
end

-- Arms the arrival settle timer. Subscribed to roominfo.on_room_frame -- any
-- accepted Room.Info, Room.Contents, or Room.Map -- rather than Room.Info
-- alone, because no single package is guaranteed to arrive (see the comment
-- on BURST_SETTLE_MS above). Only means anything while a step is outstanding;
-- the settle_timer guard means only the first frame of a burst arms anything.
--
-- The delay is chosen here, at arm time, by reading config.prompt_pattern
-- fresh rather than caching it anywhere earlier -- so a pattern set mid-run
-- with '/step set prompt' governs the very next step, with no extra
-- bookkeeping. A pattern configured means the prompt will normally complete
-- the arrival long before this fires (see complete_arrival/on_prompt, which
-- cancels this timer); with none configured this is the only mechanism, so
-- it keeps the original short delay.
local function on_room_frame_arrival()
  frames_seen = frames_seen + 1
  trace("frame #" .. frames_seen .. " (state " .. state .. ", "
        .. tostring(ri and ri.monster_count and ri.monster_count())
        .. " monsters in roominfo)")
  if not enabled or state ~= "stepping" then return end
  if settle_timer then return end
  local delay = config.prompt_pattern and PROMPT_FALLBACK_MS or BURST_SETTLE_MS
  settle_timer = timer.after(delay, function()
    settle_timer = nil
    complete_arrival("settle")
  end)
end

-- Begin waiting for the room we just moved into. One prompt is a whole arrival;
-- the escape-hatch glance adds a second command and therefore a second prompt.
local function begin_arrival_wait()
  cancel_settle()
  state = "stepping"
  frames_at_step = frames_seen
  pending_prompts = 1
  if config.glance_cmd and config.glance_cmd ~= "" then
    mud.send(config.glance_cmd)
    pending_prompts = pending_prompts + 1
  end
end

-- Ask, do not assume. roominfo's cached snapshot is whatever the last frame
-- said, which for a room entered before this command ran may be another room
-- entirely -- and Room.Contents is suppressed when it would repeat, so the
-- cache can be silently stale rather than merely old. One forced request
-- costs the same as one package (the budget is per request), and the answer
-- lands inside the arrival wait: Room.Info arms the settle timer, and
-- Room.Contents follows it in the same burst before that timer fires.
--
-- Called once per M.start/M.explore_reset -- never from do_step -- and its
-- result is not fatal: gmcp.send returns false when disconnected or GMCP
-- isn't negotiated, and mode.start's cached-roominfo seed is the fallback
-- for exactly that case, so the run must still start either way.
local function request_room_refresh()
  gmcp.send("Room.Refresh", { packages = { "Room.Info", "Room.Contents" } })
end

-- Attempt to resume a paused, retained explore run in place -- shared by
-- bare "/step explore" and the "-."/"->" shorthands. Refuses (and changes
-- nothing) unless explore.retained() says a map and profile are held AND
-- explore.resume() itself agrees the room the player is standing in now is
-- still inside the profile's area; either way the caller falls back to
-- starting fresh. Logging lives here so both callers say "Resuming" rather
-- than "Starting".
local function try_resume_explore()
  if not (explore and explore.retained and explore.retained() and explore.resume) then
    return false
  end
  explore.attach(ri)
  if not explore.resume() then return false end
  local rooms = (explore.stats and explore.stats().rooms) or 0
  log("Resuming explore (" .. rooms .. " rooms)", COLOR_RUN)
  return true
end

-- The target vocabulary in force: a speedwalk place carries its own list, and
-- an explore run -- which has no place -- uses the area profile's. Same shape
-- and same meaning either way, so everything below reads one list and does not
-- care which supplied it.
--
-- The profile is asked FIRST, and the order is load-bearing -- but only
-- WITHIN an explore run. M.start skips the place/load_steps path entirely for
-- an explore run, so speedwalk's target list is whatever an earlier route run
-- happened to leave behind -- a stale "gremlin" would otherwise be sent at
-- every mob in the sea, and it is the profile that describes the ground
-- actually being walked.
--
-- The other half, now that M.stop() pauses instead of discarding: a paused
-- explore run's profile is retained, so it must not reach a route run at
-- all, or the sequence "explore the sea, -!, .someplace, -." would run the
-- route with the sea's vocabulary -- the same stale-target defect the
-- paragraph above exists to prevent, just pointing the other way. Gated on
-- run_mode, not explore.active(): run_mode is fixed once per run in M.start
-- for exactly this reason (see its declaration), and re-deriving "is this an
-- explore run" from explore.active() here would reopen the same
-- per-step-drift hole that fixing run_mode was for.
local function vocabulary()
  if run_mode ~= "explore" then
    local place = (sw and sw.get_targets and sw.get_targets()) or {}
    return place
  end
  -- Guarded rather than assumed: the explore stand-in in the unit tests is a
  -- partial table, and an area profile need not declare targets at all.
  local prof = explore and explore.profile and explore.profile()
  local area = prof and prof.targets
  if type(area) == "table" and #area > 0 then return area end
  local place = (sw and sw.get_targets and sw.get_targets()) or {}
  if #place > 0 then return place end
  return {}
end

-- The first vocabulary entry that appears in a monster's display name, in its
-- authored case -- speedwalk's match_target rule, applied to whichever list is
-- in force. Used for BOTH the targets-only validity decision and the command,
-- so "-> in the sea attacks nothing" and "kill sends a word the mob does not
-- answer to" cannot come apart again.
local function match_vocabulary(monster)
  if type(monster) ~= "string" then return nil end
  local lower = monster:lower()
  for _, entry in ipairs(vocabulary()) do
    local trimmed = tostring(entry):match("^%s*(.-)%s*$")
    if trimmed ~= "" and lower:find(trimmed:lower(), 1, true) then
      return trimmed
    end
  end
  return nil
end

-- Words that begin a trailing clause rather than continue the noun phrase. Cut
-- there and the head noun is the last word before it: "a whirling monstrosity
-- with three heads" -> monstrosity, "an amalgamation of death" -> amalgamation.
-- ("in" and "and" need the bracket form; they are Lua keywords.)
local PHRASE_STOP = {
  of = true, with = true, ["in"] = true, on = true, at = true, from = true,
  ["and"] = true, that = true, who = true, which = true,
  wearing = true, holding = true, carrying = true, wielding = true,
  covered = true, standing = true, sitting = true, lying = true,
}

-- Last resort, when there is no vocabulary at all: the head noun of the
-- display name. A monster does not answer to its short -- Room.Contents
-- carries capitalize(no_ansi(short())) (room/room.c:722-734) while
-- obj/monster.c:538 id() matches only the name, an alias, or the race -- so
-- sending the short verbatim answers "There is no <the whole short> here." and
-- starts no fight. The head noun IS an id by mudlib convention, because
-- set_alias is conventionally seeded with the noun words of the name
-- (example/mobs/chaos_corr.c:115). Still a guess; just one that can resolve.
local function head_noun(display)
  if type(display) ~= "string" then return nil end
  -- A wizard-only entry is query_cap_name() .. " (invis)" (room/room.c:718);
  -- the parenthetical is no part of any id.
  local phrase = display:gsub("%s*%b()%s*$", "")
  local words = {}
  for word in phrase:lower():gmatch("[%a'%-]+") do
    if PHRASE_STOP[word] then break end
    words[#words + 1] = word
  end
  if #words > 1 and
     (words[1] == "a" or words[1] == "an" or words[1] == "the") then
    table.remove(words, 1)
  end
  -- Nothing usable (an all-punctuation short, or a name that is one stop word)
  -- leaves the caller to send what it has rather than an empty command.
  return words[#words]
end

-- current_target stays the DISPLAY name (see the comment on its declaration):
-- forget_monster() strikes names out of room_monsters, which is seeded from
-- Room.Contents display names, not from the keyword vocabulary. What actually
-- goes out on the wire is resolved separately, below.
local function do_attack(monster)
  state = "fighting"
  current_target = monster

  -- 1. A vocabulary keyword that appears in this monster's name wins outright.
  -- 2. Otherwise, in attack-anything mode with a non-empty vocabulary, guess
  --    the first entry -- legacy's "unparsed" case: the list is the area's
  --    monster vocabulary, so it usually resolves, but it IS a guess.
  -- 3. Otherwise (targets-only with no match, or no vocabulary at all), the
  --    head noun of the display name. Never the display name itself: that is
  --    the one string the mob is guaranteed not to answer to.
  local send_target = match_vocabulary(monster)
  if not send_target then
    local targets = (not config.targets_only) and vocabulary() or {}
    if #targets > 0 then
      send_target = targets[1]
      log("No target keyword matched \"" .. monster .. "\"; guessing \""
          .. send_target .. "\"", COLOR_WARN)
    else
      send_target = head_noun(monster) or monster
    end
  end

  local cmd = config.attack_cmd .. " " .. send_target
  log("Attacking: " .. monster, COLOR_FIGHT)
  notify(on_attack_callbacks, monster, cmd)
  mud.send(cmd)
  -- After attack, a prompt ends the fight and the next decision follows
  -- straight from the pruned view -- there is no glance any more.
end

local function do_step()
  local step
  if run_mode == "explore" then
    if not (explore and explore.active()) then
      -- The mode deactivated itself mid-run -- today that means it saw the
      -- room name leave the area (§6.6). The RUN is over. Falling through to
      -- sw.take_step() here would walk a stored speedwalk path from wherever
      -- we now stand, which is exactly what the exhaustion branch below
      -- refuses to do, reached by a different door.
      log("Explore mode ended; stopping", COLOR_RUN)
      enabled = false
      state = "idle"
      cancel_settle()
      notify(on_complete_callbacks)
      return false
    end
    step = explore.next_step()
    if not step then
      -- Every reachable exit leads somewhere already mapped, OR a pending
      -- leave path just finished draining -- explore.stop_reason() tells
      -- them apart, since "no unvisited exits remain" is the wrong message
      -- for a completed leave. It must NOT fall through to sw.take_step():
      -- the stepper would silently start walking a stored speedwalk path
      -- from wherever it happens to be standing in the maze.
      local reason = (explore.stop_reason and explore.stop_reason()) or "exhausted"
      if reason == "at origin" then
        log("Explored: back at the origin", COLOR_RUN)
      else
        log("Explored: no unvisited exits remain", COLOR_RUN)
      end
      enabled = false
      state = "idle"
      cancel_settle()
      -- Exhaustion ends the RUN, not just the stepping (6.5). Left active, the
      -- next "-." would re-enter explore mode, instantly re-exhaust the same
      -- map and never reach route mode at all.
      if explore.stop then explore.stop() end
      notify(on_complete_callbacks)
      return false
    end
  else
    step = sw.take_step()
    if not step then
      log("Route complete!", COLOR_RUN)
      enabled = false
      state = "idle"
      cancel_settle()
      notify(on_complete_callbacks)
      return false
    end
  end

  log("Step: " .. step.raw, COLOR_STEP)
  notify(on_step_callbacks, step.raw, sw and sw.step_info and sw.step_info())

  for _, cmd in ipairs(step.commands) do
    mud.send(cmd)
  end

  begin_arrival_wait()

  return true
end

function process_room()
  if not ri then
    log("Error: roominfo plugin not available", COLOR_ERROR)
    M.stop()
    return
  end

  -- Decisions come from the local per-room view, not from a fresh roominfo
  -- read: the snapshot cannot change while we stand in the room.
  sync_room_view()
  trace("deciding in state " .. state .. " (run_mode "
        .. tostring(run_mode) .. ")")
  local players = room_players
  local monsters = room_monsters
  local room = ri.room() or "unknown"

  -- Check if player in room
  if #players > 0 and config.step_on_player then
    log("Player in room (" .. room .. "), stepping...", COLOR_STEP)
    do_step()
    return
  end

  -- Check if no monsters
  if #monsters == 0 and config.step_on_no_monster then
    log("No monsters in room (" .. room .. "), stepping...", COLOR_STEP)
    do_step()
    return
  end

  -- Monsters present - decide whether to attack
  if #monsters > 0 then
    if config.targets_only then
      -- Only attack monsters in target list
      for _, monster in ipairs(monsters) do
        if match_vocabulary(monster) then
          if config.auto_attack then
            do_attack(monster)
            return
          else
            log("Valid target found but auto_attack disabled: " .. monster,
                COLOR_WARN)
          end
        end
      end
      -- No valid targets - skip and step
      log("Monster not in target list (" .. monsters[1] .. "), stepping...",
          COLOR_STEP)
      notify(on_skip_callbacks, monsters[1], room)
      do_step()
      return
    else
      -- Attack any monster (first one)
      if config.auto_attack then
        do_attack(monsters[1])
        return
      else
        log("Monster found but auto_attack disabled: " .. monsters[1],
            COLOR_WARN)
      end
    end
  end

  -- Fallback - just step
  do_step()
end

local function on_prompt()
  if not enabled then return end

  prompt_count = prompt_count + 1

  if state == "stepping" then
    pending_prompts = pending_prompts - 1
    trace("prompt #" .. prompt_count .. " while stepping ("
          .. pending_prompts .. " still owed, "
          .. (frames_seen - frames_at_step) .. " frame(s) since the step)")
    if pending_prompts <= 0 then
      complete_arrival("prompt")
    end
  elseif state == "fighting" then
    -- Once any Char.Combat frame has arrived this connection, THAT owns
    -- deciding when the fight is over (handle_combat_end, driven off the
    -- attacker field going absent) -- checked per callback, not once at
    -- registration, because the latch flips mid-connection: the prompt is on
    -- screen before the first frame lands. Without this check both the
    -- prompt and Char.Combat would try to end the same fight.
    if combat_gmcp_seen then return end

    -- Fallback, unchanged from before Char.Combat existed: the target is
    -- struck from the local view here because nothing else will. Room.Contents
    -- is not re-sent for a mob that died, so without this the next decision
    -- would attack the corpse.
    --
    -- It no longer re-glances. The glance never refreshed anything -- that is
    -- the whole reason this local view exists -- so the decision is made
    -- straight from the pruned view.
    forget_monster(current_target)
    current_target = nil
    state = "idle"
    process_room()
  end
end

--------------------------------------------------------------------------------
-- Aliases
--------------------------------------------------------------------------------

local alias_ids = {}  -- Store alias IDs for the movement shorthands
local command_id = nil

-- require("command") is optional: a profile that never required 'commands' has
-- no registry, and the "-" shorthands still work.
local command
do
  local ok, mod = pcall(require, "command")
  if ok then command = mod end
end

local function show_help()
  log("Commands:", COLOR_HEAD)
  log("  -.                     - Start stepping, kill any mob")
  log("  ->                     - Start stepping, only kill targets")
  log("  -!                     - Stop stepping")
  log("  /step status           - Show current status")
  log("  /step trace [on|off]   - Log the invisible half: frames, prompts,")
  log("                           settles, refreshes and every decision")
  log("  /step explore [area]   - Start explore mode in an area (default: chaossea)")
  log("  /step explore off      - Stop explore mode")
  log("  /step explore reset    - Reset the map to a fresh origin here, keep stepping")
  log("  /step explore leave    - Walk back to the run's origin, fighting on the way;")
  log("                           does NOT leave the area -- the last step out is yours")
  log("  /step set prompt <p>   - Set prompt detection pattern")
  log("  /step set attack [on|off] - Toggle auto-attack")
  log("  /step set glance [cmd]    - Set/show glance command")
  log("  /step set kill [cmd]      - Set/show attack command prefix")
  log("  /step set dive [on|off]   - Toggle explore dive policy")
  log("  /step set config       - Show configuration")
end

-- The movement shorthands stay raw aliases: "-", "-.", "->" and "-!" are input
-- syntax, not slash tokens the command registry can express. Everything
-- word-shaped moved to /step.
local function register_aliases()
  -- "-" - show help
  alias_ids[#alias_ids + 1] = alias.add("^-$", function()
    show_help()
    return nil
  end)

  -- "-." - start stepping, kill any mob
  alias_ids[#alias_ids + 1] = alias.add("^-\\.$", function()
    M.start(false)
    return nil
  end)

  -- "->" - start stepping, only kill targets
  alias_ids[#alias_ids + 1] = alias.add("^->$", function()
    M.start(true)
    return nil
  end)

  -- "-!" - stop stepping
  alias_ids[#alias_ids + 1] = alias.add("^-!$", function()
    M.stop()
    return nil
  end)
end

local function unregister_aliases()
  for _, id in ipairs(alias_ids) do
    if id then alias.remove(id) end
  end
  alias_ids = {}
end

--------------------------------------------------------------------------------
-- Command
--------------------------------------------------------------------------------

local function show_config()
  log("Configuration:", COLOR_HEAD)
  log("  glance_cmd: " .. config.glance_cmd)
  log("  attack_cmd: " .. config.attack_cmd)
  log("  prompt_pattern: " .. (config.prompt_pattern or "(not set)"))
  log("  auto_attack: " .. tostring(config.auto_attack))
  log("  targets_only: " .. tostring(config.targets_only))
end

-- "set" takes a key and an optional value; with no value each key reports what
-- it currently holds, which is what the bare "-set <key>" aliases used to do.
local function dispatch_set(rest)
  local key, value = rest:match("^(%S*)%s*(.-)%s*$")
  key = key:lower()

  if key == "" or key == "help" then
    show_help()
  elseif key == "status" then
    M.status()
  elseif key == "config" then
    show_config()
  elseif key == "prompt" then
    if value == "" then
      log("Usage: /step set prompt <pattern>", COLOR_WARN)
      log("Current: " .. (config.prompt_pattern or "(not set)"))
    else
      M.set_prompt_pattern(value)
    end
  elseif key == "attack" then
    if value == "" then
      log("Auto-attack: " .. (config.auto_attack and "on" or "off"))
    elseif value == "on" or value == "off" then
      config.auto_attack = (value == "on")
      log("Auto-attack " .. (config.auto_attack and "enabled" or "disabled"))
    else
      log("Usage: /step set attack [on|off]", COLOR_WARN)
    end
  elseif key == "glance" then
    if value == "" then
      local shown = (config.glance_cmd == "" or config.glance_cmd == nil)
        and "(disabled)" or config.glance_cmd
      log("glance_cmd: " .. shown)
    else
      config.glance_cmd = value
      log("Glance command set: " .. config.glance_cmd)
    end
  elseif key == "kill" then
    if value == "" then
      log("Attack command: " .. config.attack_cmd)
    else
      config.attack_cmd = value
      log("Attack command set: " .. config.attack_cmd)
    end
  elseif key == "dive" then
    if value == "" then
      -- Report what is in EFFECT, which is the live run's policy while one is
      -- running and the config only once the user has set it. Before that the
      -- honest answer is that the area profile decides -- printing "off" there
      -- would claim a setting nothing holds.
      local effective = nil
      if explore and explore.active() and explore.policy then
        effective = explore.policy()
      else
        effective = config.explore_policy
      end
      if effective then
        log("dive: " .. (effective == "dive" and "on" or "off"))
      else
        log("dive: profile default")
      end
    elseif value == "on" or value == "off" then
      config.explore_policy = (value == "on") and "dive" or "clear"
      if explore and explore.active() then explore.set_policy(config.explore_policy) end
      log("dive: " .. (config.explore_policy == "dive" and "on" or "off"))
    else
      log("Usage: /step set dive [on|off]", COLOR_WARN)
    end
  else
    log("Unknown setting: " .. key, COLOR_WARN)
    show_help()
  end
end

local function dispatch(args)
  local sub, rest = tostring(args or ""):match("^%s*(%S*)%s*(.-)%s*$")
  sub = sub:lower()

  if sub == "" or sub == "help" then
    show_help()
  elseif sub == "set" then
    dispatch_set(rest)
  elseif sub == "status" then
    M.status()
  elseif sub == "trace" then
    local arg = rest:match("^(%S*)"):lower()
    if arg == "on" then
      tracing = true
      log("Trace on: every frame, prompt, settle and decision is logged.",
          COLOR_RUN)
    elseif arg == "off" then
      tracing = false
      log("Trace off", COLOR_RUN)
    elseif arg == "" then
      log("trace: " .. (tracing and "on" or "off"))
    else
      log("Usage: /step trace [on|off]", COLOR_WARN)
    end
  elseif sub == "start" then
    M.start(false)
  elseif sub == "targets" then
    M.start(true)
  elseif sub == "stop" then
    M.stop()
  elseif sub == "explore" then
    local arg = rest:match("^(%S*)")
    if arg == "off" then
      M.explore_stop()
    elseif arg == "reset" then
      M.explore_reset()
    elseif arg == "leave" then
      M.explore_leave()
    elseif arg ~= "" then
      -- Naming an area is a statement of intent: always start fresh, even
      -- with a paused run's map retained.
      if M.explore_start(arg) then M.start(config.targets_only) end
    else
      -- No area named: resume a retained, in-area run when possible; only
      -- fall back to starting fresh (in the default area) when it is not.
      if try_resume_explore() then
        M.start(config.targets_only)
      elseif M.explore_start("chaossea") then
        M.start(config.targets_only)
      end
    end
  else
    log("Unknown subcommand: " .. sub, COLOR_WARN)
    show_help()
  end
end

local function register_command()
  if not command then return end
  local id, err = command.register({
    name = "/step",
    aliases = { "/autostepper" },
    usage = "/step [start|targets|stop|explore [area]|explore off|explore reset|"
      .. "explore leave|status|trace [on|off]|set <key> [value]]",
    summary = "Automatic speedwalk stepping with optional combat",
    description = "Walks a stored step path one room at a time, optionally "
      .. "glancing and attacking on the way. Or, with 'explore [area]', maps an "
      .. "unmapped area room by room, stopping automatically once every reachable "
      .. "exit leads somewhere already mapped; 'explore off' stops it early, "
      .. "'explore reset' resets the map to a fresh origin at the current room and "
      .. "re-asks the MUD without stopping the run, and 'explore leave' walks the "
      .. "shortest recorded route back to the run's origin, fighting anything met on "
      .. "the way -- this does NOT leave the area itself, since the explorer never "
      .. "walks an excluded exit, so the final step out is still the player's own. "
      .. "The shorthands are '-.' to start on any mob, '->' to start on targets only, "
      .. "'-!' to stop, and '-' for help. Settings: status, config, prompt, attack, "
      .. "glance, kill, dive.",
    accepts_args = true,
    handler = dispatch,
  })
  if id then
    command_id = id
  else
    log("command registration failed: " .. tostring(err), COLOR_ERROR)
  end
end

local function unregister_command()
  -- The loader drops a plugin's commands on unload; unregistering here keeps a
  -- manual reload from colliding with its own leftover record.
  if command and command_id then
    pcall(command.unregister, command_id)
    command_id = nil
  end
end

--------------------------------------------------------------------------------
-- Plugin Hooks
--------------------------------------------------------------------------------

function M.on_load()
  -- Try to get dependencies
  sw = plugin.get("speedwalk")
  ri = plugin.get("roominfo")

  if not sw then
    log("Warning: speedwalk plugin not loaded", COLOR_WARN)
  end
  if not ri then
    log("Warning: roominfo plugin not loaded", COLOR_WARN)
  end

  if ri and ri.on_room_info then
    room_info_sub = ri.on_room_info(on_room_info_frame)
  end
  if ri and ri.on_room_contents then
    room_contents_sub = ri.on_room_contents(on_room_contents_frame)
  end
  if ri and ri.on_room_frame then
    room_frame_sub = ri.on_room_frame(on_room_frame_arrival)
  end
  if gmcp and gmcp.on then
    combat_gmcp_sub = gmcp.on("Char.Combat", on_char_combat)
  end

  -- Unlike the prompt trigger, this one needs no user-supplied pattern, so it
  -- is created unconditionally on load rather than waiting on a "configured"
  -- step -- and it is removed on unload below.
  if trigger and trigger.add then
    no_target_trigger_id = trigger.add("^There is no (.*?) here\\.$", on_attack_no_target)
  end

  -- Register the movement shorthands and the /step command
  register_aliases()
  register_command()

  log("Loaded (use /step help for commands)", COLOR_RUN)
end

function M.on_unload()
  unregister_aliases()
  unregister_command()

  if room_info_sub and ri and ri.off_room_info then
    ri.off_room_info(room_info_sub)
  end
  room_info_sub = nil

  if room_contents_sub and ri and ri.off_room_contents then
    ri.off_room_contents(room_contents_sub)
  end
  room_contents_sub = nil

  if room_frame_sub and ri and ri.off_room_frame then
    ri.off_room_frame(room_frame_sub)
  end
  room_frame_sub = nil

  if combat_gmcp_sub and gmcp and gmcp.remove then
    gmcp.remove(combat_gmcp_sub)
  end
  combat_gmcp_sub = nil

  if no_target_trigger_id and trigger and trigger.remove then
    trigger.remove(no_target_trigger_id)
  end
  no_target_trigger_id = nil

  M.stop()
  -- Unlike an ordinary stop, unloading the plugin is real teardown: there is
  -- no later "-." to hand a retained map back to once this instance is gone.
  if explore and explore.discard then explore.discard() end
  log("Unloaded", COLOR_RUN)
end

-- A reconnect that never negotiates Char.Combat must fall back to the prompt
-- guess rather than freeze with the latch still set from the previous
-- connection.
function M.on_disconnect()
  combat_gmcp_seen = false
  cancel_refresh_wait()
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Set the prompt pattern and create trigger
function M.set_prompt_pattern(pattern)
  -- Remove old trigger if exists
  if prompt_trigger_id then
    trigger.remove(prompt_trigger_id)
    prompt_trigger_id = nil
  end

  config.prompt_pattern = pattern

  if pattern then
    prompt_trigger_id = trigger.add(pattern, function()
      on_prompt()
    end)

    if prompt_trigger_id then
      log("Prompt pattern set: " .. pattern)
    else
      log("Failed to compile prompt pattern", COLOR_ERROR)
      config.prompt_pattern = nil
    end
  end
end

-- Start autostepping at current place
-- targets_only: if true, only kill monsters in target list; if false, kill any monster
function M.start(targets_only)
  if not sw then
    sw = plugin.get("speedwalk")
    if not sw then
      log("Error: speedwalk plugin required", COLOR_ERROR)
      return false
    end
  end

  if not ri then
    ri = plugin.get("roominfo")
    if not ri then
      log("Error: roominfo plugin required", COLOR_ERROR)
      return false
    end
  end

  if not config.prompt_pattern then
    -- Task 5 made a settled Room.Info burst complete an arrival on its own,
    -- so a prompt is no longer load-bearing for starting a run. Warn instead
    -- of refusing, and say what the session is then relying on: arrivals
    -- come from the GMCP Room.Info path and combat end from Char.Combat. If
    -- the MUD provides neither, the run stalls -- worth saying out loud
    -- rather than discovering it.
    log("No prompt pattern set: arrivals will rely on the GMCP Room.Info path and "
        .. "combat end on Char.Combat. Set one with '/step set prompt <pattern>' if "
        .. "either is unavailable.", COLOR_WARN)
  end

  local exploring = explore and explore.active()
  -- "-." / "->" call straight in here with no area named -- resuming a
  -- retained, in-area run is what makes the plain gesture pick a paused
  -- explore run back up instead of falling through to route mode.
  if not exploring then
    exploring = try_resume_explore()
  end
  -- Fixed once, here, for the whole run -- see the run_mode declaration for
  -- why do_step() must not re-derive this from explore.active() per step.
  run_mode = exploring and "explore" or "route"

  if not exploring then
    local place = sw.get_current_place()
    if not place then
      log("Error: current place not set (use .set <place>)", COLOR_ERROR)
      return false
    end

    if not sw.load_steps() then
      log("Error: no steps configured for place '" .. place .. "'", COLOR_ERROR)
      log("Use speedwalk.configure_place('" .. place .. "', 'n|s|e|w', 'target1,target2')")
      return false
    end

    local info = sw.step_info()
    local targets = sw.get_targets()
    config.targets_only = targets_only or false
    local mode_label = config.targets_only and "targets only" or "any mob"
    log("Starting at '" .. place .. "': " .. info.total .. " steps ("
        .. mode_label .. ")", COLOR_RUN)
    if config.targets_only and #targets > 0 then
      log("Targets: " .. table.concat(targets, ", "))
    end
  else
    config.targets_only = targets_only or false
    log("Starting explore run (" .. (explore.stats().policy or "clear") .. ")",
        COLOR_RUN)
  end

  enabled = true
  state = "idle"
  prompt_count = 0
  -- Forget any stale view so the room we are standing in is seeded afresh.
  room_key = nil
  current_target = nil
  -- Reset the combat-source latch: see the on_disconnect note above for why
  -- this and on_disconnect both clear it.
  combat_gmcp_seen = false
  cancel_refresh_wait()

  -- We are standing in a room already, so wait for the next prompt and decide
  -- from it rather than manufacturing one.
  begin_arrival_wait()

  -- Both modes, not just explore: route mode reads roominfo for its first
  -- decision too, and with the glance gone nothing else forces a re-read, so
  -- '-.' in a long-occupied room would otherwise decide on stale contents.
  request_room_refresh()

  return true
end

-- Stop autostepping
function M.stop()
  if enabled then
    log("Stopped", COLOR_RUN)
  end
  cancel_settle()
  cancel_refresh_wait()
  enabled = false
  state = "idle"
  run_mode = nil
  prompt_count = 0
  pending_prompts = 0
  current_target = nil
  -- explore.stop() PAUSES rather than discards: it is dead reckoned, so what
  -- used to be guarded against here -- the next "-." resuming that reckoning,
  -- and the combat that goes with it, wherever the player is now standing
  -- after walking out of the area -- is now explore.resume()'s job, which
  -- checks the CURRENT room against the area before letting a resume
  -- through. Pausing keeps the map and profile so that check has something
  -- to resume back into.
  if explore and explore.active() and explore.stop then explore.stop() end
end

function M.explore_start(area_name)
  local prof = load_area(area_name)
  if not prof then
    log("Unknown area '" .. tostring(area_name) .. "'", COLOR_WARN)
    return false
  end
  explore.attach(ri)
  if not explore.start(prof, config.explore_policy) then
    log("Explore mode failed to start", COLOR_ERROR)
    return false
  end
  log("Explore mode active: " .. prof.name, COLOR_RUN)
  return true
end

function M.explore_stop()
  if explore and explore.active() then
    explore.stop()
    log("Explore mode off", COLOR_RUN)
  end
  M.stop()
end

-- Reset the explore map to a fresh origin at the current room, mid-run:
-- mid-run is exactly when the map turns out to be wrong (a desync reset that
-- lands on the wrong layer, a frame missed before the plugin loaded). Keeps
-- the run going -- this corrects the map, it does not stop the stepper.
--
-- After mode.reset() discards the old map, the SAME Room.Refresh Item 1
-- sends on start re-asks the MUD, so the fresh origin is recorded from an
-- answer rather than the cache reset just discarded. No extra wiring is
-- needed for that answer to land: on_room_info_frame's explore.on_frame()
-- call is unconditional (fires whether or not a step is outstanding), and
-- this run's own next arrival -- in flight already, or the next step ahead --
-- commits the refreshed exits via explore.on_arrival() as it always does.
function M.explore_reset()
  -- Works whether the run is active or merely retained (paused): resetting a
  -- stopped run must not start the player walking, so mode.reset() itself
  -- leaves `active` exactly as it found it -- this only checks that a map
  -- exists to reset in the first place.
  local has_map = explore and ((explore.active and explore.active())
    or (explore.retained and explore.retained()))
  if not has_map then
    log("No explore map to reset", COLOR_WARN)
    return false
  end
  explore.reset("manual reset")
  request_room_refresh()
  log("Explore map reset; re-asking the MUD for the current room", COLOR_RUN)
  return true
end

-- Walk back to the run's origin -- the room the explorer started in, which
-- for the target area is the entry room. Delegates entirely to mode.lua's
-- M.leave(): it arms a pending path (via Map:path_to) that next_step()
-- drains one direction per step, ahead of frontier selection, and reports
-- and changes nothing when explore mode is inactive, the origin is
-- unreachable, or it is already reached. Arrival still runs process_room()
-- exactly like any other step, so a monster met on the way out is still
-- fought -- leaving is not a reason to stop fighting.
--
-- Reaching the origin does not leave the area: the explorer never walks an
-- excluded exit (e.g. 'out' in the Chaos Sea), so the last step out remains
-- the player's own.
function M.explore_leave()
  if not (explore and explore.leave) then return false end
  return explore.leave()
end

-- Check if running
function M.is_running()
  return enabled
end

-- Get current state
function M.get_state()
  return state
end

-- Show status
function M.status()
  log("Status:", COLOR_HEAD)
  log("  Running: " .. (enabled and "yes" or "no"))
  log("  State: " .. state)
  log("  Pending prompts: " .. pending_prompts)
  log("  Mode: " .. (config.targets_only and "targets only (->)" or "any mob (-.))"))
  log("  Prompt count: " .. prompt_count)
  -- A climbing count is the actionable diagnostic: it means the target list
  -- does not match the area, which the user can fix and nothing else says.
  log("  Failed attacks (this session): " .. failed_attacks)
  -- Both counted for the same reason: each is the run acting on something
  -- weaker than the server's own answer.
  log("  Unanswered refreshes (this session): " .. unanswered_refreshes)
  log("  Trace: " .. (tracing and "on" or "off"))

  if explore and explore.active() then
    local s = explore.stats()
    log("  Explore: " .. (s.policy or "clear") .. ", " .. s.rooms .. " rooms, "
        .. "at " .. s.x .. "," .. s.y .. "," .. s.z
        .. (s.layer and (" (layer " .. s.layer .. ")") or ""))
    log("  Desyncs: " .. tostring(explore.desyncs and explore.desyncs() or 0))
  elseif explore and explore.retained and explore.retained() then
    local s = explore.stats()
    log("  Explore: paused, " .. s.rooms .. " rooms retained, "
        .. "at " .. s.x .. "," .. s.y .. "," .. s.z
        .. (s.layer and (" (layer " .. s.layer .. ")") or ""))
  end

  if sw then
    local info = sw.step_info()
    log("  Steps: " .. info.current .. "/" .. info.total ..
        " (" .. info.remaining .. " remaining)")
  end

  if ri then
    local room = ri.room()
    log("  Room: " .. (room or "(unknown)"))
    log("  Players: " .. ri.player_count())
    -- Two numbers, deliberately: roominfo's is the entry-time snapshot, which
    -- never shrinks while we stand here, and the tracked one is what the
    -- stepping decisions are actually made from.
    log("  Monsters: " .. ri.monster_count() .. " on entry, "
        .. #room_monsters .. " tracked")
    log("  Target: " .. (current_target or "(none)"))
  end
end

-- The per-room monster view stepping decisions are made from. Unlike
-- roominfo.monsters(), it shrinks as targets are finished.
function M.tracked_monsters()
  return copy_names(room_monsters)
end

-- Configuration setters
function M.set_glance_cmd(cmd)
  config.glance_cmd = cmd
end

function M.set_attack_cmd(cmd)
  config.attack_cmd = cmd
end

function M.set_auto_attack(enabled)
  config.auto_attack = enabled
end

-- Register callbacks
function M.on_step(callback)
  table.insert(on_step_callbacks, callback)
end

function M.on_attack(callback)
  table.insert(on_attack_callbacks, callback)
end

function M.on_complete(callback)
  table.insert(on_complete_callbacks, callback)
end

function M.on_skip(callback)
  table.insert(on_skip_callbacks, callback)
end

-- Manual trigger for prompt (if not using pattern trigger)
function M.prompt()
  on_prompt()
end

return M
