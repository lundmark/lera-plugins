import json
import os
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass(frozen=True)
class FeatureBinding:
    feature_key: str
    construct_ids: tuple[str, ...]


@dataclass(frozen=True)
class SelectedSource:
    kind: str
    path: str
    coverage: str
    feature_keys: tuple[str, ...]
    bindings: tuple[FeatureBinding, ...]


@dataclass(frozen=True)
class IncludedTarget:
    key: str
    sources: tuple[SelectedSource, ...]
    current_plugins: tuple[str, ...]


@dataclass(frozen=True)
class SelectionState:
    version: int
    included_targets: tuple[IncludedTarget, ...]
    omitted_candidates: tuple[str, ...]


def _relative_file(root, relative):
    root = Path(root).resolve()
    if not isinstance(relative, str) or not relative or "\\" in relative:
        raise ValueError("invalid_legacy_path")
    candidate = (root / relative).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as error:
        raise ValueError("invalid_legacy_path") from error
    if not candidate.is_file():
        raise ValueError("missing_legacy_path")
    return candidate


def discover(legacy_root, selection, revisit_omitted=False):
    root = Path(legacy_root).resolve()
    used = {
        source.path
        for target in selection.included_targets
        for source in target.sources
        if source.kind == "xml"
    }
    omitted = set(selection.omitted_candidates)
    found = []
    for candidate in (root / "plugins").rglob("*.xml"):
        resolved = candidate.resolve()
        try:
            relative = resolved.relative_to(root).as_posix()
        except ValueError:
            continue
        if candidate.is_symlink() and resolved != candidate:
            try:
                resolved.relative_to(root)
            except ValueError:
                continue
        if not resolved.is_file() or relative in used:
            continue
        if not revisit_omitted and relative in omitted:
            continue
        found.append(relative)
    return tuple(sorted(set(found)))


def record_omitted_candidate(selection, path, legacy_root):
    _relative_file(legacy_root, path)
    if not path.endswith(".xml"):
        raise ValueError("omitted_candidate_not_xml")
    omitted = tuple(sorted(set(selection.omitted_candidates) | {path}))
    return SelectionState(
        version=selection.version,
        included_targets=selection.included_targets,
        omitted_candidates=omitted,
    )


def _validate_source(source, legacy_root):
    _relative_file(legacy_root, source.path)
    if source.kind not in {"xml", "lua"}:
        raise ValueError("invalid_source_kind")
    if source.kind == "xml" and not source.path.endswith(".xml"):
        raise ValueError("invalid_source_extension")
    if source.kind == "lua" and not source.path.endswith(".lua"):
        raise ValueError("invalid_source_extension")
    if source.coverage == "complete":
        if source.feature_keys or source.bindings:
            raise ValueError("complete_source_with_bindings")
        return
    if source.coverage != "selected" or not source.feature_keys:
        raise ValueError("invalid_selected_source")
    if len(source.feature_keys) != len(set(source.feature_keys)):
        raise ValueError("duplicate_selected_feature")
    binding_keys = tuple(binding.feature_key for binding in source.bindings)
    if set(binding_keys) != set(source.feature_keys):
        raise ValueError("incomplete_selected_bindings")
    if len(binding_keys) != len(set(binding_keys)):
        raise ValueError("duplicate_selected_binding")
    construct_ids = [
        construct
        for binding in source.bindings
        for construct in binding.construct_ids
    ]
    if not construct_ids or len(construct_ids) != len(set(construct_ids)):
        raise ValueError("invalid_selected_constructs")


