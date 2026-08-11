import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.legacy_parity.coverage import verify_complete_coverage
from tools.legacy_parity.legacy import (
    XmlCompatibility,
    executable_lua_lines,
    extract_xml_constructs,
)
from tools.legacy_parity.validation import ValidationFailure


FIXTURE = Path(__file__).resolve().parent / "fixtures" / "private-tree"


class LegacyExtractionTests(unittest.TestCase):
    def malformed_xml(self):
        return (
            b'<muclient><plugin purpose="broken < value"/>'
            b'<script>value = 1\nreturn value\n</script></muclient>'
        )

    def compatibility(self, raw, relative, normalizer):
        return XmlCompatibility(
            expected_relative_path=relative,
            expected_sha256=hashlib.sha256(raw).hexdigest(),
            normalizer=normalizer,
        )

    def test_extracts_structural_xml_and_embedded_lua_constructs(self):
        path = FIXTURE / "plugins" / "coverage.xml"
        constructs = extract_xml_constructs(path, "plugins/coverage.xml")
        self.assertEqual(
            tuple(item.id for item in constructs),
            (
                "xml:plugins/coverage.xml:2",
                "xml:plugins/coverage.xml:4",
                "xml:plugins/coverage.xml:5",
                "xml-lua:plugins/coverage.xml:5:3",
                "xml-lua:plugins/coverage.xml:5:4",
                "xml-lua:plugins/coverage.xml:5:5",
            ),
        )

    def test_extracts_every_executable_helper_line(self):
        path = FIXTURE / "lua" / "coverage.lua"
        lines = executable_lua_lines(path.read_text(encoding="utf-8"))
        self.assertEqual(lines, (2, 6, 7, 8))

    def test_accepts_whitespace_before_xml_declaration(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "leading-whitespace.xml"
            path.write_bytes(
                b'\n\t<?xml version="1.0" encoding="iso-8859-1"?>\n'
                b'<muclient><plugin name="sample"/></muclient>\n'
            )
            constructs = extract_xml_constructs(
                path, "plugins/leading-whitespace.xml"
            )
        self.assertEqual(
            tuple(item.id for item in constructs),
            ("xml:plugins/leading-whitespace.xml:2",),
        )

    def test_missing_xml_path_fails_without_path_or_cause_leakage(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "private-source-name.xml"
            with self.assertRaises(ValidationFailure) as caught:
                extract_xml_constructs(path, "plugins/missing.xml")
        self.assertEqual(str(caught.exception), "legacy_xml_extraction_failed")
        self.assertIsNone(caught.exception.__cause__)
        self.assertNotIn(str(path), str(caught.exception))

    def test_unreadable_xml_fails_without_os_error_or_cause_leakage(self):
        private_detail = "private unreadable source detail"
        with mock.patch.object(
            Path, "read_bytes", side_effect=OSError(private_detail)
        ), self.assertRaises(ValidationFailure) as caught:
            extract_xml_constructs(
                Path("private-source-name.xml"),
                "plugins/unreadable.xml",
            )
        self.assertEqual(str(caught.exception), "legacy_xml_extraction_failed")
        self.assertIsNone(caught.exception.__cause__)
        self.assertNotIn(private_detail, str(caught.exception))

    def test_malformed_xml_without_compatibility_fails_sanitized(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "malformed.xml"
            path.write_bytes(self.malformed_xml())
            with self.assertRaisesRegex(
                ValidationFailure, "^legacy_xml_extraction_failed$"
            ) as caught:
                extract_xml_constructs(path, "plugins/malformed.xml")
        self.assertEqual(str(caught.exception), "legacy_xml_extraction_failed")

    def test_compatibility_requires_exact_path_and_original_digest_before_hook(self):
        raw = self.malformed_xml()
        relative = "plugins/synthetic-compatibility.xml"
        cases = (
            ("plugins/other.xml", hashlib.sha256(raw).hexdigest()),
            (relative, "0" * 64),
        )
        for expected_path, expected_digest in cases:
            with self.subTest(
                expected_path=expected_path,
                digest_matches=expected_digest != "0" * 64,
            ), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "malformed.xml"
                path.write_bytes(raw)
                normalizer = mock.Mock(return_value=b"<muclient/>")
                compatibility = XmlCompatibility(
                    expected_relative_path=expected_path,
                    expected_sha256=expected_digest,
                    normalizer=normalizer,
                )
                with self.assertRaisesRegex(
                    ValidationFailure, "^legacy_xml_extraction_failed$"
                ):
                    extract_xml_constructs(
                        path, relative, compatibility=compatibility
                    )
                normalizer.assert_not_called()

    def test_matching_compatibility_normalizes_and_preserves_ordered_ids(self):
        raw = self.malformed_xml()
        relative = "plugins/synthetic-compatibility.xml"

        def normalize(original):
            return original.replace(
                b"broken < value", b"broken &lt; value", 1
            )

        compatibility = self.compatibility(raw, relative, normalize)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "malformed.xml"
            path.write_bytes(raw)
            constructs = extract_xml_constructs(
                path, relative, compatibility=compatibility
            )
        self.assertEqual(
            tuple(item.id for item in constructs),
            (
                f"xml:{relative}:2",
                f"xml:{relative}:3",
                f"xml-lua:{relative}:3:1",
                f"xml-lua:{relative}:3:2",
            ),
        )

    def test_compatibility_hook_failures_are_sanitized(self):
        raw = self.malformed_xml()
        relative = "plugins/synthetic-compatibility.xml"

        def raises(_raw):
            raise RuntimeError("private hook detail")

        cases = (
            raises,
            lambda _raw: "not bytes",
            lambda original: original,
            lambda original: original + b" ",
        )
        for normalizer in cases:
            with self.subTest(
                normalizer=normalizer
            ), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "malformed.xml"
                path.write_bytes(raw)
                compatibility = self.compatibility(raw, relative, normalizer)
                with self.assertRaisesRegex(
                    ValidationFailure, "^legacy_xml_extraction_failed$"
                ) as caught:
                    extract_xml_constructs(
                        path, relative, compatibility=compatibility
                    )
                self.assertEqual(
                    str(caught.exception), "legacy_xml_extraction_failed"
                )

    def test_invalid_compatibility_contract_fails_sanitized(self):
        raw = self.malformed_xml()
        relative = "plugins/synthetic-compatibility.xml"
        cases = (
            XmlCompatibility(relative, "not-a-digest", lambda value: value),
            XmlCompatibility(relative, hashlib.sha256(raw).hexdigest(), None),
        )
        for compatibility in cases:
            with self.subTest(
                compatibility=compatibility
            ), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "malformed.xml"
                path.write_bytes(raw)
                with self.assertRaisesRegex(
                    ValidationFailure, "^legacy_xml_extraction_failed$"
                ):
                    extract_xml_constructs(
                        path, relative, compatibility=compatibility
                    )


class CoverageLedgerTests(unittest.TestCase):
    def test_accepts_exactly_once_coverage(self):
        required = ("construct:1", "construct:2")
        result = verify_complete_coverage(
            required,
            {
                "feature_one": ("construct:1",),
                "feature_two": ("construct:2",),
            },
            {"feature_one", "feature_two"},
        )
        self.assertTrue(result.complete)
        self.assertEqual(result.missing, ())
        self.assertEqual(result.duplicate, ())

    def test_reports_missing_duplicate_unknown_and_unmapped_features(self):
        result = verify_complete_coverage(
            ("construct:1", "construct:2"),
            {
                "feature_one": ("construct:1", "construct:1"),
                "unknown_feature": ("construct:3",),
            },
            {"feature_one", "feature_two"},
        )
        self.assertEqual(result.missing, ("construct:2",))
        self.assertEqual(result.duplicate, ("construct:1",))
        self.assertEqual(result.unknown_constructs, ("construct:3",))
        self.assertEqual(result.unknown_features, ("unknown_feature",))
        self.assertEqual(result.unmapped_features, ("feature_two",))
        self.assertFalse(result.complete)


if __name__ == "__main__":
    unittest.main()
