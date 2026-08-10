import contextlib
import hashlib
import io
import json
import shutil
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
)
from tools.legacy_parity.cli import entrypoint
from tools.legacy_parity.current import extract_current
from tools.legacy_parity.issues import (
    CommandResult,
    marker_for,
    sync_capability_issue,
)
from tools.legacy_parity.legacy import load_selection
from tools.legacy_parity.manifest import render_manifest
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
from tools.legacy_parity.publish import PUBLIC_PATHS
from tools.legacy_parity.report import (
    render_not_converted,
    render_parity_report,
)
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
    provenance_digest,
    write_staged_bundle,
)
from tools.legacy_parity.state import (
    LocalEvidence,
    ProvenanceState,
    load_approval,
    load_provenance,
    write_provenance,
)


FIXTURE = Path(__file__).resolve().parent / "fixtures" / "acceptance"


class AcceptanceWorkflow:
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.repo = root / "repo"
        self.legacy = root / "legacy"
        self.lera = root / "lera"
        self.state = root / "state"
        shutil.copytree(FIXTURE / "current", self.repo)
        shutil.copytree(FIXTURE / "legacy", self.legacy)
        shutil.copytree(
            FIXTURE / "current", self.lera / "plugins"
        )
        self.lera_bin = root / "lera-bin"
        self.lera_bin.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.lera_bin.chmod(
            self.lera_bin.stat().st_mode | stat.S_IXUSR
        )
        self.outputs = []
        self._git_init()

    def close(self):
        self.temporary.cleanup()

    def _git_init(self):
        commands = (
            ("git", "init", "-q", str(self.legacy)),
            (
                "git",
                "-C",
                str(self.legacy),
                "config",
                "user.name",
                "Acceptance",
            ),
            (
                "git",
                "-C",
                str(self.legacy),
                "config",
                "user.email",
                "acceptance@example.invalid",
            ),
            ("git", "-C", str(self.legacy), "add", "plugins"),
            (
                "git",
                "-C",
                str(self.legacy),
                "commit",
                "-qm",
                "fixtures",
            ),
        )
        for command in commands:
            subprocess.run(
                command,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

    def run(self, arguments):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            code = entrypoint(arguments)
        text = stdout.getvalue() + stderr.getvalue()
        self.outputs.append(text)
        return code, text

    def state_args(self):
        return ("--state-root", str(self.state))

    def bootstrap(self):
        code, discovered = self.run(
            [
                "discover",
                "--legacy-root",
                str(self.legacy),
                *self.state_args(),
            ]
        )
        assert code == 0
        assert "plugins/orbit.xml" in discovered
        assert "plugins/skip.xml" in discovered
        self.outputs.clear()

        self.state.mkdir(parents=True, exist_ok=True)
        target_record = self.state / "target.json"
        target_record.write_text(
            json.dumps(
                {
                    "key": "orbit_legacy",
                    "sources": [
                        {
                            "kind": "xml",
                            "path": "plugins/orbit.xml",
                            "coverage": "complete",
                            "feature_keys": [],
                            "bindings": [],
                        }
                    ],
                    "current_plugins": ["orbit"],
                }
            ),
            encoding="utf-8",
        )
        code, _ = self.run(
            [
                "select",
                "--legacy-root",
                str(self.legacy),
                "--include-target-record",
                str(target_record),
                "--public-repo",
                str(self.repo),
                *self.state_args(),
            ]
        )
        assert code == 0
        code, _ = self.run(
            [
                "select",
                "--legacy-root",
                str(self.legacy),
                "--omit",
                "plugins/skip.xml",
                "--public-repo",
                str(self.repo),
                *self.state_args(),
            ]
        )
        assert code == 0

        current_path = self.repo / "generic" / "orbit.lua"
        constructs = extract_current(
            current_path, "generic/orbit.lua"
        )
        audit = PreliminaryAudit(
            version=1,
            current_key="orbit",
            current_path="generic/orbit.lua",
            source_digest=current_source_digest(current_path),
            construct_ids=tuple(item.id for item in constructs),
            target_keys=("orbit_legacy",),
            current_only_rationale=None,
            preliminary_status_counts=(("lera_blocker", len(constructs)),),
            confirmed_blocker_keys=("synthetic_api",),
            review_date="2026-08-10",
            complete=True,
            behaviors=tuple(
                PreliminaryBehavior(
                    construct_id=item.id,
                    status="lera_blocker",
                    target_keys=("orbit_legacy",),
                    reviewed=True,
                    observation="Synthetic capability reviewed.",
                    blocker_keys=("synthetic_api",),
                )
                for item in constructs
            ),
        )
        audit_record = self.state / "preliminary.json"
        audit_record.write_text(
            json.dumps(asdict(audit)), encoding="utf-8"
        )
        code, _ = self.run(
            [
                "stage-preliminary",
                "--plugin-root",
                str(self.repo),
                "--record",
                str(audit_record),
                *self.state_args(),
            ]
        )
        assert code == 0
        proposal = self.state / "proposal.json"
        code, _ = self.run(
            [
                "propose-scope",
                "--legacy-root",
                str(self.legacy),
                "--plugin-root",
                str(self.repo),
                "--output",
                str(proposal),
                *self.state_args(),
            ]
        )
        assert code == 0
        proposed = json.loads(proposal.read_text(encoding="utf-8"))
        code, _ = self.run(
            [
                "approve-scope",
                "--proposal",
                str(proposal),
                "--revision",
                str(proposed["revision"]),
                "--approved-on",
                "2026-08-10",
                "--confirmed-public-digest",
                proposed["public_digest"],
                "--confirmed-binding-digest",
                proposed["binding_digest"],
                *self.state_args(),
            ]
        )
        assert code == 0
        self._stage_complete_bundle()

    def _stage_complete_bundle(self):
        approval = load_approval(self.state)
        feature = Feature(
            key="orbit_action",
            category="public_api",
            status="lera_blocker",
            summary="Approved behavior requires a synthetic Lera capability.",
            current_refs=("generic/orbit.lua:3",),
            evidence=Evidence(
                type="manual_private_review",
                review_date="2026-08-10",
                reviewed_scope="Approved synthetic behavior.",
                result="Synthetic capability is not available.",
                outcome="fail",
                local_key="evidence_orbit",
            ),
            capability="synthetic_api",
        )
        capability = Capability(
            "synthetic_api",
            "Synthetic approved capability.",
            "https://github.com/lundmark/lera/issues/77",
        )
        manifest = Manifest(
            scope=ScopeApproval(
                approval.revision,
                approval.approved_on,
                approval.public_digest,
            ),
            current_plugins=(
                CurrentPlugin(
                    "orbit",
                    "generic/orbit.lua",
                    ("orbit_legacy",),
                    ("orbit-scenario",),
                ),
            ),
            legacy_targets=(
                LegacyTarget(
                    key="orbit_legacy",
                    sources=(
                        LegacySource(
                            "xml", "plugins/orbit.xml", "complete"
                        ),
                    ),
                    current_plugins=("orbit",),
                    features=(feature,),
                ),
            ),
            capabilities=(capability,),
        )
        assert render_manifest(manifest)
        artifacts = {
            "manifest": render_manifest(manifest).encode(),
            "not_converted": render_not_converted(manifest).encode(),
            "parity_report": render_parity_report(manifest).encode(),
        }
        evidence = LocalEvidence(
            key="evidence_orbit",
            target="orbit_legacy",
            feature="orbit_action",
            evidence_type="manual_private_review",
            review_date="2026-08-10",
            construct_scope=("xml:plugins/orbit.xml:1",),
            outcome="fail",
            result="Synthetic capability is not available.",
        )
        commit = subprocess.run(
            ("git", "-C", str(self.legacy), "rev-parse", "HEAD"),
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        ).stdout.strip()
        source = self.legacy / "plugins" / "orbit.xml"
        provenance = ProvenanceState(
            version=1,
            scope_revision=approval.revision,
            public_digest=approval.public_digest,
            binding_digest=approval.binding_digest,
            legacy_commit=commit,
            source_digests=(
                (
                    "plugins/orbit.xml",
                    hashlib.sha256(source.read_bytes()).hexdigest(),
                ),
            ),
            evidence=(evidence,),
            refreshed_at="2026-08-10T12:00:00+00:00",
        )
        write_provenance(
            self.state,
            provenance,
            approved_paths=("plugins/orbit.xml",),
        )
        bundle = StagedAuditBundle(
            version=1,
            scope_revision=approval.revision,
            public_scope=approval.public_scope,
            public_digest=approval.public_digest,
            targets=(
                TargetAudit(
                    key="orbit_legacy",
                    source_paths=("plugins/orbit.xml",),
                    dependency_closure=("plugins/orbit.xml",),
                    construct_inventory=(
                        SourceConstructs(
                            "plugins/orbit.xml",
                            ("xml:plugins/orbit.xml:1",),
                        ),
                    ),
                    assignments=(
                        FeatureAssignment(
                            "orbit_action",
                            ("xml:plugins/orbit.xml:1",),
                            ("xml:plugins/orbit.xml:1",),
                        ),
                    ),
                    current_only_rationales=(),
                    features=(feature,),
                    current_plugins=("orbit",),
                ),
            ),
            evidence=(evidence,),
            blockers=(
                BlockerAudit(
                    key="synthetic_api",
                    description="Synthetic approved capability.",
                    evidence_keys=("evidence_orbit",),
                    issue_url="https://github.com/lundmark/lera/issues/77",
                    affected_features=("orbit_legacy.orbit_action",),
                    affected_plugins=("orbit",),
                ),
            ),
            provenance=provenance,
            provenance_digest=provenance_digest(provenance),
            runtime_scenarios=(
                RuntimeScenario(
                    "orbit-runtime",
                    "orbit_legacy",
                    "orbit-scenario",
                    "4" * 64,
                ),
            ),
            runtime_results=(
                RuntimeResult(
                    "orbit-runtime",
                    "pass",
                    "4" * 64,
                    "Scenario passed.",
                ),
            ),
            artifact_hashes=tuple(
                ArtifactHash(key, hashlib.sha256(value).hexdigest())
                for key, value in sorted(artifacts.items())
            ),
        )
        candidate = self.state / "candidate-bundle.json"
        candidate.write_text(
            json.dumps(asdict(bundle), sort_keys=True), encoding="utf-8"
        )
        code, _ = self.run(
            [
                "stage-audit",
                "--input",
                str(candidate),
                "--public-repo",
                str(self.repo),
                *self.state_args(),
            ]
        )
        assert code == 0
        self.bundle = bundle

    def staged_path(self):
        return self.state / "staged" / "audit-bundle.json"

    def publish(self):
        return self.run(
            [
                "publish",
                "--staged",
                str(self.staged_path()),
                "--plugin-root",
                str(self.repo),
                "--legacy-root",
                str(self.legacy),
                "--lera-root",
                str(self.lera),
                "--lera-bin",
                str(self.lera_bin),
                *self.state_args(),
            ]
        )

    def validate(self, level):
        arguments = [
            "validate",
            "--level",
            level,
            "--plugin-root",
            str(self.repo),
            *self.state_args(),
        ]
        if level == "full-private":
            arguments.extend(
                (
                    "--legacy-root",
                    str(self.legacy),
                    "--lera-root",
                    str(self.lera),
                    "--lera-bin",
                    str(self.lera_bin),
                )
            )
        return self.run(arguments)

    def public_bytes(self):
        return {
            key: (self.repo / relative).read_bytes()
            for key, relative in PUBLIC_PATHS.items()
        }

    def dry_run_issue_sync(self):
        marker = marker_for("synthetic_api")

        def runner(arguments):
            joined = " ".join(arguments)
            if "repo view" in joined:
                value = {
                    "nameWithOwner": "lundmark/lera",
                    "visibility": "PRIVATE",
                }
            elif "is:open" in joined:
                value = {
                    "items": [
                        {
                            "state": "open",
                            "body": marker,
                            "html_url": (
                                "https://github.com/lundmark/lera/issues/77"
                            ),
                        }
                    ]
                }
            elif "is:closed" in joined:
                value = {"items": []}
            else:
                raise AssertionError(arguments)
            return CommandResult(0, json.dumps(value), "")

        return sync_capability_issue(
            self.bundle,
            "synthetic_api",
            runner,
            state_root=self.state,
            public_repo=self.repo,
            validate_bundle=lambda value: None,
            dry_run=True,
        )


class WholeValidatorAcceptanceTests(unittest.TestCase):
    def workflow(self):
        workflow = AcceptanceWorkflow()
        self.addCleanup(workflow.close)
        workflow.bootstrap()
        return workflow

    def test_complete_private_to_public_workflow_suppresses_opt_out(self):
        workflow = self.workflow()
        sync = workflow.dry_run_issue_sync()
        self.assertEqual(sync.exit_code, 0)
        self.assertEqual(workflow.publish()[0], 0)
        self.assertEqual(workflow.validate("full-private")[0], 0)
        self.assertEqual(workflow.validate("public")[0], 0)

        public = b"".join(workflow.public_bytes().values())
        ordinary_output = "".join(workflow.outputs)
        self.assertNotIn(b"skip", public.lower())
        self.assertNotIn("skip", ordinary_output.lower())
        selection = load_selection(workflow.state)
        self.assertEqual(len(selection.included_targets), 1)
        self.assertEqual(len(selection.omitted_candidates), 1)

    def test_private_mutations_block_publication_without_partial_update(self):
        cases = (
            "approved_source",
            "current_mapping",
            "mirror",
            "coverage",
            "reverse_mapping",
            "evidence_scope",
            "issue_url",
            "runtime",
            "approval_digest",
        )
        for name in cases:
            with self.subTest(name=name):
                workflow = AcceptanceWorkflow()
                try:
                    workflow.bootstrap()
                    self.assertEqual(workflow.publish()[0], 0)
                    original = workflow.public_bytes()
                    self._mutate(workflow, name)
                    code, _ = workflow.publish()
                    self.assertIn(code, {1, 2, 3})
                    self.assertEqual(workflow.public_bytes(), original)
                finally:
                    workflow.close()

    def _mutate(self, workflow, name):
        if name == "approved_source":
            path = workflow.legacy / "plugins" / "orbit.xml"
            path.write_text(
                '<muclient name="orbit"></muclient>\n<!-- drift -->\n',
                encoding="utf-8",
            )
            return
        if name == "current_mapping":
            path = workflow.state / "selection.json"
            value = json.loads(path.read_text(encoding="utf-8"))
            value["included_targets"][0]["current_plugins"] = []
            path.write_text(json.dumps(value), encoding="utf-8")
            return
        if name == "mirror":
            path = workflow.lera / "plugins" / "generic" / "orbit.lua"
            path.write_text("return {}\n", encoding="utf-8")
            return
        bundle = load_staged_bundle(workflow.state)
        target = bundle.targets[0]
        if name == "coverage":
            assignment = replace(
                target.assignments[0], construct_ids=()
            )
            target = replace(target, assignments=(assignment,))
            bundle = replace(bundle, targets=(target,))
        elif name == "reverse_mapping":
            target = replace(
                target,
                current_only_rationales=(
                    ("orbit_action", "Synthetic rationale."),
                ),
            )
            bundle = replace(bundle, targets=(target,))
        elif name == "evidence_scope":
            assignment = replace(
                target.assignments[0], evidence_scope=()
            )
            target = replace(target, assignments=(assignment,))
            bundle = replace(bundle, targets=(target,))
        elif name == "issue_url":
            blocker = replace(
                bundle.blockers[0],
                issue_url="https://example.invalid/issues/77",
            )
            bundle = replace(bundle, blockers=(blocker,))
        elif name == "runtime":
            result = replace(bundle.runtime_results[0], outcome="fail")
            bundle = replace(bundle, runtime_results=(result,))
        elif name == "approval_digest":
            path = workflow.state / "approval.json"
            value = json.loads(path.read_text(encoding="utf-8"))
            value["public_digest"] = "f" * 64
            path.write_text(json.dumps(value), encoding="utf-8")
            return
        write_staged_bundle(
            workflow.state, bundle, public_repo=workflow.repo
        )

    def test_public_report_drift_and_exit_classes_are_detected(self):
        workflow = self.workflow()
        self.assertEqual(workflow.publish()[0], 0)
        report = workflow.repo / PUBLIC_PATHS["parity_report"]
        original_report = report.read_bytes()
        report.write_bytes(original_report + b" ")
        self.assertEqual(workflow.validate("public")[0], 1)
        report.write_bytes(original_report)

        code, _ = workflow.run(
            [
                "validate",
                "--level",
                "full-private",
                "--plugin-root",
                str(workflow.repo),
                "--legacy-root",
                str(workflow.legacy),
                "--lera-root",
                str(workflow.lera),
                "--lera-bin",
                str(workflow.lera / "missing"),
                *workflow.state_args(),
            ]
        )
        self.assertEqual(code, 2)

        marker = marker_for("synthetic_api")

        def ambiguous_runner(arguments):
            joined = " ".join(arguments)
            if "repo view" in joined:
                value = {
                    "nameWithOwner": "lundmark/lera",
                    "visibility": "PRIVATE",
                }
            elif "is:open" in joined:
                value = {
                    "items": [
                        {
                            "state": "open",
                            "body": marker,
                            "html_url": (
                                "https://github.com/lundmark/lera/issues/77"
                            ),
                        },
                        {
                            "state": "open",
                            "body": marker,
                            "html_url": (
                                "https://github.com/lundmark/lera/issues/78"
                            ),
                        },
                    ]
                }
            else:
                value = {"items": []}
            return CommandResult(0, json.dumps(value), "")

        result = sync_capability_issue(
            workflow.bundle,
            "synthetic_api",
            ambiguous_runner,
            state_root=workflow.state,
            public_repo=workflow.repo,
            validate_bundle=lambda value: None,
            dry_run=True,
        )
        self.assertEqual(result.exit_code, 3)

    def test_reviewed_source_drift_refreshes_only_approved_provenance(self):
        workflow = self.workflow()
        self.assertEqual(workflow.publish()[0], 0)
        source = workflow.legacy / "plugins" / "orbit.xml"
        source.write_text(
            '<muclient name="orbit"></muclient>\n<!-- reviewed -->\n',
            encoding="utf-8",
        )
        code, _ = workflow.run(
            [
                "validate",
                "--level",
                "full-private",
                "--plugin-root",
                str(workflow.repo),
                "--legacy-root",
                str(workflow.legacy),
                "--lera-root",
                str(workflow.lera),
                "--lera-bin",
                str(workflow.lera_bin),
                "--refresh-legacy",
                *workflow.state_args(),
            ]
        )
        self.assertEqual(code, 0)
        provenance = load_provenance(workflow.state)
        self.assertEqual(len(provenance.source_digests), 1)
        self.assertEqual(
            provenance.source_digests[0][0], "plugins/orbit.xml"
        )
        selection = load_selection(workflow.state)
        self.assertEqual(len(selection.included_targets), 1)
        self.assertEqual(len(selection.omitted_candidates), 1)


if __name__ == "__main__":
    unittest.main()
