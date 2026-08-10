# Approved Legacy Parity Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete a strict, evidence-backed audit of revision 1's 32 approved legacy targets, publish an honest parity report and separate not-converted inventory, and create deduplicated private Lera feature requests only for confirmed client capability blockers.

**Architecture:** Keep raw legacy constructs, selected-source bindings, provenance, evidence, runtime scenarios, and audit fragments in the protected private state directory. Audit one approved target at a time, require exact-once construct coverage, compare mapped targets with current Lua plugins, and derive all public artifacts from the authenticated private bundle. Reconcile the current plugin mirror, synchronize confirmed blockers, run offline Lera scenarios, and publish the manifest and both reports transactionally only after the full-private gate passes.

**Tech Stack:** Python 3.12 standard library, Lua plugins, Lera headless runtime, Git, GitHub CLI, TOML/Markdown public artifacts.

**Approved design:** `docs/superpowers/specs/2026-08-07-legacy-plugin-parity-validation-design.md`

---

## Safety and privacy invariants

- Work in `/home/simon/code/lera-plugins/.worktrees/legacy-parity` on `feature/legacy-parity-validator`.
- Treat `/home/simon/code/3s_scripts_old` as read-only.
- Keep private work under `/home/simon/.local/state/lera-plugins/legacy-parity` with directories mode `0700` and files mode `0600`.
- Never inspect or mutate `/home/simon/simon/.storage`, `profile.conf.save`, or any live profile state.
- Never connect to the live MUD. Every behavioral check uses the isolated Lera runner and temporary storage.
- Do not add, count, describe, or fingerprint anything outside revision 1's approved scope in tracked files, reports, commits, issues, logs, or fixtures.
- Never commit the private binding digest, legacy commit ID, source digests, construct IDs, trigger patterns, script bodies, or local evidence.
- A feature is `lera_blocker` only after confirming that supported Lua APIs cannot implement it. Otherwise classify the missing behavior as `plugin_gap`.
- Do not use `waived` without a new explicit user decision naming the feature, rationale, and approval date.
- Per-target audit fragments are private and are not committed. Public commits occur only for generic validator fixes, the Lera mirror correction, and the final three generated artifacts.

## File map

Public validator worktree:

- Modify: `tools/legacy_parity/validation.py` — selected-source construct snapshot validation.
- Modify: `tools/legacy_parity/privacy.py` — allow approved public-scope token collisions without weakening exact omitted-path denial.
- Modify: `tools/legacy_parity/runtime.py` — reproducible private scenario resolution and execution.
- Test: `tests/legacy_parity/test_validation.py` — selected-source snapshot regression tests.
- Test: `tests/legacy_parity/test_staged.py` — exact selected-binding coverage tests.
- Test: `tests/legacy_parity/test_privacy.py` — approved-scope/deny-token collision tests.
- Test: `tests/legacy_parity/test_runtime.py` — real scenario digest and rerun tests.
- Test: `tests/legacy_parity/test_acceptance.py` — full-private ordering and recurring-runtime acceptance tests.
- Create: `validation/legacy-parity.toml` — approved manifest and feature statuses.
- Create: `validation/parity-report.md` — approved targets and derived status details.
- Create: `validation/not-converted.md` — only approved targets without current mappings.
- Existing: `validation/README.md` — recurring public/full-private commands; update only if the actual command sequence changes.

Lera mirror repository:

- Modify: `/home/simon/code/lera/plugins/3scapes/chat_monitor.lua` — byte-identical mirror of the canonical approved current plugin.

Private state, never committed:

- Create: `staged/workspace/audit_workspace.py` and `staged/workspace/test_audit_workspace.py` — target snapshot/checkpoint/assembly helper and synthetic tests.
- Create: `staged/targets/<target-key>.json` — one complete `TargetAudit` fragment per approved target.
- Create: `staged/evidence/<target-key>.json` — local evidence records for that target.
- Create as needed: `staged/runtime/<target-key>-<scenario-key>.json` — safe offline scenarios.
- Create/update: `staged/audit-bundle.json`, `provenance.json`, and `reports/full-private-report.md`.

## Standard per-target audit protocol

Every target task below follows this protocol. Do not mark a target complete until every step passes.

1. Load the target from authenticated `selection.json`; refuse target, source, coverage, selected-feature, binding, or current-mapping drift.
2. Snapshot required constructs in source order:
   - `complete` XML: every ID from `extract_xml_constructs()`;
   - `complete` Lua: every executable line ID from `executable_lua_lines()`;
   - `selected`: only the exact construct IDs authenticated for that target/source/feature in private bindings, with the binding union computed independently for each target and source.
