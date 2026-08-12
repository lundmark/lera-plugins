import ctypes
import errno
import hashlib
import json
import os
import secrets
import stat
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


_DIRECTORY_FLAGS = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
_FILE_READ_FLAGS = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
_FILE_WRITE_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)


def _require_secure_private_io():
    if os.name != "posix":
        raise ValueError("unsupported_private_io")


def _absolute_path(path):
    return Path(os.path.abspath(os.fspath(path)))


def _private_directory_identity(descriptor):
    record = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(record.st_mode)
        or stat.S_IMODE(record.st_mode) != 0o700
        or record.st_uid != os.geteuid()
    ):
        raise ValueError("unsafe_private_path")
    return record.st_dev, record.st_ino


def _private_file_identity(descriptor):
    record = os.fstat(descriptor)
    if (
        not stat.S_ISREG(record.st_mode)
        or stat.S_IMODE(record.st_mode) != 0o600
        or record.st_uid != os.geteuid()
    ):
        raise ValueError("unsafe_private_path")
    return record.st_dev, record.st_ino


def _open_private_root(path, *, create=True):
    if os.name != "posix":
        root = _absolute_path(path)
        if root.is_symlink():
            raise ValueError("unsafe_private_path")
        if create:
            root.mkdir(parents=True, exist_ok=True, mode=0o700)
            root.chmod(0o700)
        descriptor = os.open(root, os.O_RDONLY)
        return root, descriptor, (0, 0)
    root = _absolute_path(path)
    descriptor = os.open(os.sep, _DIRECTORY_FLAGS)
    try:
        parts = root.parts[1:]
        if not parts:
            raise ValueError("unsafe_private_path")
        for index, part in enumerate(parts):
            final = index == len(parts) - 1
            created = None
            if final and create:
                try:
                    os.mkdir(part, 0o700, dir_fd=descriptor)
                    record = os.stat(part, dir_fd=descriptor, follow_symlinks=False)
                    created = record.st_dev, record.st_ino
                except FileExistsError:
                    pass
            try:
                next_descriptor = os.open(part, _DIRECTORY_FLAGS, dir_fd=descriptor)
            except OSError as error:
                raise ValueError("unsafe_private_path") from error
            os.close(descriptor)
            descriptor = next_descriptor
            if created is not None and _private_directory_identity(descriptor) != created:
                raise ValueError("unsafe_private_path")
        if create:
            record = os.fstat(descriptor)
            if not stat.S_ISDIR(record.st_mode) or record.st_uid != os.geteuid():
                raise ValueError("unsafe_private_path")
            os.fchmod(descriptor, 0o700)
        identity = _private_directory_identity(descriptor)
        return root, descriptor, identity
    except BaseException:
        os.close(descriptor)
        raise


def _verify_private_root(path, expected):
    _, descriptor, identity = _open_private_root(path, create=False)
    try:
        if identity != expected:
            raise ValueError("unsafe_private_path")
    finally:
        os.close(descriptor)


def _open_private_child(root_path, root_descriptor, root_identity, name, *, create=True):
    _verify_private_root(root_path, root_identity)
    created = None
    if create:
        try:
            os.mkdir(name, 0o700, dir_fd=root_descriptor)
            record = os.stat(name, dir_fd=root_descriptor, follow_symlinks=False)
            created = record.st_dev, record.st_ino
        except FileExistsError:
            pass
    try:
        descriptor = os.open(name, _DIRECTORY_FLAGS, dir_fd=root_descriptor)
    except OSError as error:
        raise ValueError("unsafe_private_path") from error
    try:
        if create:
            record = os.fstat(descriptor)
            if not stat.S_ISDIR(record.st_mode) or record.st_uid != os.geteuid():
                raise ValueError("unsafe_private_path")
            os.fchmod(descriptor, 0o700)
        identity = _private_directory_identity(descriptor)
        if created is not None and identity != created:
            raise ValueError("unsafe_private_path")
        _verify_private_root(root_path, root_identity)
        return descriptor, identity
    except BaseException:
        os.close(descriptor)
        raise


