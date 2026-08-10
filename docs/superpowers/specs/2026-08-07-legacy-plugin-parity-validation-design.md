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

Adding scope later requires an explicit manifest change and renewed user approval. Full local discovery may inspect the private tree to prepare candidate lists for the user, but discovery output remains private until the user approves individual targets.

### Initial Current-Plugin Inventory

The initial proposed scope includes all 17 current production plugins.

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

Each current plugin is audited locally to identify all proposed legacy XML and Lua sources that contribute to its behavior. A current-only plugin remains in the current-plugin inventory without inventing a legacy mapping.

After this baseline discovery, the remaining legacy plugins are presented to the user in manageable categories. Only selected candidates enter the proposed allowlist. Selected candidates with no current implementation appear in the proposed `not converted yet` inventory.

## Allowlist Approval Gate

Discovery and preliminary auditing produce a local-only proposed allowlist. Before any new target name or mapping is committed, the user receives the exact proposal containing:

- every proposed current plugin;
- every proposed approved legacy target name and source mapping;
- whether each source is approved in full or only for named, approved feature groups;
- mapped current plugins, including an explicit empty mapping when absent;
- preliminary aggregate status;
- any already-confirmed Lera capability blocker.

The proposal is not written to a tracked repository path until the user explicitly approves that exact scope. Omitted candidates remain only in private local state and never appear in a commit.

The tool renders the canonical scope and its SHA-256 digest for review. After explicit user go-ahead, an `approve-scope` action writes the exact digest, scope revision, approval time, and canonical scope bytes to trusted private `approval.json`. The action is never inferred from a manifest edit and is never run by CI.

The public manifest later records the matching scope revision, approval date, and digest. The public copy proves internal scope consistency; the private approval record is the authority proving that the exact scope received go-ahead. Full-private publication requires both to match.

Adding or removing a current plugin, changing a current-plugin path, adding or removing a target, changing any selected XML or Lua helper source, changing a source between full and selected coverage, changing the approved feature groups for a selected source, changing its private construct bindings, or changing a target's mapped current plugins invalidates approval and requires another explicit go-ahead. Feature status and evidence changes inside an already approved feature group do not change scope approval.

Approval applies to the exact allowlist, source coverage modes, approved selected-source feature groups, private construct bindings, and current-plugin mappings—not merely to a category or discovery rule. The validator never auto-approves or auto-expands scope.

## Canonical Scope Serialization

Scope digest version 1 is the SHA-256 of UTF-8 JSON encoded with sorted object keys, compact separators `,` and `:`, no insignificant whitespace, and no trailing newline. Arrays use the deterministic order defined below; duplicate keys or paths are invalid rather than deduplicated.

The canonical object contains exactly:

```text
{
  "version": 1,
  "current_plugins": [
    {"key": <plugin-key>, "path": <repo-relative-posix-path>}
  ],
  "legacy_targets": [
    {
      "key": <target-key>,
      "sources": [
        {
          "kind": <xml-or-lua>,
          "path": <repo-relative-posix-path>,
          "coverage": <complete-or-selected>,
          "feature_keys": [<approved-safe-feature-key>...]
        }
      ],
      "current_plugins": [<plugin-key>...]
    }
  ]
}
```

`current_plugins` is sorted by plugin key. `legacy_targets` is sorted by target key. Target mappings are sorted by current-plugin key. Sources are sorted by kind and normalized repository-relative POSIX path. Approved feature keys are sorted bytewise. A `complete` source has an empty `feature_keys` array and places every discovered construct in scope. A `selected` source has a non-empty list of safe approved feature-group keys; the exact private construct-to-group bindings are stored in private selection state and authenticated by private approval. An empty `current_plugins` array means not converted. Every current plugin key/path, selected source, coverage mode, approved selected-source feature group, and target mapping therefore participates in public scope approval.

The public scope digest covers the safe public fields above. The private approval record additionally authenticates the exact private construct bindings for every `selected` source. Full-private validation requires both the public canonical bytes and private selection bindings to match the approved private proposal. The private binding digest is never committed because it could fingerprint unselected legacy behavior.

Feature status, evidence, capabilities, issue URLs, reports, timestamps, and private construct identities are excluded from the public scope digest. Safe approved feature-group keys for selected sources are scope, not status, and are included.

