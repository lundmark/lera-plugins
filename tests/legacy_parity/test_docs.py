import re
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]


class DocumentationTests(unittest.TestCase):
    def setUp(self):
        self.readme = (REPO / "README.md").read_text(encoding="utf-8")
        self.validation = (
            REPO / "validation" / "README.md"
        ).read_text(encoding="utf-8")
        self.workflow = (
            REPO / ".github" / "workflows" / "legacy-parity.yml"
        ).read_text(encoding="utf-8")

    def test_documents_repeatable_levels_safety_and_exit_codes(self):
        self.assertIn("validation/README.md", self.readme)
        required = (
            "validate --level public",
            "validate --level full-private",
            "--legacy-root",
            "--lera-root",
            "--lera-bin",
            "--require-parity",
            "--refresh-legacy",
            "${XDG_STATE_HOME:-~/.local/state}/lera-plugins/legacy-parity",
            "public scope digest",
            "private binding digest",
            "discover",
            "live MUD",
            "lundmark/lera",
            "plan 2",
        )
        for value in required:
            with self.subTest(value=value):
                self.assertIn(value, self.validation)
        for code in ("| 0 |", "| 1 |", "| 2 |", "| 3 |"):
            self.assertIn(code, self.validation)
        self.assertIn(
            "only command that prints candidate identifiers",
            self.validation,
        )
        self.assertIn(
            "does not re-authenticate private approval",
            self.validation,
        )

    def test_public_ci_has_no_private_capability_or_secret_route(self):
        required = (
            "actions/checkout",
            "actions/setup-python",
            "python-version: \"3.12\"",
            "compileall",
            "unittest discover",
            "validate --level public",
            "validation/legacy-parity.toml",
        )
        for value in required:
            self.assertIn(value, self.workflow)
        forbidden = (
            "full-private",
            "sync-issues",
            "approval.json",
            "github.token",
            "secrets.",
            "legacy-root",
            "lera-bin",
        )
        lowered = self.workflow.lower()
        for value in forbidden:
            with self.subTest(value=value):
                self.assertNotIn(value, lowered)

    def test_docs_do_not_publish_private_catalogues_or_provenance(self):
        public_text = self.readme + self.validation + self.workflow
        self.assertNotIn("omitted candidates:", public_text.lower())
        self.assertNotIn("omission reason", public_text.lower())
        self.assertIsNone(
            re.search(
                r"(?<![0-9a-f])[0-9a-f]{40}(?:[0-9a-f]{24})?",
                public_text,
            )
        )
        self.assertNotIn("<muclient", public_text.lower())


if __name__ == "__main__":
    unittest.main()
