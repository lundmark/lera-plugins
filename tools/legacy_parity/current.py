"""Static inventory and construct extraction for current Lera plugins."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True, slots=True)
class CurrentPluginFile:
    """One production plugin source file in the current repository."""

    key: str
    path: str


@dataclass(frozen=True, slots=True)
class CurrentConstruct:
    """One statically identifiable responsibility in a current plugin."""

    id: str
    kind: str
    path: str
    line: int


_PATTERNS = (
    ("module_identity", ("M.name =",)),
    ("lifecycle", ("function M.on_",)),
    ("public_function", ("function M.",)),
    ("storage", ("store.",)),
    ("alias", ("alias.add",)),
    ("send", ("mud.send", "send_raw")),
    ("trigger", ("trigger.add",)),
    ("timer", ("timer.",)),
    ("mip", ("mip.on", "mip.off")),
    ("plugin_dependency", ("plugin.get", "plugin.load")),
    ("rendering", ("ui.", "buffer.")),
    ("configuration", ("config.",)),
    ("user_output", ("ui.text", "print(")),
    (
        "api",
        (
            "alias.",
            "trigger.",
            "timer.",
            "mip.",
            "plugin.",
            "store.",
            "mud.",
            "ui.",
            "buffer.",
            "config.",
        ),
    ),
)


def discover_current(repo_root: Path) -> tuple[CurrentPluginFile, ...]:
    """Return the direct production Lua plugins in generic/ and 3scapes/."""

    found: list[CurrentPluginFile] = []
    seen: set[str] = set()
    for directory in ("generic", "3scapes"):
        for path in sorted((repo_root / directory).glob("*.lua")):
            key = path.stem
            if key in seen:
                raise ValueError("duplicate_current_key")
            seen.add(key)
            found.append(
                CurrentPluginFile(key=key, path=path.relative_to(repo_root).as_posix())
            )
    return tuple(sorted(found, key=lambda item: item.key))


def extract_current(path: Path, relative_path: str) -> tuple[CurrentConstruct, ...]:
    """Classify current Lua responsibilities without executing the source."""

    constructs: list[CurrentConstruct] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        for kind, needles in _PATTERNS:
            if any(needle in line for needle in needles):
                constructs.append(
                    CurrentConstruct(
                        id=f"current:{relative_path}:{line_number}:{kind}",
                        kind=kind,
                        path=relative_path,
                        line=line_number,
                    )
                )
    return tuple(constructs)


def validate_code_ref(
    repo_root: Path, reference: str, current_paths
) -> tuple[str, int]:
    """Validate one safe, single-line reference to an in-scope current plugin."""

    match = re.fullmatch(r"([^:]+):([1-9][0-9]*)", reference)
    if match is None:
        raise ValueError("invalid_current_ref")
    relative, line_text = match.groups()
    if (
        relative.startswith("/")
        or "\\" in relative
        or relative not in set(current_paths)
        or not relative.startswith(("generic/", "3scapes/"))
    ):
        raise ValueError("invalid_current_ref")
    root = Path(repo_root).resolve()
    candidate = (root / relative).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as error:
        raise ValueError("invalid_current_ref") from error
    if not candidate.is_file():
        raise ValueError("invalid_current_ref")
    line_number = int(line_text)
    if line_number > len(
        candidate.read_text(encoding="utf-8").splitlines()
    ):
        raise ValueError("invalid_current_ref")
    return relative, line_number


def compare_mirror(left: Path, right: Path) -> tuple[str, ...]:
    """Compare production Lua mirror paths and bytes exactly."""

    def sources(root: Path) -> dict[str, Path]:
        return {
            path.relative_to(root).as_posix(): path
            for directory in ("generic", "3scapes")
            for path in sorted((root / directory).glob("*.lua"))
        }

    left_sources = sources(left)
    right_sources = sources(right)
    findings = [
        f"added:{name}"
        for name in sorted(right_sources.keys() - left_sources.keys())
    ]
    findings.extend(
        f"missing:{name}"
        for name in sorted(left_sources.keys() - right_sources.keys())
    )
    findings.extend(
        f"changed:{name}"
        for name in sorted(left_sources.keys() & right_sources.keys())
        if left_sources[name].read_bytes() != right_sources[name].read_bytes()
    )
    return tuple(findings)