def _verify_private_child(root_path, root_identity, name, child_identity):
    _, root_descriptor, identity = _open_private_root(root_path, create=False)
    try:
        if identity != root_identity:
            raise ValueError("unsafe_private_path")
        try:
            child = os.open(name, _DIRECTORY_FLAGS, dir_fd=root_descriptor)
        except OSError as error:
            raise ValueError("unsafe_private_path") from error
        try:
            if _private_directory_identity(child) != child_identity:
                raise ValueError("unsafe_private_path")
        finally:
            os.close(child)
    finally:
        os.close(root_descriptor)


def _write_all(descriptor, content):
    view = memoryview(content)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("short private write")
        view = view[written:]


def _write_temp_at(directory, content, prefix, recovery):
    for _ in range(128):
        name = f".{prefix}.{secrets.token_hex(12)}"
        try:
            descriptor = os.open(name, _FILE_WRITE_FLAGS, 0o600, dir_fd=directory)
        except FileExistsError:
            continue
        try:
            os.fchmod(descriptor, 0o600)
            _private_file_identity(descriptor)
            _write_all(descriptor, content)
            os.fsync(descriptor)
            return name, descriptor
        except BaseException as primary:
            identity = _descriptor_identity(descriptor)
            os.close(descriptor)
            try:
                _retire_identity_aliases(
                    directory, recovery, identity
                )
            except BaseException as cleanup_error:
                raise cleanup_error from primary
            raise
    raise ValueError("unsafe_private_path")


def _named_identity(directory, name):
    try:
        record = os.stat(name, dir_fd=directory, follow_symlinks=False)
    except FileNotFoundError:
        return None
    return record.st_dev, record.st_ino


def _descriptor_identity(descriptor):
    record = os.fstat(descriptor)
    return record.st_dev, record.st_ino


_RENAME_NOREPLACE = 1
_RENAME_EXCHANGE = 2


def _renameat2_between(
    source_directory,
    source,
    destination_directory,
    destination,
    flags,
):
    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = getattr(libc, "renameat2", None)
    if renameat2 is None:
        raise ValueError("unsupported_private_io")
    renameat2.argtypes = (
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    )
    renameat2.restype = ctypes.c_int
    result = renameat2(
        source_directory,
        os.fsencode(source),
        destination_directory,
        os.fsencode(destination),
        flags,
    )
    if result == 0:
        return
    failure = ctypes.get_errno()
    if failure == errno.EEXIST:
        raise FileExistsError(destination)
    raise OSError(failure, os.strerror(failure), destination)


def _renameat2_at(directory, source, destination, flags):
    _renameat2_between(
        directory, source, directory, destination, flags
    )


def _identity_names_at(directory, identity):
    if identity is None:
        return ()
    matches = []
    for name in os.listdir(directory):
        try:
            actual = _named_identity(directory, name)
        except OSError:
            continue
        if actual == identity:
            matches.append(name)
    return tuple(matches)


def _retire_name(directory, name, recovery, expected):
    for _ in range(128):
        destination = f"writer-{secrets.token_hex(16)}"
        try:
            _renameat2_between(
                directory,
                name,
                recovery,
                destination,
                _RENAME_NOREPLACE,
            )
            break
        except FileExistsError:
            continue
    else:
        raise ValueError("unsafe_private_path")
    actual = _named_identity(recovery, destination)
    try:
        descriptor = os.open(
            destination, _FILE_READ_FLAGS, dir_fd=recovery
        )
    except OSError as error:
        os.fsync(directory)
        os.fsync(recovery)
        raise ValueError("unsafe_private_path") from error
    try:
        metadata = os.fstat(descriptor)
        opened = (metadata.st_dev, metadata.st_ino)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
        ):
            raise ValueError("unsafe_private_path")
        os.fchmod(descriptor, 0o600)
        os.fsync(descriptor)
        if (
            opened != actual
            or _named_identity(recovery, destination) != opened
        ):
            raise ValueError("unsafe_private_path")
    finally:
        os.close(descriptor)
        os.fsync(directory)
        os.fsync(recovery)
    return actual == expected


