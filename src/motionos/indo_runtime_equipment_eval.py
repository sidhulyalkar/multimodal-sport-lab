from __future__ import annotations

import json
import math
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Any

INDO_RUNTIME_EQUIPMENT_EVAL_SCHEMA_VERSION = (
    "motionos.indo-runtime-equipment-eval.v1"
)

_REFERENCE_STATUSES = {
    "fiducial_teacher",
    "human_reviewed",
    "human_corrected",
}


def evaluate_runtime_equipment_predictions(
    reference_path: str | Path,
    prediction_path: str | Path,
    output_path: str | Path | None = None,
) -> dict[str, Any]:
    """Evaluate runtime deck/roller observations against trusted references.

    This evaluator intentionally operates on the same center-based equipment
    contract consumed by the Apple runtime. It therefore supports the
    three-marker QR teacher path, where the roller center is measured but its
    physical axis endpoints may be absent.
    """

    references = _load_observations(reference_path)
    predictions = _load_observations(prediction_path)

    ref_by_key = {
        _key(item): item
        for item in references
        if _trusted_reference(item)
    }
    pred_by_key = {
        _key(item): item
        for item in predictions
        if _equipment(item) is not None
    }

    rows: list[dict[str, Any]] = []
    by_source: dict[str, list[dict[str, Any]]] = defaultdict(list)

    for key, reference in ref_by_key.items():
        prediction = pred_by_key.get(key)
        if prediction is None:
            continue

        row = _compare(reference, prediction)
        if row is None:
            continue

        row["source_id"] = key[0]
        row["frame_index"] = key[1]
        rows.append(row)
        by_source[key[0]].append(row)

    payload = {
        "schema_version":
            INDO_RUNTIME_EQUIPMENT_EVAL_SCHEMA_VERSION,
        "reference_count": len(ref_by_key),
        "prediction_count": len(pred_by_key),
        "matched_count": len(rows),
        "reference_coverage_fraction": (
            len(rows) / len(ref_by_key)
            if ref_by_key
            else 0.0
        ),
        "metrics": _aggregate(rows),
        "by_source": {
            source_id: _aggregate(source_rows)
            for source_id, source_rows in sorted(
                by_source.items()
            )
        },
        "claim_boundary": (
            "These metrics evaluate normalized image-space runtime geometry "
            "against trusted image-space references. They do not establish "
            "metric camera calibration, force accuracy, or biomechanics "
            "validity."
        ),
    }

    if output_path is not None:
        _write_json(output_path, payload)
    return payload


def _compare(
    reference: dict[str, Any],
    prediction: dict[str, Any],
) -> dict[str, float] | None:
    ref_equipment = _equipment(reference)
    pred_equipment = _equipment(prediction)
    if ref_equipment is None or pred_equipment is None:
        return None

    ref_deck = ref_equipment.get("deck")
    pred_deck = pred_equipment.get("deck")
    ref_roller = ref_equipment.get("roller")
    pred_roller = pred_equipment.get("roller")

    if not all(
        isinstance(value, dict)
        for value in (
            ref_deck,
            pred_deck,
            ref_roller,
            pred_roller,
        )
    ):
        return None

    assert isinstance(ref_deck, dict)
    assert isinstance(pred_deck, dict)
    assert isinstance(ref_roller, dict)
    assert isinstance(pred_roller, dict)

    ref_left = _point(ref_deck.get("left_end"))
    ref_right = _point(ref_deck.get("right_end"))
    pred_left = _point(pred_deck.get("left_end"))
    pred_right = _point(pred_deck.get("right_end"))
    ref_center = _point(ref_roller.get("center"))
    pred_center = _point(pred_roller.get("center"))

    if None in (
        ref_left,
        ref_right,
        pred_left,
        pred_right,
        ref_center,
        pred_center,
    ):
        return None

    assert ref_left is not None
    assert ref_right is not None
    assert pred_left is not None
    assert pred_right is not None
    assert ref_center is not None
    assert pred_center is not None

    ref_along = _roller_along_deck(
        ref_left,
        ref_right,
        ref_center,
    )
    # Score position against the *reference deck axis* so deck detection error
    # cannot cancel roller-center error by moving both together.
    pred_along_on_reference = _roller_along_deck(
        ref_left,
        ref_right,
        pred_center,
    )

    ref_angle = _deck_angle(ref_left, ref_right)
    pred_angle = _deck_angle(pred_left, pred_right)

    return {
        "deck_left_error": _distance(
            ref_left,
            pred_left,
        ),
        "deck_right_error": _distance(
            ref_right,
            pred_right,
        ),
        "deck_endpoint_mean_error": (
            _distance(ref_left, pred_left)
            + _distance(ref_right, pred_right)
        )
        / 2,
        "deck_angle_abs_error_deg":
            _angular_difference_deg(
                ref_angle,
                pred_angle,
            ),
        "roller_center_error": _distance(
            ref_center,
            pred_center,
        ),
        "roller_along_deck_abs_error": abs(
            pred_along_on_reference - ref_along
        ),
        "center_zone_correct": float(
            (abs(ref_along) <= 0.20)
            == (abs(pred_along_on_reference) <= 0.20)
        ),
        "edge_zone_correct": float(
            (abs(ref_along) >= 0.75)
            == (abs(pred_along_on_reference) >= 0.75)
        ),
    }


