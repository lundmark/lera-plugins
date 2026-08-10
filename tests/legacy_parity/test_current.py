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
EXPECTED = (
    "autologin",
    "autostepper",
    "chat_monitor",
    "deadmans",
    "guild_druid",
    "help",
    "input_echo",
    "kill_trigger",
    "mapper",
    "mapview",
    "mercenary",
    "minimap",
    "player_stats",
    "push_notify",
    "roominfo",
    "speedwalk",
    "stats_window",
)

EXPECTED_PATHS = {
    "autologin": "generic/autologin.lua",
    "autostepper": "3scapes/autostepper.lua",
    "chat_monitor": "3scapes/chat_monitor.lua",
    "deadmans": "generic/deadmans.lua",
    "guild_druid": "3scapes/guild_druid.lua",
    "help": "generic/help.lua",
    "input_echo": "generic/input_echo.lua",
    "kill_trigger": "3scapes/kill_trigger.lua",
    "mapper": "3scapes/mapper.lua",
    "mapview": "3scapes/mapview.lua",
    "mercenary": "3scapes/mercenary.lua",
    "minimap": "3scapes/minimap.lua",
    "player_stats": "3scapes/player_stats.lua",
    "push_notify": "generic/push_notify.lua",
    "roominfo": "3scapes/roominfo.lua",
    "speedwalk": "3scapes/speedwalk.lua",
    "stats_window": "3scapes/stats_window.lua",
}


class CurrentInventoryTests(unittest.TestCase):
    def test_discovers_exactly_the_17_production_plugins(self):
        inventory = discover_current(REPO)
        self.assertEqual(tuple(item.key for item in inventory), EXPECTED)
        self.assertEqual({item.key: item.path for item in inventory}, EXPECTED_PATHS)
        self.assertNotIn("3scapes/configs/init.lua", {item.path for item in inventory})
        self.assertTrue(
            all(
                item.path.startswith(("generic/", "3scapes/"))
                for item in inventory
            )
        )

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
        records = tuple(
            CurrentPlugin(key=key, path=path)
            for key, path in sorted(EXPECTED_PATHS.items())
        )
        validate_current_scope(discover_current(REPO), records)
        with self.assertRaisesRegex(ValueError, "current_scope_mismatch"):
            validate_current_scope(discover_current(REPO), records[:-1])

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