def _retire_identity_aliases(
    directory, recovery, identity, *, preserve=()
):
    if identity is None:
        return
    preserved = set(preserve)
    mismatch = False
    for _ in range(128):
        aliases = tuple(
            alias
            for alias in _identity_names_at(directory, identity)
            if alias not in preserved
        )
        if not aliases:
            if mismatch:
                raise ValueError("unsafe_private_path")
            return
        for alias in aliases:
            if not _retire_name(
                directory, alias, recovery, identity
            ):
                mismatch = True
    raise ValueError("unsafe_private_path")


def _retire_if_same(directory, name, descriptor, recovery):
    identity = _descriptor_identity(descriptor)
    if _named_identity(directory, name) != identity:
        return False
    if not _retire_name(directory, name, recovery, identity):
        _retire_identity_aliases(
            directory, recovery, identity
        )
        raise ValueError("unsafe_private_path")
    return True



def _replace_at(directory, source, destination, replace_operation):
    replace_operation(
        f"/proc/self/fd/{directory}/{source}",
        f"/proc/self/fd/{directory}/{destination}",
    )


def _read_descriptor(descriptor):
    os.lseek(descriptor, 0, os.SEEK_SET)
    chunks = []
    while True:
        chunk = os.read(descriptor, 65536)
        if not chunk:
            break
        chunks.append(chunk)
    return b"".join(chunks)


def _read_optional_at(directory, name):
    before = _named_identity(directory, name)
    if before is None:
        return None, None
    try:
        descriptor = os.open(name, _FILE_READ_FLAGS, dir_fd=directory)
    except (FileNotFoundError, OSError) as error:
        raise ValueError("unsafe_private_path") from error
    try:
        identity = _private_file_identity(descriptor)
        if before != identity:
            raise ValueError("unsafe_private_path")
        content = _read_descriptor(descriptor)
        if _named_identity(directory, name) != identity:
            raise ValueError("unsafe_private_path")
        return content, identity
    finally:
        os.close(descriptor)


def _read_required_at(directory, name):
    content, identity = _read_optional_at(directory, name)
    if content is None or identity is None:
        raise FileNotFoundError(name)
    return content


def _destination_unchanged(directory, name, original_identity):
    if _named_identity(directory, name) != original_identity:
        raise ValueError("unsafe_private_path")


def _prepare_bytes_record(directory, recovery, name, content):
    if not isinstance(content, bytes):
        raise ValueError("invalid_private_bytes")
    original_content, original_identity = _read_optional_at(directory, name)
    temporary, descriptor = _write_temp_at(
        directory, content, name, recovery
    )
    return {
        "directory": directory,
        "recovery": recovery,
        "name": name,
        "temporary": temporary,
        "descriptor": descriptor,
        "identity": _descriptor_identity(descriptor),
        "original_content": original_content,
        "original_identity": original_identity,
        "mode": None,
        "published": False,
    }


def _prepare_json_record(directory, recovery, name, value):
    return _prepare_bytes_record(
        directory, recovery, name, _json_bytes(value)
    )


def _publish_record(record, replace_operation=None):
    directory = record["directory"]
    name = record["name"]
    temporary = record["temporary"]
    _destination_unchanged(directory, name, record["original_identity"])
    try:
        if replace_operation is not None:
            record["mode"] = "replace"
            _replace_at(directory, temporary, name, replace_operation)
        elif record["original_identity"] is None:
            record["mode"] = "noreplace"
            _renameat2_at(
                directory, temporary, name, _RENAME_NOREPLACE
            )
        else:
            record["mode"] = "exchange"
            _renameat2_at(
                directory, temporary, name, _RENAME_EXCHANGE
            )
        record["published"] = True
    except BaseException:
        candidate_at_name = _named_identity(directory, name) == record["identity"]
        candidate_at_temporary = (
            _named_identity(directory, temporary) == record["identity"]
        )
        candidate_aliases = _identity_names_at(
            directory, record["identity"]
        )
        if candidate_at_name or (
            candidate_aliases and not candidate_at_temporary
        ):
            record["published"] = True
        raise
    if _named_identity(directory, name) != record["identity"]:
        raise ValueError("unsafe_private_path")
    if record["mode"] == "exchange":
        if (
            _named_identity(directory, temporary)
            != record["original_identity"]
        ):
            raise ValueError("unsafe_private_path")
    elif _named_identity(directory, temporary) is not None:
        raise ValueError("unsafe_private_path")


