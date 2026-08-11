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
from unittest import mock

from tools.legacy_parity.audit import (
    PreliminaryAudit,
    PreliminaryBehavior,
    current_source_digest,
    stage_preliminary_audit,
)
from tools.legacy_parity.cli import main
from tools.legacy_parity.current import extract_current
from tools.legacy_parity.legacy import (
    FeatureBinding,
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
    _validate_construct_snapshots,
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
                    "scenario", "sample_legacy", "sample-scenario", "0" * 64
                ),
            ),
            runtime_results=(
                RuntimeResult(
                    "scenario", "pass", "0" * 64, "Scenario passed."
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
        scenario_path = (
            self.state / "staged" / "runtime" / "sample-scenario.json"
        )
        scenario_path.parent.mkdir(mode=0o700)
        scenario_path.write_text(
            json.dumps(
                {
                    "version": 1,
                    "key": "scenario",
                    "target_key": "sample_legacy",
                    "plugin": "generic/sample.lua",
                    "clock_ms": 0,
                    "store_seed": {},
                    "dependencies": {},
                    "operations": [],
                    "expected": {
                        "effects": [],
                        "registrations": {
                            "aliases": 0,
                            "triggers": 0,
                            "timers": 0,
                            "mip": 0,
                        },
                    },
                },
                sort_keys=True,
            ),
            encoding="utf-8",
        )
        scenario_path.chmod(0o600)
        fixture_digest = hashlib.sha256(
            scenario_path.read_bytes()
        ).hexdigest()
        self.bundle = replace(
            self.bundle,
            runtime_scenarios=(
                replace(
                    self.bundle.runtime_scenarios[0],
                    fixture_digest=fixture_digest,
                ),
            ),
            runtime_results=(
                replace(
                    self.bundle.runtime_results[0],
                    fixture_digest=fixture_digest,
                ),
            ),
        )
        write_staged_bundle(
            self.state, self.bundle, public_repo=self.repo
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

    def runtime_scenario_path(self):
        return (
            self.state / "staged" / "runtime" / "sample-scenario.json"
        )

    def restage_runtime_scenario(self, **changes):
        path = self.runtime_scenario_path()
        value = json.loads(path.read_text(encoding="utf-8"))
        value.update(changes)
        path.write_text(
            json.dumps(value, sort_keys=True), encoding="utf-8"
        )
        path.chmod(0o600)
        fixture_digest = hashlib.sha256(path.read_bytes()).hexdigest()
        self.bundle = replace(
            self.bundle,
            runtime_scenarios=(
                replace(
                    self.bundle.runtime_scenarios[0],
                    fixture_digest=fixture_digest,
                ),
            ),
            runtime_results=(
                replace(
                    self.bundle.runtime_results[0],
                    fixture_digest=fixture_digest,
                ),
            ),
        )
        write_staged_bundle(
            self.state, self.bundle, public_repo=self.repo
        )
        return path

    def declare_runtime_fixture(self, fixture_key):
        current = replace(
            self.manifest.current_plugins[0],
            fixtures=tuple(
                sorted(
                    set(self.manifest.current_plugins[0].fixtures)
                    | {fixture_key}
                )
            ),
        )
        self.manifest = replace(
            self.manifest, current_plugins=(current,)
        )
        self.artifacts = {
            "manifest": render_manifest(self.manifest).encode(),
            "not_converted": render_not_converted(self.manifest).encode(),
            "parity_report": render_parity_report(self.manifest).encode(),
        }
        self.bundle = replace(
            self.bundle,
            runtime_scenarios=(
                replace(
                    self.bundle.runtime_scenarios[0],
                    fixture_key=fixture_key,
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

    def configure_blocked_feature(self):
        blocked = replace(
            self.bundle.targets[0].features[0],
            status="plugin_gap",
            evidence=replace(
                self.bundle.targets[0].features[0].evidence,
                outcome="fail",
            ),
        )
        target = replace(
            self.manifest.legacy_targets[0], features=(blocked,)
        )
        base_manifest = replace(
            self.manifest,
            scope=replace(self.manifest.scope, digest="0" * 64),
            legacy_targets=(target,),
        )
        self.manifest = replace(
            base_manifest,
            scope=replace(
                base_manifest.scope, digest=scope_digest(base_manifest)
            ),
        )
        approve_scope(
            self.state,
            self.manifest,
            self.bindings,
            revision=1,
            approved_on="2026-08-10",
        )
        self.provenance = replace(
            self.provenance,
            public_digest=self.manifest.scope.digest,
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
        self.bundle = replace(
            self.bundle,
            public_scope=canonical_scope(self.manifest).decode(),
            public_digest=self.manifest.scope.digest,
            targets=(
                replace(self.bundle.targets[0], features=(blocked,)),
            ),
            provenance=self.provenance,
            provenance_digest=provenance_digest(self.provenance),
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
        return self.bundle

    def configure_source(
        self,
        construct_ids,
        *,
        coverage="selected",
        binding_ids=None,
    ):
        relative = "plugins/sample.xml"
        source = self.legacy / relative
        source.write_text(
            "<muclient><plugin name=\"bound\"/>"
            "<plugin name=\"outside\"/></muclient>\n",
            encoding="utf-8",
        )
        feature_key = "sample_command"
        is_selected = coverage == "selected"
        feature_keys = (feature_key,) if is_selected else ()
        selected_legacy_source = LegacySource(
            "xml", relative, coverage, feature_keys
        )
        target = replace(
            self.manifest.legacy_targets[0],
            sources=(selected_legacy_source,),
        )
        base_manifest = replace(
            self.manifest,
            scope=replace(self.manifest.scope, digest="0" * 64),
            legacy_targets=(target,),
        )
        self.manifest = replace(
            base_manifest,
            scope=replace(
                base_manifest.scope, digest=scope_digest(base_manifest)
            ),
        )
        if is_selected:
            authenticated_ids = tuple(
                construct_ids if binding_ids is None else binding_ids
            )
            selected_bindings = (
                FeatureBinding(feature_key, authenticated_ids),
            )
            self.bindings = {
                "sample_legacy": {
                    relative: {feature_key: list(authenticated_ids)}
                }
            }
        else:
            selected_bindings = ()
            self.bindings = {"sample_legacy": {}}
        self.selection = SelectionState(
            version=1,
            included_targets=(
                IncludedTarget(
                    key="sample_legacy",
                    sources=(
                        SelectedSource(
                            "xml",
                            relative,
                            coverage,
                            feature_keys,
                            selected_bindings,
                        ),
                    ),
                    current_plugins=("sample",),
                ),
            ),
            omitted_candidates=(),
        )
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
        self.provenance = replace(
            self.provenance,
            public_digest=self.manifest.scope.digest,
            binding_digest=binding_digest(self.bindings),
            source_digests=(
                (relative, hashlib.sha256(source.read_bytes()).hexdigest()),
            ),
        )
        write_provenance(
            self.state,
            self.provenance,
            approved_paths=(relative,),
        )
        self.artifacts = {
            "manifest": render_manifest(self.manifest).encode(),
            "not_converted": render_not_converted(self.manifest).encode(),
            "parity_report": render_parity_report(self.manifest).encode(),
        }
        target_audit = replace(
            self.bundle.targets[0],
            construct_inventory=(
                SourceConstructs(relative, tuple(construct_ids)),
            ),
            assignments=(
                FeatureAssignment(
                    feature_key,
                    tuple(construct_ids),
                    tuple(construct_ids),
                ),
            ),
            features=target.features,
        )
        self.bundle = replace(
            self.bundle,
            public_scope=canonical_scope(self.manifest).decode(),
            public_digest=self.manifest.scope.digest,
            targets=(target_audit,),
            provenance=self.provenance,
            provenance_digest=provenance_digest(self.provenance),
            artifact_hashes=tuple(
                ArtifactHash(key, hashlib.sha256(value).hexdigest())
                for key, value in sorted(self.artifacts.items())
            ),
        )
        write_staged_bundle(
            self.state, self.bundle, public_repo=self.repo
        )
        for key, relative_path in (
            ("manifest", "legacy-parity.toml"),
            ("not_converted", "not-converted.md"),
            ("parity_report", "parity-report.md"),
        ):
            (self.repo / "validation" / relative_path).write_bytes(
                self.artifacts[key]
            )

    def test_selected_source_snapshot_accepts_only_authenticated_constructs(self):
        selected_id = "xml:plugins/sample.xml:2"
        self.configure_source((selected_id,))

        full_private_publication_gate(
            self.candidate(),
            self.bundle,
            self.roots,
            self.lera_bin,
        )

        (self.legacy / "plugins" / "sample.xml").unlink()
        with self.assertRaisesRegex(
            ValidationFailure, "^legacy_xml_extraction_failed$"
        ):
            full_private_publication_gate(
                self.candidate(),
                self.bundle,
                self.roots,
                self.lera_bin,
            )

    def test_selected_source_snapshot_rejects_omitted_authenticated_binding(self):
        selected_ids = (
            "xml:plugins/sample.xml:2",
            "xml:plugins/sample.xml:3",
        )
        self.configure_source(
            selected_ids[:1],
            binding_ids=selected_ids,
        )

        with self.assertRaisesRegex(
            ValidationFailure, "legacy_construct_drift"
        ):
            full_private_publication_gate(
                self.candidate(),
                self.bundle,
                self.roots,
                self.lera_bin,
            )

    def test_selected_source_snapshot_rejects_unselected_construct(self):
        selected_id = "xml:plugins/sample.xml:2"
        inventory_ids = (
            selected_id,
            "xml:plugins/sample.xml:3",
        )
        self.configure_source(
            inventory_ids,
            binding_ids=(selected_id,),
        )

        with self.assertRaisesRegex(
            ValidationFailure, "legacy_construct_drift"
        ):
            full_private_publication_gate(
                self.candidate(),
                self.bundle,
                self.roots,
                self.lera_bin,
            )

    def test_selected_source_snapshot_rejects_missing_source_construct(self):
        missing_id = "xml:plugins/sample.xml:4"
        self.configure_source(
            (missing_id,),
            binding_ids=(missing_id,),
        )

        with self.assertRaisesRegex(
            ValidationFailure, "legacy_construct_drift"
        ):
            full_private_publication_gate(
                self.candidate(),
                self.bundle,
                self.roots,
                self.lera_bin,
            )

    def test_complete_source_snapshot_still_requires_full_extraction(self):
        full_ids = (
            "xml:plugins/sample.xml:2",
            "xml:plugins/sample.xml:3",
        )
        self.configure_source(full_ids, coverage="complete")

        full_private_publication_gate(
            self.candidate(),
            self.bundle,
            self.roots,
            self.lera_bin,
        )

        partial_target = replace(
            self.bundle.targets[0],
            construct_inventory=(
                SourceConstructs(
                    "plugins/sample.xml",
                    full_ids[:1],
                ),
            ),
            assignments=(
                FeatureAssignment(
                    "sample_command",
                    full_ids[:1],
                    full_ids[:1],
                ),
            ),
        )
        self.bundle = replace(self.bundle, targets=(partial_target,))
        write_staged_bundle(
            self.state, self.bundle, public_repo=self.repo
        )
        with self.assertRaisesRegex(
            ValidationFailure, "legacy_construct_drift"
        ):
            full_private_publication_gate(
                self.candidate(),
                self.bundle,
                self.roots,
                self.lera_bin,
            )

    def test_shared_selected_source_bindings_are_scoped_per_target(self):
        relative = "plugins/sample.xml"
        (self.legacy / relative).write_text(
            "<muclient><plugin name=\"alpha\"/>"
            "<plugin name=\"beta\"/></muclient>\n",
            encoding="utf-8",
        )
        alpha_id = "xml:plugins/sample.xml:2"
        beta_id = "xml:plugins/sample.xml:3"
        targets = tuple(
            replace(
                self.bundle.targets[0],
                key=target_key,
                construct_inventory=(
                    SourceConstructs(relative, (construct_id,)),
                ),
            )
            for target_key, construct_id in (
                ("target_alpha", alpha_id),
                ("target_beta", beta_id),
            )
        )
        selection = SelectionState(
            version=1,
            included_targets=tuple(
                IncludedTarget(
                    key=target_key,
                    sources=(
                        SelectedSource(
                            "xml",
                            relative,
                            "selected",
                            (feature_key,),
                            (
                                FeatureBinding(
                                    feature_key,
                                    (construct_id,),
                                ),
                            ),
                        ),
                    ),
                    current_plugins=("sample",),
                )
                for target_key, feature_key, construct_id in (
                    ("target_alpha", "feature_alpha", alpha_id),
                    ("target_beta", "feature_beta", beta_id),
                )
            ),
            omitted_candidates=(),
        )

        _validate_construct_snapshots(
            replace(self.bundle, targets=targets),
            self.legacy,
            selection,
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

    def test_full_private_privacy_authenticates_scope_before_stem_exceptions(self):
        exact_omitted_path = "omitted/sample_legacy.xml"
        self.selection = replace(
            self.selection,
            omitted_candidates=(
                exact_omitted_path,
                "omitted/unrelated_hidden.xml",
            ),
        )
        write_selection(
            self.state, self.selection, public_repo=self.repo
        )

        full_private_publication_gate(
            self.candidate(),
            self.bundle,
            self.roots,
            self.lera_bin,
        )

        leaked_feature = replace(
            self.manifest.legacy_targets[0].features[0],
            summary=f"Exposes {exact_omitted_path}.",
        )
        changed_manifest_target = replace(
            self.manifest.legacy_targets[0],
            features=(leaked_feature,),
        )
        self.manifest = replace(
            self.manifest,
            legacy_targets=(changed_manifest_target,),
        )
        self.artifacts = {
            "manifest": render_manifest(self.manifest).encode(),
            "not_converted": render_not_converted(self.manifest).encode(),
            "parity_report": render_parity_report(self.manifest).encode(),
        }
        changed_audit_target = replace(
            self.bundle.targets[0],
            features=(leaked_feature,),
        )
        self.bundle = replace(
            self.bundle,
            targets=(changed_audit_target,),
            artifact_hashes=tuple(
                ArtifactHash(key, hashlib.sha256(value).hexdigest())
                for key, value in sorted(self.artifacts.items())
            ),
        )
        write_staged_bundle(
            self.state, self.bundle, public_repo=self.repo
        )

        with self.assertRaisesRegex(
            ValidationFailure, "privacy_violation"
        ):
            full_private_publication_gate(
                self.candidate(),
                self.bundle,
                self.roots,
                self.lera_bin,
            )

    def test_validation_levels_enforce_strict_mode_and_private_roots(self):
        with self.assertRaisesRegex(
            ValueError, "require_parity_private_only"
        ):
            validate_public(self.repo, require_parity=True)
        changed_bundle = self.configure_blocked_feature()
        with self.assertRaisesRegex(ValidationFailure, "strict_parity_status"):
            full_private_publication_gate(
                self.candidate(),
                changed_bundle,
                self.roots,
                self.lera_bin,
                require_parity=True,
            )

    def test_strict_mode_reports_runtime_fixture_drift_before_status(self):
        blocked = replace(
            self.bundle.targets[0].features[0],
            status="plugin_gap",
            evidence=replace(
                self.bundle.targets[0].features[0].evidence,
                outcome="fail",
            ),
        )
        target = replace(
            self.manifest.legacy_targets[0], features=(blocked,)
        )
        base_manifest = replace(
            self.manifest,
            scope=replace(self.manifest.scope, digest="0" * 64),
            legacy_targets=(target,),
        )
        self.manifest = replace(
            base_manifest,
            scope=replace(
                base_manifest.scope, digest=scope_digest(base_manifest)
            ),
        )
        self.approval = approve_scope(
            self.state,
            self.manifest,
            self.bindings,
            revision=1,
            approved_on="2026-08-10",
        )
        self.provenance = replace(
            self.provenance,
            public_digest=self.manifest.scope.digest,
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
        changed_bundle = replace(
            self.bundle,
            public_scope=canonical_scope(self.manifest).decode(),
            public_digest=self.manifest.scope.digest,
            targets=(
                replace(self.bundle.targets[0], features=(blocked,)),
            ),
            provenance=self.provenance,
            provenance_digest=provenance_digest(self.provenance),
            artifact_hashes=tuple(
                ArtifactHash(key, hashlib.sha256(value).hexdigest())
                for key, value in sorted(self.artifacts.items())
            ),
        )
        write_staged_bundle(
            self.state, changed_bundle, public_repo=self.repo
        )
        for key, relative in (
            ("manifest", "legacy-parity.toml"),
            ("not_converted", "not-converted.md"),
            ("parity_report", "parity-report.md"),
        ):
            (self.repo / "validation" / relative).write_bytes(
                self.artifacts[key]
            )
        scenario = (
            self.state / "staged" / "runtime" / "sample-scenario.json"
        )
        scenario.write_bytes(scenario.read_bytes() + b"\n")

        with self.assertRaisesRegex(
            ValidationFailure, "runtime_fixture_mismatch"
        ):
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

    def test_runtime_rerun_rejects_stale_stored_pass_after_plugin_drift(self):
        self.lera_bin.write_text(
            "#!/bin/sh\n"
            "if grep -q runtime_drift \"$1/plugins/sample.lua\"; then\n"
            "  exit 1\n"
            "fi\n"
            "exit 0\n",
            encoding="utf-8",
        )
        self.lera_bin.chmod(
            self.lera_bin.stat().st_mode | stat.S_IXUSR
        )
        full_private_publication_gate(
            self.candidate(),
            self.bundle,
            self.roots,
            self.lera_bin,
        )
        for root in (self.repo, self.lera / "plugins"):
            path = root / "generic" / "sample.lua"
            path.write_text(
                path.read_text(encoding="utf-8")
                + "\n-- runtime_drift\n",
                encoding="utf-8",
            )

        with self.assertRaisesRegex(ValidationFailure, "runtime_failure"):
            full_private_publication_gate(
                self.candidate(),
                self.bundle,
                self.roots,
                self.lera_bin,
            )

    def test_runtime_rejects_missing_scenario_file(self):
        self.runtime_scenario_path().unlink()

        with self.assertRaisesRegex(
            ValidationFailure, "runtime_fixture_mismatch"
        ):
            full_private_publication_gate(
                self.candidate(),
                self.bundle,
                self.roots,
                self.lera_bin,
            )

    def test_runtime_uses_only_supplied_state_root(self):
        path = self.runtime_scenario_path()
        decoy_root = self.state.parent / "decoy-state"
        decoy_runtime = decoy_root / "staged" / "runtime"
        decoy_runtime.mkdir(parents=True, mode=0o700)
        decoy_path = decoy_runtime / path.name
        decoy_path.write_bytes(path.read_bytes())
        decoy_path.chmod(0o600)
        path.unlink()
        previous = os.environ.get("XDG_STATE_HOME")
        os.environ["XDG_STATE_HOME"] = str(decoy_root)
        try:
            with self.assertRaisesRegex(
                ValidationFailure, "runtime_fixture_mismatch"
            ):
                full_private_publication_gate(
                    self.candidate(),
                    self.bundle,
                    self.roots,
                    self.lera_bin,
                )
        finally:
            if previous is None:
                os.environ.pop("XDG_STATE_HOME", None)
            else:
                os.environ["XDG_STATE_HOME"] = previous

    def test_runtime_rejects_scenario_byte_digest_mismatch(self):
        path = self.runtime_scenario_path()
        path.write_bytes(path.read_bytes() + b"\n")

        with self.assertRaisesRegex(
            ValidationFailure, "runtime_fixture_mismatch"
        ):
            full_private_publication_gate(
                self.candidate(),
                self.bundle,
                self.roots,
                self.lera_bin,
            )

    def test_runtime_sanitizes_malformed_scenario_shape(self):
        self.restage_runtime_scenario(
            expected={
                "effects": None,
                "registrations": {
                    "aliases": 0,
                    "triggers": 0,
                    "timers": 0,
                    "mip": 0,
                },
            }
        )

        with self.assertRaisesRegex(
            ValidationFailure, "runtime_fixture_mismatch"
        ):
            full_private_publication_gate(
                self.candidate(),
                self.bundle,
                self.roots,
                self.lera_bin,
            )

    @unittest.skipUnless(os.name == "posix", "POSIX descriptors required")
    def test_runtime_fixture_is_not_reopened_after_authentication(self):
        scenario_path = self.runtime_scenario_path()
        original_read_bytes = Path.read_bytes

        def fail_scenario_reopen(path):
            if path == scenario_path:
                raise AssertionError("runtime fixture reopened")
            return original_read_bytes(path)

        with mock.patch.object(Path, "read_bytes", fail_scenario_reopen):
            full_private_publication_gate(
                self.candidate(),
                self.bundle,
                self.roots,
                self.lera_bin,
            )

    def test_runtime_rejects_scenario_identity_mismatch(self):
        self.restage_runtime_scenario(key="other-scenario")

        with self.assertRaisesRegex(
            ValidationFailure, "runtime_fixture_mismatch"
        ):
            full_private_publication_gate(
                self.candidate(),
                self.bundle,
                self.roots,
                self.lera_bin,
            )

    def test_runtime_rejects_scenario_target_mismatch(self):
        self.restage_runtime_scenario(target_key="other-target")

        with self.assertRaisesRegex(
            ValidationFailure, "runtime_fixture_mismatch"
        ):
            full_private_publication_gate(
                self.candidate(),
                self.bundle,
                self.roots,
                self.lera_bin,
            )

    def test_runtime_rejects_plugin_outside_approved_target_mapping(self):
        self.restage_runtime_scenario(plugin="generic/other.lua")

        with self.assertRaisesRegex(
            ValidationFailure, "runtime_fixture_mismatch"
        ):
            full_private_publication_gate(
                self.candidate(),
                self.bundle,
                self.roots,
                self.lera_bin,
            )

    def test_runtime_rejects_unsafe_fixture_keys_and_alternate_roots(self):
        for fixture_key in (
            "../escape",
            "nested/escape",
            str(self.state / "alternate"),
        ):
            with self.subTest(fixture_key=fixture_key):
                self.declare_runtime_fixture(fixture_key)
                with self.assertRaisesRegex(
                    ValidationFailure, "runtime_fixture_mismatch"
                ):
                    full_private_publication_gate(
                        self.candidate(),
                        self.bundle,
                        self.roots,
                        self.lera_bin,
                    )

    @unittest.skipUnless(os.name == "posix", "POSIX permissions required")
    def test_runtime_rejects_symlink_escape(self):
        path = self.runtime_scenario_path()
        outside = self.state / "outside-scenario.json"
        outside.write_bytes(path.read_bytes())
        outside.chmod(0o600)
        path.unlink()
        path.symlink_to(outside)

        with self.assertRaisesRegex(
            ValidationFailure, "runtime_fixture_mismatch"
        ):
            full_private_publication_gate(
                self.candidate(),
                self.bundle,
                self.roots,
                self.lera_bin,
            )

    @unittest.skipUnless(os.name == "posix", "POSIX permissions required")
    def test_runtime_rejects_group_accessible_fixture_directory(self):
        self.runtime_scenario_path().parent.chmod(0o750)

        with self.assertRaisesRegex(
            ValidationFailure, "runtime_fixture_mismatch"
        ):
            full_private_publication_gate(
                self.candidate(),
                self.bundle,
                self.roots,
                self.lera_bin,
            )

    @unittest.skipUnless(os.name == "posix", "POSIX permissions required")
    def test_runtime_rejects_group_accessible_scenario_file(self):
        self.runtime_scenario_path().chmod(0o640)

        with self.assertRaisesRegex(
            ValidationFailure, "runtime_fixture_mismatch"
        ):
            full_private_publication_gate(
                self.candidate(),
                self.bundle,
                self.roots,
                self.lera_bin,
            )

    def test_runtime_rejects_nonzero_fresh_outcome(self):
        self.lera_bin.write_text("#!/bin/sh\nexit 7\n", encoding="utf-8")
        self.lera_bin.chmod(
            self.lera_bin.stat().st_mode | stat.S_IXUSR
        )

        with self.assertRaisesRegex(ValidationFailure, "runtime_failure"):
            full_private_publication_gate(
                self.candidate(),
                self.bundle,
                self.roots,
                self.lera_bin,
            )

    def test_runtime_rejects_stored_result_summary_mismatch(self):
        result = replace(
            self.bundle.runtime_results[0], result="Stored pass."
        )
        self.bundle = replace(self.bundle, runtime_results=(result,))
        write_staged_bundle(
            self.state, self.bundle, public_repo=self.repo
        )

        with self.assertRaisesRegex(
            ValidationFailure, "runtime_result_mismatch"
        ):
            full_private_publication_gate(
                self.candidate(),
                self.bundle,
                self.roots,
                self.lera_bin,
            )

    def test_runtime_preserves_staged_key_set_and_digest_checks(self):
        changes = (
            replace(
                self.bundle.runtime_results[0],
                scenario_key="other-scenario",
            ),
            replace(
                self.bundle.runtime_results[0],
                fixture_digest="f" * 64,
            ),
        )
        for changed in changes:
            with self.subTest(changed=changed):
                bundle = replace(
                    self.bundle, runtime_results=(changed,)
                )
                write_staged_bundle(
                    self.state, bundle, public_repo=self.repo
                )
                with self.assertRaisesRegex(
                    ValidationFailure, "runtime_result_mismatch"
                ):
                    full_private_publication_gate(
                        self.candidate(),
                        bundle,
                        self.roots,
                        self.lera_bin,
                    )

    def test_refresh_strict_failure_writes_no_private_state(self):
        self.configure_blocked_feature()
        prior_provenance = (self.state / "provenance.json").read_bytes()
        prior_bundle = (
            self.state / "staged" / "audit-bundle.json"
        ).read_bytes()

        with self.assertRaisesRegex(ValidationFailure, "strict_parity_status"):
            validate_full_private(
                roots=self.roots,
                lera_bin=self.lera_bin,
                require_parity=True,
                refresh_legacy=True,
                verified_at="2026-08-10T15:30:00+00:00",
            )
        self.assertEqual(
            (self.state / "provenance.json").read_bytes(),
            prior_provenance,
        )
        self.assertEqual(
            (self.state / "staged" / "audit-bundle.json").read_bytes(),
            prior_bundle,
        )

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
