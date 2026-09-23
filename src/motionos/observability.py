from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path

OBSERVABILITY_SCHEMA_VERSION = "motionos.observability-registry.v1"
ALLOWED_OBSERVABILITY = {"observable", "conditional", "unidentifiable"}


def _strings(value: object, *, label: str, allow_empty: bool = True) -> tuple[str, ...]:
    if not isinstance(value, list):
        raise TypeError(f"{label} must be a list")
    values = tuple(str(item).strip() for item in value)
    if any(not item for item in values):
        raise ValueError(f"{label} entries must be non-empty")
    if len(set(values)) != len(values):
        raise ValueError(f"{label} entries must be unique")
    if not allow_empty and not values:
        raise ValueError(f"{label} must not be empty")
    return values


@dataclass(frozen=True)
class LatentVariable:
    variable_id: str
    label: str
    units: str
    coordinate_frame: str
    observability: str
    teacher_eligible: bool
    directly_observed_by: tuple[str, ...]
    indirectly_observed_by: tuple[str, ...]
    required_transforms: tuple[str, ...]
    reference_sources: tuple[str, ...]
    known_ambiguities: tuple[str, ...]
    non_claims: tuple[str, ...]

    def __post_init__(self) -> None:
        for label, value in (
            ("variable_id", self.variable_id),
            ("label", self.label),
            ("units", self.units),
            ("coordinate_frame", self.coordinate_frame),
        ):
            if not value.strip():
                raise ValueError(f"{label} must be non-empty")
        if self.observability not in ALLOWED_OBSERVABILITY:
            raise ValueError(
                "observability must be one of "
                + ", ".join(sorted(ALLOWED_OBSERVABILITY))
            )
        overlap = set(self.directly_observed_by) & set(self.indirectly_observed_by)
        if overlap:
            raise ValueError(
                "a modality cannot be both direct and indirect evidence: "
                + ", ".join(sorted(overlap))
            )
        if self.teacher_eligible and self.observability == "unidentifiable":
            raise ValueError(
                f"unidentifiable variable {self.variable_id!r} "
                "cannot be teacher_eligible"
            )
        if self.teacher_eligible and not (
            self.directly_observed_by or self.reference_sources
        ):
            raise ValueError(
                f"teacher-eligible variable {self.variable_id!r} requires "
                "direct evidence or an explicit reference source"
            )

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class ObservabilityRegistry:
    registry_id: str
    sport: str
    variables: tuple[LatentVariable, ...]
    notes: tuple[str, ...]
    schema_version: str = OBSERVABILITY_SCHEMA_VERSION

    def __post_init__(self) -> None:
        if not self.registry_id.strip():
            raise ValueError("registry_id must be non-empty")
        if not self.sport.strip():
            raise ValueError("sport must be non-empty")
        if not self.variables:
            raise ValueError("observability registry requires variables")
        ids = [item.variable_id for item in self.variables]
        if len(set(ids)) != len(ids):
            raise ValueError("observability variable_id values must be unique")

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "registry_id": self.registry_id,
            "sport": self.sport,
            "variables": [item.to_dict() for item in self.variables],
            "notes": list(self.notes),
            "claim_boundary": (
                "Observability entries describe which evidence constrains a "
                "quantity. They do not establish physical accuracy or model "
                "performance."
            ),
        }

    def by_id(self) -> dict[str, LatentVariable]:
        return {item.variable_id: item for item in self.variables}


def _variable(data: dict[str, object], *, index: int) -> LatentVariable:
    try:
        variable_id = str(data["variable_id"]).strip()
        label = str(data["label"]).strip()
        units = str(data["units"]).strip()
        coordinate_frame = str(data["coordinate_frame"]).strip()
        observability = str(data["observability"]).strip()
    except KeyError as exc:
        raise ValueError(
            f"observability variable {index} missing {exc.args[0]!r}"
        ) from exc

    teacher_eligible = data.get("teacher_eligible")
    if not isinstance(teacher_eligible, bool):
        raise TypeError(
            f"observability variable {variable_id!r} "
            "teacher_eligible must be boolean"
        )

    return LatentVariable(
        variable_id=variable_id,
        label=label,
        units=units,
        coordinate_frame=coordinate_frame,
        observability=observability,
        teacher_eligible=teacher_eligible,
        directly_observed_by=_strings(
            data.get("directly_observed_by", []),
            label=f"{variable_id}.directly_observed_by",
        ),
        indirectly_observed_by=_strings(
            data.get("indirectly_observed_by", []),
            label=f"{variable_id}.indirectly_observed_by",
        ),
        required_transforms=_strings(
            data.get("required_transforms", []),
            label=f"{variable_id}.required_transforms",
        ),
        reference_sources=_strings(
            data.get("reference_sources", []),
            label=f"{variable_id}.reference_sources",
        ),
        known_ambiguities=_strings(
            data.get("known_ambiguities", []),
            label=f"{variable_id}.known_ambiguities",
        ),
        non_claims=_strings(
            data.get("non_claims", []),
            label=f"{variable_id}.non_claims",
        ),
    )


def load_observability_registry(path: str | Path) -> ObservabilityRegistry:
    source = Path(path)
    raw = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("observability registry must contain a JSON object")
    if raw.get("schema_version") != OBSERVABILITY_SCHEMA_VERSION:
        raise ValueError("unsupported observability registry schema")

    variables_raw = raw.get("variables")
    if not isinstance(variables_raw, list):
        raise TypeError("observability registry variables must be a list")

    variables: list[LatentVariable] = []
    for index, item in enumerate(variables_raw):
        if not isinstance(item, dict):
            raise TypeError(f"observability variable {index} must be an object")
        variables.append(_variable(dict(item), index=index))

    return ObservabilityRegistry(
        registry_id=str(raw.get("registry_id", "")).strip(),
        sport=str(raw.get("sport", "")).strip(),
        variables=tuple(variables),
        notes=_strings(raw.get("notes", []), label="registry.notes"),
    )
