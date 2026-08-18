# Legacy parity validation

This repository validates an explicitly approved set of legacy behaviors
against the current Lera plugins. The validator keeps discovery decisions,
source provenance, local evidence, and approval records in private state. The
three eventual public artifacts contain only approved targets and sanitized
status information.

Public validation proves that committed artifacts are deterministic and
internally consistent. It does not re-authenticate private approval, private
legacy sources, coverage evidence, mirror bytes, private leakage deny tokens,
or the real Lera runtime.

## Safety boundary

- discover is the only command that prints candidate identifiers. Other
  commands emit fixed success text or sanitized diagnostic codes.
- Never copy a discovery list, an opt-out decision, private source text,
  provenance, or local evidence into this repository.
- Validation never connects to the live MUD. Runtime checks use a disposable
  profile, closed API stubs, a deterministic clock, and a temporary storage
  directory.
- Capability issues are deduplicated only in the private lundmark/lera
  repository. Issue synchronization verifies the destination before searching
  or creating anything.
- Do not inspect or reuse a live profile's .storage for validation.

Private state defaults to:

    ${XDG_STATE_HOME:-~/.local/state}/lera-plugins/legacy-parity

The directory and its JSON files are created with private permissions. Use the
optional --state-root argument only to select another path outside this
repository.

## Validation levels

Run the reproducible public baseline from the repository root:

    tools/legacy-parity validate --level public

This checks the manifest schema and public scope digest, fixture declarations,
current-code references, deterministic reports, artifact agreement, and
structural privacy. It deliberately does not require the manifest's plugin list
to match the repository's: the manifest is a point-in-time approval record, and
gating current CI on it would mean re-approving a historical audit every time a
plugin is added, renamed or removed. Audited plugins are still held to the
repository through their current-code references. Its heading explicitly
states that private approval and legacy sources were not rechecked. There is
no timestamp, so identical inputs produce identical output.

Run full private validation only on a trusted machine with all required local
inputs:

    tools/legacy-parity validate --level full-private \
      --legacy-root /path/to/approved-legacy-source \
      --lera-root /path/to/lera \
      --lera-bin /path/to/lera/build/lera

This additionally checks the exact private approval, approved-source
provenance, construct coverage, evidence linkage, current mirror bytes,
capability issue URLs, isolated runtime results, private deny tokens, and
staged/public consistency. Its report is timestamped and written below the
private state directory by default.

Strict mode is intentionally private:

    tools/legacy-parity validate --level full-private \
      --legacy-root /path/to/approved-legacy-source \
      --lera-root /path/to/lera \
      --lera-bin /path/to/lera/build/lera \
      --require-parity

Use --refresh-legacy only after reviewing drift in every already-approved
source. Refresh re-extracts only approved paths, refuses scope or construct
changes, and atomically replaces provenance.json together with the identical
snapshot in the staged audit bundle. It never discovers new scope on the
operator's behalf.

## Exact scope approval

Scope approval is a cryptographic confirmation, not a general “looks good.”
The operator must review the complete private proposal and independently
confirm both its public scope digest and private binding digest:

    tools/legacy-parity approve-scope \
      --proposal PRIVATE_PROPOSAL \
      --revision REVISION \
      --approved-on YYYY-MM-DD \
      --confirmed-public-digest PUBLIC_DIGEST \
      --confirmed-binding-digest BINDING_DIGEST

Any change to a target, source, coverage mode, selected binding, or current
mapping changes one of those exact digests and requires a new approval.
Status-only evidence updates do not silently broaden scope.

Passing plan 1 does not establish feature parity or authorize publication.
After exact approval, plan 2 must name every approved target, give each target
its own complete audit task, synchronize real blockers, run strict
full-private validation, publish transactionally, and receive independent
review.

## Commands

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

publish always runs the full private gate against the exact candidate bytes.
It has no bypass option and rolls all public artifacts back together if any
gate or replacement fails.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Requested operation completed and all applicable gates passed. |
| 1 | Validation completed and found a parity, consistency, or privacy failure. |
| 2 | Usage, required input, private state, or configuration was invalid. |
| 3 | Private GitHub issue synchronization failed or became ambiguous. |

Diagnostics are stable codes. Sensitive exception values, paths, source text,
tokens, and command output are never echoed by the CLI entry point.
