import json
import os
import tempfile
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

from .scope import (
    binding_digest,
    canonical_bindings,
    canonical_scope,
    scope_digest,
)


@dataclass(frozen=True)
class Approval:
    version: int
    revision: int
    approved_on: str
    approved_at: str
    public_digest: str
    public_scope: str
    binding_digest: str
    private_bindings: str


def _ensure_state_root(state_root):
    root = Path(state_root)
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if os.name == "posix":
        root.chmod(0o700)
    return root


def _atomic_json(path, value):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
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


def approve_scope(
    state_root,
    manifest,
    bindings,
    *,
    revision,
    approved_on,
):
    public_bytes = canonical_scope(manifest)
    binding_bytes = canonical_bindings(bindings)
    approval = Approval(
        version=1,
        revision=revision,
        approved_on=approved_on,
        approved_at=datetime.now(timezone.utc).isoformat(),
        public_digest=scope_digest(manifest),
        public_scope=public_bytes.decode("utf-8"),
        binding_digest=binding_digest(bindings),
        private_bindings=binding_bytes.decode("utf-8"),
    )
    root = _ensure_state_root(state_root)
    _atomic_json(root / "approval.json", asdict(approval))
    return approval


def load_approval(state_root):
    path = Path(state_root) / "approval.json"
    if os.name == "posix":
        if path.parent.stat().st_mode & 0o077:
            raise ValueError("unsafe_state_permissions")
        if path.stat().st_mode & 0o077:
            raise ValueError("unsafe_approval_permissions")
    value = json.loads(path.read_text(encoding="utf-8"))
    if set(value) != {
        "version",
        "revision",
        "approved_on",
        "approved_at",
        "public_digest",
        "public_scope",
        "binding_digest",
        "private_bindings",
    }:
        raise ValueError("invalid_approval_schema")
    approval = Approval(**value)
    if approval.version != 1:
        raise ValueError("invalid_approval_version")
    return approval


def approval_matches(state_root, manifest, bindings):
    try:
        approval = load_approval(state_root)
    except (FileNotFoundError, ValueError, json.JSONDecodeError):
        return False
    public_bytes = canonical_scope(manifest)
    binding_bytes = canonical_bindings(bindings)
    return (
        approval.revision == manifest.scope.revision
        and approval.public_scope == public_bytes.decode("utf-8")
        and approval.public_digest == scope_digest(manifest)
        and approval.private_bindings == binding_bytes.decode("utf-8")
        and approval.binding_digest == binding_digest(bindings)
    )

@dataclass(frozen=True)
class LocalEvidence:
    key: str
    target: str
    feature: str
    evidence_type: str
    review_date: str
    construct_scope: tuple[str, ...]
    outcome: str
    result: str


@dataclass(frozen=True)
class ProvenanceState:
    version: int
    scope_revision: int
    public_digest: str
    binding_digest: str
    legacy_commit: str
    source_digests: tuple[tuple[str, str], ...]
    evidence: tuple[LocalEvidence, ...]
    refreshed_at: str


def _validate_provenance(provenance, approved_paths):
    if provenance.version != 1:
        raise ValueError("invalid_provenance_version")
    source_paths = tuple(path for path, _ in provenance.source_digests)
    if len(source_paths) != len(set(source_paths)):
        raise ValueError("duplicate_provenance_source")
    if set(source_paths) != set(approved_paths):
        raise ValueError("provenance_source_set")
    evidence_keys = tuple(item.key for item in provenance.evidence)
    if len(evidence_keys) != len(set(evidence_keys)):
        raise ValueError("duplicate_evidence_key")
    if any(item.outcome not in {"pass", "fail"} for item in provenance.evidence):
        raise ValueError("invalid_evidence_outcome")


def write_provenance(state_root, provenance, *, approved_paths):
    _validate_provenance(provenance, approved_paths)
    root = _ensure_state_root(state_root)
    _atomic_json(root / "provenance.json", asdict(provenance))


def load_provenance(state_root):
    path = Path(state_root) / "provenance.json"
    if os.name == "posix":
        if path.parent.stat().st_mode & 0o077:
            raise ValueError("unsafe_state_permissions")
        if path.stat().st_mode & 0o077:
            raise ValueError("unsafe_provenance_permissions")
    value = json.loads(path.read_text(encoding="utf-8"))
    required = {
        "version",
        "scope_revision",
        "public_digest",
        "binding_digest",
        "legacy_commit",
        "source_digests",
        "evidence",
        "refreshed_at",
    }
    if set(value) != required:
        raise ValueError("invalid_provenance_schema")
    evidence = tuple(
        LocalEvidence(
            key=item["key"],
            target=item["target"],
            feature=item["feature"],
            evidence_type=item["evidence_type"],
            review_date=item["review_date"],
            construct_scope=tuple(item["construct_scope"]),
            outcome=item["outcome"],
            result=item["result"],
        )
        for item in value["evidence"]
    )
    return ProvenanceState(
        version=value["version"],
        scope_revision=value["scope_revision"],
        public_digest=value["public_digest"],
        binding_digest=value["binding_digest"],
        legacy_commit=value["legacy_commit"],
        source_digests=tuple(
            (item[0], item[1]) for item in value["source_digests"]
        ),
        evidence=evidence,
        refreshed_at=value["refreshed_at"],
    )
