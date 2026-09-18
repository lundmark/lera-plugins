"""Deterministic public reports and timestamped private verification reports."""

from __future__ import annotations

from collections import Counter
from pathlib import Path

from .compare import aggregate_target


PUBLIC_HEADING = (
    "PUBLIC BASELINE VERIFIED — PRIVATE APPROVAL AND "
    "LEGACY SOURCES NOT RECHECKED"
)
PRIVATE_HEADING = "FULL PRIVATE BASELINE VERIFIED"
PUBLIC_UNCHECKED = (
    "private scope approval",
    "legacy provenance and construct coverage",
    "current mirror parity",
    "private leakage deny tokens",
    "real Lera runtime",
)


def _quoted_list(values):
    values = tuple(values)
    return ", ".join(f"`{value}`" for value in values) if values else "None"


def _report_body(manifest):
    lines = [
        "# Legacy parity status",
        "",
        "## Current plugins",
    ]
    targets = {target.key: target for target in manifest.legacy_targets}
    for current in sorted(manifest.current_plugins, key=lambda item: item.key):
        mapped = tuple(
            sorted(
                target.key
                for target in manifest.legacy_targets
                if current.key in target.current_plugins
            )
        )
        lines.extend(
            [
                "",
                f"### `{current.key}`",
                "",
                f"- Path: `{current.path}`",
                f"- Approved targets: {_quoted_list(mapped)}",
            ]
        )

    capability_by_key = {
        capability.key: capability for capability in manifest.capabilities
    }
    lines.extend(["", "## Approved targets"])
    for target in sorted(manifest.legacy_targets, key=lambda item: item.key):
        aggregate = aggregate_target(target)
        counts = Counter(feature.status for feature in target.features)
        count_text = ", ".join(
            f"{status}={counts[status]}" for status in sorted(counts)
        )
        lines.extend(
            [
                "",
                f"### `{target.key}` — {aggregate.status}",
                "",
                f"- Current plugins: {_quoted_list(sorted(target.current_plugins))}",
                f"- Feature statuses: {count_text}",
            ]
        )
        for feature in target.features:
            line = (
                f"- `{feature.key}` ({feature.category}): "
                f"{feature.status} — {feature.summary}"
            )
            if feature.status == "lera_blocker":
                capability = capability_by_key.get(feature.capability)
                if capability is not None:
                    issue_number = capability.issue_url.rsplit("/", 1)[-1]
                    line += (
                        f" — [Lera issue #{issue_number}]"
                        f"({capability.issue_url})"
                    )
            lines.append(line)
    return lines


def render_parity_report(manifest) -> str:
    limitations = [
        PUBLIC_HEADING,
        "",
        "Not rechecked at the public validation level:",
        *(f"- {item}" for item in PUBLIC_UNCHECKED),
        "",
    ]
    return "\n".join(limitations + _report_body(manifest)) + "\n"


def render_not_converted(manifest) -> str:
    lines = ["# Approved targets not converted", ""]
    targets = tuple(
        sorted(
            (
                target
                for target in manifest.legacy_targets
                if not target.current_plugins
            ),
            key=lambda item: item.key,
        )
    )
    if not targets:
        lines.append("All approved targets have a current mapping.")
    else:
        for target in targets:
            count = len(target.features)
            noun = "feature" if count == 1 else "features"
            lines.append(
                f"- `{target.key}` — {count} approved {noun}"
            )
    return "\n".join(lines) + "\n"


def render_private_report(manifest, *, verified_at) -> str:
    return (
        "\n".join(
            [
                PRIVATE_HEADING,
                f"Verified at: {verified_at}",
                "",
            ]
            + _report_body(manifest)
        )
        + "\n"
    )


def resolve_private_report_path(
    state_root,
    repo_root,
    requested=None,
) -> Path:
    state = Path(state_root).resolve()
    repo = Path(repo_root).resolve()
    reports = state / "reports"
    candidate = (
        Path(requested).resolve()
        if requested is not None
        else reports / "full-private-report.md"
    )
    try:
        candidate.relative_to(repo)
    except ValueError:
        pass
    else:
        raise ValueError("public_private_report_path")
    try:
        relative = candidate.relative_to(reports)
    except ValueError as error:
        raise ValueError("unsafe_private_report_path") from error
    if len(relative.parts) != 1 or relative.name != "full-private-report.md":
        raise ValueError("unsafe_private_report_path")
    return candidate
