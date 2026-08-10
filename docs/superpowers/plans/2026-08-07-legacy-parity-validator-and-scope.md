# Legacy Parity Validator and Scope Proposal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the repeatable, privacy-preserving legacy parity validator and use it to produce an exact private allowlist proposal covering all 17 current plugins plus the user's selected not-yet-converted targets.

**Architecture:** A Python 3.12 standard-library CLI in `lundmark/lera-plugins` owns deterministic scope serialization, private approval/state, legacy/current source inventories, complete-coverage ledgers, validation, safe GitHub issue synchronization, isolated Lera runtime checks, report generation, and transactional publication. All unapproved discovery data stays under the user's private state directory; public validation can run without the private repositories. This is plan 1 of 2: it ends at the required exact-scope approval checkpoint, after which a second plan will enumerate and fully audit every approved target before publication.

**Tech Stack:** Python 3.12 standard library (`argparse`, `dataclasses`, `hashlib`, `json`, `os`, `pathlib`, `re`, `shutil`, `stat`, `subprocess`, `tempfile`, `tomllib`, `unittest`, `xml.etree.ElementTree`), Lera Lua runtime, GitHub CLI, GitHub Actions.

---

## Scope and safety boundaries

Design specification: `docs/superpowers/specs/2026-08-07-legacy-plugin-parity-validation-design.md`

This plan produces working validator software and a private, exact scope proposal. It deliberately does **not** publish a real manifest/report, create real GitHub issues, or claim parity. The user approved the semantic allowlist on 2026-08-10, but formal authentication still requires review of the generated canonical scope plus its public and private-binding digests. After that exact digest approval, write plan 2 with one full audit task per approved target and explicit publication checks.

During all development and preliminary auditing:

- Never copy private legacy source, patterns, bodies, hashes, commit IDs, omitted names, omitted counts, or omission reasons into tracked files, fixtures, commits, test output, or logs.
- Use invented synthetic names and behavior in public fixtures.
- Never run the user's live profile, connect to the MUD, or access the user's real `.storage/`.
- Treat `/home/simon/code/lera-plugins` as the only repository to modify.
- Treat `/home/simon/code/3s_scripts_old` and `/home/simon/code/lera` as read-only inputs.
- Preserve unrelated work in all repositories.
- Do not run `sync-issues` without `--dry-run` during this plan.
- Do not run `publish` against real private state during this plan.

## Standard commands

Run all unit tests:

```bash
mise exec python@3.12 -- python -m unittest discover -s tests/legacy_parity -p 'test_*.py' -v
```

Run Python syntax checks:

```bash
mise exec python@3.12 -- python -m compileall -q tools/legacy_parity tests/legacy_parity
```

Run the public verification level:

```bash
mise exec python@3.12 -- tools/legacy-parity validate --level public
```

The CLI exit contract is fixed:

- `0`: validation/synchronization succeeded;
- `1`: reviewed findings, gaps, or non-parity remain;
- `2`: invalid input, missing prerequisite, malformed state, or unapproved scope;
- `3`: GitHub issue synchronization failed or found an ambiguous issue state.

## File structure

- Create `.tool-versions`: pin Python `3.12.7` for local `mise` execution.
- Create `.github/workflows/legacy-parity.yml`: run only public validation and public tests in CI.
- Create `tools/legacy-parity`: executable CLI wrapper.
- Create `tools/legacy_parity/__init__.py`: package version and exit-code constants.
- Create `tools/legacy_parity/cli.py`: argument parsing, sanitized error handling, and command orchestration.
- Create `tools/legacy_parity/model.py`: immutable domain records and enum/value validation.
- Create `tools/legacy_parity/manifest.py`: deterministic TOML parsing/emission and semantic manifest validation.
- Create `tools/legacy_parity/scope.py`: normalized canonical-scope JSON and SHA-256 approval digest.
- Create `tools/legacy_parity/state.py`: private state layout, permissions, atomic JSON writes, selection, approval, provenance, and staged audit records.
- Create `tools/legacy_parity/legacy.py`: private XML/helper inventory and stable construct extraction.
- Create `tools/legacy_parity/current.py`: public plugin inventory, current-code reference validation, and Lera mirror comparison.
- Create `tools/legacy_parity/audit.py`: private preliminary-audit records, current-behavior extraction, target mappings, and completion gates.
- Create `tools/legacy_parity/coverage.py`: exact-once construct/source-line coverage ledger.
- Create `tools/legacy_parity/compare.py`: feature/evidence/status rules and aggregate findings.
- Create `tools/legacy_parity/staged.py`: versioned private complete-audit bundle and cross-record integrity validation.
- Create `tools/legacy_parity/privacy.py`: public-artifact leakage checks and sanitized diagnostics.
- Create `tools/legacy_parity/report.py`: deterministic parity and not-converted Markdown rendering.
- Create `tools/legacy_parity/publish.py`: exception-safe staged public-output transaction.
- Create `tools/legacy_parity/issues.py`: hard-coded, deduplicating `lundmark/lera` GitHub issue synchronization.
- Create `tools/legacy_parity/runtime.py`: isolated temporary-profile Lera behavior runner.
- Create `validation/README.md`: explain public/full-private validation and the allowlist boundary without naming unapproved targets.
- Create `tests/legacy_parity/fixtures/`: synthetic XML, Lua, manifests, current plugins, Lera mirrors, and expected reports.
- Create focused `tests/legacy_parity/test_*.py` modules matching each production module.

No real `validation/legacy-parity.toml`, `validation/parity-report.md`, or `validation/not-converted.md` is added in this plan. The first real output set is created only by plan 2 after approval and complete audit.

### Task 1: Python toolchain, package, and executable skeleton

**Files:**
- Create: `.tool-versions`
- Create: `tools/legacy-parity`
- Create: `tools/legacy_parity/__init__.py`
- Create: `tools/legacy_parity/cli.py`
- Create: `tests/legacy_parity/__init__.py`
- Create: `tests/legacy_parity/test_cli.py`

- [ ] **Step 1: Write the failing CLI smoke tests**

```python
# tests/legacy_parity/test_cli.py
import subprocess
import unittest
from pathlib import Path

from tools.legacy_parity.cli import main


class CliSmokeTests(unittest.TestCase):
    def test_no_command_is_usage_error(self):
        self.assertEqual(main([]), 2)

    def test_wrapper_prints_help(self):
        repo = Path(__file__).resolve().parents[2]
        result = subprocess.run(
            [str(repo / "tools" / "legacy-parity"), "--help"],
            cwd=repo,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("legacy parity", result.stdout.lower())
```

- [ ] **Step 2: Run the smoke tests and verify the import/wrapper failure**

Run:

```bash
mise exec python@3.12 -- python -m unittest tests.legacy_parity.test_cli -v
```

Expected: FAIL or ERROR because the package and wrapper do not exist.

- [ ] **Step 3: Add the pin, package constants, wrapper, and minimal parser**

```text
# .tool-versions
python 3.12.7
```

```python
# tools/legacy_parity/__init__.py
VERSION = "0.1.0"
EXIT_OK = 0
EXIT_FINDINGS = 1
EXIT_INVALID = 2
EXIT_GITHUB = 3
```

```python
# tools/legacy_parity/cli.py
import argparse

from . import EXIT_INVALID, EXIT_OK


def build_parser():
    parser = argparse.ArgumentParser(description="Validate approved legacy plugin parity")
    parser.add_subparsers(dest="command")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    return EXIT_OK if args.command else EXIT_INVALID
```

```python
#!/usr/bin/env python3
# tools/legacy-parity
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.legacy_parity.cli import main

raise SystemExit(main(sys.argv[1:]))
```

- [ ] **Step 4: Make the wrapper executable and rerun the smoke tests**