## Public and Private Data Boundary

The public repository may contain only information for approved targets:

- approved legacy target name and source path;
- current plugin mapping;
- safe feature keys and aggregate categories;
- public fixture identifiers and current-code references;
- parity status and non-sensitive summary;
- linked private Lera issue URL for a client blocker;
- explicit feature waiver metadata;
- scope approval revision, date, and public-data digest.

The public repository must not contain:

- copied legacy source;
- full private trigger or alias patterns;
- embedded legacy script bodies;
- private repository commit identifiers or source digests;
- detailed local discovery output;
- any identifier or count for an unapproved legacy plugin;
- credentials, stored runtime data, or MUD session data.

Detailed comparison evidence, legacy provenance, approval authority, and omitted-candidate decisions are local-only.

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
├── approval.json
├── provenance.json
├── staged/
└── reports/
```

The directory is created with mode `0700` and files with mode `0600` where the platform supports POSIX permissions. It is outside the repository and must never be copied into public reports.

`selection.json` remembers locally reviewed candidates. Included candidates are represented publicly only after approval and complete validation. Omitted candidates remain only in this private registry so ordinary discovery does not repeatedly propose them. An explicit `discover --revisit-omitted` action may show them again.

`approval.json` is the trusted local approval authority. It records the user-approved canonical public scope bytes and digest, the exact private selected-source binding digest, revision, and approval time. Recomputing the public digest in a public manifest without a matching private approval record and private bindings cannot publish or pass full-private validation.

`provenance.json` records the private legacy Git commit, SHA-256 digests of the complete selected source files, local evidence records, and the last full verification time. Hashing whole source files is used only for local drift detection; no private source hash is committed publicly.

`staged/` contains private candidate manifests, blocker records, and reports during a complete audit. Nothing in it is public or treated as approved output.

## Manifest Model

The public manifest contains scope approval metadata, current plugins, approved legacy targets, feature records, and Lera capability records.

### Scope approval record

The public scope record contains:

- positive integer revision;
- approval date;
- SHA-256 digest of canonical public scope fields.

The validator checks public internal consistency at public level. Full-private validation and publication additionally require an exact match to trusted private `approval.json`.

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
- approved legacy XML/helper sources and each source's complete/selected coverage mode;
- safe approved feature-group keys for every selected source;
- one or more mapped current plugin keys, or an empty mapping when not converted;
- a non-empty ordered list of reviewed feature records.

An approved target with no mapped current plugins still requires at least one feature record with status `not_converted`. A mapped target with no reviewed features is invalid and can never aggregate to parity.

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

New blockers are staged only in private local state until issue synchronization completes. The private staged record contains the capability key, approved affected feature keys, and detailed evidence. `sync-issues` resolves or creates the issue and records its URL in the staged private audit. It does not publish a partial manifest. Final publication assembles the complete capability and feature records with the rest of the fully audited manifest. If lookup, creation, complete validation, or publication fails, the existing public manifest remains unchanged. There is no public pending-capability form, and ordinary validation rejects every blocker without a complete capability record and exact issue URL.

### Deterministic target aggregation

Target status is derived rather than independently authored:

1. `not_converted` when there are no mapped current plugins;
2. `lera_blocker` when any feature is `lera_blocker`;
3. `plugin_gap` when any feature is `plugin_gap` or `not_converted`;
4. `parity` when every feature is `parity` or `waived`.

Reports also show feature-status counts so aggregation never hides simultaneous blocker and plugin gaps.

## Complete Coverage Requirement

Every allowlisted source is checked across its exact approved scope. Sampling may be used inside a behavioral fixture, but sampling cannot establish feature-inventory completeness or allow a target to claim parity.

For a source with `complete` coverage, the private extractor places every discovered alias, trigger, timer, callback, state responsibility, renderer, protocol handler, command, public API, and relevant Lua helper behavior in scope. Every discovered construct must map to exactly one reviewed feature record, or to an explicitly documented grouping whose evidence covers every grouped construct.

For a source with `selected` coverage, the private selection record binds every in-scope construct to exactly one approved safe feature-group key. Only those bound constructs are parity requirements. Unselected constructs remain private, require no public classification, and may not appear in public reports, counts, or diagnostics. A selected-source feature group cannot claim parity until all privately bound constructs are classified and covered by evidence.

Full-private validation fails when any required construct is unclassified, duplicated across feature records, or covered only by a fixture whose declared scope is narrower than the feature. It also fails when a public feature record has no corresponding approved legacy construct or approved current-only rationale, when a selected construct is bound to an unapproved feature-group key, or when the private selected-source bindings differ from the approved private proposal.

No target may aggregate to `parity` until coverage is 100% and every feature has valid evidence. Public reports show coverage only for approved targets and never reveal omitted-target counts.

## Status Semantics

- `parity` — current behavior is verified against the approved legacy behavior.
- `plugin_gap` — required behavior can be implemented in a Lera plugin but is missing or incorrect.
- `lera_blocker` — parity requires a missing or incompatible Lera client capability.
- `not_converted` — the approved feature or target has no current implementation.
- `waived` — a feature difference was explicitly accepted by the user.

Whole-plugin opt-outs are represented only by absence from the public allowlist. There is no public excluded status or excluded inventory.

Strict parity succeeds only when every in-scope feature is `parity` or explicitly `waived`, no approved target is `not_converted`, and feature-inventory coverage is 100% for every approved target.

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

The public manifest stores safe feature keys and categories rather than private patterns or bodies. Complete-source required sets, selected-source construct bindings, extraction detail, and provenance remain in private local state.

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

This level requires only the public repository. It validates manifest schema, internal scope digest consistency, allowlist consistency, current plugin inventory, current-code references, public fixtures, generated public reports, and privacy rules. It cannot authenticate user approval without private state.

A passing report is headed `PUBLIC BASELINE VERIFIED — PRIVATE APPROVAL AND LEGACY SOURCES NOT RECHECKED`. It never claims fresh approval or legacy parity.

### Full-private level

```text
tools/legacy-parity validate --level full-private \
  --legacy-root ../3s_scripts_old \
  --lera-root ../lera
