import json
import re
import tomllib
from datetime import date
from pathlib import Path

from .scope import canonical_scope
from .model import (
    CATEGORIES,
    COVERAGE_MODES,
    EVIDENCE_TYPES,
    SOURCE_KINDS,
    STATUSES,
    Capability,
    CurrentPlugin,
    Evidence,
    Feature,
    LegacySource,
    LegacyTarget,
    Manifest,
    ScopeApproval,
)


_ISSUE_RE = re.compile(r"^https://github\.com/lundmark/lera/issues/[1-9][0-9]*$")
_DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")


def _valid_date(value):
    try:
        date.fromisoformat(value)
    except (TypeError, ValueError):
        return False
    return True


def _duplicates(values):
    seen = set()
    return any(value in seen or seen.add(value) for value in values)


def validate_manifest(manifest, *, allow_unresolved_issues=False):
    findings = []

    if manifest.scope.revision < 1:
        findings.append("invalid_scope_revision")
    if not _valid_date(manifest.scope.approved_on):
        findings.append("invalid_scope_date")
    if not _DIGEST_RE.fullmatch(manifest.scope.digest):
        findings.append("invalid_scope_digest")

    current_keys = tuple(item.key for item in manifest.current_plugins)
    target_keys = tuple(item.key for item in manifest.legacy_targets)
    capability_keys = {item.key for item in manifest.capabilities}

    if _duplicates(current_keys):
        findings.append("duplicate_current_key")
    if _duplicates(target_keys):
        findings.append("duplicate_target_key")

    for current in manifest.current_plugins:
        if not current.key or not current.path:
            findings.append("invalid_current_plugin")
        if any(key not in target_keys for key in current.target_keys):
            findings.append("unknown_current_target")

    for target in manifest.legacy_targets:
        if not target.sources:
            findings.append("target_without_sources")
        if not target.features:
            findings.append("target_without_features")
        if _duplicates(source.path for source in target.sources):
            findings.append("duplicate_target_source")
        if _duplicates(feature.key for feature in target.features):
            findings.append("duplicate_feature_key")
        if _duplicates(target.current_plugins):
            findings.append("duplicate_current_mapping")
        if any(key not in current_keys for key in target.current_plugins):
            findings.append("unknown_current_mapping")

        feature_keys = {feature.key for feature in target.features}
        for source in target.sources:
            if source.kind not in SOURCE_KINDS:
                findings.append("invalid_source_kind")
            if source.coverage not in COVERAGE_MODES:
                findings.append("invalid_source_coverage")
            if source.coverage == "selected" and not source.feature_keys:
                findings.append("selected_source_without_features")
            if source.coverage == "complete" and source.feature_keys:
                findings.append("complete_source_with_features")
            if _duplicates(source.feature_keys):
                findings.append("duplicate_source_feature")
            if any(key not in feature_keys for key in source.feature_keys):
                findings.append("unknown_source_feature")

        if not target.current_plugins and any(
            feature.status != "not_converted" for feature in target.features
        ):
            findings.append("unmapped_target_has_implementation")

        for feature in target.features:
            if feature.category not in CATEGORIES:
                findings.append("invalid_feature_category")
            if feature.status not in STATUSES:
                findings.append("invalid_feature_status")
            if not feature.key or not feature.summary:
                findings.append("invalid_feature")
            evidence = feature.evidence
            if evidence.type not in EVIDENCE_TYPES:
                findings.append("invalid_evidence_type")
            if evidence.outcome not in {"pass", "fail"}:
                findings.append("invalid_evidence_outcome")
            if not _valid_date(evidence.review_date):
                findings.append("invalid_evidence_date")
            if not evidence.reviewed_scope or not evidence.result:
                findings.append("incomplete_evidence")
            if evidence.type == "public_fixture" and not evidence.reference:
                findings.append("fixture_without_reference")
            if evidence.type != "public_fixture" and not evidence.local_key:
                findings.append("local_evidence_without_key")
            if feature.status == "parity" and evidence.outcome != "pass":
                findings.append("parity_without_passing_evidence")
            if feature.status == "lera_blocker":
                if not feature.capability:
                    findings.append("blocker_without_capability")
                elif feature.capability not in capability_keys:
                    findings.append("unknown_blocker_capability")
            if feature.status == "waived" and (
                not _valid_date(feature.waiver_approved_on)
                or not feature.waiver_rationale
            ):
                findings.append("waiver_without_approval")

    for capability in manifest.capabilities:
        if not capability.key or not capability.description:
            findings.append("invalid_capability")
        if not (
            allow_unresolved_issues and capability.issue_url == ""
        ) and not _ISSUE_RE.fullmatch(capability.issue_url):
            findings.append("invalid_capability_url")

    return tuple(dict.fromkeys(findings))


