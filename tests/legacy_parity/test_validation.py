import contextlib
import hashlib
import io
import json
import os
import stat
import subprocess
import tempfile
import unittest
from dataclasses import asdict, replace
from pathlib import Path

from tools.legacy_parity.audit import (
    PreliminaryAudit,
    PreliminaryBehavior,
    current_source_digest,
    stage_preliminary_audit,
)
from tools.legacy_parity.cli import main
from tools.legacy_parity.current import extract_current
from tools.legacy_parity.legacy import (
    IncludedTarget,
    SelectedSource,
    SelectionState,
    write_selection,
)
from tools.legacy_parity.manifest import render_manifest
from tools.legacy_parity.model import (
    CurrentPlugin,
    Evidence,
    Feature,
    LegacySource,
    LegacyTarget,
    Manifest,
    ScopeApproval,
)
from tools.legacy_parity.publish import PublicationCandidate
from tools.legacy_parity.report import (
    PUBLIC_HEADING,
    render_not_converted,
    render_parity_report,
)
from tools.legacy_parity.scope import (
    binding_digest,
    canonical_bindings,
    canonical_scope,
    scope_digest,
)
from tools.legacy_parity.staged import (
    ArtifactHash,
    FeatureAssignment,
    RuntimeResult,
    RuntimeScenario,
    SourceConstructs,
    StagedAuditBundle,
    TargetAudit,
    load_staged_bundle,
    provenance_digest,
    write_staged_bundle,
)
from tools.legacy_parity.state import (
    ProvenanceState,
    approve_scope,
    load_approval,
    load_provenance,
    write_provenance,
    write_provenance_transaction,
)
from tools.legacy_parity.validation import (
    PRIVATE_HEADING,
    PrivateValidationRoots,
    ValidationFailure,
    full_private_publication_gate,
    validate_full_private,
    validate_public,
)


class ValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.repo = root / "repo"
        self.legacy = root / "legacy"
        self.lera = root / "lera"
        self.state = root / "state"
        (self.repo / "generic").mkdir(parents=True)
        (self.repo / "validation").mkdir()
        (self.legacy / "plugins").mkdir(parents=True)
        (self.lera / "plugins" / "generic").mkdir(parents=True)

        current = (
            "local M = {}\n"
            'M.name = "sample"\n'
            "function M.run() return \"ok\" end\n"
            "return M\n"
        )
        (self.repo / "generic" / "sample.lua").write_text(
            current, encoding="utf-8"
        )
        (self.lera / "plugins" / "generic" / "sample.lua").write_text(
            current, encoding="utf-8"
        )
        source = self.legacy / "plugins" / "sample.xml"
        source.write_text(
            '<muclient name="sample"></muclient>\n', encoding="utf-8"
        )
        subprocess.run(
            ("git", "init", "-q", str(self.legacy)),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        subprocess.run(
            ("git", "-C", str(self.legacy), "config", "user.name", "Parity"),
            check=True,
        )
        subprocess.run(
            (
                "git",
                "-C",
                str(self.legacy),
                "config",
                "user.email",
                "parity@example.invalid",
            ),
            check=True,
        )
        subprocess.run(
            ("git", "-C", str(self.legacy), "add", "plugins/sample.xml"),
            check=True,
        )
        subprocess.run(
            ("git", "-C", str(self.legacy), "commit", "-qm", "fixture"),
            check=True,
        )
        self.legacy_commit = subprocess.run(
            ("git", "-C", str(self.legacy), "rev-parse", "HEAD"),
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        ).stdout.strip()

        feature = Feature(
            key="sample_command",
            category="command",
            status="parity",
            summary="Runs the approved synthetic command.",
            current_refs=("generic/sample.lua:3",),
            evidence=Evidence(
                type="public_fixture",
                review_date="2026-08-10",
                reviewed_scope="Synthetic command behavior.",
                result="Command output matched.",
                outcome="pass",
                reference="sample-scenario",
            ),
        )
        base = Manifest(
            scope=ScopeApproval(1, "2026-08-10", "0" * 64),
            current_plugins=(
                CurrentPlugin(
                    "sample",
                    "generic/sample.lua",
                    ("sample_legacy",),
                    ("sample-scenario",),
                ),
            ),
            legacy_targets=(
                LegacyTarget(
                    key="sample_legacy",
                    sources=(
                        LegacySource(
                            "xml", "plugins/sample.xml", "complete"
                        ),
                    ),
                    current_plugins=("sample",),
                    features=(feature,),
                ),
            ),
            capabilities=(),
        )
        self.manifest = replace(
            base,
            scope=replace(base.scope, digest=scope_digest(base)),
        )
        self.selection = SelectionState(
            version=1,
            included_targets=(
                IncludedTarget(
                    key="sample_legacy",
                    sources=(
                        SelectedSource(
                            "xml",
                            "plugins/sample.xml",
                            "complete",
                            (),
                            (),
                        ),
                    ),
                    current_plugins=("sample",),
                ),
            ),
            omitted_candidates=(),
        )
        self.bindings = {"sample_legacy": {}}
        self.approval = approve_scope(
            self.state,
            self.manifest,
            self.bindings,
            revision=1,
            approved_on="2026-08-10",
        )
        write_selection(
            self.state, self.selection, public_repo=self.repo
        )
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        self.provenance = ProvenanceState(
            version=1,
            scope_revision=1,
            public_digest=self.manifest.scope.digest,
            binding_digest=binding_digest(self.bindings),
            legacy_commit=self.legacy_commit,
            source_digests=(("plugins/sample.xml", digest),),
            evidence=(),
            refreshed_at="2026-08-10T12:00:00+00:00",
        )
        write_provenance(
            self.state,
            self.provenance,
            approved_paths=("plugins/sample.xml",),
        )

        self.artifacts = {
            "manifest": render_manifest(self.manifest).encode(),
            "not_converted": render_not_converted(self.manifest).encode(),
            "parity_report": render_parity_report(self.manifest).encode(),
        }
        self.bundle = StagedAuditBundle(
            version=1,
            scope_revision=1,
            public_scope=canonical_scope(self.manifest).decode(),
            public_digest=self.manifest.scope.digest,
            targets=(
                TargetAudit(
                    key="sample_legacy",
                    source_paths=("plugins/sample.xml",),
                    dependency_closure=("plugins/sample.xml",),
                    construct_inventory=(
                        SourceConstructs(
                            "plugins/sample.xml",
                            ("xml:plugins/sample.xml:1",),
                        ),
                    ),
                    assignments=(
                        FeatureAssignment(
                            "sample_command",
                            ("xml:plugins/sample.xml:1",),
                            ("xml:plugins/sample.xml:1",),
                        ),
                    ),
                    current_only_rationales=(),
                    features=(feature,),
                    current_plugins=("sample",),
                ),
            ),
            evidence=(),
            blockers=(),
            provenance=self.provenance,
            provenance_digest=provenance_digest(self.provenance),
            runtime_scenarios=(
                RuntimeScenario(
                    "scenario", "sample_legacy", "sample-scenario", "4" * 64
                ),
            ),
            runtime_results=(
                RuntimeResult(
                    "scenario", "pass", "4" * 64, "Scenario passed."
                ),
            ),
            artifact_hashes=tuple(
                ArtifactHash(key, hashlib.sha256(value).hexdigest())
                for key, value in sorted(self.artifacts.items())
            ),
        )
        write_staged_bundle(
            self.state, self.bundle, public_repo=self.repo
        )
        for key, relative in (
            ("manifest", "legacy-parity.toml"),
            ("not_converted", "not-converted.md"),
            ("parity_report", "parity-report.md"),
        ):
            (self.repo / "validation" / relative).write_bytes(
                self.artifacts[key]
            )
        self.lera_bin = root / "lera-bin"
        self.lera_bin.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.lera_bin.chmod(
            self.lera_bin.stat().st_mode | stat.S_IXUSR
        )
        self.roots = PrivateValidationRoots(
            repo_root=self.repo,
            state_root=self.state,
            legacy_root=self.legacy,
            lera_root=self.lera,
        )

    def tearDown(self):
        self.temp.cleanup()

    def candidate(self, artifacts=None):
        values = artifacts or self.artifacts
        return PublicationCandidate(
            repo_root=self.repo,
            private_root=self.state / "publication",
            manifest_bytes=values["manifest"],
            report_bytes=values["parity_report"],
            not_converted_bytes=values["not_converted"],
        )

    def test_public_validation_is_deterministic_and_explicitly_limited(self):
        summary = validate_public(self.repo)
        self.assertTrue(summary.text.startswith(PUBLIC_HEADING))
        self.assertNotIn("Verified at:", summary.text)
        for check in (
            "private scope approval",
            "legacy provenance and construct coverage",
            "current mirror parity",
            "private leakage deny tokens",
            "real Lera runtime",
        ):
            self.assertIn(check, summary.text)

        path = self.repo / "validation" / "parity-report.md"
        path.write_bytes(path.read_bytes() + b" ")
        with self.assertRaisesRegex(
            ValidationFailure, "public_artifact_mismatch"
        ):
            validate_public(self.repo)

    def test_full_private_gate_authenticates_exact_candidate_bytes(self):
        summary = validate_full_private(
            roots=self.roots,
            lera_bin=self.lera_bin,
            verified_at="2026-08-10T13:00:00+00:00",
        )
        self.assertTrue(summary.text.startswith(PRIVATE_HEADING))
        self.assertIn("Verified at: 2026-08-10T13:00:00+00:00", summary.text)
        self.assertTrue(summary.report_path.is_file())

        full_private_publication_gate(
            self.candidate(),
            self.bundle,
            self.roots,
            self.lera_bin,
        )
        changed = dict(self.artifacts)
        changed["parity_report"] += b" "
        with self.assertRaisesRegex(
            ValidationFailure, "public_artifact_mismatch"
        ):
            full_private_publication_gate(
                self.candidate(changed),
                self.bundle,
                self.roots,
                self.lera_bin,
            )

    def test_validation_levels_enforce_strict_mode_and_private_roots(self):
        with self.assertRaisesRegex(
            ValueError, "require_parity_private_only"
        ):
            validate_public(self.repo, require_parity=True)
        blocked = replace(
            self.bundle.targets[0].features[0],
            status="plugin_gap",
            evidence=replace(
                self.bundle.targets[0].features[0].evidence,
                outcome="fail",
            ),
        )
        changed_target = replace(
            self.bundle.targets[0], features=(blocked,)
        )
        changed_bundle = replace(
            self.bundle, targets=(changed_target,)
        )
        write_staged_bundle(
            self.state, changed_bundle, public_repo=self.repo
        )
        with self.assertRaisesRegex(ValidationFailure, "strict_parity_status"):
            full_private_publication_gate(
                self.candidate(),
                changed_bundle,
                self.roots,
                self.lera_bin,
                require_parity=True,
            )

    def test_refresh_updates_only_reviewed_provenance_atomically(self):
        source = self.legacy / "plugins" / "sample.xml"
        source.write_text(
            '<muclient name="sample"></muclient>\n<!-- reviewed -->\n',
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            ValidationFailure, "legacy_source_drift"
        ):
            validate_full_private(
                roots=self.roots, lera_bin=self.lera_bin
            )

        validate_full_private(
            roots=self.roots,
            lera_bin=self.lera_bin,
            refresh_legacy=True,
            verified_at="2026-08-10T14:00:00+00:00",
        )
        refreshed = load_provenance(self.state)
        staged = load_staged_bundle(self.state)
        self.assertEqual(refreshed, staged.provenance)
        self.assertEqual(
            refreshed.source_digests[0][1],
            hashlib.sha256(source.read_bytes()).hexdigest(),
        )
        self.assertEqual(
            canonical_bindings(self.bindings).decode(),
            self.approval.private_bindings,
        )

    def test_refresh_supports_initial_provenance_creation(self):
        (self.state / "provenance.json").unlink()
        validate_full_private(
            roots=self.roots,
            lera_bin=self.lera_bin,
            refresh_legacy=True,
            verified_at="2026-08-10T14:30:00+00:00",
        )
        self.assertEqual(
            load_provenance(self.state),
            load_staged_bundle(self.state).provenance,
        )

    def test_propose_and_approve_require_the_exact_private_digests(self):
        current_path = self.repo / "generic" / "sample.lua"
        constructs = extract_current(
            current_path, "generic/sample.lua"
        )
        audit = PreliminaryAudit(
            version=1,
            current_key="sample",
            current_path="generic/sample.lua",
            source_digest=current_source_digest(current_path),
            construct_ids=tuple(item.id for item in constructs),
            target_keys=("sample_legacy",),
            current_only_rationale=None,
            preliminary_status_counts=(("parity", len(constructs)),),
            confirmed_blocker_keys=(),
            review_date="2026-08-10",
            complete=True,
            behaviors=tuple(
                PreliminaryBehavior(
                    construct_id=item.id,
                    status="parity",
                    target_keys=("sample_legacy",),
                    reviewed=True,
                    observation="Synthetic behavior reviewed.",
                    blocker_keys=(),
                )
                for item in constructs
            ),
        )
        record = self.state / "preliminary-record.json"
        record.write_text(json.dumps(asdict(audit)), encoding="utf-8")
        stage_preliminary_audit(
            self.state,
            record,
            plugin_root=self.repo,
            selection=self.selection,
        )
        proposal = self.state / "scope-proposal.json"
        with contextlib.redirect_stdout(io.StringIO()):
            propose_code = main(
                [
                    "propose-scope",
                    "--legacy-root",
                    str(self.legacy),
                    "--plugin-root",
                    str(self.repo),
                    "--state-root",
                    str(self.state),
                    "--output",
                    str(proposal),
                ]
            )
        self.assertEqual(propose_code, 0)
        value = json.loads(proposal.read_text(encoding="utf-8"))
        with contextlib.redirect_stdout(io.StringIO()):
            approve_code = main(
                [
                    "approve-scope",
                    "--proposal",
                    str(proposal),
                    "--state-root",
                    str(self.state),
                    "--revision",
                    str(value["revision"]),
                    "--approved-on",
                    "2026-08-10",
                    "--confirmed-public-digest",
                    value["public_digest"],
                    "--confirmed-binding-digest",
                    value["binding_digest"],
                ]
            )
        self.assertEqual(approve_code, 0)
        approved = load_approval(self.state)
        self.assertEqual(approved.public_digest, value["public_digest"])
        self.assertEqual(approved.binding_digest, value["binding_digest"])

    def test_provenance_transaction_rolls_back_after_each_replace(self):
        prior_provenance = (self.state / "provenance.json").read_bytes()
        prior_bundle = (
            self.state / "staged" / "audit-bundle.json"
        ).read_bytes()
        for fail_after in (1, 2):
            count = 0

            def failing_replace(source, destination):
                nonlocal count
                os.replace(source, destination)
                count += 1
                if count == fail_after:
                    raise OSError("injected")

            with self.subTest(fail_after=fail_after):
                with self.assertRaises(OSError):
                    write_provenance_transaction(
                        self.state,
                        replace(
                            self.provenance,
                            refreshed_at="2026-08-10T15:00:00+00:00",
                        ),
                        self.bundle,
                        replace_operation=failing_replace,
                    )
                self.assertEqual(
                    (self.state / "provenance.json").read_bytes(),
                    prior_provenance,
                )
                self.assertEqual(
                    (self.state / "staged" / "audit-bundle.json").read_bytes(),
                    prior_bundle,
                )


if __name__ == "__main__":
    unittest.main()