```

This level requires both private roots, private selection/provenance/approval state, and a built Lera binary. Missing inputs are invocation errors, not skipped checks. It authenticates scope against `approval.json` and revalidates approved legacy extraction, 100% construct coverage, local provenance, mirror equality, isolated plugin loading, local behavior evidence, public fixtures, reports, and privacy filtering.

A passing report is headed `FULL PRIVATE BASELINE VERIFIED` and includes the verification timestamp only in the private report.

### Strict parity

`--require-parity` is valid only with `--level full-private`. It performs the complete full-private validation and also fails while any in-scope feature is `plugin_gap`, `lera_blocker`, or `not_converted`.

Exit codes:

- `0` — all checks required by the requested level passed;
- `1` — validation findings or strict-parity gaps;
- `2` — invalid invocation, missing required inputs, malformed state, or unapproved scope change;
- `3` — external GitHub synchronization failure.

Every console summary and report states its verification level. A public-only pass cannot be presented as current private-source parity or proof of user approval.

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

## Reports and Atomic Publication

Public deterministic outputs are limited to:

- `validation/legacy-parity.toml` — the complete approved manifest;
- `validation/parity-report.md` — approved targets, aggregate statuses, and approved-target coverage;
- `validation/not-converted.md` — approved targets with no implementation.

They contain no omitted target names, counts, identifiers, or private provenance.

Private reports default to the local state `reports/` directory, never the repository. A user-supplied private report path must resolve outside the repository root. Temporary extraction directories use mode `0700` and are removed on success, failure, or interruption.

Initial and updated public outputs are assembled under private `staged/` only after scope approval. Publication is one operation that requires: matching `approval.json`; complete non-empty feature records; 100% construct coverage; complete blocker issue URLs; passing evidence; valid reports; and passing privacy scans. Only then are the manifest and both public reports atomically replaced as a set. Any failure leaves all existing public outputs unchanged; an initial failure publishes nothing.

`discover` is the only command allowed to display unapproved candidate names. It writes candidates to private `selection.json` and stdout for the explicit selection interaction. Ordinary validation, errors, logs, snapshots, cache keys, and public reports must not reveal omitted names or counts. `discover` stderr reports failures without echoing unapproved source paths unless `--verbose-private` is explicitly supplied.

Privacy tests use synthetic included and omitted candidates to verify filtering across manifest generation, reports, stdout, stderr, exceptions, snapshots, caches, and temporary filenames. A full-private run also scans all proposed public outputs against the actual unapproved local catalogue before allowing public files to be published.

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
8. records the resulting exact issue URL in the private staged audit for final publication.

The command never creates or reopens issues during ordinary validation or CI.

## Initial Audit and Candidate Selection

The first audit proceeds in explicit gates:

1. Preliminarily audit the 17 current plugins, establish proposed legacy mappings, and determine preliminary status.
2. Run private `discover`, present remaining candidates to the user in manageable categories, and record include/omit decisions only in private state.
3. Produce the exact local-only proposed allowlist with mappings and preliminary statuses.
4. Obtain explicit user go-ahead for that exact allowlist and run `approve-scope` to record it privately.
5. Perform complete feature extraction, classification, evidence review, and blocker issue synchronization for every approved target in private staged state.
6. Assemble the complete manifest and reports privately, then require matching approval, 100% coverage, evidence, issue, runtime, and privacy validation.
7. Atomically publish the manifest and reports only after every gate succeeds.

When the user omits a candidate, its name is stored only in private `selection.json` to suppress future proposals. It is not written to the repository or public output. Selection is intentionally iterative; omitted candidates can be reconsidered only through the explicit revisit action.

## Error Handling

- Missing roots or private state at full-private level return exit `2`; they are never silently skipped.
- Malformed approved XML is a validation failure with details confined to the private report.
- Missing current files, invalid statuses, duplicate keys, unknown mappings, empty or incomplete feature inventories, missing evidence, and invalid waiver metadata are fatal.
- A scope digest mismatch, missing private approval, or newly added target without renewed approval is fatal and blocks publication.
- Unclassified or multiply classified approved legacy constructs are fatal.
- Private legacy digest drift is fatal locally until reviewed and refreshed.
- GitHub lookup failure or ambiguous issue matches stop synchronization without creating another issue.
- A plugin load or fixture failure reports the approved plugin and fixture without exposing credentials or private source bodies.
- Privacy-filter failure prevents generation or update of every public output.

## Testing

Tests cover:

- manifest schema and reference integrity;
- exact canonical scope serialization for current keys/paths, target keys, every source/coverage mode, selected-source feature key, and zero-or-more current mappings;
- private approval recording and rejection of a recomputed public digest without matching trusted approval;
- approval invalidation on every scope-changing field and proof that status/evidence-only changes do not invalidate scope;
- deterministic target-status aggregation;
- rejection of empty feature lists for mapped and unmapped approved targets;
- 100% extracted-construct classification, grouping coverage, and duplicate/unclassified rejection;
- required evidence for `parity` and approval metadata for `waived`;
- multiple features and multiple capability blockers per target;
- allowlist-only extraction;
- private opt-out suppression and explicit revisit;
- public/private verification-level exit semantics and report labels;
- private provenance drift without public hash leakage;
- complete atomic publication and rollback for initial and existing public outputs;
- public report generation and not-converted filtering;
- stdout, stderr, cache, snapshot, and temporary-path privacy;
- isolated plugin syntax/load behavior without network or real storage;
- exact private Lera destination verification;
- private blocker staging and issue marker lookup, open reuse, closed/ambiguous refusal, pre-create recheck, and post-create duplicate detection.

## Success Criteria

The initial system is complete when:

- the exact proposed allowlist has received explicit user go-ahead recorded in trusted private state;
- its canonical scope digest matches both private approval and the committed manifest;
- all 17 current plugins appear in the current inventory;
- every committed legacy target was explicitly selected;
- every approved target has 100% construct classification and feature-level evidence review before publication;
- their approved legacy mappings and actual feature-level statuses are recorded;
- omitted target identifiers and counts are absent from every committed file;
- public verification is reproducible with one command and cannot be mistaken for private validation or proof of approval;
- full-private baseline validation is reproducible with one local command;
- strict mode accurately reports all remaining in-scope gaps;
- every `parity` and `waived` feature has mechanically valid evidence metadata;
- every confirmed Lera capability blocker has one deduplicated private Lera issue;
- tests prove allowlist approval, canonical scope coverage, complete audit coverage, atomic publication, privacy, provenance, validation levels, and safe issue synchronization.
