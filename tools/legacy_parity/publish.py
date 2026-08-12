"""Exception-safe publication of the three parity artifacts."""

from __future__ import annotations

import hashlib
import os
from dataclasses import dataclass, field
from pathlib import Path

from .state import (
    _RENAME_EXCHANGE,
    _RENAME_NOREPLACE,
    _close_record,
    _descriptor_identity,
    _finalize_record,
    _named_identity,
    _open_private_child,
    _open_private_root,
    _publish_record,
    _read_descriptor,
    _retire_identity_aliases,
    _rollback_record,
    _verify_private_child,
    _verify_private_root,
)


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
        object.__setattr__(
            self,
            "repo_root",
            Path(os.path.abspath(os.fspath(self.repo_root))),
        )
        object.__setattr__(
            self,
            "private_root",
            Path(os.path.abspath(os.fspath(self.private_root))),
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


_DIRECTORY_FLAGS = (
    os.O_RDONLY
    | getattr(os, "O_DIRECTORY", 0)
    | getattr(os, "O_CLOEXEC", 0)
    | getattr(os, "O_NOFOLLOW", 0)
)
_FILE_FLAGS = (
    os.O_RDONLY
    | getattr(os, "O_CLOEXEC", 0)
    | getattr(os, "O_NOFOLLOW", 0)
)
_CREATE_FLAGS = (
    os.O_WRONLY
    | os.O_CREAT
    | os.O_EXCL
    | getattr(os, "O_CLOEXEC", 0)
    | getattr(os, "O_NOFOLLOW", 0)
)


def _open_directory_root(path):
    root = Path(os.path.abspath(os.fspath(path)))
    descriptor = os.open(os.sep, _DIRECTORY_FLAGS)
    try:
        for part in root.parts[1:]:
            next_descriptor = os.open(
                part, _DIRECTORY_FLAGS, dir_fd=descriptor
            )
            os.close(descriptor)
            descriptor = next_descriptor
        record = os.fstat(descriptor)
        if not os.path.isdir(f"/proc/self/fd/{descriptor}"):
            raise ValueError("unsafe_publication_path")
        return root, descriptor, (record.st_dev, record.st_ino)
    except BaseException as error:
        os.close(descriptor)
        if isinstance(error, ValueError):
            raise
        raise ValueError("unsafe_publication_path") from error


def _verify_directory_root(path, expected):
    _, descriptor, identity = _open_directory_root(path)
    try:
        if identity != expected:
            raise ValueError("unsafe_publication_path")
    finally:
        os.close(descriptor)


def _open_validation(repo_path, repo_descriptor, repo_identity):
    _verify_directory_root(repo_path, repo_identity)
    created = None
    try:
        os.mkdir("validation", 0o755, dir_fd=repo_descriptor)
        record = os.stat(
            "validation", dir_fd=repo_descriptor, follow_symlinks=False
        )
        created = record.st_dev, record.st_ino
    except FileExistsError:
        pass
    try:
        descriptor = os.open(
            "validation", _DIRECTORY_FLAGS, dir_fd=repo_descriptor
        )
    except OSError as error:
        raise ValueError("unsafe_publication_path") from error
    record = os.fstat(descriptor)
    identity = record.st_dev, record.st_ino
    if created is not None and created != identity:
        os.close(descriptor)
        raise ValueError("unsafe_publication_path")
    _verify_directory_root(repo_path, repo_identity)
    return descriptor, identity


def _verify_validation(repo_path, repo_identity, validation_identity):
    _, repo_descriptor, identity = _open_directory_root(repo_path)
    try:
        if identity != repo_identity:
            raise ValueError("unsafe_publication_path")
        validation = os.open(
            "validation", _DIRECTORY_FLAGS, dir_fd=repo_descriptor
        )
        try:
            record = os.fstat(validation)
            if (record.st_dev, record.st_ino) != validation_identity:
                raise ValueError("unsafe_publication_path")
        finally:
            os.close(validation)
    finally:
        os.close(repo_descriptor)


def _write_all(descriptor, content):
    view = memoryview(content)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("short public write")
        view = view[written:]


def _read_public_optional(directory, name):
    before = _named_identity(directory, name)
    if before is None:
        return None, None
    descriptor = os.open(name, _FILE_FLAGS, dir_fd=directory)
    try:
        record = os.fstat(descriptor)
        identity = record.st_dev, record.st_ino
        if not os.path.isfile(f"/proc/self/fd/{descriptor}") or identity != before:
            raise ValueError("unsafe_publication_path")
        content = _read_descriptor(descriptor)
        if _named_identity(directory, name) != identity:
            raise ValueError("unsafe_publication_path")
        return content, identity
    finally:
        os.close(descriptor)


def _prepare_public_record(directory, recovery, key, name, content):
    original_content, original_identity = _read_public_optional(directory, name)
    descriptor = None
    for _ in range(128):
        temporary = f".{name}.{os.urandom(12).hex()}"
        try:
            descriptor = os.open(
                temporary, _CREATE_FLAGS, 0o644, dir_fd=directory
            )
            break
        except FileExistsError:
            continue
    if descriptor is None:
        raise ValueError("unsafe_publication_path")
    identity = _descriptor_identity(descriptor)
    try:
        os.fchmod(descriptor, 0o644)
        _write_all(descriptor, content)
        os.fsync(descriptor)
        return {
            "directory": directory,
            "recovery": recovery,
            "key": key,
            "name": name,
            "temporary": temporary,
            "descriptor": descriptor,
            "identity": identity,
            "original_content": original_content,
            "original_identity": original_identity,
            "mode": None,
            "published": False,
        }
    except BaseException as primary:
        os.close(descriptor)
        try:
            _retire_identity_aliases(directory, recovery, identity)
        except BaseException as cleanup_error:
            raise cleanup_error from primary
        raise


def publish_transaction(
    candidate,
    staged_bundle,
    gate,
    *,
    publication_hook=None,
) -> None:
    repo = candidate.repo_root
    private = candidate.private_root
    try:
        private.relative_to(repo)
    except ValueError:
        pass
    else:
        raise ValueError("public_publication_staging")

    frozen_artifacts = dict(candidate.artifacts)
    frozen_digests = {
        key: hashlib.sha256(content).hexdigest()
        for key, content in frozen_artifacts.items()
    }
    if frozen_digests != candidate.digests:
        raise ValueError("candidate_digest_mismatch")

    repo_path, repo_descriptor, repo_identity = _open_directory_root(repo)
    private_path = None
    private_descriptor = None
    recovery_descriptor = None
    validation_descriptor = None
    records = []
    try:
        gate(candidate, staged_bundle)
        if (
            candidate.artifacts != frozen_artifacts
            or candidate.digests != frozen_digests
        ):
            raise ValueError("candidate_bytes_changed")

        private_path, private_descriptor, private_identity = _open_private_root(
            private
        )
        recovery_descriptor, recovery_identity = _open_private_child(
            private_path,
            private_descriptor,
            private_identity,
            "recoveries",
        )
        validation_descriptor, validation_identity = _open_validation(
            repo_path, repo_descriptor, repo_identity
        )

        def verify_tree():
            _verify_directory_root(repo_path, repo_identity)
            _verify_validation(
                repo_path, repo_identity, validation_identity
            )
            _verify_private_root(private_path, private_identity)
            _verify_private_child(
                private_path,
                private_identity,
                "recoveries",
                recovery_identity,
            )

        for key, relative in PUBLIC_PATHS.items():
            records.append(
                _prepare_public_record(
                    validation_descriptor,
                    recovery_descriptor,
                    key,
                    relative.name,
                    frozen_artifacts[key],
                )
            )

        try:
            for record in records:
                verify_tree()
                source = repo_path / "validation" / record["temporary"]
                destination = repo_path / "validation" / record["name"]
                if publication_hook is not None:
                    publication_hook(
                        "before", record["key"], source, destination
                    )
                _publish_record(record)
                if publication_hook is not None:
                    publication_hook(
                        "after", record["key"], source, destination
                    )
                if (
                    _named_identity(validation_descriptor, record["name"])
                    != record["identity"]
                ):
                    raise ValueError("unsafe_publication_path")
                verify_tree()
            os.fsync(validation_descriptor)
        except BaseException as primary:
            cleanup_error = None
            for record in reversed(records):
                try:
                    _rollback_record(record)
                except BaseException as error:
                    if cleanup_error is None:
                        cleanup_error = error
            os.fsync(validation_descriptor)
            os.fsync(recovery_descriptor)
            if cleanup_error is not None:
                raise cleanup_error from primary
            raise

        for record in records:
            _finalize_record(record)
        os.fsync(validation_descriptor)
        os.fsync(recovery_descriptor)
        verify_tree()
    finally:
        for record in records:
            _close_record(record)
        if validation_descriptor is not None:
            os.close(validation_descriptor)
        if recovery_descriptor is not None:
            os.close(recovery_descriptor)
        if private_descriptor is not None:
            os.close(private_descriptor)
        os.close(repo_descriptor)