3. Read every approved construct and its required helper context. Group it into stable, non-sensitive feature keys and one allowed category.
4. Assign every required construct to exactly one feature. `evidence_scope` must contain every construct assigned to that feature.
5. For mapped targets, compare each legacy feature with the mapped current plugin and supported Lera APIs. Record:
   - `parity` with passing evidence and current line references or an isolated fixture;
   - `plugin_gap` with failing evidence when plugin Lua can implement it;
   - `lera_blocker` with failing evidence only after a client API audit;
   - `not_converted` only for an approved feature with no implementation.
6. For unmapped targets, give every feature status `not_converted`, failing manual-private evidence, and no fabricated current references.
7. Use concise safe public summaries. Put detailed comparison notes and all construct identities only in local evidence.
8. Run `audit_workspace.py validate-target <target-key>`. It must prove exact source/mapping agreement, exact-once construct coverage, selected-binding equality, evidence linkage, stable ordering, and safe public fields.
9. Confirm the fragment and evidence files are mode `0600`. Do not commit them.

### Task 1: Reconcile repositories and freeze execution inputs

**Files:**
- Modify: `/home/simon/code/lera/plugins/3scapes/chat_monitor.lua`
- Read: `/home/simon/code/lera-plugins/.worktrees/legacy-parity`
- Read: `/home/simon/code/3s_scripts_old`

- [ ] **Step 1: Verify all three repositories before mutation**

Run `git status --short --branch` in the plugin worktree, canonical plugin checkout, legacy checkout, and Lera checkout. Preserve unrelated untracked Lera work and stop if either target file has overlapping edits.

- [ ] **Step 2: Bring the isolated validator branch to current plugin master**

Run `git merge master` in `/home/simon/code/lera-plugins/.worktrees/legacy-parity`. Expected: the current `chat_monitor.lua` changes merge without conflict and the approved 17-file inventory matches `/home/simon/code/lera-plugins` byte-for-byte.

- [ ] **Step 3: Run the validator suite before audit work**

Run:

```bash
mise exec python@3.12 -- -m unittest discover -s tests/legacy_parity -v
```

Expected: all tests pass.

- [ ] **Step 4: Reconcile Lera's current plugin mirror**

Confirm `compare_mirror()` reports only the already-recorded `chat_monitor.lua` drift. Mechanically copy the canonical worktree file to `/home/simon/code/lera/plugins/3scapes/chat_monitor.lua`, then rerun `compare_mirror()` and require an empty result.

- [ ] **Step 5: Validate the Lera mirror offline**

Compile the mirrored Lua with an isolated temporary profile using `/home/simon/code/lera/build/lera`; do not call `mud.connect`. Run `/home/simon/code/lera/test.sh --no-deps`. Expected: syntax/load check and Lera tests pass.

- [ ] **Step 6: Commit only the mirror correction in Lera**

```bash
git add plugins/3scapes/chat_monitor.lua
git commit -m "fix: sync chat monitor plugin mirror"
```

- [ ] **Step 7: Reauthenticate the frozen scope**

Run `check-preliminary` against the worktree plugin root, reload revision 1 approval, recompute the public scope and private bindings in memory, and require exact matches. Confirm ordinary `discover` returns no undecided candidate without printing any private selection state.

### Task 2: Correct selected-source and approved-token privacy validation

**Files:**
- Modify: `tools/legacy_parity/validation.py`
- Modify: `tools/legacy_parity/privacy.py`
- Test: `tests/legacy_parity/test_validation.py`
- Test: `tests/legacy_parity/test_staged.py`
- Test: `tests/legacy_parity/test_privacy.py`

- [ ] **Step 1: Write the failing mixed-coverage snapshot test**

Create a synthetic selected XML source with at least one approved bound construct and one unselected construct. Build a target inventory containing only the authenticated bound construct. Assert full-private snapshot validation accepts the selected subset while still requiring the source file to exist.

- [ ] **Step 2: Run the focused test and verify RED**

Run the new test alone. Expected: FAIL with `legacy_construct_drift` because the current validator incorrectly requires the entire selected file inventory.

- [ ] **Step 3: Write the failing rejection tests**

Add tests proving a selected inventory is rejected when it omits an authenticated binding, includes an unselected construct, or names a construct no longer present in the source. Add a complete-source control proving complete coverage still requires the full extraction.

