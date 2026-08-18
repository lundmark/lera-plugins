import tempfile
import unittest
from pathlib import Path

from tools.legacy_parity.current import (
    compare_mirror,
    discover_current,
    extract_current,
    validate_code_ref,
    validate_current_scope,
)
from tools.legacy_parity.model import CurrentPlugin


REPO = Path(__file__).resolve().parents[2]
FIXTURE = Path(__file__).resolve().parent / "fixtures"


def globbed_production_plugins() -> dict[str, str]:
    """The production plugins as the filesystem has them.

    Computed here rather than hardcoded: the authoritative census lives in
    validation/legacy-parity.toml, and `legacy-parity validate` is what holds
    discovery to it. Duplicating that list in the unit suite only meant every
    added plugin broke a test whose name then misreported the count.
    """

    found: dict[str, str] = {}
    for directory in ("generic", "3scapes"):
        for path in sorted((REPO / directory).glob("*.lua")):
            found[path.stem] = f"{directory}/{path.name}"
    return found


class CurrentInventoryTests(unittest.TestCase):
    def test_discovers_the_production_plugins_on_disk(self):
        inventory = discover_current(REPO)
        expected = globbed_production_plugins()

        self.assertTrue(expected, "no production plugins found to discover")
        self.assertEqual({item.key: item.path for item in inventory}, expected)

        keys = [item.key for item in inventory]
        self.assertEqual(keys, sorted(keys), "inventory must be sorted by key")
        self.assertEqual(len(keys), len(set(keys)), "keys must be unique")

    def test_discovery_covers_only_the_production_directories(self):
        inventory = discover_current(REPO)
        paths = {item.path for item in inventory}

        # Nested directories, example plugins and the test tree are all out of
        # scope: only the two production directories, one level deep.
        self.assertNotIn("3scapes/configs/init.lua", paths)
        for path in paths:
            self.assertTrue(path.startswith(("generic/", "3scapes/")), path)
            self.assertEqual(path.count("/"), 1, path)
            self.assertTrue((REPO / path).is_file(), path)

    def test_extracts_current_behavior_responsibilities(self):
        path = FIXTURE / "current" / "generic" / "sample.lua"
        constructs = extract_current(path, "generic/sample.lua")
        kinds = {item.kind for item in constructs}
        self.assertTrue(
            {
                "module_identity",
                "lifecycle",
                "storage",
                "alias",
                "send",
                "trigger",
                "timer",
                "mip",
                "plugin_dependency",
                "rendering",
                "public_function",
            }.issubset(kinds)
        )
        self.assertTrue(all(item.path == "generic/sample.lua" for item in constructs))

    def test_rejects_duplicate_basenames_across_production_directories(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "generic").mkdir()
            (root / "3scapes").mkdir()
            (root / "generic" / "duplicate.lua").write_text(
                "return {}\n", encoding="utf-8"
            )
            (root / "3scapes" / "duplicate.lua").write_text(
                "return {}\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(ValueError, "duplicate_current_key"):
                discover_current(root)

    def test_validates_inventory_against_manifest_current_records(self):
        # Exercises the comparison, not the census: records built from the live
        # inventory must agree, and dropping one must be caught. Whether the
        # committed manifest agrees with the repository is what
        # `legacy-parity validate --level public` decides.
        inventory = discover_current(REPO)
        records = tuple(
            CurrentPlugin(key=item.key, path=item.path) for item in inventory
        )
        validate_current_scope(inventory, records)
        with self.assertRaisesRegex(ValueError, "current_scope_mismatch"):
            validate_current_scope(inventory, records[:-1])
        with self.assertRaisesRegex(ValueError, "current_scope_mismatch"):
            validate_current_scope(
                inventory,
                records + (CurrentPlugin(key="ghost", path="generic/ghost.lua"),),
            )

    def test_validates_only_single_line_refs_inside_current_scope(self):
        scope = {"generic/sample.lua"}
        self.assertEqual(
            validate_code_ref(
                FIXTURE / "current", "generic/sample.lua:3", scope
            ),
            ("generic/sample.lua", 3),
        )
        for reference in (
            "generic/sample.lua:0",
            "generic/sample.lua:3-4",
            "/generic/sample.lua:3",
            "generic/missing.lua:3",
            "examples/sample.lua:3",
            "generic/sample.lua:999",
        ):
            with self.subTest(reference=reference):
                with self.assertRaisesRegex(ValueError, "invalid_current_ref"):
                    validate_code_ref(FIXTURE / "current", reference, scope)

    def test_mirror_comparison_is_byte_exact(self):
        left = FIXTURE / "current"
        right = FIXTURE / "mirror"
        self.assertEqual(compare_mirror(left, right), ())
        with tempfile.TemporaryDirectory() as temp:
            changed = Path(temp)
            (changed / "generic").mkdir()
            (changed / "generic" / "sample.lua").write_text(
                "return {}\n", encoding="utf-8"
            )
            self.assertEqual(
                compare_mirror(left, changed),
                ("changed:generic/sample.lua",),
            )

            (changed / "generic" / "sample.lua").unlink()
            self.assertEqual(
                compare_mirror(left, changed),
                ("missing:generic/sample.lua",),
            )

            (changed / "generic" / "extra.lua").write_text(
                "return {}\n", encoding="utf-8"
            )
            self.assertEqual(
                compare_mirror(left, changed),
                ("added:generic/extra.lua", "missing:generic/sample.lua"),
            )


if __name__ == "__main__":
    unittest.main()
