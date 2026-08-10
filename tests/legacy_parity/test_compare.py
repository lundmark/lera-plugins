import unittest
from dataclasses import replace

from tools.legacy_parity.compare import (
    Finding,
    aggregate_target,
    strict_parity_findings,
    validate_evidence,
    validate_target,
)
from tools.legacy_parity.model import (
    Capability,
    Evidence,
    Feature,
    LegacyTarget,
)
from tools.legacy_parity.state import LocalEvidence


def evidence(
    *,
    kind="public_fixture",
    outcome="pass",
    reference="fixture-one",
    local_key=None,
    review_date="2026-08-10",
    reviewed_scope="Approved behavior.",
    result="Behavior matched.",
):
    return Evidence(
        type=kind,
        review_date=review_date,
        reviewed_scope=reviewed_scope,
        result=result,
        outcome=outcome,
        reference=reference if kind == "public_fixture" else None,
        local_key=local_key,
    )


def feature(
    key="alpha",
    *,
    status="parity",
    current_refs=("generic/sample.lua:3",),
    evidence_record=None,
    summary="Approved behavior is available.",
    capability=None,
    waiver_approved_on=None,
    waiver_rationale=None,
):
    return Feature(
        key=key,
        category="command",
        status=status,
        summary=summary,
        current_refs=current_refs,
        evidence=evidence_record or evidence(),
        capability=capability,
        waiver_approved_on=waiver_approved_on,
        waiver_rationale=waiver_rationale,
    )


def target(*features, mapped=True):
    return LegacyTarget(
        key="sample_target",
        sources=(),
        current_plugins=("sample",) if mapped else (),
        features=tuple(features),
    )


def codes(findings):
    return {item.code for item in findings}


class AggregateTests(unittest.TestCase):
    def test_uses_exact_precedence_and_preserves_all_feature_counts(self):
        summary = aggregate_target(
            target(
                feature("parity"),
                feature("gap", status="plugin_gap"),
                feature(
                    "blocker",
                    status="lera_blocker",
                    capability="missing_api",
                ),
            )
        )
        self.assertEqual(summary.status, "lera_blocker")
        self.assertEqual(
            summary.feature_status_counts,
            (("lera_blocker", 1), ("parity", 1), ("plugin_gap", 1)),
        )
        self.assertEqual(
            aggregate_target(
                target(feature(status="not_converted"))
            ).status,
            "plugin_gap",
        )
        self.assertEqual(
            aggregate_target(
                target(
                    feature("a"),
                    feature(
                        "b",
                        status="waived",
                        waiver_approved_on="2026-08-10",
                        waiver_rationale="Approved difference.",
                    ),
                )
            ).status,
            "parity",
        )
        self.assertEqual(
            aggregate_target(
                target(feature(status="not_converted"), mapped=False)
            ).status,
            "not_converted",
        )

    def test_strict_parity_accepts_only_parity_and_approved_waivers(self):
        accepted = target(
            feature("a"),
            feature(
                "b",
                status="waived",
                waiver_approved_on="2026-08-10",
                waiver_rationale="Approved difference.",
            ),
        )
        self.assertEqual(strict_parity_findings((accepted,)), ())
        rejected = target(
            feature("a", status="plugin_gap"),
            feature(
                "b",
                status="lera_blocker",
                capability="missing_api",
            ),
            feature("c", status="not_converted"),
        )
        findings = strict_parity_findings((rejected,))
        self.assertEqual(len(findings), 3)
        self.assertTrue(all(item.code == "strict_parity_status" for item in findings))
        self.assertTrue(all(isinstance(item, Finding) for item in findings))


