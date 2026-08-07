# Legacy Plugin Parity Validation Design

## Goal

Create a repeatable validation system in `lundmark/lera-plugins` that measures selected Lera plugins against approved legacy MUSHclient sources from the private `lundmark/3scapes` repository.

The system must support strict feature parity, distinguish plugin implementation gaps from missing Lera client capabilities, and maintain a separate list of approved targets that have not yet been converted. It must never publish the names or details of legacy plugins that the user has not explicitly selected for conversion.

## Repository Ownership

The validator, manifest, public reports, documentation, and tests belong in the public `lera-plugins` repository because they describe and validate the reusable plugin collection.

The validator may read these sibling repositories only when explicitly supplied:

- `3s_scripts_old` — private legacy MUSHclient XML plugins and Lua helpers.
- `lera` — the private Lera client repository, including its in-tree plugin mirror and locally built binary.

The validator does not modify either sibling checkout. Missing client capabilities are tracked as issues in the private `lundmark/lera` GitHub repository.

## Scope Is an Explicit Allowlist

The committed manifest is the complete public definition of validation scope. It is not a catalogue of everything present in the private legacy repository.

Only user-approved conversion targets may appear in committed files. A legacy plugin omitted from scope must leave no committed name, path, reason, count, exclusion marker, fingerprint, or other identifying detail.

Adding scope later requires an explicit manifest change. Full local discovery may inspect the private tree to prepare candidate lists for the user, but discovery output remains private until the user approves individual targets.

### Initial Current-Plugin Inventory

The initial manifest includes all 17 current production plugins.

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

Each current plugin is audited locally to identify all approved legacy XML and Lua sources that contribute to its behavior. A current-only plugin remains in the current-plugin inventory without inventing a legacy mapping.

After this baseline, the remaining legacy plugins are presented to the user in manageable categories. Only selected candidates are added to the public allowlist. Selected candidates with no current implementation appear in the `not converted yet` inventory.

## Public and Private Data Boundary

The public repository may contain only information for approved targets:

- approved legacy target name and source path;
- current plugin mapping;
- safe feature keys and aggregate categories;
- public fixture identifiers and current-code references;
- parity status and non-sensitive summary;
- linked private Lera issue URL for a client blocker;
- explicit feature waiver metadata.

The public repository must not contain:

- copied legacy source;
- full private trigger or alias patterns;
- embedded legacy script bodies;
- private repository commit identifiers or source digests;
- detailed local discovery output;
- any identifier or count for an unapproved legacy plugin;
- credentials, stored runtime data, or MUD session data.

Detailed comparison evidence, legacy provenance, and omitted-candidate decisions are local-only.

## Proposed Public Layout

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
│       ├── privacy.py
│       └── issues.py
├── validation/
│   ├── legacy-parity.toml
│   ├── parity-report.md
│   ├── not-converted.md
│   └── README.md
└── tests/
    └── legacy_parity/
        ├── fixtures/
        └── test_*.py
```

The implementation uses Python 3 standard-library modules only. XML parsing uses `xml.etree.ElementTree`; TOML reading uses `tomllib` on supported Python versions. If repository compatibility requires an older Python, the manifest format may use JSON instead, but it must remain human-reviewable and deterministic.

## Private Local State

Private state defaults to:

```text
${XDG_STATE_HOME:-~/.local/state}/lera-plugins/legacy-parity/
├── selection.json
├── provenance.json
└── reports/
```

The directory is created with mode `0700` and files with mode `0600` where the platform supports POSIX permissions. It is outside the repository and must never be copied into public reports.

`selection.json` remembers locally reviewed candidates. Included candidates are also represented publicly after approval. Omitted candidates remain only in this private registry so ordinary discovery does not repeatedly propose them. An explicit `discover --revisit-omitted` action may show them again.

`provenance.json` records the private legacy Git commit, SHA-256 digests of the complete selected source files, local evidence records, and the last full verification time. Hashing whole source files is used only for local drift detection; no private source hash is committed publicly.

## Manifest Model

The public manifest contains current plugins, approved legacy targets, feature records, and Lera capability records.

### Current plugin records

Each current plugin records:

- stable plugin key;
- current Lua path;
- zero or more approved legacy target keys;
- public fixture identifiers;
- optional non-sensitive notes.

Current-only plugins are valid and have no fabricated legacy target.

### Approved legacy target records

Each approved target records:

- stable target key;
- approved legacy XML path and relevant Lua helper paths;
- mapped current plugin key, or no mapping when not converted;
- a non-empty ordered list of reviewed feature records.

An approved target with no mapped current plugin still requires at least one feature record with status `not_converted`. A mapped target with no reviewed features is invalid and can never aggregate to parity.

### Feature records

Each feature has:

- a stable, non-sensitive feature key;
- category: alias, trigger, timer, callback, state, rendering, persistence, protocol, command, or public API;
- status: `parity`, `plugin_gap`, `lera_blocker`, `not_converted`, or `waived`;
- concise public summary;
- zero or more current-code references;
- one evidence record;
- optional capability key for `lera_blocker`;
- waiver approval metadata for `waived`.

An evidence record has:

- type: `public_fixture`, `local_behavior`, or `manual_private_review`;
- public reference when safe, such as a fixture ID;
- review date;
- reviewed scope and result in non-sensitive terms;
- optional opaque local evidence key whose detail exists only in `provenance.json`.

`parity` requires passing evidence. `waived` requires explicit user approval, approval date, and a public rationale. A manual review without the required metadata is invalid.

### Capability records

Each distinct missing Lera capability has:

- stable capability key;
- concise public description;
- exact `https://github.com/lundmark/lera/issues/<number>` URL;
- affected approved feature keys derived by the validator.