- [ ] **Step 4: Implement selection-aware snapshots**

Pass the authenticated selection into `_validate_construct_snapshots()`. For each source, derive full extracted IDs, then require:

- complete coverage: inventory equals the full extracted tuple;
- selected coverage: inventory equals the approved binding union ordered by the full extraction;
- every approved selected ID still exists in the full extraction.

Keep whole-file source digests in private provenance so any source-byte drift still requires review.

- [ ] **Step 5: Run focused and full tests**

Run the new tests, `test_staged.py`, `test_validation.py`, and then the complete legacy-parity suite. Expected: all pass.

- [ ] **Step 6: Commit the validator correction**

```bash
git add tools/legacy_parity/validation.py tests/legacy_parity/test_validation.py tests/legacy_parity/test_staged.py
git commit -m "fix: honor approved selected-source coverage"
```

- [ ] **Step 7: Write the failing approved-token collision test**

Create a synthetic selection where an omitted candidate's bare filename stem also occurs inside the authenticated canonical public scope as an approved target, source, current plugin, or selected feature key. Assert the exact omitted path remains a deny token, an unrelated omitted stem remains denied, and the ambiguous bare stem does not reject the approved public scope.

- [ ] **Step 8: Run the privacy test and verify RED**

Run the new test alone. Expected: FAIL with `private_deny_token` because `build_private_deny_tokens()` currently treats every omitted filename stem as unconditionally private even when that text is independently approved.

- [ ] **Step 9: Implement scope-aware deny-token construction**

Add an explicit approved-public-scope input to `build_private_deny_tokens()`. Always deny the exact omitted path. Deny its bare stem only when that stem does not occur in the authenticated canonical public scope. Pass the exact approved scope from full-private validation; do not infer approval from candidate artifact text.

- [ ] **Step 10: Run privacy and full tests, then commit**

Run `test_privacy.py`, `test_validation.py`, and the complete legacy-parity suite. Expected: all pass, exact omitted paths remain protected, and independently approved scope tokens no longer cause false positives.

```bash
git add tools/legacy_parity/privacy.py tools/legacy_parity/validation.py tests/legacy_parity/test_privacy.py tests/legacy_parity/test_validation.py
git commit -m "fix: distinguish approved privacy token collisions"
```

### Task 3: Make full-private validation complete and runtime-reproducible

**Files:**
- Modify: `tools/legacy_parity/validation.py`
- Modify: `tools/legacy_parity/runtime.py`
- Test: `tests/legacy_parity/test_validation.py`
- Test: `tests/legacy_parity/test_runtime.py`
- Test: `tests/legacy_parity/test_acceptance.py`

- [ ] **Step 1: Write the failing strict-order regression test**

Build a bundle containing both a non-parity feature and a later full-private defect such as runtime fixture drift. Run with `require_parity=True` and assert the full-private defect is detected before `strict_parity_status`. This proves strict mode does not bypass construct, provenance, mirror, runtime, issue, or privacy gates.

- [ ] **Step 2: Run the strict-order test and verify RED**

Expected: FAIL because `_validate_private()` currently raises `strict_parity_status` immediately after loading the bundle.

- [ ] **Step 3: Write failing recurring-runtime tests**

Store a safe scenario under private state, stage a matching pass result, then change the plugin or scenario expectation so an actual rerun fails. Assert full-private validation rejects the stale pass. Also reject a missing scenario file, scenario digest mismatch, target/plugin mismatch, unsafe fixture key, and nonzero Lera exit.

- [ ] **Step 4: Run the runtime tests and verify RED**

Expected: stale stored pass is incorrectly accepted because current `_validate_runtime()` checks metadata only.

- [ ] **Step 5: Implement private scenario resolution and reruns**

Resolve each safe `fixture_key` only below `PrivateValidationRoots.state_root / "staged" / "runtime" / "<fixture-key>.json"`; reject traversal and alternate roots. This must honor `--state-root`, XDG defaults, and temporary test roots. Hash the exact scenario bytes, compare `fixture_digest`, load with `load_scenario()`, require its plugin path to belong to the scenario target's approved current mapping, execute it with `run_scenario()` against the supplied repository and Lera binary, and compare the freshly derived outcome with the staged result.

- [ ] **Step 6: Move strict status evaluation behind the full gate**

Run construct snapshots, provenance, mirror comparison, recurring scenarios, issue links, and privacy checks first. Evaluate `strict_parity_findings()` only after those base checks pass and immediately before the successful return/refresh transaction.

- [ ] **Step 7: Run focused, acceptance, and full tests**

