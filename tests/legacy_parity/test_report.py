import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

from tools.legacy_parity.manifest import load_manifest
from tools.legacy_parity.model import Capability
from tools.legacy_parity.report import (
    render_not_converted,
    render_parity_report,
    render_private_report,
    resolve_private_report_path,
)


FIXTURE = Path(__file__).resolve().parent / "fixtures" / "public"


class PublicReportTests(unittest.TestCase):
    def setUp(self):
        self.manifest = load_manifest(FIXTURE / "valid-manifest.toml")

    def test_parity_report_matches_exact_deterministic_golden(self):
        expected = (FIXTURE / "expected-parity-report.md").read_text(
            encoding="utf-8"
        )
        rendered = render_parity_report(self.manifest)
        self.assertEqual(rendered, expected)
        self.assertNotIn("Generated at", rendered)
        self.assertTrue(
            rendered.startswith(
                "PUBLIC BASELINE VERIFIED — PRIVATE APPROVAL AND "
                "LEGACY SOURCES NOT RECHECKED"
            )
        )

    def test_not_converted_report_is_allowlist_only_and_deterministic(self):
        public_target = self.manifest.legacy_targets[0]
        feature = replace(public_target.features[0], status="not_converted")
        manifest = replace(
            self.manifest,
            legacy_targets=(
                replace(
                    public_target,
                    current_plugins=(),
                    features=(feature,),
                ),
            ),
        )
        expected = (FIXTURE / "expected-not-converted.md").read_text(
            encoding="utf-8"
        )
        self.assertEqual(render_not_converted(manifest), expected)
        self.assertNotIn("omitted", render_not_converted(manifest).lower())
        self.assertEqual(
            render_not_converted(self.manifest),
            "# Approved targets not converted\n\n"
            "All approved targets have a current mapping.\n",
        )

    def test_report_links_only_capabilities_used_by_blocked_features(self):
        target = self.manifest.legacy_targets[0]
        blocked = replace(
            target.features[0],
            status="lera_blocker",
            capability="used_api",
        )
        manifest = replace(
            self.manifest,
            legacy_targets=(replace(target, features=(blocked,)),),
            capabilities=(
                Capability(
                    "unused_api",
                    "Unused capability.",
                    "https://github.com/lundmark/lera/issues/999",
                ),
                Capability(
                    "used_api",
                    "Used capability.",
                    "https://github.com/lundmark/lera/issues/123",
                ),
            ),
        )
        rendered = render_parity_report(manifest)
        self.assertIn(
            "[Lera issue #123](https://github.com/lundmark/lera/issues/123)",
            rendered,
        )
        self.assertNotIn("issues/999", rendered)


class PrivateReportTests(unittest.TestCase):
    def test_private_report_has_distinct_heading_and_timestamp(self):
        manifest = load_manifest(FIXTURE / "valid-manifest.toml")
        rendered = render_private_report(
            manifest, verified_at="2026-08-10T12:34:56+00:00"
        )
        self.assertTrue(rendered.startswith("FULL PRIVATE BASELINE VERIFIED\n"))
        self.assertIn("2026-08-10T12:34:56+00:00", rendered)
        self.assertNotEqual(rendered, render_parity_report(manifest))
        self.assertNotEqual(rendered, render_not_converted(manifest))

    def test_private_report_defaults_outside_repo_and_rejects_public_path(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            state = root / "state"
            repo = root / "repo"
            repo.mkdir()
            self.assertEqual(
                resolve_private_report_path(state, repo),
                state / "reports" / "full-private-report.md",
            )
            with self.assertRaisesRegex(ValueError, "public_private_report_path"):
                resolve_private_report_path(
                    state,
                    repo,
                    repo / "validation" / "private.md",
                )

            outside = root / "other-private" / "report.md"
            with self.assertRaisesRegex(ValueError, "unsafe_private_report_path"):
                resolve_private_report_path(state, repo, outside)


if __name__ == "__main__":
    unittest.main()
