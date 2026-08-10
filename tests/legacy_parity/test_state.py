import os
import tempfile
import unittest
from pathlib import Path

from tools.legacy_parity.state import (
    LocalEvidence,
    ProvenanceState,
    load_provenance,
    write_provenance,
)


class ProvenanceStateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state_root = Path(self.temp.name) / "legacy-parity"
        self.evidence = LocalEvidence(
            key="evidence-1",
            target="sample_legacy",
            feature="sample_command",
            evidence_type="manual_private_review",
            review_date="2026-08-10",
            construct_scope=("xml:plugins/sample.xml:4",),
            outcome="pass",
            result="Approved behavior matched.",
        )
        self.provenance = ProvenanceState(
            version=1,
            scope_revision=1,
            public_digest="0" * 64,
            binding_digest="1" * 64,
            legacy_commit="a" * 40,
            source_digests=(("plugins/sample.xml", "2" * 64),),
            evidence=(self.evidence,),
            refreshed_at="2026-08-10T12:00:00+00:00",
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_round_trip_uses_safe_permissions(self):
        write_provenance(
            self.state_root,
            self.provenance,
            approved_paths={"plugins/sample.xml"},
        )
        self.assertEqual(load_provenance(self.state_root), self.provenance)
        if os.name == "posix":
            self.assertEqual(
                (self.state_root / "provenance.json").stat().st_mode & 0o777,
                0o600,
            )

    def test_rejects_missing_or_extra_approved_sources(self):
        with self.assertRaisesRegex(ValueError, "provenance_source_set"):
            write_provenance(
                self.state_root,
                self.provenance,
                approved_paths={
                    "plugins/sample.xml",
                    "lua/sample.lua",
                },
            )

    def test_rejects_duplicate_evidence_keys(self):
        changed = ProvenanceState(
            **{
                **self.provenance.__dict__,
                "evidence": (self.evidence, self.evidence),
            }
        )
        with self.assertRaisesRegex(ValueError, "duplicate_evidence_key"):
            write_provenance(
                self.state_root,
                changed,
                approved_paths={"plugins/sample.xml"},
            )


if __name__ == "__main__":
    unittest.main()
