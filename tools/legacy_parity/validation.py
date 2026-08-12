"""Public and full-private validation levels for legacy parity artifacts."""

from __future__ import annotations

import hashlib
import os
import stat
import subprocess
import tempfile
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

from .compare import strict_parity_findings, validate_evidence
from .current import (
    compare_mirror,
    discover_current,
    validate_code_ref,
    validate_current_scope,
)
from .legacy import (
    XmlCompatibility,
    _escape_raw_attribute_lt,
    discover,
    executable_lua_lines,
    extract_xml_constructs,
    extract_xml_constructs_bytes,
    load_selection,
)
from .manifest import loads_manifest, render_manifest
from .privacy import assert_public_bytes, build_private_deny_tokens
from .publish import (
    PUBLIC_PATHS,
    _open_directory_root,
    _read_public_optional,
    _verify_directory_root,
)
from .report import (
    PRIVATE_HEADING,
    PUBLIC_HEADING,
    PUBLIC_UNCHECKED,
    render_not_converted,
    render_parity_report,
    render_private_report,
    resolve_private_report_path,
)
from .runtime import loads_scenario, run_scenario, valid_scenario_key
from .scope import (
    binding_digest,
    canonical_bindings,
    canonical_scope,
    scope_digest,
)
from .staged import (
    RuntimeResult,
    load_staged_bundle,
    provenance_digest,
    validate_staged_bundle,
)
from .state import (
    _write_private_child_bytes,
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
            repo_root=Path(os.path.abspath(os.fspath(self.repo_root))),
            state_root=Path(os.path.abspath(os.fspath(self.state_root))),
            legacy_root=Path(os.path.abspath(os.fspath(self.legacy_root))),
            lera_root=Path(os.path.abspath(os.fspath(self.lera_root))),
        )


def _fail(code, error=None):
    if error is None:
        raise ValidationFailure(code)
    raise ValidationFailure(code) from error


def _read_public_artifacts(repo):
    root, root_descriptor, root_identity = _open_directory_root(repo)
    validation_descriptor = None
    try:
        validation_descriptor = os.open(
            "validation", _HELD_DIRECTORY_FLAGS, dir_fd=root_descriptor
        )
        validation_record = os.fstat(validation_descriptor)
        validation_identity = (
            validation_record.st_dev,
            validation_record.st_ino,
        )
        artifacts = {}
        for key, relative in PUBLIC_PATHS.items():
            content, identity = _read_public_optional(
                validation_descriptor, relative.name
            )
            if content is None or identity is None:
                raise ValueError("missing_public_artifact")
            artifacts[key] = content
        _verify_directory_root(root, root_identity)
        current = os.open(
            "validation", _HELD_DIRECTORY_FLAGS, dir_fd=root_descriptor
        )
        try:
            record = os.fstat(current)
            if (record.st_dev, record.st_ino) != validation_identity:
                raise ValueError("unsafe_publication_path")
        finally:
            os.close(current)
        return artifacts
    except FileNotFoundError as error:
        raise ValueError("missing_public_artifact") from error
    except OSError as error:
        raise ValueError("unsafe_publication_path") from error
    finally:
        if validation_descriptor is not None:
            os.close(validation_descriptor)
        os.close(root_descriptor)


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
    repo = Path(os.path.abspath(os.fspath(repo_root)))
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


_HELD_DIRECTORY_FLAGS = (
    os.O_RDONLY
    | getattr(os, "O_DIRECTORY", 0)
    | getattr(os, "O_CLOEXEC", 0)
    | getattr(os, "O_NOFOLLOW", 0)
)
_HELD_FILE_FLAGS = (
    os.O_RDONLY
    | getattr(os, "O_CLOEXEC", 0)
    | getattr(os, "O_NOFOLLOW", 0)
)


def _descriptor_bytes(descriptor):
    os.lseek(descriptor, 0, os.SEEK_SET)
    chunks = []
    while True:
        chunk = os.read(descriptor, 65536)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)


