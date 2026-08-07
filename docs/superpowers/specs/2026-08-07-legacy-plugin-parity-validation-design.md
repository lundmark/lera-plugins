# Legacy Plugin Parity Validation Design

## Goal

Create a repeatable validation system in `lundmark/lera-plugins` that measures selected Lera plugins against approved legacy MUSHclient sources from the private `lundmark/3scapes` repository.

The system must support strict feature parity, distinguish plugin implementation gaps from missing Lera client capabilities, and maintain a separate list of approved targets that have not yet been converted. It must never publish the names or details of legacy plugins that the user has not explicitly selected for conversion.

## Repository Ownership

The validator, manifest, documentation, and tests belong in the public `lera-plugins` repository because they describe and validate the reusable plugin collection.

The validator may read these sibling repositories when explicitly supplied:

- `3s_scripts_old` — private legacy MUSHclient XML plugins and Lua helpers.
- `lera` — the private Lera client repository, including its in-tree plugin mirror and locally built binary.

The validator does not modify either sibling repository. Missing client capabilities are tracked as issues in the private `lundmark/lera` GitHub repository.

## Scope Is an Explicit Allowlist

The committed manifest is the complete public definition of validation scope. It is not a catalogue of everything present in the private legacy repository.

Only user-approved conversion targets may appear in committed files. A legacy plugin that is omitted from scope must leave no committed name, path, reason, count, exclusion marker, or other identifying detail.

Adding scope later requires an explicit manifest change. Full local discovery may inspect the private tree to prepare candidate lists for the user, but discovery output remains local until the user approves individual targets.

### Initial Current-Plugin Inventory

The initial manifest includes all 17 current production plugins:

Generic:

- `autologin`
- `deadmans`
- `help`
- `input_echo`
- `push_notify`

3scapes:

- `autostepper`
- `chat_monitor`
- `guild_druid`
- `kill_trigger`
- `mapper`
- `mapview`
- `mercenary`
- `minimap`
- `player_stats`
- `roominfo`
- `speedwalk`
- `stats_window`

Each current plugin is audited locally to identify all legacy XML and Lua sources that contribute to its behavior. A current-only plugin remains in the current-plugin inventory without inventing a legacy mapping.

After this baseline, the remaining legacy plugins are presented to the user in manageable categories. Only selected candidates are added to the public allowlist. Selected candidates with no current implementation appear in the `not converted yet` inventory.

## Public and Private Data Boundary

The public repository may contain only information for approved targets:

- approved legacy target name and source path;
- current plugin mapping;
- aggregate feature categories and status;
- non-reversible evidence hashes;
- public test and fixture identifiers;
- linked Lera issue URLs;
- concise, non-sensitive rationales.

The public repository must not contain:

- copied legacy source;
- full private trigger or alias patterns;
- embedded legacy script bodies;
- detailed local discovery output;
- any identifier for an unapproved or omitted legacy plugin;
- credentials, stored runtime data, or MUD session data.

Detailed comparison evidence is generated locally and is not committed by default.

## Proposed Layout

```text
lera-plugins/
├── tools/
│   ├── legacy-parity
│   └── legacy_parity/
│       ├── __init__.py
│       ├── cli.py
│       ├── manifest.py
│       ├── legacy.py
│       ├── current.py
│       ├── compare.py
│       ├── report.py
│       └── issues.py
├── validation/
│   ├── legacy-parity.toml
│   └── README.md
└── tests/
    └── legacy_parity/
        ├── fixtures/
        └── test_*.py
```

The implementation uses Python 3 standard-library modules only. XML parsing uses `xml.etree.ElementTree`; TOML reading uses `tomllib` on supported Python versions. If repository compatibility requires an older Python, the manifest format may use JSON instead, but it must remain human-reviewable and deterministic.

## Manifest Model

The manifest contains two explicit inventories.

### Current plugins

Each current plugin entry records:

- stable plugin name;
- current Lua path;
- zero or more approved legacy targets;
- current-source evidence hash;
- fixture identifiers;
- optional notes that contain no private source details.

### Approved legacy targets

Each approved target records:

- stable target key;
- approved legacy XML path and relevant Lua helper paths;
- mapped current plugin, or `not_converted` when no implementation exists;
- aggregate feature categories;
- parity status;
- local evidence hash;
- linked Lera issue for client blockers;
- explicitly approved feature waiver, when applicable.

The manifest never stores unapproved discovery results.

## Status Model

In-scope features use these statuses:

- `parity` — current behavior is verified against the approved legacy behavior.
- `plugin_gap` — required behavior can be implemented in a Lera plugin but is missing or incorrect.
- `lera_blocker` — parity requires a missing or incompatible Lera client capability.
- `not_converted` — the approved target has no current implementation.
- `waived` — a feature difference was explicitly accepted by the user.

Whole-plugin opt-outs are represented only by absence from the allowlist. There is no excluded status or excluded inventory.

Strict parity succeeds only when every in-scope feature is `parity` or explicitly `waived`, and no approved target is `not_converted`.

## Legacy Extraction

For approved targets only, the local extractor collects:

- plugin metadata and source identity;
- aliases and their callback identities;
- triggers and their callback identities;
- timers and their callback identities;
- lifecycle and script callbacks;
- Lua includes and helper dependencies;
- saved variables and persistent state;
- MUSHclient API families used;
- miniwindow and rendering responsibilities;
- protocol and event handlers;
- user-visible commands and information displays.