Run `test_runtime.py`, `test_validation.py`, `test_acceptance.py`, then the full legacy-parity suite. Expected: all pass; a stale runtime result is rejected and strict mode completes all base checks before reporting parity status.

- [ ] **Step 8: Commit the full-private correction**

```bash
git add tools/legacy_parity/runtime.py tools/legacy_parity/validation.py tests/legacy_parity/test_runtime.py tests/legacy_parity/test_validation.py tests/legacy_parity/test_acceptance.py
git commit -m "fix: rerun runtime evidence in strict validation"
```

### Task 4: Build the private target-audit workspace

**Files:**
- Create privately: `staged/workspace/audit_workspace.py`
- Create privately: `staged/workspace/test_audit_workspace.py`

- [ ] **Step 1: Write synthetic failing tests**

Cover `snapshot`, `validate-target`, `assemble`, and sanitized `summary` operations. Tests must reject incomplete/duplicate construct assignment, selected-binding drift, source/mapping drift, unsafe summaries, missing evidence, and writes outside private state.

- [ ] **Step 2: Verify RED**

Run the private tests with Python 3.12. Expected: failure because the helper does not exist.

- [ ] **Step 3: Implement the minimal private helper**

Use only `tools.legacy_parity` public dataclasses and validators. `snapshot TARGET` writes a mode-`0600` skeleton from authenticated selection; `validate-target TARGET` applies the standard protocol; `assemble` sorts and combines all 32 fragments without inventing targets; `summary` prints only approved target keys and aggregate status counts.

- [ ] **Step 4: Verify GREEN and permissions**

Run all private helper tests and verify workspace directory mode `0700`, files mode `0600`, and no path resolves inside either public repository.

### Task 5: Audit `autostepper`

**Sources:** `lua/autostepper.lua`, `plugins/autostepper.xml`

**Current mapping:** `3scapes/autostepper.lua`

- [ ] Apply the standard per-target audit protocol to all constructs in both complete sources, including route-step state, combat stepping, aliases, callbacks, persistence, and dependencies.
- [ ] Add safe offline scenarios for representative step progression, target handling, and send effects.
- [ ] Validate the private `autostepper` fragment; do not claim parity for behavior not exercised or completely reviewed.

### Task 6: Audit `chat_monitor`

**Source:** `plugins/chat_monitor.xml`

**Current mapping:** `3scapes/chat_monitor.lua`

- [ ] Apply the standard protocol to all chat capture, filtering, gagging, persistence, wrapping, rendering, and configuration behavior.
- [ ] Exercise safe MIP tell, emote, and chat scenarios plus local/remote render-state behavior in isolation.
- [ ] Validate the private `chat_monitor` fragment against the newly reconciled current file.

### Task 7: Audit `deadmans`

**Sources:** `lua/deadmans_switch.lua`, `plugins/deadmans_switch.xml`

**Current mapping:** `generic/deadmans.lua`

- [ ] Apply the standard protocol to idle accounting, warning/block thresholds, send suppression, timer behavior, commands, persistence, and status rendering.
- [ ] Exercise boundary-time and blocked-send scenarios with the deterministic clock.
- [ ] Validate the private `deadmans` fragment.

### Task 8: Audit `general`

**Selected source:** `plugins/general.xml`

**Current mapping:** none

**Approved selected features:** `angry_abyss_alert`, `automatic_acceptance`, `combat_proc_display`, `daemon_graft_confirmation`, `hidden_spike_interaction`, `hidden_wall_search_recovery`, `high_colonic_auto_attack`, `mining_automation`, `necromancer_teleport_rope`, `party_assist_shortcuts`, `party_divvy_recovery`, `reputation_display`, `retrieve_new_creation`, `river_crossing`, `shansabyk_life_alert`, `skill_training_confirmation`, `torch_maintenance`.

- [ ] Snapshot only the authenticated bindings for these 17 feature keys; do not enumerate or classify any other construct from the shared source.
- [ ] Review and record each approved feature separately as `not_converted` with private evidence.
- [ ] Validate selected-binding equality and the private `general` fragment.

### Task 9: Audit `guild_angels`

**Sources:** `lua/guild_angel.lua`, `plugins/guild_angels.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to both complete sources, group all approved guild behavior into safe features, and mark every feature `not_converted`.
- [ ] Validate the private `guild_angels` fragment.

### Task 10: Audit `guild_bards`

**Sources:** `lua/guild_bard.lua`, `plugins/guild_bards.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to both complete sources and classify all approved guild behavior as `not_converted`.
- [ ] Validate the private `guild_bards` fragment.

