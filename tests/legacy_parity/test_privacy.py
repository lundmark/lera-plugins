import unittest
from pathlib import Path

from tools.legacy_parity.legacy import SelectionState
from tools.legacy_parity.privacy import (
    assert_public_bytes,
    build_private_deny_tokens,
    sanitize_diagnostic,
    scan_public_bytes,
)
from tools.legacy_parity.state import ProvenanceState


class PrivacyTests(unittest.TestCase):
    def setUp(self):
        self.omitted = "plugins/private_omission.xml"
        self.commit = "a" * 40
        self.source_hash = "b" * 64
        self.root = Path("/home/example/private-legacy")
        self.selection = SelectionState(
            version=1,
            included_targets=(),
            omitted_candidates=(self.omitted,),
        )
        self.provenance = ProvenanceState(
            version=1,
            scope_revision=1,
            public_digest="0" * 64,
            binding_digest="1" * 64,
            legacy_commit=self.commit,
            source_digests=(("plugins/approved.xml", self.source_hash),),
            evidence=(),
            refreshed_at="2026-08-10T12:00:00+00:00",
        )

    def test_private_deny_tokens_cover_omissions_roots_and_provenance(self):
        tokens = build_private_deny_tokens(
            self.selection,
            self.provenance,
            private_roots=(self.root,),
            private_text=(
                "secret trigger pattern",
                "decision reason",
                "<muclient private='body'>",
            ),
        )
        for secret in (
            self.omitted,
            "private_omission",
            str(self.root),
            self.commit,
            self.source_hash,
            "secret trigger pattern",
            "decision reason",
            "<muclient private='body'>",
        ):
            self.assertIn(secret, tokens)

    def test_scanner_reports_only_sanitized_artifact_codes(self):
        tokens = build_private_deny_tokens(
            self.selection,
            self.provenance,
            private_roots=(self.root,),
        )
        findings = scan_public_bytes(
            {
                "manifest": (
                    b"safe prefix "
                    + self.omitted.encode("utf-8")
                    + b" token=credential-value"
                )
            },
            deny_tokens=tokens,
            allowed_hashes={"0" * 64},
        )
        self.assertTrue(findings)
        rendered = repr(findings)
        self.assertNotIn("private_omission", rendered)
        self.assertNotIn("credential-value", rendered)
        self.assertTrue(
            all(item.artifact == "manifest" for item in findings)
        )
        with self.assertRaisesRegex(ValueError, "^privacy_violation$"):
            assert_public_bytes(
                {"manifest": self.omitted.encode("utf-8")},
                deny_tokens=tokens,
            )

    def test_public_structural_scan_rejects_paths_bodies_hashes_and_tokens(self):
        unsafe = {
            "path": b"/home/example/private/file",
            "xml": b"<muclient><triggers>",
            "lua": b"trigger.add('private pattern')",
            "commit": self.commit.encode("ascii"),
            "hash": self.source_hash.encode("ascii"),
            "credential": b"websocket_token = 'fixture-secret'",
        }
        for key, content in unsafe.items():
            with self.subTest(key=key):
                self.assertTrue(scan_public_bytes({key: content}))
        self.assertEqual(
            scan_public_bytes(
                {"manifest": ("0" * 64).encode("ascii")},
                allowed_hashes={"0" * 64},
            ),
            (),
        )

    def test_opaque_evidence_keys_are_allowed_and_diagnostics_are_generic(self):
        self.assertEqual(
            scan_public_bytes({"manifest": b'local_key = "evidence-123"'}),
            (),
        )
        self.assertEqual(
            sanitize_diagnostic(ValueError("staged_scope_mismatch")),
            "staged_scope_mismatch",
        )
        self.assertEqual(
            sanitize_diagnostic(
                ValueError("/home/example/private secret trigger")
            ),
            "validation_failed",
        )


if __name__ == "__main__":
    unittest.main()