class EvidenceTests(unittest.TestCase):
    def test_parity_requires_pass_and_current_ref_or_public_fixture(self):
        failed = feature(evidence_record=evidence(outcome="fail"))
        self.assertIn(
            "parity_evidence_failed",
            codes(validate_evidence(failed, target_key="sample_target")),
        )
        no_proof = feature(
            current_refs=(),
            evidence_record=evidence(
                kind="local_behavior",
                local_key="local-one",
            ),
        )
        self.assertIn(
            "parity_without_current_proof",
            codes(validate_evidence(no_proof, target_key="sample_target")),
        )
        fixture_only = feature(current_refs=())
        self.assertEqual(
            validate_evidence(
                fixture_only,
                target_key="sample_target",
                public_fixtures={"fixture-one"},
            ),
            (),
        )

    def test_every_evidence_record_requires_complete_review_metadata(self):
        cases = (
            (replace(evidence(), review_date="not-a-date"), "invalid_evidence_date"),
            (replace(evidence(), reviewed_scope=""), "missing_reviewed_scope"),
            (replace(evidence(), result=""), "missing_evidence_result"),
            (replace(evidence(), outcome="unknown"), "invalid_evidence_outcome"),
        )
        for record, expected in cases:
            with self.subTest(expected=expected):
                self.assertIn(
                    expected,
                    codes(
                        validate_evidence(
                            feature(evidence_record=record),
                            target_key="sample_target",
                            public_fixtures={"fixture-one"},
                        )
                    ),
                )

    def test_plugin_gap_requires_reviewed_evidence_and_safe_summary(self):
        gap = feature(
            status="plugin_gap",
            summary="/home/simon/private legacy detail",
        )
        self.assertIn(
            "unsafe_gap_summary",
            codes(
                validate_evidence(
                    gap,
                    target_key="sample_target",
                    public_fixtures={"fixture-one"},
                )
            ),
        )
        unreviewed = replace(
            gap,
            summary="Approved behavior is not implemented.",
            evidence=evidence(reviewed_scope=""),
        )
        self.assertIn(
            "missing_reviewed_scope",
            codes(validate_evidence(unreviewed, target_key="sample_target")),
        )

    def test_blocker_requires_known_capability_with_exact_lera_issue(self):
        blocker = feature(
            status="lera_blocker",
            capability="missing_api",
        )
        self.assertIn(
            "unknown_blocker_capability",
            codes(validate_evidence(blocker, target_key="sample_target")),
        )
        invalid = Capability(
            key="missing_api",
            description="Missing approved API.",
            issue_url="https://github.com/example/lera/issues/1",
        )
        self.assertIn(
            "invalid_capability_issue_url",
            codes(
                validate_evidence(
                    blocker,
                    target_key="sample_target",
                    capabilities=(invalid,),
                )
            ),
        )
        valid = replace(
            invalid,
            issue_url="https://github.com/lundmark/lera/issues/123",
        )
        self.assertNotIn(
            "unknown_blocker_capability",
            codes(
                validate_evidence(
                    blocker,
                    target_key="sample_target",
                    capabilities=(valid,),
                )
            ),
        )

    def test_waiver_requires_explicit_approval_and_safe_rationale(self):
        waived = feature(status="waived")
        self.assertIn(
            "waiver_without_approval",
            codes(validate_evidence(waived, target_key="sample_target")),
        )
        unsafe = replace(
            waived,
            waiver_approved_on="2026-08-10",
            waiver_rationale="/home/simon/private detail",
        )
        self.assertIn(
            "unsafe_waiver_rationale",
            codes(validate_evidence(unsafe, target_key="sample_target")),
        )

    def test_full_private_authenticates_complete_local_evidence_record(self):
        local = feature(
            current_refs=("generic/sample.lua:3",),
            evidence_record=evidence(
                kind="manual_private_review",
                local_key="review-one",
            ),
        )
        self.assertIn(
            "missing_private_evidence",
            codes(
                validate_evidence(
                    local,
                    target_key="sample_target",
                    full_private=True,
                    declared_construct_scope=("xml:approved:1",),
                )
            ),
        )
        private = LocalEvidence(
            key="review-one",
            target="sample_target",
            feature="alpha",
            evidence_type="manual_private_review",
            review_date="2026-08-10",
            construct_scope=("xml:approved:1",),
            outcome="pass",
            result="Behavior matched.",
        )
        self.assertEqual(
            validate_evidence(
                local,
                target_key="sample_target",
                private_evidence={"review-one": private},
                full_private=True,
                declared_construct_scope=("xml:approved:1",),
            ),
            (),
        )
        changed = replace(private, construct_scope=("xml:approved:2",))
        self.assertIn(
            "private_evidence_mismatch",
            codes(
                validate_evidence(
                    local,
                    target_key="sample_target",
                    private_evidence={"review-one": changed},
                    full_private=True,
                    declared_construct_scope=("xml:approved:1",),
                )
            ),
        )


class TargetValidationTests(unittest.TestCase):
    def test_mapped_and_unmapped_feature_status_rules(self):
        mapped = target(feature(status="not_converted"))
        self.assertNotIn(
            "mapped_not_converted_feature",
            codes(validate_target(mapped)),
        )
        self.assertEqual(aggregate_target(mapped).status, "plugin_gap")

        unmapped = target(feature(status="parity"), mapped=False)
        self.assertIn(
            "unmapped_target_has_implementation",
            codes(validate_target(unmapped)),
        )
        empty = target(mapped=True)
        self.assertIn("target_without_features", codes(validate_target(empty)))

    def test_requires_stable_unique_feature_order(self):
        unordered = target(feature("zeta"), feature("alpha"))
        self.assertIn(
            "unstable_feature_order", codes(validate_target(unordered))
        )
        duplicate = target(feature("alpha"), feature("alpha"))
        self.assertIn(
            "duplicate_feature_key", codes(validate_target(duplicate))
        )

    def test_reverse_coverage_and_evidence_scope_are_complete(self):
        item = target(feature())
        self.assertIn(
            "feature_without_approved_origin",
            codes(validate_target(item)),
        )
        assignments = {"alpha": ("xml:approved:1", "xml:approved:2")}
        self.assertIn(
            "evidence_scope_incomplete",
            codes(
                validate_target(
                    item,
                    construct_assignments=assignments,
                    evidence_scopes={"alpha": ("xml:approved:1",)},
                    public_fixtures={"fixture-one"},
                )
            ),
        )
        self.assertEqual(
            validate_target(
                item,
                construct_assignments=assignments,
                evidence_scopes={"alpha": assignments["alpha"]},
                public_fixtures={"fixture-one"},
            ),
            (),
        )

        current_only = target(feature("alpha"))
        self.assertNotIn(
            "feature_without_approved_origin",
            codes(
                validate_target(
                    current_only,
                    current_only_features={"alpha"},
                    public_fixtures={"fixture-one"},
                )
            ),
        )

    def test_findings_never_contain_private_detail(self):
        unsafe = target(
            feature(
                status="plugin_gap",
                summary="/home/simon/secret.xml pattern",
            )
        )
        findings = validate_target(unsafe)
        self.assertTrue(findings)
        for finding in findings:
            rendered = repr(finding)
            self.assertNotIn("/home/simon", rendered)
            self.assertNotIn("secret.xml", rendered)


if __name__ == "__main__":
    unittest.main()
