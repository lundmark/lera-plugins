import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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

    def test_rejects_symlinked_validation_directory_without_redirect(self):
        external = Path(self.temp.name) / "external"
        external.mkdir()
        (self.repo / "validation").symlink_to(external, target_is_directory=True)

        with self.assertRaisesRegex(ValueError, "unsafe_publication_path"):
            publish_transaction(
                self.candidate, self.bundle, lambda candidate, bundle: None
            )

        self.assertEqual(tuple(external.iterdir()), ())

    def test_preserves_concurrent_destination_substitution(self):
        validation = self.repo / "validation"
        validation.mkdir()
        originals = {
            "manifest": b"old manifest\n",
            "not_converted": b"old inventory\n",
            "parity_report": b"old report\n",
        }
        for key, relative in PUBLIC_PATHS.items():
            (self.repo / relative).write_bytes(originals[key])

        for target_key in PUBLIC_PATHS:
            with self.subTest(target_key=target_key):
                concurrent = f"concurrent-{target_key}\n".encode()
                displaced = validation / f"displaced-{target_key}"
                injected = False

                def substituting_publish(event, key, source, destination):
                    nonlocal injected
                    destination = Path(destination)
                    if (
                        event == "before"
                        and key == target_key
                        and not injected
                    ):
                        destination.replace(displaced)
                        destination.write_bytes(concurrent)
                        injected = True

                with self.assertRaises((OSError, ValueError)):
                    publish_transaction(
                        self.candidate,
                        self.bundle,
                        lambda candidate, bundle: None,
                        publication_hook=substituting_publish,
                    )
                self.assertTrue(injected)
                self.assertEqual(
                    (self.repo / PUBLIC_PATHS[target_key]).read_bytes(),
                    concurrent,
                )
                self.assertFalse(displaced.exists())
                recovered = tuple((self.private / "recoveries").iterdir())
                self.assertTrue(
                    any(path.read_bytes() == originals[target_key] for path in recovered)
                )
                for key, relative in PUBLIC_PATHS.items():
                    path = self.repo / relative
                    if key != target_key:
                        self.assertEqual(path.read_bytes(), originals[key])

                (self.repo / PUBLIC_PATHS[target_key]).unlink()
                (self.repo / PUBLIC_PATHS[target_key]).write_bytes(
                    originals[target_key]
                )

    def test_preserves_post_publish_destination_substitution(self):
        validation = self.repo / "validation"
        validation.mkdir()
        originals = {
            "manifest": b"old manifest\n",
            "not_converted": b"old inventory\n",
            "parity_report": b"old report\n",
        }
        for key, relative in PUBLIC_PATHS.items():
            (self.repo / relative).write_bytes(originals[key])

        for target_key in PUBLIC_PATHS:
            with self.subTest(target_key=target_key):
                concurrent = f"post-{target_key}\n".encode()
                escaped = validation / f"escaped-{target_key}"
                injected = False

                def substitute_after(event, key, source, destination):
                    nonlocal injected
                    destination = Path(destination)
                    if event == "after" and key == target_key and not injected:
                        destination.replace(escaped)
                        destination.write_bytes(concurrent)
                        injected = True

                with self.assertRaises((OSError, ValueError)):
                    publish_transaction(
                        self.candidate,
                        self.bundle,
                        lambda candidate, bundle: None,
                        publication_hook=substitute_after,
                    )
                self.assertTrue(injected)
                self.assertEqual(
                    (self.repo / PUBLIC_PATHS[target_key]).read_bytes(),
                    concurrent,
                )
                self.assertFalse(escaped.exists())
                for key, relative in PUBLIC_PATHS.items():
                    if key != target_key:
                        self.assertEqual(
                            (self.repo / relative).read_bytes(), originals[key]
                        )

                (self.repo / PUBLIC_PATHS[target_key]).unlink()
                (self.repo / PUBLIC_PATHS[target_key]).write_bytes(
                    originals[target_key]
                )

    def test_partial_temporary_write_leaves_no_public_residue(self):
        called = False

        def partial_write(descriptor, content):
            nonlocal called
            called = True
            os.write(descriptor, content[:1])
            raise OSError("injected short write")

        with mock.patch(
            "tools.legacy_parity.publish._write_all",
            side_effect=partial_write,
        ):
            with self.assertRaises(OSError):
                publish_transaction(
                    self.candidate,
                    self.bundle,
                    lambda candidate, bundle: None,
                )

        self.assertTrue(called)
        self.assertEqual(self.public_bytes(), {})
        validation = self.repo / "validation"
        self.assertEqual(tuple(validation.iterdir()), ())

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

                def failing_publish(event, key, source, destination):
                    nonlocal count
                    if event != "after":
                        return
                    count += 1
                    if count == fail_after:
                        raise OSError("injected publication failure")

                with self.assertRaises(OSError):
                    publish_transaction(
                        self.candidate,
                        self.bundle,
                        lambda candidate, bundle: None,
                        publication_hook=failing_publish,
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
