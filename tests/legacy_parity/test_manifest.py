import builtins
import importlib
import types
import unittest
from dataclasses import replace
from pathlib import Path
from unittest import mock

try:
    import tomllib as stdlib_tomllib
except ModuleNotFoundError:
    stdlib_tomllib = None

import tools.legacy_parity.manifest as manifest_module
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


class ManifestImportCompatibilityTests(unittest.TestCase):
    def test_falls_back_to_tomli_when_tomllib_is_unavailable(self):
        real_import = builtins.__import__
        fallback = types.ModuleType("tomli")
        fallback.loads = lambda content: {"content": content}
        fallback.TOMLDecodeError = ValueError

        def import_without_tomllib(name, globals=None, locals=None,
                                   fromlist=(), level=0):
            if name == "tomllib":
                raise ModuleNotFoundError(
                    "No module named 'tomllib'", name="tomllib"
                )
            if name == "tomli":
                return fallback
            return real_import(name, globals, locals, fromlist, level)

        selected = None
        import_error = None
        try:
            with mock.patch.object(
                builtins, "__import__", side_effect=import_without_tomllib
            ):
                try:
                    selected = importlib.reload(manifest_module).tomllib
                except ModuleNotFoundError as error:
                    import_error = error
        finally:
            importlib.reload(manifest_module)

        self.assertIsNone(import_error)
        self.assertIs(selected, fallback)

    @unittest.skipIf(stdlib_tomllib is None, "stdlib tomllib requires Python 3.11+")
    def test_prefers_stdlib_tomllib_when_available(self):
        real_import = builtins.__import__
        tomli_requests = []

        def record_tomli_import(name, globals=None, locals=None,
                                fromlist=(), level=0):
            if name == "tomli":
                tomli_requests.append(name)
            return real_import(name, globals, locals, fromlist, level)

        try:
            with mock.patch.object(
                builtins, "__import__", side_effect=record_tomli_import
            ):
                selected = importlib.reload(manifest_module).tomllib
        finally:
            importlib.reload(manifest_module)

        self.assertIs(selected, stdlib_tomllib)
        self.assertEqual(tomli_requests, [])


if __name__ == "__main__":
    unittest.main()