def record_included_target(
    selection,
    target,
    legacy_root,
    *,
    current_keys,
):
    if selection.version != 1 or not target.key:
        raise ValueError("invalid_selection")
    if target.key in {item.key for item in selection.included_targets}:
        raise ValueError("duplicate_target_key")
    if not target.sources:
        raise ValueError("target_without_sources")
    if not any(source.kind == "xml" for source in target.sources):
        raise ValueError("target_without_xml")
    source_ids = tuple((source.kind, source.path) for source in target.sources)
    if len(source_ids) != len(set(source_ids)):
        raise ValueError("duplicate_target_source")
    if len(target.current_plugins) != len(set(target.current_plugins)):
        raise ValueError("duplicate_current_mapping")
    if any(key not in current_keys for key in target.current_plugins):
        raise ValueError("unknown_current_mapping")

    for source in target.sources:
        _validate_source(source, legacy_root)

    existing = {}
    for prior_target in selection.included_targets:
        for source in prior_target.sources:
            existing.setdefault((source.kind, source.path), []).append(source)

    for source in target.sources:
        prior_sources = existing.get((source.kind, source.path), ())
        for prior in prior_sources:
            if source.coverage == "complete" or prior.coverage == "complete":
                raise ValueError("complete_source_reuse")
            current_constructs = {
                construct
                for binding in source.bindings
                for construct in binding.construct_ids
            }
            prior_constructs = {
                construct
                for binding in prior.bindings
                for construct in binding.construct_ids
            }
            if current_constructs & prior_constructs:
                raise ValueError("overlapping_binding")

    targets = tuple(
        sorted(
            selection.included_targets + (target,),
            key=lambda item: item.key,
        )
    )
    omitted = tuple(
        path
        for path in selection.omitted_candidates
        if path not in {
            source.path for source in target.sources if source.kind == "xml"
        }
    )
    return SelectionState(
        version=selection.version,
        included_targets=targets,
        omitted_candidates=omitted,
    )


def _atomic_json(path, value):
    fd, temporary = tempfile.mkstemp(prefix=".selection.", dir=path.parent)
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


def write_selection(state_root, selection, *, public_repo):
    root = Path(state_root).resolve()
    public = Path(public_repo).resolve()
    if root == public or public in root.parents:
        raise ValueError("public_selection_path")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if os.name == "posix":
        root.chmod(0o700)
    _atomic_json(root / "selection.json", asdict(selection))


def load_selection(state_root):
    path = Path(state_root) / "selection.json"
    if os.name == "posix" and path.stat().st_mode & 0o077:
        raise ValueError("unsafe_selection_permissions")
    value = json.loads(path.read_text(encoding="utf-8"))
    targets = []
    for target in value["included_targets"]:
        sources = []
        for source in target["sources"]:
            bindings = tuple(
                FeatureBinding(
                    feature_key=binding["feature_key"],
                    construct_ids=tuple(binding["construct_ids"]),
                )
                for binding in source["bindings"]
            )
            sources.append(
                SelectedSource(
                    kind=source["kind"],
                    path=source["path"],
                    coverage=source["coverage"],
                    feature_keys=tuple(source["feature_keys"]),
                    bindings=bindings,
                )
            )
        targets.append(
            IncludedTarget(
                key=target["key"],
                sources=tuple(sources),
                current_plugins=tuple(target["current_plugins"]),
            )
        )
    return SelectionState(
        version=value["version"],
        included_targets=tuple(targets),
        omitted_candidates=tuple(value["omitted_candidates"]),
    )


def included_target_from_dict(value):
    if set(value) != {"key", "sources", "current_plugins"}:
        raise ValueError("invalid_target_record")
    sources = []
    for source in value["sources"]:
        if set(source) != {
            "kind",
            "path",
            "coverage",
            "feature_keys",
            "bindings",
        }:
            raise ValueError("invalid_source_record")
        bindings = tuple(
            FeatureBinding(
                feature_key=binding["feature_key"],
                construct_ids=tuple(binding["construct_ids"]),
            )
            for binding in source["bindings"]
        )
        sources.append(
            SelectedSource(
                kind=source["kind"],
                path=source["path"],
                coverage=source["coverage"],
                feature_keys=tuple(source["feature_keys"]),
                bindings=bindings,
            )
        )
    return IncludedTarget(
        key=value["key"],
        sources=tuple(sources),
        current_plugins=tuple(value["current_plugins"]),
    )