Run:

```bash
chmod +x tools/legacy-parity
mise exec python@3.12 -- python -m unittest tests.legacy_parity.test_cli -v
```

Expected: both tests PASS.

- [ ] **Step 5: Commit the skeleton**

```bash
git add .tool-versions tools/legacy-parity tools/legacy_parity tests/legacy_parity
git commit -m "feat: add legacy parity validator skeleton"
```

### Task 2: Domain model and deterministic public manifest

**Files:**
- Create: `tools/legacy_parity/model.py`
- Create: `tools/legacy_parity/manifest.py`
- Create: `tests/legacy_parity/test_manifest.py`
- Create: `tests/legacy_parity/fixtures/public/valid-manifest.toml`

- [ ] **Step 1: Write failing model and manifest round-trip tests**

The synthetic fixture uses only invented target names. Assert that:

```python
manifest = load_manifest(FIXTURES / "public" / "valid-manifest.toml")
self.assertEqual(manifest.scope.revision, 1)
self.assertEqual(manifest.current_plugins[0].key, "sample_current")
self.assertEqual(manifest.legacy_targets[0].features[0].status, "parity")
self.assertEqual(render_manifest(manifest), fixture_text)
```

Also assert rejection of unknown feature categories/statuses, empty feature lists, duplicate keys, a mapped target incorrectly aggregated as `not_converted`, an unmapped target without at least one `not_converted` feature, a blocker without a capability, a waiver without approval metadata, and capability URLs outside `https://github.com/lundmark/lera/issues/<number>`. A mapped target may contain individual `not_converted` features; deterministic aggregation reports it as `plugin_gap`. Every evidence record must have a valid ISO review date, non-empty safe reviewed-scope and result summaries, and outcome `pass` or `fail`; `parity` requires `pass`. A `public_fixture` requires a public fixture reference. `local_behavior` and `manual_private_review` require an opaque local evidence key whose existence is checked at full-private level.

- [ ] **Step 2: Run the focused tests and verify the missing-module failure**

Run:

```bash
mise exec python@3.12 -- python -m unittest tests.legacy_parity.test_manifest -v
```

Expected: ERROR because `model` and `manifest` do not exist.

- [ ] **Step 3: Implement immutable records and strict value sets**

Use frozen dataclasses for `ScopeApproval`, `Evidence`, `Feature`, `CurrentPlugin`, `LegacyTarget`, `Capability`, and `Manifest`. Export these exact allowed values:

```python
CATEGORIES = frozenset({
    "alias", "trigger", "timer", "callback", "state", "rendering",
    "persistence", "protocol", "command", "public_api",
})
STATUSES = frozenset({
    "parity", "plugin_gap", "lera_blocker", "not_converted", "waived",
})
EVIDENCE_TYPES = frozenset({
    "public_fixture", "local_behavior", "manual_private_review",
})
```

`validate_manifest()` returns a tuple of non-sensitive diagnostic codes rather than interpolating source paths or target names into errors.

- [ ] **Step 4: Implement deterministic TOML load/render**

Parse with `tomllib`. Render the fixed schema in this order: scope, sorted current plugins, sorted targets with ordered features, sorted capabilities. Escape TOML strings explicitly; do not use a third-party writer. End the file with one newline. A parse/render/parse round trip must preserve the dataclass value exactly.

- [ ] **Step 5: Run manifest tests and the full suite**

Run:

```bash
mise exec python@3.12 -- python -m unittest tests.legacy_parity.test_manifest -v
mise exec python@3.12 -- python -m unittest discover -s tests/legacy_parity -p 'test_*.py' -v
```

Expected: PASS.

- [ ] **Step 6: Commit the manifest model**

```bash
git add tools/legacy_parity/model.py tools/legacy_parity/manifest.py tests/legacy_parity/test_manifest.py tests/legacy_parity/fixtures/public/valid-manifest.toml
git commit -m "feat: model legacy parity manifests"
```

### Task 3: Canonical scope serialization and authenticated approval

**Files:**
- Create: `tools/legacy_parity/scope.py`
- Create: `tools/legacy_parity/state.py`
- Create: `tests/legacy_parity/test_scope.py`
- Create: `tests/legacy_parity/test_state.py`

- [ ] **Step 1: Write failing canonicalization vectors**

Construct two equivalent synthetic scopes with shuffled input order and assert identical bytes/digest. Assert the exact byte form:

```python
expected = (
    b'{"current_plugins":[{"key":"sample_current","path":"generic/sample.lua"}],'
    b'"legacy_targets":[{"current_plugins":["sample_current"],"key":"sample_legacy",'
    b'"sources":[{"coverage":"complete","feature_keys":[],"kind":"lua","path":"lua/sample.lua"},{"coverage":"selected","feature_keys":["sample_behavior"],"kind":"xml","path":"plugins/sample.xml"}]}],'
    b'"version":1}'
)
self.assertEqual(canonical_scope(scope), expected)
self.assertEqual(scope_digest(scope), hashlib.sha256(expected).hexdigest())
```

Reject absolute paths, backslashes, empty segments, `.`/`..`, duplicate keys/paths, unknown current mappings, non-UTF-8-surrogate strings, and any scope version other than 1.

- [ ] **Step 2: Write failing approval-authority tests**

With `XDG_STATE_HOME` pointed at a temporary directory, assert:

- state directory mode is `0700` and JSON files are `0600` on POSIX;
- `approve_scope()` records revision, approval date/time, public digest, exact canonical public UTF-8 JSON, private binding digest, and exact canonical private bindings;
- a changed plugin path, target source/coverage mode, selected-source feature key, mapping, target set, or current plugin set invalidates the public digest;
- a changed selected-source construct binding invalidates the private binding digest;
- feature status/evidence changes inside approved feature groups do not affect either digest;
- a digest copied only into a public manifest never authenticates approval;
- malformed or permission-unsafe approval state fails closed.

Add version-1 `ProvenanceState` tests covering: exact approved scope digest/revision; private legacy repository commit; one whole-source SHA-256 for every and only approved XML/helper path; opaque local evidence records keyed by ID with target, feature, evidence type, review date, declared construct scope, pass/fail outcome, and non-sensitive result; and last refresh time. Assert strict parsing, mode `0600`, atomic create/update/rollback, and rejection of extra/missing source paths or evidence references. A staged bundle's provenance snapshot/digest must exactly match separate `provenance.json` during ordinary full-private validation.

- [ ] **Step 3: Run the focused tests and verify failure**

Run:

```bash
mise exec python@3.12 -- python -m unittest tests.legacy_parity.test_scope tests.legacy_parity.test_state -v
```

Expected: ERROR because `scope.py`/`state.py` do not exist.

- [ ] **Step 4: Implement the canonical object and digest**

Build the exact version-1 object from manifest scope fields, sort as specified, and encode with:

```python
json.dumps(
    value,
    ensure_ascii=False,
    sort_keys=True,
    separators=(",", ":"),
).encode("utf-8")
```

Do not append a newline. Keep feature, status, evidence, capability, timestamp, and private provenance data out of this object.

- [ ] **Step 5: Implement private state, approval matching, and provenance authority**

Resolve state under `${XDG_STATE_HOME:-~/.local/state}/lera-plugins/legacy-parity`. Use `os.open(..., 0o600)` for files, `mkdir(mode=0o700)`, `os.replace()` for writes, and explicit mode verification on POSIX. `approval_matches()` must compare revision, both digests, exact canonical public bytes, and exact private binding bytes. Implement strict `load_provenance()`/`write_provenance()` for the version-1 state. Provenance may be absent before the first post-approval full audit, but ordinary full-private validation never treats absence as a skip.

- [ ] **Step 6: Run the focused and full suites**

