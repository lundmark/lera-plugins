"""Public and full-private validation levels for legacy parity artifacts."""

from __future__ import annotations

import hashlib
import os
import subprocess
import tempfile
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from pathlib import Path

from .compare import strict_parity_findings, validate_evidence
from .current import (
    compare_mirror,
    discover_current,
    validate_code_ref,
    validate_current_scope,
)
from .legacy import (
    discover,
    executable_lua_lines,
    extract_xml_constructs,
    load_selection,
)
from .manifest import loads_manifest, render_manifest
from .privacy import assert_public_bytes, build_private_deny_tokens
from .publish import PUBLIC_PATHS
from .report import (
    PRIVATE_HEADING,
    PUBLIC_HEADING,
    PUBLIC_UNCHECKED,
    render_not_converted,
    render_parity_report,
    render_private_report,
    resolve_private_report_path,
)
from .scope import (
    binding_digest,
    canonical_bindings,
    canonical_scope,
    scope_digest,
)
from .staged import (
    load_staged_bundle,
    provenance_digest,
    validate_staged_bundle,
)
from .state import (
    load_approval,
    load_provenance,
    write_provenance_transaction,
    ProvenanceState,
)


class ValidationFailure(ValueError):
    """A completed validation gate found a parity inconsistency."""


@dataclass(frozen=True, slots=True)
class ValidationSummary:
    level: str
    text: str
    report_path: Path | None = None


@dataclass(frozen=True, slots=True)
class PrivateValidationRoots:
    repo_root: Path
    state_root: Path
    legacy_root: Path
    lera_root: Path

    def resolved(self):
        return PrivateValidationRoots(
            repo_root=Path(self.repo_root).resolve(),
            state_root=Path(self.state_root).resolve(),
            legacy_root=Path(self.legacy_root).resolve(),
            lera_root=Path(self.lera_root).resolve(),
        )


def _fail(code, error=None):
    if error is None:
        raise ValidationFailure(code)
    raise ValidationFailure(code) from error


def _read_public_artifacts(repo):
    artifacts = {}
    for key, relative in PUBLIC_PATHS.items():
        path = Path(repo) / relative
        try:
            artifacts[key] = path.read_bytes()
        except OSError as error:
            raise ValueError("missing_public_artifact") from error
    return artifacts


def _public_summary():
    lines = [
        PUBLIC_HEADING,
        "",
        "Not rechecked at the public validation level:",
    ]
    lines.extend(f"- {item}" for item in PUBLIC_UNCHECKED)
    return "\n".join(lines) + "\n"


def _validate_mapping_agreement(manifest):
    for current in manifest.current_plugins:
        derived = tuple(
            sorted(
                target.key
                for target in manifest.legacy_targets
                if current.key in target.current_plugins
            )
        )
        if tuple(sorted(current.target_keys)) != derived:
            _fail("public_mapping_mismatch")


def _validate_public_artifacts(repo_root, artifacts):
    repo = Path(repo_root).resolve()
    if not repo.is_dir():
        raise ValueError("missing_plugin_root")
    if set(artifacts) != set(PUBLIC_PATHS) or any(
        not isinstance(content, bytes) for content in artifacts.values()
    ):
        raise ValueError("invalid_public_artifacts")
    try:
        manifest = loads_manifest(artifacts["manifest"])
    except ValueError as error:
        _fail("public_manifest_invalid", error)
    if manifest.scope.digest != scope_digest(manifest):
        _fail("public_scope_digest_mismatch")
    if artifacts["manifest"] != render_manifest(manifest).encode("utf-8"):
        _fail("public_artifact_mismatch")
    try:
        inventory = discover_current(repo)
        validate_current_scope(inventory, manifest.current_plugins)
    except (OSError, ValueError) as error:
        _fail("public_current_inventory_mismatch", error)
    _validate_mapping_agreement(manifest)

    fixtures = tuple(
        fixture
        for current in manifest.current_plugins
        for fixture in current.fixtures
    )
    if len(fixtures) != len(set(fixtures)):
        _fail("public_fixture_declaration")
    current_paths = tuple(item.path for item in manifest.current_plugins)
    for target in manifest.legacy_targets:
        for feature in target.features:
            for reference in feature.current_refs:
                try:
                    validate_code_ref(repo, reference, current_paths)
                except (OSError, ValueError) as error:
                    _fail("public_current_reference", error)
            if validate_evidence(
                feature,
                target_key=target.key,
                capabilities=manifest.capabilities,
                public_fixtures=fixtures,
            ):
                _fail("public_evidence_mismatch")
    expected = {
        "manifest": render_manifest(manifest).encode("utf-8"),
        "not_converted": render_not_converted(manifest).encode("utf-8"),
        "parity_report": render_parity_report(manifest).encode("utf-8"),
    }
    if artifacts != expected:
        _fail("public_artifact_mismatch")
    try:
        assert_public_bytes(
            artifacts, allowed_hashes=(manifest.scope.digest,)
        )
    except ValueError as error:
        _fail("public_privacy_failure", error)
    return manifest


