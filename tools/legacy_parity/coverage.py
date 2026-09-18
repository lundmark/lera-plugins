from collections import Counter
from dataclasses import dataclass


@dataclass(frozen=True)
class CoverageResult:
    missing: tuple[str, ...]
    duplicate: tuple[str, ...]
    unknown_constructs: tuple[str, ...]
    unknown_features: tuple[str, ...]
    unmapped_features: tuple[str, ...]

    @property
    def complete(self):
        return not (
            self.missing
            or self.duplicate
            or self.unknown_constructs
            or self.unknown_features
            or self.unmapped_features
        )


def verify_complete_coverage(required, assignments, known_features):
    required_set = set(required)
    counts = Counter(
        construct
        for constructs in assignments.values()
        for construct in constructs
        if construct in required_set
    )
    assigned_all = {
        construct
        for constructs in assignments.values()
        for construct in constructs
    }
    return CoverageResult(
        missing=tuple(sorted(required_set - set(counts))),
        duplicate=tuple(
            sorted(construct for construct, count in counts.items() if count > 1)
        ),
        unknown_constructs=tuple(sorted(assigned_all - required_set)),
        unknown_features=tuple(sorted(set(assignments) - set(known_features))),
        unmapped_features=tuple(
            sorted(
                feature
                for feature in known_features
                if not assignments.get(feature)
            )
        ),
    )
