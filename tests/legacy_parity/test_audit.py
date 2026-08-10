import contextlib
import io
import json
import os
import shutil
import tempfile
import unittest
from dataclasses import asdict, replace
from pathlib import Path

from tools.legacy_parity.cli import main
from tools.legacy_parity.audit import (
    PreliminaryAudit,
    PreliminaryBehavior,
    current_source_digest,
    load_preliminary_audit,
    stage_preliminary_audit,
    validate_preliminary_audits,
)
from tools.legacy_parity.current import discover_current, extract_current
from tools.legacy_parity.legacy import (
    IncludedTarget,
    SelectionState,
    write_selection,
)


FIXTURE = Path(__file__).resolve().parent / "fixtures" / "current"


class PreliminaryAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.plugin_root = Path(self.temp.name) / "plugins"
        self.state_root = Path(self.temp.name) / "private-state"
        (self.plugin_root / "generic").mkdir(parents=True)
        shutil.copy2(
            FIXTURE / "generic" / "sample.lua",
            self.plugin_root / "generic" / "sample.lua",
        )
        self.current_path = self.plugin_root / "generic" / "sample.lua"
        self.constructs = extract_current(
            self.current_path, "generic/sample.lua"
        )
        self.selection = SelectionState(
            version=1,
            included_targets=(
                IncludedTarget(
                    key="sample_target",
                    sources=(),
                    current_plugins=("sample",),
                ),
            ),
            omitted_candidates=(),
        )
        self.audit = PreliminaryAudit(
            version=1,
            current_key="sample",
            current_path="generic/sample.lua",
            source_digest=current_source_digest(self.current_path),
            construct_ids=tuple(item.id for item in self.constructs),
            target_keys=("sample_target",),
            current_only_rationale=None,
            preliminary_status_counts=(("parity", len(self.constructs)),),
            confirmed_blocker_keys=(),
            review_date="2026-08-10",
            complete=True,
            behaviors=tuple(
                PreliminaryBehavior(
                    construct_id=item.id,
                    status="parity",
                    target_keys=("sample_target",),
                    reviewed=True,
                    observation="Synthetic behavior reviewed.",
                    blocker_keys=(),
                )
                for item in self.constructs
            ),
        )

    def tearDown(self):
        self.temp.cleanup()

    def write_record(self, audit=None, *, path=None):
        self.state_root.mkdir(parents=True, exist_ok=True)
        record = path or self.state_root / "candidate.json"
        record.write_text(
            json.dumps(asdict(audit or self.audit)),
            encoding="utf-8",
        )
        return record

    def stage(self, audit=None):
        return stage_preliminary_audit(
            self.state_root,
            self.write_record(audit),
            plugin_root=self.plugin_root,
            selection=self.selection,
        )

    def test_stages_round_trip_atomically_with_private_permissions(self):
        self.assertEqual(self.stage(), self.audit)
        self.assertEqual(
            load_preliminary_audit(self.state_root, "sample"), self.audit
        )
        self.assertEqual(
            validate_preliminary_audits(
                self.state_root, self.plugin_root, self.selection
            ),
            (self.audit,),
        )
        if os.name == "posix":
            self.assertEqual(
                (self.state_root / "preliminary" / "sample.json").stat().st_mode
                & 0o777,
                0o600,
            )

    def test_accepts_audit_input_only_from_private_state(self):
        outside = Path(self.temp.name) / "outside.json"
        self.write_record(path=outside)
        with self.assertRaisesRegex(ValueError, "audit_record_not_private"):
            stage_preliminary_audit(
                self.state_root,
                outside,
                plugin_root=self.plugin_root,
                selection=self.selection,
            )

    def test_rejects_source_and_construct_inventory_drift(self):
        self.stage()
        self.current_path.write_text("return {}\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "current_source_changed"):
            validate_preliminary_audits(
                self.state_root, self.plugin_root, self.selection
            )

        shutil.copy2(
            FIXTURE / "generic" / "sample.lua",
            self.current_path,
        )
        changed = replace(
            self.audit,
            construct_ids=self.audit.construct_ids[:-1],
            complete=False,
            behaviors=self.audit.behaviors[:-1],
            preliminary_status_counts=(
                ("parity", len(self.audit.behaviors) - 1),
            ),
        )
        with self.assertRaisesRegex(ValueError, "current_inventory_changed"):
            self.stage(changed)

    def test_rejects_unknown_or_disagreeing_target_mappings(self):
        for target_keys in ((), ("unknown_target",)):
            with self.subTest(target_keys=target_keys):
                changed = replace(self.audit, target_keys=target_keys)
                with self.assertRaisesRegex(
                    ValueError, "preliminary_target_mismatch"
                ):
                    self.stage(changed)

    def test_rejects_mapping_shape_and_status_inconsistency(self):
        changed = replace(
            self.audit,
            current_only_rationale="Incorrectly marked current-only.",
        )
        with self.assertRaisesRegex(ValueError, "mapped_current_only_rationale"):
            self.stage(changed)

        changed = replace(
            self.audit,
            preliminary_status_counts=(("plugin_gap", len(self.constructs)),),
        )
        with self.assertRaisesRegex(ValueError, "preliminary_status_counts"):
            self.stage(changed)

        first = replace(
            self.audit.behaviors[0],
            status="lera_blocker",
            blocker_keys=("missing_api",),
        )
        changed = replace(
            self.audit,
            behaviors=(first,) + self.audit.behaviors[1:],
            preliminary_status_counts=(
                ("lera_blocker", 1),
                ("parity", len(self.constructs) - 1),
            ),
        )
        with self.assertRaisesRegex(ValueError, "confirmed_blocker_keys"):
            self.stage(changed)

    def test_complete_requires_every_behavior_reviewed_and_classified(self):
        missing = replace(
            self.audit,
            behaviors=self.audit.behaviors[:-1],
            preliminary_status_counts=(
                ("parity", len(self.audit.behaviors) - 1),
            ),
        )
        with self.assertRaisesRegex(
            ValueError, "incomplete_current_classification"
        ):
            self.stage(missing)

        unreviewed_behavior = replace(self.audit.behaviors[0], reviewed=False)
        unreviewed = replace(
            self.audit,
            behaviors=(unreviewed_behavior,) + self.audit.behaviors[1:],
        )
        with self.assertRaisesRegex(ValueError, "unreviewed_current_behavior"):
            self.stage(unreviewed)

    def test_empty_mapping_requires_explicit_current_only_rationale(self):
        no_targets = SelectionState(
            version=1, included_targets=(), omitted_candidates=()
        )
        behaviors = tuple(
            replace(
                item,
                status="current_only",
                target_keys=(),
            )
            for item in self.audit.behaviors
        )
        changed = replace(
            self.audit,
            target_keys=(),
            current_only_rationale=None,
            behaviors=behaviors,
            preliminary_status_counts=(("current_only", len(behaviors)),),
        )
        self.write_record(changed)
        with self.assertRaisesRegex(
            ValueError, "current_only_rationale_required"
        ):
            stage_preliminary_audit(
                self.state_root,
                self.state_root / "candidate.json",
                plugin_root=self.plugin_root,
                selection=no_targets,
            )

    def test_requires_one_audit_for_every_discovered_current_plugin(self):
        self.stage()
        (self.plugin_root / "3scapes").mkdir()
        (self.plugin_root / "3scapes" / "second.lua").write_text(
            "return {}\n", encoding="utf-8"
        )
        self.assertEqual(
            tuple(item.key for item in discover_current(self.plugin_root)),
            ("sample", "second"),
        )
        with self.assertRaisesRegex(ValueError, "preliminary_audit_set"):
            validate_preliminary_audits(
                self.state_root, self.plugin_root, self.selection
            )

    def test_cli_stages_and_checks_without_echoing_private_names(self):
        write_selection(
            self.state_root,
            self.selection,
            public_repo=self.plugin_root,
        )
        record = self.write_record()
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = main(
                [
                    "stage-preliminary",
                    "--plugin-root",
                    str(self.plugin_root),
                    "--state-root",
                    str(self.state_root),
                    "--record",
                    str(record),
                ]
            )
        self.assertEqual(code, 0)
        self.assertEqual(output.getvalue(), "Preliminary audit staged.\n")

        legacy_root = Path(self.temp.name) / "legacy"
        legacy_root.mkdir()
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = main(
                [
                    "check-preliminary",
                    "--plugin-root",
                    str(self.plugin_root),
                    "--legacy-root",
                    str(legacy_root),
                    "--state-root",
                    str(self.state_root),
                ]
            )
        self.assertEqual(code, 0)
        self.assertEqual(output.getvalue(), "Preliminary audits valid.\n")


if __name__ == "__main__":
    unittest.main()
