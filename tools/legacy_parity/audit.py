"""Private preliminary audits for current plugin behavior."""

from __future__ import annotations

import hashlib
import json
import os
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path

from .current import discover_current, extract_current
from .state import _atomic_json, _ensure_state_root


PRELIMINARY_STATUSES = frozenset(
    {
        "parity",
        "plugin_gap",
        "lera_blocker",
        "not_converted",
        "waived",
        "current_only",
    }
)


@dataclass(frozen=True)
class PreliminaryBehavior:
    construct_id: str
    status: str
    target_keys: tuple[str, ...]
    reviewed: bool
    observation: str
    blocker_keys: tuple[str, ...]


@dataclass(frozen=True)
class PreliminaryAudit:
    version: int
    current_key: str
    current_path: str
    source_digest: str
    construct_ids: tuple[str, ...]
    target_keys: tuple[str, ...]
    current_only_rationale: str | None
    preliminary_status_counts: tuple[tuple[str, int], ...]
    confirmed_blocker_keys: tuple[str, ...]
    review_date: str
    complete: bool
    behaviors: tuple[PreliminaryBehavior, ...]


def current_source_digest(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _audit_from_dict(value) -> PreliminaryAudit:
    required = {
        "version",
        "current_key",
        "current_path",
        "source_digest",
        "construct_ids",
        "target_keys",
        "current_only_rationale",
        "preliminary_status_counts",
        "confirmed_blocker_keys",
        "review_date",
        "complete",
        "behaviors",
    }
    if not isinstance(value, dict) or set(value) != required:
        raise ValueError("invalid_preliminary_audit_schema")
    behaviors = []
    behavior_fields = {
        "construct_id",
        "status",
        "target_keys",
        "reviewed",
        "observation",
        "blocker_keys",
    }
    for item in value["behaviors"]:
        if not isinstance(item, dict) or set(item) != behavior_fields:
            raise ValueError("invalid_preliminary_behavior_schema")
        behaviors.append(
            PreliminaryBehavior(
                construct_id=item["construct_id"],
                status=item["status"],
                target_keys=tuple(item["target_keys"]),
                reviewed=item["reviewed"],
                observation=item["observation"],
                blocker_keys=tuple(item["blocker_keys"]),
            )
        )
    try:
        status_counts = tuple(
            (item[0], item[1])
            for item in value["preliminary_status_counts"]
        )
        return PreliminaryAudit(
            version=value["version"],
            current_key=value["current_key"],
            current_path=value["current_path"],
            source_digest=value["source_digest"],
            construct_ids=tuple(value["construct_ids"]),
            target_keys=tuple(value["target_keys"]),
            current_only_rationale=value["current_only_rationale"],
            preliminary_status_counts=status_counts,
            confirmed_blocker_keys=tuple(value["confirmed_blocker_keys"]),
            review_date=value["review_date"],
            complete=value["complete"],
            behaviors=tuple(behaviors),
        )
    except (IndexError, TypeError) as error:
        raise ValueError("invalid_preliminary_audit_schema") from error


def _selection_mappings(selection, inventory):
    if selection.version != 1:
        raise ValueError("invalid_selection")
    inventory_keys = {item.key for item in inventory}
    target_keys = tuple(target.key for target in selection.included_targets)
    if len(target_keys) != len(set(target_keys)):
        raise ValueError("duplicate_target_key")
    expected = {key: [] for key in inventory_keys}
    for target in selection.included_targets:
        if len(target.current_plugins) != len(set(target.current_plugins)):
            raise ValueError("duplicate_current_mapping")
        for current_key in target.current_plugins:
            if current_key not in inventory_keys:
                raise ValueError("unknown_current_mapping")
            expected[current_key].append(target.key)
    return {
        key: tuple(sorted(values))
        for key, values in expected.items()
    }


def _validate_audit(
    audit,
    inventory_item,
    plugin_root,
    expected_targets,
    *,
    require_complete,
):
    if audit.version != 1:
        raise ValueError("invalid_preliminary_version")
    if (
        audit.current_key != inventory_item.key
        or audit.current_path != inventory_item.path
    ):
        raise ValueError("preliminary_current_mismatch")
    source = Path(plugin_root) / inventory_item.path
    if audit.source_digest != current_source_digest(source):
        raise ValueError("current_source_changed")
    extracted_ids = tuple(
        item.id
        for item in extract_current(source, inventory_item.path)
    )
    if (
        audit.construct_ids != extracted_ids
        or len(audit.construct_ids) != len(set(audit.construct_ids))
    ):
        raise ValueError("current_inventory_changed")
    if audit.target_keys != expected_targets:
        raise ValueError("preliminary_target_mismatch")
    if expected_targets:
        if audit.current_only_rationale is not None:
            raise ValueError("mapped_current_only_rationale")
    elif not isinstance(audit.current_only_rationale, str) or not (
        audit.current_only_rationale.strip()
    ):
        raise ValueError("current_only_rationale_required")

    behavior_ids = tuple(item.construct_id for item in audit.behaviors)
    if (
        len(behavior_ids) != len(set(behavior_ids))
        or any(item not in set(extracted_ids) for item in behavior_ids)
    ):
        raise ValueError("invalid_current_classification")

    represented_targets = set()
    blockers = set()
    counts = Counter()
    for behavior in audit.behaviors:
        if behavior.status not in PRELIMINARY_STATUSES:
            raise ValueError("invalid_preliminary_status")
        if (
            len(behavior.target_keys) != len(set(behavior.target_keys))
            or any(key not in expected_targets for key in behavior.target_keys)
        ):
            raise ValueError("preliminary_behavior_target")
        if behavior.status == "current_only":
            if behavior.target_keys:
                raise ValueError("current_only_behavior_target")
        elif not behavior.target_keys:
            raise ValueError("preliminary_behavior_without_target")
        if not isinstance(behavior.observation, str) or not behavior.observation.strip():
            raise ValueError("missing_preliminary_observation")
        if behavior.status == "lera_blocker":
            if not behavior.blocker_keys:
                raise ValueError("missing_preliminary_blocker")
        elif behavior.blocker_keys:
            raise ValueError("unexpected_preliminary_blocker")
        if len(behavior.blocker_keys) != len(set(behavior.blocker_keys)):
            raise ValueError("duplicate_preliminary_blocker")
        represented_targets.update(behavior.target_keys)
        blockers.update(behavior.blocker_keys)
        counts[behavior.status] += 1

    if represented_targets != set(expected_targets):
        raise ValueError("preliminary_target_coverage")
    if audit.preliminary_status_counts != tuple(sorted(counts.items())):
        raise ValueError("preliminary_status_counts")
    if audit.confirmed_blocker_keys != tuple(sorted(blockers)):
        raise ValueError("confirmed_blocker_keys")
    if not isinstance(audit.review_date, str) or not audit.review_date:
        raise ValueError("missing_preliminary_review_date")
    if not isinstance(audit.complete, bool):
        raise ValueError("invalid_preliminary_complete")
    if audit.complete:
        if set(behavior_ids) != set(extracted_ids):
            raise ValueError("incomplete_current_classification")
        if any(not item.reviewed for item in audit.behaviors):
            raise ValueError("unreviewed_current_behavior")
    if require_complete and not audit.complete:
        raise ValueError("incomplete_preliminary_audit")


def stage_preliminary_audit(
    state_root,
    record_path,
    *,
    plugin_root,
    selection,
) -> PreliminaryAudit:
    root = Path(state_root).resolve()
    record = Path(record_path).resolve()
    try:
        record.relative_to(root)
    except ValueError as error:
        raise ValueError("audit_record_not_private") from error
    if not record.is_file():
        raise ValueError("missing_preliminary_record")
    audit = _audit_from_dict(json.loads(record.read_text(encoding="utf-8")))
    inventory = discover_current(Path(plugin_root))
    by_key = {item.key: item for item in inventory}
    if audit.current_key not in by_key:
        raise ValueError("unknown_preliminary_current")
    mappings = _selection_mappings(selection, inventory)
    _validate_audit(
        audit,
        by_key[audit.current_key],
        plugin_root,
        mappings[audit.current_key],
        require_complete=False,
    )
    root = _ensure_state_root(root)
    preliminary = root / "preliminary"
    preliminary.mkdir(mode=0o700, exist_ok=True)
    if os.name == "posix":
        preliminary.chmod(0o700)
    _atomic_json(preliminary / f"{audit.current_key}.json", asdict(audit))
    return audit


def load_preliminary_audit(state_root, current_key) -> PreliminaryAudit:
    path = Path(state_root) / "preliminary" / f"{current_key}.json"
    if os.name == "posix":
        if path.parent.stat().st_mode & 0o077:
            raise ValueError("unsafe_preliminary_directory")
        if path.stat().st_mode & 0o077:
            raise ValueError("unsafe_preliminary_permissions")
    return _audit_from_dict(json.loads(path.read_text(encoding="utf-8")))


def validate_preliminary_audits(
    state_root,
    plugin_root,
    selection,
) -> tuple[PreliminaryAudit, ...]:
    inventory = discover_current(Path(plugin_root))
    mappings = _selection_mappings(selection, inventory)
    directory = Path(state_root) / "preliminary"
    staged_keys = (
        {path.stem for path in directory.glob("*.json")}
        if directory.is_dir()
        else set()
    )
    expected_keys = {item.key for item in inventory}
    if staged_keys != expected_keys:
        raise ValueError("preliminary_audit_set")
    audits = []
    for item in inventory:
        audit = load_preliminary_audit(state_root, item.key)
        _validate_audit(
            audit,
            item,
            plugin_root,
            mappings[item.key],
            require_complete=True,
        )
        audits.append(audit)
    return tuple(audits)
