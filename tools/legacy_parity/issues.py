"""Safe, deduplicated synchronization of private Lera capability issues."""

from __future__ import annotations

import json
import os
import re
import tempfile
from dataclasses import dataclass
from pathlib import Path

from .privacy import scan_public_bytes
from .staged import with_issue_url, write_staged_bundle


REPOSITORY = "lundmark/lera"
_URL_RE = re.compile(
    r"^https://github\.com/lundmark/lera/issues/[1-9][0-9]*$"
)
_KEY_RE = re.compile(r"^[a-z][a-z0-9_]{0,79}$")


@dataclass(frozen=True, slots=True)
class CommandResult:
    exit_code: int
    stdout: str
    stderr: str


@dataclass(frozen=True, slots=True)
class IssueSyncResult:
    exit_code: int
    bundle: object
    issue_url: str | None = None


def marker_for(capability_key):
    if not _KEY_RE.fullmatch(capability_key):
        raise ValueError("invalid_capability_key")
    return f"<!-- legacy-parity-capability: {capability_key} -->"


def _json(stdout, code):
    try:
        value = json.loads(stdout)
    except (TypeError, json.JSONDecodeError) as error:
        raise ValueError(code) from error
    if not isinstance(value, dict):
        raise ValueError(code)
    return value


def _run(runner, arguments):
    result = runner(tuple(arguments))
    if (
        not isinstance(result, CommandResult)
        or result.exit_code != 0
    ):
        raise ValueError("github_command_failed")
    return result


def _derive(bundle, capability_key):
    features = []
    plugins = set()
    evidence = []
    evidence_records = {item.key: item for item in bundle.evidence}
    for target in bundle.targets:
        for feature in target.features:
            if (
                feature.status != "lera_blocker"
                or feature.capability != capability_key
            ):
                continue
            features.append(f"{target.key}.{feature.key}")
            plugins.update(target.current_plugins)
            local_key = feature.evidence.local_key
            local = evidence_records.get(local_key)
            if (
                local is None
                or local.target != target.key
                or local.feature != feature.key
                or local.outcome != "fail"
            ):
                raise ValueError("invalid_blocker_evidence")
            evidence.append(local_key)
    blockers = [item for item in bundle.blockers if item.key == capability_key]
    if len(blockers) != 1 or not features:
        raise ValueError("invalid_blocker_record")
    blocker = blockers[0]
    if (
        blocker.affected_features != tuple(sorted(features))
        or blocker.affected_plugins != tuple(sorted(plugins))
        or blocker.evidence_keys != tuple(sorted(evidence))
    ):
        raise ValueError("invalid_blocker_derivation")
    return blocker, tuple(sorted(plugins))


def _issue_text(blocker, plugins):
    marker = marker_for(blocker.key)
    title = f"Legacy parity capability: {blocker.key}"
    plugin_lines = "\n".join(f"- `{key}`" for key in plugins)
    body = (
        f"A Lera capability is required for approved legacy parity.\n\n"
        f"Capability: `{blocker.key}`\n\n"
        f"Summary: {blocker.description}\n\n"
        f"Affected current plugins:\n{plugin_lines}\n\n"
        f"{marker}\n"
    )
    artifacts = {
        "issue_title": title.encode("utf-8"),
        "issue_body": body.encode("utf-8"),
    }
    if scan_public_bytes(artifacts):
        raise ValueError("unsafe_issue_text")
    if not all(_KEY_RE.fullmatch(key) for key in plugins):
        raise ValueError("unsafe_issue_text")
    return title, body


def _repository_is_private(runner):
    result = _run(
        runner,
        (
            "gh",
            "repo",
            "view",
            REPOSITORY,
            "--json",
            "nameWithOwner,visibility",
        ),
    )
    value = _json(result.stdout, "invalid_repository_response")
    return (
        set(value) == {"nameWithOwner", "visibility"}
        and value["nameWithOwner"] == REPOSITORY
        and value["visibility"] == "PRIVATE"
    )


def _search(runner, marker, state):
    query = f'repo:{REPOSITORY} is:{state} in:body "{marker}"'
    result = _run(
        runner,
        (
            "gh",
            "api",
            "search/issues",
            "-f",
            f"q={query}",
            "-f",
            "per_page=100",
        ),
    )
    value = _json(result.stdout, "invalid_issue_search")
    if set(value) != {"items"} or not isinstance(value["items"], list):
        raise ValueError("invalid_issue_search")
    urls = []
    for item in value["items"]:
        if (
            not isinstance(item, dict)
            or item.get("state") != state
            or marker not in item.get("body", "")
            or not _URL_RE.fullmatch(item.get("html_url", ""))
        ):
            raise ValueError("invalid_issue_search")
        urls.append(item["html_url"])
    return tuple(urls)


def _search_both(runner, marker):
    return _search(runner, marker, "open"), _search(
        runner, marker, "closed"
    )


def _create(runner, state_root, title, body):
    root = Path(state_root)
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if os.name == "posix":
        root.chmod(0o700)
    fd, path = tempfile.mkstemp(prefix=".issue-body.", dir=root)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(body)
            handle.flush()
            os.fsync(handle.fileno())
        result = _run(
            runner,
            (
                "gh",
                "issue",
                "create",
                "--repo",
                REPOSITORY,
                "--title",
                title,
                "--body-file",
                path,
            ),
        )
        url = result.stdout.strip()
        if not _URL_RE.fullmatch(url):
            raise ValueError("invalid_created_issue_url")
        return url
    finally:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def sync_capability_issue(
    bundle,
    capability_key,
    runner,
    *,
    state_root,
    public_repo,
    validate_bundle,
    dry_run=False,
) -> IssueSyncResult:
    try:
        validate_bundle(bundle)
        if bundle.version != 1:
            raise ValueError("invalid_staged_version")
        blocker, plugins = _derive(bundle, capability_key)
        title, body = _issue_text(blocker, plugins)
        marker = marker_for(capability_key)
        if not _repository_is_private(runner):
            raise ValueError("repository_not_private")
        open_urls, closed_urls = _search_both(runner, marker)
        if len(open_urls) + len(closed_urls) > 1 or closed_urls:
            raise ValueError("ambiguous_issue_marker")
        if open_urls:
            url = open_urls[0]
        elif dry_run:
            return IssueSyncResult(0, bundle, None)
        else:
            created_url = _create(runner, state_root, title, body)
            open_urls, closed_urls = _search_both(runner, marker)
            if (
                closed_urls
                or open_urls != (created_url,)
            ):
                raise ValueError("post_create_issue_ambiguity")
            url = created_url

        if dry_run:
            return IssueSyncResult(0, bundle, url)
        updated = with_issue_url(bundle, capability_key, url)
        write_staged_bundle(
            state_root,
            updated,
            public_repo=public_repo,
        )
        return IssueSyncResult(0, updated, url)
    except (OSError, ValueError, KeyError, TypeError):
        return IssueSyncResult(3, bundle, None)
