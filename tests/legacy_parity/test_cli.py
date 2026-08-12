import contextlib
import io
import subprocess
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest import mock

from tools.legacy_parity.cli import build_parser, entrypoint, main


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

    def test_parser_exposes_the_complete_approved_command_surface(self):
        commands = (
            ["discover", "--legacy-root", "/private"],
            ["select", "--legacy-root", "/private", "--omit", "plugins/a.xml"],
            ["stage-preliminary", "--plugin-root", "/plugins", "--record", "/private/a.json"],
            ["check-preliminary", "--plugin-root", "/plugins", "--legacy-root", "/private"],
            ["stage-audit", "--input", "/private/bundle.json"],
            ["propose-scope", "--legacy-root", "/private", "--plugin-root", "/plugins", "--output", "/private/proposal.json"],
            ["approve-scope", "--proposal", "/private/proposal.json", "--revision", "1", "--approved-on", "2026-08-10", "--confirmed-public-digest", "a" * 64, "--confirmed-binding-digest", "b" * 64],
            ["validate", "--level", "public"],
            ["validate", "--level", "full-private", "--legacy-root", "/private", "--lera-root", "/lera", "--lera-bin", "/lera/build/lera", "--require-parity", "--refresh-legacy"],
            ["sync-issues", "--staged", "/private/bundle.json", "--dry-run"],
            ["publish", "--staged", "/private/bundle.json", "--legacy-root", "/private", "--lera-root", "/lera", "--lera-bin", "/lera/build/lera"],
        )
        parser = build_parser()
        for argv in commands:
            with self.subTest(command=argv[0]):
                self.assertEqual(parser.parse_args(argv).command, argv[0])

    def test_entrypoint_returns_sanitized_exit_codes(self):
        private_value = "/private/never-print-this.xml"
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = entrypoint(
                ["validate", "--level", "public", "--plugin-root", private_value]
            )
        self.assertEqual(code, 2)
        self.assertNotIn(private_value, stderr.getvalue())

        with mock.patch(
            "tools.legacy_parity.cli._dispatch",
            side_effect=__import__(
                "tools.legacy_parity.validation", fromlist=["ValidationFailure"]
            ).ValidationFailure("public_artifact_mismatch"),
        ):
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(
                    entrypoint(["validate", "--level", "public"]), 1
                )

        with mock.patch(
            "tools.legacy_parity.cli._dispatch", return_value=3
        ):
            self.assertEqual(
                entrypoint(["sync-issues", "--staged", private_value]), 3
            )

    def test_scope_proposal_io_rejects_symlink_redirects(self):
        cli = __import__("tools.legacy_parity.cli", fromlist=["proposal"])
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            external = root / "external"
            external.mkdir(mode=0o700)
            state = root / "state"
            state.symlink_to(external, target_is_directory=True)
            proposal = state / "proposal.json"

            with self.assertRaisesRegex(ValueError, "unsafe_private_path"):
                cli._write_scope_proposal(
                    proposal, state, {"version": 1}
                )
            self.assertFalse((external / "proposal.json").exists())

            (external / "proposal.json").write_text(
                '{"version":1}\n', encoding="utf-8"
            )
            (external / "proposal.json").chmod(0o600)
            with self.assertRaisesRegex(ValueError, "unsafe_private_path"):
                cli._load_scope_proposal(proposal, state)

    def test_scope_proposal_loader_rejects_symlink_and_duplicate_keys(self):
        cli = __import__("tools.legacy_parity.cli", fromlist=["proposal"])
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            state = root / "state"
            state.mkdir(mode=0o700)
            external = root / "external.json"
            external.write_text('{"version":1}\n', encoding="utf-8")
            external.chmod(0o600)
            proposal = state / "proposal.json"
            proposal.symlink_to(external)
            with self.assertRaisesRegex(ValueError, "unsafe_private_path"):
                cli._load_scope_proposal(proposal, state)

            proposal.unlink()
            proposal.write_text(
                '{"version":1,"version":1}\n', encoding="utf-8"
            )
            proposal.chmod(0o600)
            with self.assertRaisesRegex(ValueError, "invalid_scope_proposal"):
                cli._load_scope_proposal(proposal, state)

    def test_issue_sync_rejects_noncanonical_staged_input_before_github(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            state = root / "state"
            supplied = root / "crafted.json"
            supplied.write_text("{}", encoding="utf-8")
            args = Namespace(
                staged=str(supplied),
                state_root=str(state),
                public_repo=str(root / "repo"),
                dry_run=False,
            )
            with mock.patch(
                "tools.legacy_parity.cli.sync_capability_issue"
            ) as synchronize:
                with self.assertRaisesRegex(
                    ValueError, "noncanonical_staged_input"
                ):
                    __import__(
                        "tools.legacy_parity.cli", fromlist=["_sync_issues"]
                    )._sync_issues(args)
            synchronize.assert_not_called()