### Task 11: Audit `guild_breeds`

**Sources:** `lua/guild_breed.lua`, `plugins/guild_breeds.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to both complete sources and classify all approved guild behavior as `not_converted`.
- [ ] Validate the private `guild_breeds` fragment.

### Task 12: Audit `guild_changelings`

**Source:** `plugins/guild_changelings.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to the complete source and classify all approved guild behavior as `not_converted`.
- [ ] Validate the private `guild_changelings` fragment.

### Task 13: Audit `guild_cyborgs`

**Sources:** `lua/guild_cyborg.lua`, `plugins/guild_cyborgs.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to both complete sources and classify all approved guild behavior as `not_converted`.
- [ ] Validate the private `guild_cyborgs` fragment.

### Task 14: Audit `guild_druid`

**Sources:** `lua/guild_druid.lua`, `plugins/guild_druid.xml`

**Current mapping:** `3scapes/guild_druid.lua`

- [ ] Apply the standard protocol to guild status parsing/rendering, command automation, kill-trigger integration, aliases, persistence, and setup behavior.
- [ ] Exercise safe custom-status, automation-decision, and renderer scenarios with dependencies stubbed.
- [ ] Validate the private `guild_druid` fragment with exact current references.

### Task 15: Audit `guild_elementals`

**Source:** `plugins/guild_elementals.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to the complete source and classify every feature `not_converted`.
- [ ] Validate the private `guild_elementals` fragment.

### Task 16: Audit `guild_fremen`

**Source:** `plugins/guild_fremen.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to the complete source and classify every feature `not_converted`.
- [ ] Validate the private `guild_fremen` fragment.

### Task 17: Audit `guild_gentech`

**Source:** `plugins/guild_gentech.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to the complete source and classify every feature `not_converted`.
- [ ] Validate the private `guild_gentech` fragment.

### Task 18: Audit `guild_jedis`

**Sources:** `lua/guild_jedi.lua`, `plugins/guild_jedis.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to both complete sources and classify every feature `not_converted`.
- [ ] Validate the private `guild_jedis` fragment.

### Task 19: Audit `guild_juggernauts`

**Sources:** `lua/guild_jugger.lua`, `plugins/guild_juggernauts.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to both complete sources and classify every feature `not_converted`.
- [ ] Validate the private `guild_juggernauts` fragment.

### Task 20: Audit `guild_knights`

**Sources:** `lua/guild_knight.lua`, `plugins/guild_knights.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to both complete sources and classify every feature `not_converted`.
- [ ] Validate the private `guild_knights` fragment.

### Task 21: Audit `guild_mage`

**Source:** `plugins/guild_mage.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to the complete source and classify every feature `not_converted`.
- [ ] Validate the private `guild_mage` fragment.

### Task 22: Audit `guild_monks`

**Source:** `plugins/guild_monks.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to the complete source and classify every feature `not_converted`.
- [ ] Validate the private `guild_monks` fragment.

### Task 23: Audit `guild_necromancers`

**Sources:** `lua/guild_necromancers.lua`, `plugins/guild_necromancers.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to both complete sources and classify every feature `not_converted`.
- [ ] Validate the private `guild_necromancers` fragment.

### Task 24: Audit `guild_priests`

**Sources:** `lua/guild_priest.lua`, `plugins/guild_priests.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to both complete sources and classify every feature `not_converted`.
- [ ] Validate the private `guild_priests` fragment.

### Task 25: Audit `guild_sii`

**Sources:** `lua/guild_sii.lua`, `plugins/sii.xml`, `plugins/test_window.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to all three complete sources, including window behavior only where it belongs to this approved target.
- [ ] Classify every feature `not_converted` and validate the private `guild_sii` fragment.

### Task 26: Audit `guild_viking`

**Sources:** `lua/guild_viking.lua`, `lua/guild_viking_autotrader.lua`, `plugins/guild_viking.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to all three complete sources, preserving trader behavior as explicit features.
- [ ] Classify every feature `not_converted` and validate the private `guild_viking` fragment.

### Task 27: Audit `guild_warders`

**Source:** `plugins/guild_warders.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to the complete source and classify every feature `not_converted`.
- [ ] Validate the private `guild_warders` fragment.

### Task 28: Audit `guild_witches`