def _cleanup_displaced_record(record):
    directory = record["directory"]
    recovery = record["recovery"]
    name = record["name"]
    temporary = record["temporary"]
    original_identity = record["original_identity"]
    preserve_original = (
        (name,) if _named_identity(directory, name) == original_identity else ()
    )
    _retire_identity_aliases(
        directory, recovery, record["identity"]
    )
    _retire_identity_aliases(
        directory,
        recovery,
        original_identity,
        preserve=preserve_original,
    )
    temporary_identity = _named_identity(directory, temporary)
    owned = {record["identity"], original_identity, None}
    if temporary_identity not in owned:
        raise ValueError("unsafe_private_path")


def _rollback_record(record):
    directory = record["directory"]
    recovery = record["recovery"]
    name = record["name"]
    temporary = record["temporary"]
    identity = record["identity"]
    mode = record["mode"]
    if not record["published"]:
        _cleanup_displaced_record(record)
        return

    if mode == "exchange":
        if (
            _named_identity(directory, name) == identity
            and _named_identity(directory, temporary) is not None
        ):
            _renameat2_at(
                directory, name, temporary, _RENAME_EXCHANGE
            )
            if _named_identity(directory, temporary) != identity:
                raise ValueError("unsafe_private_path")
            if not _retire_if_same(
                directory,
                temporary,
                record["descriptor"],
                recovery,
            ):
                raise ValueError("unsafe_private_path")
            _retire_identity_aliases(
                directory,
                recovery,
                record["original_identity"],
                preserve=(
                    (name,)
                    if _named_identity(directory, name)
                    == record["original_identity"]
                    else ()
                ),
            )
            return
        _cleanup_displaced_record(record)
        return

    if mode == "noreplace":
        if _named_identity(directory, name) == identity:
            if _named_identity(directory, temporary) is not None:
                raise ValueError("unsafe_private_path")
            _renameat2_at(
                directory, name, temporary, _RENAME_NOREPLACE
            )
            if not _retire_if_same(
                directory,
                temporary,
                record["descriptor"],
                recovery,
            ):
                raise ValueError("unsafe_private_path")
            return
        _cleanup_displaced_record(record)
        return

    if mode == "replace":
        if _named_identity(directory, name) != identity:
            _cleanup_displaced_record(record)
            return
        if record["original_content"] is None:
            if not _retire_if_same(
                directory, name, record["descriptor"], recovery
            ):
                raise ValueError("unsafe_private_path")
            return
        restore, restore_descriptor = _write_temp_at(
            directory,
            record["original_content"],
            f"restore-{name}",
            recovery,
        )
        try:
            _renameat2_at(
                directory, restore, name, _RENAME_EXCHANGE
            )
            if (
                _named_identity(directory, name)
                != _descriptor_identity(restore_descriptor)
                or _named_identity(directory, restore) != identity
            ):
                raise ValueError("unsafe_private_path")
            if not _retire_if_same(
                directory,
                restore,
                record["descriptor"],
                recovery,
            ):
                raise ValueError("unsafe_private_path")
        finally:
            _retire_if_same(
                directory, restore, restore_descriptor, recovery
            )
            os.close(restore_descriptor)
        return

    _cleanup_displaced_record(record)