Features reference capability keys, allowing multiple blockers per target and multiple targets per capability while preserving one issue per capability.

New blockers are staged only in private local state until issue synchronization completes. The private staged record contains the capability key, approved affected feature keys, and detailed evidence. `sync-issues` resolves or creates the issue first, then writes the complete capability record and affected `lera_blocker` feature records to a temporary public manifest, validates that manifest, and atomically replaces the public manifest. If lookup, creation, validation, or replacement fails, the public manifest remains unchanged. There is no public pending-capability form, and ordinary validation rejects every blocker without a complete capability record and exact issue URL.

### Deterministic target aggregation

Target status is derived rather than independently authored:

1. `not_converted` when there is no mapped current plugin;
2. `lera_blocker` when any feature is `lera_blocker`;
3. `plugin_gap` when any feature is `plugin_gap` or `not_converted`;
4. `parity` when every feature is `parity` or `waived`.

Reports also show feature-status counts so aggregation never hides simultaneous blocker and plugin gaps.

## Status Semantics

- `parity` — current behavior is verified against the approved legacy behavior.
- `plugin_gap` — required behavior can be implemented in a Lera plugin but is missing or incorrect.
- `lera_blocker` — parity requires a missing or incompatible Lera client capability.
- `not_converted` — the approved feature or target has no current implementation.
- `waived` — a feature difference was explicitly accepted by the user.

Whole-plugin opt-outs are represented only by absence from the public allowlist. There is no public excluded status or excluded inventory.

Strict parity succeeds only when every in-scope feature is `parity` or explicitly `waived`, and no approved target is `not_converted`.

## Legacy Extraction

For approved targets only, the full local extractor collects:

- plugin metadata and source identity;
- aliases and callback identities;
- triggers and callback identities;
- timers and callback identities;
- lifecycle and script callbacks;
- Lua includes and helper dependencies;
- saved variables and persistent state;
- MUSHclient API families used;
- miniwindow and rendering responsibilities;
- protocol and event handlers;
- user-visible commands and information displays.

The public manifest stores safe feature keys and categories rather than private patterns or bodies. The complete extraction and its provenance remain in private local state.

## Current Plugin Extraction

The current-side extractor records:

- module identity and lifecycle hooks;
- aliases, triggers, timers, MIP handlers, and plugin dependencies;
- public module functions;
- persistence and configuration behavior;
- renderers and user-visible output;
- relevant Lera APIs used.

Static extraction is evidence, not proof of semantic parity. Every `parity` conclusion must reference a passing public fixture, passing local behavior check, or complete manual private review record.

## Verification Levels and Exit Semantics

The tool exposes two verification levels that cannot be confused in output or reports.

### Public level

```text
tools/legacy-parity validate --level public
```

This level requires only the public repository. It validates manifest schema, allowlist consistency, current plugin inventory, current-code references, public fixtures, generated public reports, and privacy rules.

A passing report is headed `PUBLIC BASELINE VERIFIED — PRIVATE LEGACY SOURCES NOT RECHECKED`. It never claims fresh legacy parity.

### Full-private level

```text
tools/legacy-parity validate --level full-private \
  --legacy-root ../3s_scripts_old \
  --lera-root ../lera
```

This level requires both private roots, private local state, and a built Lera binary. Missing inputs are invocation errors, not skipped checks. It revalidates approved legacy extraction, local provenance, mirror equality, isolated plugin loading, local behavior evidence, public fixtures, reports, and privacy filtering.

A passing report is headed `FULL PRIVATE BASELINE VERIFIED` and includes the verification timestamp only in the private report.

### Strict parity

`--require-parity` is valid only with `--level full-private`. It performs the complete full-private validation and also fails while any in-scope feature is `plugin_gap`, `lera_blocker`, or `not_converted`.

Exit codes:

- `0` — all checks required by the requested level passed;
- `1` — validation findings or strict-parity gaps;
- `2` — invalid invocation, missing required inputs, or malformed state;
- `3` — external GitHub synchronization failure.

Every console summary and report states its verification level. A public-only pass cannot be presented as current private-source parity.

## Refreshing Private Evidence

`--refresh-legacy` is valid only with full-private validation and an explicit private legacy root. It updates `provenance.json` for already approved targets after review. It never discovers or adds new targets automatically and never writes private provenance into the public repository.

## Offline Behavioral Validation

Validation must not connect to the live MUD or use real profile storage.

Current plugins are compiled or loaded through isolated temporary profiles. External APIs, plugin dependencies, timers, storage, and sends are stubbed or redirected to temporary state. Fixtures exercise selected behavior such as:

