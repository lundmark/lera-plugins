import os
import tempfile
import unittest
from pathlib import Path

from tools.legacy_parity.publish import (
    PUBLIC_PATHS,
    PublicationCandidate,
    publish_transaction,
)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.repo = root / "repo"
        self.private = root / "private"
        self.repo.mkdir()
        self.bundle = object()
        self.candidate = PublicationCandidate(
            repo_root=self.repo,
            private_root=self.private,
            manifest_bytes=b"new manifest\n",
            report_bytes=b"new report\n",
            not_converted_bytes=b"new inventory\n",
        )

    def tearDown(self):
        self.temp.cleanup()

    def public_bytes(self):
        return {
            key: (self.repo / relative).read_bytes()
            for key, relative in PUBLIC_PATHS.items()
            if (self.repo / relative).exists()
        }

    def test_success_writes_exact_candidate_set_after_gate(self):
        calls = []

        def gate(candidate, bundle):
            calls.append((candidate, bundle))

        publish_transaction(self.candidate, self.bundle, gate)
        self.assertEqual(calls, [(self.candidate, self.bundle)])
        self.assertEqual(
            self.public_bytes(),
            {
                "manifest": b"new manifest\n",
                "not_converted": b"new inventory\n",
                "parity_report": b"new report\n",
            },
        )
        self.assertEqual(
            set(self.candidate.digests),
            {"manifest", "not_converted", "parity_report"},
        )
        self.assertFalse(any(self.private.glob("publication-*")))

    def test_each_gate_failure_leaves_first_publication_empty(self):
        failures = (
            "missing_private_approval",
            "incomplete_coverage",
            "unresolved_blocker",
            "invalid_evidence",
            "runtime_failure",
            "privacy_violation",
            "staged_scope_mismatch",
        )
        readme = self.repo / "validation" / "README.md"
        readme.parent.mkdir()
        readme.write_text("Unrelated documentation.\n", encoding="utf-8")
        for code in failures:
            with self.subTest(code=code):
                with self.assertRaisesRegex(ValueError, code):
                    publish_transaction(
                        self.candidate,
                        self.bundle,
                        lambda candidate, bundle, value=code: (
                            _raise(value)
                        ),
                    )
                self.assertEqual(self.public_bytes(), {})
                self.assertEqual(
                    readme.read_text(encoding="utf-8"),
                    "Unrelated documentation.\n",
                )
                self.assertFalse(any(self.private.glob("publication-*")))

    def test_failure_after_each_replace_restores_all_existing_bytes(self):
        validation = self.repo / "validation"
        validation.mkdir()
        originals = {
            "manifest": b"old manifest\n",
            "not_converted": b"old inventory\n",
            "parity_report": b"old report\n",
        }
        for key, relative in PUBLIC_PATHS.items():
            (self.repo / relative).write_bytes(originals[key])

        for fail_after in (1, 2, 3):
            with self.subTest(fail_after=fail_after):
                count = 0

                def failing_replace(source, destination):
                    nonlocal count
                    os.replace(source, destination)
                    count += 1
                    if count == fail_after:
                        raise OSError("injected publication failure")

                with self.assertRaises(OSError):
                    publish_transaction(
                        self.candidate,
                        self.bundle,
                        lambda candidate, bundle: None,
                        replace_public=failing_replace,
                    )
                self.assertEqual(self.public_bytes(), originals)
                self.assertFalse(any(self.private.glob("publication-*")))

    def test_gate_receives_exact_bytes_before_any_public_write(self):
        observed = []

        def gate(candidate, bundle):
            observed.append(
                (
                    candidate.artifacts,
                    candidate.digests,
                    bundle,
                    self.public_bytes(),
                )
            )

        publish_transaction(self.candidate, self.bundle, gate)
        artifacts, digests, bundle, before = observed[0]
        self.assertEqual(artifacts["manifest"], b"new manifest\n")
        self.assertEqual(bundle, self.bundle)
        self.assertEqual(before, {})
        self.assertEqual(
            digests["manifest"],
            self.candidate.digests["manifest"],
        )

    def test_candidate_mutation_after_gate_is_rejected_without_public_write(self):
        def mutating_gate(candidate, bundle):
            object.__setattr__(candidate, "report_bytes", b"changed\n")

        with self.assertRaisesRegex(ValueError, "candidate_bytes_changed"):
            publish_transaction(
                self.candidate,
                self.bundle,
                mutating_gate,
            )
        self.assertEqual(self.public_bytes(), {})


def _raise(code):
    raise ValueError(code)


if __name__ == "__main__":
    unittest.main()