def validate_public(repo_root, *, require_parity=False):
    if require_parity:
        raise ValueError("require_parity_private_only")
    artifacts = _read_public_artifacts(repo_root)
    _validate_public_artifacts(repo_root, artifacts)
    return ValidationSummary(level="public", text=_public_summary())


def selection_bindings(selection):
    return {
        target.key: {
            source.path: {
                binding.feature_key: list(binding.construct_ids)
                for binding in source.bindings
            }
            for source in target.sources
            if source.bindings
        }
        for target in selection.included_targets
    }


def _approval_matches(approval, manifest, bindings):
    public = canonical_scope(manifest).decode("utf-8")
    private = canonical_bindings(bindings).decode("utf-8")
    return (
        approval.revision == manifest.scope.revision
        and approval.public_scope == public
        and approval.public_digest == scope_digest(manifest)
        and approval.binding_digest == binding_digest(bindings)
        and approval.private_bindings == private
    )


def _git_commit(root):
    result = subprocess.run(
        ("git", "-C", str(root), "rev-parse", "HEAD"),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=10,
        check=False,
    )
    if result.returncode != 0:
        raise ValueError("legacy_provenance_unavailable")
    value = result.stdout.strip()
    if len(value) not in {40, 64} or any(
        character not in "0123456789abcdef" for character in value
    ):
        raise ValueError("legacy_provenance_unavailable")
    return value


def _actual_source_digests(bundle, legacy_root):
    root = Path(legacy_root).resolve()
    paths = tuple(
        sorted(
            {
                path
                for target in bundle.targets
                for path in target.dependency_closure
            }
        )
    )
    digests = []
    for relative in paths:
        candidate = (root / relative).resolve()
        try:
            candidate.relative_to(root)
        except ValueError as error:
            raise ValueError("invalid_legacy_path") from error
        if not candidate.is_file():
            raise ValueError("missing_legacy_path")
        digests.append(
            (relative, hashlib.sha256(candidate.read_bytes()).hexdigest())
        )
    return tuple(digests)


def _construct_ids(source, relative):
    if relative.endswith(".xml"):
        return tuple(
            item.id for item in extract_xml_constructs(source, relative)
        )
    if relative.endswith(".lua"):
        return tuple(
            f"lua:{relative}:{line}"
            for line in executable_lua_lines(
                source.read_text(encoding="utf-8")
            )
        )
    raise ValueError("invalid_legacy_path")


def _validate_construct_snapshots(bundle, legacy_root, selection):
    root = Path(legacy_root).resolve()
    selected_targets = {
        target.key: target for target in selection.included_targets
    }
    for target in bundle.targets:
        selected_target = selected_targets.get(target.key)
        if selected_target is None:
            _fail("legacy_construct_drift")
        selected_sources = {
            source.path: source for source in selected_target.sources
        }
        for inventory in target.construct_inventory:
            selected_source = selected_sources.get(inventory.source_path)
            if selected_source is None:
                _fail("legacy_construct_drift")
            source = (root / inventory.source_path).resolve()
            extracted_ids = _construct_ids(source, inventory.source_path)
            if selected_source.coverage == "complete":
                expected_ids = extracted_ids
            elif selected_source.coverage == "selected":
                approved_ids = {
                    construct_id
                    for binding in selected_source.bindings
                    for construct_id in binding.construct_ids
                }
                if not approved_ids.issubset(extracted_ids):
                    _fail("legacy_construct_drift")
                expected_ids = tuple(
                    construct_id
                    for construct_id in extracted_ids
                    if construct_id in approved_ids
                )
            else:
                _fail("legacy_construct_drift")
            if expected_ids != inventory.construct_ids:
                _fail("legacy_construct_drift")


def _validate_runtime(bundle, manifest, lera_bin):
    binary = Path(lera_bin).resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError("missing_lera_binary")
    fixtures = {
        value
        for current in manifest.current_plugins
        for value in current.fixtures
    }
    if any(
        result.outcome != "pass" for result in bundle.runtime_results
    ):
        _fail("runtime_failure")
    if any(
        scenario.fixture_key not in fixtures
        for scenario in bundle.runtime_scenarios
    ):
        _fail("runtime_fixture_mismatch")


def _validate_issue_links(bundle, manifest):
    capabilities = {
        item.key: item.issue_url for item in manifest.capabilities
    }
    if any(
        blocker.issue_url is None
        or capabilities.get(blocker.key) != blocker.issue_url
        for blocker in bundle.blockers
    ):
        _fail("unresolved_blocker")


def _write_private_report(path, content):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
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


