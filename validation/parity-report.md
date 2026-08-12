PUBLIC BASELINE VERIFIED — PRIVATE APPROVAL AND LEGACY SOURCES NOT RECHECKED

Not rechecked at the public validation level:
- private scope approval
- legacy provenance and construct coverage
- current mirror parity
- private leakage deny tokens
- real Lera runtime

# Legacy parity status

## Current plugins

### `autologin`

- Path: `generic/autologin.lua`
- Approved targets: None

### `autostepper`

- Path: `3scapes/autostepper.lua`
- Approved targets: `autostepper`

### `chat_monitor`

- Path: `3scapes/chat_monitor.lua`
- Approved targets: `chat_monitor`

### `deadmans`

- Path: `generic/deadmans.lua`
- Approved targets: `deadmans`

### `guild_druid`

- Path: `3scapes/guild_druid.lua`
- Approved targets: `guild_druid`

### `help`

- Path: `generic/help.lua`
- Approved targets: None

### `input_echo`

- Path: `generic/input_echo.lua`
- Approved targets: None

### `kill_trigger`

- Path: `3scapes/kill_trigger.lua`
- Approved targets: `kill_trigger`

### `mapper`

- Path: `3scapes/mapper.lua`
- Approved targets: None

### `mapview`

- Path: `3scapes/mapview.lua`
- Approved targets: None

### `mercenary`

- Path: `3scapes/mercenary.lua`
- Approved targets: `mercenary`

### `minimap`

- Path: `3scapes/minimap.lua`
- Approved targets: `minimap`

### `player_stats`

- Path: `3scapes/player_stats.lua`
- Approved targets: None

### `push_notify`

- Path: `generic/push_notify.lua`
- Approved targets: `push_notify`

### `roominfo`

- Path: `3scapes/roominfo.lua`
- Approved targets: None

### `speedwalk`

- Path: `3scapes/speedwalk.lua`
- Approved targets: `speedwalk_routes`

### `stats_window`

- Path: `3scapes/stats_window.lua`
- Approved targets: `status_monitor`

## Approved targets

### `autostepper` — plugin_gap

- Current plugins: `autostepper`
- Feature statuses: parity=1, plugin_gap=15
- `alias_configuration` (alias): plugin_gap — Advanced legacy aliases and runtime configuration controls remain missing.
- `assist_multi_target_combat` (command): plugin_gap — Advanced assist, fallback, and multi-target combat responsibilities remain missing.
- `basic_control_aliases` (alias): parity — Only the two exact overlapping start and stop control registrations are equivalent.
- `callback_dependency_integration` (callback): plugin_gap — Legacy protocol, event, and dependency integrations are not fully equivalent.
- `host_lifecycle` (callback): plugin_gap — Legacy plugin, host, and window lifecycle behavior is not fully equivalent.
- `ordinary_route_step_dispatch` (state): plugin_gap — Ordinary route dispatch is interleaved with missing prediction, recovery, event, and special-mode behavior.
- `ordinary_single_target_attack` (trigger): plugin_gap — Ordinary single-target attack handling cannot be separated from missing filter, shared-target, and protocol behavior.
- `ordinary_start_scan` (command): plugin_gap — Ordinary start and initial inspection are interleaved with missing modes, events, and watchdog state.
- `ordinary_stop_reset` (state): plugin_gap — The basic stop reset is interleaved with richer missing recovery, route, and window cleanup state.
- `persistence` (persistence): plugin_gap — Legacy stepping preferences and route state persistence remain missing.
- `predictive_step_skipping` (state): plugin_gap — Predictive room caching and multi-room step skipping remain missing.
- `richer_room_player_combat_cleanup` (state): plugin_gap — Richer room, player, combat, and stale-state cleanup remains missing.
- `specialized_navigation` (command): plugin_gap — Specialized navigation, recovery routes, and farming modes remain missing.
- `target_filtering_protocol` (trigger): plugin_gap — Ignore, skip, shared-target, and protocol-specific target controls remain missing.
- `watchdog_recovery` (timer): plugin_gap — Idle watchdog, bounded recovery, and resume behavior remain missing.
- `window_status_controls` (rendering): plugin_gap — Legacy status-window rendering and window lifecycle controls remain missing.

### `chat_monitor` — lera_blocker