def _open_held_root(path):
    root = Path(os.path.abspath(os.fspath(path)))
    descriptor = os.open(os.sep, _HELD_DIRECTORY_FLAGS)
    try:
        for part in root.parts[1:]:
            next_descriptor = os.open(
                part, _HELD_DIRECTORY_FLAGS, dir_fd=descriptor
            )
            os.close(descriptor)
            descriptor = next_descriptor
        record = os.fstat(descriptor)
        if not stat.S_ISDIR(record.st_mode):
            raise ValueError("unsafe_source_path")
        return root, descriptor, (record.st_dev, record.st_ino)
    except BaseException:
        os.close(descriptor)
        raise


def _verify_held_root(path, expected):
    _, descriptor, identity = _open_held_root(path)
    try:
        if identity != expected:
            raise ValueError("unsafe_source_path")
    finally:
        os.close(descriptor)


def _relative_parts(relative):
    if (
        not isinstance(relative, str)
        or not relative
        or relative.startswith("/")
        or "\\" in relative
    ):
        raise ValueError("invalid_source_path")
    parts = PurePosixPath(relative).parts
    if not parts or any(part in {"", ".", ".."} for part in parts):
        raise ValueError("invalid_source_path")
    return parts


def _read_held_relative(root_descriptor, relative):
    parts = _relative_parts(relative)
    directory = os.dup(root_descriptor)
    try:
        for part in parts[:-1]:
            next_directory = os.open(
                part, _HELD_DIRECTORY_FLAGS, dir_fd=directory
            )
            os.close(directory)
            directory = next_directory
        before = os.stat(parts[-1], dir_fd=directory, follow_symlinks=False)
        descriptor = os.open(
            parts[-1], _HELD_FILE_FLAGS, dir_fd=directory
        )
        try:
            record = os.fstat(descriptor)
            identity = (record.st_dev, record.st_ino)
            if (
                not stat.S_ISREG(record.st_mode)
                or identity != (before.st_dev, before.st_ino)
            ):
                raise ValueError("unsafe_source_path")
            content = _descriptor_bytes(descriptor)
            after = os.stat(
                parts[-1], dir_fd=directory, follow_symlinks=False
            )
            if identity != (after.st_dev, after.st_ino):
                raise ValueError("unsafe_source_path")
            return content
        finally:
            os.close(descriptor)
    finally:
        os.close(directory)


def _capture_relative_files(root_path, relatives):
    root, descriptor, identity = _open_held_root(root_path)
    try:
        captured = {
            relative: _read_held_relative(descriptor, relative)
            for relative in sorted(set(relatives))
        }
        _verify_held_root(root, identity)
        return captured
    except OSError as error:
        raise ValueError("unsafe_source_path") from error
    finally:
        os.close(descriptor)


def _capture_current_sources(root_path):
    root, descriptor, identity = _open_held_root(root_path)
    try:
        names = []
        for directory_name in ("generic", "3scapes"):
            try:
                directory = os.open(
                    directory_name,
                    _HELD_DIRECTORY_FLAGS,
                    dir_fd=descriptor,
                )
            except FileNotFoundError:
                continue
            try:
                for name in os.listdir(directory):
                    if not name.endswith(".lua"):
                        continue
                    record = os.stat(
                        name, dir_fd=directory, follow_symlinks=False
                    )
                    if not stat.S_ISREG(record.st_mode):
                        raise ValueError("unsafe_source_path")
                    names.append(f"{directory_name}/{name}")
            finally:
                os.close(directory)
        captured = {
            relative: _read_held_relative(descriptor, relative)
            for relative in sorted(names)
        }
        _verify_held_root(root, identity)
        return captured
    except OSError as error:
        raise ValueError("unsafe_source_path") from error
    finally:
        os.close(descriptor)


