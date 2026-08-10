import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

from . import EXIT_FINDINGS, EXIT_GITHUB, EXIT_INVALID, EXIT_OK
from .audit import stage_preliminary_audit, validate_preliminary_audits
from .current import discover_current
from .issues import CommandResult, sync_capability_issue
from .legacy import (
    SelectionState,
    discover,
    included_target_from_dict,
    load_selection,
    record_included_target,
    record_omitted_candidate,
    write_selection,
)
from .manifest import manifest_from_staged, render_manifest
from .model import (
    CurrentPlugin,
    LegacySource,
    LegacyTarget,
    Manifest,
    ScopeApproval,
)
from .privacy import sanitize_diagnostic
from .publish import PublicationCandidate, publish_transaction
from .report import render_not_converted, render_parity_report
from .scope import (
    binding_digest,
    canonical_bindings,
    canonical_scope,
    scope_digest,
)
from .staged import (
    load_staged_bundle,
    parse_staged_bundle,
    write_staged_bundle,
)
from .state import (
    _atomic_json,
    approve_canonical_scope,
    load_approval,
)
from .validation import (
    PrivateValidationRoots,
    ValidationFailure,
    full_private_publication_gate,
    selection_bindings,
    validate_full_private,
    validate_public,
)


def _repo_root():
    return Path(__file__).resolve().parents[2]


def _state_root():
    base = os.environ.get("XDG_STATE_HOME")
    if base:
        return Path(base) / "lera-plugins" / "legacy-parity"
    return Path.home() / ".local" / "state" / "lera-plugins" / "legacy-parity"


def _common(parser, *, plugin=False, public=False):
    parser.add_argument("--state-root", default=str(_state_root()))
    if plugin:
        parser.add_argument("--plugin-root", default=str(_repo_root()))
    if public:
        parser.add_argument("--public-repo", default=str(_repo_root()))


def build_parser():
    parser = argparse.ArgumentParser(
        description="Legacy parity validation for approved plugins"
    )
    commands = parser.add_subparsers(dest="command")

    discover_parser = commands.add_parser("discover")
    discover_parser.add_argument("--legacy-root", required=True)
    discover_parser.add_argument("--revisit-omitted", action="store_true")
    _common(discover_parser)

    select_parser = commands.add_parser("select")
    select_parser.add_argument("--legacy-root", required=True)
    selection = select_parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--omit")
    selection.add_argument("--include-target-record")
    _common(select_parser, public=True)

    stage_parser = commands.add_parser("stage-preliminary")
    stage_parser.add_argument("--record", required=True)
    _common(stage_parser, plugin=True)

    check_parser = commands.add_parser("check-preliminary")
    check_parser.add_argument("--legacy-root", required=True)
    _common(check_parser, plugin=True)

    stage_audit_parser = commands.add_parser("stage-audit")
    stage_audit_parser.add_argument("--input", required=True)
    _common(stage_audit_parser, public=True)

    propose = commands.add_parser("propose-scope")
    propose.add_argument("--legacy-root", required=True)
    propose.add_argument("--output", required=True)
    _common(propose, plugin=True)

    approve = commands.add_parser("approve-scope")
    approve.add_argument("--proposal", required=True)
    approve.add_argument("--revision", required=True, type=int)
    approve.add_argument("--approved-on", required=True)
    approve.add_argument("--confirmed-public-digest", required=True)
    approve.add_argument("--confirmed-binding-digest", required=True)
    _common(approve)

    validate = commands.add_parser("validate")
    validate.add_argument(
        "--level", choices=("public", "full-private"), required=True
    )
    validate.add_argument("--legacy-root")
    validate.add_argument("--lera-root")
    validate.add_argument("--lera-bin")
    validate.add_argument("--require-parity", action="store_true")
    validate.add_argument("--refresh-legacy", action="store_true")
    validate.add_argument("--private-report")
    _common(validate, plugin=True)

    sync = commands.add_parser("sync-issues")
    sync.add_argument("--staged", required=True)
    sync.add_argument("--dry-run", action="store_true")
    _common(sync, public=True)

    publish = commands.add_parser("publish")
    publish.add_argument("--staged", required=True)
    publish.add_argument("--legacy-root", required=True)
    publish.add_argument("--lera-root", required=True)
    publish.add_argument("--lera-bin", required=True)
    _common(publish, plugin=True)

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


