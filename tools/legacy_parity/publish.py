"""Exception-safe publication of the three parity artifacts."""

from __future__ import annotations

import hashlib
import os
import shutil
import tempfile
from dataclasses import dataclass, field
from pathlib import Path


PUBLIC_PATHS = {
    "manifest": Path("validation/legacy-parity.toml"),
    "not_converted": Path("validation/not-converted.md"),
    "parity_report": Path("validation/parity-report.md"),
}


@dataclass(frozen=True)
class PublicationCandidate:
    repo_root: Path
    private_root: Path
    manifest_bytes: bytes
    report_bytes: bytes
    not_converted_bytes: bytes
    manifest_digest: str = field(init=False)
    report_digest: str = field(init=False)
    not_converted_digest: str = field(init=False)

    def __post_init__(self):
        object.__setattr__(self, "repo_root", Path(self.repo_root).resolve())
        object.__setattr__(
            self, "private_root", Path(self.private_root).resolve()
        )
        for value in self.artifacts.values():
            if not isinstance(value, bytes):
                raise ValueError("invalid_publication_bytes")
        object.__setattr__(
            self,
            "manifest_digest",
            hashlib.sha256(self.manifest_bytes).hexdigest(),
        )
        object.__setattr__(
            self,
            "report_digest",
            hashlib.sha256(self.report_bytes).hexdigest(),
        )
        object.__setattr__(
            self,
            "not_converted_digest",
            hashlib.sha256(self.not_converted_bytes).hexdigest(),
        )

    @property
    def artifacts(self):
        return {
            "manifest": self.manifest_bytes,
            "not_converted": self.not_converted_bytes,
            "parity_report": self.report_bytes,
        }

    @property
    def digests(self):
        return {
            "manifest": self.manifest_digest,
            "not_converted": self.not_converted_digest,
            "parity_report": self.report_digest,
        }


def _write_fsync(path, content):
    path = Path(path)
    with path.open("wb") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())


def _restore(destinations, originals, private_directory):
    restore = private_directory / "restore"
    restore.mkdir(exist_ok=True)
    for key, destination in destinations.items():
        original = originals[key]
        if original is None:
            try:
                destination.unlink()
            except FileNotFoundError:
                pass
            continue
        temporary = restore / key
        _write_fsync(temporary, original)
        destination.parent.mkdir(parents=True, exist_ok=True)
        os.replace(temporary, destination)


def publish_transaction(
    candidate,
    staged_bundle,
    gate,
    *,
    replace_public=None,
) -> None:
    repo = candidate.repo_root
    private = candidate.private_root
    try:
        private.relative_to(repo)
    except ValueError:
        pass
    else:
        raise ValueError("public_publication_staging")
    if not repo.is_dir():
        raise ValueError("missing_publication_repo")
    private.mkdir(parents=True, exist_ok=True, mode=0o700)
    if os.name == "posix":
        private.chmod(0o700)

    frozen_artifacts = dict(candidate.artifacts)
    frozen_digests = {
        key: hashlib.sha256(content).hexdigest()
        for key, content in frozen_artifacts.items()
    }
    if frozen_digests != candidate.digests:
        raise ValueError("candidate_digest_mismatch")

    directory = Path(
        tempfile.mkdtemp(prefix="publication-", dir=private)
    )
    destinations = {
        key: repo / relative for key, relative in PUBLIC_PATHS.items()
    }
    originals = {
        key: destination.read_bytes() if destination.is_file() else None
        for key, destination in destinations.items()
    }
    validation_existed = (repo / "validation").is_dir()
    replace_operation = replace_public or os.replace
    try:
        staged = directory / "candidate"
        backups = directory / "backups"
        staged.mkdir()
        backups.mkdir()
        for key, content in frozen_artifacts.items():
            _write_fsync(staged / key, content)
            if originals[key] is not None:
                _write_fsync(backups / key, originals[key])

        gate(candidate, staged_bundle)

        if candidate.artifacts != frozen_artifacts:
            raise ValueError("candidate_bytes_changed")
        if candidate.digests != frozen_digests:
            raise ValueError("candidate_bytes_changed")
        if any(
            (staged / key).read_bytes() != content
            for key, content in frozen_artifacts.items()
        ):
            raise ValueError("candidate_bytes_changed")

        for destination in destinations.values():
            destination.parent.mkdir(parents=True, exist_ok=True)
        try:
            for key, destination in destinations.items():
                replace_operation(staged / key, destination)
        except BaseException:
            _restore(destinations, originals, directory)
            raise
    finally:
        shutil.rmtree(directory, ignore_errors=True)
        validation = repo / "validation"
        if not validation_existed and validation.is_dir():
            try:
                validation.rmdir()
            except OSError:
                pass
