import json
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

from tools.legacy_parity.issues import (
    CommandResult,
    REPOSITORY,
    marker_for,
    sync_capability_issue,
)
from tools.legacy_parity.model import Evidence, Feature
from tools.legacy_parity.staged import (
    BlockerAudit,
    StagedAuditBundle,
    TargetAudit,
    load_staged_bundle,
    provenance_digest,
)
from tools.legacy_parity.state import LocalEvidence, ProvenanceState


def blocked_feature(key, capability, evidence_key):
    return Feature(
        key=key,
        category="public_api",
        status="lera_blocker",
        summary="Approved behavior requires a Lera capability.",
        current_refs=(),
        evidence=Evidence(
            type="manual_private_review",
            review_date="2026-08-10",
            reviewed_scope="Approved behavior.",
            result="Capability is unavailable.",
            outcome="fail",
            local_key=evidence_key,
        ),
        capability=capability,
    )


class FakeRunner:
    def __init__(
        self,
        *,
        open_matches=(),
        closed_matches=(),
        post_open=None,
        post_open_after=1,
        repository_private=True,
        extra_marker=None,
    ):
        self.open_matches = tuple(open_matches)
        self.closed_matches = tuple(closed_matches)
        self.post_open = (
            tuple(post_open) if post_open is not None else self.open_matches
        )
        self.post_open_after = post_open_after
        self.repository_private = repository_private
        self.commands = []
        self.created_bodies = []
        self.open_searches = 0
        self.extra_marker = extra_marker

    def issue(self, url, state):
        body = marker_for("shared_api")
        if self.extra_marker is not None:
            body += "\n" + marker_for(self.extra_marker)
        return {
            "html_url": url,
            "state": state,
            "title": "Legacy parity capability: shared_api",
            "body": body,
        }

    def __call__(self, arguments):
        args = tuple(str(value) for value in arguments)
        self.commands.append(args)
        if args[:3] == ("gh", "repo", "view"):
            return CommandResult(
                0,
                json.dumps(
                    {
                        "nameWithOwner": REPOSITORY,
                        "visibility": (
                            "PRIVATE" if self.repository_private else "PUBLIC"
                        ),
                    }
                ),
                "",
            )
        if args[:3] == ("gh", "api", "search/issues"):
            query = args[args.index("-f") + 1]
            if "is:open" in query:
                self.open_searches += 1
                matches = (
                    self.open_matches
                    if self.open_searches <= self.post_open_after
                    else self.post_open
                )
                state = "open"
            else:
                matches = self.closed_matches
                state = "closed"
            return CommandResult(
                0,
                json.dumps(
                    {
                        "total_count": len(matches),
                        "incomplete_results": False,
                        "items": [
                            self.issue(url, state) for url in matches
                        ],
                        "search_type": "lexical",
                    }
                ),
                "",
            )
        if args[:3] == ("gh", "issue", "create"):
            if "--body-file" in args:
                return CommandResult(1, "", "body file inaccessible")
            self.created_bodies.append(args[args.index("--body") + 1])
            return CommandResult(
                0,
                "https://github.com/lundmark/lera/issues/123\n",
                "",
            )
        return CommandResult(1, "", "unexpected")


class IssueSynchronizationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.state_root = root / "private"
        self.public_repo = root / "public"
        self.public_repo.mkdir()
        evidence = (
            LocalEvidence(
                "evidence_one",
                "target_one",
                "feature_one",
                "manual_private_review",
                "2026-08-10",
                ("xml:one:1",),
                "fail",
                "Capability is unavailable.",
            ),
            LocalEvidence(
                "evidence_two",
                "target_one",
                "feature_two",
                "manual_private_review",
                "2026-08-10",
                ("xml:one:2",),
                "fail",
                "Capability is unavailable.",
            ),
            LocalEvidence(
                "evidence_three",
                "target_two",
                "feature_three",
                "manual_private_review",
                "2026-08-10",
                ("xml:two:1",),
                "fail",
                "Capability is unavailable.",
            ),
        )
        provenance = ProvenanceState(
            1,
            1,
            "0" * 64,
            "1" * 64,
            "a" * 40,
            (),
            evidence,
            "2026-08-10T12:00:00+00:00",
        )
        self.bundle = StagedAuditBundle(
            version=1,
            scope_revision=1,
            public_scope="{}",
            public_digest="0" * 64,
            targets=(
                TargetAudit(
                    key="target_one",
                    current_plugins=("current_one",),
                    source_paths=(),
                    dependency_closure=(),
                    construct_inventory=(),
                    assignments=(),
                    current_only_rationales=(),
                    features=(
                        blocked_feature(
                            "feature_one", "shared_api", "evidence_one"
                        ),
                        blocked_feature(
                            "feature_two", "distinct_api", "evidence_two"
                        ),
                    ),
                ),
                TargetAudit(
                    key="target_two",
                    current_plugins=("current_two",),
                    source_paths=(),
                    dependency_closure=(),
                    construct_inventory=(),
                    assignments=(),
                    current_only_rationales=(),
                    features=(
                        blocked_feature(
                            "feature_three",
                            "shared_api",
                            "evidence_three",
                        ),
                    ),
                ),
            ),
            evidence=evidence,
            blockers=(
                BlockerAudit(
                    "distinct_api",
                    "Distinct approved capability.",
                    ("evidence_two",),
                    None,
                    ("target_one.feature_two",),
                    ("current_one",),
                ),
                BlockerAudit(
                    "shared_api",
                    "Shared approved capability.",
                    ("evidence_one", "evidence_three"),
                    None,
                    (
                        "target_one.feature_one",
                        "target_two.feature_three",
                    ),
                    ("current_one", "current_two"),
                ),
            ),
            provenance=provenance,
            provenance_digest=provenance_digest(provenance),
            runtime_scenarios=(),
            runtime_results=(),
            artifact_hashes=(),
        )
        self.validated = []

    def tearDown(self):
        self.temp.cleanup()

    def validate(self, bundle):
        self.validated.append(bundle)
        if bundle.version != 1:
            raise ValueError("invalid_staged_version")

    def sync(self, runner, *, dry_run=False, bundle=None, key="shared_api"):
        return sync_capability_issue(
            bundle or self.bundle,
            key,
            runner,
            state_root=self.state_root,
            public_repo=self.public_repo,
            validate_bundle=self.validate,
            dry_run=dry_run,
        )

    def test_hard_codes_and_verifies_exact_private_repository(self):
        runner = FakeRunner(
            open_matches=("https://github.com/lundmark/lera/issues/22",)
        )
        result = self.sync(runner)
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(self.validated, [self.bundle])
        self.assertEqual(
            runner.commands[0],
            (
                "gh",
                "repo",
                "view",
                "lundmark/lera",
                "--json",
                "nameWithOwner,visibility",
            ),
        )
        public = FakeRunner(repository_private=False)
        self.assertEqual(self.sync(public).exit_code, 3)
        self.assertFalse(
            any(command[:3] == ("gh", "issue", "create") for command in public.commands)
        )

    def test_searches_open_and_closed_by_exact_marker_and_reuses_one_open(self):
        url = "https://github.com/lundmark/lera/issues/22"
        runner = FakeRunner(open_matches=(url,))
        result = self.sync(runner)
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.issue_url, url)
        queries = [
            command[command.index("-f") + 1]
            for command in runner.commands
            if command[:3] == ("gh", "api", "search/issues")
        ]
        self.assertEqual(len(queries), 2)
        self.assertTrue(any("is:open" in query for query in queries))
        self.assertTrue(any("is:closed" in query for query in queries))
        self.assertTrue(all(marker_for("shared_api") in query for query in queries))
        searches = [
            command
            for command in runner.commands
            if command[:3] == ("gh", "api", "search/issues")
        ]
        self.assertTrue(
            all(
                "--method" in command
                and command[command.index("--method") + 1] == "GET"
                for command in searches
            )
        )
        self.assertEqual(
            load_staged_bundle(self.state_root).blockers[1].issue_url,
            url,
        )

    def test_closed_or_ambiguous_matches_stop_without_mutation(self):
        url = "https://github.com/lundmark/lera/issues/22"
        cases = (
            FakeRunner(closed_matches=(url,)),
            FakeRunner(open_matches=(url, url)),
            FakeRunner(open_matches=(url,), closed_matches=(url,)),
        )
        for runner in cases:
            with self.subTest(commands=len(runner.commands)):
                result = self.sync(runner)
                self.assertEqual(result.exit_code, 3)
                self.assertFalse(
                    any(
                        command[:3] == ("gh", "issue", "create")
                        for command in runner.commands
                    )
                )
                self.assertFalse(
                    (self.state_root / "staged" / "audit-bundle.json").exists()
                )

    def test_creates_once_rechecks_and_detects_post_create_duplicates(self):
        created = "https://github.com/lundmark/lera/issues/123"
        runner = FakeRunner(open_matches=(), post_open=(created,))
        result = self.sync(runner)
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.issue_url, created)
        creates = [
            command
            for command in runner.commands
            if command[:3] == ("gh", "issue", "create")
        ]
        self.assertEqual(len(creates), 1)
        self.assertEqual(runner.open_searches, 2)

        staged_path = (
            self.state_root / "staged" / "audit-bundle.json"
        )
        before = staged_path.read_bytes()
        duplicate = FakeRunner(
            open_matches=(),
            post_open=(
                created,
                "https://github.com/lundmark/lera/issues/124",
            ),
        )
        self.assertEqual(self.sync(duplicate).exit_code, 3)
        self.assertEqual(staged_path.read_bytes(), before)

    def test_post_create_recheck_tolerates_search_index_delay(self):
        created = "https://github.com/lundmark/lera/issues/123"
        runner = FakeRunner(
            open_matches=(),
            post_open=(created,),
            post_open_after=3,
        )
        result = self.sync(runner)
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.issue_url, created)
        self.assertEqual(runner.open_searches, 4)


    def test_dry_run_never_creates_or_writes(self):
        runner = FakeRunner()
        result = self.sync(runner, dry_run=True)
        self.assertEqual(result.exit_code, 0)
        self.assertIsNone(result.issue_url)
        self.assertFalse(
            any(
                command[:3] == ("gh", "issue", "create")
                for command in runner.commands
            )
        )
        self.assertFalse(
            (self.state_root / "staged" / "audit-bundle.json").exists()
        )

    def test_title_body_are_derived_safe_and_commands_are_nondestructive(self):
        runner = FakeRunner(
            open_matches=(),
            post_open=("https://github.com/lundmark/lera/issues/123",),
        )
        self.assertEqual(self.sync(runner).exit_code, 0)
        body = runner.created_bodies[0]
        self.assertIn("shared_api", body)
        self.assertIn("current_one", body)
        self.assertIn("current_two", body)
        self.assertIn(marker_for("shared_api"), body)
        self.assertNotIn("target_one", body)
        self.assertNotIn("xml:", body)
        destructive = {
            command[:3]
            for command in runner.commands
            if len(command) >= 3
        }
        for forbidden in ("reopen", "close", "delete", "edit"):
            self.assertNotIn(("gh", "issue", forbidden), destructive)

    def test_rejects_issue_owned_by_multiple_capability_markers(self):
        runner = FakeRunner(
            open_matches=("https://github.com/lundmark/lera/issues/22",),
            extra_marker="distinct_api",
        )
        result = self.sync(runner, dry_run=True)
        self.assertEqual(result.exit_code, 3)
        self.assertFalse(
            any(
                command[:3] == ("gh", "issue", "create")
                for command in runner.commands
            )
        )

    def test_rejects_reusing_one_issue_url_for_distinct_capabilities(self):
        shared = "https://github.com/lundmark/lera/issues/22"
        linked = replace(
            self.bundle,
            blockers=(
                replace(self.bundle.blockers[0], issue_url=shared),
                self.bundle.blockers[1],
            ),
        )
        runner = FakeRunner(open_matches=(shared,))
        result = self.sync(
            runner,
            dry_run=True,
            bundle=linked,
            key="shared_api",
        )
        self.assertEqual(result.exit_code, 3)

    def test_rejects_authored_derivation_or_private_text_before_gh(self):
        blocker = replace(
            self.bundle.blockers[1], affected_plugins=("unapproved",)
        )
        changed = replace(
            self.bundle,
            blockers=(self.bundle.blockers[0], blocker),
        )
        runner = FakeRunner()
        self.assertEqual(self.sync(runner, bundle=changed).exit_code, 3)
        self.assertEqual(runner.commands, [])

        unsafe = replace(
            self.bundle.blockers[1],
            description="/home/example/private plugins/private.xml",
        )
        changed = replace(
            self.bundle,
            blockers=(self.bundle.blockers[0], unsafe),
        )
        runner = FakeRunner()
        self.assertEqual(self.sync(runner, bundle=changed).exit_code, 3)
        self.assertEqual(runner.commands, [])


if __name__ == "__main__":
    unittest.main()