def _private_path(path, state_root, code):
    candidate = Path(path).resolve()
    root = Path(state_root).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as error:
        raise ValueError(code) from error
    return candidate


def _proposal_manifest(selection, plugin_root, revision):
    inventory = discover_current(Path(plugin_root))
    current = []
    for item in inventory:
        targets = tuple(
            sorted(
                target.key
                for target in selection.included_targets
                if item.key in target.current_plugins
            )
        )
        current.append(CurrentPlugin(item.key, item.path, targets))
    targets = tuple(
        LegacyTarget(
            key=target.key,
            sources=tuple(
                LegacySource(
                    source.kind,
                    source.path,
                    source.coverage,
                    source.feature_keys,
                )
                for source in target.sources
            ),
            current_plugins=target.current_plugins,
            features=(),
        )
        for target in selection.included_targets
    )
    base = Manifest(
        ScopeApproval(revision, "1970-01-01", "0" * 64),
        tuple(current),
        targets,
        (),
    )
    return base


def _propose_scope(args):
    selection = load_selection(args.state_root)
    audits = validate_preliminary_audits(
        args.state_root, args.plugin_root, selection
    )
    if not Path(args.legacy_root).is_dir():
        raise ValueError("missing_legacy_root")
    try:
        prior = load_approval(args.state_root)
        revision = prior.revision + 1
    except (OSError, ValueError):
        revision = 1
    manifest = _proposal_manifest(selection, args.plugin_root, revision)
    bindings = selection_bindings(selection)
    public = canonical_scope(manifest).decode("utf-8")
    private = canonical_bindings(bindings).decode("utf-8")
    proposal = {
        "version": 1,
        "revision": revision,
        "public_scope": public,
        "public_digest": scope_digest(manifest),
        "private_bindings": private,
        "binding_digest": binding_digest(bindings),
        "preliminary": [
            {
                "current_key": audit.current_key,
                "target_keys": list(audit.target_keys),
                "status_counts": [
                    list(item) for item in audit.preliminary_status_counts
                ],
            }
            for audit in audits
        ],
    }
    output = _private_path(
        args.output, args.state_root, "scope_proposal_not_private"
    )
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    _atomic_json(output, proposal)
    print("Private scope proposal written.")
    return EXIT_OK


def _approve_scope(args):
    proposal_path = _private_path(
        args.proposal, args.state_root, "scope_proposal_not_private"
    )
    value = json.loads(proposal_path.read_text(encoding="utf-8"))
    required = {
        "version",
        "revision",
        "public_scope",
        "public_digest",
        "private_bindings",
        "binding_digest",
        "preliminary",
    }
    if set(value) != required or value["version"] != 1:
        raise ValueError("invalid_scope_proposal")
    if (
        args.revision != value["revision"]
        or args.confirmed_public_digest != value["public_digest"]
        or args.confirmed_binding_digest != value["binding_digest"]
    ):
        raise ValueError("scope_confirmation_mismatch")
    approve_canonical_scope(
        args.state_root,
        public_scope=value["public_scope"],
        private_bindings=value["private_bindings"],
        revision=args.revision,
        approved_on=args.approved_on,
        confirmed_public_digest=args.confirmed_public_digest,
        confirmed_binding_digest=args.confirmed_binding_digest,
    )
    print("Exact private scope approval recorded.")
    return EXIT_OK


def _gh_runner(arguments):
    result = subprocess.run(
        arguments,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=30,
        check=False,
    )
    return CommandResult(result.returncode, result.stdout, result.stderr)


def _sync_issues(args):
    path = Path(args.staged).resolve()
    bundle = parse_staged_bundle(path)
    state_root = (
        path.parent.parent
        if path.parent.name == "staged"
        else Path(args.state_root).resolve()
    )
    for blocker in bundle.blockers:
        result = sync_capability_issue(
            bundle,
            blocker.key,
            _gh_runner,
            state_root=state_root,
            public_repo=args.public_repo,
            validate_bundle=lambda value: (
                None
                if value == bundle and value.version == 1
                else (_ for _ in ()).throw(ValueError("staged_bundle_mismatch"))
            ),
            dry_run=args.dry_run,
        )
        if result.exit_code != 0:
            return EXIT_GITHUB
        bundle = result.bundle
    print("Capability issues synchronized.")
    return EXIT_OK


