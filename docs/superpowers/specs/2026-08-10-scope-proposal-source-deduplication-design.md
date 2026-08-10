# Scope Proposal Source Deduplication Design

## Context

The private legacy-parity workflow builds a canonical public scope before the
user gives digest-bound approval. The proposal builder currently nests two
iterations over the same target source collection. A target with multiple
approved sources therefore repeats every source in the canonical scope and
produces a digest for a scope the user did not select.

## Requirement

For every included legacy target, the proposal manifest must preserve each
selected source exactly once and in selection order. The correction must not
change target grouping, source metadata, private bindings, preliminary audit
status, approval rules, or privacy behavior.

## Design

Change only `_proposal_manifest` in `tools/legacy_parity/cli.py`: construct the
target's `LegacySource` tuple with one iteration over `target.sources`.

Add a focused unit regression test that constructs a selection containing one
target with two distinct sources, calls the real proposal-manifest builder, and
asserts that the resulting target contains exactly those two sources once and
in order. This directly reproduces the defect without file-system or CLI
mocking.

## Validation

Follow red-green TDD:

1. Add the regression test and run it alone, confirming the current code fails
   because it returns four source records instead of two.
2. Apply the one-loop correction and rerun the focused test.
3. Run the complete legacy-parity test suite.
4. Regenerate the private canonical proposal through the supported CLI and
   verify proposal completeness before showing either digest to the user.

## Non-goals

- No legacy selection or mapping changes.
- No publication, issue synchronization, or formal approval.
- No Lera client or plugin behavior changes.
- No private candidate, exclusion, or construct identity in tracked files.
