import hashlib
import json
import os
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

from tools.legacy_parity.manifest import load_manifest
from tools.legacy_parity.scope import (
    canonical_bindings,
    canonical_scope,
    scope_digest,
)
from tools.legacy_parity.state import (
    approval_matches,
    approve_scope,
    load_approval,
)


FIXTURE = (
    Path(__file__).resolve().parent
    / "fixtures"
    / "public"
    / "valid-manifest.toml"
)
BINDINGS = {
    "sample_legacy": {
        "plugins/sample.xml": {
            "sample_command": ["xml:plugins/sample.xml:4"]
        }
    }
}


class ScopeTests(unittest.TestCase):
    def setUp(self):
        self.manifest = load_manifest(FIXTURE)

    def test_canonical_scope_has_exact_stable_bytes(self):
        expected = (
            b'{"current_plugins":[{"key":"sample_current","path":"generic/sample.lua"}],'
            b'"legacy_targets":[{"current_plugins":["sample_current"],'
            b'"key":"sample_legacy","sources":[{"coverage":"selected",'
            b'"feature_keys":["sample_command"],"kind":"xml",'
            b'"path":"plugins/sample.xml"}]}],"version":1}'
        )
        self.assertEqual(canonical_scope(self.manifest), expected)
        self.assertEqual(
            scope_digest(self.manifest), hashlib.sha256(expected).hexdigest()
        )

    def test_canonicalization_sorts_all_scope_arrays(self):
        source = self.manifest.legacy_targets[0].sources[0]
        changed_source = replace(
            source, feature_keys=("z_feature", "sample_command")
        )
        target = replace(
            self.manifest.legacy_targets[0],
            sources=(changed_source,),
            current_plugins=("sample_current",),
        )
        changed = replace(self.manifest, legacy_targets=(target,))
        value = json.loads(canonical_scope(changed))
        self.assertEqual(
            value["legacy_targets"][0]["sources"][0]["feature_keys"],
            ["sample_command", "z_feature"],
        )

    def test_rejects_unsafe_scope_paths(self):
        current = replace(self.manifest.current_plugins[0], path="../secret.lua")
        changed = replace(self.manifest, current_plugins=(current,))
        with self.assertRaisesRegex(ValueError, "invalid_scope_path"):
            canonical_scope(changed)

    def test_private_bindings_are_deterministic(self):
        expected = (
            b'{"sample_legacy":{"plugins/sample.xml":'
            b'{"sample_command":["xml:plugins/sample.xml:4"]}}}'
        )
        self.assertEqual(canonical_bindings(BINDINGS), expected)


class ApprovalStateTests(unittest.TestCase):
    def setUp(self):
        self.manifest = load_manifest(FIXTURE)
        self.temp = tempfile.TemporaryDirectory()
        self.state_root = Path(self.temp.name) / "legacy-parity"

    def tearDown(self):
        self.temp.cleanup()

    def test_approval_records_both_exact_digests_and_safe_modes(self):
        approval = approve_scope(
            self.state_root,
            self.manifest,
            BINDINGS,
            revision=1,
            approved_on="2026-08-10",
        )
        loaded = load_approval(self.state_root)
        self.assertEqual(loaded, approval)
        self.assertTrue(
            approval_matches(self.state_root, self.manifest, BINDINGS)
        )
        if os.name == "posix":
            self.assertEqual(self.state_root.stat().st_mode & 0o777, 0o700)
            self.assertEqual(
                (self.state_root / "approval.json").stat().st_mode & 0o777,
                0o600,
            )

    def test_changed_binding_invalidates_approval(self):
        approve_scope(
            self.state_root,
            self.manifest,
            BINDINGS,
            revision=1,
            approved_on="2026-08-10",
        )
        changed = {
            "sample_legacy": {
                "plugins/sample.xml": {
                    "sample_command": ["xml:plugins/sample.xml:5"]
                }
            }
        }
        self.assertFalse(
            approval_matches(self.state_root, self.manifest, changed)
        )

    def test_status_change_does_not_change_public_scope(self):
        target = self.manifest.legacy_targets[0]
        feature = replace(target.features[0], status="plugin_gap")
        changed = replace(
            self.manifest,
            legacy_targets=(replace(target, features=(feature,)),),
        )
        self.assertEqual(
            canonical_scope(self.manifest), canonical_scope(changed)
        )


if __name__ == "__main__":
    unittest.main()