def _roots(args):
    if not args.legacy_root or not args.lera_root or not args.lera_bin:
        raise ValueError("missing_private_root")
    return PrivateValidationRoots(
        repo_root=Path(args.plugin_root),
        state_root=Path(args.state_root),
        legacy_root=Path(args.legacy_root),
        lera_root=Path(args.lera_root),
    )


def _publish(args):
    path = Path(args.staged).resolve()
    bundle = parse_staged_bundle(path)
    loaded = load_staged_bundle(args.state_root)
    if bundle != loaded:
        raise ValidationFailure("staged_bundle_mismatch")
    approval = load_approval(args.state_root)
    selection = load_selection(args.state_root)
    manifest = manifest_from_staged(bundle, approval, selection)
    candidate = PublicationCandidate(
        repo_root=args.plugin_root,
        private_root=Path(args.state_root) / "publication",
        manifest_bytes=render_manifest(manifest).encode("utf-8"),
        report_bytes=render_parity_report(manifest).encode("utf-8"),
        not_converted_bytes=render_not_converted(manifest).encode("utf-8"),
    )
    roots = _roots(args)
    publish_transaction(
        candidate,
        bundle,
        lambda exact, staged: full_private_publication_gate(
            exact, staged, roots, args.lera_bin
        ),
    )
    print("Validated parity artifacts published.")
    return EXIT_OK


def _dispatch(args):
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
            _selection(args.state_root), args.omit, args.legacy_root
        )
        write_selection(
            args.state_root, selection, public_repo=args.public_repo
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
        current_keys = {
            item.key for item in discover_current(Path(args.public_repo))
        }
        selection = record_included_target(
            _selection(args.state_root),
            target,
            args.legacy_root,
            current_keys=current_keys,
        )
        write_selection(
            args.state_root, selection, public_repo=args.public_repo
        )
        print("Selection updated.")
        return EXIT_OK
    if args.command == "stage-preliminary":
        stage_preliminary_audit(
            args.state_root,
            args.record,
            plugin_root=args.plugin_root,
            selection=load_selection(args.state_root),
        )
        print("Preliminary audit staged.")
        return EXIT_OK
    if args.command == "check-preliminary":
        if not Path(args.legacy_root).is_dir():
            raise ValueError("missing_legacy_root")
        validate_preliminary_audits(
            args.state_root,
            args.plugin_root,
            load_selection(args.state_root),
        )
        print("Preliminary audits valid.")
        return EXIT_OK
    if args.command == "stage-audit":
        input_path = _private_path(
            args.input, args.state_root, "bundle_input_not_private"
        )
        bundle = parse_staged_bundle(input_path)
        write_staged_bundle(
            args.state_root, bundle, public_repo=args.public_repo
        )
        print("Private audit bundle staged.")
        return EXIT_OK
    if args.command == "propose-scope":
        return _propose_scope(args)
    if args.command == "approve-scope":
        return _approve_scope(args)
    if args.command == "validate":
        if args.level == "public":
            if args.refresh_legacy:
                raise ValueError("refresh_legacy_private_only")
            summary = validate_public(
                args.plugin_root, require_parity=args.require_parity
            )
        else:
            summary = validate_full_private(
                roots=_roots(args),
                lera_bin=args.lera_bin,
                require_parity=args.require_parity,
                refresh_legacy=args.refresh_legacy,
                private_report=args.private_report,
            )
        print(summary.text, end="")
        return EXIT_OK
    if args.command == "sync-issues":
        return _sync_issues(args)
    if args.command == "publish":
        return _publish(args)
    return EXIT_INVALID


def main(argv=None):
    return _dispatch(build_parser().parse_args(argv))


def entrypoint(argv=None):
    try:
        return main(argv)
    except ValidationFailure as error:
        print(sanitize_diagnostic(error), file=sys.stderr)
        return EXIT_FINDINGS
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        json.JSONDecodeError,
        subprocess.SubprocessError,
    ) as error:
        print(sanitize_diagnostic(error), file=sys.stderr)
        return EXIT_INVALID