def _finalize_record(record):
    if record["mode"] != "exchange":
        return
    directory = record["directory"]
    recovery = record["recovery"]
    temporary = record["temporary"]
    original_identity = record["original_identity"]
    if _named_identity(directory, temporary) != original_identity:
        _retire_identity_aliases(
            directory,
            recovery,
            original_identity,
            preserve=(
                (record["name"],)
                if _named_identity(directory, record["name"])
                == original_identity
                else ()
            ),
        )
        raise ValueError("unsafe_private_path")
    try:
        retired = _retire_name(
            directory, temporary, recovery, original_identity
        )
    except BaseException:
        _retire_identity_aliases(
            directory,
            recovery,
            original_identity,
        )
        raise
    if not retired:
        _retire_identity_aliases(
            directory,
            recovery,
            original_identity,
        )
        raise ValueError("unsafe_private_path")


def _close_record(record):
    try:
        _retire_identity_aliases(
            record["directory"],
            record["recovery"],
            record["identity"],
            preserve=(
                (record["name"],)
                if _named_identity(
                    record["directory"], record["name"]
                )
                == record["identity"]
                else ()
            ),
        )
    finally:
        os.close(record["descriptor"])



def _atomic_bytes_at(
    directory,
    name,
    content,
    verify_tree,
    *,
    recovery,
    replace_operation=None,
):
    verify_tree()
    record = _prepare_bytes_record(
        directory, recovery, name, content
    )
    try:
        try:
            verify_tree()
            _publish_record(record, replace_operation)
            verify_tree()
            os.fsync(directory)
        except BaseException as primary:
            try:
                _rollback_record(record)
                os.fsync(directory)
            except BaseException as cleanup_error:
                raise cleanup_error from primary
            raise
        _finalize_record(record)
        os.fsync(directory)
    finally:
        _close_record(record)


def _atomic_json_at(
    directory,
    name,
    value,
    verify_tree,
    *,
    recovery,
    replace_operation=None,
):
    _atomic_bytes_at(
        directory,
        name,
        _json_bytes(value),
        verify_tree,
        recovery=recovery,
        replace_operation=replace_operation,
    )




def _write_private_root_bytes(state_root, name, content):
    _require_secure_private_io()
    root_path, root_descriptor, root_identity = _open_private_root(state_root)
    recovery_descriptor = None
    try:
        recovery_descriptor, recovery_identity = _open_private_child(
            root_path, root_descriptor, root_identity, "recoveries"
        )

        def verify_tree():
            _verify_private_root(root_path, root_identity)
            _verify_private_child(
                root_path,
                root_identity,
                "recoveries",
                recovery_identity,
            )

        _atomic_bytes_at(
            root_descriptor,
            name,
            content,
            verify_tree,
            recovery=recovery_descriptor,
        )
    finally:
        if recovery_descriptor is not None:
            os.close(recovery_descriptor)
        os.close(root_descriptor)


def _write_private_child_bytes(state_root, child_name, name, content):
    _require_secure_private_io()
    root_path, root_descriptor, root_identity = _open_private_root(state_root)
    child_descriptor = None
    recovery_descriptor = None
    try:
        recovery_descriptor, recovery_identity = _open_private_child(
            root_path, root_descriptor, root_identity, "recoveries"
        )
        child_descriptor, child_identity = _open_private_child(
            root_path, root_descriptor, root_identity, child_name
        )

        def verify_tree():
            _verify_private_root(root_path, root_identity)
            _verify_private_child(
                root_path, root_identity, child_name, child_identity
            )
            _verify_private_child(
                root_path,
                root_identity,
                "recoveries",
                recovery_identity,
            )

        _atomic_bytes_at(
            child_descriptor,
            name,
            content,
            verify_tree,
            recovery=recovery_descriptor,
        )
    finally:
        if child_descriptor is not None:
            os.close(child_descriptor)
        if recovery_descriptor is not None:
            os.close(recovery_descriptor)
        os.close(root_descriptor)


def _load_private_root_bytes(state_root, name):
    _require_secure_private_io()
    root_path, root_descriptor, root_identity = _open_private_root(
        state_root, create=False
    )
    try:
        content = _read_required_at(root_descriptor, name)
        _verify_private_root(root_path, root_identity)
        return content
    finally:
        os.close(root_descriptor)


def _unique_json_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate_private_json_key")
        value[key] = item
    return value