def _open_held_executable(path):
    absolute = Path(os.path.abspath(os.fspath(path)))
    root, directory, _ = _open_held_root(absolute.parent)
    del root
    try:
        before = os.stat(
            absolute.name, dir_fd=directory, follow_symlinks=False
        )
        descriptor = os.open(
            absolute.name, _HELD_FILE_FLAGS, dir_fd=directory
        )
        record = os.fstat(descriptor)
        if (
            not stat.S_ISREG(record.st_mode)
            or (record.st_dev, record.st_ino)
            != (before.st_dev, before.st_ino)
            or not (record.st_mode & 0o111)
        ):
            os.close(descriptor)
            raise ValueError("missing_lera_binary")
        return descriptor
    finally:
        os.close(directory)


def _legacy_snapshots(bundle, legacy_root):
    paths = {
        path
        for target in bundle.targets
        for path in target.dependency_closure
    }
    try:
        return _capture_relative_files(legacy_root, paths)
    except ValueError as error:
        if str(error) == "unsafe_source_path":
            _fail("legacy_xml_extraction_failed", error)
        raise


def _actual_source_digests(bundle, snapshots):
    expected = {
        path
        for target in bundle.targets
        for path in target.dependency_closure
    }
    if set(snapshots) != expected:
        raise ValueError("legacy_source_drift")
    return tuple(
        (relative, hashlib.sha256(snapshots[relative]).hexdigest())
        for relative in sorted(expected)
    )


def _construct_ids(source_bytes, relative, expected_digest=None):
    if not isinstance(source_bytes, bytes):
        raise ValueError("legacy_construct_drift")
    if relative.endswith(".xml"):
        try:
            constructs = extract_xml_constructs_bytes(
                source_bytes, relative
            )
        except ValidationFailure:
            if expected_digest is None:
                raise
            constructs = extract_xml_constructs_bytes(
                source_bytes,
                relative,
                compatibility=XmlCompatibility(
                    expected_relative_path=relative,
                    expected_sha256=expected_digest,
                    normalizer=_escape_raw_attribute_lt,
                ),
            )
        return tuple(item.id for item in constructs)
    if relative.endswith(".lua"):
        try:
            text = source_bytes.decode("utf-8")
        except UnicodeDecodeError as error:
            raise ValueError("legacy_construct_drift") from error
        return tuple(
            f"lua:{relative}:{line}"
            for line in executable_lua_lines(text)
        )
    raise ValueError("invalid_legacy_path")


def _validate_construct_snapshots(bundle, snapshots, selection):
    if not isinstance(snapshots, dict):
        snapshots = _legacy_snapshots(bundle, snapshots)
    selected_targets = {
        target.key: target for target in selection.included_targets
    }
    source_digests = dict(bundle.provenance.source_digests)
    for target in bundle.targets:
        selected_target = selected_targets.get(target.key)
        if selected_target is None:
            _fail("legacy_construct_drift")
        selected_sources = {
            source.path: source for source in selected_target.sources
        }
        for inventory in target.construct_inventory:
            selected_source = selected_sources.get(inventory.source_path)
            source_bytes = snapshots.get(inventory.source_path)
            if selected_source is None or source_bytes is None:
                _fail("legacy_construct_drift")
            extracted_ids = _construct_ids(
                source_bytes,
                inventory.source_path,
                source_digests.get(inventory.source_path),
            )
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


def _read_descriptor(descriptor):
    chunks = []
    while True:
        chunk = os.read(descriptor, 65536)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)


def _private_directory(descriptor):
    mode = os.fstat(descriptor).st_mode
    if (
        not stat.S_ISDIR(mode)
        or stat.S_IMODE(mode) != 0o700
    ):
        raise ValueError("unsafe_runtime_fixture")