- representative safe input lines and expected state changes;
- alias inputs and resulting commands;
- timer scheduling and cancellation;
- MIP event parsing;
- persistence round trips;
- rendered information values and status transitions.

Fixtures encode approved behavior without copying private source. When a safe public fixture cannot be written without revealing private content, the feature uses local-only evidence and is not claimed as automatically verified by public CI.

## Reports and Output Safety

Public deterministic outputs are limited to:

- `validation/parity-report.md` — approved targets and aggregate statuses;
- `validation/not-converted.md` — approved targets with no implementation.

They contain no omitted target names, counts, identifiers, or private provenance.

Private reports default to the local state `reports/` directory, never the repository. A user-supplied private report path must resolve outside the repository root. Temporary extraction directories use mode `0700` and are removed on success, failure, or interruption.

`discover` is the only command allowed to display unapproved candidate names. It writes candidates to private `selection.json` and stdout for the explicit selection interaction. Ordinary validation, errors, logs, snapshots, cache keys, and public reports must not reveal omitted names or counts. `discover` stderr reports failures without echoing unapproved source paths unless `--verbose-private` is explicitly supplied.

Privacy tests use synthetic included and omitted candidates to verify filtering across manifest generation, reports, stdout, stderr, exceptions, snapshots, caches, and temporary filenames. A full-private run also scans all proposed public outputs against the actual unapproved local catalogue before allowing public files to be refreshed.

## Lera Feature Requests

A feature is a `lera_blocker` only after confirming that the required behavior cannot be implemented safely through existing public Lera Lua APIs.

Issue synchronization is explicit and hard-coded to the exact repository `lundmark/lera`:

```text
tools/legacy-parity sync-issues
```

Before any mutation, the command uses authenticated GitHub CLI access to verify that `lundmark/lera` exists and is private. It refuses alternate slugs or a public destination.

Every managed issue contains a machine-readable marker:

```text
<!-- legacy-parity-capability: <stable-capability-key> -->
```

For each blocker, synchronization:

1. searches open and closed issues for the exact marker;
2. reuses the single open match;
3. stops for manual review when only a closed match exists;
4. stops without mutation when multiple matches exist;
5. rechecks immediately before creation;
6. creates one issue for the capability, listing only approved affected plugins;
7. rechecks afterward and reports any concurrent duplicate as an error rather than performing destructive cleanup;
8. records the resulting exact issue URL in the public manifest.

The command never creates or reopens issues during ordinary validation or CI.

## Initial Audit and Candidate Selection

The first audit proceeds in two phases:

1. Audit the 17 current plugins, establish approved legacy mappings, define per-feature evidence, and record their actual parity status.
2. Run private `discover`, present remaining candidates to the user in manageable categories, and add only approved candidates to the public manifest.

When the user omits a candidate, its name is stored only in private `selection.json` to suppress future proposals. It is not written to the repository or public output. Selection is intentionally iterative; omitted candidates can be reconsidered only through the explicit revisit action.

## Error Handling

- Missing roots or private state at full-private level return exit `2`; they are never silently skipped.
- Malformed approved XML is a validation failure with details confined to the private report.
- Missing current files, invalid statuses, duplicate keys, unknown mappings, missing evidence, and invalid waiver metadata are fatal.
- Private legacy digest drift is fatal locally until reviewed and refreshed.
- GitHub lookup failure or ambiguous issue matches stop synchronization without creating another issue.
- A plugin load or fixture failure reports the approved plugin and fixture without exposing credentials or private source bodies.
- Privacy-filter failure prevents generation or update of every public output.

## Testing

Tests cover:

- manifest schema and reference integrity;
- deterministic target-status aggregation;
- rejection of empty feature lists for mapped and unmapped approved targets;
- required evidence for `parity` and approval metadata for `waived`;
- multiple features and multiple capability blockers per target;
- allowlist-only extraction;
- private opt-out suppression and explicit revisit;
- public/private verification-level exit semantics and report labels;
- private provenance drift without public hash leakage;
- public report generation and not-converted filtering;
- stdout, stderr, cache, snapshot, and temporary-path privacy;
- isolated plugin syntax/load behavior without network or real storage;
- exact private Lera destination verification;
- private blocker staging, atomic complete-manifest publication, and rollback on synchronization failure;
- issue marker lookup, open reuse, closed/ambiguous refusal, pre-create recheck, and post-create duplicate detection.

## Success Criteria

The initial system is complete when:

- all 17 current plugins appear in the current inventory;
- their approved legacy mappings and feature-level statuses have been reviewed;
- every committed target was explicitly selected;
- omitted target identifiers and counts are absent from every committed file;
- public verification is reproducible with one command and cannot be mistaken for private validation;
- full-private baseline validation is reproducible with one local command;
- strict mode accurately reports all remaining in-scope gaps;
- every `parity` and `waived` feature has mechanically valid evidence metadata;
- every confirmed Lera capability blocker has one deduplicated private Lera issue;
- tests prove allowlist isolation, private decision memory, provenance handling, validation levels, privacy filtering, and safe issue synchronization.
