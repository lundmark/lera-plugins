# Autostepper GMCP arrival repair

The user approved removing prompt-driven decisions, waiting for room contents on
each successful step, fixing blocked-move reckoning, and preventing prompts from
ending fights. Targets-only matching and unrelated no-target recovery stay as
they are. Tracking manual moves during a pause remains a TODO.

## Design

- A complete Room.Contents snapshot marked entry=1 completes one pending move;
  an unmarked startup refresh seeds the initial room. Room.Info
  supplies exits, while Room.Map and elapsed time never commit movement.
- Remove prompt triggers, settings, counters, and manual prompt entrypoints.
  Char.Combat and the existing post-combat contents refresh own fight completion.
- Arm the wait before sending a move. Clear it before making the next decision,
  so trailing Room.Map frames cannot complete the next move.
- Record blocked-move responses while awaiting entry. Chaossea prints the same
  warning for wizards who may pass, so a subsequent entry still succeeds. If no
  entry arrives within five seconds, stop and cancel the pending direction
  without moving the coordinate map.
- The mudlib currently suppresses identical Room.Contents lists across entries.
  Force contents in protocol_room_entered and mark every page entry=1,
  preserving the Info, Contents, Map order, subscription checks, and paging.
  Refresh/subscription snapshots remain unmarked, so they cannot confirm moves.
- Keep an initial forced room refresh for starting/resuming. Setup waits for
  actual entry into the Sea, ignoring intermediate outside rooms. Missing combat
  refresh responses must not falsely assert a surviving target died.

## Work and verification

- [x] Add failing integration cases using real roominfo, explore, and autostepper
  modules: delayed/paged/identical contents, ignored Info/Map/timers, no prompts,
  blocked moves, cancellation, and combat ownership across starts.
- [x] Repair the engine and area-specific blocked responses; retain route,
  target, callback, and farm behavior within the approved scope.
- [x] Update existing tests from prompt-driven fixtures to GMCP events and wire
  the arrival integration suite into run_tests.sh.
- [x] Repair the mudlib entry writer and test repeated entry delivery. Preserve
  unrelated local mudlib changes; record local verification separately from
  live activation.
- [x] Run all plugin tests, review the final diff, and report remaining runtime
  gates. The user subsequently authorized scoped Ferry delivery and publication.

## Deferred

TODO: invalidate or track paused explore coordinates when the user moves manually.
The user explicitly deferred this, targets-only alias matching, and correlation
of unrelated "There is no ... here" messages with the current attack.

## Verification

- Full `LERA_ROOT=/home/simon/code/lera ./run_tests.sh` passed, including 40
  integration checks for real roominfo/explore/autostepper modules.
- Review caught and resolved compound-route arrival ownership and repeated-start
  bypasses. Expanded moves are now serialized across intervening fights;
  preparation commands still precede their movement, and active starts refuse.
- Local LDMud probe: original writer 83 checks / 12 expected failures; changed
  writer 83 checks / 0 failures. The changed harness function compiled in the
  isolated probe, and three decoder checks passed.
- The probe uses the production writer/entry/refresh functions, real paging and
  Telnet codecs, and a test JSON adapter because the installed driver lacks JSON
  support. This is not full production compilation or live harness acceptance.
- Four local mudlib files changed: `secure/pinc/gmcp.h`,
  `secure/protocol/config.h`, `secure/protocol/tests/gmcp_vitals_fixture.c`, and
  `secure/protocol/tests/gmcp_harness.c`. Other existing mudlib edits were kept.
- The four server files were subsequently Ferry-pushed and remotely
  check-compiled, including `secure/player.c`. The matching protocol help was
  updated and pushed. Remote copies were pulled and byte-verified. Compilation
  and synchronization do not establish runtime activation.

## Follow-up: stop at the cask (2026-09-09)

The run in `snoppelisnopptest.txt` visited 168 rooms with consistent coordinates.
It killed the boss beside the cask at 174 seconds, then continued exploring until
574 seconds. Completion was checked only after frontier exhaustion, and only
farm mode acted on it. The user clarified that ordinary runs must stop at the
cask too.

- Check the profile's completion items after clearing the room, before selecting
  another exit. Normal runs stop there; farm runs schedule their next instance.
- Keep complete contents and post-combat refresh requirements. A cask on an
  incomplete page or beside a surviving boss must not complete the run.
- Regression first: 11 failures reproduced the missing stop/restart behavior.
  With the repair, all 56 arrival checks pass, including restart cancellation.
- The full plugin suite passed with 4,685 CASE checks before integration onto
  the latest default branch. README and in-client help describe the stop.
- Delivery review found that truncated contents could omit a living boss. Such
  cask/portal snapshots now stop without completion or a farm restart. Ordinary
  and farm regressions cover entry and post-combat lists across two pages, with
  truncation flagged on the first page. The guard fixed 10 failing assertions;
  all 68 arrival checks and 4,769 CASE checks pass on the integrated result.
- The capture still used the old prompt-driven client despite the server's
  entry marker being present. Updated client plugins must be loaded before
  runtime acceptance of these changes.
- The default branch advanced during delivery with exact-name mob ignores.
  Integration preserves that feature, migrates its prompt-based tests to GMCP,
  and counts only non-ignored mobs for cask completion. Four failing assertions
  reproduced the integration gap; all 74 arrival checks and 4,804 CASE checks
  pass after the repair.
