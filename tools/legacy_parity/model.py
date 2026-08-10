from dataclasses import dataclass
from typing import Optional


CATEGORIES = frozenset(
    {
        "alias",
        "trigger",
        "timer",
        "callback",
        "state",
        "rendering",
        "persistence",
        "protocol",
        "command",
        "public_api",
    }
)
STATUSES = frozenset(
    {"parity", "plugin_gap", "lera_blocker", "not_converted", "waived"}
)
EVIDENCE_TYPES = frozenset(
    {"public_fixture", "local_behavior", "manual_private_review"}
)
SOURCE_KINDS = frozenset({"xml", "lua"})
COVERAGE_MODES = frozenset({"complete", "selected"})


@dataclass(frozen=True)
class ScopeApproval:
    revision: int
    approved_on: str
    digest: str


@dataclass(frozen=True)
class LegacySource:
    kind: str
    path: str
    coverage: str
    feature_keys: tuple[str, ...] = ()


@dataclass(frozen=True)
class Evidence:
    type: str
    review_date: str
    reviewed_scope: str
    result: str
    outcome: str
    reference: Optional[str] = None
    local_key: Optional[str] = None


@dataclass(frozen=True)
class Feature:
    key: str
    category: str
    status: str
    summary: str
    current_refs: tuple[str, ...]
    evidence: Evidence
    capability: Optional[str] = None
    waiver_approved_on: Optional[str] = None
    waiver_rationale: Optional[str] = None


@dataclass(frozen=True)
class CurrentPlugin:
    key: str
    path: str
    target_keys: tuple[str, ...] = ()
    fixtures: tuple[str, ...] = ()
    notes: Optional[str] = None


@dataclass(frozen=True)
class LegacyTarget:
    key: str
    sources: tuple[LegacySource, ...]
    current_plugins: tuple[str, ...]
    features: tuple[Feature, ...]


@dataclass(frozen=True)
class Capability:
    key: str
    description: str
    issue_url: str


@dataclass(frozen=True)
class Manifest:
    scope: ScopeApproval
    current_plugins: tuple[CurrentPlugin, ...]
    legacy_targets: tuple[LegacyTarget, ...]
    capabilities: tuple[Capability, ...] = ()