def _read_runtime_scenario_posix(state, filename):
    descriptors = []
    try:
        directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        state_descriptor = os.open(state, directory_flags)
        descriptors.append(state_descriptor)
        _private_directory(state_descriptor)
        staged_descriptor = os.open(
            "staged", directory_flags, dir_fd=state_descriptor
        )
        descriptors.append(staged_descriptor)
        _private_directory(staged_descriptor)
        runtime_descriptor = os.open(
            "runtime", directory_flags, dir_fd=staged_descriptor
        )
        descriptors.append(runtime_descriptor)
        _private_directory(runtime_descriptor)
        file_flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
        file_descriptor = os.open(
            filename, file_flags, dir_fd=runtime_descriptor
        )
        descriptors.append(file_descriptor)
        mode = os.fstat(file_descriptor).st_mode
        if (
            not stat.S_ISREG(mode)
            or stat.S_IMODE(mode) != 0o600
        ):
            raise ValueError("unsafe_runtime_fixture")
        return _read_descriptor(file_descriptor)
    finally:
        for descriptor in reversed(descriptors):
            try:
                os.close(descriptor)
            except OSError:
                pass


def _read_runtime_scenario_fallback(state, filename):
    staged = state / "staged"
    runtime = state / "staged" / "runtime"
    candidate = runtime / filename
    descriptor = None
    try:
        if (
            staged.is_symlink()
            or runtime.is_symlink()
            or candidate.is_symlink()
        ):
            raise ValueError("unsafe_runtime_fixture")
        resolved_runtime = runtime.resolve(strict=True)
        resolved_candidate = candidate.resolve(strict=True)
        resolved_candidate.relative_to(resolved_runtime)
        if (
            resolved_runtime != runtime
            or resolved_candidate.parent != resolved_runtime
            or not resolved_candidate.is_file()
        ):
            raise ValueError("unsafe_runtime_fixture")
        descriptor = os.open(
            resolved_candidate,
            os.O_RDONLY | getattr(os, "O_BINARY", 0),
        )
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError("unsafe_runtime_fixture")
        return _read_descriptor(descriptor)
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass


def _runtime_scenario_bytes(state_root, fixture_key):
    if not valid_scenario_key(fixture_key):
        _fail("runtime_fixture_mismatch")
    state = Path(state_root).resolve()
    filename = f"{fixture_key}.json"
    try:
        if os.name == "posix":
            return _read_runtime_scenario_posix(state, filename)
        return _read_runtime_scenario_fallback(state, filename)
    except (OSError, RuntimeError, ValueError) as error:
        _fail("runtime_fixture_mismatch", error)


def _validate_runtime(
    bundle,
    manifest,
    selection,
    roots,
    lera_bin,
    current_snapshots,
):
    binary = Path(os.path.abspath(os.fspath(lera_bin)))
    binary_descriptor = _open_held_executable(binary)
    manifest_targets = {
        target.key: target for target in manifest.legacy_targets
    }
    selected_targets = {
        target.key: target for target in selection.included_targets
    }
    bundle_targets = {target.key: target for target in bundle.targets}
    current_plugins = {
        current.key: current for current in manifest.current_plugins
    }
    stored_results = {
        result.scenario_key: result for result in bundle.runtime_results
    }
    try:
        _validate_runtime_cases(
            bundle,
            manifest_targets,
            selected_targets,
            bundle_targets,
            current_plugins,
            stored_results,
            roots,
            binary,
            binary_descriptor,
            current_snapshots,
        )
    finally:
        os.close(binary_descriptor)


