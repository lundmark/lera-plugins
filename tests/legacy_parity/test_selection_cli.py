import contextlib
import io
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from tools.legacy_parity.cli import main
from tools.legacy_parity.legacy import load_selection


FIXTURE = Path(__file__).resolve().parent / "fixtures" / "private-tree"


class SelectionCliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.legacy_root = Path(self.temp.name) / "legacy"
        self.state_root = Path(self.temp.name) / "state"
        shutil.copytree(FIXTURE, self.legacy_root)

    def tearDown(self):
        self.temp.cleanup()

    def run_cli(self, args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = main(args)
        return code, output.getvalue()

    def test_discover_is_the_only_command_that_prints_candidate_names(self):
        code, output = self.run_cli(
            [
                "discover",
                "--legacy-root",
                str(self.legacy_root),
                "--state-root",
                str(self.state_root),
            ]
        )
        self.assertEqual(code, 0)
        self.assertIn("plugins/alpha.xml", output)

        code, output = self.run_cli(
            [
                "select",
                "--legacy-root",
                str(self.legacy_root),
                "--state-root",
                str(self.state_root),
                "--public-repo",
                str(Path(__file__).resolve().parents[2]),
                "--omit",
                "plugins/alpha.xml",
            ]
        )
        self.assertEqual(code, 0)
        self.assertNotIn("alpha", output.lower())

        _, output = self.run_cli(
            [
                "discover",
                "--legacy-root",
                str(self.legacy_root),
                "--state-root",
                str(self.state_root),
            ]
        )
        self.assertNotIn("plugins/alpha.xml", output)

    def test_include_target_record_stays_private_and_is_persisted(self):
        record = Path(self.temp.name) / "target.json"
        record.write_text(
            json.dumps(
                {
                    "key": "sample_target",
                    "sources": [
                        {
                            "kind": "xml",
                            "path": "plugins/alpha.xml",
                            "coverage": "selected",
                            "feature_keys": ["sample_command"],
                            "bindings": [
                                {
                                    "feature_key": "sample_command",
                                    "construct_ids": [
                                        "xml:plugins/alpha.xml:1"
                                    ],
                                }
                            ],
                        }
                    ],
                    "current_plugins": [],
                }
            ),
            encoding="utf-8",
        )
        code, output = self.run_cli(
            [
                "select",
                "--legacy-root",
                str(self.legacy_root),
                "--state-root",
                str(self.state_root),
                "--public-repo",
                str(Path(__file__).resolve().parents[2]),
                "--include-target-record",
                str(record),
            ]
        )
        self.assertEqual(code, 0)
        self.assertNotIn("sample_target", output)

if __name__ == "__main__":
    unittest.main()
