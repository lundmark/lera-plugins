"""Strict parity evidence and deterministic target-status rules."""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass
from datetime import date


_ISSUE_RE = re.compile(
    r"^https://github\.com/lundmark/lera/issues/[1-9][0-9]*$"
)
_EVIDENCE_TYPES = frozenset(
    {"public_fixture", "local_behavior", "manual_private_review"}
)


@dataclass(frozen=True, slots=True)
class Finding:
    code: str
    severity: str = "error"
    public_key: str | None = None


@dataclass(frozen=True, slots=True)
class TargetAggregation:
    status: str
    feature_status_counts: tuple[tuple[str, int], ...]


def _finding(code, public_key=None):
    return Finding(code=code, severity="error", public_key=public_key)


def _valid_date(value):
    try:
        date.fromisoformat(value)
    except (TypeError, ValueError):
        return False
    return True


def _safe_summary(value):
    if not isinstance(value, str) or not value.strip() or len(value) > 500:
        return False
    lowered = value.lower()
    return not any(
        marker in lowered
        for marker in (
            "/home/",
            "/tmp/",
            "\\users\\",
            ".xml",
            "<muclient",
            "sha256:",
        )
    )


def aggregate_target(target) -> TargetAggregation:
    counts = tuple(
        sorted(Counter(feature.status for feature in target.features).items())
    )
    statuses = {feature.status for feature in target.features}
    if not target.current_plugins:
        status = "not_converted"
    elif not target.features:
        status = "plugin_gap"
    elif "lera_blocker" in statuses:
        status = "lera_blocker"
    elif statuses & {"plugin_gap", "not_converted"}:
        status = "plugin_gap"
    else:
        status = "parity"
    return TargetAggregation(status=status, feature_status_counts=counts)


def strict_parity_findings(targets) -> tuple[Finding, ...]:
    findings = []
    for target in sorted(targets, key=lambda item: item.key):
        for feature in sorted(target.features, key=lambda item: item.key):
            accepted = feature.status == "parity"
            if feature.status == "waived":
                accepted = (
                    _valid_date(feature.waiver_approved_on)
                    and _safe_summary(feature.waiver_rationale)
                )
            if not accepted:
                findings.append(
                    _finding(
                        "strict_parity_status",
                        f"{target.key}.{feature.key}",
                    )
                )
    return tuple(findings)