**Source:** `plugins/witches.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to the complete source and classify every feature `not_converted`.
- [ ] Validate the private `guild_witches` fragment.

### Task 29: Audit `kill_trigger`

**Sources:** `plugins/kill_command.xml`, `plugins/kill_trigger.xml`

**Current mapping:** `3scapes/kill_trigger.lua`

- [ ] Apply the standard protocol to killing-blow recognition, output handling, killer/non-killer command queues, counters, persistence, aliases, and rendering.
- [ ] Exercise representative safe trigger callbacks and queue/state transitions offline.
- [ ] Validate the private `kill_trigger` fragment with exact current references.

### Task 30: Audit `mercenary`

**Sources:** `plugins/merc_monitor.xml`, `plugins/mercenary_stats.xml`

**Current mapping:** `3scapes/mercenary.lua`

- [ ] Apply the standard protocol to protocol parsing, counters, rates/deltas, automatic-use decisions, persistence, rendering, and public APIs.
- [ ] Exercise safe mercenary protocol and state-transition scenarios offline.
- [ ] Validate the private `mercenary` fragment.

### Task 31: Audit `minimap`

**Source:** `plugins/minimap.xml`

**Current mapping:** `3scapes/minimap.lua`

- [ ] Apply the standard protocol to map-line detection, capture/finalization, path highlighting, rendering, commands, persistence, and public APIs.
- [ ] Exercise representative map capture and highlighting scenarios offline without a MUD connection.
- [ ] Validate the private `minimap` fragment.

### Task 32: Audit `party_interface`

**Source:** `plugins/party_interface.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to the complete source and classify every feature `not_converted`.
- [ ] Validate the private `party_interface` fragment.

### Task 33: Audit `professions`

**Sources:** `plugins/profession_reforger.xml`, `plugins/profession_transmuter.xml`, `plugins/professions.xml`

**Current mapping:** none

- [ ] Apply the standard protocol to all three complete sources, preserving shared and profession-specific responsibilities as separate safe features.
- [ ] Classify every feature `not_converted` and validate the private `professions` fragment.

### Task 34: Audit `push_notify`

**Sources:** `lua/push_notifications.lua`, selected `plugins/general.xml`, `plugins/push_notifications.xml`

**Current mapping:** `generic/push_notify.lua`

**Approved selected feature:** `wimpy_push_notification` from `plugins/general.xml`.

- [ ] Audit all constructs in the complete sources and only the authenticated `wimpy_push_notification` binding from the shared selected source.
- [ ] Compare credentials/configuration handling, channels, keyword/rate/grace behavior, disconnect notification, and the selected wimpy notification with the current plugin.
- [ ] Exercise safe stubbed push scenarios; never read or send real credentials.
- [ ] Validate the private `push_notify` fragment and selected-binding equality.

### Task 35: Audit `speedwalk_routes`

**Sources:** `lua/speedwalker.lua`, `lua/speedwalks.lua`, `plugins/Speedwalks.xml`, selected `plugins/general.xml`, `plugins/speedwalker.xml`

**Current mapping:** `3scapes/speedwalk.lua`

**Approved selected feature:** `speedwalk_train_continuation` from `plugins/general.xml`.

- [ ] Audit every construct in the four complete sources and only the authenticated train-continuation binding from the selected shared source.
- [ ] Compare route parsing, graph registration, reverse paths, walk queue/pause/continue behavior, place configuration, step lists, aliases, persistence, and public APIs.
- [ ] Exercise safe route/queue/step scenarios with `mud.send` captured.
- [ ] Validate the private `speedwalk_routes` fragment and selected-binding equality.

### Task 36: Audit `status_monitor`

**Sources:** `plugins/clock.xml`, `plugins/damage_tracker.xml`, `plugins/hmheal.xml`, `plugins/hmonitor.xml`, `plugins/status_monitor.xml`, selected `plugins/status_monitor_new.xml`, `plugins/timer_window.xml`, `plugins/wiz_damage_tracker.xml`, `plugins/xp_monitor.xml`

**Current mapping:** `3scapes/stats_window.lua`

**Approved selected feature:** `coffin_status_mip` from `plugins/status_monitor_new.xml`.

- [ ] Audit all constructs in the eight complete sources and only the authenticated coffin-status binding from the selected source.
- [ ] Compare XP, damage, healing, health/resource, clock/timer, coffin-status, composition, rendering, configuration, and dependency behavior with `stats_window` and its approved current dependencies.
- [ ] Exercise safe renderer and protocol/state scenarios in an isolated profile.
- [ ] Validate the private `status_monitor` fragment and selected-binding equality.