Run the two commands from Step 3, then the standard full test command. Expected: PASS.

- [ ] **Step 7: Commit canonical approval support**

```bash
git add tools/legacy_parity/scope.py tools/legacy_parity/state.py tests/legacy_parity/test_scope.py tests/legacy_parity/test_state.py
git commit -m "feat: authenticate approved parity scope"
```

### Task 4: Private discovery and explicit target selection

**Files:**
- Create: `tools/legacy_parity/legacy.py`
- Create: `tests/legacy_parity/test_discovery.py`
- Create: `tests/legacy_parity/fixtures/private-tree/plugins/alpha.xml`
- Create: `tests/legacy_parity/fixtures/private-tree/plugins/category/beta.xml`
- Create: `tests/legacy_parity/fixtures/private-tree/lua/alpha.lua`

- [ ] **Step 1: Write failing discovery tests using invented candidates**

Assert that `discover()`:

- returns normalized repository-relative POSIX XML paths grouped deterministically;
- never follows symlinks outside the supplied root;
- does not infer scope from filenames;
- suppresses candidates recorded as omitted in private `selection.json`;
- includes them only with `revisit_omitted=True`;
- carries included/omitted decisions only in private state;
- records an included target only from an explicit private record containing a stable target key, one or more typed sources with `complete` or `selected` coverage, approved feature keys and exact private bindings for selected sources, and zero or more current-plugin mappings;
- permits several XML/helper sources and several current plugins to form one target without inferring grouping from names, and permits one source to contribute disjoint selected bindings to several targets;
- rejects overlapping selected bindings, complete-source reuse across targets, an included target with no XML source, incomplete selected bindings, and unknown current mappings;
- does not print or write a total omitted count;
- refuses to write discovery output beneath the public repository.

- [ ] **Step 2: Run the discovery tests and verify failure**

Run:

```bash
mise exec python@3.12 -- python -m unittest tests.legacy_parity.test_discovery -v
```

Expected: FAIL because discovery is not implemented.

- [ ] **Step 3: Implement candidate discovery and selection records**

`discover(legacy_root, selection, revisit_omitted=False)` may reveal unapproved names only in its returned private command result. Implement version-1 `selection.json` with `included_targets` records shaped as `{key, sources, current_plugins}` and private `omitted_candidates` records keyed by XML path. Each source records `kind`, normalized `path`, `coverage`, safe approved `feature_keys`, and private construct bindings when selected. `record_included_target()` requires the complete explicit grouping, selected bindings, and mappings; `record_omitted_candidate()` stores only the private decision. Neither API derives target identity, helper membership, feature groups, or mappings from a filename.

- [ ] **Step 4: Add CLI commands and sanitized ordinary output**

Add:

```text
legacy-parity discover --legacy-root PATH [--revisit-omitted]
legacy-parity select --legacy-root PATH --omit XML_PATH
legacy-parity select --legacy-root PATH --include-target-record PRIVATE_JSON
```

Only `discover` may display unapproved candidate names. `select`, `validate`, `propose-scope`, `approve-scope`, `sync-issues`, and `publish` return generic record counts/status codes without echoing unapproved names.

- [ ] **Step 5: Run tests and commit**

Run discovery tests and the full suite. Expected: PASS.

```bash
git add tools/legacy_parity/legacy.py tools/legacy_parity/state.py tools/legacy_parity/cli.py tests/legacy_parity/test_discovery.py tests/legacy_parity/fixtures/private-tree
git commit -m "feat: keep legacy discovery decisions private"
```

### Task 5: Exhaustive legacy construct extraction and exact-once coverage

**Files:**
- Modify: `tools/legacy_parity/legacy.py`
- Create: `tools/legacy_parity/coverage.py`
- Create: `tests/legacy_parity/test_legacy.py`
- Create: `tests/legacy_parity/test_coverage.py`
- Create: `tests/legacy_parity/fixtures/private-tree/plugins/coverage.xml`
- Create: `tests/legacy_parity/fixtures/private-tree/lua/coverage.lua`

- [ ] **Step 1: Write failing XML construct tests**

Use a synthetic plugin containing metadata, variables, aliases, triggers, timers, callbacks, and embedded script. Assert that every XML element with attributes or non-whitespace text receives one stable private construct ID of the form `xml:<relative-path>:<structural-index>`, including disabled elements. Structural container elements with no attributes/text are recorded as groups but do not create behavior constructs. Every executable physical line in an embedded Lua script/body is additionally extracted as `xml-lua:<relative-path>:<structural-index>:<line>` so a large script can never receive one blanket coverage assignment.

- [ ] **Step 2: Write failing Lua coverage tests**

Use a synthetic helper containing comments, multiline comments, named/local functions, top-level statements, multiline calls, and blank lines. Assert that `executable_lua_lines()` returns every nonblank, non-comment physical line. Coverage assignments use inclusive source ranges and must reject missing lines, overlaps, out-of-bounds lines, nonexistent feature keys, and paths outside the approved helper list.

Add literal and dynamic dependency cases for XML `<include>`/external script references plus embedded/helper Lua `require`, `dofile`, and `loadfile`. Assert the extractor resolves a dependency closure under the legacy root, rejects traversal/symlink escapes, fails when any resolved helper is absent from the target's approved Lua sources, fails when an approved helper is neither reachable nor explicitly documented as relevant in private evidence, and requires a reviewed private resolution for every dynamic dependency construct. Complete helpers contribute their full executable-line set; selected helpers contribute exactly their approved private bindings.

- [ ] **Step 3: Write failing exact-once aggregate tests**

Given XML construct IDs and Lua executable-line IDs, assert:

```python
result = verify_complete_coverage(required, assignments, known_features)
self.assertEqual(result.missing, ())
self.assertEqual(result.duplicate, ())
self.assertTrue(result.complete)
```

Then independently introduce one missing and one duplicate assignment and assert failure. Grouping several constructs under one feature is valid only when every member is enumerated in the private assignment.

Also test the reverse direction: every public feature must reference at least one approved construct or an explicit approved current-only rationale. Each evidence record has a private declared construct scope; reject a fixture/local/manual evidence scope that is narrower than the feature's assigned construct set, references another target, or includes an unknown construct.

- [ ] **Step 4: Run focused tests and verify failure**

Run:

```bash
mise exec python@3.12 -- python -m unittest tests.legacy_parity.test_legacy tests.legacy_parity.test_coverage -v
```

Expected: FAIL because extraction/coverage are incomplete.

- [ ] **Step 5: Implement XML extraction without public source copying**

Parse with `xml.etree.ElementTree`. Store only private structural IDs, path, element tag, structural index, line offsets, and source kind. Feed embedded Lua bodies and code-bearing script elements through the same executable-line partitioner used for helper files and include those IDs in the target's required set. Extract and resolve XML/Lua helper references to a closed approved dependency graph; represent dynamic references as required private constructs until manually resolved to approved paths. Never put attribute values, text bodies, patterns, or script bodies in public objects or diagnostics. Parse/dependency failure is exit class 2, never partial coverage.

- [ ] **Step 6: Implement Lua executable-line partitioning and coverage ledger**

Recognize line comments, long comments using Lua's `--[=*[`/`]=*]` delimiters, strings sufficiently to avoid treating comment markers inside quoted strings as comments, and retain every executable physical line. Private assignments expand ranges to stable helper or embedded-Lua IDs. Require the union to equal the required set and intersection counts to equal one. Then verify the reverse feature mapping and require each evidence scope to cover the full assigned construct set; current-only rationales require their own explicit private approval metadata.

- [ ] **Step 7: Run tests and commit**

Run focused tests and the full suite. Expected: PASS.