def _evidence(value):
    return Evidence(
        type=value["type"],
        review_date=value["review_date"],
        reviewed_scope=value["reviewed_scope"],
        result=value["result"],
        outcome=value["outcome"],
        reference=value.get("reference"),
        local_key=value.get("local_key"),
    )


def _feature(value):
    return Feature(
        key=value["key"],
        category=value["category"],
        status=value["status"],
        summary=value["summary"],
        current_refs=tuple(value.get("current_refs", ())),
        evidence=_evidence(value["evidence"]),
        capability=value.get("capability"),
        waiver_approved_on=value.get("waiver_approved_on"),
        waiver_rationale=value.get("waiver_rationale"),
    )


def _manifest_from_data(data):
    scope_data = data["scope"]
    manifest = Manifest(
        scope=ScopeApproval(
            revision=scope_data["revision"],
            approved_on=scope_data["approved_on"],
            digest=scope_data["digest"],
        ),
        current_plugins=tuple(
            CurrentPlugin(
                key=value["key"],
                path=value["path"],
                target_keys=tuple(value.get("target_keys", ())),
                fixtures=tuple(value.get("fixtures", ())),
                notes=value.get("notes"),
            )
            for value in data.get("current_plugins", ())
        ),
        legacy_targets=tuple(
            LegacyTarget(
                key=value["key"],
                sources=tuple(
                    LegacySource(
                        kind=source["kind"],
                        path=source["path"],
                        coverage=source["coverage"],
                        feature_keys=tuple(source.get("feature_keys", ())),
                    )
                    for source in value.get("sources", ())
                ),
                current_plugins=tuple(value.get("current_plugins", ())),
                features=tuple(
                    _feature(feature) for feature in value.get("features", ())
                ),
            )
            for value in data.get("legacy_targets", ())
        ),
        capabilities=tuple(
            Capability(
                key=value["key"],
                description=value["description"],
                issue_url=value["issue_url"],
            )
            for value in data.get("capabilities", ())
        ),
    )
    findings = validate_manifest(manifest)
    if findings:
        raise ValueError(",".join(findings))
    return manifest


def loads_manifest(content):
    if isinstance(content, bytes):
        try:
            content = content.decode("utf-8")
        except UnicodeDecodeError as error:
            raise ValueError("invalid_manifest_encoding") from error
    if not isinstance(content, str):
        raise ValueError("invalid_manifest_content")
    try:
        data = tomllib.loads(content)
        return _manifest_from_data(data)
    except (KeyError, TypeError, tomllib.TOMLDecodeError) as error:
        raise ValueError("invalid_manifest") from error


def load_manifest(path):
    return loads_manifest(Path(path).read_bytes())


def _quote(value):
    return json.dumps(value, ensure_ascii=False)


def _array(values):
    return "[" + ", ".join(_quote(value) for value in values) + "]"