The committed evidence stores aggregate categories and hashes rather than private patterns or bodies. A full local report may contain details but is written outside committed paths by default.

## Current Plugin Extraction

The current-side extractor records:

- module identity and lifecycle hooks;
- aliases, triggers, timers, MIP handlers, and plugin dependencies;
- public module functions;
- persistence and configuration behavior;
- renderers and user-visible output;
- relevant Lera APIs used.

Static extraction is evidence, not proof of semantic parity. Every `parity` conclusion must also reference either a behavioral fixture or a documented manual comparison.

## Validation Modes

### Baseline validation

The normal command validates the approved baseline and fails when:

- a committed current plugin disappears or changes without refreshed evidence;
- an approved mapping is malformed;
- a selected legacy source changes during a full local run without refreshed evidence;
- a fixture fails;
- an in-tree Lera plugin mirror differs when a Lera checkout is supplied;
- a `lera_blocker` lacks a linked Lera issue;
- generated public summaries are stale;
- committed data violates the privacy boundary.

Known, explicitly recorded gaps remain visible but do not make baseline CI permanently unusable.

### Strict validation

`--require-parity` performs baseline validation and also fails while any in-scope feature is `plugin_gap`, `lera_blocker`, or `not_converted`.

### Refreshing legacy evidence

`--refresh-legacy` requires an explicit private legacy root. It updates evidence only for already approved targets and records the legacy Git commit. It never discovers or adds new targets automatically.

## Local and CI Operation

A full local run accepts explicit paths, for example:

```text
tools/legacy-parity validate \
  --legacy-root ../3s_scripts_old \
  --lera-root ../lera
```

The local run can parse approved private sources, compare the Lera mirror, use a locally built Lera binary, and generate a detailed uncommitted report.

Public CI does not receive automatic access to the private legacy or Lera repositories. It validates the manifest schema, current plugin inventory, current evidence, unit tests, public fixtures, and committed summaries. Full private-source validation remains a local command unless a cross-repository credential is configured later.

## Offline Behavioral Validation

Validation must not connect to the live MUD or use real profile storage.

Current plugins are compiled or loaded through isolated temporary profiles. External APIs, plugin dependencies, timers, storage, and sends are stubbed or redirected to temporary state. Fixtures exercise selected behavior such as:

- representative legacy input lines and expected state changes;
- alias inputs and resulting commands;
- timer scheduling and cancellation;
- MIP event parsing;
- persistence round trips;
- rendered information values and status transitions.

Fixtures encode expected behavior derived from approved legacy targets without copying full private source into the public repository. When a safe public fixture cannot be written without revealing private content, the feature uses a local-only evidence check and is not claimed as automatically verified in CI.

## Reports

The validator produces two public views containing approved targets only:

1. Parity report — each approved mapping and its aggregate current status.
2. Not converted yet — approved targets whose status is `not_converted`.

A third detailed report is local-only. It may show feature-level evidence and private source references and must default to a path outside the repository or an ignored directory.

No report mentions omitted targets.

## Lera Feature Requests

A feature is a `lera_blocker` only after confirming that the required behavior cannot be implemented safely through existing public Lera Lua APIs.

Issue synchronization is explicit, never part of ordinary CI:

```text
tools/legacy-parity sync-issues --lera-repo lundmark/lera
```

For each blocker, the command:

1. searches open and closed Lera issues for the stable capability key;
2. reuses an existing matching issue when present;
3. otherwise creates one issue for the missing capability, not one issue per affected plugin;
4. lists all approved affected plugins and the parity requirement;
5. records the resulting issue URL in the manifest.

The command requires authenticated GitHub CLI access and performs no writes without the explicit `sync-issues` action.

## Initial Audit and Candidate Selection

The first audit proceeds in two phases:

1. Audit the 17 current plugins, establish verified legacy mappings, and record their actual parity status.
2. Build a local-only catalogue of the remaining legacy plugins and present it to the user in categories. Add only approved candidates to the manifest; discard all omitted candidate data without committing it.

Selection is intentionally iterative. A later run may propose additional private candidates, but the validator never expands public scope on its own.

## Error Handling

- Missing private roots produce a clear explanation of which checks were skipped.
- Malformed approved XML is a validation failure with its selected path identified.
- Missing current files, invalid statuses, duplicate keys, or mappings to unknown entries are fatal.
- Legacy hash drift is fatal until reviewed and refreshed.
- GitHub lookup failure does not create duplicate issues; issue synchronization stops safely.
- A plugin load or fixture failure reports the plugin and fixture without exposing credentials or private source bodies.

## Success Criteria

The initial system is complete when:

- all 17 current plugins appear in the current inventory;
- their approved legacy mappings and actual statuses have been reviewed;
- every committed target was explicitly selected;
- baseline validation is reproducible with one local command;
- strict mode accurately reports all remaining in-scope gaps;
- the public reports contain no omitted target identifiers or private source bodies;
- every confirmed Lera capability blocker has a deduplicated private Lera issue;
- tests prove manifest validation, allowlist isolation, privacy filtering, drift detection, reporting, and issue-deduplication behavior.