```bash
git add tools/legacy_parity/legacy.py tools/legacy_parity/coverage.py tests/legacy_parity/test_legacy.py tests/legacy_parity/test_coverage.py tests/legacy_parity/fixtures/private-tree
git commit -m "feat: enforce complete legacy construct coverage"
```

### Task 6: Current extraction and preliminary-audit records

**Files:**
- Create: `tools/legacy_parity/current.py`
- Create: `tools/legacy_parity/audit.py`
- Create: `tests/legacy_parity/test_current.py`
- Create: `tests/legacy_parity/test_audit.py`
- Create: `tests/legacy_parity/fixtures/current/generic/sample.lua`
- Create: `tests/legacy_parity/fixtures/mirror/generic/sample.lua`

- [ ] **Step 1: Write failing inventory tests**

Assert that production discovery includes only `generic/*.lua` and `3scapes/*.lua`, excludes `examples/` and `3scapes/configs/`, returns normalized sorted keys/paths, rejects duplicate basenames, and compares exactly against the current-plugin records in a manifest.

- [ ] **Step 2: Write failing current-behavior extraction tests**

Use a synthetic current plugin and assert extraction records module identity, lifecycle hooks, alias/trigger/timer/MIP registrations, plugin dependencies, public module functions, persistence/configuration calls, renderers/user-visible output, sends, and Lera API families. Stable private current construct IDs include safe current path and line. Static extraction is inventory evidence only and never establishes semantic parity.

- [ ] **Step 3: Write failing private preliminary-audit tests**

Define a version-1 `PreliminaryAudit` record containing `current_key`, `current_path`, private current-source digest, complete extracted current construct IDs, included target keys, explicit current-only rationale when there are no targets, preliminary feature-status observations, confirmed blocker keys, review date, and `complete`. Assert atomic/private persistence and rejection when source digest/inventory changed, target keys are absent from selection, target mappings disagree, a behavior is unreviewed, empty/nonempty current mappings conflict, status aggregation is inconsistent, or `complete` is set before every extracted behavior is classified.

`validate_preliminary_audits()` must require exactly one current record for every discovered production plugin and exactly one audit/mapping record for every included target. Test all 17 expected current keys as a fixture vector so the later gate is mechanical rather than narrative.

- [ ] **Step 4: Write failing reference and mirror tests**

Assert that `generic/sample.lua:3` validates only when the path is in current scope and the line exists. Reject ranges, absolute paths, missing files, line zero, and references to examples. Assert mirror comparison checks path sets and file bytes, reports added/missing/changed generically, and never modifies either tree.

- [ ] **Step 5: Run tests and verify failure**

Run:

```bash
mise exec python@3.12 -- python -m unittest tests.legacy_parity.test_current tests.legacy_parity.test_audit -v
```

Expected: ERROR because `current.py` and `audit.py` do not exist.

- [ ] **Step 6: Implement extraction, audit persistence, and completion gates**

Expose `discover_current(repo_root)`, `extract_current(path)`, `validate_current_scope(...)`, `validate_code_ref(...)`, and `compare_mirror(plugin_root, lera_plugin_root)`. In `audit.py`, implement `load_preliminary_audit()`, `stage_preliminary_audit()`, and `validate_preliminary_audits()`. Accept audit input only from a path already inside private state, recompute source/inventory facts rather than trusting authored values, and use stable safe diagnostic codes.

Add CLI commands:

```text
legacy-parity stage-preliminary --plugin-root PATH --record PRIVATE_JSON
legacy-parity check-preliminary --plugin-root PATH --legacy-root PATH
```

- [ ] **Step 7: Run tests and commit**

Run focused tests and the full suite. Expected: PASS.

```bash
git add tools/legacy_parity/current.py tools/legacy_parity/audit.py tools/legacy_parity/cli.py tests/legacy_parity/test_current.py tests/legacy_parity/test_audit.py tests/legacy_parity/fixtures/current tests/legacy_parity/fixtures/mirror
git commit -m "feat: stage complete preliminary parity audits"
```

### Task 7: Evidence, status, and strict-parity rules

**Files:**
- Create: `tools/legacy_parity/compare.py`
- Create: `tests/legacy_parity/test_compare.py`

- [ ] **Step 1: Write failing evidence/status matrix tests**

Cover every status and assert:

- `parity` requires reviewed evidence and at least one safe current reference or public behavior fixture;
- `plugin_gap` requires reviewed evidence and a non-sensitive gap summary;
- `lera_blocker` requires a known capability with an exact private Lera issue URL before publication;
- `not_converted` is valid for every feature of an unmapped target and for an individual unimplemented feature of a mapped, partially converted target;
- `waived` requires explicit approval date and non-sensitive rationale;
- mapped targets have at least one feature, may use `not_converted` for an unimplemented approved feature, and then aggregate to `plugin_gap`;
- unmapped targets have at least one `not_converted` feature;
- `--require-parity` treats `parity` and explicitly approved `waived` as accepted, and returns findings for every other status;
- feature order is stable and feature keys are unique within a target.
- reverse coverage rejects any feature without approved legacy constructs or an approved current-only rationale;
- evidence declared scope contains every construct assigned to its feature;
- target aggregation follows exact precedence: an empty current mapping is `not_converted`; otherwise any blocker is `lera_blocker`; otherwise any gap/not-converted feature is `plugin_gap`; otherwise all parity/waived is `parity`;
- feature-status counts retain simultaneous blocker/gap information even though aggregate precedence selects one status.
- every evidence record has valid review date, reviewed-scope summary, result summary, and explicit pass/fail outcome;
- parity never accepts failed evidence, and full-private validation resolves every local evidence key to a matching provenance record with the same target, feature, evidence type, declared construct scope, outcome, and review date;
- manual-private-review evidence is rejected without its complete private review record.

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
mise exec python@3.12 -- python -m unittest tests.legacy_parity.test_compare -v
```

Expected: ERROR because `compare.py` does not exist.

- [ ] **Step 3: Implement comparison rules and safe findings**

Return structured `Finding(code, severity, public_key=None)` records. Never include legacy source snippets, patterns, local absolute paths, omitted candidates, or private hashes. Implement `aggregate_target(target)` with the specification's exact deterministic precedence and separately return sorted feature-status counts for reports.

Implement `validate_evidence(feature, private_evidence=None)` so public validation checks safe schema/outcome/fixture references, while full-private validation additionally authenticates opaque local evidence keys and their complete private metadata.

- [ ] **Step 4: Run tests and commit**

Run focused tests and the full suite. Expected: PASS.

```bash
git add tools/legacy_parity/compare.py tests/legacy_parity/test_compare.py
git commit -m "feat: enforce strict parity evidence rules"
```

### Task 8: Versioned private complete-audit bundle

**Files:**
- Create: `tools/legacy_parity/staged.py`
- Create: `tests/legacy_parity/test_staged.py`
- Create: `tests/legacy_parity/fixtures/private-bundle/valid-bundle.json`

- [ ] **Step 1: Write failing versioned-schema tests**

Define a synthetic version-1 `StagedAuditBundle` containing: exact canonical scope bytes/digest/revision; one record per approved target; complete private legacy construct inventory and dependency closure; construct-to-feature assignments; current-only rationales; public feature candidates; private evidence records and exact evidence scopes; blocker records with detailed evidence keys and issue URLs; derived affected feature/plugin keys; an exact `ProvenanceState` snapshot plus its digest; runtime scenario/result records; and hashes of the three candidate public artifacts. Assert strict parsing, duplicate/unknown-key rejection, normalized approved paths, and no unapproved target/source acceptance.

- [ ] **Step 2: Write failing cross-record integrity tests**

Independently break scope/approval matching, dependency closure, exact-once/reverse coverage, evidence-key linkage, evidence scope/outcome/date, blocker evidence, derived capability feature/plugin sets, runtime result/fixture digest, provenance source set/digest, staged-snapshot versus separate-`provenance.json` equality, and candidate artifact hashes. Assert `validate_staged_bundle()` rejects each mutation with sanitized diagnostics. Test one capability shared by two targets and two distinct capabilities affecting different features of one target.

- [ ] **Step 3: Write failing private persistence tests**

Assert `load_staged_bundle()`/`write_staged_bundle()` use only private state, mode `0600`, atomic replacement, and immutable update helpers for issue URLs, runtime results, and refreshed provenance. Refuse a bundle path beneath the public repository. Interruption/failure leaves the prior bundle unchanged.

- [ ] **Step 4: Run tests and verify failure**

Run:

```bash
mise exec python@3.12 -- python -m unittest tests.legacy_parity.test_staged -v
```

Expected: ERROR because `staged.py` does not exist.

- [ ] **Step 5: Implement the bundle and staging command**

Implement frozen private bundle records plus `load_staged_bundle()`, `validate_staged_bundle()`, `write_staged_bundle()`, and immutable field-specific update functions. Derived affected features/plugins are recomputed from feature capability references and approved mappings, never trusted from authored JSON. Add:

```text
legacy-parity stage-audit --input PRIVATE_JSON
```

The input and destination must both resolve inside private state. This synthetic command path is the sole representation consumed by issue sync, full-private validation, publication, and acceptance tests.

- [ ] **Step 6: Run tests and commit**

Run focused tests and the full suite. Expected: PASS.

```bash
git add tools/legacy_parity/staged.py tools/legacy_parity/cli.py tests/legacy_parity/test_staged.py tests/legacy_parity/fixtures/private-bundle
git commit -m "feat: validate private staged parity audits"
```

### Task 9: Privacy checks and deterministic public reports

**Files:**
- Create: `tools/legacy_parity/privacy.py`
- Create: `tools/legacy_parity/report.py`
- Create: `tests/legacy_parity/test_privacy.py`
- Create: `tests/legacy_parity/test_report.py`
- Create: `tests/legacy_parity/fixtures/public/expected-parity-report.md`
- Create: `tests/legacy_parity/fixtures/public/expected-not-converted.md`

- [ ] **Step 1: Write failing privacy tests**

Build public artifacts from synthetic approved and omitted candidates. Assert every rendered byte is free of:

- omitted names, paths, decision reasons, and counts;
- the private root and home path;
- private commit IDs and whole-source SHA-256 values;
- XML/Lua source bodies and trigger/alias patterns;
- private staged evidence keys except allowed opaque identifiers;
- credentials/token-like fixture values.

Also assert ordinary command diagnostics remain sanitized. Only `discover` may return unapproved names.

- [ ] **Step 2: Write failing report golden tests**

Assert deterministic exact Markdown for:

- parity report grouped by current plugin and approved target;
- separate not-converted inventory containing only approved targets with empty current mappings;
- zero-entry not-converted inventory with an explicit safe empty statement;
- issue links only for approved `lera_blocker` capabilities;
- no generation timestamp that would create nondeterministic diffs.
- a passing public parity report starts exactly `PUBLIC BASELINE VERIFIED — PRIVATE APPROVAL AND LEGACY SOURCES NOT RECHECKED`;
- a passing private full-validation report starts exactly `FULL PRIVATE BASELINE VERIFIED`, contains the verification timestamp, and is never one of the three public artifacts;
- private reports default under the state directory's `reports/`, and any user-supplied private report path resolving inside the public repository is rejected.

- [ ] **Step 3: Run tests and verify failure**

Run:

```bash
mise exec python@3.12 -- python -m unittest tests.legacy_parity.test_privacy tests.legacy_parity.test_report -v
```

Expected: ERROR because the modules do not exist.

- [ ] **Step 4: Implement deny-token scanning and report rendering**

Full-private validation builds deny tokens from private selection/provenance/root data and scans the exact staged public bytes. Public validation scans for structural leaks and unsafe URL/path/token forms without needing the private repositories. Render only fields explicitly admitted by the specification. Implement separate deterministic public and timestamped private renderers plus `resolve_private_report_path(state_root, repo_root, requested=None)`, which defaults to `state_root/reports/` and rejects paths inside the repository after symlink-aware resolution.

- [ ] **Step 5: Run tests and commit**

Run focused tests and the full suite. Expected: PASS.

```bash
git add tools/legacy_parity/privacy.py tools/legacy_parity/report.py tests/legacy_parity/test_privacy.py tests/legacy_parity/test_report.py tests/legacy_parity/fixtures/public
git commit -m "feat: render privacy-safe parity reports"
```

### Task 10: Transactional publication primitive

**Files:**
- Create: `tools/legacy_parity/publish.py`
- Create: `tests/legacy_parity/test_publish.py`

- [ ] **Step 1: Write failing first-publication and rollback tests**

In a temporary repository, assert:

- publication refuses missing/mismatched private approval;
- publication refuses incomplete coverage, unresolved blocker URLs, invalid evidence, runtime failure, privacy failure, or nonmatching scope digest;
- first-publication failure creates none of the three public outputs;
- update failure injected after each replace restores all three original bytes;
- successful publication writes manifest/report/not-converted as one validated set;
- stage/backup files are outside the public repository and removed on success/failure;
- unrelated `validation/README.md` content remains untouched.
- an injected publication gate receives the exact candidate bytes and matching staged bundle before any public write;
- gate failure or candidate-byte mutation after validation leaves every public output unchanged.

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
mise exec python@3.12 -- python -m unittest tests.legacy_parity.test_publish -v
```

Expected: ERROR because `publish.py` does not exist.

- [ ] **Step 3: Implement exception-safe staged publication**

Implement `PublicationCandidate` with exact manifest/report/not-converted bytes and SHA-256 values plus `publish_transaction(candidate, staged_bundle, gate)`. Render all three artifacts into a private temporary directory, fsync them, call the injected gate on those exact immutable bytes, retain private backups of existing public files, then replace the public files. On any exception, restore all prior bytes or remove every newly created output. Task 10 tests use a fake gate; Task 13 wires the real full-private gate after runtime/validation exist and re-tests publication end to end.

- [ ] **Step 4: Run tests and commit**

Run focused tests and the full suite. Expected: PASS.

```bash
git add tools/legacy_parity/publish.py tests/legacy_parity/test_publish.py
git commit -m "feat: publish parity artifacts transactionally"
```

### Task 11: Safe, deduplicated private Lera issue synchronization

**Files:**
- Create: `tools/legacy_parity/issues.py`
- Create: `tests/legacy_parity/test_issues.py`

- [ ] **Step 1: Write failing repository/marker tests with a fake runner**

Use an injected command runner; never call the network in unit tests. Assert the implementation:

- hard-codes exact repository `lundmark/lera` and verifies it is private;
- uses marker `<!-- legacy-parity-capability: <stable-capability-key> -->`;
- searches both open and closed issues by exact marker;
- reuses exactly one open issue;
- returns exit 3 for closed-only matches or multiple matches;
- creates exactly one issue when no match exists and not in dry-run mode;
- re-queries after creation and fails on post-create duplicates;
- never reopens, closes, deletes, or edits an issue;
- stores only the exact resulting issue URL in private staged state;
- never writes a partial public manifest.
- consumes only a validated version-1 staged bundle and requires detailed private blocker evidence for every capability;
- derives affected approved feature references and current plugin keys from feature capability links rather than trusting authored lists;
- supports one capability shared by multiple approved targets and multiple capabilities within one target without duplicates.

- [ ] **Step 2: Write failing title/body privacy tests**

