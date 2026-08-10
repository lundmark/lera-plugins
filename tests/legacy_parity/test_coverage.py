import tempfile
import unittest
from pathlib import Path

from tools.legacy_parity.coverage import verify_complete_coverage
from tools.legacy_parity.legacy import (
    executable_lua_lines,
    extract_xml_constructs,
)


FIXTURE = Path(__file__).resolve().parent / "fixtures" / "private-tree"


class LegacyExtractionTests(unittest.TestCase):
    def test_extracts_structural_xml_and_embedded_lua_constructs(self):
        path = FIXTURE / "plugins" / "coverage.xml"
        constructs = extract_xml_constructs(path, "plugins/coverage.xml")
        ids = {item.id for item in constructs}
        self.assertIn("xml:plugins/coverage.xml:2", ids)
        self.assertIn("xml:plugins/coverage.xml:4", ids)
        self.assertIn("xml:plugins/coverage.xml:5", ids)
        self.assertIn("xml-lua:plugins/coverage.xml:5:3", ids)
        self.assertIn("xml-lua:plugins/coverage.xml:5:4", ids)
        self.assertIn("xml-lua:plugins/coverage.xml:5:5", ids)

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