def _aggregate(
    rows: list[dict[str, Any]],
) -> dict[str, float]:
    if not rows:
        return {}

    error_keys = (
        "deck_left_error",
        "deck_right_error",
        "deck_endpoint_mean_error",
        "deck_angle_abs_error_deg",
        "roller_center_error",
        "roller_along_deck_abs_error",
    )
    agreement_keys = (
        "center_zone_correct",
        "edge_zone_correct",
    )

    result: dict[str, float] = {}
    for key in error_keys:
        values = _numeric(rows, key)
        if not values:
            continue
        result[f"{key}_mean"] = statistics.fmean(values)
        result[f"{key}_p90"] = _percentile(values, 0.90)

    for key in agreement_keys:
        values = _numeric(rows, key)
        if values:
            result[f"{key}_fraction"] = statistics.fmean(values)

    return result


def _load_observations(
    path: str | Path,
) -> list[dict[str, Any]]:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if isinstance(raw, list):
        values = raw
    elif isinstance(raw, dict):
        values = raw.get("observations")
    else:
        values = None

    if not isinstance(values, list):
        raise TypeError(
            "runtime equipment evaluation input must be a list or "
            "{observations: [...]}"
        )

    return [
        value
        for value in values
        if isinstance(value, dict)
    ]


def _trusted_reference(
    observation: dict[str, Any],
) -> bool:
    status = observation.get("review_status")
    return (
        status in _REFERENCE_STATUSES
        and _equipment(observation) is not None
    )


def _equipment(
    observation: dict[str, Any],
) -> dict[str, Any] | None:
    value = observation.get("indo_board_equipment")
    return value if isinstance(value, dict) else None


def _key(
    observation: dict[str, Any],
) -> tuple[str, int]:
    source_id = observation.get("source_id")
    frame_index = observation.get("frame_index")
    if not isinstance(source_id, str) or not source_id:
        raise ValueError("observation source_id must be non-empty")
    if not isinstance(frame_index, int) or frame_index < 0:
        raise ValueError(
            "observation frame_index must be a non-negative integer"
        )
    return source_id, frame_index


def _point(
    value: object,
) -> tuple[float, float] | None:
    if not isinstance(value, list) or len(value) != 2:
        return None

    try:
        x = float(value[0])
        y = float(value[1])
    except (TypeError, ValueError):
        return None

    if not math.isfinite(x) or not math.isfinite(y):
        return None
    return x, y


def _distance(
    first: tuple[float, float],
    second: tuple[float, float],
) -> float:
    return math.hypot(
        first[0] - second[0],
        first[1] - second[1],
    )


def _deck_angle(
    left: tuple[float, float],
    right: tuple[float, float],
) -> float:
    return math.degrees(
        math.atan2(
            right[1] - left[1],
            right[0] - left[0],
        )
    )


def _angular_difference_deg(
    first: float,
    second: float,
) -> float:
    difference = (second - first + 180) % 360 - 180
    return abs(difference)


def _roller_along_deck(
    deck_left: tuple[float, float],
    deck_right: tuple[float, float],
    roller_center: tuple[float, float],
) -> float:
    dx = deck_right[0] - deck_left[0]
    dy = deck_right[1] - deck_left[1]
    length_squared = dx * dx + dy * dy
    if length_squared <= 1e-9:
        raise ValueError("deck endpoints are degenerate")

    rel_x = roller_center[0] - deck_left[0]
    rel_y = roller_center[1] - deck_left[1]
    projection = (
        rel_x * dx + rel_y * dy
    ) / length_squared
    return (projection - 0.5) * 2


def _numeric(
    rows: list[dict[str, Any]],
    key: str,
) -> list[float]:
    return [
        float(row[key])
        for row in rows
        if isinstance(row.get(key), (int, float))
    ]


def _percentile(
    values: list[float],
    quantile: float,
) -> float:
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]

    position = (
        len(ordered) - 1
    ) * min(1.0, max(0.0, quantile))
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]

    fraction = position - lower
    return (
        ordered[lower] * (1 - fraction)
        + ordered[upper] * fraction
    )


def _write_json(
    path: str | Path,
    payload: dict[str, Any],
) -> None:
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
