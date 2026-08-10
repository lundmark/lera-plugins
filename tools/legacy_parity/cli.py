import argparse
import json
from pathlib import Path

from . import EXIT_INVALID, EXIT_OK
from .audit import stage_preliminary_audit, validate_preliminary_audits
from .legacy import (
    SelectionState,
    discover,
    included_target_from_dict,
    load_selection,
    record_included_target,
    record_omitted_candidate,
    write_selection,
)


def build_parser():
    parser = argparse.ArgumentParser(
        description="Legacy parity validation for approved plugins"
    )
    commands = parser.add_subparsers(dest="command")

    discover_parser = commands.add_parser("discover")
    discover_parser.add_argument("--legacy-root", required=True)
    discover_parser.add_argument("--state-root", required=True)
    discover_parser.add_argument("--revisit-omitted", action="store_true")

    select_parser = commands.add_parser("select")
    select_parser.add_argument("--legacy-root", required=True)
    select_parser.add_argument("--state-root", required=True)
    select_parser.add_argument("--public-repo", required=True)
    selection = select_parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--omit")
    selection.add_argument("--include-target-record")

    stage_parser = commands.add_parser("stage-preliminary")
    stage_parser.add_argument("--plugin-root", required=True)
    stage_parser.add_argument("--state-root", required=True)
    stage_parser.add_argument("--record", required=True)

    check_parser = commands.add_parser("check-preliminary")
    check_parser.add_argument("--plugin-root", required=True)
    check_parser.add_argument("--legacy-root", required=True)
    check_parser.add_argument("--state-root", required=True)

    return parser


def _selection(state_root):
    path = Path(state_root) / "selection.json"
    if path.exists():
        return load_selection(state_root)
    return SelectionState(
        version=1,
        included_targets=(),
        omitted_candidates=(),
    )


def main(argv=None):
    args = build_parser().parse_args(argv)
    if not args.command:
        return EXIT_INVALID

    if args.command == "discover":
        selection = _selection(args.state_root)
        for path in discover(
            args.legacy_root,
            selection,
            revisit_omitted=args.revisit_omitted,
        ):
            print(path)
        return EXIT_OK

    if args.command == "select" and args.omit:
        selection = record_omitted_candidate(
            _selection(args.state_root),
            args.omit,
            args.legacy_root,
        )
        write_selection(
            args.state_root,
            selection,
            public_repo=args.public_repo,
        )
        print("Selection updated.")
        return EXIT_OK

    if args.command == "select" and args.include_target_record:
        record_path = Path(args.include_target_record).resolve()
        public_repo = Path(args.public_repo).resolve()
        if record_path == public_repo or public_repo in record_path.parents:
            raise ValueError("public_target_record")
        value = json.loads(record_path.read_text(encoding="utf-8"))
        target = included_target_from_dict(value)
        selection = record_included_target(
            _selection(args.state_root),
            target,
            args.legacy_root,
            current_keys=set(target.current_plugins),
        )
        write_selection(
            args.state_root,
            selection,
            public_repo=args.public_repo,
        )
        print("Selection updated.")
        return EXIT_OK

    if args.command == "stage-preliminary":
        selection = load_selection(args.state_root)
        stage_preliminary_audit(
            args.state_root,
            args.record,
            plugin_root=args.plugin_root,
            selection=selection,
        )
        print("Preliminary audit staged.")
        return EXIT_OK

    if args.command == "check-preliminary":
        if not Path(args.legacy_root).is_dir():
            raise ValueError("missing_legacy_root")
        selection = load_selection(args.state_root)
        validate_preliminary_audits(
            args.state_root,
            args.plugin_root,
            selection,
        )
        print("Preliminary audits valid.")
        return EXIT_OK

    return EXIT_INVALID
