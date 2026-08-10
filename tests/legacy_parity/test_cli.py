import subprocess
import unittest
from pathlib import Path

from tools.legacy_parity.cli import main


class CliSmokeTests(unittest.TestCase):
    def test_no_command_is_usage_error(self):
        self.assertEqual(main([]), 2)

    def test_wrapper_prints_help(self):
        repo = Path(__file__).resolve().parents[2]
        result = subprocess.run(
            [str(repo / "tools" / "legacy-parity"), "--help"],
            cwd=repo,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("legacy parity", result.stdout.lower())