def _validate_runtime_cases(
    bundle,
    manifest_targets,
    selected_targets,
    bundle_targets,
    current_plugins,
    stored_results,
    roots,
    binary,
    binary_descriptor,
    current_snapshots,
):
    for staged_scenario in bundle.runtime_scenarios:
        content = _runtime_scenario_bytes(
            roots.state_root, staged_scenario.fixture_key
        )
        fixture_digest = hashlib.sha256(content).hexdigest()
        if fixture_digest != staged_scenario.fixture_digest:
            _fail("runtime_fixture_mismatch")
        try:
            scenario = loads_scenario(content)
        except (TypeError, ValueError) as error:
            _fail("runtime_fixture_mismatch", error)
        if (
            scenario.key != staged_scenario.key
            or scenario.target_key != staged_scenario.target_key
        ):
            _fail("runtime_fixture_mismatch")

        manifest_target = manifest_targets.get(staged_scenario.target_key)
        selected_target = selected_targets.get(staged_scenario.target_key)
        bundle_target = bundle_targets.get(staged_scenario.target_key)
        if (
            manifest_target is None
            or selected_target is None
            or bundle_target is None
        ):
            _fail("runtime_fixture_mismatch")
        approved_keys = tuple(sorted(manifest_target.current_plugins))
        if (
            approved_keys
            != tuple(sorted(selected_target.current_plugins))
            or approved_keys != tuple(sorted(bundle_target.current_plugins))
        ):
            _fail("runtime_fixture_mismatch")
        try:
            approved_current = tuple(
                current_plugins[key] for key in approved_keys
            )
        except KeyError as error:
            _fail("runtime_fixture_mismatch", error)
        matching_current = tuple(
            current
            for current in approved_current
            if current.path == scenario.plugin
            and staged_scenario.target_key in current.target_keys
            and staged_scenario.fixture_key in current.fixtures
        )
        if not matching_current:
            _fail("runtime_fixture_mismatch")

        try:
            outcome = run_scenario(
                binary,
                roots.repo_root,
                scenario,
                plugin_bytes=current_snapshots[scenario.plugin],
                binary_descriptor=binary_descriptor,
            )
        except (OSError, RuntimeError, ValueError) as error:
            _fail("runtime_failure", error)
        if outcome.exit_code != 0:
            _fail("runtime_failure")
        fresh_result = RuntimeResult(
            scenario_key=staged_scenario.key,
            outcome="pass",
            fixture_digest=fixture_digest,
            result="Scenario passed.",
        )
        if stored_results.get(staged_scenario.key) != fresh_result:
            _fail("runtime_result_mismatch")


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


def _write_private_report(state_root, path, content):
    state = Path(os.path.abspath(os.fspath(state_root)))
    expected = state / "reports" / "full-private-report.md"
    if Path(os.path.abspath(os.fspath(path))) != expected:
        raise ValueError("unsafe_private_report_path")
    _write_private_child_bytes(
        state_root,
        "reports",
        "full-private-report.md",
        content.encode("utf-8"),
    )


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
    legacy_snapshots = _legacy_snapshots(bundle, roots.legacy_root)
    _validate_construct_snapshots(
        bundle, legacy_snapshots, selection
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
                bundle, legacy_snapshots
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
    actual_digests = _actual_source_digests(bundle, legacy_snapshots)
    if (
        separate_provenance.source_digests != actual_digests
        or separate_provenance.legacy_commit
        != _git_commit(roots.legacy_root)
    ):
        _fail("legacy_source_drift")
    current_snapshots = _capture_current_sources(roots.repo_root)
    mirror_snapshots = _capture_current_sources(
        roots.lera_root / "plugins"
    )
    expected_current = {item.path for item in manifest.current_plugins}
    if (
        set(current_snapshots) != expected_current
        or set(mirror_snapshots) != expected_current
        or current_snapshots != mirror_snapshots
    ):
        _fail("current_mirror_mismatch")
    for target in manifest.legacy_targets:
        for feature in target.features:
            for reference in feature.current_refs:
                relative, line_number = reference.rsplit(":", 1)
                content = current_snapshots.get(relative)
                try:
                    lines = content.decode("utf-8").splitlines()
                except (AttributeError, UnicodeDecodeError) as error:
                    _fail("public_current_reference", error)
                if int(line_number) > len(lines):
                    _fail("public_current_reference")
    _validate_runtime(
        bundle,
        manifest,
        selection,
        roots,
        lera_bin,
        current_snapshots,
    )
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
    if require_parity:
        strict = strict_parity_findings(
            target
            for target in bundle.targets
        )
        if strict:
            _fail(strict[0].code)
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
    _write_private_report(roots.state_root, report_path, report)
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