def render_manifest(manifest):
    lines = [
        "[scope]",
        f"revision = {manifest.scope.revision}",
        f"approved_on = {_quote(manifest.scope.approved_on)}",
        f"digest = {_quote(manifest.scope.digest)}",
    ]

    for current in sorted(manifest.current_plugins, key=lambda item: item.key):
        lines.extend(
            [
                "",
                "[[current_plugins]]",
                f"key = {_quote(current.key)}",
                f"path = {_quote(current.path)}",
                f"target_keys = {_array(sorted(current.target_keys))}",
                f"fixtures = {_array(sorted(current.fixtures))}",
            ]
        )
        if current.notes is not None:
            lines.append(f"notes = {_quote(current.notes)}")

    for target in sorted(manifest.legacy_targets, key=lambda item: item.key):
        lines.extend(
            [
                "",
                "[[legacy_targets]]",
                f"key = {_quote(target.key)}",
                f"current_plugins = {_array(sorted(target.current_plugins))}",
            ]
        )
        for source in sorted(
            target.sources, key=lambda item: (item.kind, item.path)
        ):
            lines.extend(
                [
                    "",
                    "[[legacy_targets.sources]]",
                    f"kind = {_quote(source.kind)}",
                    f"path = {_quote(source.path)}",
                    f"coverage = {_quote(source.coverage)}",
                    f"feature_keys = {_array(sorted(source.feature_keys))}",
                ]
            )
        for feature in target.features:
            lines.extend(
                [
                    "",
                    "[[legacy_targets.features]]",
                    f"key = {_quote(feature.key)}",
                    f"category = {_quote(feature.category)}",
                    f"status = {_quote(feature.status)}",
                    f"summary = {_quote(feature.summary)}",
                    f"current_refs = {_array(feature.current_refs)}",
                ]
            )
            if feature.capability is not None:
                lines.append(f"capability = {_quote(feature.capability)}")
            if feature.waiver_approved_on is not None:
                lines.append(
                    f"waiver_approved_on = {_quote(feature.waiver_approved_on)}"
                )
            if feature.waiver_rationale is not None:
                lines.append(
                    f"waiver_rationale = {_quote(feature.waiver_rationale)}"
                )
            evidence = feature.evidence
            lines.extend(
                [
                    "",
                    "[legacy_targets.features.evidence]",
                    f"type = {_quote(evidence.type)}",
                    f"review_date = {_quote(evidence.review_date)}",
                    f"reviewed_scope = {_quote(evidence.reviewed_scope)}",
                    f"result = {_quote(evidence.result)}",
                    f"outcome = {_quote(evidence.outcome)}",
                ]
            )
            if evidence.reference is not None:
                lines.append(f"reference = {_quote(evidence.reference)}")
            if evidence.local_key is not None:
                lines.append(f"local_key = {_quote(evidence.local_key)}")

    for capability in sorted(manifest.capabilities, key=lambda item: item.key):
        lines.extend(
            [
                "",
                "[[capabilities]]",
                f"key = {_quote(capability.key)}",
                f"description = {_quote(capability.description)}",
                f"issue_url = {_quote(capability.issue_url)}",
            ]
        )

    return "\n".join(lines) + "\n"


def manifest_from_staged(
    bundle, approval, selection, *, allow_unresolved_issues=False
):
    """Derive the public manifest solely from approved private records."""

    try:
        public_scope = json.loads(bundle.public_scope)
    except json.JSONDecodeError as error:
        raise ValueError("invalid_staged_scope") from error
    current_scope = public_scope.get("current_plugins")
    if not isinstance(current_scope, list):
        raise ValueError("invalid_staged_scope")
    selected = {target.key: target for target in selection.included_targets}
    audits = {target.key: target for target in bundle.targets}
    if set(selected) != set(audits):
        raise ValueError("staged_target_set")
    runtime_by_target = {}
    for scenario in bundle.runtime_scenarios:
        runtime_by_target.setdefault(scenario.target_key, set()).add(
            scenario.fixture_key
        )
    current_plugins = []
    for item in current_scope:
        key = item["key"]
        mapped = tuple(
            sorted(
                target.key
                for target in selection.included_targets
                if key in target.current_plugins
            )
        )
        fixtures = tuple(
            sorted(
                {
                    fixture
                    for target_key in mapped
                    for fixture in runtime_by_target.get(target_key, ())
                }
            )
        )
        current_plugins.append(
            CurrentPlugin(
                key=key,
                path=item["path"],
                target_keys=mapped,
                fixtures=fixtures,
            )
        )
    targets = []
    for key in sorted(audits):
        audit = audits[key]
        private = selected[key]
        sources = tuple(
            LegacySource(
                kind=source.kind,
                path=source.path,
                coverage=source.coverage,
                feature_keys=source.feature_keys,
            )
            for source in private.sources
        )
        targets.append(
            LegacyTarget(
                key=key,
                sources=sources,
                current_plugins=audit.current_plugins,
                features=audit.features,
            )
        )
    capabilities = tuple(
        Capability(
            key=blocker.key,
            description=blocker.description,
            issue_url=blocker.issue_url or "",
        )
        for blocker in bundle.blockers
    )
    manifest = Manifest(
        scope=ScopeApproval(
            revision=bundle.scope_revision,
            approved_on=approval.approved_on,
            digest=bundle.public_digest,
        ),
        current_plugins=tuple(current_plugins),
        legacy_targets=tuple(targets),
        capabilities=capabilities,
    )
    findings = validate_manifest(
        manifest, allow_unresolved_issues=allow_unresolved_issues
    )
    if findings:
        raise ValueError(",".join(findings))
    if canonical_scope(manifest).decode("utf-8") != bundle.public_scope:
        raise ValueError("staged_scope_mismatch")
    return manifest
