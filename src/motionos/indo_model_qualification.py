from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

INDO_MODEL_QUALIFICATION_SCHEMA_VERSION = (
    "motionos.indo-equipment-model-qualification.v1"
)
INDO_MODEL_QUALIFICATION_REGISTRY_SCHEMA_VERSION = (
    "motionos.indo-equipment-model-qualification-registry.v1"
)

_ALLOWED_STATUSES = {
    "unqualified",
    "evaluation_only",
    "qualified_for_beta_tracking",
    "qualified_for_beta_coaching",
}

_AUTHORIZED_STATUSES = {
    "qualified_for_beta_tracking",
    "qualified_for_beta_coaching",
}


def build_equipment_model_qualification_registry(
    evaluation_path: str | Path,
    output_path: str | Path,
    *,
    model_id: str,
    status: str = "evaluation_only",
    evaluation_dataset_id: str | None = None,
    authorization_note: str | None = None,
) -> dict[str, Any]:
    """Build a Swift-compatible markerless model qualification registry.

    Promotion is intentionally explicit. Evaluation metrics are copied into
    the receipt, but no threshold automatically converts a model from
    evaluation-only to a runtime-authorized state.
    """

    if not model_id.strip():
        raise ValueError("model_id must be non-empty")
    if status not in _ALLOWED_STATUSES:
        raise ValueError(
            "status must be one of: "
            + ", ".join(sorted(_ALLOWED_STATUSES))
        )
    if status in _AUTHORIZED_STATUSES and not (
        authorization_note
        and authorization_note.strip()
    ):
        raise ValueError(
            "runtime authorization requires an explicit authorization_note"
        )

    evaluation_file = Path(evaluation_path)
    raw_bytes = evaluation_file.read_bytes()
    evaluation = json.loads(raw_bytes)
    if not isinstance(evaluation, dict):
        raise TypeError(
            "evaluation report must contain a JSON object"
        )

    schema = evaluation.get("schema_version")
    if schema not in {
        "motionos.indo-runtime-equipment-eval.v1",
        "motionos.indo-equipment-eval.v1",
    }:
        raise ValueError(
            "unsupported equipment evaluation schema"
        )

    raw_metrics = evaluation.get("metrics")
    metrics = _numeric_map(raw_metrics)

    coverage = evaluation.get(
        "reference_coverage_fraction"
    )
    if isinstance(coverage, (int, float)):
        metrics["reference_coverage_fraction"] = float(
            coverage
        )

    matched = evaluation.get("matched_count")
    if isinstance(matched, int):
        metrics["matched_count"] = float(matched)

    reference_count = evaluation.get("reference_count")
    if isinstance(reference_count, int):
        metrics["reference_count"] = float(reference_count)

    evaluation_sha256 = hashlib.sha256(
        raw_bytes
    ).hexdigest()
    dataset_id = (
        evaluation_dataset_id.strip()
        if evaluation_dataset_id
        and evaluation_dataset_id.strip()
        else f"equipment-eval/{evaluation_sha256[:16]}"
    )

    qualification = {
        "schema_version":
            INDO_MODEL_QUALIFICATION_SCHEMA_VERSION,
        "model_id": model_id.strip(),
        "status": status,
        "evaluation_dataset_id": dataset_id,
        "evaluation_report_sha256":
            evaluation_sha256,
        "authorization_note": (
            authorization_note.strip()
            if authorization_note
            and authorization_note.strip()
            else None
        ),
        "metrics": metrics,
        "claim_boundary": (
            "Qualification authorizes only the declared MotionOS beta "
            "equipment-tracking use. It does not establish metric camera "
            "calibration, force, center-of-mass, medical, or injury-risk "
            "validity."
        ),
    }

    registry = {
        "schema_version":
            INDO_MODEL_QUALIFICATION_REGISTRY_SCHEMA_VERSION,
        "qualifications": [qualification],
        "claim_boundary": (
            "This registry is an explicit runtime authorization boundary. "
            "Absence from the registry must fail closed rather than silently "
            "authorizing a markerless model."
        ),
    }

    _write_json(output_path, registry)
    return registry


def _numeric_map(
    raw: object,
) -> dict[str, float]:
    if not isinstance(raw, dict):
        return {}

    result: dict[str, float] = {}
    for key, value in raw.items():
        if isinstance(value, bool):
            continue
        if isinstance(value, (int, float)):
            result[str(key)] = float(value)
    return result


def _write_json(
    path: str | Path,
    payload: dict[str, Any],
) -> None:
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, indent=2, sort_keys=True)
        + "\n",
        encoding="utf-8",
    )