### Task 37: Assemble and validate the complete private audit bundle

**Files:**
- Create/update privately: `staged/audit-bundle.json`
- Create/update privately: `provenance.json`

- [ ] **Step 1: Require the exact 32-target set**

Run `audit_workspace.py assemble`. It must fail unless all 32 approved target fragments exist, validate individually, and match revision 1 sources, coverage, bindings, and mappings exactly.

- [ ] **Step 2: Derive provenance privately**

Record the legacy checkout commit, whole-file SHA-256 values for the unique approved dependency closure, the exact approval digests loaded from private state, and all local evidence. Never print or commit these values.

- [ ] **Step 3: Derive blocker records**

Group only confirmed `lera_blocker` features by stable capability key. Require failing evidence, a safe description, exact approved affected feature keys, and approved affected current plugin keys. Leave `issue_url` null until synchronization.

- [ ] **Step 4: Run structural bundle checks**

Require sorted unique target/source/feature/evidence keys, exact-once construct coverage, complete reverse feature coverage, selected-binding equality, runtime scenario/result equality, provenance equality, and safe summaries.

- [ ] **Step 5: Stage the provisional bundle**

Run `tools/legacy-parity stage-audit --input PRIVATE_BUNDLE`. Confirm only `staged/audit-bundle.json` changes and remains mode `0600`.

### Task 38: Synchronize required Lera feature requests

**Files:**
- Update privately: `staged/audit-bundle.json`
- External destination: private `lundmark/lera` GitHub issues

- [ ] **Step 1: Authenticate and verify the destination**

Run `gh auth status`, then let `sync-issues` verify `lundmark/lera` is private. Do not accept another repository slug.

- [ ] **Step 2: Dry-run all derived blockers**

Run `tools/legacy-parity sync-issues --staged PRIVATE_BUNDLE --dry-run`. Expected: reuse a single valid open marker or report that one issue would be created; closed or ambiguous markers stop the task.

- [ ] **Step 3: Create or reuse issues**

Run the same command without `--dry-run`. Each capability gets exactly one issue containing only its safe capability description and approved affected plugins. The command rechecks before and after creation.

- [ ] **Step 4: Revalidate issue linkage**

Require every blocker and capability to have one exact `https://github.com/lundmark/lera/issues/<number>` URL. If there are no confirmed client blockers, record that the derived blocker set is empty and skip external mutation.

### Task 39: Run every isolated runtime scenario

**Files:**
- Update privately: `staged/runtime/*.json`
- Update privately: `staged/audit-bundle.json`

- [ ] **Step 1: Validate scenario safety**

Load every scenario through `load_scenario()`. Reject live paths, `.storage`, `mud.connect`, shell execution, undeclared external APIs, credentials, and non-JSON data.

- [ ] **Step 2: Execute against the real local Lera binary**

Use `run_scenario('/home/simon/code/lera/build/lera', WORKTREE, scenario)` for every mapped-target scenario. Expected: exit `0`, no timeout, captured effects and registrations exactly match, and all storage remains temporary.

- [ ] **Step 3: Record immutable results**

Store scenario key, target key, safe fixture key, fixture digest, a passing outcome, and concise result. Every scenario declared in the final bundle must pass because full-private validation reruns it. If a scenario exposes a behavior gap, classify the affected feature with failing manual/local evidence and either fix the implementation until the scenario passes or remove that scenario from runtime evidence; never convert a failed run into a stored pass.

### Task 40: Generate candidate artifacts and finish private validation

**Files:**
- Generate privately first: candidate manifest/report/not-converted bytes
- Update privately: `staged/audit-bundle.json`, `provenance.json`

- [ ] **Step 1: Derive the manifest and reports**

Use `manifest_from_staged()`, `render_manifest()`, `render_parity_report()`, and `render_not_converted()`. The not-converted file must contain exactly approved targets with empty current mappings.

- [ ] **Step 2: Freeze artifact hashes in the bundle**

Compute SHA-256 for the three exact candidate byte strings and replace the provisional artifact hashes. Use `write_provenance_transaction()` to install `provenance.json` and the identical final hash-bearing staged bundle together with rollback safety.

- [ ] **Step 3: Run the full-private gate against candidate bytes**

Invoke `full_private_publication_gate()` directly with the frozen candidate and staged bundle. Expected: pass without publication. It must authenticate approval, coverage, provenance, mirror equality, issue URLs, rerun every declared runtime scenario, and enforce privacy deny tokens.

- [ ] **Step 4: Run the strict-parity gate deliberately**

