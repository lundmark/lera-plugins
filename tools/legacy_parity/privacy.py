"""Privacy guards for candidate public bytes and diagnostics."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


@dataclass(frozen=True, slots=True)
class PrivacyFinding:
    artifact: str
    code: str


_HOME_RE = re.compile(r"(?:/home/|/Users/|[A-Za-z]:\\Users\\)")
_HEX_RE = re.compile(r"(?<![0-9a-f])[0-9a-f]{40}(?:[0-9a-f]{24})?(?![0-9a-f])")
_CREDENTIAL_RE = re.compile(
    r"(?i)(?:websocket[_-]?)?(?:token|password|credential|secret)"
    r"\s*[:=]\s*['\"]?[^\s'\"]+"
)
_SOURCE_BODY_RE = re.compile(
    r"(?i)<\s*(?:muclient|triggers|aliases|timers|script)\b"
    r"|\b(?:trigger|alias|timer)\s*\.\s*(?:add|new)\s*\("
)
_SAFE_DIAGNOSTIC_RE = re.compile(r"^[a-z][a-z0-9_]{0,79}$")
_PUBLIC_AUDIT_VOCABULARY = frozenset({"events"})


def _approved_public_scope_tokens(encoded):
    if not isinstance(encoded, str):
        raise ValueError("invalid_approved_public_scope")
    try:
        scope = json.loads(encoded)
    except json.JSONDecodeError as error:
        raise ValueError("invalid_approved_public_scope") from error
    canonical = json.dumps(
        scope,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    if (
        not isinstance(scope, dict)
        or set(scope) != {"version", "current_plugins", "legacy_targets"}
        or type(scope["version"]) is not int
        or scope["version"] != 1
        or not isinstance(scope["current_plugins"], list)
        or not isinstance(scope["legacy_targets"], list)
        or canonical != encoded
    ):
        raise ValueError("invalid_approved_public_scope")

    tokens = set()
    for current in scope["current_plugins"]:
        if (
            not isinstance(current, dict)
            or set(current) != {"key", "path"}
            or not all(
                isinstance(current[field], str) and current[field]
                for field in ("key", "path")
            )
        ):
            raise ValueError("invalid_approved_public_scope")
        tokens.add(current["key"])
        tokens.add(PurePosixPath(current["path"]).stem)

    for target in scope["legacy_targets"]:
        if (
            not isinstance(target, dict)
            or set(target) != {"key", "sources", "current_plugins"}
            or not isinstance(target["key"], str)
            or not target["key"]
            or not isinstance(target["sources"], list)
            or not isinstance(target["current_plugins"], list)
            or not all(
                isinstance(value, str) and value
                for value in target["current_plugins"]
            )
        ):
            raise ValueError("invalid_approved_public_scope")
        tokens.add(target["key"])
        tokens.update(target["current_plugins"])
        for source in target["sources"]:
            if (
                not isinstance(source, dict)
                or set(source)
                != {"kind", "path", "coverage", "feature_keys"}
                or not isinstance(source["path"], str)
                or not source["path"]
                or not isinstance(source["feature_keys"], list)
                or not all(
                    isinstance(value, str) and value
                    for value in source["feature_keys"]
                )
            ):
                raise ValueError("invalid_approved_public_scope")
            tokens.add(PurePosixPath(source["path"]).stem)
            tokens.update(source["feature_keys"])
    tokens.update(
        component
        for component in re.findall(r"[A-Za-z0-9]+", canonical)
        if len(component) >= 4
    )
    tokens.update(_PUBLIC_AUDIT_VOCABULARY)
    return frozenset(tokens)


def build_private_deny_tokens(
    selection,
    provenance,
    *,
    approved_public_scope,
    private_roots=(),
    private_text=(),
) -> tuple[str, ...]:
    approved_tokens = _approved_public_scope_tokens(
        approved_public_scope
    )
    tokens = set()
    for candidate in selection.omitted_candidates:
        tokens.add(candidate)
        stem = Path(candidate).stem
        if stem not in approved_tokens:
            tokens.add(stem)
    for root in private_roots:
        tokens.add(str(Path(root)))
    if provenance.legacy_commit:
        tokens.add(provenance.legacy_commit)
    for _, digest in provenance.source_digests:
        tokens.add(digest)
    tokens.update(
        value for value in private_text if isinstance(value, str) and value
    )
    return tuple(sorted(token for token in tokens if len(token) >= 4))


def _contains_deny_token(text, token):
    if re.fullmatch(r"[A-Za-z0-9_]+", token):
        return re.search(
            rf"(?<![A-Za-z0-9_]){re.escape(token)}(?![A-Za-z0-9_])",
            text,
        ) is not None
    return token in text


def scan_public_bytes(
    artifacts,
    *,
    deny_tokens=(),
    allowed_hashes=(),
) -> tuple[PrivacyFinding, ...]:
    allowed = set(allowed_hashes)
    findings = []
    for artifact in sorted(artifacts):
        content = artifacts[artifact]
        if not isinstance(content, bytes):
            raise ValueError("invalid_public_artifact_bytes")
        text = content.decode("utf-8", errors="replace")
        codes = set()
        if any(
            _contains_deny_token(text, token)
            for token in deny_tokens
        ):
            codes.add("private_deny_token")
        if _HOME_RE.search(text):
            codes.add("private_absolute_path")
        if _SOURCE_BODY_RE.search(text):
            codes.add("private_source_body")
        if _CREDENTIAL_RE.search(text):
            codes.add("credential_like_value")
        for match in _HEX_RE.finditer(text):
            if match.group(0) not in allowed:
                codes.add("private_hash_or_commit")
        findings.extend(
            PrivacyFinding(artifact=artifact, code=code)
            for code in sorted(codes)
        )
    return tuple(findings)


def assert_public_bytes(
    artifacts,
    *,
    deny_tokens=(),
    allowed_hashes=(),
) -> None:
    if scan_public_bytes(
        artifacts,
        deny_tokens=deny_tokens,
        allowed_hashes=allowed_hashes,
    ):
        raise ValueError("privacy_violation")


def sanitize_diagnostic(error) -> str:
    value = str(error)
    if _SAFE_DIAGNOSTIC_RE.fullmatch(value):
        return value
    return "validation_failed"