- Current plugins: `chat_monitor`
- Feature statuses: lera_blocker=7, plugin_gap=16
- `alias_controls` (alias): plugin_gap — Legacy window and monitor aliases remain absent from the mapped plugin.
- `bootstrap_defaults` (state): plugin_gap — Legacy bootstrap defaults and host-specific initialization are not equivalent.
- `channel_visibility_state` (state): plugin_gap — Legacy channel discovery, visibility, and per-channel state remain incomplete.
- `clickable_link_interaction` (rendering): lera_blocker — Clickable link hotspots require pointer click callbacks not exposed to Lua. — [Lera issue #15](https://github.com/lundmark/lera/issues/15)
- `color_preferences` (state): plugin_gap — Legacy color conversion, presets, and saved color preferences remain incomplete.
- `cross_instance_chat_sync` (protocol): plugin_gap — Legacy partner selection, channel synchronization, and queue transport remain missing.
- `diagnostic_support` (command): plugin_gap — Legacy trigger and table diagnostics remain missing.
- `dynamic_event_registration` (callback): plugin_gap — Legacy dynamic chatline triggers and event attachment remain incomplete.
- `filtering_and_gagging` (trigger): plugin_gap — Current type filtering and gags do not cover the full legacy filtering contract.
- `host_lifecycle` (callback): plugin_gap — Legacy host, plugin-list, connection, and enablement lifecycle behavior remains incomplete.
- `interactive_channel_configuration` (rendering): lera_blocker — Interactive channel configuration requires pointer click callbacks not exposed to Lua. — [Lera issue #15](https://github.com/lundmark/lera/issues/15)
- `interactive_color_picker` (rendering): lera_blocker — The interactive color picker requires pointer click and drag callbacks not exposed to Lua. — [Lera issue #16](https://github.com/lundmark/lera/issues/16)
- `link_detection` (rendering): plugin_gap — Legacy URL detection and styled link extraction remain missing.
- `logging_and_export` (persistence): lera_blocker — Timestamped logs, queue files, and message export require an arbitrary file-write API not exposed to plugins. — [Lera issue #8](https://github.com/lundmark/lera/issues/8)
- `message_capture_dispatch` (protocol): plugin_gap — Current MIP capture covers useful subsets but not the complete legacy dispatch contract.
- `message_wrapping_buffering` (state): plugin_gap — Character wrapping and bounded history do not reproduce legacy styled pixel-width buffering.
- `mouse_driven_configuration_menus` (rendering): lera_blocker — Legacy context and synchronization menus require pointer click callbacks not exposed to Lua. — [Lera issue #15](https://github.com/lundmark/lera/issues/15)
- `persistence` (persistence): plugin_gap — Current stored history and type settings do not cover all legacy persistent state.
- `scriptable_clipboard_export` (public_api): lera_blocker — Script-driven clipboard export requires a clipboard-write API not exposed to Lua. — [Lera issue #7](https://github.com/lundmark/lera/issues/7)
- `scroll_and_autofollow` (state): plugin_gap — Current wrapped-row scrolling does not reproduce all legacy scrollbar and autofollow behavior.
- `visual_chat_rendering` (rendering): plugin_gap — ANSI pane rendering does not reproduce the complete legacy styled miniwindow presentation.
- `window_drag_resize` (rendering): lera_blocker — Interactive window movement and resizing require pointer drag callbacks not exposed to Lua. — [Lera issue #16](https://github.com/lundmark/lera/issues/16)
- `window_visibility_state` (state): plugin_gap — Legacy show, hide, minimize, restore, and window-state controls remain incomplete.

### `deadmans` — plugin_gap

- Current plugins: `deadmans`
- Feature statuses: plugin_gap=9
- `bootstrap_state_persistence` (persistence): plugin_gap — Current storage preserves configuration but not the complete legacy runtime-state bootstrap and persistence contract.
- `command_threshold_configuration` (command): plugin_gap — Current aliases configure warning and block thresholds, but command syntax, validation, time modes, and side effects are not strictly equivalent.
- `external_event_integration` (protocol): plugin_gap — Legacy cross-plugin activity and state notifications are not reproduced by the mapped plugin.
- `idle_accounting_activity_reset` (state): plugin_gap — Current epoch-second local-input accounting omits legacy activity sources, clock basis, and reset side effects.
- `legacy_script_bootstrap` (callback): plugin_gap — The legacy host loader and shared-script bootstrap are replaced rather than reproduced by the mapped plugin.
- `lifecycle_event_registration` (callback): plugin_gap — Current load, unload, alias, and timer registration do not reproduce the complete legacy event attachment and cleanup lifecycle.
- `send_suppression` (callback): plugin_gap — Current automated-send blocking is useful, but its derived boundary and feedback behavior are not strictly identical to the legacy send and command hooks.
- `status_feedback_rendering` (rendering): plugin_gap — Current status text and overlay do not reproduce the complete legacy warning, recovery, and timing feedback contract.
- `timer_warning_anti_idle_cutoff` (timer): plugin_gap — Periodic redraw exists, but legacy warning transitions, anti-idle execution, tick state, and daily cutoff behavior remain missing.

### `general` — not_converted

- Current plugins: None
- Feature statuses: not_converted=17
- `angry_abyss_alert` (trigger): not_converted — Approved selected behavior is not converted.
- `automatic_acceptance` (trigger): not_converted — Approved selected behavior is not converted.
- `combat_proc_display` (rendering): not_converted — Approved selected behavior is not converted.
- `daemon_graft_confirmation` (trigger): not_converted — Approved selected behavior is not converted.
- `hidden_spike_interaction` (trigger): not_converted — Approved selected behavior is not converted.
- `hidden_wall_search_recovery` (trigger): not_converted — Approved selected behavior is not converted.
- `high_colonic_auto_attack` (trigger): not_converted — Approved selected behavior is not converted.
- `mining_automation` (command): not_converted — Approved selected behavior is not converted.
- `necromancer_teleport_rope` (trigger): not_converted — Approved selected behavior is not converted.
- `party_assist_shortcuts` (alias): not_converted — Approved selected behavior is not converted.
- `party_divvy_recovery` (trigger): not_converted — Approved selected behavior is not converted.
- `reputation_display` (rendering): not_converted — Approved selected behavior is not converted.
- `retrieve_new_creation` (command): not_converted — Approved selected behavior is not converted.
- `river_crossing` (trigger): not_converted — Approved selected behavior is not converted.
- `shansabyk_life_alert` (trigger): not_converted — Approved selected behavior is not converted.
- `skill_training_confirmation` (trigger): not_converted — Approved selected behavior is not converted.
- `torch_maintenance` (timer): not_converted — Approved selected behavior is not converted.

### `guild_angels` — not_converted

- Current plugins: None
- Feature statuses: not_converted=6
- `guild_command_interface` (alias): not_converted — Provide the legacy guild command interface.
- `guild_event_capture` (trigger): not_converted — Capture guild activity events for downstream processing.
- `guild_event_colour_rendering` (rendering): not_converted — Render guild activity with event-specific colours and actions.
- `guild_plugin_lifecycle` (callback): not_converted — Integrate guild behavior with the legacy plugin lifecycle.
- `guild_session_tracking` (state): not_converted — Track the start and stop phases of guild activity.
- `guild_state_persistence` (persistence): not_converted — Preserve legacy guild configuration across sessions.

### `guild_bards` — not_converted

- Current plugins: None
- Feature statuses: not_converted=13
- `bard_alias_interface` (alias): not_converted — Expose the XML bard command bridge.
- `bard_command_interface` (alias): not_converted — Provide the legacy bard command and configuration interface.
- `bard_event_capture` (trigger): not_converted — Capture legacy bard activity for downstream processing.
- `bard_event_ingestion` (trigger): not_converted — Parse incoming bard events into state transitions.
- `bard_event_state_updates` (state): not_converted — Apply captured bard events to the tracked guild state.
- `bard_performance_automation` (command): not_converted — Select and maintain bard performances from current conditions.
- `bard_plugin_lifecycle` (callback): not_converted — Integrate bard behavior with the legacy plugin lifecycle.
- `bard_rule_configuration` (state): not_converted — Define bard thresholds, song rules, and event classifications.
- `bard_state_model` (state): not_converted — Model the bard's tracked resources, voices, songs, and effects.
- `bard_state_persistence` (persistence): not_converted — Preserve the tracked bard state across sessions.
- `bard_state_reconciliation` (state): not_converted — Reconcile bard state changes and parsed command values.
- `bard_status_reporting` (rendering): not_converted — Report bard readiness and maintain performance status.
- `bard_xml_lifecycle` (callback): not_converted — Load and connect the bard implementation through the XML plugin.

### `guild_breeds` — not_converted

- Current plugins: None
- Feature statuses: not_converted=19
- `breed_aura_maintenance_automation` (command): not_converted — Renew tracked strengthened auras when they expire.
- `breed_automation_configuration` (state): not_converted — Configure automatic Breed aura and maintained-working behavior.
- `breed_chat_event_registration` (callback): not_converted — Register Breed external events and chat channels.
- `breed_combat_maintenance_automation` (command): not_converted — Maintain Breed combat workings and psi recovery actions.
- `breed_combat_state_reconciliation` (state): not_converted — Reset and refresh Breed state after combat ends.
- `breed_command_interface` (alias): not_converted — Expose Breed automation configuration commands.
- `breed_event_configuration` (state): not_converted — Declare external events consumed by Breed behavior.
- `breed_hp_state_ingestion` (trigger): not_converted — Parse Breed prompt values and combat state.
- `breed_mip_state_ingestion` (trigger): not_converted — Parse composite MIP events into Breed and combat state.
- `breed_plugin_lifecycle` (callback): not_converted — Integrate Breed behavior with the legacy plugin lifecycle.
- `breed_state_model` (state): not_converted — Initialize Breed dependencies and tracked guild state.
- `breed_state_persistence` (persistence): not_converted — Save and restore Breed automation and tracked state.
- `breed_status_display_rules` (rendering): not_converted — Define status colors, confidence levels, and maintained-working labels.
- `breed_status_rendering` (rendering): not_converted — Render Breed resources, confidence, coffin, aura, and combat status.
- `breed_trigger_state_updates` (trigger): not_converted — Apply captured Breed effect events and recovery actions.
- `breed_xml_alias_interface` (alias): not_converted — Expose the XML Breed command bridge.
- `breed_xml_effect_capture` (trigger): not_converted — Capture legacy Breed effect and recovery events.
- `breed_xml_lifecycle` (callback): not_converted — Load and connect Breed behavior through the XML plugin.
- `breed_xml_status_capture` (trigger): not_converted — Capture legacy Breed prompt status lines.

### `guild_changelings` — not_converted

- Current plugins: None
- Feature statuses: not_converted=28
- `changeling_action_threshold_configuration` (alias): not_converted — Stores an operator-selected resource threshold for automated actions.
- `changeling_active_effect_toggle_state` (state): not_converted — Toggles one temporary combat effect and records activation or deactivation feedback.
- `changeling_automation_preference_commands` (alias): not_converted — Exposes independent controls for optional automation behaviors.
- `changeling_auxiliary_inventory_tracking` (state): not_converted — Tracks a bounded auxiliary inventory across availability events.
- `changeling_auxiliary_resource_alerts` (rendering): not_converted — Maintains warning thresholds and emits low-resource alerts.
- `changeling_combat_output_suppression` (trigger): not_converted — Suppresses high-volume combat and recovery output that does not update state.
- `changeling_combat_session_state` (state): not_converted — Maintains combat-session markers across engagement, reset, and movement.
- `changeling_combat_status_reconciliation` (state): not_converted — Reconciles opponent condition, combat state, round count, and final status.
- `changeling_contextual_shortcut_commands` (alias): not_converted — Provides direct and context-sensitive convenience command sequences.
- `changeling_defensive_mode_control` (command): not_converted — Controls a sustained defensive mode and records its external transitions.
- `changeling_emergency_movement_response` (command): not_converted — Invokes an escape response after an involuntary movement event.
- `changeling_extended_status_rendering` (rendering): not_converted — Renders a consolidated resource and form-status display.
- `changeling_linked_resource_transfer_assist` (command): not_converted — Filters linked-transfer chatter and performs a configured transfer sequence.
- `changeling_manual_status_refresh` (alias): not_converted — Adjusts the round counter and requests an immediate status refresh.
- `changeling_map_aware_movement_commands` (alias): not_converted — Wraps directional commands with optional mapping and combat-state handling.
- `changeling_plugin_lifecycle_setup` (callback): not_converted — Initializes defaults, persistence timing, startup actions, and disconnect feedback.
- `changeling_plugin_runtime_bootstrap` (callback): not_converted — Defines the plugin envelope and loads shared runtime dependencies.
- `changeling_post_combat_resource_workflow` (command): not_converted — Resets combat markers and selects an enabled post-encounter resource action.
- `changeling_primary_vitals_automation` (command): not_converted — Applies threshold-driven release, offense, recovery, and consumable actions.
- `changeling_primary_vitals_state_ingestion` (trigger): not_converted — Parses and persists the primary resource prompt and automation context.
- `changeling_recovery_consumable_state` (state): not_converted — Tracks recovery, consumable, and offensive-effect result states.
- `changeling_resource_extraction_retry` (command): not_converted — Schedules a delayed retry after a transient resource-extraction failure.
- `changeling_resource_release_control` (command): not_converted — Responds to an approaching resource condition and tracks release-mode transitions.
- `changeling_secondary_status_state_ingestion` (trigger): not_converted — Parses and persists secondary form, skill, condition, and opponent status.
- `changeling_specialization_feedback` (rendering): not_converted — Displays specialization state feedback and queries specialization status.
- `changeling_state_persistence_sync` (persistence): not_converted — Applies broadcast state updates and performs periodic state persistence.
- `changeling_temporary_form_actions` (command): not_converted — Temporarily selects action prerequisites and optionally restores prior state.
- `changeling_transformation_capacity_tracking` (state): not_converted — Tracks, resets, and conditionally reuses transformation capacity.

### `guild_cyborgs` — not_converted

- Current plugins: None
- Feature statuses: not_converted=23
- `cyborg_lua_combat_workflow` (command): not_converted — Preserve the legacy cyborg combat workflow responsibility.
- `cyborg_lua_configuration_data` (state): not_converted — Define the legacy cyborg configuration and resource data.
- `cyborg_lua_lifecycle_01` (callback): not_converted — Preserve one complete legacy cyborg initialization and lifecycle helper responsibility.
- `cyborg_lua_lifecycle_02` (callback): not_converted — Preserve one complete legacy cyborg initialization and lifecycle helper responsibility.
- `cyborg_lua_lifecycle_03` (callback): not_converted — Preserve one complete legacy cyborg initialization and lifecycle helper responsibility.
- `cyborg_lua_lifecycle_04` (callback): not_converted — Preserve one complete legacy cyborg initialization and lifecycle helper responsibility.
- `cyborg_lua_lifecycle_05` (callback): not_converted — Preserve one complete legacy cyborg initialization and lifecycle helper responsibility.
- `cyborg_lua_lifecycle_06` (callback): not_converted — Preserve one complete legacy cyborg initialization and lifecycle helper responsibility.
- `cyborg_lua_lifecycle_07` (callback): not_converted — Preserve one complete legacy cyborg initialization and lifecycle helper responsibility.
- `cyborg_lua_persistence_01` (persistence): not_converted — Preserve one complete legacy cyborg persistence helper responsibility.
- `cyborg_lua_persistence_02` (persistence): not_converted — Preserve one complete legacy cyborg persistence helper responsibility.
- `cyborg_lua_resource_tracking_01` (state): not_converted — Preserve one complete legacy cyborg resource-tracking helper responsibility.
- `cyborg_lua_resource_tracking_02` (state): not_converted — Preserve one complete legacy cyborg resource-tracking helper responsibility.
- `cyborg_lua_state_management_01` (state): not_converted — Preserve one complete legacy cyborg state-management helper responsibility.
- `cyborg_lua_state_management_02` (state): not_converted — Preserve one complete legacy cyborg state-management helper responsibility.
- `cyborg_lua_state_management_03` (state): not_converted — Preserve one complete legacy cyborg state-management helper responsibility.
- `cyborg_lua_state_management_04` (state): not_converted — Preserve one complete legacy cyborg state-management helper responsibility.
- `cyborg_lua_state_management_05` (state): not_converted — Preserve one complete legacy cyborg state-management helper responsibility.
- `cyborg_lua_state_management_06` (state): not_converted — Preserve one complete legacy cyborg state-management helper responsibility.
- `cyborg_xml_alias_behavior` (alias): not_converted — Preserve the legacy cyborg XML alias responsibility.
- `cyborg_xml_embedded_script_behavior` (callback): not_converted — Preserve the legacy cyborg XML embedded-script responsibility.
- `cyborg_xml_plugin_configuration` (callback): not_converted — Preserve the legacy cyborg XML plugin configuration.
- `cyborg_xml_trigger_behavior` (trigger): not_converted — Preserve the legacy cyborg XML trigger responsibilities.

### `guild_druid` — plugin_gap

- Current plugins: `guild_druid`
- Feature statuses: plugin_gap=30
- `lua_alias_command_controls` (alias): plugin_gap — Legacy command aliases expose controls that are not completely equivalent in the current plugin.
- `lua_automation_decisions` (command): plugin_gap — Legacy automation decisions and send ordering are not completely equivalent in the current plugin.
- `lua_automation_display` (rendering): plugin_gap — Legacy automation display behavior is not fully reproduced by the current plugin.
- `lua_automation_preferences` (persistence): plugin_gap — Legacy automation preferences are not completely preserved by the current plugin.
- `lua_automation_trigger_sync` (trigger): plugin_gap — Legacy automation trigger synchronization is not completely reproduced by the current plugin.
- `lua_core_state_support` (state): plugin_gap — Legacy core state and utility behavior is not completely reproduced by the current plugin.
- `lua_custom_status_parsing` (protocol): plugin_gap — Legacy custom status parsing is only partially represented by the current plugin.
- `lua_guild_experience_state` (state): plugin_gap — Legacy guild experience accounting is not completely equivalent in the current plugin.
- `lua_guild_status_parsing` (protocol): plugin_gap — Legacy guild status parsing is not completely equivalent in the current plugin.
- `lua_kill_and_combat_state` (trigger): plugin_gap — Legacy combat and kill state transitions are not completely reproduced by the current plugin.
- `lua_kill_trigger_integration` (trigger): plugin_gap — Legacy kill-trigger integration has behavior not completely reproduced by the current plugin.
- `lua_legacy_setup_helpers` (callback): plugin_gap — Legacy setup helper callbacks are not completely reproduced by the current plugin.
- `lua_lingering_status_rendering` (rendering): plugin_gap — Legacy lingering-effect rendering is not completely equivalent in the current plugin.
- `lua_persistence_setup` (persistence): plugin_gap — Legacy persistence and setup lifecycle behavior is not completely equivalent in the current plugin.
- `lua_renderer_experience` (rendering): plugin_gap — Legacy guild experience rendering is not completely equivalent in the current plugin.
- `lua_renderer_session_summary` (rendering): plugin_gap — Legacy session summary rendering is not completely equivalent in the current plugin.
- `lua_renderer_status_header` (rendering): plugin_gap — Legacy status header rendering is not completely equivalent in the current plugin.
- `lua_renderer_status_resources` (rendering): plugin_gap — Legacy resource rendering is only partially represented by the current plugin.
- `lua_spell_state_and_queue` (state): plugin_gap — Legacy spell state and queue tracking is not completely reproduced by the current plugin.
- `lua_status_helper_values` (state): plugin_gap — Legacy status helper values are not completely reproduced by the current plugin.
- `lua_status_parse_helpers` (protocol): plugin_gap — Legacy status parsing helpers are not completely reproduced by the current plugin.
- `lua_status_state_model` (state): plugin_gap — Legacy status state behavior is not completely equivalent in the current plugin.
- `lua_status_window_updates` (rendering): plugin_gap — Legacy status window updates are not completely equivalent in the current plugin.
- `lua_table_helper_support` (callback): plugin_gap — Legacy collection helper behavior is not completely reproduced by the current plugin.
- `lua_trigger_timer_dispatch` (timer): plugin_gap — Legacy trigger and timer dispatch behavior is not completely reproduced by the current plugin.
- `lua_ui_state_helpers` (rendering): plugin_gap — Legacy UI state helpers are not completely reproduced by the current plugin.
- `xml_alias_registration` (alias): plugin_gap — Legacy XML alias registrations are not completely equivalent in the current plugin.
- `xml_metadata` (state): plugin_gap — Legacy XML metadata has no complete current semantic equivalent.
- `xml_script_lifecycle` (callback): plugin_gap — Legacy embedded script lifecycle behavior is not completely reproduced by the current plugin.
- `xml_trigger_registration` (trigger): plugin_gap — Legacy XML trigger registrations are not completely equivalent in the current plugin.

### `guild_elementals` — not_converted

- Current plugins: None
- Feature statuses: not_converted=28
- `legacy_command_automation` (command): not_converted — Legacy command-alias responsibilities remain unavailable in the current plugin set.
- `legacy_embedded_responsibility_01` (callback): not_converted — Legacy embedded automation responsibility segment 01 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_02` (callback): not_converted — Legacy embedded automation responsibility segment 02 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_03` (callback): not_converted — Legacy embedded automation responsibility segment 03 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_04` (callback): not_converted — Legacy embedded automation responsibility segment 04 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_05` (callback): not_converted — Legacy embedded automation responsibility segment 05 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_06` (callback): not_converted — Legacy embedded automation responsibility segment 06 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_07` (callback): not_converted — Legacy embedded automation responsibility segment 07 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_08` (callback): not_converted — Legacy embedded automation responsibility segment 08 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_09` (callback): not_converted — Legacy embedded automation responsibility segment 09 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_10` (callback): not_converted — Legacy embedded automation responsibility segment 10 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_11` (callback): not_converted — Legacy embedded automation responsibility segment 11 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_12` (callback): not_converted — Legacy embedded automation responsibility segment 12 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_13` (callback): not_converted — Legacy embedded automation responsibility segment 13 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_14` (callback): not_converted — Legacy embedded automation responsibility segment 14 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_15` (callback): not_converted — Legacy embedded automation responsibility segment 15 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_16` (callback): not_converted — Legacy embedded automation responsibility segment 16 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_17` (callback): not_converted — Legacy embedded automation responsibility segment 17 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_18` (callback): not_converted — Legacy embedded automation responsibility segment 18 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_19` (callback): not_converted — Legacy embedded automation responsibility segment 19 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_20` (callback): not_converted — Legacy embedded automation responsibility segment 20 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_21` (callback): not_converted — Legacy embedded automation responsibility segment 21 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_22` (callback): not_converted — Legacy embedded automation responsibility segment 22 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_23` (callback): not_converted — Legacy embedded automation responsibility segment 23 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_24` (callback): not_converted — Legacy embedded automation responsibility segment 24 remains unavailable in the current plugin set.
- `legacy_timer_and_persistence` (persistence): not_converted — Legacy timer, persisted-state, and embedded-script container responsibilities remain unavailable in the current plugin set.
- `legacy_trigger_automation` (trigger): not_converted — Legacy event-trigger responsibilities remain unavailable in the current plugin set.
- `legacy_xml_metadata` (protocol): not_converted — Legacy plugin metadata and loading responsibilities remain unavailable in the current plugin set.

### `guild_fremen` — not_converted

- Current plugins: None
- Feature statuses: not_converted=28
- `legacy_command_automation` (command): not_converted — Legacy command-alias responsibilities remain unavailable in the current plugin set.
- `legacy_embedded_responsibility_01` (callback): not_converted — Legacy embedded automation responsibility segment 01 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_02` (callback): not_converted — Legacy embedded automation responsibility segment 02 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_03` (callback): not_converted — Legacy embedded automation responsibility segment 03 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_04` (callback): not_converted — Legacy embedded automation responsibility segment 04 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_05` (callback): not_converted — Legacy embedded automation responsibility segment 05 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_06` (callback): not_converted — Legacy embedded automation responsibility segment 06 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_07` (callback): not_converted — Legacy embedded automation responsibility segment 07 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_08` (callback): not_converted — Legacy embedded automation responsibility segment 08 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_09` (callback): not_converted — Legacy embedded automation responsibility segment 09 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_10` (callback): not_converted — Legacy embedded automation responsibility segment 10 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_11` (callback): not_converted — Legacy embedded automation responsibility segment 11 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_12` (callback): not_converted — Legacy embedded automation responsibility segment 12 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_13` (callback): not_converted — Legacy embedded automation responsibility segment 13 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_14` (callback): not_converted — Legacy embedded automation responsibility segment 14 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_15` (callback): not_converted — Legacy embedded automation responsibility segment 15 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_16` (callback): not_converted — Legacy embedded automation responsibility segment 16 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_17` (callback): not_converted — Legacy embedded automation responsibility segment 17 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_18` (callback): not_converted — Legacy embedded automation responsibility segment 18 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_19` (callback): not_converted — Legacy embedded automation responsibility segment 19 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_20` (callback): not_converted — Legacy embedded automation responsibility segment 20 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_21` (callback): not_converted — Legacy embedded automation responsibility segment 21 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_22` (callback): not_converted — Legacy embedded automation responsibility segment 22 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_23` (callback): not_converted — Legacy embedded automation responsibility segment 23 remains unavailable in the current plugin set.
- `legacy_embedded_responsibility_24` (callback): not_converted — Legacy embedded automation responsibility segment 24 remains unavailable in the current plugin set.
- `legacy_script_container` (callback): not_converted — Legacy embedded-script container responsibilities remain unavailable in the current plugin set.
- `legacy_trigger_automation` (trigger): not_converted — Legacy event-trigger responsibilities remain unavailable in the current plugin set.
- `legacy_xml_metadata` (protocol): not_converted — Legacy plugin metadata and loading responsibilities remain unavailable in the current plugin set.

### `guild_gentech` — not_converted

- Current plugins: None
- Feature statuses: not_converted=32
- `command_responsibility_01` (command): not_converted — Legacy source-delimited command responsibility group 01.
- `command_responsibility_02` (command): not_converted — Legacy source-delimited command responsibility group 02.
- `plugin_metadata` (protocol): not_converted — Legacy plugin configuration and metadata.
- `script_initialization` (protocol): not_converted — Legacy embedded-script initialization responsibility.
- `script_responsibility_01` (callback): not_converted — Legacy function-delimited embedded-script responsibility 01.
- `script_responsibility_02` (callback): not_converted — Legacy function-delimited embedded-script responsibility 02.
- `script_responsibility_03` (callback): not_converted — Legacy function-delimited embedded-script responsibility 03.
- `script_responsibility_04` (callback): not_converted — Legacy function-delimited embedded-script responsibility 04.
- `script_responsibility_05` (callback): not_converted — Legacy function-delimited embedded-script responsibility 05.
- `script_responsibility_06` (callback): not_converted — Legacy function-delimited embedded-script responsibility 06.
- `script_responsibility_07` (callback): not_converted — Legacy function-delimited embedded-script responsibility 07.
- `script_responsibility_08` (callback): not_converted — Legacy function-delimited embedded-script responsibility 08.
- `script_responsibility_09` (callback): not_converted — Legacy function-delimited embedded-script responsibility 09.
- `script_responsibility_10` (callback): not_converted — Legacy function-delimited embedded-script responsibility 10.
- `script_responsibility_11` (callback): not_converted — Legacy function-delimited embedded-script responsibility 11.
- `script_responsibility_12` (callback): not_converted — Legacy function-delimited embedded-script responsibility 12.
- `script_responsibility_13` (callback): not_converted — Legacy function-delimited embedded-script responsibility 13.
- `script_responsibility_14` (callback): not_converted — Legacy function-delimited embedded-script responsibility 14.
- `script_responsibility_15` (callback): not_converted — Legacy function-delimited embedded-script responsibility 15.
- `script_responsibility_16` (callback): not_converted — Legacy function-delimited embedded-script responsibility 16.
- `script_responsibility_17` (callback): not_converted — Legacy function-delimited embedded-script responsibility 17.
- `script_responsibility_18` (callback): not_converted — Legacy function-delimited embedded-script responsibility 18.
- `script_responsibility_19` (callback): not_converted — Legacy function-delimited embedded-script responsibility 19.
- `script_responsibility_20` (callback): not_converted — Legacy function-delimited embedded-script responsibility 20.
- `script_responsibility_21` (callback): not_converted — Legacy function-delimited embedded-script responsibility 21.
- `trigger_responsibility_01` (trigger): not_converted — Legacy source-delimited trigger responsibility group 01.
- `trigger_responsibility_02` (trigger): not_converted — Legacy source-delimited trigger responsibility group 02.
- `trigger_responsibility_03` (trigger): not_converted — Legacy source-delimited trigger responsibility group 03.
- `trigger_responsibility_04` (trigger): not_converted — Legacy source-delimited trigger responsibility group 04.
- `trigger_responsibility_05` (trigger): not_converted — Legacy source-delimited trigger responsibility group 05.
- `trigger_responsibility_06` (trigger): not_converted — Legacy source-delimited trigger responsibility group 06.
- `trigger_responsibility_07` (trigger): not_converted — Legacy source-delimited trigger responsibility group 07.

### `guild_jedis` — not_converted

- Current plugins: None
- Feature statuses: not_converted=19
- `jedi_automation_configuration` (state): not_converted — Configure automatic Jedi power maintenance behavior.
- `jedi_combat_maintenance_automation` (command): not_converted — Issue conditional combat, recovery, charge, and maintained-effect actions.
- `jedi_combat_status_reconciliation` (state): not_converted — Classify rendered opponent status and reconcile combat-round state.
- `jedi_command_interface` (alias): not_converted — Expose inspection and mutation of Jedi automation settings.
- `jedi_display_bootstrap` (rendering): not_converted — Load display dependencies and define status color-selection helpers.
- `jedi_effect_state_updates` (trigger): not_converted — Apply captured on-and-off transitions to tracked Jedi effects.
- `jedi_event_configuration` (state): not_converted — Declare the external events consumed by Jedi behavior.
- `jedi_event_registration_and_combat_reset` (callback): not_converted — Reset combat state and register or unregister external event handlers.
- `jedi_plugin_lifecycle` (callback): not_converted — Integrate Jedi event registration, persistence, initialization, and reconnect reset with plugin lifecycle callbacks.
- `jedi_prompt_state_ingestion` (trigger): not_converted — Parse two prompt segments into Jedi resource and combat state.
- `jedi_protocol_state_ingestion` (protocol): not_converted — Parse composite protocol events into resource and opponent state.
- `jedi_resource_status_rendering` (rendering): not_converted — Render Jedi resources, modes, charge, energy, and progress status.
- `jedi_state_model` (state): not_converted — Initialize tracked target, resource, combat, and effect state.
- `jedi_state_persistence` (persistence): not_converted — Save and restore Jedi automation and tracked state.
- `jedi_target_support_automation` (command): not_converted — Track an external target-health event and issue conditional support action.
- `jedi_xml_alias_interface` (alias): not_converted — Expose the XML bridge to the Jedi automation interface.
- `jedi_xml_effect_capture` (trigger): not_converted — Capture Jedi maintained-effect activation and expiration events.
- `jedi_xml_lifecycle` (callback): not_converted — Declare plugin metadata, include shared support, and load Jedi behavior.
- `jedi_xml_status_capture` (trigger): not_converted — Capture two Jedi prompt segments and one target-health event.

### `guild_juggernauts` — not_converted

- Current plugins: None
- Feature statuses: not_converted=26
- `juggernauts_lua_01_initial_state` (state): not_converted — Initialize the legacy Juggernaut display and tracked combat defaults.
- `juggernauts_lua_02_display_state_setup` (rendering): not_converted — Prepare the first bounded group of display state and visual configuration.
- `juggernauts_lua_03_resource_state_setup` (state): not_converted — Prepare the bounded resource and condition state used by the display.
- `juggernauts_lua_04_event_state_setup` (protocol): not_converted — Bind captured event state into the legacy display model.
- `juggernauts_lua_05_layout_foundation` (rendering): not_converted — Construct the foundational bounded portion of the Juggernaut layout.
- `juggernauts_lua_06_combat_indicator_rendering` (rendering): not_converted — Construct the bounded combat-indicator portion of the display.
- `juggernauts_lua_07_window_interaction_state` (rendering): not_converted — Complete interactive window state and related visual behavior.
- `juggernauts_lua_08_condition_rendering` (rendering): not_converted — Render bounded combat-condition and defensive status indicators.
- `juggernauts_lua_09_display_finalization` (rendering): not_converted — Finalize the legacy status display after its component groups are prepared.
- `juggernauts_lua_10_event_refresh_callback` (callback): not_converted — Refresh the display from the first bounded event callback.
- `juggernauts_lua_11_state_refresh_callback` (callback): not_converted — Refresh tracked Juggernaut state from a bounded callback.
- `juggernauts_lua_12_state_transition_callback` (callback): not_converted — Apply a bounded legacy state transition callback.
- `juggernauts_lua_13_defensive_response_callback` (callback): not_converted — Apply a bounded defensive-response callback.
- `juggernauts_lua_14_event_cleanup_callback` (callback): not_converted — Clear transient event state through a bounded callback.
- `juggernauts_lua_15_defensive_reset_callback` (callback): not_converted — Reset bounded defensive state after a captured transition.
- `juggernauts_lua_16_protocol_refresh_callback` (protocol): not_converted — Reconcile protocol-fed state and request a visual refresh.
- `juggernauts_lua_17_persisted_display_state` (persistence): not_converted — Maintain saved display placement and related visual state.
- `juggernauts_lua_18_lifecycle_preparation` (callback): not_converted — Prepare bounded plugin lifecycle and display teardown behavior.
- `juggernauts_lua_19_lifecycle_bootstrap` (callback): not_converted — Bootstrap one bounded phase of the plugin lifecycle.
- `juggernauts_lua_20_lifecycle_integration` (callback): not_converted — Integrate bounded lifecycle callbacks with display state.
- `juggernauts_lua_21_lifecycle_completion` (callback): not_converted — Complete remaining bounded lifecycle, reconnect, and cleanup callbacks.
- `juggernauts_xml_01_lifecycle` (callback): not_converted — Declare plugin metadata, shared support, and the embedded loader.
- `juggernauts_xml_02_status_event_capture` (trigger): not_converted — Capture the first bounded group of legacy status events.
- `juggernauts_xml_03_combat_event_capture` (trigger): not_converted — Capture the next bounded group of legacy combat events.
- `juggernauts_xml_04_defensive_event_capture` (trigger): not_converted — Capture the final bounded group of legacy defensive and display events.
- `juggernauts_xml_05_alias_interface` (alias): not_converted — Expose the bounded XML alias interface for the legacy plugin.

### `guild_knights` — not_converted

- Current plugins: None
- Feature statuses: not_converted=19
- `knights_lua_01_initial_state` (state): not_converted — Initialize legacy Knight display state and shared defaults.
- `knights_lua_02_display_initialization` (rendering): not_converted — Initialize the first bounded portion of the Knight status display.
- `knights_lua_03_layout_foundation` (rendering): not_converted — Construct the bounded foundational layout for the Knight display.
- `knights_lua_04_primary_status_rendering` (rendering): not_converted — Render the primary bounded group of Knight status indicators.
- `knights_lua_05_secondary_status_rendering` (rendering): not_converted — Render the secondary bounded group of Knight status indicators.
- `knights_lua_06_condition_rendering` (rendering): not_converted — Render bounded condition and combat-state indicators.
- `knights_lua_07_interaction_state` (rendering): not_converted — Prepare bounded window interaction and visual state.
- `knights_lua_08_display_finalization` (rendering): not_converted — Finalize the legacy Knight display after its component groups are prepared.
- `knights_lua_09_persisted_display_state` (persistence): not_converted — Maintain saved display placement and related visual state.
- `knights_lua_10_lifecycle_bootstrap` (callback): not_converted — Bootstrap one bounded phase of the plugin lifecycle.
- `knights_lua_11_lifecycle_activation` (callback): not_converted — Activate the legacy display through a bounded lifecycle callback.
- `knights_lua_12_connection_refresh` (callback): not_converted — Refresh legacy display state after a connection transition.
- `knights_lua_13_event_response` (protocol): not_converted — Respond to a bounded legacy inter-plugin event.
- `knights_lua_14_lifecycle_teardown` (callback): not_converted — Tear down bounded display state during plugin closure.
- `knights_lua_15_lifecycle_disable` (callback): not_converted — Disable the legacy display through a bounded lifecycle callback.
- `knights_lua_16_lifecycle_completion` (callback): not_converted — Complete the remaining bounded lifecycle cleanup behavior.
- `knights_xml_01_lifecycle` (callback): not_converted — Declare plugin metadata and the embedded loader.
- `knights_xml_02_event_capture` (trigger): not_converted — Capture the bounded group of legacy Knight events.
- `knights_xml_03_alias_interface` (alias): not_converted — Expose the bounded XML alias interface for the legacy plugin.

### `guild_mage` — not_converted

- Current plugins: None
- Feature statuses: not_converted=16
- `command_automation` (alias): not_converted — Legacy command-alias responsibilities remain unavailable in the current plugin set.
- `plugin_metadata` (protocol): not_converted — Legacy plugin metadata responsibility remains unavailable in the current plugin set.
- `script_container` (callback): not_converted — Legacy script-container responsibilities remain unavailable in the current plugin set.
- `script_responsibility_01` (callback): not_converted — Legacy source-delimited embedded-script responsibility group 01 remains unavailable in the current plugin set.
- `script_responsibility_02` (callback): not_converted — Legacy source-delimited embedded-script responsibility group 02 remains unavailable in the current plugin set.
- `script_responsibility_03` (callback): not_converted — Legacy source-delimited embedded-script responsibility group 03 remains unavailable in the current plugin set.
- `script_responsibility_04` (callback): not_converted — Legacy source-delimited embedded-script responsibility group 04 remains unavailable in the current plugin set.
- `script_responsibility_05` (callback): not_converted — Legacy source-delimited embedded-script responsibility group 05 remains unavailable in the current plugin set.
- `script_responsibility_06` (callback): not_converted — Legacy source-delimited embedded-script responsibility group 06 remains unavailable in the current plugin set.
- `script_responsibility_07` (callback): not_converted — Legacy source-delimited embedded-script responsibility group 07 remains unavailable in the current plugin set.
- `script_responsibility_08` (callback): not_converted — Legacy source-delimited embedded-script responsibility group 08 remains unavailable in the current plugin set.
- `script_responsibility_09` (callback): not_converted — Legacy source-delimited embedded-script responsibility group 09 remains unavailable in the current plugin set.
- `send_automation` (command): not_converted — Legacy send responsibilities remain unavailable in the current plugin set.
- `timer_automation` (timer): not_converted — Legacy timer responsibilities remain unavailable in the current plugin set.
- `trigger_responsibility_01` (trigger): not_converted — Legacy source-delimited trigger responsibility group 01 remains unavailable in the current plugin set.
- `trigger_responsibility_02` (trigger): not_converted — Legacy source-delimited trigger responsibility group 02 remains unavailable in the current plugin set.

### `guild_monks` — not_converted

- Current plugins: None
- Feature statuses: not_converted=16
- `command_automation` (alias): not_converted — Legacy command-alias responsibilities remain unavailable in the current plugin set.
- `include_dependency` (protocol): not_converted — Legacy shared-include dependency remains unavailable in the current plugin set.
- `plugin_metadata` (protocol): not_converted — Legacy plugin metadata responsibility remains unavailable in the current plugin set.
- `script_container` (callback): not_converted — Legacy script-container responsibilities remain unavailable in the current plugin set.
- `script_responsibility_01` (callback): not_converted — Legacy source-delimited embedded-script responsibility group 01 remains unavailable in the current plugin set.
- `script_responsibility_02` (callback): not_converted — Legacy source-delimited embedded-script responsibility group 02 remains unavailable in the current plugin set.
- `script_responsibility_03` (callback): not_converted — Legacy source-delimited embedded-script responsibility group 03 remains unavailable in the current plugin set.
- `script_responsibility_04` (callback): not_converted — Legacy source-delimited embedded-script responsibility group 04 remains unavailable in the current plugin set.
- `script_responsibility_05` (callback): not_converted — Legacy source-delimited embedded-script responsibility group 05 remains unavailable in the current plugin set.
- `script_responsibility_06` (callback): not_converted — Legacy source-delimited embedded-script responsibility group 06 remains unavailable in the current plugin set.
- `send_automation` (command): not_converted — Legacy send responsibilities remain unavailable in the current plugin set.
- `timer_automation` (timer): not_converted — Legacy timer responsibilities remain unavailable in the current plugin set.
- `trigger_responsibility_01` (trigger): not_converted — Legacy source-delimited trigger responsibility group 01 remains unavailable in the current plugin set.
- `trigger_responsibility_02` (trigger): not_converted — Legacy source-delimited trigger responsibility group 02 remains unavailable in the current plugin set.
- `trigger_responsibility_03` (trigger): not_converted — Legacy source-delimited trigger responsibility group 03 remains unavailable in the current plugin set.
- `trigger_responsibility_04` (trigger): not_converted — Legacy source-delimited trigger responsibility group 04 remains unavailable in the current plugin set.

### `guild_necromancers` — not_converted

- Current plugins: None
- Feature statuses: not_converted=33
- `necromancers_lua_01_startup_state` (state): not_converted — Initialize legacy combat, corpse, enemy, and color state.
- `necromancers_lua_02_color_encoding` (rendering): not_converted — Translate legacy color specifications into display values.
- `necromancers_lua_03_combat_color_policy` (rendering): not_converted — Apply the complete combat, death, and enemy color policy.
- `necromancers_lua_04_corpse_status_color_policy` (rendering): not_converted — Apply the complete corpse and status color policy.
- `necromancers_lua_05_state_color_adapters` (rendering): not_converted — Maintain the coherent state- and combat-specific color adapters.
- `necromancers_lua_06_color_availability` (rendering): not_converted — Parse and refresh corpse and status color availability.
- `necromancers_lua_07_combat_color_enablement` (rendering): not_converted — Enable combat-state color presentation helpers.
- `necromancers_lua_08_combat_information` (state): not_converted — Initialize and capture mob, spell, and attack information.
- `necromancers_lua_09_combat_state_update` (state): not_converted — Update the bounded legacy combat-information state.
- `necromancers_lua_10_combat_list_management` (state): not_converted — Maintain legacy combat-information list membership.
- `necromancers_lua_11_state_persistence` (persistence): not_converted — Persist approved legacy plugin state.
- `necromancers_lua_12_state_restoration` (persistence): not_converted — Restore approved legacy state during startup.
- `necromancers_lua_13_close` (state): not_converted — Close legacy plugin-owned state.
- `necromancers_lua_14_enable` (state): not_converted — Enable legacy plugin behavior.
- `necromancers_lua_15_disable` (state): not_converted — Disable and persist legacy plugin behavior.
- `necromancers_lua_16_list_changed` (state): not_converted — Respond to legacy plugin-list changes.
- `necromancers_lua_17_install` (state): not_converted — Initialize legacy plugin installation state.
- `necromancers_lua_18_disconnect` (state): not_converted — Handle legacy connection teardown.
- `necromancers_lua_19_connect` (state): not_converted — Handle legacy connection activation and combat-state binding.
- `necromancers_xml_01_lifecycle` (state): not_converted — Register legacy plugin metadata and embedded lifecycle dispatch.
- `necromancers_xml_02_creature_classification` (trigger): not_converted — Capture the complete creature classification event purpose.
- `necromancers_xml_03_creature_state_reset` (trigger): not_converted — Capture the standalone creature state reset purpose.
- `necromancers_xml_04_darkness_state` (trigger): not_converted — Track the complete darkness state transition purpose.
- `necromancers_xml_05_equipment_loss` (trigger): not_converted — Track equipment loss after a death event.
- `necromancers_xml_06_combat_closure` (trigger): not_converted — Close the complete combat state transition purpose.
- `necromancers_xml_07_effect_state` (trigger): not_converted — Capture the standalone effect state transition purpose.
- `necromancers_xml_08_creature_presence` (trigger): not_converted — Register summoned and enemy creature presence transitions.
- `necromancers_xml_09_creature_absence` (trigger): not_converted — Remove blood- and shadow-related creature presence.
- `necromancers_xml_10_vitality_transitions` (trigger): not_converted — Track coherent vitality, status, and death transitions.
- `necromancers_xml_11_corpse_status` (trigger): not_converted — Capture the complete corpse status reporting purpose.
- `necromancers_xml_12_observation_transitions` (trigger): not_converted — Track the complete observation state transition purpose.
- `necromancers_xml_13_combat_information` (trigger): not_converted — Capture the complete combat information purpose.
- `necromancers_xml_14_alias_interface` (command): not_converted — Expose the bounded legacy alias command interface.

### `guild_priests` — not_converted

- Current plugins: None
- Feature statuses: not_converted=30
- `priests_lua_01_startup_state` (state): not_converted — Initialize legacy priest status, command, event, and rendering state.
- `priests_lua_02_status_color_policy` (rendering): not_converted — Calculate and register legacy status color presentation.
- `priests_lua_03_coffin_status_capture` (state): not_converted — Capture legacy coffin count status.
- `priests_lua_04_vitality_capture` (state): not_converted — Capture legacy health and condition values.
- `priests_lua_05_mana_capture` (state): not_converted — Capture legacy mana status values.
- `priests_lua_06_status_rendering` (rendering): not_converted — Render the complete legacy priest resource and effect status.
- `priests_lua_07_psummon_completion` (callback): not_converted — Record legacy summoning completion state.
- `priests_lua_08_planeshift_completion` (callback): not_converted — Record legacy planeshift completion state.
- `priests_lua_09_recitation_activation` (callback): not_converted — Activate legacy recitation state.
- `priests_lua_10_recitation_deactivation` (callback): not_converted — Deactivate legacy recitation state.
- `priests_lua_11_automatic_interface` (command): not_converted — Dispatch the legacy automatic interface command.
- `priests_lua_12_combat_event_processing` (protocol): not_converted — Process legacy combat information and monster-death events.
- `priests_lua_13_event_subscriptions` (callback): not_converted — Register and unregister legacy event subscriptions.
- `priests_lua_14_state_persistence_restoration` (persistence): not_converted — Persist and restore complete legacy priest state.
- `priests_lua_15_close` (state): not_converted — Close legacy plugin-owned state.
- `priests_lua_16_enable` (state): not_converted — Enable legacy priest event behavior.
- `priests_lua_17_disable` (state): not_converted — Disable and persist legacy priest behavior.
- `priests_lua_18_list_changed` (state): not_converted — Respond to legacy plugin-list changes.
- `priests_lua_19_install` (state): not_converted — Initialize legacy priest installation state.
- `priests_lua_20_disconnect` (state): not_converted — Handle legacy connection teardown.
- `priests_lua_21_connect` (state): not_converted — Handle legacy connection activation.
- `priests_xml_01_lifecycle` (state): not_converted — Register legacy metadata, shared include, and embedded lifecycle dispatch.
- `priests_xml_02_health_status` (trigger): not_converted — Capture the complete health and condition trigger purpose.
- `priests_xml_03_mana_status` (trigger): not_converted — Capture the complete mana resource trigger purpose.
- `priests_xml_04_resource_rendering` (trigger): not_converted — Dispatch complete resource status rendering.
- `priests_xml_05_coffin_status` (trigger): not_converted — Capture the complete coffin count trigger purpose.
- `priests_xml_06_psummon_completion` (trigger): not_converted — Track the complete summoning completion purpose.
- `priests_xml_07_planeshift_completion` (trigger): not_converted — Track the complete planeshift completion purpose.
- `priests_xml_08_recitation_activation` (trigger): not_converted — Track the complete recitation activation purpose.
- `priests_xml_09_recitation_deactivation` (trigger): not_converted — Track the complete recitation deactivation purpose.

### `guild_sii` — not_converted

- Current plugins: None
- Feature statuses: not_converted=30
- `sii_lua_01_dependencies_and_timing` (state): not_converted — Load guild Sii dependencies and provide its elapsed-time formatter.
- `sii_lua_02_combat_state_defaults` (state): not_converted — Initialize guild Sii combat, automation, timing, and ability state defaults.
- `sii_lua_03_status_color_policy` (rendering): not_converted — Choose guild Sii status colors and register the color policy.
- `sii_lua_04_combat_opening_status` (protocol): not_converted — Process guild Sii combat opening state, health change, and fortitude tracking.
- `sii_lua_05_combat_rendering_automation` (protocol): not_converted — Process guild Sii combat rendering, progression, forms, and automation decisions.
- `sii_lua_06_combat_status_reset` (state): not_converted — Reset the guild Sii combat-status sequence.
- `sii_lua_07_ability_state_transitions` (state): not_converted — Track guild Sii analysis, offense, perception, defense, root, amplification, and mesh transitions.
- `sii_lua_08_automatic_interface` (command): not_converted — Parse and dispatch the guild Sii automatic-control interface.
- `sii_lua_09_combat_event_bridge` (protocol): not_converted — Consume guild Sii combat event data and maintain tracked monster state.
- `sii_lua_10_monster_death_summary` (rendering): not_converted — Summarize guild Sii combat timing and progression after monster death.
- `sii_lua_11_event_subscriptions` (callback): not_converted — Register and unregister guild Sii event subscriptions.
- `sii_lua_12_persistence_restore` (persistence): not_converted — Persist and restore guild Sii state.
- `sii_lua_13_lifecycle` (state): not_converted — Handle guild Sii close, enable, disable, install, plugin-list, and connection lifecycle.
- `sii_window_01_metadata` (state): not_converted — Declare the guild Sii status-window plugin metadata.
- `sii_window_02_psi_trail_triggers` (trigger): not_converted — Track psi-trail state for the guild Sii status window.
- `sii_window_03_bubble_triggers` (trigger): not_converted — Track bubble activation and release for the guild Sii status window.
- `sii_window_04_shield_and_form_triggers` (trigger): not_converted — Track shield and form changes for the guild Sii status window.
- `sii_window_05_bubble_aliases` (command): not_converted — Accept bubble count and target input for the guild Sii status window.
- `sii_window_06_bootstrap_install_and_geometry` (rendering): not_converted — Initialize fonts, state, geometry, and drag behavior for the guild Sii status window.
- `sii_window_07_lifecycle` (state): not_converted — Manage the guild Sii status window across plugin lifecycle events.
- `sii_window_08_status_rendering` (rendering): not_converted — Draw the complete guild Sii status-window presentation from guild state.
- `sii_window_09_tick_refresh` (callback): not_converted — Schedule and execute guild Sii status-window refreshes.
- `sii_window_10_bubble_interaction` (command): not_converted — Apply bubble state, count, target, and release interactions for the guild Sii status window.
- `sii_window_11_shield_form_and_trail_callbacks` (callback): not_converted — Apply shield, form, and psi-trail updates to the guild Sii status window.
- `sii_xml_01_metadata` (state): not_converted — Declare the guild Sii plugin metadata.
- `sii_xml_02_combat_status_triggers` (trigger): not_converted — Dispatch the three guild Sii combat-status callbacks.
- `sii_xml_03_active_ability_triggers` (trigger): not_converted — Dispatch guild Sii analysis, malice, perception, and bloodrush state transitions.
- `sii_xml_04_defensive_ability_triggers` (trigger): not_converted — Dispatch guild Sii mitigation, root, amplification, and mesh transitions.
- `sii_xml_05_automatic_interface_alias` (command): not_converted — Expose the guild Sii automatic-control alias.
- `sii_xml_06_embedded_bootstrap` (state): not_converted — Load the owning guild Sii Lua behavior from the approved guild Sii descriptor.

### `guild_viking` — not_converted

- Current plugins: None
- Feature statuses: not_converted=51
- `viking_base_01_dependencies_state_and_core_helpers` (state): not_converted — Initialize guild-Viking dependencies, persistent state, labels, and core helpers.
- `viking_base_02_market_history_and_demand_metrics` (state): not_converted — Track guild-Viking market history, price statistics, trends, and demand cycles.
- `viking_base_03_status_bar_callbacks` (rendering): not_converted — Render guild-Viking health and progress status callbacks.
- `viking_base_04_core_persistence_and_lifecycle` (persistence): not_converted — Persist guild-Viking core state and handle its plugin lifecycle.
- `viking_base_04_mip_event_dispatch` (callback): not_converted — Dispatch guild-Viking event notifications from protocol state.
- `viking_base_04_protocol_ingestion_and_guild_state` (protocol): not_converted — Ingest the complete guild-Viking protocol payload and maintain coupled guild state.
- `viking_base_05_events_timers_and_batch_processing` (callback): not_converted — Handle guild-Viking events, countdowns, and protocol batches.
- `viking_base_05_market_movers_and_trade_rows` (rendering): not_converted — Compute guild-Viking market movers and trade-row presentation data.
- `viking_base_06_automated_voyage_planning` (callback): not_converted — Plan and advance guild-Viking automated voyages.
- `viking_base_07_autotrader_bridge_and_raid_automation` (callback): not_converted — Bridge guild-Viking autotrader context and run automated raids.
- `viking_base_08_window_chrome_tabs_and_lifecycle` (persistence): not_converted — Manage guild-Viking window chrome, tabs, persistence, and lifecycle.
- `viking_base_09_detached_interactions_and_resizing` (callback): not_converted — Handle guild-Viking detached-window interactions and resizing.
- `viking_base_09_detached_trade_rendering` (rendering): not_converted — Render guild-Viking detached trade content and its scrollbar.
- `viking_base_09_detached_update_dispatch` (callback): not_converted — Update and synchronize guild-Viking detached windows.
- `viking_base_10_cityplan_assets_and_resize` (rendering): not_converted — Load guild-Viking city-plan assets and resize its window.
- `viking_base_10_scroll_controls` (callback): not_converted — Handle guild-Viking dashboard scrolling and scrollbars.
- `viking_base_10_terrain_and_building_drawers` (rendering): not_converted — Construct guild-Viking terrain and building drawing helpers.
- `viking_base_10_voyage_assets` (rendering): not_converted — Load guild-Viking voyage visual assets.
- `viking_base_10_window_creation_and_interactions` (rendering): not_converted — Create the guild-Viking window and handle its direct interactions.
- `viking_base_11_dashboard_update_and_shared_rendering` (rendering): not_converted — Update the guild-Viking dashboard and shared presentation helpers.
- `viking_base_12_building_page` (rendering): not_converted — Render the guild-Viking building page.
- `viking_base_12_city_status_page` (rendering): not_converted — Render the guild-Viking city status page.
- `viking_base_12_production_page` (rendering): not_converted — Render the complete guild-Viking production page.
- `viking_base_13_logistics_and_governance_page` (rendering): not_converted — Render guild-Viking logistics, taxation, edicts, and governance data.
- `viking_base_14_trade_dashboard_and_autotrader_controls` (rendering): not_converted — Render guild-Viking trade data and autotrader-specific controls.
- `viking_base_15_page_and_automation_menus` (command): not_converted — Handle guild-Viking page, autotrader, raid, and voyage menus.
- `viking_base_16_map_page_rendering` (rendering): not_converted — Render the guild-Viking map page.
- `viking_base_16_map_pathfinding` (state): not_converted — Find traversable guild-Viking map routes.
- `viking_base_16_missions_and_errands` (command): not_converted — Dispatch guild-Viking missions and errands.
- `viking_base_16_point_of_interest_interactions` (command): not_converted — Operate guild-Viking map point-of-interest interactions.
- `viking_base_17_voyage_views_and_interactions` (rendering): not_converted — Render and operate guild-Viking voyage views.
- `viking_base_18_city_planning_views_and_controls` (command): not_converted — Render and operate guild-Viking city planning.
- `viking_base_19_court_army_and_battle_controls` (command): not_converted — Render guild-Viking court and army views and handle battle controls.
- `viking_base_20_battle_detail` (rendering): not_converted — Render the complete guild-Viking battle detail view.
- `viking_base_20_campaign_map` (rendering): not_converted — Render the guild-Viking campaign map and campaign interactions.
- `viking_base_20_prison_panel` (rendering): not_converted — Render the guild-Viking prison panel.
- `viking_base_20_war_overview` (rendering): not_converted — Render the guild-Viking war overview and its coupled battle tiles.
- `viking_base_21_public_window_controls` (public_api): not_converted — Expose guild-Viking window visibility and minimization controls.
- `viking_trader_01_settings_inventory_and_cart_selection` (state): not_converted — Configure the guild-Viking autotrader and select inventory and carts.
- `viking_trader_02_quality_perishability_and_sale_policy` (state): not_converted — Apply guild-Viking autotrader quality, perishability, and sale policy.
- `viking_trader_03_stock_and_deal_leg_construction` (protocol): not_converted — Build guild-Viking autotrader stock and market-deal route legs.
- `viking_trader_04_route_plan_construction` (protocol): not_converted — Construct a complete guild-Viking autotrader route plan.
- `viking_trader_05_configuration_and_command_interface` (command): not_converted — Configure and command the guild-Viking autotrader.
- `viking_trader_06_transactional_tick_and_status` (callback): not_converted — Execute fail-closed guild-Viking autotrader transactions and report status.
- `viking_xml_01_metadata` (state): not_converted — Declare the guild-Viking plugin metadata.
- `viking_xml_02_status_and_return_triggers` (trigger): not_converted — Dispatch guild-Viking status and return events.
- `viking_xml_03_voyage_and_raid_event_triggers` (trigger): not_converted — Dispatch guild-Viking voyage and raid events.
- `viking_xml_04_war_and_reward_event_triggers` (trigger): not_converted — Dispatch guild-Viking war, capture, loss, and reward events.
- `viking_xml_05_update_timer` (timer): not_converted — Schedule guild-Viking periodic interface updates.
- `viking_xml_06_window_alias` (alias): not_converted — Expose the guild-Viking window command alias.
- `viking_xml_07_embedded_window_controls` (public_api): not_converted — Implement embedded guild-Viking window controls.

### `guild_warders` — not_converted

- Current plugins: None
- Feature statuses: not_converted=21
- `warders_xml_01_metadata` (state): not_converted — Declare the guild Warders plugin metadata.
- `warders_xml_02_daes_timer` (timer): not_converted — Schedule the guild Warders political-game countdown.
- `warders_xml_03_form_aliases` (alias): not_converted — Expose guild Warders form-selection commands.
- `warders_xml_04_personal_ward_alias` (alias): not_converted — Expose the guild Warders personal-ward command.
- `warders_xml_05_automation_alias` (alias): not_converted — Expose the guild Warders automation-control command.
- `warders_xml_06_progression_alias` (alias): not_converted — Expose the guild Warders progression reset command.
- `warders_xml_07_combat_telemetry_triggers` (trigger): not_converted — Dispatch guild Warders combat telemetry observations.
- `warders_xml_08_combat_readiness_triggers` (trigger): not_converted — Dispatch guild Warders combat-readiness transitions.
- `warders_xml_09_protection_alert_triggers` (trigger): not_converted — Dispatch guild Warders protection and equipment alerts.
- `warders_xml_10_daes_guard_progression_triggers` (trigger): not_converted — Dispatch guild Warders political, guard, and progression state.
- `warders_xml_11_consider_analysis_triggers` (trigger): not_converted — Dispatch guild Warders opponent analysis observations.
- `warders_xml_12_bootstrap_state_configuration` (state): not_converted — Initialize guild Warders dependencies, configuration, and state.
- `warders_xml_13_timer_and_dynamic_trigger_callbacks` (callback): not_converted — Implement guild Warders timer and dynamic trigger callbacks.
- `warders_xml_14_command_callbacks` (command): not_converted — Implement guild Warders command callbacks.
- `warders_xml_15_combat_telemetry_automation_callbacks` (protocol): not_converted — Process guild Warders combat telemetry and automation.
- `warders_xml_16_defensive_status_callbacks` (state): not_converted — Maintain guild Warders defensive and status state.
- `warders_xml_17_alert_political_callbacks` (callback): not_converted — Produce guild Warders protection alerts and political-game updates.
- `warders_xml_18_event_bridge_combat_completion` (protocol): not_converted — Bridge guild Warders events and complete combat bookkeeping.
- `warders_xml_19_status_window_rendering` (rendering): not_converted — Implement guild Warders status-window rendering.
- `warders_xml_20_persistence` (persistence): not_converted — Persist and restore guild Warders state.
- `warders_xml_21_lifecycle` (callback): not_converted — Handle guild Warders plugin and connection lifecycle.

### `guild_witches` — not_converted

- Current plugins: None
- Feature statuses: not_converted=30
- `witches_xml_01_metadata` (state): not_converted — Declare the guild Witches plugin metadata.
- `witches_xml_02_combat_recovery_aliases` (alias): not_converted — Expose guild Witches combat-cleanup and recovery commands.
- `witches_xml_03_automation_control_alias` (alias): not_converted — Expose the guild Witches automation-control command.
- `witches_xml_04_herb_management_aliases` (alias): not_converted — Expose guild Witches herb inventory and brewing commands.
- `witches_xml_05_hex_command_alias` (alias): not_converted — Expose the guild Witches targeted-hex command.
- `witches_xml_06_ritual_selection_alias` (alias): not_converted — Expose the guild Witches next-ritual selection command.
- `witches_xml_07_renewal_herb_triggers` (trigger): not_converted — Dispatch guild Witches renewal and herb inventory observations.
- `witches_xml_08_hex_state_triggers` (trigger): not_converted — Dispatch guild Witches hex-state transitions.
- `witches_xml_09_vitals_cycle_triggers` (protocol): not_converted — Parse guild Witches vitals, world cycles, and combat status lines.
- `witches_xml_10_gramarye_progression_triggers` (trigger): not_converted — Dispatch guild Witches gramarye progression observations.
- `witches_xml_11_ritual_state_triggers` (trigger): not_converted — Dispatch guild Witches ritual-state transitions.
- `witches_xml_12_blessing_invoke_triggers` (trigger): not_converted — Dispatch guild Witches blessing and invocation transitions.
- `witches_xml_13_spiritus_proc_trigger` (trigger): not_converted — Dispatch the guild Witches world-spirit proc observation.
- `witches_xml_14_bootstrap_state_configuration` (state): not_converted — Initialize guild Witches dependencies, state, and output helpers.
- `witches_xml_15_automation_configuration_callbacks` (command): not_converted — Configure and control guild Witches automation.
- `witches_xml_16_recovery_inventory_callbacks` (command): not_converted — Manage guild Witches recovery and herb inventory commands.
- `witches_xml_17_hex_targeting_callbacks` (command): not_converted — Implement guild Witches hex parsing and target dispatch.
- `witches_xml_18_ritual_gramarye_command_callbacks` (command): not_converted — Implement guild Witches ritual selection and gramarye display commands.
- `witches_xml_19_ritual_state_callbacks` (state): not_converted — Maintain guild Witches ritual state and active-ritual tracking.
- `witches_xml_20_blessing_invoke_callbacks` (protocol): not_converted — Process guild Witches blessing and invocation automation.
- `witches_xml_21_renewal_herb_spiritus_callbacks` (state): not_converted — Maintain guild Witches renewal, herb inventory, and world-spirit timing state.
- `witches_xml_22_hex_state_callbacks` (state): not_converted — Maintain guild Witches active-hex state and retry behavior.
- `witches_xml_23_gramarye_progression_callbacks` (state): not_converted — Maintain guild Witches gramarye category and progression state.
- `witches_xml_24_vitals_progression_callback` (protocol): not_converted — Parse guild Witches resources and development progression.
- `witches_xml_25_cycle_status_callback` (state): not_converted — Maintain guild Witches world-cycle and blessing-reset state.
- `witches_xml_26_combat_automation_callback` (protocol): not_converted — Drive guild Witches combat, ritual, blessing, and invocation automation.
- `witches_xml_27_event_chat_bridge_callbacks` (callback): not_converted — Bridge guild Witches combat, coffin, and chat events.
- `witches_xml_28_status_window_rendering` (rendering): not_converted — Render guild Witches hex, cycle, and progression status.
- `witches_xml_29_persistence` (persistence): not_converted — Persist and restore guild Witches state.
- `witches_xml_30_lifecycle` (callback): not_converted — Handle guild Witches plugin and connection lifecycle.

### `kill_trigger` — lera_blocker

- Current plugins: `kill_trigger`
- Feature statuses: lera_blocker=1, plugin_gap=22
- `alias_controls` (alias): plugin_gap — Legacy control aliases are not fully reproduced by the current plugin.
- `command_dispatch` (command): plugin_gap — Legacy queued command dispatch is not fully reproduced by the current plugin.
- `command_metadata` (state): plugin_gap — Legacy target-command plugin metadata has no complete current equivalent.
- `counters_and_room_state` (state): plugin_gap — Legacy room-target counters are absent from the current plugin.
- `default_reset` (state): plugin_gap — Legacy reset state includes behavior not retained by the current plugin.
- `external_control_events` (callback): plugin_gap — Legacy external control events are absent from the current plugin.
- `killer_command_queue` (command): plugin_gap — Legacy killer-command queue semantics are not completely equivalent.
- `killer_set_management` (state): plugin_gap — Legacy killer membership and enablement behavior is not completely equivalent.
- `killing_blow_recognition` (trigger): plugin_gap — Legacy killing-blow handling has event and notification behavior missing from the current plugin.
- `killing_blow_registration` (trigger): plugin_gap — Legacy killing-blow registration is not fully semantically equivalent.
- `non_killer_command_queue` (command): plugin_gap — Legacy non-killer command queue semantics are not completely equivalent.
- `output_handling` (timer): lera_blocker — Legacy local sound playback requires a client audio API not exposed to Lua. — [Lera issue #11](https://github.com/lundmark/lera/issues/11)
- `persistence_and_lifecycle` (persistence): plugin_gap — Legacy persistence and lifecycle side effects are not fully reproduced.
- `queue_configuration` (command): plugin_gap — Legacy external queue configuration is absent from the current plugin.
- `status_and_rendering` (rendering): plugin_gap — Legacy status-event publication is not equivalent to current local rendering.
- `target_alias_registration` (alias): plugin_gap — Legacy target-selection aliases are absent from the current plugin.
- `target_attack_execution` (command): plugin_gap — Legacy target attack commands are absent from the current plugin.
- `target_event_bridge` (callback): plugin_gap — Legacy target and room event integration is absent from the current plugin.
- `target_lifecycle` (callback): plugin_gap — Legacy target-command lifecycle integration is absent from the current plugin.
- `target_list_management` (state): plugin_gap — Legacy target-list synchronization is absent from the current plugin.
- `target_state_bootstrap` (state): plugin_gap — Legacy target-command dependencies and state are absent from the current plugin.
- `trigger_metadata` (state): plugin_gap — Legacy kill-trigger metadata has no complete current semantic equivalent.
- `trigger_state_bootstrap` (state): plugin_gap — Legacy kill-trigger bootstrap state is not completely reproduced.

### `mercenary` — plugin_gap

- Current plugins: `mercenary`
- Feature statuses: plugin_gap=16
- `automatic_use_controls` (callback): plugin_gap — Legacy automatic-use control callbacks are not fully reproduced by the current plugin.
- `automatic_use_decisions` (command): plugin_gap — Legacy automatic-use decisions are not fully reproduced by the current plugin.
- `monitor_event_tracking` (callback): plugin_gap — Legacy mercenary monitor event handling is not fully reproduced by the current plugin.
- `monitor_lifecycle` (callback): plugin_gap — Legacy monitor lifecycle behavior has no complete current equivalent.
- `monitor_metadata` (state): plugin_gap — Legacy monitor metadata has no complete current semantic equivalent.
- `monitor_protocol_triggers` (trigger): plugin_gap — Legacy monitor protocol trigger declarations are not completely equivalent.
- `monitor_state_bootstrap` (state): plugin_gap — Legacy monitor bootstrap state is not completely reproduced.
- `persistence_and_lifecycle` (persistence): plugin_gap — Legacy persistence and lifecycle side effects are not fully reproduced.
- `protocol_parsing` (protocol): plugin_gap — Legacy mercenary protocol parsing is not completely equivalent.
- `public_visibility_api` (public_api): plugin_gap — Legacy public window-visibility controls are absent from the current data plugin.
- `rates_and_deltas` (state): plugin_gap — Legacy rate and delta calculations are not completely equivalent.
- `rendering` (rendering): plugin_gap — Legacy interactive stats-window rendering is not reproduced by the current data plugin.
- `stat_counters` (state): plugin_gap — Legacy mercenary counters and accumulated statistics are not completely equivalent.
- `stats_metadata` (state): plugin_gap — Legacy stats metadata has no complete current semantic equivalent.
- `stats_protocol_triggers` (trigger): plugin_gap — Legacy stats protocol trigger declarations are not completely equivalent.
- `stats_state_bootstrap` (state): plugin_gap — Legacy stats bootstrap state is not completely reproduced.

### `minimap` — lera_blocker

- Current plugins: `minimap`
- Feature statuses: lera_blocker=5, plugin_gap=14
- `capture_finalization` (callback): plugin_gap — Legacy map finalization sequencing is not fully reproduced by the current plugin.
- `command_aliases` (alias): plugin_gap — Legacy minimap command aliases are not completely equivalent in the current plugin.
- `display_mode_controls` (command): plugin_gap — Legacy map display-mode controls are not completely equivalent in the current plugin.
- `font_controls` (rendering): lera_blocker — Legacy per-pane font sizing requires a client capability that is not available. — [Lera issue #13](https://github.com/lundmark/lera/issues/13)
- `interactive_resize_controls` (rendering): lera_blocker — Legacy pointer-driven pane resizing requires a client capability that is not available. — [Lera issue #10](https://github.com/lundmark/lera/issues/10)
- `map_line_detection_and_capture` (protocol): plugin_gap — Legacy map-line detection and styled capture are not completely equivalent.
- `metadata` (state): plugin_gap — Legacy minimap metadata has no complete current semantic equivalent.
- `output_omission_controls` (command): plugin_gap — Legacy runtime map-output omission control is not completely equivalent in the current plugin.
- `path_highlighting` (rendering): plugin_gap — Legacy path expansion and styled highlighting are not completely equivalent.
- `persistence_and_lifecycle` (persistence): plugin_gap — Legacy minimap lifecycle and persisted state are not fully reproduced.
- `pointer_display_controls` (command): lera_blocker — Legacy pane pointer and context-menu controls require a client capability that is not available. — [Lera issue #14](https://github.com/lundmark/lera/issues/14)
- `public_window_api` (public_api): lera_blocker — Legacy public window visibility controls require a client capability that is not available. — [Lera issue #9](https://github.com/lundmark/lera/issues/9)
- `rendering` (rendering): plugin_gap — Legacy styled miniwindow rendering is not fully reproduced by the current pane renderer.
- `room_exit_capture` (protocol): plugin_gap — Legacy room and exit capture variants are not completely reproduced.
- `room_status_api` (public_api): plugin_gap — Legacy predictive room-status APIs and events are not reproduced completely.
- `speedwalk_integration` (callback): plugin_gap — Legacy speedwalk event integration is not completely equivalent.
- `state_bootstrap` (state): plugin_gap — Legacy bootstrap state and helper dependencies are not completely reproduced.
- `trigger_registration` (trigger): plugin_gap — Legacy minimap trigger registrations are not completely equivalent.
- `window_layout_controls` (rendering): lera_blocker — Legacy movable independent-window layout behavior requires a client capability that is not available. — [Lera issue #12](https://github.com/lundmark/lera/issues/12)

### `party_interface` — not_converted

- Current plugins: None
- Feature statuses: not_converted=13
- `party_interface_xml_01_metadata` (state): not_converted — Declare the party interface plugin metadata.
- `party_interface_xml_02_command_alias` (alias): not_converted — Expose the party interface configuration command.
- `party_interface_xml_03_message_trigger` (trigger): not_converted — Dispatch party messages into the interface.
- `party_interface_xml_04_bootstrap_state` (state): not_converted — Initialize party interface dependencies and state.
- `party_interface_xml_05_persistence` (persistence): not_converted — Persist party interface state.
- `party_interface_xml_06_window_setup` (rendering): not_converted — Create and initialize the party interface window.
- `party_interface_xml_07_window_geometry` (rendering): not_converted — Manage party interface window geometry and visibility.
- `party_interface_xml_08_member_rendering` (rendering): not_converted — Render party members and configured actions.
- `party_interface_xml_09_menu_interaction` (command): not_converted — Handle party interface menu and pointer interaction.
- `party_interface_xml_10_font_configuration` (persistence): not_converted — Apply persistent party interface font configuration.
- `party_interface_xml_11_lifecycle` (callback): not_converted — Handle party interface plugin lifecycle.
- `party_interface_xml_12_command_configuration` (command): not_converted — Configure party members and their interface commands.
- `party_interface_xml_13_message_dispatch` (protocol): not_converted — Dispatch configured actions from party messages.

### `professions` — not_converted

- Current plugins: None
- Feature statuses: not_converted=20
- `professions_shared_xml_01_metadata` (state): not_converted — Declare shared profession coordination metadata.
- `professions_shared_xml_02_control_command` (alias): not_converted — Expose shared profession controls.
- `professions_shared_xml_03_alert_dispatch` (trigger): not_converted — Dispatch shared profession activity alerts.
- `professions_shared_xml_04_bootstrap` (state): not_converted — Initialize shared profession coordination state.
- `professions_shared_xml_05_activity_alerts` (protocol): not_converted — Track shared profession activity transitions.
- `professions_shared_xml_06_chatline_integration` (protocol): not_converted — Coordinate shared profession chat channels.
- `professions_shared_xml_07_trigger_controls` (command): not_converted — Control shared profession trigger groups.
- `professions_shared_xml_08_enablement_controls` (command): not_converted — Control shared profession availability.
- `professions_shared_xml_09_interface_registration` (protocol): not_converted — Register shared profession interfaces.
- `professions_shared_xml_10_persistence` (persistence): not_converted — Persist shared profession state.
- `professions_shared_xml_11_lifecycle` (callback): not_converted — Handle shared profession plugin lifecycle.
- `reforger_xml_01_metadata` (state): not_converted — Declare reforger profession metadata.
- `reforger_xml_02_feedback_display` (rendering): not_converted — Present reforging process feedback.
- `reforger_xml_03_bootstrap` (state): not_converted — Initialize reforger profession state.
- `reforger_xml_04_quantity_control` (command): not_converted — Track and control reforging quantities.
- `reforger_xml_05_material_control` (command): not_converted — Configure reforging material choices.
- `reforger_xml_06_category_control` (command): not_converted — Configure reforging category choices.
- `transmuter_xml_01_metadata` (state): not_converted — Declare transmuter profession metadata.
- `transmuter_xml_02_feedback_display` (rendering): not_converted — Present transmutation process feedback.
- `transmuter_xml_03_bootstrap` (state): not_converted — Initialize transmuter profession state.

### `push_notify` — plugin_gap

- Current plugins: `push_notify`
- Feature statuses: plugin_gap=12
- `command_configuration` (command): plugin_gap — Legacy push configuration commands are not completely reproduced.
- `configuration_credentials` (state): plugin_gap — Legacy push configuration and credential state are not completely reproduced.
- `connection_notifications` (callback): plugin_gap — Legacy connection notifications and their delivery gates differ from the current disconnect alert.
- `delivery_channels_filters_grace` (callback): plugin_gap — Legacy channel discovery, per-channel filters, and idle grace differ from current matching and rate behavior.
- `event_tracking` (protocol): plugin_gap — Legacy event tracking and external event registration are not completely reproduced.
- `inactivity_alert` (timer): plugin_gap — Legacy no-combat timer notification is absent from the current plugin.
- `lifecycle_events` (callback): plugin_gap — Legacy push lifecycle registration and persistence are not completely reproduced.
- `persistence_migration` (persistence): plugin_gap — Legacy persistence and saved-state migration are not completely reproduced.
- `push_command_alias` (alias): plugin_gap — Legacy push command routing and syntax are not completely reproduced.
- `push_plugin_bootstrap` (state): plugin_gap — Legacy XML bootstrap and auxiliary dependency loading differ from the current module loader.
- `push_plugin_metadata` (state): plugin_gap — Legacy push plugin metadata has no complete current semantic equivalent.
- `wimpy_push_notification` (trigger): plugin_gap — The selected wimpy event notification is absent from the current push plugin.

### `speedwalk_routes` — plugin_gap

- Current plugins: `speedwalk`
- Feature statuses: plugin_gap=19
- `alias_and_movement_commands` (alias): plugin_gap — Legacy movement interception and command routing are not completely reproduced.
- `area_queue_and_saved_queues` (state): plugin_gap — Legacy area and named queue management is not completely reproduced.
- `bootrun_automation` (trigger): plugin_gap — Legacy bootrun recovery automation is absent from the current plugin.
- `command_configuration` (command): plugin_gap — Legacy speedwalker configuration commands are not completely reproduced.
- `event_and_integration_api` (public_api): plugin_gap — Legacy external event and plugin-query integration is not completely reproduced.
- `legacy_alias_route_catalog` (alias): plugin_gap — The approved legacy static alias route catalogue is not reproduced in current configuration.
- `legacy_plugin_metadata` (state): plugin_gap — Legacy speedwalker descriptors and bootstrap contracts differ from the current module.
- `legacy_route_declaration_catalog` (state): plugin_gap — The approved legacy route declaration catalogue is not reproduced in current configuration.
- `legacy_route_trigger_catalog` (trigger): plugin_gap — Legacy static route trigger behavior is not reproduced.
- `legacy_variable_route_catalog` (state): plugin_gap — The approved legacy variable route catalogue is not reproduced in current configuration.
- `output_debug_and_echo` (rendering): plugin_gap — Legacy diagnostic output and client echo control are not completely reproduced.
- `persistence_and_migration` (persistence): plugin_gap — Legacy state migration and persistence are not completely reproduced.
- `place_configuration_and_targets` (state): plugin_gap — Legacy place, target, scaler, and area command configuration differs from the current model.
- `reverse_paths_and_unstep` (command): plugin_gap — Legacy reverse-path, unstep, and return-to-step semantics differ from the current plugin.
- `route_graph_and_path_resolution` (public_api): plugin_gap — Legacy hierarchical path resolution is not completely reproduced.
- `route_recording` (state): plugin_gap — Legacy movement recording and editable step capture are not completely reproduced.
- `speedwalk_train_continuation` (trigger): plugin_gap — The selected train-arrival continuation trigger is absent from the current plugin.
- `step_lists_and_progression` (state): plugin_gap — Legacy step-list progression and completion integration are not completely reproduced.
- `walk_queue_pause_continue` (state): plugin_gap — Legacy queued pause, stop, and continuation semantics are not completely reproduced.

### `status_monitor` — plugin_gap

- Current plugins: `stats_window`
- Feature statuses: plugin_gap=9
- `clock_display_and_configuration` (rendering): plugin_gap — Legacy clock display, update, and configuration behavior is not reproduced.
- `coffin_status_mip` (protocol): plugin_gap — The selected coffin status protocol and display behavior is absent.
- `damage_tracking_and_rendering` (state): plugin_gap — Legacy damage tracking, aggregation, and rendering is not reproduced.
- `experience_tracking_and_rendering` (state): plugin_gap — Legacy experience tracking, rate calculation, and rendering is not completely reproduced.
- `healing_tracking_and_rendering` (state): plugin_gap — Legacy healing tracking and rendering behavior is not reproduced.
- `health_resource_monitoring` (protocol): plugin_gap — Legacy health and resource monitoring is not completely reproduced.
- `status_composition_rendering_and_dependencies` (rendering): plugin_gap — Legacy status composition, rendering, configuration, and dependency behavior is not completely reproduced.
- `timer_tracking_and_rendering` (state): plugin_gap — Legacy timer tracking, commands, and rendering behavior is not reproduced.
- `wizard_damage_tracking` (state): plugin_gap — Legacy wizard damage tracking and output behavior is not reproduced.
