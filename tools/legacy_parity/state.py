import hashlib
import json
import os
import shutil
import tempfile
from dataclasses import asdict, dataclass
from datetime import date, datetime, timezone
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


def approve_canonical_scope(
    state_root,
    *,
    public_scope,
    private_bindings,
    revision,
    approved_on,
    confirmed_public_digest,
    confirmed_binding_digest,
):
    if (
        not isinstance(public_scope, str)
        or not isinstance(private_bindings, str)
        or not isinstance(revision, int)
        or revision < 1
    ):
        raise ValueError("invalid_scope_proposal")
    try:
        date.fromisoformat(approved_on)
        public_value = json.loads(public_scope)
        private_value = json.loads(private_bindings)
    except (TypeError, ValueError, json.JSONDecodeError) as error:
        raise ValueError("invalid_scope_proposal") from error
    canonical_public = json.dumps(
        public_value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    canonical_private = json.dumps(
        private_value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    if (
        canonical_public != public_scope
        or canonical_private != private_bindings
    ):
        raise ValueError("invalid_scope_proposal")
    public_digest = hashlib.sha256(
        public_scope.encode("utf-8")
    ).hexdigest()
    private_digest = hashlib.sha256(
        private_bindings.encode("utf-8")
    ).hexdigest()
    if (
        public_digest != confirmed_public_digest
        or private_digest != confirmed_binding_digest
    ):
        raise ValueError("scope_confirmation_mismatch")
    approval = Approval(
        version=1,
        revision=revision,
        approved_on=approved_on,
        approved_at=datetime.now(timezone.utc).isoformat(),
        public_digest=public_digest,
        public_scope=public_scope,
        binding_digest=private_digest,
        private_bindings=private_bindings,
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
    provenance = ProvenanceState(
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
    _validate_provenance(
        provenance, (path for path, _ in provenance.source_digests)
    )
    return provenance


def _json_bytes(value):
    return (
        json.dumps(
            value, ensure_ascii=False, sort_keys=True
        )
        + "\n"
    ).encode("utf-8")


def _write_bytes(path, content):
    path = Path(path)
    with path.open("wb") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())
    if os.name == "posix":
        path.chmod(0o600)


def write_provenance_transaction(
    state_root,
    provenance,
    bundle,
    *,
    replace_operation=None,
):
    """Replace provenance and its staged snapshot as one rollback-safe unit."""

    approved_paths = tuple(
        path for path, _ in provenance.source_digests
    )
    _validate_provenance(provenance, approved_paths)
    root = _ensure_state_root(state_root)
    staged = root / "staged"
    staged.mkdir(mode=0o700, exist_ok=True)
    if os.name == "posix":
        staged.chmod(0o700)
    destinations = (
        root / "provenance.json",
        staged / "audit-bundle.json",
    )
    originals = tuple(
        path.read_bytes() if path.is_file() else None
        for path in destinations
    )
    directory = Path(tempfile.mkdtemp(prefix=".provenance-", dir=root))
    replace = replace_operation or os.replace
    try:
        candidates = (
            directory / "provenance.json",
            directory / "audit-bundle.json",
        )
        _write_bytes(candidates[0], _json_bytes(asdict(provenance)))
        _write_bytes(candidates[1], _json_bytes(asdict(bundle)))
        try:
            for source, destination in zip(candidates, destinations):
                replace(source, destination)
                if os.name == "posix":
                    destination.chmod(0o600)
        except BaseException:
            for destination, original in zip(destinations, originals):
                if original is None:
                    try:
                        destination.unlink()
                    except FileNotFoundError:
                        pass
                else:
                    restore = directory / f"restore-{destination.name}"
                    _write_bytes(restore, original)
                    os.replace(restore, destination)
            raise
    finally:
        shutil.rmtree(directory, ignore_errors=True)
