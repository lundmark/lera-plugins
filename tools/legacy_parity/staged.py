"""Versioned private bundle used by all complete-audit operations."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from dataclasses import asdict, dataclass, replace
from pathlib import Path, PurePosixPath

from .compare import validate_target
from .model import Evidence, Feature
from .scope import canonical_scope
from .state import LocalEvidence, ProvenanceState


_ARTIFACT_KEYS = frozenset(
    {"manifest", "not_converted", "parity_report"}
)
_ISSUE_PREFIX = "https://github.com/lundmark/lera/issues/"


@dataclass(frozen=True)
class SourceConstructs:
    source_path: str
    construct_ids: tuple[str, ...]


@dataclass(frozen=True)
class FeatureAssignment:
    feature_key: str
    construct_ids: tuple[str, ...]
    evidence_scope: tuple[str, ...]


@dataclass(frozen=True)
class TargetAudit:
    key: str
    source_paths: tuple[str, ...]
    dependency_closure: tuple[str, ...]
    construct_inventory: tuple[SourceConstructs, ...]
    assignments: tuple[FeatureAssignment, ...]
    current_only_rationales: tuple[tuple[str, str], ...]
    features: tuple[Feature, ...]


@dataclass(frozen=True)
class BlockerAudit:
    key: str
    description: str
    evidence_keys: tuple[str, ...]
    issue_url: str | None
    affected_features: tuple[str, ...]
    affected_plugins: tuple[str, ...]


@dataclass(frozen=True)
class RuntimeScenario:
    key: str
    target_key: str
    fixture_key: str
    fixture_digest: str


@dataclass(frozen=True)
class RuntimeResult:
    scenario_key: str
    outcome: str
    fixture_digest: str
    result: str


@dataclass(frozen=True)
class ArtifactHash:
    key: str
    digest: str


@dataclass(frozen=True)
class StagedAuditBundle:
    version: int
    scope_revision: int
    public_scope: str
    public_digest: str
    targets: tuple[TargetAudit, ...]
    evidence: tuple[LocalEvidence, ...]
    blockers: tuple[BlockerAudit, ...]
    provenance: ProvenanceState
    provenance_digest: str
    runtime_scenarios: tuple[RuntimeScenario, ...]
    runtime_results: tuple[RuntimeResult, ...]
    artifact_hashes: tuple[ArtifactHash, ...]


def _object(fields, required, code):
    if not isinstance(fields, dict) or set(fields) != set(required):
        raise ValueError(code)
    return fields


def _path(value):
    if (
        not isinstance(value, str)
        or not value
        or value.startswith("/")
        or "\\" in value
        or value.endswith("/")
        or "//" in value
    ):
        raise ValueError("invalid_staged_path")
    path = PurePosixPath(value)
    if any(part in {"", ".", ".."} for part in path.parts):
        raise ValueError("invalid_staged_path")
    return value


def _evidence(value):
    value = _object(
        value,
        {
            "type",
            "review_date",
            "reviewed_scope",
            "result",
            "outcome",
            "reference",
            "local_key",
        },
        "invalid_staged_feature_evidence",
    )
    return Evidence(
        type=value["type"],
        review_date=value["review_date"],
        reviewed_scope=value["reviewed_scope"],
        result=value["result"],
        outcome=value["outcome"],
        reference=value["reference"],
        local_key=value["local_key"],
    )


def _feature(value):
    value = _object(
        value,
        {
            "key",
            "category",
            "status",
            "summary",
            "current_refs",
            "evidence",
            "capability",
            "waiver_approved_on",
            "waiver_rationale",
        },
        "invalid_staged_feature",
    )
    return Feature(
        key=value["key"],
        category=value["category"],
        status=value["status"],
        summary=value["summary"],
        current_refs=tuple(value["current_refs"]),
        evidence=_evidence(value["evidence"]),
        capability=value["capability"],
        waiver_approved_on=value["waiver_approved_on"],
        waiver_rationale=value["waiver_rationale"],
    )


def _local_evidence(value):
    value = _object(
        value,
        {
            "key",
            "target",
            "feature",
            "evidence_type",
            "review_date",
            "construct_scope",
            "outcome",
            "result",
        },
        "invalid_staged_evidence",
    )
    return LocalEvidence(
        key=value["key"],
        target=value["target"],
        feature=value["feature"],
        evidence_type=value["evidence_type"],
        review_date=value["review_date"],
        construct_scope=tuple(value["construct_scope"]),
        outcome=value["outcome"],
        result=value["result"],
    )


def _provenance(value):
    value = _object(
        value,
        {
            "version",
            "scope_revision",
            "public_digest",
            "binding_digest",
            "legacy_commit",
            "source_digests",
            "evidence",
            "refreshed_at",
        },
        "invalid_staged_provenance",
    )
    return ProvenanceState(
        version=value["version"],
        scope_revision=value["scope_revision"],
        public_digest=value["public_digest"],
        binding_digest=value["binding_digest"],
        legacy_commit=value["legacy_commit"],
        source_digests=tuple(
            (_path(item[0]), item[1]) for item in value["source_digests"]
        ),
        evidence=tuple(_local_evidence(item) for item in value["evidence"]),
        refreshed_at=value["refreshed_at"],
    )


def _bundle(value):
    value = _object(
        value,
        {
            "version",
            "scope_revision",
            "public_scope",
            "public_digest",
            "targets",
            "evidence",
            "blockers",
            "provenance",
            "provenance_digest",
            "runtime_scenarios",
            "runtime_results",
            "artifact_hashes",
        },
        "invalid_staged_bundle",
    )
    targets = []
    for item in value["targets"]:
        item = _object(
            item,
            {
                "key",
                "source_paths",
                "dependency_closure",
                "construct_inventory",
                "assignments",
                "current_only_rationales",
                "features",
            },
            "invalid_staged_target",
        )
        inventories = []
        for inventory in item["construct_inventory"]:
            inventory = _object(
                inventory,
                {"source_path", "construct_ids"},
                "invalid_staged_inventory",
            )
            inventories.append(
                SourceConstructs(
                    _path(inventory["source_path"]),
                    tuple(inventory["construct_ids"]),
                )
            )
        assignments = []
        for assignment in item["assignments"]:
            assignment = _object(
                assignment,
                {"feature_key", "construct_ids", "evidence_scope"},
                "invalid_staged_assignment",
            )
            assignments.append(
                FeatureAssignment(
                    assignment["feature_key"],
                    tuple(assignment["construct_ids"]),
                    tuple(assignment["evidence_scope"]),
                )
            )
        targets.append(
            TargetAudit(
                key=item["key"],
                source_paths=tuple(_path(path) for path in item["source_paths"]),
                dependency_closure=tuple(
                    _path(path) for path in item["dependency_closure"]
                ),
                construct_inventory=tuple(inventories),
                assignments=tuple(assignments),
                current_only_rationales=tuple(
                    (entry[0], entry[1])
                    for entry in item["current_only_rationales"]
                ),
                features=tuple(_feature(feature) for feature in item["features"]),
            )
        )
    blockers = []
    for item in value["blockers"]:
        item = _object(
            item,
            {
                "key",
                "description",
                "evidence_keys",
                "issue_url",
                "affected_features",
                "affected_plugins",
            },
            "invalid_staged_blocker",
        )
        blockers.append(
            BlockerAudit(
                key=item["key"],
                description=item["description"],
                evidence_keys=tuple(item["evidence_keys"]),
                issue_url=item["issue_url"],
                affected_features=tuple(item["affected_features"]),
                affected_plugins=tuple(item["affected_plugins"]),
            )
        )
    scenarios = []
    for item in value["runtime_scenarios"]:
        item = _object(
            item,
            {"key", "target_key", "fixture_key", "fixture_digest"},
            "invalid_runtime_scenario",
        )
        scenarios.append(RuntimeScenario(**item))
    results = []
    for item in value["runtime_results"]:
        item = _object(
            item,
            {"scenario_key", "outcome", "fixture_digest", "result"},
            "invalid_runtime_result",
        )
        results.append(RuntimeResult(**item))
    artifacts = []
    for item in value["artifact_hashes"]:
        item = _object(
            item, {"key", "digest"}, "invalid_artifact_hash"
        )
        artifacts.append(ArtifactHash(**item))
    return StagedAuditBundle(
        version=value["version"],
        scope_revision=value["scope_revision"],
        public_scope=value["public_scope"],
        public_digest=value["public_digest"],
        targets=tuple(targets),
        evidence=tuple(_local_evidence(item) for item in value["evidence"]),
        blockers=tuple(blockers),
        provenance=_provenance(value["provenance"]),
        provenance_digest=value["provenance_digest"],
        runtime_scenarios=tuple(scenarios),
        runtime_results=tuple(results),
        artifact_hashes=tuple(artifacts),
    )


def _unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate_json_key")
        value[key] = item
    return value


def parse_staged_bundle(path) -> StagedAuditBundle:
    try:
        value = json.loads(
            Path(path).read_text(encoding="utf-8"),
            object_pairs_hook=_unique_object,
        )
    except json.JSONDecodeError as error:
        raise ValueError("invalid_staged_json") from error
    bundle = _bundle(value)
    if bundle.version != 1:
        raise ValueError("invalid_staged_version")
    return bundle


def provenance_digest(provenance) -> str:
    encoded = json.dumps(
        asdict(provenance),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _duplicates(values):
    values = tuple(values)
    return len(values) != len(set(values))


def _require_unique_sorted(values, code):
    values = tuple(values)
    if _duplicates(values) or values != tuple(sorted(values)):
        raise ValueError(code)


def _validate_scope(bundle, manifest, approval):
    public_scope = canonical_scope(manifest).decode("utf-8")
    expected_digest = hashlib.sha256(public_scope.encode("utf-8")).hexdigest()
    if (
        bundle.version != 1
        or bundle.scope_revision != manifest.scope.revision
        or bundle.public_scope != public_scope
        or bundle.public_digest != expected_digest
        or manifest.scope.digest != expected_digest
        or approval.revision != bundle.scope_revision
        or approval.public_scope != bundle.public_scope
        or approval.public_digest != bundle.public_digest
    ):
        raise ValueError("staged_scope_mismatch")


def _validate_target_set(bundle, manifest, selection):
    manifest_targets = {item.key: item for item in manifest.legacy_targets}
    selected_targets = {item.key: item for item in selection.included_targets}
    bundle_targets = {item.key: item for item in bundle.targets}
    if (
        _duplicates(item.key for item in bundle.targets)
        or set(bundle_targets) != set(manifest_targets)
        or set(bundle_targets) != set(selected_targets)
    ):
        raise ValueError("staged_target_set")
    return manifest_targets, selected_targets, bundle_targets


def _validate_targets(bundle, manifest, selection):
    manifest_targets, selected_targets, bundle_targets = _validate_target_set(
        bundle, manifest, selection
    )

    private_evidence = {item.key: item for item in bundle.evidence}
    for key in sorted(bundle_targets):
        audit = bundle_targets[key]
        public = manifest_targets[key]
        selected = selected_targets[key]
        expected_sources = tuple(
            sorted(source.path for source in public.sources)
        )
        selected_sources = tuple(
            sorted(source.path for source in selected.sources)
        )
        if (
            audit.source_paths != expected_sources
            or audit.source_paths != selected_sources
            or tuple(sorted(public.current_plugins))
            != tuple(sorted(selected.current_plugins))
            or audit.features != public.features
        ):
            raise ValueError("staged_source_set")
        _require_unique_sorted(audit.source_paths, "staged_source_set")
        _require_unique_sorted(
            audit.dependency_closure, "dependency_closure_mismatch"
        )
        if audit.dependency_closure != audit.source_paths:
            raise ValueError("dependency_closure_mismatch")
        inventory_paths = tuple(
            item.source_path for item in audit.construct_inventory
        )
        if inventory_paths != audit.dependency_closure or _duplicates(
            inventory_paths
        ):
            raise ValueError("dependency_closure_mismatch")

        required = tuple(
            construct
            for inventory in audit.construct_inventory
            for construct in inventory.construct_ids
        )
        assigned = tuple(
            construct
            for assignment in audit.assignments
            for construct in assignment.construct_ids
        )
        if (
            not required
            or _duplicates(required)
            or _duplicates(assigned)
            or set(required) != set(assigned)
        ):
            raise ValueError("staged_construct_coverage")
        feature_keys = {feature.key for feature in audit.features}
        assignment_keys = tuple(
            assignment.feature_key for assignment in audit.assignments
        )
        rationales = dict(audit.current_only_rationales)
        if (
            _duplicates(assignment_keys)
            or len(rationales) != len(audit.current_only_rationales)
            or any(key not in feature_keys for key in assignment_keys)
            or any(key not in feature_keys for key in rationales)
            or set(assignment_keys) & set(rationales)
            or set(assignment_keys) | set(rationales) != feature_keys
            or any(not value.strip() for value in rationales.values())
        ):
            raise ValueError("staged_reverse_coverage")
        for assignment in audit.assignments:
            if not set(assignment.construct_ids).issubset(
                set(assignment.evidence_scope)
            ):
                raise ValueError("staged_evidence_scope")

        for source in selected.sources:
            if source.coverage != "selected":
                continue
            expected_bindings = {
                binding.feature_key: set(binding.construct_ids)
                for binding in source.bindings
            }
            actual_bindings = {
                assignment.feature_key: set(assignment.construct_ids)
                for assignment in audit.assignments
            }
            if any(
                actual_bindings.get(feature_key, set()) != constructs
                for feature_key, constructs in expected_bindings.items()
            ):
                raise ValueError("staged_selected_binding")

        assignments = {
            item.feature_key: item.construct_ids
            for item in audit.assignments
        }
        scopes = {
            item.feature_key: item.evidence_scope
            for item in audit.assignments
        }
        findings = validate_target(
            public,
            capabilities=manifest.capabilities,
            construct_assignments=assignments,
            current_only_features=set(rationales),
            evidence_scopes=scopes,
            private_evidence=private_evidence,
            full_private=True,
        )
        if findings:
            raise ValueError("staged_feature_validation")


def _validate_evidence(bundle):
    keys = tuple(item.key for item in bundle.evidence)
    if _duplicates(keys):
        raise ValueError("staged_evidence_linkage")
    expected = tuple(
        sorted(
            feature.evidence.local_key
            for target in bundle.targets
            for feature in target.features
            if feature.evidence.local_key
        )
    )
    if tuple(sorted(keys)) != expected:
        raise ValueError("staged_evidence_linkage")


def _validate_blockers(bundle, manifest):
    blocker_by_key = {item.key: item for item in bundle.blockers}
    derived = {}
    evidence_by_feature = {
        (item.target, item.feature): item.key for item in bundle.evidence
    }
    for target in manifest.legacy_targets:
        for feature in target.features:
            if feature.status != "lera_blocker":
                continue
            entry = derived.setdefault(
                feature.capability,
                {"features": [], "plugins": set(), "evidence": []},
            )
            entry["features"].append(f"{target.key}.{feature.key}")
            entry["plugins"].update(target.current_plugins)
            evidence_key = evidence_by_feature.get((target.key, feature.key))
            if evidence_key is None:
                raise ValueError("staged_blocker_evidence")
            entry["evidence"].append(evidence_key)
    if _duplicates(item.key for item in bundle.blockers) or set(
        blocker_by_key
    ) != set(derived):
        raise ValueError("staged_blocker_derivation")
    capability_by_key = {item.key: item for item in manifest.capabilities}
    for key, expected in derived.items():
        blocker = blocker_by_key[key]
        capability = capability_by_key.get(key)
        if (
            capability is None
            or blocker.description != capability.description
            or blocker.affected_features
            != tuple(sorted(expected["features"]))
            or blocker.affected_plugins
            != tuple(sorted(expected["plugins"]))
            or blocker.evidence_keys != tuple(sorted(expected["evidence"]))
            or (
                blocker.issue_url is not None
                and (
                    not blocker.issue_url.startswith(_ISSUE_PREFIX)
                    or not blocker.issue_url[len(_ISSUE_PREFIX) :].isdigit()
                )
            )
        ):
            raise ValueError("staged_blocker_derivation")


def _validate_runtime(bundle, target_keys):
    scenarios = {item.key: item for item in bundle.runtime_scenarios}
    results = {item.scenario_key: item for item in bundle.runtime_results}
    if (
        _duplicates(item.key for item in bundle.runtime_scenarios)
        or _duplicates(item.scenario_key for item in bundle.runtime_results)
        or set(scenarios) != set(results)
        or any(item.target_key not in target_keys for item in scenarios.values())
    ):
        raise ValueError("runtime_result_mismatch")
    for key, scenario in scenarios.items():
        result = results[key]
        if (
            result.fixture_digest != scenario.fixture_digest
            or result.outcome not in {"pass", "fail"}
            or not result.result
        ):
            raise ValueError("runtime_result_mismatch")


def _validate_provenance(bundle, approval, separate_provenance):
    if bundle.provenance_digest != provenance_digest(bundle.provenance):
        raise ValueError("provenance_digest_mismatch")
    if bundle.provenance != separate_provenance:
        raise ValueError("provenance_snapshot_mismatch")
    expected_paths = {
        path for target in bundle.targets for path in target.dependency_closure
    }
    actual_paths = tuple(
        path for path, _ in bundle.provenance.source_digests
    )
    if (
        _duplicates(actual_paths)
        or set(actual_paths) != expected_paths
        or bundle.provenance.scope_revision != bundle.scope_revision
        or bundle.provenance.public_digest != bundle.public_digest
        or bundle.provenance.binding_digest != approval.binding_digest
    ):
        raise ValueError("provenance_source_set")
    if bundle.provenance.evidence != bundle.evidence:
        raise ValueError("staged_evidence_linkage")


def _validate_artifacts(bundle, candidate_artifacts):
    hashes = {item.key: item.digest for item in bundle.artifact_hashes}
    if (
        _duplicates(item.key for item in bundle.artifact_hashes)
        or set(hashes) != _ARTIFACT_KEYS
        or set(candidate_artifacts) != _ARTIFACT_KEYS
    ):
        raise ValueError("candidate_artifact_hash")
    for key, content in candidate_artifacts.items():
        if hashes[key] != hashlib.sha256(content).hexdigest():
            raise ValueError("candidate_artifact_hash")


def validate_staged_bundle(
    bundle,
    *,
    manifest,
    approval,
    selection,
    separate_provenance,
    candidate_artifacts,
) -> None:
    _validate_scope(bundle, manifest, approval)
    _validate_target_set(bundle, manifest, selection)
    _validate_evidence(bundle)
    _validate_targets(bundle, manifest, selection)
    _validate_blockers(bundle, manifest)
    _validate_runtime(
        bundle, {target.key for target in manifest.legacy_targets}
    )
    _validate_provenance(bundle, approval, separate_provenance)
    _validate_artifacts(bundle, candidate_artifacts)


def _atomic_json(path, value):
    fd, temporary = tempfile.mkstemp(prefix=".audit-bundle.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        if os.name == "posix":
            path.chmod(0o600)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def write_staged_bundle(state_root, bundle, *, public_repo):
    root = Path(state_root).resolve()
    public = Path(public_repo).resolve()
    if root == public or public in root.parents:
        raise ValueError("public_staged_path")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    staged = root / "staged"
    staged.mkdir(mode=0o700, exist_ok=True)
    if os.name == "posix":
        root.chmod(0o700)
        staged.chmod(0o700)
    _atomic_json(staged / "audit-bundle.json", asdict(bundle))


def load_staged_bundle(state_root):
    path = Path(state_root) / "staged" / "audit-bundle.json"
    if os.name == "posix":
        if path.parent.stat().st_mode & 0o077:
            raise ValueError("unsafe_staged_directory")
        if path.stat().st_mode & 0o077:
            raise ValueError("unsafe_staged_permissions")
    return parse_staged_bundle(path)


def with_issue_url(bundle, blocker_key, issue_url):
    if not issue_url.startswith(_ISSUE_PREFIX) or not issue_url[
        len(_ISSUE_PREFIX) :
    ].isdigit():
        raise ValueError("invalid_staged_issue_url")
    found = False
    blockers = []
    for blocker in bundle.blockers:
        if blocker.key == blocker_key:
            blocker = replace(blocker, issue_url=issue_url)
            found = True
        blockers.append(blocker)
    if not found:
        raise ValueError("unknown_staged_blocker")
    return replace(bundle, blockers=tuple(blockers))


def with_runtime_result(bundle, result):
    found = False
    results = []
    for prior in bundle.runtime_results:
        if prior.scenario_key == result.scenario_key:
            prior = result
            found = True
        results.append(prior)
    if not found:
        raise ValueError("unknown_runtime_scenario")
    return replace(bundle, runtime_results=tuple(results))


def with_refreshed_provenance(bundle, provenance):
    return replace(
        bundle,
        provenance=provenance,
        provenance_digest=provenance_digest(provenance),
        evidence=provenance.evidence,
    )
