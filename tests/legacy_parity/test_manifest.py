import unittest
from dataclasses import replace
from pathlib import Path

from tools.legacy_parity.manifest import (
    load_manifest,
    render_manifest,
    validate_manifest,
)


FIXTURE = (
    Path(__file__).resolve().parent
    / "fixtures"
    / "public"
    / "valid-manifest.toml"
)


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.manifest = load_manifest(FIXTURE)

    def test_loads_and_round_trips_deterministically(self):
        self.assertEqual(self.manifest.scope.revision, 1)
        self.assertEqual(self.manifest.current_plugins[0].key, "sample_current")
        target = self.manifest.legacy_targets[0]
        self.assertEqual(target.current_plugins, ("sample_current",))
        self.assertEqual(target.sources[0].coverage, "selected")
        self.assertEqual(target.features[0].status, "parity")
        self.assertEqual(validate_manifest(self.manifest), ())
        self.assertEqual(render_manifest(self.manifest), FIXTURE.read_text())

    def test_selected_source_requires_feature_keys(self):
        target = self.manifest.legacy_targets[0]
        source = replace(target.sources[0], feature_keys=())
        changed = replace(
            self.manifest,
            legacy_targets=(replace(target, sources=(source,)),),
        )
        self.assertIn("selected_source_without_features", validate_manifest(changed))

    def test_complete_source_rejects_feature_keys(self):
        target = self.manifest.legacy_targets[0]
        source = replace(target.sources[0], coverage="complete")
        changed = replace(
            self.manifest,
            legacy_targets=(replace(target, sources=(source,)),),
        )
        self.assertIn("complete_source_with_features", validate_manifest(changed))

    def test_target_requires_features(self):
        target = replace(self.manifest.legacy_targets[0], features=())
        changed = replace(self.manifest, legacy_targets=(target,))
        self.assertIn("target_without_features", validate_manifest(changed))

    def test_unmapped_target_requires_not_converted_features(self):
        target = replace(
            self.manifest.legacy_targets[0], current_plugins=()
        )
        changed = replace(self.manifest, legacy_targets=(target,))
        self.assertIn("unmapped_target_has_implementation", validate_manifest(changed))

    def test_blocker_requires_known_capability(self):
        target = self.manifest.legacy_targets[0]
        feature = replace(
            target.features[0], status="lera_blocker", capability=None
        )
        changed = replace(
            self.manifest,
            legacy_targets=(replace(target, features=(feature,)),),
        )
        self.assertIn("blocker_without_capability", validate_manifest(changed))

    def test_waiver_requires_approval_metadata(self):
        target = self.manifest.legacy_targets[0]
        feature = replace(target.features[0], status="waived")
        changed = replace(
            self.manifest,
            legacy_targets=(replace(target, features=(feature,)),),
        )
        self.assertIn("waiver_without_approval", validate_manifest(changed))

    def test_parity_requires_passing_evidence(self):
        target = self.manifest.legacy_targets[0]
        evidence = replace(target.features[0].evidence, outcome="fail")
        feature = replace(target.features[0], evidence=evidence)
        changed = replace(
            self.manifest,
            legacy_targets=(replace(target, features=(feature,)),),
        )
        self.assertIn(
            "parity_without_passing_evidence", validate_manifest(changed)
        )


if __name__ == "__main__":
    unittest.main()
