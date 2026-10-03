from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any

INDO_SHADOW_GATE_SPEC_SCHEMA_VERSION = (
    "motionos.indo-markerless-shadow-gate-spec.v1"
)
INDO_SHADOW_GATE_REPORT_SCHEMA_VERSION = (
    "motionos.indo-markerless-shadow-gate-report.v1"
)

_THRESHOLD_FIELDS = {
    "minimum_comparison_count": ("minimum", int),
    "maximum_roller_center_error_p90": ("maximum", float),
    "maximum_roller_along_reference_deck_abs_error_p90": (
        "maximum",
        float,
    ),
    "minimum_center_zone_agreement_fraction": (
        "minimum",
        float,
    ),
    "minimum_edge_zone_agreement_fraction": (
        "minimum",
        float,
    ),
    "minimum_detector_observation_fraction": (
        "minimum",
        float,
    ),
    "maximum_detector_error_fraction": (
        "maximum",
        float,
    ),
    "maximum_detector_duration_ms_p90": (
        "maximum",
        float,
    ),
}


def assess_markerless_shadow_gate(
    shadow_evaluation_path: str | Path,
    spec_path: str | Path,
    output_path: str | Path | None = None,
) -> dict[str, Any]:
    """Evaluate explicit engineering gates without authorizing the model.

    Thresholds live in a separate spec so MotionOS never invents a promotion
    policy from metrics. A passing report is evidence for review only; runtime
    authorization still requires a separately issued qualification registry.
    """

    evaluation_file = Path(shadow_evaluation_path)
    spec_file = Path(spec_path)

    evaluation = json.loads(
        evaluation_file.read_text(encoding="utf-8")
    )
    spec = json.loads(
        spec_file.read_text(encoding="utf-8")
    )

    if not isinstance(evaluation, dict):
        raise TypeError(
            "shadow evaluation must contain a JSON object"
        )
    if not isinstance(spec, dict):
        raise TypeError(
            "shadow gate spec must contain a JSON object"
        )

    if evaluation.get("schema_version") != (
        "motionos.indo-shadow-equipment-eval.v1"
    ):
        raise ValueError(
            "unsupported shadow evaluation schema"
        )
    if spec.get("schema_version") not in {
        None,
        INDO_SHADOW_GATE_SPEC_SCHEMA_VERSION,
    }:
        raise ValueError(
            "unsupported shadow gate spec schema"
        )

    model_id = _required_text(
        spec,
        "model_id",
    )
    detector_id = _required_text(
        spec,
        "candidate_detector_id",
    )
    reference_detector_id = _optional_text(
        spec.get("reference_detector_id")
    )

    thresholds_raw = spec.get("thresholds")
    if not isinstance(thresholds_raw, dict):
        raise TypeError(
            "shadow gate spec.thresholds must be an object"
        )

    thresholds = _thresholds(thresholds_raw)

    group = _select_evaluation_group(
        evaluation,
        model_id=model_id,
        detector_id=detector_id,
        reference_detector_id=reference_detector_id,
    )
    execution = _select_execution_group(
        evaluation,
        detector_id=detector_id,
    )

    observed = {
        "minimum_comparison_count":
            group["comparison_count"],
        "maximum_roller_center_error_p90":
            _metric(
                group,
                "roller_center_error_p90",
            ),
        "maximum_roller_along_reference_deck_abs_error_p90":
            _metric(
                group,
                "roller_along_reference_deck_abs_error_p90",
            ),
        "minimum_center_zone_agreement_fraction":
            _metric(
                group,
                "center_zone_agreement_fraction",
            ),
        "minimum_edge_zone_agreement_fraction":
            _metric(
                group,
                "edge_zone_agreement_fraction",
            ),
        "minimum_detector_observation_fraction":
            _execution_metric(
                execution,
                "observation_fraction",
            ),
        "maximum_detector_error_fraction":
            _execution_metric(
                execution,
                "error_fraction",
            ),
        "maximum_detector_duration_ms_p90":
            _execution_metric(
                execution,
                "duration_ms_p90",
            ),
    }

    criteria = []
    for name, threshold in thresholds.items():
        direction, _ = _THRESHOLD_FIELDS[name]
        value = observed[name]
        if direction == "minimum":
            passed = value >= threshold
        else:
            passed = value <= threshold

        criteria.append(
            {
                "criterion": name,
                "direction": direction,
                "threshold": threshold,
                "observed": value,
                "passed": passed,
            }
        )

    passed = all(
        criterion["passed"]
        for criterion in criteria
    )

    report = {
        "schema_version":
            INDO_SHADOW_GATE_REPORT_SCHEMA_VERSION,
        "model_id": model_id,
        "candidate_detector_id": detector_id,
        "reference_detector_id":
            group.get("reference_detector_id"),
        "passed": passed,
        "criteria": criteria,
        "source_shadow_evaluation":
            evaluation_file.name,
        "source_gate_spec":
            spec_file.name,
        "authorization_effect":
            "none",
        "claim_boundary": (
            "Passing this report means only that the explicit engineering "
            "thresholds in the referenced gate spec were met. It does not "
            "authorize runtime tracking or coaching; authorization requires "
            "a separate qualification registry and human approval note."
        ),
    }

    if output_path is not None:
        output = Path(output_path)
        output.parent.mkdir(
            parents=True,
            exist_ok=True,
        )
        output.write_text(
            json.dumps(
                report,
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )

    return report


def _select_evaluation_group(
    evaluation: dict[str, Any],
    *,
    model_id: str,
    detector_id: str,
    reference_detector_id: str | None,
) -> dict[str, Any]:
    groups = evaluation.get("groups")
    if not isinstance(groups, list):
        raise TypeError(
            "shadow evaluation groups must be a list"
        )

    matches = [
        group
        for group in groups
        if isinstance(group, dict)
        and group.get("candidate_model_id") == model_id
        and group.get("candidate_detector_id")
        == detector_id
        and (
            reference_detector_id is None
            or group.get("reference_detector_id")
            == reference_detector_id
        )
    ]

    if len(matches) != 1:
        raise ValueError(
            "shadow evaluation must contain exactly one matching "
            "model/detector/reference group"
        )

    group = matches[0]
    count = group.get("comparison_count")
    if not isinstance(count, int) or count < 0:
        raise ValueError(
            "shadow comparison_count must be a non-negative integer"
        )
    return group


def _select_execution_group(
    evaluation: dict[str, Any],
    *,
    detector_id: str,
) -> dict[str, Any]:
    groups = evaluation.get(
        "detector_execution_groups"
    )
    if not isinstance(groups, list):
        raise TypeError(
            "shadow detector_execution_groups must be a list"
        )

    matches = [
        group
        for group in groups
        if isinstance(group, dict)
        and group.get("detector_id") == detector_id
    ]
    if len(matches) != 1:
        raise ValueError(
            "shadow evaluation must contain exactly one matching "
            "detector execution group"
        )
    return matches[0]


def _metric(
    group: dict[str, Any],
    key: str,
) -> float:
    metrics = group.get("metrics")
    if not isinstance(metrics, dict):
        raise TypeError(
            "shadow evaluation group.metrics must be an object"
        )
    return _finite_number(
        metrics.get(key),
        label=f"metrics.{key}",
    )


def _execution_metric(
    group: dict[str, Any],
    key: str,
) -> float:
    return _finite_number(
        group.get(key),
        label=f"detector_execution.{key}",
    )


def _thresholds(
    raw: dict[str, Any],
) -> dict[str, float | int]:
    unknown = sorted(
        set(raw) - set(_THRESHOLD_FIELDS)
    )
    missing = sorted(
        set(_THRESHOLD_FIELDS) - set(raw)
    )
    if unknown:
        raise ValueError(
            "unknown shadow gate thresholds: "
            + ", ".join(unknown)
        )
    if missing:
        raise ValueError(
            "missing shadow gate thresholds: "
            + ", ".join(missing)
        )

    result: dict[str, float | int] = {}
    for name, (_, value_type) in _THRESHOLD_FIELDS.items():
        raw_value = raw[name]
        if value_type is int:
            if (
                not isinstance(raw_value, int)
                or isinstance(raw_value, bool)
                or raw_value < 1
            ):
                raise ValueError(
                    f"{name} must be an integer >= 1"
                )
            result[name] = raw_value
            continue

        value = _finite_number(
            raw_value,
            label=name,
        )
        if value < 0:
            raise ValueError(
                f"{name} must be >= 0"
            )
        if "fraction" in name and value > 1:
            raise ValueError(
                f"{name} must be <= 1"
            )
        result[name] = value

    return result


def _finite_number(
    value: object,
    *,
    label: str,
) -> float:
    if isinstance(value, bool) or not isinstance(
        value,
        (int, float),
    ):
        raise TypeError(
            f"{label} must be numeric"
        )
    number = float(value)
    if not math.isfinite(number):
        raise ValueError(
            f"{label} must be finite"
        )
    return number


def _required_text(
    value: dict[str, Any],
    key: str,
) -> str:
    text = _optional_text(value.get(key))
    if text is None:
        raise ValueError(
            f"{key} must be non-empty"
        )
    return text


def _optional_text(
    value: object,
) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise TypeError(
            "optional text values must be strings"
        )
    text = value.strip()
    return text or None