Run the same gate with `require_parity=True`. The Task 3 ordering regression guarantees all base full-private checks and runtime reruns complete first. If any approved feature is `plugin_gap`, `lera_blocker`, or `not_converted`, expected result is exit/finding `1` with `strict_parity_status`; record that as the honest strict status, not as a workflow failure. It may pass only when every approved feature is `parity` or explicitly waived.

### Task 41: Publish transactionally and verify recurring validation

**Files:**
- Create: `validation/legacy-parity.toml`
- Create: `validation/parity-report.md`
- Create: `validation/not-converted.md`

- [ ] **Step 1: Publish through the supported transaction**

Run:

```bash
tools/legacy-parity publish \
  --staged /home/simon/.local/state/lera-plugins/legacy-parity/staged/audit-bundle.json \
  --plugin-root /home/simon/code/lera-plugins/.worktrees/legacy-parity \
  --legacy-root /home/simon/code/3s_scripts_old \
  --lera-root /home/simon/code/lera \
  --lera-bin /home/simon/code/lera/build/lera
```

Expected: all three public artifacts appear together, or none changes.

- [ ] **Step 2: Run public validation**

```bash
tools/legacy-parity validate --level public \
  --plugin-root /home/simon/code/lera-plugins/.worktrees/legacy-parity
```

Expected: exit `0` with the public-baseline heading and explicit private-check limitations.

- [ ] **Step 3: Run full-private validation**

```bash
tools/legacy-parity validate --level full-private \
  --plugin-root /home/simon/code/lera-plugins/.worktrees/legacy-parity \
  --legacy-root /home/simon/code/3s_scripts_old \
  --lera-root /home/simon/code/lera \
  --lera-bin /home/simon/code/lera/build/lera
```

Expected: exit `0`, `FULL PRIVATE BASELINE VERIFIED`, and a private report below the state directory.

- [ ] **Step 4: Verify the expected strict result**

Repeat full-private validation with `--require-parity`. Expected: exit `0` only if every approved feature is parity/waived; otherwise exit `1` and leave the honest gap inventory unchanged.

- [ ] **Step 5: Run regression and privacy checks**

Run the complete legacy-parity test suite, `git diff --check`, the tracked/private deny-token scan, and confirm no private state, omitted identity, source body, binding digest, provenance value, or credential entered tracked bytes.

- [ ] **Step 6: Commit the three generated artifacts**

```bash
git add validation/legacy-parity.toml validation/parity-report.md validation/not-converted.md
git commit -m "docs: publish approved legacy parity baseline"
```

### Task 42: Independent final review

**Files:**
- Review: all commits since the authenticated revision-1 checkpoint
- Review privately: staged bundle, provenance, runtime results, and full-private report

- [ ] **Step 1: Request code and audit review**

Use `superpowers:requesting-code-review`. Provide the approved design, this plan, public diff, exact verification commands, and safe status summary. Do not give the reviewer omitted identities or raw legacy bodies.

- [ ] **Step 2: Independently recompute critical invariants**

Require a reviewer to confirm the 17 current plugins, exact 32 approved targets, selected-source boundary, complete construct coverage, current mappings, blocker derivation, runtime result linkage, mirror equality, deterministic artifacts, and privacy scan.

- [ ] **Step 3: Resolve findings and rerun all gates**

Fix material findings with TDD where code changes are needed, regenerate the private bundle/artifacts when evidence changes, and rerun public, full-private, strict, runtime, and privacy checks.

- [ ] **Step 4: Report the baseline honestly**

Report which approved targets are parity, plugin gaps, Lera blockers with issue links, and not converted. State the strict command's actual exit result and keep the separate not-converted inventory free of every non-approved identity.

## Completion criteria

- Revision 1 private approval still authenticates the exact public scope and selected bindings.
- All 32 approved targets have individual, complete, private audit fragments.
- Every in-scope construct is assigned exactly once and every feature has valid evidence.
- Selected sources cover only their authenticated bindings; whole-file provenance still detects source drift.
- Current plugin mirror bytes match Lera's bundled mirror.
- Confirmed client blockers have one deduplicated private Lera issue each; plugin gaps do not create client issues.
- All isolated runtime scenarios have immutable pass/fail results and no live side effects.
- Full-private baseline validation passes; strict mode accurately passes or reports remaining approved gaps.
- The manifest, parity report, and not-converted inventory are published atomically and pass public validation.
- Tracked files contain no private binding digest, provenance, source bodies, credentials, or information about non-approved candidates.