Assert issue title/body contain only stable capability key, safe capability summary, generic parity impact, the derived approved affected current plugin keys, and marker. Reject unapproved plugin/target keys, private legacy names/paths/source snippets, current credentials, and local absolute paths before invoking `gh`. Test shared/multiple capability cases and assert the issue URL is atomically written back to the private bundle.

- [ ] **Step 3: Run tests and verify failure**

Run:

```bash
mise exec python@3.12 -- python -m unittest tests.legacy_parity.test_issues -v
```

Expected: ERROR because `issues.py` does not exist.

- [ ] **Step 4: Implement `gh` calls with argument arrays**

Use `gh repo view lundmark/lera --json nameWithOwner,visibility`, `gh api search/issues` for exact-marker lookup, and `gh issue create --repo lundmark/lera --body-file <private-temp-file>`. Parse JSON strictly, validate every returned URL against the exact repository, and map all GitHub failures/ambiguity to exit 3.

- [ ] **Step 5: Run tests and commit**

Run focused tests and the full suite. Expected: PASS.

```bash
git add tools/legacy_parity/issues.py tests/legacy_parity/test_issues.py
git commit -m "feat: deduplicate Lera capability issues"
```

### Task 12: Isolated Lera runtime validation

**Files:**
- Create: `tools/legacy_parity/runtime.py`
- Create: `tests/legacy_parity/test_runtime.py`
- Create: `tests/legacy_parity/fixtures/runtime/sample_plugin.lua`
- Create: `tests/legacy_parity/fixtures/runtime/sample_scenario.json`

- [ ] **Step 1: Write failing temporary-profile tests**

With a fake Lera executable, assert the runner creates a temporary profile containing only generated `profile.conf`, generated `init.lua`, copied synthetic plugins, and temporary `.storage`; passes the temporary profile path as the only profile; captures stdout/stderr; enforces a timeout; removes the directory; and never reads the user's profile or storage.

- [ ] **Step 2: Write failing deterministic stub and redirection tests**

Define data-only scenario JSON with plugin path, deterministic clock, temporary store seed, declared plugin dependency interfaces, callback/hook invocations, and expected returns/registrations/side effects. Assert the generated harness captures instead of performing `mud.send`/`send_raw`, push, IPC, WebSocket, timers, external HTTP/API calls, UI writes, prints, storage, MIP handlers, and alias/trigger registrations. `plugin.get`/non-target `plugin.load` resolve only declared stub tables; undeclared dependencies fail closed. Timer callbacks advance only through explicit scenario clock steps, and storage persists only inside the temporary profile.

The generated Lua harness saves the real loader for the target and installs stubs before loading it:

```lua
local real_plugin_load = plugin.load
-- generated data-only stubs replace side-effecting API table functions here
local p, err = real_plugin_load(assert(os.getenv("PARITY_PLUGIN")))
assert(p, err)
-- generated assertions invoke captured hooks/callbacks and inspect redirected effects
lera.quit()
```

Permit send/timer/external-API behavior only through these capture stubs so alias-to-command and automation behavior can be verified safely. Reject `mud.connect`, raw executable Lua in scenario JSON, absolute user-profile paths, real storage paths, wall-clock sleeps, shell commands, sockets, and undeclared external/plugin APIs.

- [ ] **Step 3: Run tests and verify failure**

Run:

```bash
mise exec python@3.12 -- python -m unittest tests.legacy_parity.test_runtime -v
```

Expected: ERROR because `runtime.py` does not exist.

- [ ] **Step 4: Implement the safe runner and real-binary smoke test**

`run_scenario(lera_bin, plugin_root, scenario, timeout=10)` validates the data-only schema, renders Lua literals safely, creates a new temporary directory, and uses an environment allowlist. Stubs preserve captured call order and expose explicit callback invocation/clock advancement operations. Add a test skipped unless `LERA_TEST_BIN` exists. When enabled with `/home/simon/code/lera/build/lera`, it loads only the synthetic fixture and exits without connecting.

- [ ] **Step 5: Run fake and real isolated tests**

Run:

```bash
mise exec python@3.12 -- python -m unittest tests.legacy_parity.test_runtime -v
LERA_TEST_BIN=/home/simon/code/lera/build/lera mise exec python@3.12 -- python -m unittest tests.legacy_parity.test_runtime -v
```

Expected: fake tests PASS; real-binary smoke test PASS or is reported skipped only when the binary is absent. No live MUD connection occurs.

- [ ] **Step 6: Commit the runtime harness**

```bash
git add tools/legacy_parity/runtime.py tests/legacy_parity/test_runtime.py tests/legacy_parity/fixtures/runtime
git commit -m "feat: run parity checks in isolated Lera profiles"
```

### Task 13: Validation levels and complete CLI orchestration

**Files:**
- Modify: `tools/legacy_parity/cli.py`
- Modify: `tools/legacy_parity/state.py`
- Modify: `tools/legacy_parity/manifest.py`
- Create: `tests/legacy_parity/test_validation.py`
- Modify: `tests/legacy_parity/test_cli.py`

- [ ] **Step 1: Write failing public-level tests**

Public validation must require only the public repository and verify schema, internal scope digest, current inventory, fixture declarations, current-code references, report determinism, report/manifest agreement, and structural privacy. It must explicitly report that private approval, legacy provenance/coverage, mirror parity, private leakage tokens, and real Lera runtime were not rechecked.
Its passing report/console summary begins with the exact public heading `PUBLIC BASELINE VERIFIED — PRIVATE APPROVAL AND LEGACY SOURCES NOT RECHECKED` and contains no verification timestamp.

- [ ] **Step 2: Write failing full-private tests**

Full-private validation requires `--legacy-root`, `--lera-root`, `--lera-bin`, and private state. It authenticates approval, selected-source existence/hash provenance, exact-once coverage, current mirror bytes, feature evidence, issue URLs, isolated runtime results, privacy deny tokens, and staged/public consistency. `--require-parity` is rejected at public level and accepted only at full-private level.
It loads the versioned staged bundle as its single private audit input, recomputes all derived capability links, resolves every local evidence key against provenance, and exposes `full_private_publication_gate(candidate, staged_bundle, roots, lera_bin)` for Task 10's transaction primitive. Add an integration test proving the gate validates the exact candidate bytes and a one-byte mutation prevents publication.
Ordinary full-private validation requires separate version-1 `provenance.json` and exact equality/digest match with the staged snapshot. Its private report begins `FULL PRIVATE BASELINE VERIFIED`, includes a verification timestamp, defaults under private state `reports/`, and rejects a requested path inside the repository.

Add `--refresh-legacy` tests: it is valid only at full-private level with explicit legacy root and matching private approval; it re-extracts only already-approved target paths; it refuses any added/discovered target, scope/mapping change, incomplete new coverage/evidence review, or failed non-provenance check; and it supports the initial post-approval creation when provenance is absent. It constructs the complete version-1 `ProvenanceState`, then transactionally writes `provenance.json` and the staged bundle's identical snapshot/digest with rollback injection after either replace. Subsequent refreshes use the same transaction. It never changes selection, approval, staged public scope, or tracked files.

- [ ] **Step 3: Write failing CLI/exit-code tests**

Cover exact commands:

```text
discover --legacy-root PATH [--revisit-omitted]
select --legacy-root PATH --omit XML_PATH
select --legacy-root PATH --include-target-record PRIVATE_JSON
stage-preliminary --plugin-root PATH --record PRIVATE_JSON
check-preliminary --plugin-root PATH --legacy-root PATH
stage-audit --input PRIVATE_JSON
propose-scope --legacy-root PATH --plugin-root PATH --output PRIVATE_PATH
approve-scope --proposal PRIVATE_PATH --revision N --approved-on YYYY-MM-DD --confirmed-public-digest HEX --confirmed-binding-digest HEX
validate --level public [--plugin-root PATH]
validate --level full-private --legacy-root PATH --lera-root PATH --lera-bin PATH [--require-parity] [--refresh-legacy] [--private-report PATH]
sync-issues --staged PRIVATE_PATH [--dry-run]
publish --staged PRIVATE_PATH --legacy-root PATH --lera-root PATH --lera-bin PATH
```