def _validate_private(
    *,
    roots,
    lera_bin,
    artifacts,
    bundle,
    require_parity,
    refresh_legacy,
    verified_at,
):
    roots = roots.resolved()
    for value, code in (
        (roots.repo_root, "missing_plugin_root"),
        (roots.state_root, "missing_private_state"),
        (roots.legacy_root, "missing_legacy_root"),
        (roots.lera_root, "missing_lera_root"),
    ):
        if not value.is_dir():
            raise ValueError(code)
    manifest = _validate_public_artifacts(roots.repo_root, artifacts)
    try:
        approval = load_approval(roots.state_root)
        selection = load_selection(roots.state_root)
    except (OSError, ValueError) as error:
        raise ValueError("missing_private_approval") from error
    bindings = selection_bindings(selection)
    if not _approval_matches(approval, manifest, bindings):
        _fail("missing_private_approval")
    loaded_bundle = load_staged_bundle(roots.state_root)
    if bundle is None:
        bundle = loaded_bundle
    elif bundle != loaded_bundle:
        _fail("staged_bundle_mismatch")
    if require_parity:
        strict = strict_parity_findings(
            target
            for target in bundle.targets
        )
        if strict:
            _fail(strict[0].code)

    _validate_construct_snapshots(
        bundle, roots.legacy_root, selection
    )
    if refresh_legacy and discover(roots.legacy_root, selection):
        _fail("unapproved_legacy_candidate")

    if refresh_legacy:
        refreshed = ProvenanceState(
            version=1,
            scope_revision=bundle.scope_revision,
            public_digest=bundle.public_digest,
            binding_digest=approval.binding_digest,
            legacy_commit=_git_commit(roots.legacy_root),
            source_digests=_actual_source_digests(
                bundle, roots.legacy_root
            ),
            evidence=bundle.evidence,
            refreshed_at=verified_at,
        )
        bundle = replace(
            bundle,
            provenance=refreshed,
            provenance_digest=provenance_digest(refreshed),
            evidence=refreshed.evidence,
        )
        separate_provenance = refreshed
    else:
        try:
            separate_provenance = load_provenance(roots.state_root)
        except (OSError, ValueError) as error:
            raise ValueError("missing_private_provenance") from error

    try:
        validate_staged_bundle(
            bundle,
            manifest=manifest,
            approval=approval,
            selection=selection,
            separate_provenance=separate_provenance,
            candidate_artifacts=artifacts,
        )
    except ValueError as error:
        _fail(str(error), error)
    actual_digests = _actual_source_digests(bundle, roots.legacy_root)
    if (
        separate_provenance.source_digests != actual_digests
        or separate_provenance.legacy_commit
        != _git_commit(roots.legacy_root)
    ):
        _fail("legacy_source_drift")
    if compare_mirror(roots.repo_root, roots.lera_root / "plugins"):
        _fail("current_mirror_mismatch")
    _validate_runtime(bundle, manifest, lera_bin)
    _validate_issue_links(bundle, manifest)
    deny_tokens = build_private_deny_tokens(
        selection,
        separate_provenance,
        approved_public_scope=approval.public_scope,
        private_roots=(
            roots.state_root,
            roots.legacy_root,
            roots.lera_root,
        ),
    )
    try:
        assert_public_bytes(
            artifacts,
            deny_tokens=deny_tokens,
            allowed_hashes=(manifest.scope.digest,),
        )
    except ValueError as error:
        _fail("privacy_violation", error)
    if refresh_legacy:
        write_provenance_transaction(
            roots.state_root, separate_provenance, bundle
        )
    return manifest, bundle


def validate_full_private(
    *,
    roots,
    lera_bin,
    require_parity=False,
    refresh_legacy=False,
    private_report=None,
    verified_at=None,
):
    roots = roots.resolved()
    verified_at = verified_at or datetime.now(timezone.utc).isoformat()
    artifacts = _read_public_artifacts(roots.repo_root)
    manifest, _ = _validate_private(
        roots=roots,
        lera_bin=lera_bin,
        artifacts=artifacts,
        bundle=None,
        require_parity=require_parity,
        refresh_legacy=refresh_legacy,
        verified_at=verified_at,
    )
    report_path = resolve_private_report_path(
        roots.state_root, roots.repo_root, private_report
    )
    report = render_private_report(
        manifest, verified_at=verified_at
    )
    _write_private_report(report_path, report)
    return ValidationSummary(
        level="full-private", text=report, report_path=report_path
    )


def full_private_publication_gate(
    candidate,
    staged_bundle,
    roots,
    lera_bin,
    *,
    require_parity=False,
):
    _validate_private(
        roots=roots,
        lera_bin=lera_bin,
        artifacts=dict(candidate.artifacts),
        bundle=staged_bundle,
        require_parity=require_parity,
        refresh_legacy=False,
        verified_at=datetime.now(timezone.utc).isoformat(),
    )