def _load_private_json_bytes(content, code):
    try:
        return json.loads(
            content.decode("utf-8"),
            object_pairs_hook=_unique_json_object,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise ValueError(code) from error


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
    _write_private_root_bytes(
        state_root, "approval.json", _json_bytes(asdict(approval))
    )
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
    _write_private_root_bytes(
        state_root, "approval.json", _json_bytes(asdict(approval))
    )
    return approval


def load_approval(state_root):
    value = _load_private_json_bytes(
        _load_private_root_bytes(state_root, "approval.json"),
        "invalid_approval_json",
    )
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
    _require_secure_private_io()
    root_path, root_descriptor, root_identity = _open_private_root(state_root)
    recovery_descriptor = None
    try:
        recovery_descriptor, recovery_identity = _open_private_child(
            root_path,
            root_descriptor,
            root_identity,
            "recoveries",
        )

        def verify_tree():
            _verify_private_root(root_path, root_identity)
            _verify_private_child(
                root_path,
                root_identity,
                "recoveries",
                recovery_identity,
            )

        _atomic_json_at(
            root_descriptor,
            "provenance.json",
            asdict(provenance),
            verify_tree,
            recovery=recovery_descriptor,
        )
    finally:
        if recovery_descriptor is not None:
            os.close(recovery_descriptor)
        os.close(root_descriptor)



def _provenance_from_value(value):
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


def load_provenance(state_root):
    _require_secure_private_io()

    root_path, root_descriptor, root_identity = _open_private_root(
        state_root, create=False
    )
    try:
        content = _read_required_at(root_descriptor, "provenance.json")
        _verify_private_root(root_path, root_identity)
    finally:
        os.close(root_descriptor)
    try:
        value = json.loads(content.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("invalid_provenance_json") from error
    return _provenance_from_value(value)



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

    approved_paths = tuple(path for path, _ in provenance.source_digests)
    _validate_provenance(provenance, approved_paths)
    _require_secure_private_io()

    root_path, root_descriptor, root_identity = _open_private_root(state_root)
    staged_descriptor = None
    recovery_descriptor = None
    records = []
    try:
        recovery_descriptor, recovery_identity = _open_private_child(
            root_path,
            root_descriptor,
            root_identity,
            "recoveries",
        )
        staged_descriptor, staged_identity = _open_private_child(
            root_path, root_descriptor, root_identity, "staged"
        )

        def verify_tree():
            _verify_private_root(root_path, root_identity)
            _verify_private_child(
                root_path, root_identity, "staged", staged_identity
            )
            _verify_private_child(
                root_path,
                root_identity,
                "recoveries",
                recovery_identity,
            )

        destinations = (
            (root_descriptor, "provenance.json", asdict(provenance)),
            (staged_descriptor, "audit-bundle.json", asdict(bundle)),
        )
        verify_tree()
        for directory, name, value in destinations:
            records.append(
                _prepare_json_record(
                    directory,
                    recovery_descriptor,
                    name,
                    value,
                )
            )

        try:
            for record in records:
                verify_tree()
                _publish_record(record, replace_operation)
                verify_tree()
            os.fsync(root_descriptor)
            os.fsync(staged_descriptor)
        except BaseException as primary:
            cleanup_error = None
            for record in reversed(records):
                try:
                    _rollback_record(record)
                except BaseException as error:
                    if cleanup_error is None:
                        cleanup_error = error
            os.fsync(root_descriptor)
            os.fsync(staged_descriptor)
            if cleanup_error is not None:
                raise cleanup_error from primary
            raise

        cleanup_error = None
        for record in records:
            try:
                _finalize_record(record)
            except BaseException as error:
                if cleanup_error is None:
                    cleanup_error = error
        os.fsync(root_descriptor)
        os.fsync(staged_descriptor)
        if cleanup_error is not None:
            raise cleanup_error
        verify_tree()
    finally:
        for record in records:
            _close_record(record)
        if staged_descriptor is not None:
            os.close(staged_descriptor)
        if recovery_descriptor is not None:
            os.close(recovery_descriptor)
        os.close(root_descriptor)
