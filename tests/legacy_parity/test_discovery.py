import shutil
import tempfile
import unittest
from pathlib import Path

from tools.legacy_parity.legacy import (
    FeatureBinding,
    IncludedTarget,
    SelectedSource,
    SelectionState,
    discover,
    load_selection,
    record_included_target,
    record_omitted_candidate,
    write_selection,
)


FIXTURE = Path(__file__).resolve().parent / "fixtures" / "private-tree"


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "legacy"
        shutil.copytree(FIXTURE, self.root)
        self.empty = SelectionState(version=1, included_targets=(), omitted_candidates=())

    def tearDown(self):
        self.temp.cleanup()

    def test_discovers_normalized_xml_paths_recursively(self):
        self.assertEqual(
            discover(self.root, self.empty),
            (
                "plugins/alpha.xml",
                "plugins/category/beta.xml",
                "plugins/coverage.xml",
            ),
        )

    def test_omitted_candidates_are_private_and_suppressed(self):
        selection = record_omitted_candidate(
            self.empty, "plugins/alpha.xml", self.root
        )
        self.assertEqual(
            discover(self.root, selection),
            (
                "plugins/category/beta.xml",
                "plugins/coverage.xml",
            ),
        )
        self.assertEqual(
            discover(self.root, selection, revisit_omitted=True),
            (
                "plugins/alpha.xml",
                "plugins/category/beta.xml",
                "plugins/coverage.xml",
            ),
        )

    def test_does_not_follow_symlinks_outside_root(self):
        outside = Path(self.temp.name) / "outside.xml"
        outside.write_text("<muclient/>", encoding="utf-8")
        (self.root / "plugins" / "leak.xml").symlink_to(outside)
        self.assertNotIn("plugins/leak.xml", discover(self.root, self.empty))

    def test_records_selected_bindings_and_multiple_current_plugins(self):
        target = IncludedTarget(
            key="sample_target",
            sources=(
                SelectedSource(
                    kind="xml",
                    path="plugins/alpha.xml",
                    coverage="selected",
                    feature_keys=("sample_command",),
                    bindings=(
                        FeatureBinding(
                            feature_key="sample_command",
                            construct_ids=("xml:plugins/alpha.xml:1",),
                        ),
                    ),
                ),
            ),
            current_plugins=("sample_a", "sample_b"),
        )
        selection = record_included_target(
            self.empty,
            target,
            self.root,
            current_keys={"sample_a", "sample_b"},
        )
        self.assertEqual(selection.included_targets, (target,))

    def test_rejects_overlapping_selected_bindings(self):
        first = IncludedTarget(
            key="first",
            sources=(
                SelectedSource(
                    kind="xml",
                    path="plugins/alpha.xml",
                    coverage="selected",
                    feature_keys=("one",),
                    bindings=(
                        FeatureBinding(
                            feature_key="one",
                            construct_ids=("xml:plugins/alpha.xml:1",),
                        ),
                    ),
                ),
            ),
            current_plugins=(),
        )
        second = IncludedTarget(
            key="second",
            sources=(
                SelectedSource(
                    kind="xml",
                    path="plugins/alpha.xml",
                    coverage="selected",
                    feature_keys=("two",),
                    bindings=(
                        FeatureBinding(
                            feature_key="two",
                            construct_ids=("xml:plugins/alpha.xml:1",),
                        ),
                    ),
                ),
            ),
            current_plugins=(),
        )
        selection = record_included_target(
            self.empty, first, self.root, current_keys=set()
        )
        with self.assertRaisesRegex(ValueError, "overlapping_binding"):
            record_included_target(
                selection, second, self.root, current_keys=set()
            )

    def test_rejects_target_without_xml_source(self):
        target = IncludedTarget(
            key="helper_only",
            sources=(
                SelectedSource(
                    kind="lua",
                    path="lua/alpha.lua",
                    coverage="complete",
                    feature_keys=(),
                    bindings=(),
                ),
            ),
            current_plugins=(),
        )
        with self.assertRaisesRegex(ValueError, "target_without_xml"):
            record_included_target(
                self.empty, target, self.root, current_keys=set()
            )

    def test_selection_persists_only_outside_public_repository(self):
        target_state = record_omitted_candidate(
            self.empty, "plugins/alpha.xml", self.root
        )
        private_state = Path(self.temp.name) / "state"
        write_selection(private_state, target_state, public_repo=self.root)
        self.assertEqual(load_selection(private_state), target_state)
        with self.assertRaisesRegex(ValueError, "public_selection_path"):
            write_selection(
                self.root / "private-state",
                target_state,
                public_repo=self.root,
            )


    def test_selection_reader_and_writer_reject_symlinked_state(self):
        target_state = record_omitted_candidate(
            self.empty, "plugins/alpha.xml", self.root
        )
        external = Path(self.temp.name) / "external-state"
        write_selection(external, target_state, public_repo=self.root)
        state = Path(self.temp.name) / "state-link"
        state.symlink_to(external, target_is_directory=True)

        with self.assertRaisesRegex(ValueError, "unsafe_private_path"):
            load_selection(state)
        (external / "selection.json").unlink()
        with self.assertRaisesRegex(ValueError, "unsafe_private_path"):
            write_selection(state, target_state, public_repo=self.root)
        self.assertFalse((external / "selection.json").exists())


if __name__ == "__main__":
    unittest.main()