Assert exit codes 0/1/2/3 and that exceptions never print sensitive values.

- [ ] **Step 4: Run tests and verify failure**

Run:

```bash
mise exec python@3.12 -- python -m unittest tests.legacy_parity.test_validation tests.legacy_parity.test_cli -v
```

Expected: FAIL because orchestration is incomplete.

- [ ] **Step 5: Implement validators and command routing**

Keep command functions small and pass explicit roots/state/runner dependencies. `propose-scope` may write only to a verified private-state path and consumes only complete selection/audit records. `approve-scope` verifies both caller-supplied digests against the exact proposal. `refresh-legacy` performs the two-file atomic/rollback private provenance transaction after all new extraction/coverage/evidence checks pass. Private report paths use the resolver from Task 9. `publish` always invokes full-private validation internally and has no bypass flag.

- [ ] **Step 6: Run all tests and syntax checks**

Run the standard full test and syntax commands. Expected: PASS.

- [ ] **Step 7: Commit CLI orchestration**

```bash
git add tools/legacy_parity/cli.py tools/legacy_parity/state.py tools/legacy_parity/manifest.py tests/legacy_parity/test_validation.py tests/legacy_parity/test_cli.py
git commit -m "feat: orchestrate public and private parity validation"
```

### Task 14: Documentation and public-only CI

**Files:**
- Create: `validation/README.md`
- Modify: `README.md`
- Create: `.github/workflows/legacy-parity.yml`
- Create: `tests/legacy_parity/test_docs.py`

- [ ] **Step 1: Write failing documentation/privacy assertions**

Assert the docs contain the public/full-private commands, exit-code table, state-directory location, exact approval warning, discover-only disclosure rule, no-live-MUD rule, issue-repository rule, and plan-2 requirement. Assert they do not contain any private candidate catalogue, omitted name/count/reason, private commit/hash, or copied source.

- [ ] **Step 2: Run the docs test and verify failure**

Run:

```bash
mise exec python@3.12 -- python -m unittest tests.legacy_parity.test_docs -v
```

Expected: FAIL because docs/workflow are missing.

- [ ] **Step 3: Write public documentation**

Add a concise README section linking `validation/README.md`. Clearly state that public CI proves internal consistency only and cannot re-authenticate private approval or private legacy parity.

- [ ] **Step 4: Add CI**

Create a workflow triggered for pushes/PRs that affect plugins, validation, tools, or tests. Use `actions/checkout`, `actions/setup-python` with Python 3.12, then run compileall, the full synthetic unit suite, and `tools/legacy-parity validate --level public` only when a public manifest exists. Never check out private repositories, restore private state, call GitHub issue sync, or run full-private validation in public CI.

- [ ] **Step 5: Run tests and inspect the workflow**

Run docs test, full suite, compileall, and:

```bash
rg -n "3s_scripts_old|approval.json|sync-issues|full-private|github\.token|secrets\." .github validation README.md
```

Expected: test suite PASS; matches are documentation warnings only, not CI actions or secret use.

- [ ] **Step 6: Commit docs and CI**

```bash
git add README.md validation/README.md .github/workflows/legacy-parity.yml tests/legacy_parity/test_docs.py
git commit -m "docs: document repeatable legacy parity validation"
```

### Task 15: Whole-validator synthetic acceptance test

**Files:**
- Create: `tests/legacy_parity/test_acceptance.py`
- Create: `tests/legacy_parity/fixtures/acceptance/`

- [ ] **Step 1: Write a failing end-to-end acceptance test**

Using invented legacy/current trees and a temporary private state directory, execute: discover, explicitly group/map an included target, record an omission, stage complete preliminary current audits, propose scope, approve exact digest, stage a validated version-1 bundle with bidirectional complete coverage/evidence/blocker/runtime/provenance records, dry-run issue sync, full-private validate, transactional publish through the real full-private gate into a temporary public repo, then public validate. Assert the omitted synthetic candidate is absent from every public byte and ordinary captured output.

- [ ] **Step 2: Add negative end-to-end cases**

Independently mutate an approved source, current mapping, mirror file, coverage assignment, reverse feature mapping, evidence scope, issue URL, runtime result, approval digest, and public report. Assert the appropriate 1/2/3 exit and no partial public update. Then explicitly review the synthetic source drift and run full-private `--refresh-legacy`; assert only approved provenance changes atomically and no target is added.

- [ ] **Step 3: Run the acceptance test and fix only integration defects**

Run:

```bash
mise exec python@3.12 -- python -m unittest tests.legacy_parity.test_acceptance -v
```

Expected before integration fixes: FAIL. Expected after minimal fixes: PASS.

- [ ] **Step 4: Run all verification**

Run:

```bash
mise exec python@3.12 -- python -m unittest discover -s tests/legacy_parity -p 'test_*.py' -v
mise exec python@3.12 -- python -m compileall -q tools/legacy_parity tests/legacy_parity
git diff --check
git status --short
```

Expected: tests PASS, compileall silent with exit 0, `git diff --check` silent, only intended files changed.

- [ ] **Step 5: Commit acceptance coverage**

```bash
git add tools/legacy_parity tests/legacy_parity/test_acceptance.py tests/legacy_parity/fixtures/acceptance
git commit -m "test: cover legacy parity workflow end to end"
```

### Task 16: Private preliminary audit of all 17 current plugins

**Files:**
- Read only: `generic/autologin.lua`
- Read only: `generic/deadmans.lua`
- Read only: `generic/help.lua`
- Read only: `generic/input_echo.lua`
- Read only: `generic/push_notify.lua`
- Read only: `3scapes/autostepper.lua`
- Read only: `3scapes/chat_monitor.lua`
- Read only: `3scapes/guild_druid.lua`
- Read only: `3scapes/kill_trigger.lua`
- Read only: `3scapes/mapper.lua`
- Read only: `3scapes/mapview.lua`
- Read only: `3scapes/mercenary.lua`
- Read only: `3scapes/minimap.lua`
- Read only: `3scapes/player_stats.lua`
- Read only: `3scapes/roominfo.lua`
- Read only: `3scapes/speedwalk.lua`
- Read only: `3scapes/stats_window.lua`
- Read only: approved candidate files under `/home/simon/code/3s_scripts_old`
- Write only: private `${XDG_STATE_HOME:-~/.local/state}/lera-plugins/legacy-parity/selection.json`
- Write only: private state under `${XDG_STATE_HOME:-~/.local/state}/lera-plugins/legacy-parity/staged/`

- [ ] **Step 1: Verify both source repositories before auditing**

Run:

```bash
git -C /home/simon/code/lera-plugins status --short --branch
git -C /home/simon/code/3s_scripts_old status --short --branch
git -C /home/simon/code/lera status --short --branch
```

Inspect repository status for drift and record preliminary observations only in the private staged audit workspace. Do not populate authoritative `provenance.json` before exact scope approval and the complete post-approval audit; Task 13's first reviewed `--refresh-legacy` creates it. Do not commit legacy/Lera commit IDs or hashes.

- [ ] **Step 2: Inventory the 17 current plugins with the validator**

Run public current discovery and assert the set equals the 17 paths listed above. Any addition/removal is a scope finding requiring user review, not automatic expansion.

- [ ] **Step 3: Review every current plugin in full**

For each of the 17 files, read the complete file and record privately:

