"""Privacy guards for candidate public bytes and diagnostics."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path


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


def build_private_deny_tokens(
    selection,
    provenance,
    *,
    private_roots=(),
    private_text=(),
) -> tuple[str, ...]:
    tokens = set()
    for candidate in selection.omitted_candidates:
        tokens.add(candidate)
        tokens.add(Path(candidate).stem)
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
        if any(token in text for token in deny_tokens):
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