def validate_evidence(
    feature,
    *,
    target_key,
    capabilities=(),
    public_fixtures=(),
    private_evidence=None,
    full_private=False,
    declared_construct_scope=(),
) -> tuple[Finding, ...]:
    public_key = f"{target_key}.{feature.key}"
    findings = []
    record = feature.evidence
    fixture_keys = set(public_fixtures)
    capability_by_key = {item.key: item for item in capabilities}

    if record.type not in _EVIDENCE_TYPES:
        findings.append(_finding("invalid_evidence_type", public_key))
    if not _valid_date(record.review_date):
        findings.append(_finding("invalid_evidence_date", public_key))
    if not _safe_summary(record.reviewed_scope):
        findings.append(_finding("missing_reviewed_scope", public_key))
    if not _safe_summary(record.result):
        findings.append(_finding("missing_evidence_result", public_key))
    if record.outcome not in {"pass", "fail"}:
        findings.append(_finding("invalid_evidence_outcome", public_key))

    if record.type == "public_fixture":
        if not record.reference:
            findings.append(_finding("fixture_without_reference", public_key))
        elif fixture_keys and record.reference not in fixture_keys:
            findings.append(_finding("unknown_public_fixture", public_key))
    elif record.type in {"local_behavior", "manual_private_review"}:
        if not record.local_key:
            findings.append(_finding("local_evidence_without_key", public_key))

    if feature.status == "parity":
        if record.outcome != "pass":
            findings.append(_finding("parity_evidence_failed", public_key))
        has_fixture = (
            record.type == "public_fixture"
            and bool(record.reference)
            and (not fixture_keys or record.reference in fixture_keys)
        )
        if not feature.current_refs and not has_fixture:
            findings.append(_finding("parity_without_current_proof", public_key))

    if feature.status == "plugin_gap" and not _safe_summary(feature.summary):
        findings.append(_finding("unsafe_gap_summary", public_key))

    if feature.status == "lera_blocker":
        capability = capability_by_key.get(feature.capability)
        if capability is None:
            findings.append(_finding("unknown_blocker_capability", public_key))
        elif not _ISSUE_RE.fullmatch(capability.issue_url):
            findings.append(_finding("invalid_capability_issue_url", public_key))

    if feature.status == "waived":
        if not _valid_date(feature.waiver_approved_on) or not (
            feature.waiver_rationale
        ):
            findings.append(_finding("waiver_without_approval", public_key))
        elif not _safe_summary(feature.waiver_rationale):
            findings.append(_finding("unsafe_waiver_rationale", public_key))

    if full_private and record.type in {
        "local_behavior",
        "manual_private_review",
    }:
        local_records = private_evidence or {}
        local = local_records.get(record.local_key)
        if local is None:
            findings.append(_finding("missing_private_evidence", public_key))
        else:
            expected = (
                target_key,
                feature.key,
                record.type,
                record.review_date,
                tuple(declared_construct_scope),
                record.outcome,
                record.result,
            )
            actual = (
                local.target,
                local.feature,
                local.evidence_type,
                local.review_date,
                tuple(local.construct_scope),
                local.outcome,
                local.result,
            )
            if actual != expected:
                findings.append(
                    _finding("private_evidence_mismatch", public_key)
                )

    return tuple(dict.fromkeys(findings))


def validate_target(
    target,
    *,
    capabilities=(),
    current_paths=(),
    public_fixtures=(),
    construct_assignments=None,
    current_only_features=(),
    evidence_scopes=None,
    private_evidence=None,
    full_private=False,
) -> tuple[Finding, ...]:
    del current_paths  # Current reference syntax/path validation is a separate gate.
    findings = []
    feature_keys = tuple(feature.key for feature in target.features)
    known_features = set(feature_keys)
    assignments = construct_assignments or {}
    scopes = evidence_scopes or {}
    current_only = set(current_only_features)

    if not target.features:
        findings.append(_finding("target_without_features", target.key))
    if len(feature_keys) != len(known_features):
        findings.append(_finding("duplicate_feature_key", target.key))
    if feature_keys != tuple(sorted(feature_keys)):
        findings.append(_finding("unstable_feature_order", target.key))
    if not target.current_plugins and any(
        feature.status != "not_converted" for feature in target.features
    ):
        findings.append(
            _finding("unmapped_target_has_implementation", target.key)
        )
    if any(key not in known_features for key in assignments):
        findings.append(_finding("unknown_construct_feature", target.key))
    if any(key not in known_features for key in current_only):
        findings.append(_finding("unknown_current_only_feature", target.key))
    if any(key not in known_features for key in scopes):
        findings.append(_finding("unknown_evidence_scope", target.key))

    for feature in target.features:
        public_key = f"{target.key}.{feature.key}"
        assigned = tuple(assignments.get(feature.key, ()))
        declared_scope = tuple(scopes.get(feature.key, ()))
        if not assigned and feature.key not in current_only:
            findings.append(
                _finding("feature_without_approved_origin", public_key)
            )
        if assigned and not set(assigned).issubset(set(declared_scope)):
            findings.append(_finding("evidence_scope_incomplete", public_key))
        findings.extend(
            validate_evidence(
                feature,
                target_key=target.key,
                capabilities=capabilities,
                public_fixtures=public_fixtures,
                private_evidence=private_evidence,
                full_private=full_private,
                declared_construct_scope=declared_scope,
            )
        )
    return tuple(dict.fromkeys(findings))
