import os
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest import mock

import tools.legacy_parity.state as state_module

from tools.legacy_parity.state import (
    LocalEvidence,
    ProvenanceState,
    load_provenance,
    write_provenance,
)


class ProvenanceStateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state_root = Path(self.temp.name) / "legacy-parity"
        self.evidence = LocalEvidence(
            key="evidence-1",
            target="sample_legacy",
            feature="sample_command",
            evidence_type="manual_private_review",
            review_date="2026-08-10",
            construct_scope=("xml:plugins/sample.xml:4",),
            outcome="pass",
            result="Approved behavior matched.",
        )
        self.provenance = ProvenanceState(
            version=1,
            scope_revision=1,
            public_digest="0" * 64,
            binding_digest="1" * 64,
            legacy_commit="a" * 40,
            source_digests=(("plugins/sample.xml", "2" * 64),),
            evidence=(self.evidence,),
            refreshed_at="2026-08-10T12:00:00+00:00",
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_round_trip_uses_safe_permissions(self):
        write_provenance(
            self.state_root,
            self.provenance,
            approved_paths={"plugins/sample.xml"},
        )
        self.assertEqual(load_provenance(self.state_root), self.provenance)
        if os.name == "posix":
            self.assertEqual(
                (self.state_root / "provenance.json").stat().st_mode & 0o777,
                0o600,
            )

    def test_rejects_missing_or_extra_approved_sources(self):
        with self.assertRaisesRegex(ValueError, "provenance_source_set"):
            write_provenance(
                self.state_root,
                self.provenance,
                approved_paths={
                    "plugins/sample.xml",
                    "lua/sample.lua",
                },
            )

    def test_rejects_duplicate_evidence_keys(self):
        changed = ProvenanceState(
            **{
                **self.provenance.__dict__,
                "evidence": (self.evidence, self.evidence),
            }
        )
        with self.assertRaisesRegex(ValueError, "duplicate_evidence_key"):
            write_provenance(
                self.state_root,
                changed,
                approved_paths={"plugins/sample.xml"},
            )


    def test_private_io_fails_closed_without_secure_primitives(self):
        with mock.patch(
            "tools.legacy_parity.state._require_secure_private_io",
            side_effect=ValueError("unsupported_private_io"),
        ):
            with self.assertRaisesRegex(
                ValueError, "unsupported_private_io"
            ):
                write_provenance(
                    self.state_root,
                    self.provenance,
                    approved_paths={"plugins/sample.xml"},
                )
            with self.assertRaisesRegex(
                ValueError, "unsupported_private_io"
            ):
                load_provenance(self.state_root)


    @unittest.skipUnless(os.name == "posix", "requires descriptor semantics")
    def test_retirement_fsyncs_source_and_recovery_directories(self):
        write_provenance(
            self.state_root,
            self.provenance,
            approved_paths={"plugins/sample.xml"},
        )
        recovery = self.state_root / "recoveries"
        source_identity = (
            self.state_root.stat().st_dev,
            self.state_root.stat().st_ino,
        )
        recovery_identity = (
            recovery.stat().st_dev,
            recovery.stat().st_ino,
        )
        real_fsync = os.fsync
        synced = []

        def recording_fsync(descriptor):
            metadata = os.fstat(descriptor)
            synced.append((metadata.st_dev, metadata.st_ino))
            return real_fsync(descriptor)

        with mock.patch(
            "tools.legacy_parity.state.os.fsync",
            side_effect=recording_fsync,
        ):
            write_provenance(
                self.state_root,
                replace(self.provenance, refreshed_at="later"),
                approved_paths={"plugins/sample.xml"},
            )
        self.assertIn(source_identity, synced)
        self.assertIn(recovery_identity, synced)


    @unittest.skipUnless(os.name == "posix", "requires descriptor semantics")
    def test_reader_holds_authenticated_provenance_bytes(self):
        write_provenance(
            self.state_root,
            self.provenance,
            approved_paths={"plugins/sample.xml"},
        )
        path = self.state_root / "provenance.json"
        external = Path(self.temp.name) / "external-provenance.json"
        external.write_bytes(path.read_bytes())
        external.chmod(0o600)
        path.unlink()
        path.symlink_to(external)
        with self.assertRaisesRegex(ValueError, "unsafe_private_path"):
            load_provenance(self.state_root)

        path.unlink()
        write_provenance(
            self.state_root,
            self.provenance,
            approved_paths={"plugins/sample.xml"},
        )
        held = self.state_root / "held-provenance.json"
        changed = external.read_text(encoding="utf-8").replace(
            "2026-08-10T12:00:00+00:00",
            "2026-08-10T13:00:00+00:00",
        )
        external.write_text(changed, encoding="utf-8")
        external.chmod(0o600)
        real_identity = state_module._named_identity
        substituted = False

        def substitute_after_identity(directory, name):
            nonlocal substituted
            result = real_identity(directory, name)
            if name == "provenance.json" and not substituted:
                substituted = True
                path.rename(held)
                path.symlink_to(external)
            return result

        with mock.patch(
            "tools.legacy_parity.state._named_identity",
            side_effect=substitute_after_identity,
        ):
            with self.assertRaisesRegex(ValueError, "unsafe_private_path"):
                load_provenance(self.state_root)
        self.assertTrue(substituted)

    @unittest.skipUnless(os.name == "posix", "requires renameat2")
    def test_writer_preserves_concurrent_provenance_destination(self):
        write_provenance(
            self.state_root,
            self.provenance,
            approved_paths={"plugins/sample.xml"},
        )
        displaced = self.state_root / "displaced-provenance.json"
        concurrent = b'{"concurrent":true}\n'
        real_rename = state_module._renameat2_at
        injected = False

        def substitute_before_rename(directory, source, destination, flags):
            nonlocal injected
            if destination == "provenance.json" and not injected:
                injected = True
                os.rename(
                    destination,
                    displaced.name,
                    src_dir_fd=directory,
                    dst_dir_fd=directory,
                )
                descriptor = os.open(
                    destination,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o600,
                    dir_fd=directory,
                )
                try:
                    os.write(descriptor, concurrent)
                finally:
                    os.close(descriptor)
            return real_rename(directory, source, destination, flags)

        with mock.patch(
            "tools.legacy_parity.state._renameat2_at",
            side_effect=substitute_before_rename,
        ):
            with self.assertRaisesRegex(ValueError, "unsafe_private_path"):
                write_provenance(
                    self.state_root,
                    self.provenance,
                    approved_paths={"plugins/sample.xml"},
                )
        self.assertTrue(injected)
        self.assertEqual(
            (self.state_root / "provenance.json").read_bytes(), concurrent
        )
        self.assertFalse(displaced.exists())


    @unittest.skipUnless(os.name == "posix", "requires renameat2")
    def test_writer_cleans_owned_alias_after_destination_substitution(self):
        write_provenance(
            self.state_root,
            self.provenance,
            approved_paths={"plugins/sample.xml"},
        )
        concurrent = b'{"concurrent":"post-rename"}\n'
        real_rename = state_module._renameat2_at
        injected = False

        def substitute_after_rename(directory, source, destination, flags):
            nonlocal injected
            real_rename(directory, source, destination, flags)
            if destination == "provenance.json" and not injected:
                injected = True
                os.rename(
                    destination,
                    "escaped-owned",
                    src_dir_fd=directory,
                    dst_dir_fd=directory,
                )
                descriptor = os.open(
                    destination,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o600,
                    dir_fd=directory,
                )
                try:
                    os.write(descriptor, concurrent)
                finally:
                    os.close(descriptor)

        with mock.patch(
            "tools.legacy_parity.state._renameat2_at",
            side_effect=substitute_after_rename,
        ):
            with self.assertRaisesRegex(ValueError, "unsafe_private_path"):
                write_provenance(
                    self.state_root,
                    self.provenance,
                    approved_paths={"plugins/sample.xml"},
                )
        self.assertTrue(injected)
        self.assertEqual(
            (self.state_root / "provenance.json").read_bytes(), concurrent
        )
        self.assertEqual(
            {item.name for item in self.state_root.iterdir()},
            {"provenance.json", "recoveries"},
        )


    @unittest.skipUnless(os.name == "posix", "requires renameat2")
    def test_writer_preserves_unknown_during_verified_provenance_unlink(self):
        write_provenance(
            self.state_root,
            self.provenance,
            approved_paths={"plugins/sample.xml"},
        )
        directory_path = self.state_root
        destination = directory_path / "provenance.json"
        old_identity = (
            destination.stat().st_dev,
            destination.stat().st_ino,
        )
        unknown = b'{"unknown":"retirement-race"}\n'
        real_rename = state_module._renameat2_between
        injected = False

        def substitute_before_retirement(
            source_directory,
            source,
            recovery_directory,
            recovery_name,
            flags,
        ):
            nonlocal injected
            if (
                source_directory != recovery_directory
                and state_module._named_identity(
                    source_directory, source
                )
                == old_identity
                and not injected
            ):
                injected = True
                os.rename(
                    source,
                    "escaped-old",
                    src_dir_fd=source_directory,
                    dst_dir_fd=source_directory,
                )
                descriptor = os.open(
                    source,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o644,
                    dir_fd=source_directory,
                )
                try:
                    os.write(descriptor, unknown)
                finally:
                    os.close(descriptor)
            return real_rename(
                source_directory,
                source,
                recovery_directory,
                recovery_name,
                flags,
            )

        with mock.patch(
            "tools.legacy_parity.state._renameat2_between",
            side_effect=substitute_before_retirement,
        ):
            with self.assertRaisesRegex(ValueError, "unsafe_private_path"):
                write_provenance(
                    self.state_root,
                    self.provenance,
                    approved_paths={"plugins/sample.xml"},
                )
        self.assertTrue(injected)
        self.assertTrue(destination.exists())
        active = tuple(directory_path.iterdir())
        self.assertFalse(
            any(
                item.is_file()
                and (item.stat().st_dev, item.stat().st_ino)
                == old_identity
                for item in active
            )
        )
        recovered = tuple(
            item
            for item in (self.state_root / "recoveries").iterdir()
            if item.is_file()
        )
        self.assertTrue(any(item.read_bytes() == unknown for item in recovered))
        self.assertTrue(
            all((item.stat().st_mode & 0o777) == 0o600 for item in recovered)
        )
        self.assertTrue(
            any(
                (item.stat().st_dev, item.stat().st_ino) == old_identity
                for item in recovered
            )
        )


    @unittest.skipUnless(os.name == "posix", "requires descriptor semantics")
    def test_recovery_open_is_bound_to_retired_provenance_identity(self):
        write_provenance(
            self.state_root,
            self.provenance,
            approved_paths={"plugins/sample.xml"},
        )
        destination = (
            self.state_root / "provenance.json"
            if "tests/legacy_parity/test_state.py".endswith("test_state.py")
            else self.state_root / "staged" / "audit-bundle.json"
        )
        old_identity = (
            destination.stat().st_dev,
            destination.stat().st_ino,
        )
        unknown = b'{"unknown":"recovery-open-race"}\n'
        real_open = os.open
        injected = False

        def substitute_before_open(name, flags, *args, **kwargs):
            nonlocal injected
            directory = kwargs.get("dir_fd")
            if (
                directory is not None
                and isinstance(name, str)
                and name.startswith("writer-")
                and not injected
            ):
                injected = True
                os.rename(
                    name,
                    "escaped-old",
                    src_dir_fd=directory,
                    dst_dir_fd=directory,
                )
                descriptor = real_open(
                    name,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o644,
                    dir_fd=directory,
                )
                try:
                    os.write(descriptor, unknown)
                finally:
                    os.close(descriptor)
            return real_open(name, flags, *args, **kwargs)

        with mock.patch(
            "tools.legacy_parity.state.os.open",
            side_effect=substitute_before_open,
        ):
            with self.assertRaisesRegex(ValueError, "unsafe_private_path"):
                write_provenance(
                    self.state_root,
                    replace(self.provenance, refreshed_at="changed"),
                    approved_paths={"plugins/sample.xml"},
                )
        self.assertTrue(injected)
        active_root = destination.parent
        self.assertFalse(
            any(
                item.is_file()
                and (item.stat().st_dev, item.stat().st_ino)
                == old_identity
                for item in active_root.iterdir()
            )
        )
        recovered = tuple(
            item
            for item in (self.state_root / "recoveries").iterdir()
            if item.is_file()
        )
        self.assertTrue(any(item.read_bytes() == unknown for item in recovered))
        self.assertTrue(
            any(
                (item.stat().st_dev, item.stat().st_ino) == old_identity
                for item in recovered
            )
        )
        self.assertTrue(
            all((item.stat().st_mode & 0o777) == 0o600 for item in recovered)
        )


    @unittest.skipUnless(os.name == "posix", "requires descriptor semantics")
    def test_writer_rejects_symlinked_or_substituted_state_root(self):
        redirect = Path(self.temp.name) / "redirect"
        redirect.mkdir(mode=0o700)
        self.state_root.symlink_to(redirect, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "unsafe_private_path"):
            write_provenance(
                self.state_root,
                self.provenance,
                approved_paths={"plugins/sample.xml"},
            )
        self.assertFalse((redirect / "provenance.json").exists())

        self.state_root.unlink()
        original_atomic = state_module._atomic_json_at
        held = Path(self.temp.name) / "held-state"

        def substitute(directory, name, value, verify_tree, **kwargs):
            self.state_root.rename(held)
            self.state_root.symlink_to(redirect, target_is_directory=True)
            return original_atomic(
                directory, name, value, verify_tree, **kwargs
            )

        with mock.patch(
            "tools.legacy_parity.state._atomic_json_at",
            side_effect=substitute,
        ):
            with self.assertRaisesRegex(ValueError, "unsafe_private_path"):
                write_provenance(
                    self.state_root,
                    self.provenance,
                    approved_paths={"plugins/sample.xml"},
                )
        self.assertFalse((redirect / "provenance.json").exists())
        self.assertFalse((held / "provenance.json").exists())
        self.state_root.unlink()
        held.rename(self.state_root)

        (self.state_root / "placeholder").touch()
        real_rename = state_module._renameat2_at
        substituted = False

        def substitute_after_rename(directory, source, destination, flags):
            nonlocal substituted
            real_rename(directory, source, destination, flags)
            if not substituted:
                substituted = True
                self.state_root.rename(held)
                self.state_root.symlink_to(redirect, target_is_directory=True)

        with mock.patch(
            "tools.legacy_parity.state._renameat2_at",
            side_effect=substitute_after_rename,
        ):
            with self.assertRaisesRegex(ValueError, "unsafe_private_path"):
                write_provenance(
                    self.state_root,
                    self.provenance,
                    approved_paths={"plugins/sample.xml"},
                )
        self.assertFalse((redirect / "provenance.json").exists())
        self.assertFalse((held / "provenance.json").exists())


if __name__ == "__main__":
    unittest.main()
