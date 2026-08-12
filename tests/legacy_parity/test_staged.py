import contextlib
import hashlib
import io
import json
import os
import tempfile
import unittest
from dataclasses import asdict, replace
from pathlib import Path
from unittest import mock

import tools.legacy_parity.state as state_module

from tools.legacy_parity.cli import main
from tools.legacy_parity.legacy import (
    IncludedTarget,
    SelectedSource,
    SelectionState,
)
from tools.legacy_parity.model import (
    Capability,
    CurrentPlugin,
    Evidence,
    Feature,
    LegacySource,
    LegacyTarget,
    Manifest,
    ScopeApproval,
)
from tools.legacy_parity.scope import canonical_scope, scope_digest
from tools.legacy_parity.staged import (
    ArtifactHash,
    BlockerAudit,
    FeatureAssignment,
    RuntimeResult,
    RuntimeScenario,
    SourceConstructs,
    StagedAuditBundle,
    TargetAudit,
    load_staged_bundle,
    parse_staged_bundle,
    provenance_digest,
    validate_staged_bundle,
    with_issue_url,
    with_refreshed_provenance,
    with_runtime_result,
    write_staged_bundle,
)
from tools.legacy_parity.state import Approval, LocalEvidence, ProvenanceState


FIXTURE = (
    Path(__file__).resolve().parent
    / "fixtures"
    / "private-bundle"
    / "valid-bundle.json"
)


def local_feature(key, capability, evidence_key):
    return Feature(
        key=key,
        category="public_api",
        status="lera_blocker",
        summary="Approved behavior requires a Lera capability.",
        current_refs=("generic/sample.lua:3",),
        evidence=Evidence(
            type="manual_private_review",
            review_date="2026-08-10",
            reviewed_scope="Approved behavior.",
            result="Capability is not available.",
            outcome="fail",
            local_key=evidence_key,
        ),
        capability=capability,
    )


class StagedBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state_root = Path(self.temp.name) / "private"
        self.public_repo = Path(self.temp.name) / "public"
        self.public_repo.mkdir()
        one_features = (
            local_feature("feature_one", "shared_api", "evidence_one"),
            local_feature("feature_two", "distinct_api", "evidence_two"),
        )
        two_features = (
            local_feature("feature_three", "shared_api", "evidence_three"),
        )
        base_manifest = Manifest(
            scope=ScopeApproval(
                revision=1,
                approved_on="2026-08-10",
                digest="0" * 64,
            ),
            current_plugins=(
                CurrentPlugin("current_one", "generic/current_one.lua"),
                CurrentPlugin("current_two", "generic/current_two.lua"),
            ),
            legacy_targets=(
                LegacyTarget(
                    key="target_one",
                    sources=(
                        LegacySource(
                            "xml", "plugins/one.xml", "complete"
                        ),
                    ),
                    current_plugins=("current_one",),
                    features=one_features,
                ),
                LegacyTarget(
                    key="target_two",
                    sources=(
                        LegacySource(
                            "xml", "plugins/two.xml", "complete"
                        ),
                    ),
                    current_plugins=("current_two",),
                    features=two_features,
                ),
            ),
            capabilities=(
                Capability(
                    "distinct_api",
                    "Distinct approved capability.",
                    "https://github.com/lundmark/lera/issues/102",
                ),
                Capability(
                    "shared_api",
                    "Shared approved capability.",
                    "https://github.com/lundmark/lera/issues/101",
                ),
            ),
        )
        self.manifest = replace(
            base_manifest,
            scope=replace(
                base_manifest.scope, digest=scope_digest(base_manifest)
            ),
        )
        public_bytes = canonical_scope(self.manifest)
        self.approval = Approval(
            version=1,
            revision=1,
            approved_on="2026-08-10",
            approved_at="2026-08-10T12:00:00+00:00",
            public_digest=self.manifest.scope.digest,
            public_scope=public_bytes.decode("utf-8"),
            binding_digest="1" * 64,
            private_bindings="{}",
        )
        self.selection = SelectionState(
            version=1,
            included_targets=(
                IncludedTarget(
                    key="target_one",
                    sources=(
                        SelectedSource(
                            "xml", "plugins/one.xml", "complete", (), ()
                        ),
                    ),
                    current_plugins=("current_one",),
                ),
                IncludedTarget(
                    key="target_two",
                    sources=(
                        SelectedSource(
                            "xml", "plugins/two.xml", "complete", (), ()
                        ),
                    ),
                    current_plugins=("current_two",),
                ),
            ),
            omitted_candidates=(),
        )
        self.evidence = (
            LocalEvidence(
                key="evidence_one",
                target="target_one",
                feature="feature_one",
                evidence_type="manual_private_review",
                review_date="2026-08-10",
                construct_scope=("xml:plugins/one.xml:1",),
                outcome="fail",
                result="Capability is not available.",
            ),
            LocalEvidence(
                key="evidence_two",
                target="target_one",
                feature="feature_two",
                evidence_type="manual_private_review",
                review_date="2026-08-10",
                construct_scope=("xml:plugins/one.xml:2",),
                outcome="fail",
                result="Capability is not available.",
            ),
            LocalEvidence(
                key="evidence_three",
                target="target_two",
                feature="feature_three",
                evidence_type="manual_private_review",
                review_date="2026-08-10",
                construct_scope=("xml:plugins/two.xml:1",),
                outcome="fail",
                result="Capability is not available.",
            ),
        )
        self.provenance = ProvenanceState(
            version=1,
            scope_revision=1,
            public_digest=self.manifest.scope.digest,
            binding_digest="1" * 64,
            legacy_commit="a" * 40,
            source_digests=(
                ("plugins/one.xml", "2" * 64),
                ("plugins/two.xml", "3" * 64),
            ),
            evidence=self.evidence,
            refreshed_at="2026-08-10T12:00:00+00:00",
        )
        self.artifacts = {
            "manifest": b"manifest candidate",
            "not_converted": b"not converted candidate",
            "parity_report": b"parity report candidate",
        }
        self.bundle = StagedAuditBundle(
            version=1,
            scope_revision=1,
            public_scope=public_bytes.decode("utf-8"),
            public_digest=self.manifest.scope.digest,
            targets=(
                TargetAudit(
                    key="target_one",
                    current_plugins=("current_one",),
                    source_paths=("plugins/one.xml",),
                    dependency_closure=("plugins/one.xml",),
                    construct_inventory=(
                        SourceConstructs(
                            "plugins/one.xml",
                            (
                                "xml:plugins/one.xml:1",
                                "xml:plugins/one.xml:2",
                            ),
                        ),
                    ),
                    assignments=(
                        FeatureAssignment(
                            "feature_one",
                            ("xml:plugins/one.xml:1",),
                            ("xml:plugins/one.xml:1",),
                        ),
                        FeatureAssignment(
                            "feature_two",
                            ("xml:plugins/one.xml:2",),
                            ("xml:plugins/one.xml:2",),
                        ),
                    ),
                    current_only_rationales=(),
                    features=one_features,
                ),
                TargetAudit(
                    key="target_two",
                    current_plugins=("current_two",),
                    source_paths=("plugins/two.xml",),
                    dependency_closure=("plugins/two.xml",),
                    construct_inventory=(
                        SourceConstructs(
                            "plugins/two.xml",
                            ("xml:plugins/two.xml:1",),
                        ),
                    ),
                    assignments=(
                        FeatureAssignment(
                            "feature_three",
                            ("xml:plugins/two.xml:1",),
                            ("xml:plugins/two.xml:1",),
                        ),
                    ),
                    current_only_rationales=(),
                    features=two_features,
                ),
            ),
            evidence=self.evidence,
            blockers=(
                BlockerAudit(
                    key="distinct_api",
                    description="Distinct approved capability.",
                    evidence_keys=("evidence_two",),
                    issue_url="https://github.com/lundmark/lera/issues/102",
                    affected_features=("target_one.feature_two",),
                    affected_plugins=("current_one",),
                ),
                BlockerAudit(
                    key="shared_api",
                    description="Shared approved capability.",
                    evidence_keys=("evidence_one", "evidence_three"),
                    issue_url="https://github.com/lundmark/lera/issues/101",
                    affected_features=(
                        "target_one.feature_one",
                        "target_two.feature_three",
                    ),
                    affected_plugins=("current_one", "current_two"),
                ),
            ),
            provenance=self.provenance,
            provenance_digest=provenance_digest(self.provenance),
            runtime_scenarios=(
                RuntimeScenario(
                    "scenario_one", "target_one", "fixture-one", "4" * 64
                ),
                RuntimeScenario(
                    "scenario_two", "target_two", "fixture-two", "5" * 64
                ),
            ),
            runtime_results=(
                RuntimeResult(
                    "scenario_one", "pass", "4" * 64, "Scenario passed."
                ),
                RuntimeResult(
                    "scenario_two", "pass", "5" * 64, "Scenario passed."
                ),
            ),
            artifact_hashes=tuple(
                ArtifactHash(key, hashlib.sha256(value).hexdigest())
                for key, value in sorted(self.artifacts.items())
            ),
        )

    def tearDown(self):
        self.temp.cleanup()

    def validate(self, bundle=None, **changes):
        values = {
            "manifest": self.manifest,
            "approval": self.approval,
            "selection": self.selection,
            "separate_provenance": self.provenance,
            "candidate_artifacts": self.artifacts,
        }
        values.update(changes)
        validate_staged_bundle(bundle or self.bundle, **values)

    def test_strict_fixture_parser_and_duplicate_key_rejection(self):
        parsed = parse_staged_bundle(FIXTURE)
        self.assertEqual(parsed.version, 1)
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "duplicate.json"
            path.write_text(
                '{"version":1,"version":1}', encoding="utf-8"
            )
            with self.assertRaisesRegex(ValueError, "duplicate_json_key"):
                parse_staged_bundle(path)

    def test_valid_bundle_cross_record_integrity(self):
        self.validate()

    def test_rejects_scope_target_source_and_dependency_drift(self):
        with self.assertRaisesRegex(ValueError, "staged_scope_mismatch"):
            self.validate(replace(self.bundle, public_digest="f" * 64))
        with self.assertRaisesRegex(ValueError, "staged_target_set"):
            self.validate(replace(self.bundle, targets=self.bundle.targets[:1]))
        changed_target = replace(
            self.bundle.targets[0],
            source_paths=("plugins/unapproved.xml",),
        )
        with self.assertRaisesRegex(ValueError, "staged_source_set"):
            self.validate(
                replace(
                    self.bundle,
                    targets=(changed_target,) + self.bundle.targets[1:],
                )
            )
        changed_target = replace(
            self.bundle.targets[0], dependency_closure=()
        )
        with self.assertRaisesRegex(ValueError, "dependency_closure_mismatch"):
            self.validate(
                replace(
                    self.bundle,
                    targets=(changed_target,) + self.bundle.targets[1:],
                )
            )

    def test_rejects_coverage_evidence_and_blocker_drift(self):
        changed_target = replace(
            self.bundle.targets[0],
            assignments=self.bundle.targets[0].assignments[:1],
        )
        with self.assertRaisesRegex(ValueError, "staged_construct_coverage"):
            self.validate(
                replace(
                    self.bundle,
                    targets=(changed_target,) + self.bundle.targets[1:],
                )
            )
        with self.assertRaisesRegex(ValueError, "staged_evidence_linkage"):
            self.validate(replace(self.bundle, evidence=self.evidence[:2]))
        changed_blocker = replace(
            self.bundle.blockers[1], affected_plugins=("current_one",)
        )
        with self.assertRaisesRegex(ValueError, "staged_blocker_derivation"):
            self.validate(
                replace(
                    self.bundle,
                    blockers=(self.bundle.blockers[0], changed_blocker),
                )
            )

    def test_rejects_runtime_provenance_and_artifact_drift(self):
        changed_result = replace(
            self.bundle.runtime_results[0], fixture_digest="9" * 64
        )
        with self.assertRaisesRegex(ValueError, "runtime_result_mismatch"):
            self.validate(
                replace(
                    self.bundle,
                    runtime_results=(changed_result,)
                    + self.bundle.runtime_results[1:],
                )
            )
        changed_provenance = replace(
            self.provenance,
            source_digests=self.provenance.source_digests[:1],
        )
        with self.assertRaisesRegex(ValueError, "provenance_source_set"):
            self.validate(
                replace(
                    self.bundle,
                    provenance=changed_provenance,
                    provenance_digest=provenance_digest(changed_provenance),
                ),
                separate_provenance=changed_provenance,
            )
        with self.assertRaisesRegex(ValueError, "provenance_snapshot_mismatch"):
            self.validate(separate_provenance=replace(self.provenance, legacy_commit="b" * 40))
        with self.assertRaisesRegex(ValueError, "candidate_artifact_hash"):
            self.validate(candidate_artifacts={**self.artifacts, "manifest": b"changed"})

    def test_private_atomic_round_trip_and_immutable_updates(self):
        write_staged_bundle(
            self.state_root, self.bundle, public_repo=self.public_repo
        )
        self.assertEqual(load_staged_bundle(self.state_root), self.bundle)
        if os.name == "posix":
            self.assertEqual(
                (self.state_root / "staged" / "audit-bundle.json").stat().st_mode
                & 0o777,
                0o600,
            )
        updated = with_issue_url(
            self.bundle,
            "shared_api",
            "https://github.com/lundmark/lera/issues/999",
        )
        self.assertNotEqual(updated, self.bundle)
        self.assertEqual(self.bundle.blockers[1].issue_url, "https://github.com/lundmark/lera/issues/101")
        runtime = replace(self.bundle.runtime_results[0], result="Retested.")
        self.assertEqual(
            with_runtime_result(self.bundle, runtime).runtime_results[0],
            runtime,
        )
        refreshed = replace(self.provenance, refreshed_at="2026-08-11T12:00:00+00:00")
        self.assertEqual(
            with_refreshed_provenance(self.bundle, refreshed).provenance,
            refreshed,
        )

        before = (self.state_root / "staged" / "audit-bundle.json").read_bytes()
        with mock.patch(
            "tools.legacy_parity.state._renameat2_at",
            side_effect=OSError("interrupted"),
        ):
            with self.assertRaises(OSError):
                write_staged_bundle(
                    self.state_root, updated, public_repo=self.public_repo
                )
        self.assertEqual(
            (self.state_root / "staged" / "audit-bundle.json").read_bytes(),
            before,
        )
        with self.assertRaisesRegex(ValueError, "public_staged_path"):
            write_staged_bundle(
                self.public_repo / "state",
                self.bundle,
                public_repo=self.public_repo,
            )

    def test_stage_audit_cli_requires_private_input(self):
        self.state_root.mkdir()
        candidate = self.state_root / "candidate.json"
        candidate.write_text(
            json.dumps(asdict(self.bundle)), encoding="utf-8"
        )
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = main(
                [
                    "stage-audit",
                    "--state-root",
                    str(self.state_root),
                    "--public-repo",
                    str(self.public_repo),
                    "--input",
                    str(candidate),
                ]
            )
        self.assertEqual(code, 0)
        self.assertEqual(output.getvalue(), "Private audit bundle staged.\n")
        outside = Path(self.temp.name) / "outside.json"
        outside.write_bytes(candidate.read_bytes())
        with self.assertRaisesRegex(ValueError, "bundle_input_not_private"):
            main(
                [
                    "stage-audit",
                    "--state-root",
                    str(self.state_root),
                    "--public-repo",
                    str(self.public_repo),
                    "--input",
                    str(outside),
                ]
            )


    def test_private_staged_io_fails_closed_without_secure_primitives(self):
        with mock.patch(
            "tools.legacy_parity.staged._require_secure_private_io",
            side_effect=ValueError("unsupported_private_io"),
        ):
            with self.assertRaisesRegex(
                ValueError, "unsupported_private_io"
            ):
                write_staged_bundle(
                    self.state_root,
                    self.bundle,
                    public_repo=self.public_repo,
                )
            with self.assertRaisesRegex(
                ValueError, "unsupported_private_io"
            ):
                load_staged_bundle(self.state_root)


    @unittest.skipUnless(os.name == "posix", "requires descriptor semantics")
    def test_reader_holds_authenticated_staged_bytes(self):
        write_staged_bundle(
            self.state_root, self.bundle, public_repo=self.public_repo
        )
        path = self.state_root / "staged" / "audit-bundle.json"
        external = Path(self.temp.name) / "external-bundle.json"
        external.write_bytes(path.read_bytes())
        external.chmod(0o600)
        path.unlink()
        path.symlink_to(external)
        with self.assertRaisesRegex(ValueError, "unsafe_private_path"):
            load_staged_bundle(self.state_root)

        path.unlink()
        write_staged_bundle(
            self.state_root, self.bundle, public_repo=self.public_repo
        )
        held = path.parent / "held-audit-bundle.json"
        changed = external.read_text(encoding="utf-8").replace(
            '"version": 1', '"version": 99'
        )
        external.write_text(changed, encoding="utf-8")
        external.chmod(0o600)
        real_identity = state_module._named_identity
        substituted = False

        def substitute_after_identity(directory, name):
            nonlocal substituted
            result = real_identity(directory, name)
            if name == "audit-bundle.json" and not substituted:
                substituted = True
                path.rename(held)
                path.symlink_to(external)
            return result

        with mock.patch(
            "tools.legacy_parity.state._named_identity",
            side_effect=substitute_after_identity,
        ):
            with self.assertRaisesRegex(ValueError, "unsafe_private_path"):
                load_staged_bundle(self.state_root)
        self.assertTrue(substituted)

    @unittest.skipUnless(os.name == "posix", "requires renameat2")
    def test_writer_preserves_concurrent_staged_destination(self):
        write_staged_bundle(
            self.state_root, self.bundle, public_repo=self.public_repo
        )
        staged = self.state_root / "staged"
        displaced = staged / "displaced-audit-bundle.json"
        concurrent = b'{"concurrent":true}\n'
        real_rename = state_module._renameat2_at
        injected = False

        def substitute_before_rename(directory, source, destination, flags):
            nonlocal injected
            if destination == "audit-bundle.json" and not injected:
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
                write_staged_bundle(
                    self.state_root,
                    self.bundle,
                    public_repo=self.public_repo,
                )
        self.assertTrue(injected)
        self.assertEqual((staged / "audit-bundle.json").read_bytes(), concurrent)
        self.assertFalse(displaced.exists())


    @unittest.skipUnless(os.name == "posix", "requires renameat2")
    def test_writer_cleans_owned_alias_after_staged_substitution(self):
        write_staged_bundle(
            self.state_root, self.bundle, public_repo=self.public_repo
        )
        staged = self.state_root / "staged"
        concurrent = b'{"concurrent":"post-rename"}\n'
        real_rename = state_module._renameat2_at
        injected = False

        def substitute_after_rename(directory, source, destination, flags):
            nonlocal injected
            real_rename(directory, source, destination, flags)
            if destination == "audit-bundle.json" and not injected:
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
                write_staged_bundle(
                    self.state_root,
                    self.bundle,
                    public_repo=self.public_repo,
                )
        self.assertTrue(injected)
        self.assertEqual(
            (staged / "audit-bundle.json").read_bytes(), concurrent
        )
        self.assertEqual(
            {item.name for item in staged.iterdir()},
            {"audit-bundle.json"},
        )


    @unittest.skipUnless(os.name == "posix", "requires renameat2")
    def test_writer_preserves_unknown_during_verified_staged_unlink(self):
        write_staged_bundle(
            self.state_root, self.bundle, public_repo=self.public_repo
        )
        directory_path = self.state_root / "staged"
        destination = directory_path / "audit-bundle.json"
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
                write_staged_bundle(
                    self.state_root,
                    self.bundle,
                    public_repo=self.public_repo,
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
    def test_recovery_open_is_bound_to_retired_staged_identity(self):
        write_staged_bundle(
            self.state_root, self.bundle, public_repo=self.public_repo
        )
        destination = (
            self.state_root / "provenance.json"
            if "tests/legacy_parity/test_staged.py".endswith("test_state.py")
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
                write_staged_bundle(
                    self.state_root,
                    replace(
                        self.bundle,
                        public_digest="1" * 64,
                    ),
                    public_repo=self.public_repo,
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
    def test_writer_rejects_symlinked_or_substituted_staged_directory(self):
        self.state_root.mkdir(mode=0o700)
        (self.state_root / "staged").symlink_to(
            self.public_repo, target_is_directory=True
        )
        with self.assertRaisesRegex(ValueError, "unsafe_private_path"):
            write_staged_bundle(
                self.state_root, self.bundle, public_repo=self.public_repo
            )
        self.assertFalse((self.public_repo / "audit-bundle.json").exists())

        (self.state_root / "staged").unlink()
        (self.state_root / "staged").mkdir(mode=0o700)
        held = self.state_root / "held-staged"
        staged_module = __import__(
            "tools.legacy_parity.staged", fromlist=["_atomic_json_at"]
        )
        original_atomic = staged_module._atomic_json_at

        def substitute(directory, name, value, verify_tree, **kwargs):
            (self.state_root / "staged").rename(held)
            (self.state_root / "staged").symlink_to(
                self.public_repo, target_is_directory=True
            )
            return original_atomic(
                directory, name, value, verify_tree, **kwargs
            )

        with mock.patch(
            "tools.legacy_parity.staged._atomic_json_at",
            side_effect=substitute,
        ):
            with self.assertRaisesRegex(ValueError, "unsafe_private_path"):
                write_staged_bundle(
                    self.state_root, self.bundle, public_repo=self.public_repo
                )
        self.assertFalse((self.public_repo / "audit-bundle.json").exists())
        self.assertFalse((held / "audit-bundle.json").exists())

        (self.state_root / "staged").unlink()
        held.rename(self.state_root / "staged")
        real_rename = state_module._renameat2_at
        substituted = False

        def substitute_after_rename(directory, source, destination, flags):
            nonlocal substituted
            real_rename(directory, source, destination, flags)
            if not substituted:
                substituted = True
                (self.state_root / "staged").rename(held)
                (self.state_root / "staged").symlink_to(
                    self.public_repo, target_is_directory=True
                )

        with mock.patch(
            "tools.legacy_parity.state._renameat2_at",
            side_effect=substitute_after_rename,
        ):
            with self.assertRaisesRegex(ValueError, "unsafe_private_path"):
                write_staged_bundle(
                    self.state_root, self.bundle, public_repo=self.public_repo
                )
        self.assertFalse((self.public_repo / "audit-bundle.json").exists())
        self.assertFalse((held / "audit-bundle.json").exists())


if __name__ == "__main__":
    unittest.main()