- exported hooks/public functions;
- registered aliases, triggers, timers, MIP/protocol handlers, and callbacks;
- state/persistence and configuration;
- rendered UI and line transformation/gag behavior;
- sends/commands and lifecycle cleanup;
- dependencies on other plugins or Lera APIs;
- candidate legacy XML/helper mappings or explicit current-only status;
- preliminary aggregate status and confirmed client blockers only.

Do not sample long files. Mark each current plugin `preliminary_review_complete` only after all lines and exported behavior have been considered.

Do not stage the `PreliminaryAudit` yet. Its target keys must first exist in private selection.

- [ ] **Step 4: Inspect every proposed legacy source mapping in full**

For a current plugin's proposed mapping, extract the complete private construct/dependency inventory and inspect every mapped XML file and every relevant helper file. Choose an explicit stable target key, typed source coverage, safe feature keys and exact private bindings for selected sources, and all current mappings, then record the proposed private target with `legacy-parity select --include-target-record ...`. This is a proposal for the later exact approval gate, not public approval. Repeat until every target key referenced by a current audit exists in `selection.json`. This phase may establish mappings and preliminary status, but does not yet create parity claims.

- [ ] **Step 5: Stage all 17 private preliminary audits**

For each plugin, prepare a private `PreliminaryAudit` JSON record whose extracted behavior IDs exactly match `extract_current()`, whose included target keys/mappings match the newly recorded private selection, and whose preliminary observations derive one aggregate status using the specification's precedence. Stage it with:

```bash
mise exec python@3.12 -- tools/legacy-parity stage-preliminary \
  --plugin-root /home/simon/code/lera-plugins \
  --record PRIVATE_RECORD_PATH
```

- [ ] **Step 6: Verify all 17 completion flags and current mirror bytes**

Run:

```bash
mise exec python@3.12 -- tools/legacy-parity check-preliminary \
  --plugin-root /home/simon/code/lera-plugins \
  --legacy-root /home/simon/code/3s_scripts_old
```

It must fail unless all 17 current plugin keys have a complete, source-current record and every included target has an exact grouped source/mapping record. Compare `/home/simon/code/lera-plugins/{generic,3scapes}` with `/home/simon/code/lera/plugins/{generic,3scapes}` and stage any drift as a private finding.

- [ ] **Step 7: Do not commit private audit state**

Run `git status --short` and confirm no candidate names, mappings, provenance, or audit evidence entered the repository. No commit is made for this task.

### Task 17: Privately review remaining conversion candidates

**Files:**
- Read only: `/home/simon/code/3s_scripts_old`
- Write only: `${XDG_STATE_HOME:-~/.local/state}/lera-plugins/legacy-parity/selection.json`

- [ ] **Step 1: Run private discovery**

Run:

```bash
mise exec python@3.12 -- tools/legacy-parity discover --legacy-root /home/simon/code/3s_scripts_old
```

The command may show candidate names only in its direct terminal output. It must exclude candidates already mapped during the 17-plugin preliminary audit and candidates already marked omitted unless explicitly revisiting them.

- [ ] **Step 2: Present candidates to the user in manageable private categories**

Show names and a short locally derived purpose only in the live conversation. Do not save the catalogue in the public repository, plan, report, or commit. Ask which candidates should be included for conversion and which should be omitted.

- [ ] **Step 3: Record each explicit decision privately**

Use `legacy-parity select --omit` for each opt-out. For each inclusion, explicitly choose a stable target key, typed sources, complete/selected coverage, approved feature keys and exact private bindings for selected sources, and zero or more current mappings, then use `legacy-parity select --include-target-record ...`. Omitted names/reasons remain only in `selection.json` and disappear from later ordinary discovery. Do not infer grouping, mapping, feature selection, or a decision from silence.

- [ ] **Step 4: Repeat until every presented candidate has an explicit decision**

Use additional categories as needed. `discover` must eventually return only candidates awaiting a user decision, without revealing or counting omitted entries.

- [ ] **Step 5: Verify repository privacy**

Scan tracked/staged repository bytes with the private deny-token set and run `git status --short`. Expected: no selection catalogue or omitted identity entered the repository. No commit is made for this task.

### Task 18: Produce the exact allowlist proposal and stop for approval

**Files:**
- Write only: `${XDG_STATE_HOME:-~/.local/state}/lera-plugins/legacy-parity/staged/proposed-scope.json`
- Do not create yet: `${XDG_STATE_HOME:-~/.local/state}/lera-plugins/legacy-parity/approval.json`

- [ ] **Step 1: Generate the private proposal**

Run:

```bash
mise exec python@3.12 -- tools/legacy-parity propose-scope \
  --legacy-root /home/simon/code/3s_scripts_old \
  --plugin-root /home/simon/code/lera-plugins \
  --output "${XDG_STATE_HOME:-$HOME/.local/state}/lera-plugins/legacy-parity/staged/proposed-scope.json"
```

The proposal contains exactly all 17 current plugin keys/paths, every user-selected legacy target with typed sources, complete/selected coverage, safe approved feature keys, exact private bindings for selected sources, zero or more mapped current plugins, preliminary aggregate status, and already-confirmed client blockers. Public canonical scope fields produce the displayed public digest; the proposal also displays the private binding digest without exposing construct identities.

- [ ] **Step 2: Validate proposal completeness without approving it**

Assert every current plugin has a completed preliminary audit; every included legacy target has explicit source coverage, selected bindings, and current mappings; every source path exists under the legacy root; no selected binding overlaps; no omitted candidate appears; and no unreviewed candidate was auto-added.

- [ ] **Step 3: Present the exact canonical scope and both digests to the user**

Show the proposed current plugin list, approved legacy target sources/coverage/mappings, preliminary statuses/blockers, canonical scope revision, public SHA-256 digest, and private binding SHA-256 digest in the live conversation. This disclosure is the private review interaction, not a tracked artifact; private construct identities remain hidden.

- [ ] **Step 4: Stop and request explicit go-ahead for that exact scope**

Do not infer formal approval from this plan, the prior semantic approval, category decisions, or silence. Do not run `approve-scope`, sync real issues, generate public outputs, or claim parity until the user explicitly approves the exact displayed proposal and both digests.

- [ ] **Step 5: After exact approval, authenticate it privately**

Only after the user's explicit response, run:

```bash
mise exec python@3.12 -- tools/legacy-parity approve-scope \
  --proposal "${XDG_STATE_HOME:-$HOME/.local/state}/lera-plugins/legacy-parity/staged/proposed-scope.json" \
  --revision 1 \
  --approved-on "$APPROVAL_DATE" \
  --confirmed-public-digest "$APPROVED_SCOPE_DIGEST" \
  --confirmed-binding-digest "$APPROVED_BINDING_DIGEST"
```

Set both digest variables in the executing shell to the exact values shown to and approved by the user, and set `APPROVAL_DATE` to the actual local calendar date on which that exact approval is given. Then verify `approval.json` mode/content and that a one-byte public-scope or private-binding change invalidates it.

No public manifest/report commit is made at the end of plan 1.

## Plan 1 completion criteria

Plan 1 is complete only when:

- the standard-library validator and all synthetic tests are committed;
- all 17 current plugins have private completed preliminary-audit records;
- all remaining presented candidates have explicit private include/omit decisions;
- the exact canonical allowlist and digest were shown to the user;
- the user explicitly approved that exact scope and private approval matches it;
- no omitted candidate identity/count/reason, private source/hash/commit, or legacy source body entered tracked bytes;

Passing plan 1 does not establish feature parity. Only plan 2's full-private, complete-coverage validation can do that.

After plan 1 completes, use `superpowers:writing-plans` as a separate planning action to create plan 2 from the fixed approved scope. Plan 2 must name every approved target and give each one an individual full-audit task, then cover real blocker issue synchronization, full-private strict validation, transactional publication, and independent review.
