import hashlib
import json
from pathlib import PurePosixPath


def _normalize_path(value):
    if not isinstance(value, str):
        raise ValueError("invalid_scope_path")
    if (
        not value
        or "\\" in value
        or value.startswith("/")
        or value.endswith("/")
        or "//" in value
    ):
        raise ValueError("invalid_scope_path")
    path = PurePosixPath(value)
    if any(part in {"", ".", ".."} for part in path.parts):
        raise ValueError("invalid_scope_path")
    return value


def _duplicates(values):
    return len(values) != len(set(values))


def _scope_object(manifest):
    current_plugins = []
    current_keys = set()
    for current in sorted(manifest.current_plugins, key=lambda item: item.key):
        if current.key in current_keys:
            raise ValueError("duplicate_current_key")
        current_keys.add(current.key)
        current_plugins.append(
            {"key": current.key, "path": _normalize_path(current.path)}
        )

    legacy_targets = []
    target_keys = set()
    for target in sorted(manifest.legacy_targets, key=lambda item: item.key):
        if target.key in target_keys:
            raise ValueError("duplicate_target_key")
        target_keys.add(target.key)
        mappings = sorted(target.current_plugins)
        if _duplicates(mappings) or any(
            mapping not in current_keys for mapping in mappings
        ):
            raise ValueError("invalid_current_mapping")

        sources = []
        source_ids = set()
        for source in sorted(
            target.sources, key=lambda item: (item.kind, item.path)
        ):
            path = _normalize_path(source.path)
            source_id = (source.kind, path)
            if source_id in source_ids:
                raise ValueError("duplicate_target_source")
            source_ids.add(source_id)
            feature_keys = sorted(source.feature_keys)
            if _duplicates(feature_keys):
                raise ValueError("duplicate_source_feature")
            if source.coverage == "complete" and feature_keys:
                raise ValueError("complete_source_with_features")
            if source.coverage == "selected" and not feature_keys:
                raise ValueError("selected_source_without_features")
            if source.coverage not in {"complete", "selected"}:
                raise ValueError("invalid_source_coverage")
            if source.kind not in {"xml", "lua"}:
                raise ValueError("invalid_source_kind")
            sources.append(
                {
                    "kind": source.kind,
                    "path": path,
                    "coverage": source.coverage,
                    "feature_keys": feature_keys,
                }
            )

        legacy_targets.append(
            {
                "key": target.key,
                "sources": sources,
                "current_plugins": mappings,
            }
        )

    return {
        "version": 1,
        "current_plugins": current_plugins,
        "legacy_targets": legacy_targets,
    }


def canonical_scope(manifest):
    return json.dumps(
        _scope_object(manifest),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def scope_digest(manifest):
    return hashlib.sha256(canonical_scope(manifest)).hexdigest()


def _normalize_binding_value(value):
    if isinstance(value, dict):
        return {
            key: _normalize_binding_value(value[key])
            for key in sorted(value)
        }
    if isinstance(value, list):
        if not all(isinstance(item, str) and item for item in value):
            raise ValueError("invalid_private_binding")
        if len(value) != len(set(value)):
            raise ValueError("duplicate_private_binding")
        return sorted(value)
    raise ValueError("invalid_private_binding")


def canonical_bindings(bindings):
    normalized = _normalize_binding_value(bindings)
    return json.dumps(
        normalized,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def binding_digest(bindings):
    return hashlib.sha256(canonical_bindings(bindings)).hexdigest()
